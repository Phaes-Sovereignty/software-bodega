#!/usr/bin/env python3
"""Schema validation for the factory's three machine-checked artifacts.

Rule from FACTORY-BUILD.md: add fields, never rename or remove them. So this
validates that required fields are PRESENT and well-typed, and is deliberately
permissive about extra keys.

Phase C's foreman/gates.py imports these validators rather than reimplementing
them, so a schema is defined in exactly one place.

Usage:
    python3 scripts/lib/schemas.py <spec|decompose|plan> <file.json>
    -> prints errors to stderr, exit 0 if valid, 1 if not
"""
from __future__ import annotations

import json
import sys

VALID_CHECKS = {"test", "type", "cli"}
VALID_QUALIFIERS = {"strong", "weak"}


def _req(obj, key, typ, path, errs):
    if key not in obj:
        errs.append(f"{path}: missing required field '{key}'")
        return None
    val = obj[key]
    if not isinstance(val, typ):
        name = typ.__name__ if isinstance(typ, type) else str(typ)
        errs.append(f"{path}.{key}: expected {name}, got {type(val).__name__}")
        return None
    return val


def validate_spec(doc) -> list[str]:
    errs: list[str] = []
    if not isinstance(doc, dict):
        return ["spec: top level must be an object"]
    _req(doc, "actors", list, "spec", errs)
    criteria = _req(doc, "criteria", list, "spec", errs)
    non_goals = _req(doc, "non_goals", list, "spec", errs)

    seen = set()
    for i, c in enumerate(criteria or []):
        p = f"spec.criteria[{i}]"
        if not isinstance(c, dict):
            errs.append(f"{p}: must be an object")
            continue
        cid = _req(c, "id", str, p, errs)
        _req(c, "text", str, p, errs)
        check = _req(c, "check", str, p, errs)
        if check is not None and check not in VALID_CHECKS:
            errs.append(f"{p}.check: '{check}' not in {sorted(VALID_CHECKS)}")
        if cid:
            if cid in seen:
                errs.append(f"{p}.id: duplicate id '{cid}'")
            seen.add(cid)

    for i, g in enumerate(non_goals or []):
        p = f"spec.non_goals[{i}]"
        if not isinstance(g, dict):
            errs.append(f"{p}: must be an object")
            continue
        _req(g, "id", str, p, errs)
        _req(g, "text", str, p, errs)
    return errs


def validate_decompose(doc) -> list[str]:
    errs: list[str] = []
    if not isinstance(doc, dict):
        return ["decompose: top level must be an object"]
    tasks = _req(doc, "tasks", list, "decompose", errs)

    ids = set()
    for i, t in enumerate(tasks or []):
        p = f"decompose.tasks[{i}]"
        if not isinstance(t, dict):
            errs.append(f"{p}: must be an object")
            continue
        tid = _req(t, "id", str, p, errs)
        _req(t, "goal", str, p, errs)
        _req(t, "boundary", list, p, errs)
        _req(t, "depends", list, p, errs)
        _req(t, "exam_refs", list, p, errs)
        ce = _req(t, "context_estimate", int, p, errs)
        if ce is not None and ce <= 0:
            errs.append(f"{p}.context_estimate: must be positive")
        if tid:
            if tid in ids:
                errs.append(f"{p}.id: duplicate id '{tid}'")
            ids.add(tid)

    # referential integrity: depends must name real tasks
    for i, t in enumerate(tasks or []):
        if not isinstance(t, dict):
            continue
        for d in t.get("depends", []) or []:
            if d not in ids:
                errs.append(f"decompose.tasks[{i}].depends: unknown task '{d}'")
    return errs


def validate_plan(doc) -> list[str]:
    errs: list[str] = []
    if not isinstance(doc, dict):
        return ["plan: top level must be an object"]
    slices = _req(doc, "slices", list, "plan", errs)

    for i, s in enumerate(slices or []):
        p = f"plan.slices[{i}]"
        if not isinstance(s, dict):
            errs.append(f"{p}: must be an object")
            continue
        _req(s, "plan_id", str, p, errs)
        _req(s, "claim", str, p, errs)
        _req(s, "warrant", str, p, errs)
        q = _req(s, "qualifier", str, p, errs)
        if q is not None and q not in VALID_QUALIFIERS:
            errs.append(f"{p}.qualifier: '{q}' not in {sorted(VALID_QUALIFIERS)}")
        reb = _req(s, "rebuttal", list, p, errs)
        if reb is not None and len(reb) == 0:
            # "nothing could go wrong" is never a valid rebuttal
            errs.append(f"{p}.rebuttal: must list at least one failure condition")
        g = _req(s, "grounds", dict, p, errs)
        if isinstance(g, dict):
            _req(g, "file_manifest", list, f"{p}.grounds", errs)
            _req(g, "acceptance_criteria", list, f"{p}.grounds", errs)
    return errs


VALIDATORS = {
    "spec": validate_spec,
    "decompose": validate_decompose,
    "plan": validate_plan,
}


def validate_file(kind: str, path: str) -> list[str]:
    if kind not in VALIDATORS:
        return [f"unknown schema kind '{kind}' (want one of {sorted(VALIDATORS)})"]
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return [f"{path}: no such file"]
    except json.JSONDecodeError as exc:
        return [f"{path}: invalid JSON — {exc}"]
    return VALIDATORS[kind](doc)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    errs = validate_file(argv[1], argv[2])
    for e in errs:
        print(f"  ✗ {e}", file=sys.stderr)
    return 1 if errs else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
