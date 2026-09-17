#!/usr/bin/env bash
#
# endpoint-validator.sh - find where a Qodo deployment answers.
#
# qodo-platform publishes no unauthenticated health or ping route, so the
# cheapest thing that proves a base URL and a token together is the principal
# GET, /platform/v2/users: no query parameters, bearer only, and it returns the
# identity the token resolves to.
#
# Given one base URL this builds a matrix of plausible bases and users routes,
# GETs every combination, and prints the full URL and result for each - so when
# you do not know how a deployment is mounted, one run tells you.
#
# Usage:
#   ./endpoint-validator.sh <base-url>                        # token from $QODO_API_KEY
#   ./endpoint-validator.sh <base-url> <env-var-name|token>   # named variable, or literal
#
# Written for bash 3.2 (the macOS system bash).

set -euo pipefail

readonly DEFAULT_TOKEN_VAR="QODO_API_KEY"
readonly AUTH_KEY_FILE="${HOME}/.qodo/auth.key"

PROG="$(basename "$0")"

# Route suffixes that could serve the principal GET, most likely first.
DEFAULT_ROUTES="/platform/v2/users
/platform/v1/users
/v2/users
/v1/users
/users"

# Prefixes inserted between the host and the route, most likely first. An empty
# entry means the route hangs directly off the base URL.
DEFAULT_PREFIXES="
/api
/platform"

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
${C_BOLD}$PROG${C_OFF} - find where a Qodo deployment answers the principal GET.

${C_BOLD}USAGE${C_OFF}
  $PROG <base-url> [token-source] [options]

${C_BOLD}ARGUMENTS${C_OFF}
  base-url      Any URL for the deployment, e.g. https://qodo-platform.qodo.ai
                Route prefixes already in the URL are peeled back, so the full
                endpoint URL works as well as the bare host.
  token-source  Optional 2nd argument, same rules as upload-rules.sh. Either:
                  - the NAME of an environment variable holding the token
                    (e.g. MY_QODO_TOKEN), or
                  - the token itself (e.g. sk-... / qodo-svc-...).
                A value that matches a set, non-empty variable is read from that
                variable; anything else is used as a literal token.
                Omit it to fall back to \$$DEFAULT_TOKEN_VAR, then $AUTH_KEY_FILE.

${C_BOLD}OPTIONS${C_OFF}
  -w, --workspace-id ID   Also send 'qodo-workspace-id' (default: \$QODO_WORKSPACE_ID).
      --route PATH        Probe PATH instead of the built-in users routes.
                          Repeatable; replaces the defaults on first use.
      --prefix PATH       Extra prefix between host and route. Repeatable.
                          Use --prefix '' for the bare host.
      --all               Keep probing after the first success.
  -1, --first             Stop at the first success (default).
      --timeout SECONDS   Per-request timeout (default: 10).
      --insecure          Skip TLS verification (self-signed dev endpoints).
      --json              Emit one JSON object per probe on stdout.
  -v, --verbose           Print the full response body of every probe.
  -h, --help              Show this help.

${C_BOLD}WHAT IT PROBES${C_OFF}
  Bases are the given URL with each trailing path segment peeled off in turn, so
  https://host/rules/v1/rule also tries https://host/rules/v1, https://host/rules
  and https://host. Every base is combined with every prefix and every route,
  duplicates are dropped, and each surviving URL gets one GET.

  Default routes:   $(printf '%s' "$DEFAULT_ROUTES" | tr '\n' ' ')
  Default prefixes: (none) /api /platform

${C_BOLD}EXAMPLES${C_OFF}
  export $DEFAULT_TOKEN_VAR=sk-...
  $PROG https://qodo-platform.qodo.ai

  $PROG https://qodo-platform.qodo.ai MY_QODO_TOKEN --all

  $PROG https://host/rules/v1/rule sk-live-abc123 -v

  $PROG https://host --route /platform/v2/users --route /rules/v1/metadata

${C_BOLD}EXIT CODES${C_OFF}
  0  at least one URL answered 200
  1  usage error
  2  no URL answered 200 (the table shows what each one said)
EOF
}

