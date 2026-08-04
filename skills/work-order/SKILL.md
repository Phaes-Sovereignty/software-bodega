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
**How do I run the visible tests?** `<exact command>`
**What am I allowed to touch?** Only the boundary listed in factory/tasks/<id>.md
**What does done look like?** Visible suite exits 0; status block emitted.
**What if I get stuck?** Emit STATUS: BLOCKED with the specific error. Do not
guess at scope. Do not touch factory/tests/heldout/ (it is not there).

## Slices
<one section per slice, claim + file manifest + how to verify>
```

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
