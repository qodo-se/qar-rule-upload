#!/usr/bin/env bash
#
# upload-rules.sh - bulk-create Qodo rules from a JSON array.
#
# Each object in the input array becomes one POST to {base-url}/rules/v1/rule.
# Only the part of that route the base URL is not already carrying is appended,
# so the platform base URL and the full endpoint URL both work.
#
# The whole file is validated before the first request, so a malformed entry
# never leaves a half-uploaded set behind.
#
# Usage:
#   ./upload-rules.sh <base-url> <rule.json>                        # token from $QODO_API_KEY
#   ./upload-rules.sh <base-url> <rule.json> <env-var-name|token>   # named variable, or literal
#
# Written for bash 3.2 (the macOS system bash).

set -euo pipefail

readonly DEFAULT_RULE_PATH="/rules/v1/rule"
readonly NAME_MAX_LENGTH=128
readonly MAX_SCOPES=25
readonly DEFAULT_TOKEN_VAR="QODO_API_KEY"
readonly AUTH_KEY_FILE="${HOME}/.qodo/auth.key"

PROG="$(basename "$0")"

# ---------------------------------------------------------------- output ---

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi

info() { printf '%s\n' "$*" >&2; }
warn() { printf '%s%s%s\n' "$C_YELLOW" "$*" "$C_OFF" >&2; }
ok()   { printf '%s%s%s\n' "$C_GREEN" "$*" "$C_OFF" >&2; }
err()  { printf '%s%s%s\n' "$C_RED" "$*" "$C_OFF" >&2; }
die()  { err "$PROG: $*"; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}$PROG${C_OFF} - bulk-create Qodo rules from a JSON array.

${C_BOLD}USAGE${C_OFF}
  $PROG <base-url> <rule.json> [token-source] [options]

${C_BOLD}ARGUMENTS${C_OFF}
  base-url      Qodo platform base URL, e.g. https://qodo-platform.qodo.ai
                Only the missing part of '$DEFAULT_RULE_PATH' is appended, so a base
                URL that already carries some of that route (or all of it) lands
                on the same endpoint. Use --path for a different route, or
                --path '' to post to base-url verbatim.
  rule.json     Path to a JSON array; each object is one POST body. Use "-" for stdin.
  token-source  Optional 3rd argument. Either:
                  - the NAME of an environment variable holding the token
                    (e.g. MY_QODO_TOKEN), or
                  - the token itself (e.g. sk-... / qodo-svc-...).
                A value that matches a set, non-empty variable is read from that
                variable; anything else is used as a literal token.
                Omit it to fall back to \$$DEFAULT_TOKEN_VAR, then $AUTH_KEY_FILE.

${C_BOLD}OPTIONS${C_OFF}
  -w, --workspace-id ID   Send the 'qodo-workspace-id' header (default: \$QODO_WORKSPACE_ID).
                          Needed for service keys (qodo-svc-...); user keys (sk-...)
                          carry the workspace in the token itself.
  -n, --dry-run           Validate and print the payloads; send nothing.
  -k, --keep-going        Keep uploading after a rule fails (default: stop).
      --path PATH         Path appended to base-url (default: '$DEFAULT_RULE_PATH').
                          Pass --path '' when base-url is the full endpoint URL.
      --retries N         Retry attempts for 429 / 5xx responses (default: 2).
      --timeout SECONDS   Per-request timeout (default: 30).
      --insecure          Skip TLS verification (self-signed dev endpoints).
  -q, --quiet             Only report failures and the final summary.
  -h, --help              Show this help.

${C_BOLD}RULE OBJECT${C_OFF} - mandatory fields only; snake_case aliases accepted
  name          string, non-empty, <= $NAME_MAX_LENGTH chars, unique in the workspace
  category      string, e.g. Security | Correctness | Quality | Reliability |
                Performance | Testability | Compliance | Accessibility |
                Observability | Architecture
  severity      "error" | "warning" | "recommendation"   (case-insensitive)
  content       string, non-empty - what the rule enforces
  goodExamples  string, may be "" but the key must be present  (alias: good_examples)
  badExamples   string, may be "" but the key must be present  (alias: bad_examples)
  scopes        OPTIONAL string[], max $MAX_SCOPES paths like "/owner/repo/";
                omit for the universal scope "/"

