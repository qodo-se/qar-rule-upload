# qar-rule-upload

[![tests](https://github.com/qodo-se/qar-rule-upload/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/qodo-se/qar-rule-upload/actions/workflows/tests.yml)

Bulk-create Qodo rules from a JSON file.

| Script | What it does |
| --- | --- |
| [`upload-rules.sh`](upload-rules.sh) | Uploads a JSON array of rules to `{base-url}/rules/v1/rule`. |
| [`endpoint-validator.sh`](endpoint-validator.sh) | Probes a base URL to find where the API answers, before you point the uploader at it. |

`upload-rules.sh` reads a JSON **array**, validates every entry against the platform's write
contract, and POSTs each object — one request per rule, because the platform has no bulk-create
endpoint (`/rules/v1/bulk` only operates on rule IDs that already exist).

Validation runs over the whole file before the first request, so a typo in rule 40 fails the run
before rule 1 is uploaded.

## Requirements

`bash` (3.2+, so the macOS system bash is fine), `curl`, and `jq`.

```bash
brew install jq
```

## Usage

```
./upload-rules.sh <base-url> <rule.json> [token-source] [options]
```

The third argument is optional, which is how the script takes either two or three parameters:

```bash
# 2 arguments — token comes from $QODO_API_KEY (or ~/.qodo/auth.key)
export QODO_API_KEY=sk-...
./upload-rules.sh https://qodo-platform.qodo.ai rule.json

# 3 arguments — the NAME of the variable holding the token
export MY_QODO_TOKEN=sk-...
./upload-rules.sh https://qodo-platform.qodo.ai rule.json MY_QODO_TOKEN

# 3 arguments — the token itself
./upload-rules.sh https://qodo-platform.qodo.ai rule.json sk-live-abc123
```

### The endpoint URL

`base-url` is the Qodo platform base URL, and the script appends `/rules/v1/rule` — the route the
platform's rules module is mounted at. It appends only the part your URL is missing, so a base that
already carries some of that route lands in the same place instead of doubling up:

| You pass | POSTs to |
| --- | --- |
| `https://host` | `https://host/rules/v1/rule` |
| `https://host/` | `https://host/rules/v1/rule` |
| `https://host/rules` | `https://host/rules/v1/rule` |
| `https://host/rules/v1` | `https://host/rules/v1/rule` |
| `https://host/rules/v1/rule` | `https://host/rules/v1/rule` |
| `https://host/some/endpoint` + `--path ''` | `https://host/some/endpoint` |

The overlap is matched on path-segment boundaries, so a base URL ending in `/qodo-rules` is not
mistaken for one ending in `/rules`. Use `--path` when a deployment mounts the route somewhere else,
and `--path ''` to post to `base-url` verbatim with nothing appended.

The resolved endpoint is printed before anything is sent, so `--dry-run` is a cheap way to confirm
it.

### How the token is resolved

| Situation | Where the token comes from |
| --- | --- |
| 3rd argument names a set, non-empty variable | that variable's value |
| 3rd argument is anything else | the argument is used as the literal token |
| No 3rd argument | `$QODO_API_KEY`, then `~/.qodo/auth.key` |

So `MY_QODO_TOKEN` is read as a variable name when that variable is exported, and treated as a
literal token when it isn't. The script prints which source it used (with the value redacted) before
it sends anything. The token is passed to `curl` through a `0600` config file rather than on the
command line, so it never appears in the process list.

### Options

| Option | Effect |
| --- | --- |
| `-w, --workspace-id ID` | Send the `qodo-workspace-id` header. Defaults to `$QODO_WORKSPACE_ID`. |
| `-n, --dry-run` | Validate and print each payload; send nothing. Works without a token. |
| `-k, --keep-going` | Keep uploading after a failure. Default is to stop at the first one. |
| `--path PATH` | Route appended to `base-url` (default `/rules/v1/rule`). `--path ''` appends nothing. |
| `--retries N` | Retry attempts for `429` and `5xx` (default `2`). Honours `Retry-After`. |
| `--timeout SECONDS` | Per-request timeout (default `30`). |
| `--insecure` | Skip TLS verification, for self-signed dev endpoints. |
| `-q, --quiet` | Only print failures and the final summary. |

A user key (`sk-...`) carries its workspace in the token itself, so `--workspace-id` is not needed.
A service key (`qodo-svc-...`) does need it — without it the platform cannot tell which workspace to
write to and the request comes back `403`.

Pass `-` as the file to read the array from stdin.

## Finding the endpoint: `endpoint-validator.sh`

If you are not sure a base URL is right, or a token works, probe it first:

```
./endpoint-validator.sh <base-url> [token-source] [options]
```

It takes a base URL and a token, with the **same token rules as `upload-rules.sh`** (named variable,
literal, or `$QODO_API_KEY`), builds a matrix of plausible URLs, GETs each one, and prints the
complete URL and the result for every probe.

```bash
export QODO_API_KEY=sk-...
./endpoint-validator.sh https://qodo-platform.qodo.ai
```

```
base       https://qodo-platform.qodo.ai
origin     https://qodo-platform.qodo.ai
token      sk-liv...1234 (from $QODO_API_KEY)
workspace  header not sent
probing    11 URL(s) with GET, stopping at the first 200

  200   0.184s  https://qodo-platform.qodo.ai/platform/v2/users
              user@example.com / 00000000-0000-0000-0000-0000000000ff

found      https://qodo-platform.qodo.ai/platform/v2/users
resolved   user@example.com / 00000000-0000-0000-0000-0000000000ff
upload with ./upload-rules.sh https://qodo-platform.qodo.ai rule.json
```

### Why the users endpoint

qodo-platform publishes **no unauthenticated health or ping route** — nothing like `/health`,
`/healthz` or `/ping` exists on it. (The `/v1/health/live` and `/v1/health/ready` endpoints in
`qodo-agent-runtime` belong to QAR, a different host, and 404 on the platform.)

So the validator uses the cheapest authenticated GET there is, `/platform/v2/users` — the principal
resolution call. No query parameters, bearer only, and it returns the identity your token maps to,
which is more informative than a health check would be: it proves the host is reachable, the token
is valid, and tells you *who* the token is.

### What it probes

Bases are the URL you gave with each trailing path segment peeled off in turn, so
`https://host/rules/v1/rule` also tries `https://host/rules/v1`, `https://host/rules` and
`https://host`. Each base is combined with each prefix and each route; duplicates are dropped.

- **Routes:** `/platform/v2/users`, `/platform/v1/users`, `/v2/users`, `/v1/users`, `/users`
- **Prefixes:** none, `/api`, `/platform`

By default it stops at the first `200`. Pass `--all` to probe everything, which is what you want
when you are mapping an unfamiliar deployment.

### Options

| Option | Effect |
| --- | --- |
| `-w, --workspace-id ID` | Also send `qodo-workspace-id`. Defaults to `$QODO_WORKSPACE_ID`. |
| `--route PATH` | Probe `PATH` instead of the built-in routes. Repeatable; replaces the defaults. |
| `--prefix PATH` | Extra prefix between host and route. Repeatable. `--prefix ''` for the bare host. |
| `--all` | Keep probing after the first success. |
| `-1, --first` | Stop at the first success (default). |
| `--timeout SECONDS` | Per-request timeout (default `10`). |
| `--insecure` | Skip TLS verification. |
| `--json` | Emit one JSON object per probe on stdout. |
| `-v, --verbose` | Print the full response body of every probe. |

Exit codes: `0` when something answered `200`, `1` for a usage error, `2` when nothing did (the
table still shows what each URL said, so a wall of `401`s tells you the token is the problem and a
wall of `404`s tells you the base URL is).

`--route` also makes it a general-purpose prober — point it at any endpoint you want to check:

```bash
./endpoint-validator.sh https://host --route /rules/v1/metadata --all
```

## Input format

A JSON array. Each object becomes one POST body.

```json
[
  {
    "name": "Never log secrets or tokens",
    "category": "Security",
    "severity": "error",
    "content": "Do not pass credentials, API keys, or bearer tokens to a logger. Redact the value or log a stable identifier instead.",
    "goodExamples": "logger.info(\"authenticated\", extra={\"key_id\": key.id})",
    "badExamples": "logger.info(f\"authenticated with {api_key}\")"
  },
  {
    "name": "Set a timeout on outbound HTTP calls",
    "category": "Reliability",
    "severity": "error",
    "content": "Every outbound HTTP request must set an explicit timeout so a slow upstream cannot exhaust the caller's connection pool.",
    "goodExamples": "resp = await client.get(url, timeout=10.0)",
    "badExamples": "resp = await client.get(url)",
    "scopes": ["/owner/repo/"]
  }
]
```

Two ready-made sets ship with the repo: [`rule.json`](rule.json), 31 security rules keyed to CWE,
CERT C, OWASP and CMMC, and [`jama.json`](jama.json), 35 MISRA C and MISRA C++ rules for
safety-critical embedded code. Upload either the same way:

```bash
export QODO_API_KEY=sk-...
./upload-rules.sh https://qodo-platform.qodo.ai jama.json
```

**Both sets ship universally scoped, so as written every rule in them applies to every repository in
the workspace.** `jama.json` says so out loud — every rule carries `"scopes": []`, the universal
scope `/` — and `rule.json` says it by leaving the key off, which means the same thing. For
`jama.json` that default is only suitable for a workspace dedicated to applicable C and C++ safety
code; anywhere else it raises MISRA C and C++ guidance against the TypeScript, Python and Go
repositories next door.

So scope the set to the repositories or source directories it belongs to before uploading. The
`"scopes": []` in each rule is the line to edit, and the script prints a `scope` warning in its
banner whenever a file is about to go up universally scoped anyway:

```bash
# Scope every rule to one repository, then upload the scoped copy.
jq '[.[] | .scopes = ["/owner/firmware/"]]' jama.json > jama.scoped.json
./upload-rules.sh https://qodo-platform.qodo.ai jama.scoped.json
```

Narrowing it afterwards is not a re-upload: rule names are unique per workspace, so the scoped copy
comes back `409` for every rule and the universal ones stay exactly as they were. Delete those in
the workspace first, or scope the file before the first run.

See [`rule.schema.json`](rule.schema.json) for a JSON Schema of the whole file.

### Fields

These six are the mandatory ones — the script sends nothing else unless you add `scopes`. They are
the required properties of the platform's `RuleCreateRequest`, and the bounds below come from it.

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `name` | string | yes | Non-empty, max **128** characters. Must be unique in the workspace; a duplicate comes back as `409`. |
| `category` | string | yes | Free-form string, but use one of the known values below so rules group correctly. |
| `severity` | string | yes | Closed enum: `error`, `warning`, `recommendation`. |
| `content` | string | yes | Non-empty. What the rule checks or enforces, 1–3 sentences, imperative voice. |
| `goodExamples` | string | yes | Code that **follows** the rule. May be `""`, but the key must be present. |
| `badExamples` | string | yes | Code that **violates** the rule. May be `""`, but the key must be present. |
| `scopes` | string[] | no | Repository paths the rule applies to, max **100**. Omitting it — or writing `[]`, which the script sends as the same body — means the universal scope `/`: **every repository in the workspace**. Set it unless the rule really is workspace-wide. |

The platform also accepts `source`, `sourceType`, `sourceUri`, `suggestionType` and the structured
`scopeElements` on a create. The script does not send them: a user key already records the creator
as the rule's source, and `scopeElements` is the newer form of the same information `scopes` carries.
Put any of them in your file and they are dropped with a note, like any other non-contract field.

### `severity`

Exactly one of these three, lowercase on the wire. The script lowercases and trims for you, so
`"Error"` in your file is sent as `"error"`.

| Value | Meaning |
| --- | --- |
| `error` | Must comply. |
| `warning` | Comply by default. |
| `recommendation` | Apply when appropriate. |

Severity is the weight the workspace puts on the rule, so it has to match what the rule's own text
claims. A rule that rests on a "should" guideline — MISRA's Advisory category, for one — is a
`recommendation` however forcefully it is worded, because `error` says the code cannot ship this
way. [`jama.json`](jama.json) maps MISRA's categories that way: guidelines marked Mandatory or
Required are `error`, Advisory ones are `recommendation`, and the process and compliance-artifact
rules that no single guideline decides are `warning`. A project whose re-categorization plan
upgrades an Advisory guideline can of course raise the severity to match — but then the rule should
cite the upgrade rather than the category the guideline ships with.

### `category`

The API accepts any non-empty string, so this is **not** rejected server-side the way `severity` is —
but these are the values the Qodo tooling generates and searches against, and a typo here quietly
creates a new category:

`Security` · `Correctness` · `Quality` · `Reliability` · `Performance` · `Testability` ·
`Compliance` · `Accessibility` · `Observability` · `Architecture`

Title Case, as written. For the categories a specific workspace actually uses, call
`GET {base-url}/rules/v1/metadata`.

### `scopes`

Optional, but the default is the widest one there is: a rule with no `scopes` applies to **every
repository in the workspace**, including the ones in languages the rule was never written for.
Paths look like `/owner/repo/` or `/owner/repo/src/module/`, max 100 entries.

- Omit the key entirely for the universal scope `/` — right for a rule that really is
  workspace-wide, wrong for a language- or project-specific one.
- `[]` means the same thing, written down. The script drops an empty list before sending, so the
  server sees the same body either way; use it when the universal scope is a decision rather than
  an oversight, the way [`jama.json`](jama.json) does.
- Entries are trimmed; a bare string is accepted and wrapped into a list.
- The script counts unscoped rules and warns in its banner before it sends anything. `--dry-run`
  prints the same line without uploading.

### Conveniences the script applies

These exist so a hand-written file doesn't get bounced for cosmetic reasons:

- `good_examples` / `bad_examples` are accepted as aliases for `goodExamples` / `badExamples`.
- `severity` is lowercased and trimmed.
- `scopes` entries are trimmed, and a bare string becomes a one-element list.
- An empty `scopes` list is dropped, so `[]` and an omitted key produce the same request body.
- Fields outside the contract (`state`, `ruleId`, `createdAt`, `sourceType`, …) are dropped with a
  note, so you can round-trip a `GET` response back into an upload without hand-editing it.

### JSON Schema

[`rule.schema.json`](rule.schema.json) (draft 2020-12) describes the file **as written**, so it
allows the snake_case aliases and the mixed-case severity the script normalises for you — not just
the wire shape. The two are kept in step: a file that validates against the schema passes the
script's own validation, and a file the schema rejects is one the script refuses to upload.

Point an editor at it for completion and inline errors, or run it in CI:

```bash
# any JSON Schema validator will do
check-jsonschema --schemafile rule.schema.json rule.json
npx ajv-cli validate -s rule.schema.json -d rule.json --spec=draft2020
```

The script itself does not read the schema — it validates with `jq` so it needs nothing beyond
`jq` and `curl`. The schema is for your editor, your CI, and for reading the contract in one place.

## Output

```
endpoint  https://qodo-platform.qodo.ai/rules/v1/rule
rules     31 from rule.json
scope     all 31 rules are universally scoped ("/") - EVERY repository in the workspace
          set "scopes": ["/owner/repo/"] per rule to narrow it
token     sk-liv...c123 (from $QODO_API_KEY)
workspace header not sent - resolved from the token

[1/31] [Qodo-CWE] Format String (CWE-134) - created (ruleId 41)
[2/31] [Qodo-CWE] Stack Buffer Overflow (CWE-121) - created (ruleId 42)
[3/31] [Qodo-CWE] Double Free (CWE-415) - already exists, skipped
...

done: created 30, already existed 1 (of 31)
```

### Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Every rule was created or already existed. |
| `1` | Usage or validation error. **Nothing was uploaded.** |
| `2` | One or more uploads failed. |

### Response handling

| Status | Behaviour |
| --- | --- |
| `201` | Created. The returned `ruleId` is printed. |
| `409` | Name already exists. Counted as "already existed", not a failure. |
| `429`, `5xx` | Retried up to `--retries` times, honouring `Retry-After`. |
| `401`, `403` | Stops immediately — these repeat for every rule, so continuing is pointless. |
| `400`, `422` | Reported with the server's `detail` message. |

## Severity policy for `rule.json`

`severity` in this file is derived rather than chosen. Two published signals decide it,
so a reviewer can re-derive every value from source instead of taking it on trust.

```
error    the rule's DISA anchor is CAT I
         OR its CWE appears in the 2025 CWE Top 25
warning  otherwise
```

| Signal | Edition | Where it is read from |
| --- | --- | --- |
| DISA CAT level | **ASD STIG V6R3** | `Rule/@severity` in the XCCDF, `high` maps to CAT I |
| CWE Top 25 | **MITRE CWE 4.20, catalog View 1435** | `Weaknesses in the 2025 CWE Top 25 Most Dangerous Software Weaknesses`, 25 members |

Current split is 20 `error` and 11 `warning` across 31 rules.

### Why CAT alone is not enough

`APSC-DV-003170` is CAT II because it is a **process** control, *"an application code
review must be performed on the application."* Its CAT reflects the severity of the
control, not of the defect a rule detects. Deriving severity from CAT alone demoted
use-after-free, path traversal and unchecked allocation result to `warning`. View 1435
membership restores exactly those three.

### Documented exceptions

One rule is set above what the two signals produce. Exceptions are listed here rather
than applied silently, so the policy stays auditable.

| Rule | Derived | Shipped | Why |
| --- | --- | --- | --- |
| `[Qodo-OWASP] Log Injection and Log Disclosure (CWE-117)` | `warning` | **`error`** | Its second clause covers credentials, tokens and full personal records. A warning may not block a secrets leak, and the confidentiality impact of that clause is not captured by either signal. |

### Re-deriving it

Both inputs are public downloads:

- `cwe.mitre.org/data/xml/cwec_latest.xml.zip`, then read View `1435` members
- `dl.dod.cyber.mil/wp-content/uploads/stigs/zip/U_ASD_V6R3_STIG.zip`, then read
  `Group/Rule/@severity` for each `APSC-DV` id cited in a rule's `content`

Every rule in `rule.json` carries its DISA control id in the `content` tail, so the
mapping is checkable per rule without any extra metadata file.

## A note on rule state

Creating a rule is not admin-gated. If the token belongs to a **non-admin**, the rule lands as a
`state=pending` suggestion for someone to triage rather than going live. An **admin** token creates
active rules directly. Either way the response is `201 {"ruleId": N}`, so the script reports both the
same way — check the workspace if you need to know which you got.

## Tests

[`tests/run-tests.sh`](tests/run-tests.sh) boots a mock of the endpoint
([`tests/mock-server.py`](tests/mock-server.py)), runs the script against it, and asserts both the
CLI behaviour and the exact shape of every request that reached the server.

Two instances come up. The first takes the CLI cases, which deliberately send malformed, duplicate
and exploding payloads. The second is armed via `--expect` with the fixture
[`tests/test.json`](tests/test.json) — the same file the script uploads to it — and asserts that the
body of POST number N is deep-equal to entry N of that fixture, so any field the script drops,
renames or rewrites comes straight back as a `422` carrying the diff. Every request must also carry
a bearer token. `GET /__verify__` then reports the run's verdict, which fails unless all of the
fixture arrived.

```bash
./tests/run-tests.sh            # upload-rules.sh
./tests/run-validator-tests.sh  # endpoint-validator.sh
```

Requires `python3` for the mock; no other dependencies.

### CI

[`.github/workflows/tests.yml`](.github/workflows/tests.yml) runs `run-tests.sh` on every push to
`main`, on pull requests targeting it, and on demand from the Actions tab. A failing run puts the
`PASSED/FAILED` tally and every `FAIL:` line in the job summary, raises one annotation per failure
so they show on the checks tab, and uploads the suite output with both mock-server logs as a
`test-logs` artifact. The job installs `jsonschema` from
[`.github/ci-requirements.txt`](.github/ci-requirements.txt), so the schema case runs there instead
of skipping the way it does on a machine without it.

The GitHub Actions used by the job are pinned to reviewed commit SHAs, with their release versions
kept in trailing comments. Python package artifacts are also pinned by exact version and sha256 and
installed with `pip --require-hashes`, which forces the requirements file to carry the whole
dependency closure. The hosted runner image, its bundled tools (including Bash, jq, and curl), and
the resolved Python 3.12 patch release remain managed by GitHub and may change independently.
The file's header carries the `uv pip compile` line that regenerates it.
