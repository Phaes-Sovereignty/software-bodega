---
name: work-order
description: Write plan.json as Toulmin slices (claim/grounds/warrant/qualifier/rebuttal) plus HANDOFF.md with Orientation Q&A, then submit the plan for cross-family review.
---

# Station: WORK ORDER

Role: **planner**. Input: `decompose.json` + `CONTRACT.md`.
Output: `factory/.planning/plan.json` + `factory/HANDOFF.md`.

## Why Toulmin

A plan that says "implement the poller" cannot be reviewed — there is nothing to
disagree with. A plan that states its **warrant** ("concurrent polling is safe
here because each endpoint owns its own connection and results merge only at the
aggregate layer") exposes the reasoning, so a reviewer can attack the reasoning
instead of the vocabulary. Weak warrants are where overnight builds die.

## Schema — factory/.planning/plan.json

```json
{
  "slices": [
    {
      "plan_id": "P-T03",
      "claim": "<what this slice will make true>",
      "grounds": {
        "file_manifest": ["src/poller.py", "tests/test_poller.py"],
        "acceptance_criteria": ["AC-3", "AC-5"]
      },
      "warrant": "<why this approach satisfies the claim — the reasoning>",
      "qualifier": "strong | weak",
      "rebuttal": ["<what would have to be true for this to fail>"]
    }
  ]
}
```

- `claim` — the behavior that becomes true. Not the activity performed.
- `grounds.file_manifest` — must be a subset of the task's `boundary`.
- `warrant` — the load-bearing field. If you cannot write one without hand-waving,
  the task is under-specified: say so rather than bluffing.
- `qualifier` — honest self-assessment. `weak` when you are guessing about a
  library's behavior, a protocol detail, or a concurrency model. **`weak` is not
  a failure**; it triggers an executor tier bump for that slice, which is the
  system working. Marking a shaky plan `strong` is the actual failure.
- `rebuttal` — the conditions under which this plan is wrong. At least one per
  slice. "Nothing could go wrong" is never a valid rebuttal.

## HANDOFF.md — Orientation Q&A

The night shift starts each task in a fresh context with no memory. HANDOFF.md
answers the questions it would otherwise waste a turn asking:

```markdown
# HANDOFF

## Orientation Q&A
**Where does the code live?** ...
**How do I run the visible tests?** `$VISIBLE_CMD`, verbatim from toolchain.env
**How do I build?** `$BUILD_CMD`, verbatim (omit the line if it is empty)
**What am I allowed to touch?** Only the boundary listed in factory/tasks/<id>.md
**What does done look like?** The task's `Verify:` command is no worse than the
baseline taken before you started; status block emitted.
**What if I get stuck?** Emit STATUS: BLOCKED with the specific error. Do not
guess at scope. Do not touch `$HELDOUT_DIR` (it is not there).

Quote the DECLARED values, not the defaults. HANDOFF.md is pasted into every
worker prompt, so a `factory/tests/heldout/` written here reaches a Swift
builder that has no such directory — and the real exam sits in
`Tests/HeldoutTests` with nothing telling anyone not to read it.

## Slices
<one section per slice, claim + file manifest + how to verify>
```

## The verification gate — read, not written

The night shift does not guess how this project is built. It reads
`factory/toolchain.env`, written by **`scripts/toolchain.sh resolve`** at the
TOOLCHAIN station, which runs **before the exam board** — the exam board has to
be told where the held-out suite lives, and in a compiled project that is a
build-manifest fact that cannot be decided afterwards.

**You do not author `factory/toolchain.env`.** You read it and you must not
contradict it. If the declared commands are wrong for the plan you are writing,
that is a finding to raise in the plan review, not something to quietly patch
here. (This skill used to tell you to write the file. That ordering is what let
a Swift project receive Python exam instructions.)

The values you will find there, and what they mean for your slices:

```bash
VISIBLE_CMD='swift test --filter VisibleTests'          # the whole visible suite
HELDOUT_CMD='swift test --manifest-cache none --filter HeldoutTests'
BUILD_CMD='swift build'
EXTRA_GATE_CMD='bash scripts/check-target-graph.sh'     # optional, may be empty
FACTORY_ROLE_TIMEOUT=5400                                # compiled builds are slow
```

`HELDOUT_DIR` is the directory the seal removes; your slices must never place a
file inside it, and a `file_manifest` naming it is an automatic REJECT.
`VISIBLE_CMD` is the fallback for tasks whose `Verify:` is `-`; per-task
commands come from `factory/tasks/<id>.md` and are usually a `--filter` slice of
it. `EXTRA_GATE_CMD` runs after every verification and fails it on non-zero —
use it for project invariants that are not tests (target-graph shape, no
circular imports, generated files still in sync). Leave it empty when the
project has no such check; do not invent one to look thorough.

Copy `docs/toolchains/swift.env` as a starting point for Swift projects. Every
command must run from the repo root. Verify each one actually runs before you
write it down — a toolchain.env with a typo parks every task in the build.

## ◈ Plan review — cross-family, mandatory

Submit plan.json to the **plan_judge** role. It must be a different model family
than the plan's author (`assert_cross_family plan_judge planner`). The reviewer
sees the plan artifact only — no transcript, no implementation notes.

Expected verdict form: `Verdict on plan@<sha>: APPROVE | APPROVE WITH NOTES |
REJECT` plus per-slice notes. A `weak` qualifier that the reviewer confirms gets
recorded as a tier bump for that slice in the plan file.

Record the verdict at `factory/.planning/gate-results/plan_review-<sha>.json`.
Verdicts are SHA-bound: if the plan changes, the verdict is stale and discarded.

End with the standard block (`STATION: work-order`).