# ------------------------------------------------------------ arg parsing ---

BASE_URL=""
TOKEN_SOURCE=""
POSITIONAL_COUNT=0

WORKSPACE_ID="${QODO_WORKSPACE_ID:-}"
ROUTES=""
PREFIXES=""
STOP_AT_FIRST=1
TIMEOUT=10
INSECURE=0
JSON_OUT=0
VERBOSE=0

add_positional() {
  POSITIONAL_COUNT=$((POSITIONAL_COUNT + 1))
  case "$POSITIONAL_COUNT" in
    1) BASE_URL="$1" ;;
    2) TOKEN_SOURCE="$1" ;;
    *) die "too many arguments: expected 1 or 2, got $POSITIONAL_COUNT (try --help)" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) STOP_AT_FIRST=0; shift ;;
    -1|--first) STOP_AT_FIRST=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    -w|--workspace-id)
      [ $# -ge 2 ] || die "$1 requires a value"
      WORKSPACE_ID="$2"; shift 2 ;;
    --workspace-id=*) WORKSPACE_ID="${1#*=}"; shift ;;
    --route)
      [ $# -ge 2 ] || die "$1 requires a value"
      ROUTES="$ROUTES$2
"; shift 2 ;;
    --route=*) ROUTES="$ROUTES${1#*=}
"; shift ;;
    --prefix)
      [ $# -ge 2 ] || die "$1 requires a value (use --prefix '' for the bare host)"
      PREFIXES="$PREFIXES$2
"; shift 2 ;;
    --prefix=*) PREFIXES="$PREFIXES${1#*=}
"; shift ;;
    --timeout)
      [ $# -ge 2 ] || die "$1 requires a value"
      TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --) shift; while [ $# -gt 0 ]; do add_positional "$1"; shift; done ;;
    -*) die "unknown option '$1' (try --help)" ;;
    *) add_positional "$1"; shift ;;
  esac
done

[ "$POSITIONAL_COUNT" -ge 1 ] || { usage >&2; info ""; die "expected a base-url (try --help)"; }

case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a positive integer, got '$TIMEOUT'" ;; esac
[ "$TIMEOUT" -gt 0 ] || die "--timeout must be greater than 0"

command -v curl >/dev/null 2>&1 || die "curl is required but not installed"
command -v jq >/dev/null 2>&1 || die "jq is required but not installed (brew install jq)"

case "$BASE_URL" in
  http://*|https://*) ;;
  *) die "base-url must start with http:// or https://, got '$BASE_URL'" ;;
esac

[ -n "$ROUTES" ] || ROUTES="$DEFAULT_ROUTES"
PREFIXES="$PREFIXES$DEFAULT_PREFIXES"

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

resolve_token || die "no bearer token found. Set \$$DEFAULT_TOKEN_VAR, pass the token (or the
    name of the variable holding it) as the 2nd argument, or create $AUTH_KEY_FILE"

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

# ---------------------------------------------------------- candidate URLs ---

TMPDIR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/qar-endpoint-validator.XXXXXX")"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT INT TERM

ORIGIN="$BASE_URL"
# Everything after the scheme's "//" up to the first "/" is the authority; the
# rest is a path this run should peel back rather than trust.
SCHEME="${BASE_URL%%://*}"
REST="${BASE_URL#*://}"
AUTHORITY="${REST%%/*}"
ORIGIN="$SCHEME://$AUTHORITY"
[ -n "$AUTHORITY" ] || die "base-url has no host, got '$BASE_URL'"

# Bases: the URL as given, then each trailing segment peeled off, down to the
# bare origin. Ordered most specific first so an exact URL is probed early.
BASES_FILE="$TMPDIR_RUN/bases.txt"
: > "$BASES_FILE"
candidate="${BASE_URL%/}"
while : ; do
  printf '%s\n' "$candidate" >> "$BASES_FILE"
  [ "$candidate" != "$ORIGIN" ] || break
  next="${candidate%/*}"
  [ "$next" != "$candidate" ] || break
  candidate="$next"
  [ -n "$candidate" ] || break
done
printf '%s\n' "$ORIGIN" >> "$BASES_FILE"

