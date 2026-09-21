#!/usr/bin/env bash
# Harness: boots the mock server, exercises upload-rules.sh, tears down.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export NO_COLOR=1
PORT=8791
HOST="http://127.0.0.1:$PORT"
# The script appends /rules/v1/rule, so the base URL is the bare platform host.
BASE="$HOST"

# A second instance is armed with the fixture and matches every POST against
# it, so it gets a port of its own: the cases below deliberately send
# malformed, duplicate and exploding payloads that would land there as
# fixture mismatches.
FIXTURE=tests/test.json
FIXTURE_PORT=8792
FIXTURE_HOST="http://127.0.0.1:$FIXTURE_PORT"
FIXTURE_BASE="$FIXTURE_HOST"

wait_for() { # wait_for <host-url> <log-file>
  for _ in $(seq 1 40); do
    curl -sf -o /dev/null "$1/__log__" && return 0
    sleep 0.25
  done
  echo "mock server at $1 never came up; see $2" >&2
  return 1
}

python3 tests/mock-server.py "$PORT" > /tmp/mock.log 2>&1 &
MOCK_PID=$!
python3 tests/mock-server.py "$FIXTURE_PORT" --expect "$FIXTURE" > /tmp/mock-fixture.log 2>&1 &
FIXTURE_PID=$!
trap 'kill $MOCK_PID $FIXTURE_PID 2>/dev/null; rm -rf /tmp/qartest' EXIT
wait_for "$HOST" /tmp/mock.log || exit 1
wait_for "$FIXTURE_HOST" /tmp/mock-fixture.log || exit 1

mkdir -p /tmp/qartest
PASS=0; FAIL=0
check() { # check <desc> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1 (exit $3)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected exit $2, got $3)"; fi
}

check_eq() { # check_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1";
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (wanted '$2', got '$3')"; fi
}

# A botched retry budget hangs rather than fails, and a suite that hangs with
# it reports nothing. Runs that could loop get a deadline instead.
run_bounded() { # run_bounded <seconds> <cmd...>; exits 124 on the deadline
  local limit="$1"; shift
  "$@" &
  local pid=$! tenths=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$tenths" -ge "$((limit * 10))" ]; then
      # TERM first: the script traps it and takes its temp dir with it.
      kill -TERM "$pid" 2>/dev/null
      sleep 1
      kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 0.1
    tenths=$((tenths+1))
  done
  wait "$pid"
}

banner() { echo; echo "=============== $* ==============="; }

banner "T1  happy path, 2 args, token from \$QODO_API_KEY"
QODO_API_KEY=sk-default-var ./upload-rules.sh "$BASE" rule.json
check "every rule in rule.json created" 0 $?

banner "T2  re-upload is idempotent-ish (all 409)"
QODO_API_KEY=sk-default-var ./upload-rules.sh "$BASE" rule.json
check "all already exist" 0 $?

banner "T3  3 args, token read from a NAMED variable"
export MY_QODO_TOKEN=sk-named-var
env -u QODO_API_KEY ./upload-rules.sh "$BASE/" rule.json MY_QODO_TOKEN -w ws-abc -q
check "named-var token accepted" 0 $?

banner "T4  3 args, LITERAL token (name does not match any variable)"
env -u QODO_API_KEY ./upload-rules.sh "$BASE" rule.json sk-literal-token-123 -q
check "literal token accepted" 0 $?

banner "T5  3 args, literal token that LOOKS like a var name but is unset"
env -u QODO_API_KEY ./upload-rules.sh "$BASE" rule.json NOT_A_REAL_VAR -q
check "falls back to literal" 0 $?

banner "T6  no token anywhere"
env -u QODO_API_KEY HOME=/tmp/qartest ./upload-rules.sh "$BASE" rule.json
check "usage error" 1 $?

banner "T7  401 from server"
env -u QODO_API_KEY ./upload-rules.sh "$BASE" rule.json bad-token
check "auth failure" 2 $?

banner "T8  403 from server"
env -u QODO_API_KEY ./upload-rules.sh "$BASE" rule.json no-perms
check "forbidden" 2 $?

banner "T9  validation - missing + bad fields, nothing uploaded"
cat > /tmp/qartest/bad.json <<'EOF'
[
  {"name": "ok but no severity", "category": "Quality", "content": "x", "goodExamples": "", "badExamples": ""},
  {"name": "bad sev", "category": "Quality", "severity": "critical", "content": "x", "goodExamples": "", "badExamples": ""},
  {"name": "", "category": "  ", "severity": "error", "content": "x", "goodExamples": "", "badExamples": ""},
  {"name": "no examples", "category": "Quality", "severity": "error", "content": "x"},
  {"name": "wrong types", "category": 5, "severity": "error", "content": "x", "goodExamples": [], "badExamples": ""},
  "not an object",
  {"name": "bad scopes", "category": "Quality", "severity": "error", "content": "x", "goodExamples": "", "badExamples": "", "scopes": "   "}
]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/bad.json
check "blocked before upload" 1 $?