${C_BOLD}EXAMPLES${C_OFF}
  # 2 arguments - token from \$$DEFAULT_TOKEN_VAR
  export $DEFAULT_TOKEN_VAR=sk-...
  $PROG https://qodo-platform.qodo.ai rule.json

  # 3 arguments - token read from a differently named variable
  export MY_QODO_TOKEN=sk-...
  $PROG https://qodo-platform.qodo.ai rule.json MY_QODO_TOKEN

  # 3 arguments - token passed literally
  $PROG https://qodo-platform.qodo.ai rule.json sk-live-abc123 -w 0000-...-00ff

  # the full endpoint URL - nothing is appended twice
  $PROG https://qodo-platform.qodo.ai$DEFAULT_RULE_PATH rule.json

  # validate without sending
  $PROG https://qodo-platform.qodo.ai rule.json --dry-run

${C_BOLD}EXIT CODES${C_OFF}
  0  all rules created (or already existed)
  1  usage or validation error - nothing was uploaded
  2  one or more uploads failed
EOF
}

# ------------------------------------------------------------ jq programs ---

# Shared prelude: canonicalise a rule to the camelCase wire shape the platform
# expects. Unknown keys are dropped here, so only contract fields are sent.
read -r -d '' JQ_LIB <<'JQEOF' || true
def loc($i): "rules[\($i)]";

def trim: if type == "string" then gsub("^\\s+|\\s+$"; "") else . end;

def isblank: (type != "string") or (trim == "");

def alias($camel; $snake):
  if has($camel) then {($camel): .[$camel]}
  elif has($snake) then {($camel): .[$snake]}
  else {} end;

def keep($f): if has($f) then {($f): .[$f]} else {} end;

# Severity is a closed lowercase enum upstream, so "Error" from a hand-written
# file is normalised rather than bounced.
def canon:
  keep("name")
  + keep("category")
  + (if has("severity") and (.severity | type) == "string"
     then {severity: (.severity | ascii_downcase | trim)}
     else keep("severity") end)
  + keep("content")
  + alias("goodExamples"; "good_examples")
  + alias("badExamples"; "bad_examples")
  + keep("scopes");

# A bare string scope is wrapped into a list, mirroring the platform client.
def wire:
  canon
  | {name, category, severity, content, goodExamples, badExamples}
  + (if has("scopes")
     then {scopes: ((if (.scopes | type) == "string" then [.scopes] else .scopes end)
                    | map(trim) | map(select(. != "")))}
     else {} end);
JQEOF

# Blocking problems: one per line, silence means the file is good.
read -r -d '' JQ_ERRORS <<'JQEOF' || true
def required($i; $f):
  if has($f) | not then ["\(loc($i)): missing required field \"\($f)\""]
  elif (.[$f] | type) != "string" then ["\(loc($i)): \"\($f)\" must be a string, got \(.[$f] | type)"]
  elif (.[$f] | isblank) then ["\(loc($i)): \"\($f)\" must be a non-empty string"]
  else [] end;

# The platform requires the example keys to be present, but tolerates "".
def required_allow_empty($i; $f):
  if has($f) | not then ["\(loc($i)): missing required field \"\($f)\" (may be \"\", but the key must be present)"]
  elif (.[$f] | type) != "string" then ["\(loc($i)): \"\($f)\" must be a string, got \(.[$f] | type)"]
  else [] end;

def check_name($i):
  required($i; "name")
  + (if (.name | type) == "string" and (.name | length) > $name_max
     then ["\(loc($i)): \"name\" must be at most \($name_max) characters, got \(.name | length)"]
     else [] end);

def check_severity($i):
  required($i; "severity")
  + (.severity as $sev
     | if ($sev | type) == "string" and ($sev | isblank | not)
          and (($severities | index($sev)) == null)
       then ["\(loc($i)): \"severity\" must be one of \($severities | join(", ")) - got \($sev | tojson)"]
       else [] end);

def check_scopes($i):
  if has("scopes") | not then []
  elif (.scopes | type) == "string" then
    (if (.scopes | isblank)
     then ["\(loc($i)): \"scopes\" entries must be non-empty strings"] else [] end)
  elif (.scopes | type) != "array" then
    ["\(loc($i)): \"scopes\" must be an array of strings, got \(.scopes | type)"]
  elif ([.scopes[] | select(type != "string")] | length) > 0 then
    ["\(loc($i)): \"scopes\" must contain only strings"]
  elif (.scopes | length) > $max_scopes then
    ["\(loc($i)): \"scopes\" must contain at most \($max_scopes) paths, got \(.scopes | length)"]
  elif (.scopes | length) > 0 and ([.scopes[] | select(isblank | not)] | length) == 0 then
    ["\(loc($i)): \"scopes\" entries must be non-empty; use [] for the universal scope \"/\""]
  else [] end;

