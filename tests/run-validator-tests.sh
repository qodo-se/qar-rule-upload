#!/usr/bin/env bash
# Harness for endpoint-validator.sh: boots the mock, probes it, tears down.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

export NO_COLOR=1
PORT=8793
HOST="http://127.0.0.1:$PORT"
USERS="$HOST/platform/v2/users"

python3 tests/mock-server.py "$PORT" > /tmp/mock-validator.log 2>&1 &
MOCK_PID=$!
trap 'kill $MOCK_PID 2>/dev/null; rm -rf /tmp/qarvalid' EXIT
for _ in $(seq 1 40); do
  curl -sf -o /dev/null "$HOST/__log__" && break
  sleep 0.25
done

mkdir -p /tmp/qarvalid
PASS=0; FAIL=0
check() { # check <desc> <expected-exit> <actual-exit>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1 (exit $3)";
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (expected exit $2, got $3)"; fi
}
check_eq() { # check_eq <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  PASS: $1";
  else FAIL=$((FAIL+1)); echo "  FAIL: $1 (wanted '$2', got '$3')"; fi
}
banner() { echo; echo "=============== $* ==============="; }

banner "V1  bare host finds the users route"
QODO_API_KEY=sk-validator ./endpoint-validator.sh "$HOST" > /tmp/qarvalid/v1.txt 2>&1
check "found it" 0 $?
grep -q "found      $USERS" /tmp/qarvalid/v1.txt
check "printed the complete URL" 0 $?
grep -q "user@example.com" /tmp/qarvalid/v1.txt
check "printed the result" 0 $?
grep -q "upload with ./upload-rules.sh $HOST rule.json" /tmp/qarvalid/v1.txt
check "suggested the upload base" 0 $?

banner "V2  a deep URL is peeled back to the origin"
QODO_API_KEY=sk-deep ./endpoint-validator.sh "$HOST/rules/v1/rule" > /tmp/qarvalid/v2.txt 2>&1
check "still found it" 0 $?
grep -q "found      $USERS" /tmp/qarvalid/v2.txt
check "peeled back to the origin" 0 $?

banner "V3  every probe prints a full URL and a status"
QODO_API_KEY=sk-all ./endpoint-validator.sh "$HOST" --all > /tmp/qarvalid/v3.txt 2>&1
check "--all completes" 0 $?
python3 - <<'PY'
import re, sys
lines = open("/tmp/qarvalid/v3.txt").read().splitlines()
probes = [l for l in lines if re.match(r"^  \d{3}\s+[\d.]+s\s+https?://", l)]
errs = []
if len(probes) < 10:
    errs.append(f"expected a matrix of probes, saw {len(probes)}")
if not any(l.split()[0] == "200" for l in probes):
    errs.append("no 200 in the table")
if not any(l.split()[0] == "404" for l in probes):
    errs.append("no 404 in the table (the matrix is not exploring)")
seen = [l.split()[-1] for l in probes]
if len(seen) != len(set(seen)):
    errs.append("the same URL was probed twice")
for u in seen:
    if not u.startswith("http"):
        errs.append(f"not a complete URL: {u}")
print(f"  {len(probes)} URLs probed, {len(set(seen))} unique")
for e in errs: print("  FAIL:", e)
raise SystemExit(1 if errs else 0)
PY
check "table is a deduped full-URL matrix" 0 $?

banner "V4  --first stops early, --all does not"
FIRST_N=$(grep -cE "^  [0-9]{3} " /tmp/qarvalid/v1.txt)
ALL_N=$(grep -cE "^  [0-9]{3} " /tmp/qarvalid/v3.txt)
if [ "$ALL_N" -gt "$FIRST_N" ]; then
  PASS=$((PASS+1)); echo "  PASS: --all probed more ($ALL_N) than --first ($FIRST_N)"
else
  FAIL=$((FAIL+1)); echo "  FAIL: --all ($ALL_N) did not probe more than --first ($FIRST_N)"
fi

banner "V5  token handling matches upload-rules.sh"
export MY_VALIDATOR_TOKEN=sk-named-validator
env -u QODO_API_KEY ./endpoint-validator.sh "$HOST" MY_VALIDATOR_TOKEN > /dev/null 2>&1
check "named variable" 0 $?
env -u QODO_API_KEY ./endpoint-validator.sh "$HOST" sk-literal-validator > /dev/null 2>&1
check "literal token" 0 $?
env -u QODO_API_KEY ./endpoint-validator.sh "$HOST" UNSET_VALIDATOR_VAR > /dev/null 2>&1
check "unset name used literally" 0 $?
env -u QODO_API_KEY HOME=/tmp/qarvalid ./endpoint-validator.sh "$HOST" > /dev/null 2>&1
check "no token is a usage error" 1 $?

