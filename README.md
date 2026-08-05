# Software Bodega

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

## Start here

Clone this repo, then run the launcher for your platform. It asks for a project
folder, sets it up (never destructively), and opens a terminal there with one
agent session that takes it from there.

| Platform | Normal | Unattended test run |
|---|---|---|
| macOS | `Software-Bodega-mac.command` | `Software-Bodega-mac-YOLO.command` |
| Linux | `Software-Bodega-linux.sh` | `Software-Bodega-linux-YOLO.sh` |
| Windows | `Software-Bodega-windows.ps1` | `Software-Bodega-windows-YOLO.ps1` |

On macOS the `.command` files are double-clickable from Finder. Everywhere,
they also take arguments:

```bash
./Software-Bodega-mac.command                     # pick a folder
./Software-Bodega-linux.sh ~/my-project           # skip the picker
./Software-Bodega-linux.sh ~/my-project --no-launch   # set up only
```
```powershell
.\Software-Bodega-windows.ps1 -Dir C:\code\my-project
```

**What YOLO changes:** the human *stops* only — no tool-approval prompts, no
signature gates, no between-station questions. It does **not** relax
verification: the contract stays immutable, tests are never weakened, held-out
exams stay sealed, and the run **stops before merging**. A test that merges
itself has removed the last thing between a bad night and `main`. Point it at a
scratch folder.

### Requirements