def check_rule($i):
  if type != "object" then ["\(loc($i)): must be a JSON object, got \(type)"]
  else
    canon
    | check_name($i)
      + required($i; "category")
      + check_severity($i)
      + required($i; "content")
      + required_allow_empty($i; "goodExamples")
      + required_allow_empty($i; "badExamples")
      + check_scopes($i)
  end;

if type != "array" then
  ["input: the top-level JSON must be an array of rule objects, got \(type)"]
elif length == 0 then
  ["input: the rules array is empty"]
else
  [to_entries[] | .key as $i | .value | check_rule($i)] | add
end
| .[]
JQEOF

# Non-blocking notes: things worth saying that should not stop an upload.
read -r -d '' JQ_WARNINGS <<'JQEOF' || true
if type != "array" then empty
else
  ( to_entries[]
    | .key as $i
    | select(.value | type == "object")
    | .value
    | ([keys_unsorted[]] - $known) as $extra
    | select($extra | length > 0)
    | "\(loc($i)): ignoring non-contract field(s) \($extra | join(", "))" ),
  ( [ .[] | select(type == "object") | .name | select(type == "string") ]
    | group_by(.) | map(select(length > 1) | .[0])[]
    | "input: \(tojson) appears more than once; the duplicate will come back as HTTP 409" )
end
JQEOF

# ------------------------------------------------------------ arg parsing ---

BASE_URL=""
RULES_FILE=""
TOKEN_SOURCE=""
POSITIONAL_COUNT=0

WORKSPACE_ID="${QODO_WORKSPACE_ID:-}"
RULE_PATH="$DEFAULT_RULE_PATH"
DRY_RUN=0
KEEP_GOING=0
RETRIES=2
TIMEOUT=30
INSECURE=0
QUIET=0

add_positional() {
  POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
  case "$POSITIONAL_COUNT" in
    1) BASE_URL="$1" ;;
    2) RULES_FILE="$1" ;;
    3) TOKEN_SOURCE="$1" ;;
    *) die "too many arguments: expected 2 or 3, got $POSITIONAL_COUNT (try --help)" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -k|--keep-going) KEEP_GOING=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -w|--workspace-id)
      [ $# -ge 2 ] || die "$1 requires a value"
      WORKSPACE_ID="$2"; shift 2 ;;
    --workspace-id=*) WORKSPACE_ID="${1#*=}"; shift ;;
    --path)
      [ $# -ge 2 ] || die "$1 requires a value (use --path '' to append nothing)"
      RULE_PATH="$2"; shift 2 ;;
    --path=*) RULE_PATH="${1#*=}"; shift ;;
    --retries)
      [ $# -ge 2 ] || die "$1 requires a value"
      RETRIES="$2"; shift 2 ;;
    --retries=*) RETRIES="${1#*=}"; shift ;;
    --timeout)
      [ $# -ge 2 ] || die "$1 requires a value"
      TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --) shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -) add_positional "$1"; shift ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *) add_positional "$1"; shift ;;
  esac
done

if [ "$POSITIONAL_COUNT" -lt 2 ]; then
  usage >&2
  info ""
  die "expected at least 2 arguments (base-url and rules.json), got $POSITIONAL_COUNT"
fi

case "$RETRIES" in ''|*[!0-9]*) die "--retries must be a non-negative integer, got '$RETRIES'" ;; esac
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;; esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be greater than 0"

command -v jq >/dev/null 2>&1 || die "jq is required but not installed (brew install jq)"
command -v curl >/dev/null 2>&1 || die "curl is required but not installed"

# -------------------------------------------------------------- endpoint ---

case "$BASE_URL" in
  http://*|https://*) ;;
  *) die "base-url must start with http:// or https://, got '$BASE_URL'" ;;
esac

