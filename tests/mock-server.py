#!/usr/bin/env python3
"""Mock of POST /rules/v1/rule for exercising upload-rules.sh.

    mock-server.py <port> [--expect <rules.json>]

GET /rules/v1/metadata is served too, under the same auth rules, because that
is the preflight probe the script runs before its first POST.

Unarmed it enforces only the generic wire contract: the six required fields,
no extras, a known severity, 409 on a repeated name.

Armed with --expect it additionally asserts that the body of POST number N is
deep-equal to entry N of the fixture - i.e. that upload-rules.sh sent exactly
what the file says, in file order. A body that differs comes back as 422
carrying the field-level diff, and GET /__verify__ reports the run's verdict.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

SEVERITIES = {"error", "warning", "recommendation"}
REQUIRED = ["name", "category", "severity", "content", "goodExamples", "badExamples"]
ALLOWED = set(REQUIRED) | {"scopes"}
RULE_PATH = "/rules/v1/rule"
RULES_LIST_PATH = "/rules/v1/rules"
METADATA_PATH = "/rules/v1/metadata"
# The principal-resolution GET that endpoint-validator.sh hunts for. Exactly one
# path serves it, so a validator run has to actually find this one.
USERS_PATH = "/platform/v2/users"
BEARER = "Bearer "

# What GET /rules/v1/metadata reports as the workspace's existing categories.
# "Architecture" is deliberately absent so the upload script has something to
# flag as a category this workspace does not use yet.
CATEGORIES = [
    "Security",
    "Correctness",
    "Quality",
    "Reliability",
    "Performance",
    "Testability",
    "Observability",
]

expect_path = None
expect = None  # fixture entries, or None when unarmed

seen_names = set()
rules_by_name = {}
updates = []
next_id = [40]
log = []
metadata_log = []
users_log = []
auth_failures = []


def bearer_problem(auth):
    """Why this Authorization header is not a usable bearer, or None."""
    if not auth:
        return "Authorization header missing"
    if not auth.startswith(BEARER):
        return "Authorization header is not a Bearer credential"
    if not auth[len(BEARER):].strip():
        return "Bearer token is empty"
    return None


def contract_problems(body):
    """Wire-contract violations, independent of any fixture."""
    problems = []
    extra = sorted(set(body) - ALLOWED)
    if extra:
        problems.append(f"extra fields: {extra}")
    missing = [f for f in REQUIRED if f not in body]
    if missing:
        problems.append(f"missing: {missing}")
    if body.get("severity") not in SEVERITIES:
        problems.append(f"bad severity {body.get('severity')!r}")
    return problems


def fixture_problems(body, index):
    """How this body differs from the fixture entry it should have matched.

    A name mismatch is reported on its own: it means the wrong rule arrived in
    this slot, and the per-field diff that follows from it is just noise.
    """
    if index >= len(expect):
        return [f"request {index + 1} exceeds the {len(expect)} rule(s) in {expect_path}"]
    wanted = expect[index]
    if body.get("name") != wanted.get("name"):
        return [
            f"expected fixture[{index}] {wanted.get('name')!r}, "
            f"got {body.get('name')!r} (wrong rule, or out of order)"
        ]
    problems = []
    for key in sorted(set(wanted) | set(body)):
        if key not in body:
            problems.append(f"{key!r} missing, expected {wanted[key]!r}")
        elif key not in wanted:
            problems.append(f"{key!r} unexpected, got {body[key]!r}")
        elif body[key] != wanted[key]:
            problems.append(f"{key!r} expected {wanted[key]!r}, got {body[key]!r}")
    return problems


def mismatches():
    """The recorded requests that failed a check, in arrival order."""
    return [
        {"request": i + 1, "name": e["body"].get("name"), "problems": e["problems"]}
        for i, e in enumerate(log)
        if e["problems"]
    ]


def verdict():
    """Whether this run proved upload-rules.sh sent the fixture verbatim."""
    bad = mismatches()
    bearer_on_every = all(e["token"].strip() for e in log)
    return {
        "fixture": expect_path,
        "expected": len(expect) if expect is not None else None,
        "received": len(log),
        "matched": len(log) - len(bad),
        "bearerOnEveryRequest": bearer_on_every,
        "mismatches": bad,
        "authFailures": auth_failures,
        "ok": (
            expect is not None
            and len(log) == len(expect)
            and not bad
            and not auth_failures
            and bearer_on_every
        ),
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _reject_auth(self, code, reason):
        auth_failures.append({"request": len(log) + 1, "status": code, "reason": reason})
        return self._send(code, {"detail": reason})

    def do_POST(self):
        if self.path != RULE_PATH:
            return self._send(404, {"detail": "Not Found"})

        auth = self.headers.get("Authorization", "")
        problem = bearer_problem(auth)
        if problem:
            return self._reject_auth(401, problem)
        token = auth[len(BEARER):]
        if token == "bad-token":
            return self._reject_auth(401, "Invalid authentication credentials")
        if token == "no-perms":
            return self._reject_auth(403, "workspace access denied")

        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw or b"{}")
        except ValueError as exc:
            return self._send(400, {"detail": f"body is not valid JSON: {exc}"})
        if not isinstance(body, dict):
            return self._send(422, {"detail": [{"msg": "body must be a JSON object"}]})

        index = len(log)
        entry = {
            "token": token,
            "workspace": self.headers.get("qodo-workspace-id"),
            "content_type": self.headers.get("Content-Type"),
            "accept": self.headers.get("Accept"),
            "body": body,
            "problems": [],
        }
        log.append(entry)

        entry["problems"] = contract_problems(body)
        if entry["problems"]:
            return self._send(422, {"detail": [{"msg": m} for m in entry["problems"]]})

        if body["name"] == "__boom__":
            return self._send(500, {"detail": "internal error"})

        if expect is not None:
            entry["problems"] = fixture_problems(body, index)
            if entry["problems"]:
                return self._send(422, {"detail": [{"msg": m} for m in entry["problems"]]})

        if body["name"] in seen_names:
            return self._send(409, {"detail": "a rule with this name already exists"})

        seen_names.add(body["name"])
        next_id[0] += 1
        rules_by_name[body["name"]] = dict(body, ruleId=next_id[0], state="active")
        return self._send(201, {"ruleId": next_id[0]})

    def do_GET(self):
        if self.path == "/__log__":
            return self._send(200, log)
        if self.path == "/__verify__":
            return self._send(200, verdict())
        if self.path == "/__metalog__":
            return self._send(200, metadata_log)
        if self.path == "/__updates__":
            return self._send(200, updates)
        if self.path == "/__userslog__":
            return self._send(200, users_log)
        if self.path.split("?")[0] == RULES_LIST_PATH:
            return self._rules_list()
        if self.path == METADATA_PATH:
            return self._metadata()
        if self.path == USERS_PATH:
            return self._users()
        return self._send(404, {"detail": "Not Found"})

    def _rules_list(self):
        """GET /rules/v1/rules - name lookup used by the 409 upsert path."""
        auth = self.headers.get("Authorization", "")
        if bearer_problem(auth):
            return self._send(401, {"detail": bearer_problem(auth)})
        from urllib.parse import urlparse, parse_qs, unquote
        q = parse_qs(urlparse(self.path).query)
        needle = unquote((q.get("name_contains") or [""])[0])
        hits = [r for n, r in rules_by_name.items() if needle and needle in n]
        return self._send(200, {"page": 1, "totalCount": len(hits), "rules": hits})

    def do_PUT(self):
        """PUT /rules/v1/rule/{id} - the update half of the upsert."""
        auth = self.headers.get("Authorization", "")
        if bearer_problem(auth):
            return self._send(401, {"detail": bearer_problem(auth)})
        m = re.match(re.escape(RULE_PATH) + r"/(\d+)$", self.path)
        if not m:
            return self._send(404, {"detail": "Not Found"})
        rid = int(m.group(1))
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError as exc:
            return self._send(400, {"detail": f"body is not valid JSON: {exc}"})
        # PUT's contract: camelCase, seven mandatory fields including state.
        missing = [k for k in ("name", "category", "severity", "content",
                               "goodExamples", "badExamples", "state")
                   if k not in body]
        if missing:
            return self._send(422, {"detail": [{"msg": "***"} for _ in missing]})
        updates.append({"ruleId": rid, "body": body})
        rules_by_name[body["name"]] = dict(body, ruleId=rid)
        return self._send(200, dict(body, ruleId=rid))

    def _users(self):
        """GET /platform/v2/users - principal resolution, bearer only."""
        auth = self.headers.get("Authorization", "")
        problem = bearer_problem(auth)
        if problem:
            return self._send(401, {"detail": problem})
        token = auth[len(BEARER):]
        if token == "bad-token":
            return self._send(401, {"detail": "Invalid authentication credentials"})
        if token == "no-perms":
            return self._send(403, {"detail": "workspace access denied"})
        users_log.append({"token": token, "workspace": self.headers.get("qodo-workspace-id")})
        return self._send(200, {"data": {"user": {
            "email": "user@example.com",
            "tenant_id": "00000000-0000-0000-0000-0000000000ff",
            "organization_id": "org-1",
            "organization_permission": "admin",
            "is_scoped_key": False,
        }}})

    def _metadata(self):
        """The preflight probe: same auth as a write, but read-only."""
        auth = self.headers.get("Authorization", "")
        problem = bearer_problem(auth)
        if problem:
            return self._send(401, {"detail": problem})
        token = auth[len(BEARER):]
        if token == "bad-token":
            return self._send(401, {"detail": "Invalid authentication credentials"})
        if token == "no-perms":
            return self._send(403, {"detail": "workspace access denied"})
        metadata_log.append({"token": token, "workspace": self.headers.get("qodo-workspace-id")})
        return self._send(200, {
            "categories": list(CATEGORIES),
            "severities": sorted(SEVERITIES),
            "sourceTypes": ["User", "System"],
        })


def load_expect(path):
    """Read the fixture the incoming requests will be matched against."""
    try:
        with open(path, encoding="utf-8") as fh:
            rules = json.load(fh)
    except OSError as exc:
        sys.exit(f"mock-server: cannot read --expect file: {exc}")
    except ValueError as exc:
        sys.exit(f"mock-server: --expect file is not valid JSON: {exc}")
    if not isinstance(rules, list) or not rules:
        sys.exit(f"mock-server: --expect file must be a non-empty JSON array: {path}")
    if any(not isinstance(r, dict) for r in rules):
        sys.exit(f"mock-server: --expect entries must all be JSON objects: {path}")
    return rules


def parse_args(argv):
    port = 8781
    path = None
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--expect":
            if not rest:
                sys.exit("mock-server: --expect requires a path")
            path = rest.pop(0)
        elif arg.startswith("--expect="):
            path = arg.split("=", 1)[1]
        else:
            try:
                port = int(arg)
            except ValueError:
                sys.exit(f"mock-server: unexpected argument {arg!r}")
    return port, path


if __name__ == "__main__":
    port, expect_path = parse_args(sys.argv[1:])
    if expect_path is not None:
        expect = load_expect(expect_path)
    try:
        server = HTTPServer(("127.0.0.1", port), Handler)
    except OSError as exc:
        sys.exit(f"mock-server: cannot bind 127.0.0.1:{port}: {exc}")
    server.serve_forever()