# Cross bases x prefixes x routes, normalising slashes and dropping duplicates
# while preserving order.
URLS_FILE="$TMPDIR_RUN/urls.txt"
: > "$URLS_FILE"
while IFS= read -r base; do
  [ -n "$base" ] || continue
  base="${base%/}"
  while IFS= read -r prefix; do
    case "$prefix" in
      "") norm_prefix="" ;;
      /*) norm_prefix="${prefix%/}" ;;
      *)  norm_prefix="/${prefix%/}" ;;
    esac
    while IFS= read -r route; do
      [ -n "$route" ] || continue
      case "$route" in
        /*) norm_route="${route%/}" ;;
        *)  norm_route="/${route%/}" ;;
      esac
      # Skip a prefix the route already starts with: base + /platform and a
      # /platform/v2/users route would only produce /platform/platform/v2/users.
      if [ -n "$norm_prefix" ]; then
        case "$norm_route" in
          "$norm_prefix"/*) continue ;;
        esac
      fi
      printf '%s%s%s\n' "$base" "$norm_prefix" "$norm_route" >> "$URLS_FILE"
    done <<EOF
$ROUTES
EOF
  done <<EOF
$PREFIXES
EOF
done < "$BASES_FILE"

# awk keeps first-seen order, which sort -u would destroy.
CANDIDATES="$TMPDIR_RUN/candidates.txt"
awk '!seen[$0]++' "$URLS_FILE" > "$CANDIDATES"
TOTAL="$(wc -l < "$CANDIDATES" | tr -d ' ')"

# ------------------------------------------------------------- curl setup ---

CURL_CFG="$TMPDIR_RUN/curl.cfg"
( umask 077; : > "$CURL_CFG" )
{
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN"
  printf 'header = "Accept: application/json"\n'
  if [ -n "$WORKSPACE_ID" ]; then
    printf 'header = "qodo-workspace-id: %s"\n' "$WORKSPACE_ID"
  fi
  printf 'silent\nshow-error\n'
  printf 'max-time = %s\n' "$TIMEOUT"
  if [ "$INSECURE" -eq 1 ]; then printf 'insecure\n'; fi
} >> "$CURL_CFG"

BODY="$TMPDIR_RUN/body.json"
CURL_ERR="$TMPDIR_RUN/curlerr.txt"

detail_for() {
  # A short human summary of whatever came back.
  local status="$1" summary
  if [ "$status" = "200" ]; then
    # Pull an identity out of the principal shape when it is there.
    summary="$(jq -r '
        (.data.user // .user // .data // .) as $u
        | if ($u | type) == "object"
          then [($u.email // empty), ($u.tenant_id // $u.tenantId // empty)]
               | map(select(. != "" and . != null)) | join(" / ")
          else empty end' "$BODY" 2>/dev/null || true)"
  else
    summary="$(jq -r '
        if type == "object" then
          (.detail // .message // .error // empty)
          | if type == "array" then map(.msg // tostring) | join("; ")
            elif type == "object" then tojson
            else tostring end
        else empty end' "$BODY" 2>/dev/null || true)"
  fi
  if [ -z "$summary" ]; then
    summary="$(tr -d '\r\n' < "$BODY" | cut -c1-120)"
  fi
  printf '%s' "$summary"
}

transport_detail() {
  tr -d '\r' < "$CURL_ERR" | tr '\n' ' ' | sed 's/  */ /g;s/^ *//;s/ *$//'
}

# ----------------------------------------------------------------- banner ---

if [ "$JSON_OUT" -eq 0 ]; then
  info "${C_BOLD}base${C_OFF}       $BASE_URL"
  info "${C_BOLD}origin${C_OFF}     $ORIGIN"
  info "${C_BOLD}token${C_OFF}      $(redact "$TOKEN") ${C_DIM}(from $TOKEN_ORIGIN)${C_OFF}"
  if [ -n "$WORKSPACE_ID" ]; then
    info "${C_BOLD}workspace${C_OFF}  $WORKSPACE_ID"
  else
    info "${C_BOLD}workspace${C_OFF}  ${C_DIM}header not sent${C_OFF}"
  fi
  info "${C_BOLD}probing${C_OFF}    $TOTAL URL(s) with GET$([ "$STOP_AT_FIRST" -eq 1 ] && printf ', stopping at the first 200')"
  info ""