banner "T10 name over 128 chars"
python3 -c "
import json
print(json.dumps([{'name':'x'*129,'category':'Quality','severity':'error','content':'c','goodExamples':'','badExamples':''}]))" > /tmp/qartest/long.json
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/long.json
check "name length rejected" 1 $?

banner "T11 snake_case aliases + uppercase severity + stdin + scopes"
cat > /tmp/qartest/snake.json <<'EOF'
[
  {"name": "Snake alias rule", "category": "Quality", "severity": "WARNING",
   "content": "Aliases and case are normalised.",
   "good_examples": "good()", "bad_examples": "bad()",
   "scopes": ["  /owner/repo/  ", "/owner/repo/src/"]},
  {"name": "Empty scope rule", "category": "Quality", "severity": "error",
   "content": "An empty list is the universal scope, same as omitting the key.",
   "goodExamples": "", "badExamples": "", "scopes": []}
]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" - < /tmp/qartest/snake.json
check "aliases normalised" 0 $?

banner "T12 non-contract fields are dropped, with a note"
cat > /tmp/qartest/extra.json <<'EOF'
[{"name": "Extra field rule", "category": "Quality", "severity": "error",
  "content": "c", "goodExamples": "", "badExamples": "",
  "state": "active", "ruleId": 7, "notes": "should be dropped"}]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/extra.json
check "extras dropped, 201" 0 $?

banner "T13 duplicate names inside one file"
cat > /tmp/qartest/dupe.json <<'EOF'
[{"name": "Dupe me", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""},
 {"name": "Dupe me", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""}]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/dupe.json
check "warned, second 409s" 0 $?

banner "T14 500 with retries, then --keep-going"
cat > /tmp/qartest/boom.json <<'EOF'
[{"name": "__boom__", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""},
 {"name": "After the boom", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""}]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/boom.json --keep-going --retries 1
check "5xx retried then failed" 2 $?

banner "T15 malformed JSON / empty array / not an array"
echo '{not json' > /tmp/qartest/broken.json
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/broken.json 2>&1 | head -3
check "invalid json" 1 "${PIPESTATUS[0]}"
echo '[]' > /tmp/qartest/empty.json
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/empty.json
check "empty array" 1 $?
echo '{"name":"obj"}' > /tmp/qartest/obj.json
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/obj.json
check "top-level object" 1 $?

banner "T16 usage errors"
./upload-rules.sh > /dev/null 2>&1;                     check "no args" 1 $?
./upload-rules.sh "$BASE" > /dev/null 2>&1;             check "one arg" 1 $?
./upload-rules.sh ftp://x f.json t > /dev/null 2>&1;    check "bad scheme" 1 $?
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" nope.json > /dev/null 2>&1; check "missing file" 1 $?
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" a.json b c > /dev/null 2>&1; check "4 positionals" 1 $?
./upload-rules.sh "$BASE" a.json --bogus > /dev/null 2>&1; check "unknown option" 1 $?
./upload-rules.sh --help > /dev/null 2>&1;              check "help" 0 $?

banner "T17 endpoint construction"
WANTPATH="/rules/v1/rule"
WANT="$HOST$WANTPATH"
endpoint_of() {
  QODO_API_KEY=sk-x ./upload-rules.sh "$@" --dry-run 2>&1 | sed -n 's/^endpoint  *//p'
}
check_eq "bare platform host"             "$WANT" "$(endpoint_of "$HOST" rule.json)"
check_eq "trailing slash tolerated"       "$WANT" "$(endpoint_of "$HOST/" rule.json)"
check_eq "base already has /rules"        "$WANT" "$(endpoint_of "$HOST/rules" rule.json)"
check_eq "base already has /rules/v1"     "$WANT" "$(endpoint_of "$HOST/rules/v1" rule.json)"
check_eq "full endpoint URL, not doubled" "$WANT" "$(endpoint_of "$WANT" rule.json)"
check_eq "--path '' posts base verbatim"  "$WANT" "$(endpoint_of "$WANT" rule.json --path '')"
check_eq "--path /rule onto /rules/v1"    "$WANT" "$(endpoint_of "$HOST/rules/v1" rule.json --path /rule)"
check_eq "--path= normalises slashes"     "$WANT" "$(endpoint_of "$HOST" rule.json --path=rules/v1/rule/)"
# A base ending in "-rules" must not be mistaken for one ending in "/rules".
check_eq "overlap is segment-aligned"     "$HOST/qodo-rules$WANTPATH" \
                                           "$(endpoint_of "$HOST/qodo-rules" rule.json)"
