#!/usr/bin/env python3
"""Assert that rule.schema.json reaches the same verdict as upload-rules.sh.

    check-schema.py --schema <schema.json> [--valid FILE ...] [--invalid FILE ...]

The harness passes it the files the script accepted as --valid and the ones the
script rejected as --invalid, so the schema is checked against the script's own
validator rather than against a second copy of the rules.

    0   every file got the expected verdict
    1   a file validated when it should not have, or the other way round
    77  skipped: the jsonschema package is not installed

The skip keeps the suite's python3-only dependency: the schema is a deliverable
for editors and CI, not something upload-rules.sh reads at runtime.
"""
import json
import sys

try:
    from jsonschema import Draft202012Validator
except ImportError:
    print("  SKIP: python3 jsonschema is not installed (pip install jsonschema)")
    raise SystemExit(77) from None


def parse_args(argv):
    schema = None
    files = []  # (path, should_validate)
    bucket = None
    rest = list(argv)
    while rest:
        arg = rest.pop(0)
        if arg == "--schema":
            if not rest:
                sys.exit("check-schema: --schema requires a path")
            schema = rest.pop(0)
        elif arg == "--valid":
            bucket = True
        elif arg == "--invalid":
            bucket = False
        elif arg.startswith("-"):
            sys.exit(f"check-schema: unknown option {arg!r}")
        else:
            if bucket is None:
                sys.exit("check-schema: list files after --valid or --invalid")
            files.append((arg, bucket))
    if schema is None:
        sys.exit("check-schema: --schema is required")
    if not files:
        sys.exit("check-schema: nothing to check")
    return schema, files


def errors_for(validator, path):
    """Why this file fails the schema, as a list of one-line reasons."""
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except OSError as exc:
        return [f"cannot read: {exc}"]
    except ValueError as exc:
        return [f"not valid JSON: {exc}"]
    return [
        f"{'/'.join(str(p) for p in e.absolute_path) or 'input'}: {e.message}"
        for e in validator.iter_errors(doc)
    ]


def main(argv):
    schema_path, files = parse_args(argv)
    with open(schema_path, encoding="utf-8") as fh:
        schema = json.load(fh)
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)

    failures = []
    for path, should_validate in files:
        problems = errors_for(validator, path)
        if should_validate and problems:
            failures.append(f"{path} should validate, but does not:")
            failures.extend(f"    - {p}" for p in problems[:5])
        elif not should_validate and not problems:
            failures.append(f"{path} validates, but upload-rules.sh rejects it")

    print(f"  {len(files)} file(s) checked against {schema_path}")
    if failures:
        for line in failures:
            print(f"  FAIL: {line}" if not line.startswith("    ") else line)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
