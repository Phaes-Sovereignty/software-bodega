---
name: blueprint
description: Turn spec.json into a task DAG (decompose.json) — walking skeleton first, each task sized to one context window, ADR for every high-risk task.
---

# Station: BLUEPRINT

Role: **planner**. Input: `factory/.planning/spec.json`.
Output: `factory/.planning/decompose.json` + `factory/BLUEPRINT.md` + one file
per task in `factory/tasks/`.

## Skeleton first — non-negotiable ordering

T01 is always a **walking skeleton**: the thinnest end-to-end slice that runs,
has a health check, and has CI green. Not "set up the project" — something that
executes. Every later task extends a system that already works, so a failure at
T04 is a broken feature, not a broken repo.

Everything not needed for the skeleton + the core criteria goes to **backlog**
(`backlog: true`). Those become issues for the Small Loop, not tonight's work.
Be aggressive here. A bootstrap that builds 5 tasks and files 6 issues beats one
that tries 11 tasks overnight and parks 7.

## Sizing — one context window each

A task fits one context window when a fresh agent can read its boundary files,
write the code, and run the tests without ever needing to ask what happened
before. Signals you must split a task:
- boundary touches more than ~6 files
- goal contains "and" joining two behaviors
- `context_estimate` exceeds the cap in `models.env` (`CONTEXT_ESTIMATE_CAP`)

`context_estimate` is your honest token estimate for the whole task attempt
(files read + code written + test output), not the size of the diff.

## Boundary and depends

- `boundary`: the exact file paths this task may create or modify. The night
  shift commits only these paths. A task that needs a file outside its boundary
  is mis-decomposed — fix the DAG, do not widen the boundary to "src/".
- `depends`: task IDs that must be DONE first. The graph must be **acyclic**.
- `exam_refs`: the AC-N ids this task is responsible for satisfying.

## Risk and ADRs

Mark `risk: high` when a task involves concurrency, data migration, an external
protocol, or anything where a wrong choice is expensive to reverse. Every
`risk: high` task gets an ADR at `factory/adr/ADR-<n>.md` (context / options
considered / decision / consequences) and links it via `adr: "ADR-1"`.

## Schema — factory/.planning/decompose.json

```json
{
  "tasks": [
    {
      "id": "T01",
      "goal": "<one sentence, one behavior>",
      "boundary": ["src/app.py", "tests/test_health.py"],
      "depends": [],
      "exam_refs": ["AC-1"],
      "context_estimate": 18000,
      "risk": "low",
      "backlog": false
    }
  ]
}
```

## decompose_gate

- [ ] DAG is acyclic; task order is dependency-respecting
- [ ] **AC coverage both directions**: every AC-N in spec.json appears in some
      task's `exam_refs`, AND every `exam_refs` entry names a real AC-N
- [ ] every `context_estimate` < `CONTEXT_ESTIMATE_CAP`
- [ ] T01 is a walking skeleton with a health check
- [ ] every `risk: high` task has an `adr` that points at a file that exists
- [ ] boundaries do not overlap between tasks that can run in parallel

Also write `factory/tasks/<id>.md` per task (id, goal, boundary, depends,
exam_refs) — the night shift reads these, not the JSON.

End with the standard block (`STATION: blueprint`).