QODO_API_KEY=sk-x ./upload-rules.sh "$HOST" rule.json --path > /dev/null 2>&1
check "--path with no value" 1 $?

banner "T18 an overlapping base URL actually reaches the server"
QODO_API_KEY=sk-path-probe ./upload-rules.sh "$HOST/rules/v1" rule.json -q
check "base carrying /rules/v1 uploads" 0 $?

banner "T19 token never appears in the process list"
QODO_API_KEY=sk-super-secret-value ./upload-rules.sh "$BASE" rule.json -q > /dev/null 2>&1 &
UP=$!
LEAK=0
for _ in $(seq 1 25); do
  if ps -Ao args 2>/dev/null | grep -v grep | grep -q 'sk-super-secret-value'; then LEAK=1; break; fi
  sleep 0.05
done
wait $UP 2>/dev/null
check "token absent from argv" 0 "$LEAK"

banner "T20 armed server matches every POST against $FIXTURE"
# The server holds the same file the script reads, so it can answer 422 with a
# field-level diff the moment a body stops matching its fixture entry.
QODO_API_KEY=sk-fixture-run ./upload-rules.sh "$FIXTURE_BASE" "$FIXTURE" -q
check "fixture uploaded" 0 $?
curl -s "$FIXTURE_HOST/__verify__" > /tmp/qartest/verify.json
python3 - <<'PY'
import json
v = json.load(open("/tmp/qartest/verify.json"))
print(f"  {v['matched']}/{v['expected']} POSTs matched {v['fixture']} verbatim"
      f" ({v['received']} received, bearer on every request: {v['bearerOnEveryRequest']})")
for m in v["mismatches"]:
    print(f"  FAIL: request {m['request']} ({m['name']!r}) did not match its fixture entry:")
    for p in m["problems"]:
        print(f"    - {p}")
for a in v["authFailures"]:
    print(f"  FAIL: request {a['request']} rejected {a['status']}: {a['reason']}")
raise SystemExit(0 if v["ok"] else 1)
PY
check "every POST matched the fixture" 0 $?

banner "T21 a collision lookup that never recovers stops after --retries"
# The lookup's retry budget is spent by attempts, not by the number of the page
# being fetched: a page number does not move while the same request is retried,
# so counting it retries an early page forever and leaves a late page none.
# Only a 409 reaches the lookup, so each rule has to be created first.
cat > /tmp/qartest/wedged429.json <<'EOF'
[{"name": "__lookup_429__", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""}]
EOF
cat > /tmp/qartest/wedged5xx.json <<'EOF'
[{"name": "__lookup_5xx__", "category": "Quality", "severity": "error", "content": "c", "goodExamples": "", "badExamples": ""}]
EOF
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/wedged429.json -q
check "429-lookup rule created" 0 $?
QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" /tmp/qartest/wedged5xx.json -q
check "5xx-lookup rule created" 0 $?

# Re-uploading collides, and the lookup that resolves the collision never
# answers 200. Both runs must end on their own; a deadline catches the loop.
run_bounded 30 env QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" \
  /tmp/qartest/wedged429.json --retries 2 > /tmp/qartest/wedged429.out 2>&1
check "persistent 429 lookup gave up" 2 $?
run_bounded 30 env QODO_API_KEY=sk-x ./upload-rules.sh "$BASE" \
  /tmp/qartest/wedged5xx.json --retries 1 > /tmp/qartest/wedged5xx.out 2>&1
check "persistent 5xx lookup gave up" 2 $?

# Giving up is only half of it: the status it gave up on has to reach the
# report, or the operator is told the id did not resolve and not why.
grep -q 'lookup returned HTTP 429' /tmp/qartest/wedged429.out
check "429 named in the failure report" 0 $?
grep -q 'lookup returned HTTP 503' /tmp/qartest/wedged5xx.out
check "503 named in the failure report" 0 $?

curl -s "$HOST/__lookuplog__" > /tmp/qartest/lookups.json
python3 - <<'PY'
import json
log = json.load(open("/tmp/qartest/lookups.json"))
errs = []
for needle, retries in (("__lookup_429__", 2), ("__lookup_5xx__", 1)):
    hits = [e for e in log if e["needle"] == needle]
    if len(hits) != retries + 1:
        errs.append(f"{needle}: {len(hits)} lookup(s), expected {retries + 1}"
                    f" (1 attempt + --retries {retries})")
    pages = sorted({e["page"] for e in hits})
    if pages not in ([1], []):
        errs.append(f"{needle}: retries walked off page 1, saw pages {pages}")

# The successful lookups the earlier collision cases drove must still be here,
# or this case proved nothing about the wedged ones.
if not [e for e in log if e["status"] == 200]:
    errs.append("no lookup ever succeeded; the 409 upsert path never ran")