banner "V6  a rejected token is reported, not mistaken for a miss"
env -u QODO_API_KEY ./endpoint-validator.sh "$HOST" bad-token --all > /tmp/qarvalid/v6.txt 2>&1
check "no 200 anywhere" 2 $?
grep -q "401" /tmp/qarvalid/v6.txt
check "401 shown in the table" 0 $?
grep -q "Invalid authentication credentials" /tmp/qarvalid/v6.txt
check "server reason shown" 0 $?

banner "V7  an unreachable host fails cleanly"
QODO_API_KEY=sk-x ./endpoint-validator.sh http://127.0.0.1:9 --timeout 2 > /tmp/qarvalid/v7.txt 2>&1
check "reports no hit" 2 $?
grep -q "000" /tmp/qarvalid/v7.txt
check "000 shown for transport failure" 0 $?

banner "V8  --json is machine readable"
QODO_API_KEY=sk-json ./endpoint-validator.sh "$HOST" --json --all > /tmp/qarvalid/v8.json 2>/dev/null
check "json mode exits 0" 0 $?
python3 - <<'PY'
import json
rows = [json.loads(l) for l in open("/tmp/qarvalid/v8.json") if l.strip()]
errs = []
if not rows: errs.append("no json rows")
for r in rows:
    if set(r) != {"url", "status", "seconds", "detail"}: errs.append(f"unexpected keys {sorted(r)}")
    if not str(r["url"]).startswith("http"): errs.append(f"bad url {r['url']}")
if not any(r["status"] == 200 for r in rows): errs.append("no 200 row")
print(f"  {len(rows)} json rows")
for e in errs: print("  FAIL:", e)
raise SystemExit(1 if errs else 0)
PY
check "json rows well formed" 0 $?

banner "V9  --route overrides the defaults"
QODO_API_KEY=sk-route ./endpoint-validator.sh "$HOST" --route /rules/v1/metadata --all > /tmp/qarvalid/v9.txt 2>&1
check "custom route found" 0 $?
grep -q "found      $HOST/rules/v1/metadata" /tmp/qarvalid/v9.txt
check "reported the custom URL" 0 $?
grep -q "platform/v2/users" /tmp/qarvalid/v9.txt && DEFAULTS_STILL_THERE=0 || DEFAULTS_STILL_THERE=1
check_eq "default routes replaced" 1 "$DEFAULTS_STILL_THERE"

banner "V10 usage errors"
./endpoint-validator.sh > /dev/null 2>&1;                          check "no args" 1 $?
./endpoint-validator.sh ftp://x > /dev/null 2>&1;                  check "bad scheme" 1 $?
QODO_API_KEY=sk-x ./endpoint-validator.sh "$HOST" a b > /dev/null 2>&1; check "3 positionals" 1 $?
./endpoint-validator.sh "$HOST" --bogus > /dev/null 2>&1;          check "unknown option" 1 $?
QODO_API_KEY=sk-x ./endpoint-validator.sh "$HOST" --timeout 0 > /dev/null 2>&1; check "zero timeout" 1 $?
./endpoint-validator.sh --help > /dev/null 2>&1;                   check "help" 0 $?

banner "V11 the token stays out of the process list"
QODO_API_KEY=sk-validator-secret-value ./endpoint-validator.sh "$HOST" --all > /dev/null 2>&1 &
VP=$!
LEAK=0
for _ in $(seq 1 40); do
  if ps -Ao args 2>/dev/null | grep -v grep | grep -q 'sk-validator-secret-value'; then LEAK=1; break; fi
  sleep 0.05
done
wait $VP 2>/dev/null
check "token absent from argv" 0 "$LEAK"

banner "SERVER-SIDE ASSERTIONS"
python3 - <<'PY'
import json, urllib.request
hits = json.load(urllib.request.urlopen("http://127.0.0.1:8793/__userslog__"))
tokens = [h["token"] for h in hits]
errs = []
for want in ("sk-validator", "sk-deep", "sk-named-validator",
             "sk-literal-validator", "UNSET_VALIDATOR_VAR"):
    if want not in tokens:
        errs.append(f"{want} never reached the users endpoint")
if any(h["workspace"] is not None for h in hits):
    errs.append("workspace header sent when unset")
print(f"  {len(hits)} successful users GETs recorded")
for e in errs: print("  FAIL:", e)
raise SystemExit(1 if errs else 0)
PY
check "users endpoint saw the right bearers" 0 $?

echo
echo "================================================"
echo "  PASSED: $PASS   FAILED: $FAIL"
echo "================================================"
[ "$FAIL" -eq 0 ]
