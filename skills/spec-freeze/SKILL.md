---
name: spec-freeze
description: Turn a signed BRIEF.md into factory/.planning/spec.json where every acceptance criterion is machine-checkable. Runs the spec gate.
---

# Station: SPEC FREEZE

Role: **planner**. No human in the loop. Input: `factory/BRIEF.md` (signed).
Output: `factory/.planning/spec.json`.

## The one rule

**Every criterion must be checkable by a machine.** Each carries a `check` kind:

| check | means | example |
|---|---|---|
| `test` | an automated test asserts it | "a dead endpoint is marked down within 2 poll cycles" |
| `type` | the type system / schema enforces it | "config rejects a non-integer port at load" |
| `cli` | running a command and inspecting output/exit code proves it | "`GET /api/summary` returns aggregate tok_s within 200ms" |

If you cannot assign a check kind, the criterion is prose, not a criterion.
Rewrite it until it is observable, or drop it to a non-goal. Never invent a
criterion the brief does not support — if the brief is silent on something
important, emit `STATUS: NEEDS_CONTEXT` and name the gap.

Criteria must be **observable from outside**: about behavior, not about how the
code is organized. "Poller uses asyncio" is not a criterion. "Polling 4
endpoints where one hangs still serves /api/summary in <1s" is.

## Schema — factory/.planning/spec.json

```json
{
  "actors": ["operator", "cron"],
  "criteria": [
    {"id": "AC-1", "check": "cli",  "text": "<observable behavior>"},
    {"id": "AC-2", "check": "test", "text": "<observable behavior>"}
  ],
  "non_goals": [
    {"id": "NG-1", "text": "<from the brief>"}
  ]
}
```

Add fields if you must; never rename or remove them. IDs are stable forever —
tasks, exams, and verdicts all reference them.

## spec_gate (checklist here at Phase B; a pure function at Phase C)

- [ ] valid JSON, matches the schema above
- [ ] every criterion has `id`, `check` ∈ {test,type,cli}, non-empty `text`
- [ ] `non_goals` is **non-empty** (an empty non-goals list means the interview
      failed to bound the work — go back, do not proceed)
- [ ] every NG-N from BRIEF.md appears
- [ ] no criterion describes implementation rather than behavior

Report each checklist line as pass/fail explicitly. A gate you did not run is
a gate that failed.

End your output with the standard block (`STATION: spec-freeze`).