print(f"  {len(log)} lookups recorded")
if errs:
    for e in errs: print("  FAIL:", e)
    raise SystemExit(1)
print("  PASS: each wedged lookup stopped after exactly --retries retries")
PY
check "lookup retried exactly --retries times" 0 $?

banner "T22 rule.schema.json reaches the same verdict as the script"
# The schema is checked against the script rather than against a second copy of
# the rules: every file the cases above uploaded must validate, and every file
# they rejected must fail. The fixtures are still in /tmp/qartest at this point.
python3 tests/check-schema.py --schema rule.schema.json \
  --valid rule.json "$FIXTURE" /tmp/qartest/snake.json /tmp/qartest/extra.json \
          /tmp/qartest/dupe.json /tmp/qartest/boom.json \
          /tmp/qartest/wedged429.json /tmp/qartest/wedged5xx.json \
  --invalid /tmp/qartest/bad.json /tmp/qartest/long.json /tmp/qartest/broken.json \
            /tmp/qartest/empty.json /tmp/qartest/obj.json
SCHEMA_RC=$?
if [ "$SCHEMA_RC" -eq 77 ]; then
  echo "  SKIP: schema check needs the python3 jsonschema package"
else
  check "schema agrees with the script on every fixture" 0 "$SCHEMA_RC"
fi

banner "SERVER-SIDE ASSERTIONS"
curl -s "$HOST/__log__" > /tmp/qartest/log.json
python3 - <<'PY'
import json
log = json.load(open("/tmp/qartest/log.json"))
req = ["name","category","severity","content","goodExamples","badExamples"]
allowed = set(req) | {"scopes"}
errs = []
if not log: errs.append("no requests recorded")
for i, e in enumerate(log):
    b = e["body"]
    if e["content_type"] != "application/json": errs.append(f"[{i}] content-type {e['content_type']}")
    if e["accept"] != "application/json": errs.append(f"[{i}] accept {e['accept']}")
    miss = [f for f in req if f not in b]
    if miss: errs.append(f"[{i}] missing {miss}")
    extra = set(b) - allowed
    if extra: errs.append(f"[{i}] extra {sorted(extra)}")
    if b.get("severity") not in {"error","warning","recommendation"}:
        errs.append(f"[{i}] severity {b.get('severity')!r}")

named = [e for e in log if e["token"] == "sk-named-var"]
if not named: errs.append("named-var token never used")
elif any(e["workspace"] != "ws-abc" for e in named): errs.append("workspace header not sent for -w run")
if not any(e["token"] == "sk-literal-token-123" for e in log): errs.append("literal token never used")
if not any(e["token"] == "NOT_A_REAL_VAR" for e in log): errs.append("unset var name not used as literal")

default = [e for e in log if e["token"] == "sk-default-var"]
if not default: errs.append("default var token never used")
elif any(e["workspace"] is not None for e in default): errs.append("workspace header sent when unset")

snake = [e for e in log if e["body"]["name"] == "Snake alias rule"]
if not snake: errs.append("snake_case rule never sent")
else:
    b = snake[0]["body"]
    if b["goodExamples"] != "good()": errs.append(f"alias not mapped: {b}")
    if b["severity"] != "warning": errs.append(f"severity not lowercased: {b['severity']!r}")
    if b["scopes"] != ["/owner/repo/", "/owner/repo/src/"]: errs.append(f"scopes not trimmed: {b['scopes']}")

extra_rule = [e for e in log if e["body"]["name"] == "Extra field rule"]
if not extra_rule: errs.append("extra-field rule never sent")
elif set(extra_rule[0]["body"]) - allowed: errs.append("non-contract fields leaked to the server")

# "scopes": [] is the universal scope spelled out, so it has to reach the server
# as the body an omitted key produces, not as an empty list.
empty_scope = [e for e in log if e["body"]["name"] == "Empty scope rule"]
if not empty_scope: errs.append("empty-scopes rule never sent")
elif "scopes" in empty_scope[0]["body"]: errs.append("empty scopes list sent instead of dropped")

# rule.json omits scopes, so the key must be absent; names read from the file so a rename cannot void this.
with open("rule.json") as fh:
    rule_json_names = {r["name"] for r in json.load(fh)}
from_rule_json = [e for e in log if e["body"]["name"] in rule_json_names]
if not from_rule_json: errs.append("rule.json rules never sent")
elif any("scopes" in e["body"] for e in from_rule_json):
    errs.append("scopes key sent for a rule that omits it")

print(f"  {len(log)} requests recorded")
if errs:
    for e in errs: print("  FAIL:", e)
    raise SystemExit(1)
print("  PASS: every request matched the wire contract")
PY
check "server-side contract" 0 $?

echo
echo "================================================"
echo "  PASSED: $PASS   FAILED: $FAIL"
echo "================================================"
[ "$FAIL" -eq 0 ]
