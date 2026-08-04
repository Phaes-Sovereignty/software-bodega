# factory-app

A personal AI software factory. It turns an idea into verified, reviewed code
with about four human touches per project and roughly ten minutes a day after
that.

Two pipelines live here:

- **Bootstrap** (once per project): INTERVIEW → SPEC → BLUEPRINT → EXAM BOARD →
  WORK ORDER → NIGHT SHIFT → INSPECTOR. Produces a walking skeleton, two exam
  suites, and a backlog of small issues.
- **Small Loop** (forever after): issue → triage → worker opens a PR → CI runs
  visible **and held-out** exams → a cross-family judge posts a verdict → you
  merge. Scripts and CI only — there is deliberately no state machine here.

## Run a project through it

```bash
# 0. one-time: check every headless adapter answers
bash scripts/selftest.sh

# 1. INTERVIEW — the only conversational stage (~30 min)
#    Load skills/factory-interview/SKILL.md in your interactive agent.
#    Output: factory/BRIEF.md              ◉ you sign it

# 2-3. SPEC + BLUEPRINT — no human
#    skills/spec-freeze  -> factory/.planning/spec.json
#    skills/blueprint    -> factory/.planning/decompose.json + factory/tasks/*.md

# 4. EXAM BOARD — fresh, spec-blind session
#    skills/exam-board   -> factory/CONTRACT.md + tests/visible + tests/heldout
#                                                  ◉ you sign CONTRACT.md

# 5. WORK ORDER + cross-family plan review
#    skills/work-order   -> factory/.planning/plan.json + factory/HANDOFF.md
#                                                  ◈ codex reviews the plan

# 6. NIGHT SHIFT — unattended                      ◉ you type go, then sleep
bash scripts/nightshift.sh

# 7. INSPECTOR — before you wake up
#    skills/inspector    -> factory/REVIEW.md ("Verdict on <SHA>: SHIP|FIX FIRST|NOT DONE")
#                                                  ◉ you merge
```

Then you are in the Small Loop:

```bash
bash scripts/triage.sh     # classify new issues: ready | needs-info
bash scripts/runner.sh     # oldest ready issue -> branch -> PR. Never merges.
```

## What is where

| Path | What it holds |
|---|---|
| `factory/STATE.md` | current stage. Single source of truth. |
| `factory/{BRIEF,BLUEPRINT,CONTRACT,HANDOFF,REVIEW,GUIDE}.md` | station outputs |
| `factory/.planning/*.json` | machine-checked artifacts (spec, decompose, plan) |
| `factory/.planning/gate-results/` | `<gate>-<sha>.json` verdicts, SHA-bound |
| `factory/tasks/*.md` | one file per task — what the night shift reads |
| `factory/tests/visible/` | the builder sees these and drives TDD against them |
| `factory/tests/heldout/` | **the builder never sees these** |
| `factory/progress.md` `log.md` | append-only diaries. Never rewritten. |
| `skills/` | the eight station prompts. Roles only, no model names. |
| `scripts/` | night shift, small loop runner, triage, status parser |

## The held-out seal

The single most important mechanism here. Held-out exams only mean something if
the builder physically cannot read them:

- **Worker worktrees** are created with `git sparse-checkout` excluding
  `factory/tests/heldout/`, then the directory is removed for good measure.
  `runner.sh` aborts if the directory exists anyway.
- **CI** fetches the held-out suite from the `HELDOUT_TESTS` repo secret
  (base64 tarball) at run time. If the secret is missing, the job **fails** —
  it does not skip. Missing evidence is never a pass.
- **CI** also fails any PR whose diff touches `factory/tests/heldout/`.

Three independent nets sit behind every change: visible exams the builder must
pass, held-out exams it cannot see, and a cross-family judge plus your merge
button. Nothing self-merges.

## Configuring models

`models.env` maps **roles** to CLIs. Prompt files never name a model, so
swapping providers is a one-file edit:

| Role | Family | Command |
|---|---|---|
| executor | xai | `grok -p` |
| planner | anthropic | `claude -p --output-format json` |
| judge | anthropic | `claude -p --output-format json` |
| plan_judge | openai | `codex exec --skip-git-repo-check` |
| glue / triage | xai / anthropic | as configured |

Independence invariants, enforced by `assert_cross_family` in
`scripts/lib/status.sh`: the judge must not share a family with the executor,
and the plan reviewer must not share one with the plan's author.

## Deviations from FACTORY-BUILD.md

Recorded per §5. Each is the smallest working alternative.

1. **Grok CLI headless mode exists**, so the conditional xAI-API fallback in §1
   does not apply. Verified at build time: `grok -p "<prompt>"` returns a
   parseable result non-interactively. No `XAI_API_KEY` is needed.
2. **`shellcheck` is not installed** on this machine. `bash -n` runs on every
   script in `scripts/selftest.sh` and in CI, which is the mandatory half of
   that check; the shellcheck pass is marked optional in the spec ("if
   available"). Install with `brew install shellcheck` to enable it.
3. **The companion docs name a different stack** (`omp`, GLM-5.2,
   DeepSeek-V4-Flash, ralph) than FACTORY-BUILD.md §1 (claude / grok / codex).
   §1 says "configure exactly this", so §1 wins. `runner.sh` invokes the
   `executor` role rather than the `omp -p worker` named in the §2 tree comment.
   Switching to GLM/DeepSeek later is a `models.env` edit — no prompt changes.
4. **Test-count parsing is best-effort.** `test_counts` reads TAP-ish and
   pytest-ish output; an unrecognized format records `?/?` rather than guessing.
   The exit code, not the count, is what gates anything.

## Not built, on purpose

No state machine for the Small Loop — scripts and CI, forever. No merge queue
(revisit above ~3 issues/night). No sandboxing beyond git worktrees. No
dashboards. No second frontier judge. No automated mutation testing — **run it
by hand monthly** against the exam suites and check they still kill mutants;
that is the only scheduled manual chore this system has.

`CONTRACT.md` is immutable once signed. A contract that turned out wrong gets a
new contract and a new signature, never a quiet edit.
