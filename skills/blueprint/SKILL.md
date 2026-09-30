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
- `verify`: the exact command that proves *this task* works — the narrowest
  slice of the visible suite that covers its `exam_refs`. Omit it (or write
  `-`) and the night shift falls back to the whole visible suite.

## `verify` — the narrowest command that can fail for this task

The night shift takes a baseline before the task runs and re-runs the same
command after, then applies the no-regression rule. A whole-suite command makes
that comparison noisy: unrelated red elsewhere in the repo drowns the signal
this task is judged on, and a slow suite is paid once per repair attempt.

Write the filter that matches the tests covering this task's `exam_refs`:

| Toolchain | `verify` |
|---|---|
| Swift (SwiftPM) | `swift test --filter VisibleTests.PollerTests` |
| Swift (Xcode) | `xcodebuild test -scheme App -only-testing:VisibleTests/PollerTests` |
| Python | `python -m pytest tests/test_poller.py -q` |
| Node | `npm test -- tests/poller.test.js` |

The command must be runnable from the repo root and must exercise **visible**
tests only. Never reference the held-out directory — `HELDOUT_DIR` from
`factory/toolchain.env` (ask `bash scripts/toolchain.sh get HELDOUT_DIR`; it is
`Tests/HeldoutTests` in a Swift package, not `factory/tests/heldout`). It is not
in the builder's checkout, and a task whose verify command needs it can never
pass.

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
      "verify": "python -m pytest tests/test_health.py -q",
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
- [ ] every `verify` command names visible tests only — no path under
      `$HELDOUT_DIR` (as declared in `factory/toolchain.env`) appears in any
      of them

Also write `factory/tasks/<id>.md` per task — the night shift reads these, not
the JSON. One `Key: value` per line, exactly these keys:

```
Id: T03
Goal: poll every endpoint concurrently and merge results
Boundary: src/poller.py, tests/test_poller.py
Depends: T01, T02
Exam_refs: AC-3, AC-5
Verify: python -m pytest tests/test_poller.py -q
Risk: low
```

`Verify:` is read verbatim as a shell command, so keep it on one line. `-`
means "use the project-wide visible suite".

End with the standard block (`STATION: blueprint`).