- **[oh-my-pi](https://github.com/anthropics/oh-my-pi) (`omp`)** on your PATH — see *Swapping the harness* below if you use something else.
- **git**
- **bash** — the stations are shell scripts. macOS and Linux have it; on Windows install [Git for Windows](https://git-scm.com/download/win) or enable WSL, and the launcher will find it.
- **Python 3.11+** for the Phase C foreman (optional; the shell pipeline runs without it).

### Swapping the harness

Software Bodega is **built for oh-my-pi**, but nothing in the pipeline is tied
to it. Prompts name **roles**, never models, and every role's command lives in
one file — so pointing it at Claude Code, codex, grok, a local llama.cpp
server, or anything else that takes a prompt and returns text is a config edit,
not a rewrite.

The fastest way to switch: open this repo in whatever coding agent you already
use and ask it to swap the harness. Point it at `models.env` and
`foreman/routing.yaml` and say which CLI you want. It will need to work out
four things per role, all of which `scripts/selftest.sh` verifies for you:

1. the non-interactive invocation (most CLIs use `-p` or an `exec` subcommand)
2. whether the prompt goes as an **argument** or on **stdin**
3. whether the CLI needs a permission flag to write files
4. which model family the role resolves to — the judge must not share a family
   with the executor, and the plan reviewer must not share one with the planner

Then run `bash scripts/selftest.sh`. It probes every adapter live and fails
loudly with the reason if one is misconfigured, so you find out in a minute
rather than at 3am. The `## Adapter facts` section below lists the traps that
cost the most time when this was wired up the first time — a new harness will
have its own.

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

## The foreman (Phase C)

Once `foreman/` exists it owns station transitions for the **bootstrap pipeline
only**. The Small Loop stays scripts + CI forever, and the night loop keeps its
own semantics — the foreman invokes `nightshift.sh`, it does not replace it.

```bash
python -m foreman init --probe   # validate routing, contract-test every adapter
python -m foreman status         # where the line is and what is blocking it
python -m foreman gate spec      # run a gate, record the verdict, transition
python -m foreman gate --gc      # discard verdicts not bound to a live artifact
python -m foreman launch         # night shift in a SEALED worktree
python -m foreman resume         # continue after a crash or a BLOCKED state
python -m foreman debrief --notify
```

What the foreman adds that prompts and scripts could not enforce:

| Module | The property it makes mechanical |
|---|---|
| `fsm.py` | Transitions are an enumerated table. Skipping the exam board is not a policy violation — it is a transition that does not exist. |
| `contracts.py` | Verdicts are keyed by content SHA. Edit an approved artifact and its approval is gone, automatically. |
| `contracts.py` | The seal is **physical**: worker sandboxes are sparse-checkout worktrees with the held-out directory absent from disk. |
| `gates.py` | Gates are pure functions over artifacts. The exam gate runs the suite itself, twice — a flaky green is a finding. |
| `router.py` | A same-family judge **raises**. A soft failure here yields a verdict indistinguishable from a real one. |
| `ledger.py` | Exactly one ceiling blocks (rounds); tokens observe and warn. Two blocking ceilings means a night dies for a reason nobody chose. |
| `steps.py` | `kill -9` costs one step, not a night. Memoized by (step, input SHA). |
| `breakers.py` | 3 parks stop the night; 3 empty diffs park a task; the same error 5× parks; 30-minute cooldown then one half-open retry. |
| `workers.py` | One `invoke(role, work_order)`. Judges are structurally incapable of receiving Implementation Notes. |

Run the suite with `python3 -m unittest foreman.tests.test_foreman` (47 tests),
or `bash scripts/selftest.sh` for everything.

## Scripts

| Script | What it does |
|---|---|
| `scripts/selftest.sh` | every mechanical Phase B check. Run before trusting a night. `--offline` skips live model calls. |
| `scripts/bootstrap.sh` | drives SPEC → BLUEPRINT → EXAM → WORKORDER → PLANREVIEW, one fresh session per station, gates between. `--from <stage>` resumes. |
| `scripts/nightshift.sh` | the unattended night loop. |
| `scripts/inspect.sh` | the inspector: suite ×2, held-out suite, tamper audit, scope ledger, SHA-bound verdict. |
| `scripts/runner.sh` `triage.sh` | the Small Loop. |
| `scripts/tests/` | tests for the loop semantics and the held-out seal. |

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
4. **Verification is no-regression, not all-green.** The spec's night loop reads
   as "run the visible tests, repair on fail". Taken literally that parks every
   task but the last, because a walking skeleton cannot make a full suite green.
   A task must instead not *increase* the failing-check count from its own
   baseline; the suite must reach zero by the end, which the inspector enforces
   by running it twice. An unparseable receipt never counts as green.
5. **`scripts/bootstrap.sh` and `scripts/inspect.sh` are additions** to the §2
   tree. The spec names the stations but not a driver for them; without one, the
   pipeline can only be run by hand. Phase C's foreman replaces `bootstrap.sh`.
6. **`foreman/` is ~1,990 lines, not the ~700 the spec estimated.** The extra
   is mostly docstrings explaining *why* each invariant exists and the adapter
   quirks Phase B uncovered. No module was added beyond the ten specified.
7. **A REJECT from the ◈ plan review is repairable.** The planner gets the review
   back and revises, capped at `PLAN_REVISE_CAP` (2) rounds, then escalates to a
   human — hard rule 4 applied to plans. Without this a single REJECT is a dead
   end. The revision prompt forbids resolving objections by downgrading
   qualifiers to `weak`.

## Adapter facts learned the hard way

These are load-bearing and easy to regress, so each has a check in `selftest.sh`:

- **`claude -p` refuses tool use non-interactively** unless given a permission
  mode. Without `--permission-mode acceptEdits` it replies "the write was
  blocked" and produces no artifacts.
- **`--allowedTools` is variadic**, so a prompt passed as a trailing argument is
  swallowed as another tool name. Claude and codex therefore take the prompt on
  **stdin**; grok rejects stdin and takes it as an **argument**. Declared per
  role in `models.env` as `*_INPUT`, never sniffed from the model name.
- **An arg-mode prompt must not start with `-`.** Every skill file opens with
  YAML frontmatter (`---`), so this fires on essentially every worker prompt;
  the CLI exits 2 before the model sees anything, and `--` does not help.
  `run_role` prepends a newline.
- **Adapter stderr must be surfaced.** While `run_role` swallowed it, the above
  bug looked like "the worker returned no valid status block" — every task
  parked, with no clue why.
- **Planner stations legitimately run 25–40 minutes** and are I/O-bound, so low
  CPU is *not* evidence of a hang; check artifact mtimes. `FACTORY_ROLE_TIMEOUT`
  (default 3600s) is the ceiling for a station that has genuinely stopped.
- **`grep -c` prints `0` and exits 1** when it matches nothing, so `|| echo 0`
  appends a second zero. This corrupted both the failure count and a
  pipe-delimited diary field.

## CI, proven end to end

Run against a live private repo (`pomo-factory-ci-proof`, PR #1), both directions:

| | build | visible | held-out | scope | review |
|---|---|---|---|---|---|
| PR body under-declared its diff | pass | pass | pass | **fail** | `NOT DONE` |
| PR body declared it honestly | pass | pass | pass | pass | gates GREEN |

The held-out job printed `held-out checks unpacked: 17` → `Ran 19 tests … OK`,
fetched from the `HELDOUT_TESTS` secret in a repo where those files do not
exist. The scope failure was real: the PR had quietly picked up a change to
`.github/workflows/factory.yml` that its ledger never mentioned.

**Setting it up on a new repo:**

```bash
tar czf - -C factory/tests/heldout . | base64 > heldout.b64
gh secret set HELDOUT_TESTS --repo <owner>/<repo> < heldout.b64
git rm -r --cached factory/tests/heldout    # the builder must not be able to read them
echo 'factory/tests/heldout/' >> .gitignore
```

Pushing a workflow file needs a token with the `workflow` scope — `gh auth
status` will show whether yours has it.

## Known gaps

- **The night shift's held-out seal is prompt-level at Phase B**, as the spec
  intends ("At B: directory never referenced in worker prompts"). The files are
  on disk in the main checkout; only `runner.sh` worktrees seal them physically.
  Phase C seals the night shift too, by sparse-checkout mount.
- **The CI judge needs an API key.** `ANTHROPIC_API_KEY` is unset in the proof
  repo, so the review job posts "mechanical gates GREEN … judge review skipped"
  rather than a verdict. That degradation is deliberate — it never claims SHIP
  without the judge — but subscription CLI auth does not transfer into CI, so a
  real deployment needs a key in secrets for the judge comment to appear.
- **A stale workflow copy is invisible locally.** GitHub rejects an invalid
  workflow by failing a run at 0s with no annotations and no job list, which is
  nearly undebuggable from the API. `selftest.sh` parses the workflow and shell-
  lints every `run:` block precisely so this is caught before pushing — run it
  in the project repo, not just the template.

## Not built, on purpose

No state machine for the Small Loop — scripts and CI, forever. No merge queue
(revisit above ~3 issues/night). No sandboxing beyond git worktrees. No
dashboards. No second frontier judge. No automated mutation testing — **run it
by hand monthly** against the exam suites and check they still kill mutants;
that is the only scheduled manual chore this system has.

`CONTRACT.md` is immutable once signed. A contract that turned out wrong gets a
new contract and a new signature, never a quiet edit.