BASE_URL="${BASE_URL%/}"
if [ -n "$RULE_PATH" ]; then
  case "$RULE_PATH" in /*) ;; *) RULE_PATH="/$RULE_PATH" ;; esac
  RULE_PATH="${RULE_PATH%/}"
fi

# Append only the part of the route the base URL is not already carrying, so
# https://host, https://host/rules/v1 and the full endpoint URL all land on the
# same place. The overlap is matched on segment boundaries, so a base ending in
# /qodo-rules is not mistaken for one ending in /rules.
join_url() {
  local base="$1" path="$2" candidate="$2"
  while [ -n "$candidate" ]; do
    case "$base" in
      *"$candidate") printf '%s%s' "$base" "${path#"$candidate"}"; return 0 ;;
    esac
    candidate="${candidate%/*}"
  done
  printf '%s%s' "$base" "$path"
}

if [ -z "$RULE_PATH" ]; then
  ENDPOINT="$BASE_URL"
else
  ENDPOINT="$(join_url "$BASE_URL" "$RULE_PATH")"
fi

# ----------------------------------------------------------------- token ---

TOKEN=""
TOKEN_ORIGIN=""

# Shell globs are not regexes: "[A-Za-z_][A-Za-z0-9_]*" would also match
# "sk-abc-123", so the character set is tested by exclusion instead. Indirect
# expansion on a non-identifier is a hard bash error, not a miss.
is_identifier() {
  case "$1" in
    ''|[0-9]*|*[!A-Za-z0-9_]*) return 1 ;;
    *) return 0 ;;
  esac
}

resolve_token() {
  if [ -n "$TOKEN_SOURCE" ]; then
    # A 3rd argument naming a set, non-empty variable is an indirection;
    # anything else is the token itself.
    if is_identifier "$TOKEN_SOURCE" \
      && [ -n "${!TOKEN_SOURCE+x}" ] && [ -n "${!TOKEN_SOURCE}" ]; then
      TOKEN="${!TOKEN_SOURCE}"
      TOKEN_ORIGIN="\$$TOKEN_SOURCE"
      return 0
    fi
    TOKEN="$TOKEN_SOURCE"
    TOKEN_ORIGIN="the token argument"
    return 0
  fi

  if [ -n "${!DEFAULT_TOKEN_VAR+x}" ] && [ -n "${!DEFAULT_TOKEN_VAR}" ]; then
    TOKEN="${!DEFAULT_TOKEN_VAR}"
    TOKEN_ORIGIN="\$$DEFAULT_TOKEN_VAR"
    return 0
  fi

  if [ -r "$AUTH_KEY_FILE" ]; then
    TOKEN="$(tr -d '[:space:]' < "$AUTH_KEY_FILE")"
    if [ -n "$TOKEN" ]; then
      TOKEN_ORIGIN="$AUTH_KEY_FILE"
      return 0
    fi
  fi

  return 1
}

if resolve_token; then
  :
elif [ "$DRY_RUN" -eq 1 ]; then
  # A dry run sends nothing, so a missing token must not block validation.
  TOKEN=""
  TOKEN_ORIGIN="none (dry run)"
else
  die "no bearer token found. Set \$$DEFAULT_TOKEN_VAR, pass the token (or the name of the
    variable holding it) as the 3rd argument, or create $AUTH_KEY_FILE"
fi

# The token rides in a curl config file rather than argv, so it stays out of
# the process list; these characters would break that file's quoting.
case "$TOKEN" in
  *'"'*|*'\'*) die "the bearer token contains a quote or backslash and cannot be passed safely" ;;
  *[[:space:]]*) die "the bearer token contains whitespace - check the value you passed" ;;
esac

redact() {
  local t="$1"
  if [ "${#t}" -le 10 ]; then printf '***'; else printf '%s...%s' "${t:0:6}" "${t: -4}"; fi
}

# ------------------------------------------------------------ input file ---

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/qar-rule-upload.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT INT TERM

INPUT="$TMPDIR_RUN/rules.json"
SOURCE_LABEL="$RULES_FILE"
if [ "$RULES_FILE" = "-" ]; then
  SOURCE_LABEL="stdin"
  cat > "$INPUT"
else
  [ -e "$RULES_FILE" ] || die "rules file not found: $RULES_FILE"
  [ -r "$RULES_FILE" ] || die "rules file is not readable: $RULES_FILE"
  cat "$RULES_FILE" > "$INPUT"
fi

if ! jq empty "$INPUT" 2>"$TMPDIR_RUN/jqerr"; then
  err "$PROG: $SOURCE_LABEL is not valid JSON:"
  sed 's/^/  /' "$TMPDIR_RUN/jqerr" >&2
  exit 1
fi

# ------------------------------------------------------------- validation ---

SEVERITIES_JSON='["error","warning","recommendation"]'
KNOWN_JSON='["name","category","severity","content","goodExamples","badExamples","good_examples","bad_examples","scopes"]'

jq_validate() {
  jq -r \
    --argjson severities "$SEVERITIES_JSON" \
    --argjson known "$KNOWN_JSON" \
    --argjson name_max "$NAME_MAX_LENGTH" \
    --argjson max_scopes "$MAX_SCOPES" \
    "$JQ_LIB $1" "$INPUT"
}

PROBLEMS="$TMPDIR_RUN/problems.txt"
NOTES="$TMPDIR_RUN/notes.txt"
jq_validate "$JQ_ERRORS" > "$PROBLEMS"
jq_validate "$JQ_WARNINGS" > "$NOTES"

if [ -s "$PROBLEMS" ]; then
  count="$(wc -l < "$PROBLEMS" | tr -d ' ')"
  err "$PROG: $count problem(s) in $SOURCE_LABEL - nothing was uploaded:"
  sed 's/^/  - /' "$PROBLEMS" >&2
  exit 1
fi

if [ -s "$NOTES" ]; then
  while IFS= read -r note; do warn "note: $note"; done < "$NOTES"
  info ""
fi

TOTAL="$(jq -r 'length' "$INPUT")"

# ------------------------------------------------------------- curl setup ---

CURL_CFG="$TMPDIR_RUN/curl.cfg"
( umask 077; : > "$CURL_CFG" )
{
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
  printf 'header = "Content-Type: application/json"\n'
  printf 'header = "Accept: application/json"\n'
  # Omitted rather than sent empty: user keys carry the workspace in the token
  # claims, and only service keys need this header.
  if [ -n "$WORKSPACE_ID" ]; then
    printf 'header = "qodo-workspace-id: %s"\n' "$WORKSPACE_ID"
  fi
  printf 'silent\nshow-error\n'
  printf 'max-time = %s\n' "$TIMEOUT"
  if [ "$INSECURE" -eq 1 ]; then printf 'insecure\n'; fi
} >> "$CURL_CFG"

# ----------------------------------------------------------------- banner ---

info "${C_BOLD}endpoint${C_OFF}  $ENDPOINT"
info "${C_BOLD}rules${C_OFF}     $TOTAL from $SOURCE_LABEL"
if [ "$DRY_RUN" -eq 1 ]; then
  info "${C_BOLD}mode${C_OFF}      ${C_YELLOW}dry run - no requests will be sent${C_OFF}"
else
  info "${C_BOLD}token${C_OFF}     $(redact "$TOKEN") ${C_DIM}(from $TOKEN_ORIGIN)${C_OFF}"
  if [ -n "$WORKSPACE_ID" ]; then
    info "${C_BOLD}workspace${C_OFF} $WORKSPACE_ID"
  else
    info "${C_BOLD}workspace${C_OFF} ${C_DIM}header not sent - resolved from the token${C_OFF}"
  fi
fi
info ""

# ------------------------------------------------------------------ upload ---

HEADERS="$TMPDIR_RUN/headers.txt"
BODY="$TMPDIR_RUN/body.json"
CURL_ERR="$TMPDIR_RUN/curlerr.txt"

post_rule() {
  # post_rule <payload-file>; echoes the HTTP status, 000 when unreachable.
  curl -K "$CURL_CFG" \
    -X POST "$ENDPOINT" \
    --data-binary "@$1" \
    -D "$HEADERS" \
    -o "$BODY" \
    -w '%{http_code}' \
    < /dev/null 2>"$CURL_ERR" || true
}

server_detail() {
  # FastAPI puts the reason in .detail; fall back to a trimmed raw body.
  local detail
  detail="$(jq -r '
      if type == "object" then
        (.detail // .message // .error // empty)
        | if type == "array" then map(.msg // tostring) | join("; ")
          elif type == "object" then tojson
          else tostring end
      else empty end' "$BODY" 2>/dev/null || true)"
  if [ -z "$detail" ]; then
    detail="$(tr -d '\r\n' < "$BODY" | cut -c1-200)"
  fi
  printf '%s' "$detail"
}

transport_detail() {
  tr -d '\r' < "$CURL_ERR" | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//'
}

retry_delay() {
  # Honour Retry-After when the server sends one, else back off linearly.
  local attempt="$1" hinted
  hinted="$(tr 'A-Z' 'a-z' < "$HEADERS" 2>/dev/null \
    | sed -n 's/^retry-after:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)"
  if [ -n "$hinted" ] && [ "$hinted" -gt 0 ] 2>/dev/null; then
    printf '%s' "$hinted"
  else
    printf '%s' $((attempt * 2))
  fi
}

CREATED=0
EXISTED=0
FAILED=0
FAILED_NAMES=""

record_failure() {
  FAILED=$((FAILED + 1))
  FAILED_NAMES="$FAILED_NAMES
  - $1 ($2)"
}

PAYLOAD="$TMPDIR_RUN/payload.json"
idx=0
while [ "$idx" -lt "$TOTAL" ]; do
  jq -c --argjson n "$idx" "$JQ_LIB .[\$n] | wire" "$INPUT" > "$PAYLOAD"
  rule_name="$(jq -r '.name' "$PAYLOAD")"
  idx=$((idx + 1))
  label="$(printf '[%d/%d] %s' "$idx" "$TOTAL" "$rule_name")"

  if [ "$DRY_RUN" -eq 1 ]; then
    info "$label"
    jq . "$PAYLOAD" | sed "s/^/${C_DIM}  /;s/\$/${C_OFF}/" >&2
    CREATED=$((CREATED + 1))
    continue
  fi

  attempt=0
  while : ; do
    attempt=$((attempt + 1))
    status="$(post_rule "$PAYLOAD")"

    if [ -z "$status" ] || [ "$status" = "000" ]; then
      detail="$(transport_detail)"
      if [ "$attempt" -le "$RETRIES" ]; then
        warn "$label - no response ($detail); retrying in $((attempt * 2))s"
        sleep $((attempt * 2))
        continue
      fi
      err "$label - unreachable: $detail"
      record_failure "$rule_name" "no response"
      break
    fi

    case "$status" in
      201)
        rule_id="$(jq -r '.ruleId // empty' "$BODY" 2>/dev/null || true)"
        if [ "$QUIET" -eq 0 ]; then
          ok "$label - created${rule_id:+ (ruleId $rule_id)}"
        fi
        CREATED=$((CREATED + 1))
        break ;;
      409)
        warn "$label - already exists, skipped"
        EXISTED=$((EXISTED + 1))
        break ;;
      429|5??)
        if [ "$attempt" -le "$RETRIES" ]; then
          wait_s="$(retry_delay "$attempt")"
          warn "$label - HTTP $status; retrying in ${wait_s}s (attempt $attempt of $RETRIES)"
          sleep "$wait_s"
          continue
        fi
        err "$label - HTTP $status: $(server_detail)"
        record_failure "$rule_name" "HTTP $status"
        break ;;
      401)
        err "$label - HTTP 401: $(server_detail)"
        err "  the bearer token was rejected - check the value from $TOKEN_ORIGIN"
        record_failure "$rule_name" "HTTP 401"
        # Auth failures repeat for every rule, so stop regardless of --keep-going.
        break 2 ;;
      403)
        err "$label - HTTP 403: $(server_detail)"
        if [ -n "$WORKSPACE_ID" ]; then
          err "  the token has no write access to workspace $WORKSPACE_ID"
        else
          err "  no workspace access; a service key (qodo-svc-...) also needs --workspace-id"
        fi
        record_failure "$rule_name" "HTTP 403"
        break 2 ;;
      400|422)
        err "$label - HTTP $status: $(server_detail)"
        record_failure "$rule_name" "HTTP $status"
        break ;;
      *)
        err "$label - HTTP $status: $(server_detail)"
        record_failure "$rule_name" "HTTP $status"
        break ;;
    esac
  done

  if [ "$FAILED" -gt 0 ] && [ "$KEEP_GOING" -eq 0 ]; then
    err ""
    err "$PROG: stopping after the first failure (pass --keep-going to continue)"
    break
  fi
done

# ----------------------------------------------------------------- report ---

info ""
if [ "$DRY_RUN" -eq 1 ]; then
  ok "dry run: $CREATED rule(s) validated, nothing sent"
  exit 0
fi

SKIPPED=$((TOTAL - CREATED - EXISTED - FAILED))
summary="created $CREATED"
if [ "$EXISTED" -gt 0 ]; then summary="$summary, already existed $EXISTED"; fi
if [ "$FAILED" -gt 0 ]; then summary="$summary, failed $FAILED"; fi
if [ "$SKIPPED" -gt 0 ]; then summary="$summary, not attempted $SKIPPED"; fi

if [ "$FAILED" -eq 0 ]; then
  ok "done: $summary (of $TOTAL)"
  exit 0
fi

err "done: $summary (of $TOTAL)"
err "failed rules:$FAILED_NAMES"
exit 2