fi

# ------------------------------------------------------------------ probe ---

FOUND=""
FOUND_DETAIL=""
ATTEMPTED=0
SKIPPED=0

emit_json() { # emit_json <url> <status> <seconds> <detail>
  jq -n -c \
    --arg url "$1" --arg status "$2" --arg seconds "$3" --arg detail "$4" \
    '{url: $url, status: ($status | tonumber? // $status), seconds: ($seconds | tonumber? // null), detail: $detail}'
}

while IFS= read -r url; do
  [ -n "$url" ] || continue

  if [ -n "$FOUND" ] && [ "$STOP_AT_FIRST" -eq 1 ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  ATTEMPTED=$((ATTEMPTED + 1))
  measured="$(curl -K "$CURL_CFG" -X GET "$url" \
    -o "$BODY" -w '%{http_code} %{time_total}' \
    < /dev/null 2>"$CURL_ERR" || true)"
  status="${measured%% *}"
  seconds="${measured##* }"
  [ -n "$status" ] || status="000"
  case "$seconds" in ''|"$status") seconds="0" ;; esac
  # curl reports microseconds; milliseconds are all this is accurate to.
  seconds="$(printf '%.3f' "$seconds" 2>/dev/null || printf '%s' "$seconds")"

  if [ "$status" = "000" ]; then
    detail="$(transport_detail)"
  else
    detail="$(detail_for "$status")"
  fi

  if [ "$JSON_OUT" -eq 1 ]; then
    emit_json "$url" "$status" "$seconds" "$detail"
  else
    line="$(printf '  %-4s %6ss  %s' "$status" "$seconds" "$url")"
    case "$status" in
      200) ok "$line" ;;
      401|403) warn "$line" ;;
      000) err "$line" ;;
      *) info "${C_DIM}$line${C_OFF}" ;;
    esac
    # A 404 body says nothing the status has not already said; anything else
    # (a 200's identity, a 401's reason) is the point of the run.
    if [ -n "$detail" ] && { [ "$status" != "404" ] || [ "$VERBOSE" -eq 1 ]; }; then
      info "${C_DIM}              $detail${C_OFF}"
    fi
    if [ "$VERBOSE" -eq 1 ] && [ -s "$BODY" ]; then
      jq . "$BODY" 2>/dev/null | sed "s/^/${C_DIM}              /;s/\$/${C_OFF}/" >&2 \
        || sed "s/^/${C_DIM}              /;s/\$/${C_OFF}/" "$BODY" >&2
    fi
  fi

  if [ "$status" = "200" ] && [ -z "$FOUND" ]; then
    FOUND="$url"
    FOUND_DETAIL="$detail"
  fi
done < "$CANDIDATES"

# ----------------------------------------------------------------- report ---

if [ "$JSON_OUT" -eq 1 ]; then
  [ -n "$FOUND" ] && exit 0
  exit 2
fi

info ""
if [ -n "$FOUND" ]; then
  ok "${C_BOLD}found${C_OFF}${C_GREEN}      $FOUND"
  if [ -n "$FOUND_DETAIL" ]; then
    info "${C_BOLD}resolved${C_OFF}   $FOUND_DETAIL"
  fi
  # The rules module hangs off the same origin, so hand back the base URL
  # upload-rules.sh should be pointed at.
  info "${C_BOLD}upload with${C_OFF} ./upload-rules.sh $ORIGIN rule.json"
  info "${C_DIM}probed $ATTEMPTED of $TOTAL URL(s)$([ "$SKIPPED" -gt 0 ] && printf ', %s skipped after the first hit - use --all to probe them too' "$SKIPPED")${C_OFF}"
  exit 0
fi

err "no URL answered 200 after $ATTEMPTED probe(s)"
info "${C_DIM}if the deployment mounts the API somewhere unusual, add it with --route / --prefix${C_OFF}"
exit 2
