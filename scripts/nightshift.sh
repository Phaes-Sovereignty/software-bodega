#!/usr/bin/env bash
# nightshift.sh — the bootstrap night loop.
#
# Picks the highest-priority ready task, runs the executor on it in a fresh
# session, verifies against the visible suite, repairs up to REPAIR_CAP, then
# resamples N=3 (execution-selected), then PARKs. Commits per task with
# selective adds. Exits on the dual condition: all tasks resolved AND the last
# status block carries EXIT_SIGNAL: true.
#
# Usage: bash scripts/nightshift.sh [--dry-run] [--max-iters N] [--help]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"

cd "$FACTORY_ROOT" || exit 1

# The verification arithmetic (fail_count, swift_fail_count, test_counts,
# verify_ok) lives in scripts/lib/verify.sh so fix-round.sh and the behaviour
# tests use the SAME parser the loop does. It used to be duplicated there with a
# python-unittest-only grep, which read a Swift receipt as "0 failures" and
# called a broken build a pass.
# shellcheck source=lib/verify.sh
. "$HERE/lib/verify.sh"

DRY_RUN=0
MAX_ITERS=${MAX_ITERS:-40}
# VISIBLE_CMD/HELDOUT_CMD/BUILD_CMD/HELDOUT_DIR arrive from
# scripts/lib/toolchain.sh (sourced by status.sh). Defaulting them again here is
# how two answers to "where are the tests" could coexist.
REPAIR_CAP="${REPAIR_CAP:-2}"
RESAMPLE_N="${RESAMPLE_N:-3}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"
# The ladder's resample rung may carry its own N. Keep the operator's value so
# each task re-derives from it instead of compounding the previous task's rung.
RESAMPLE_N_DEFAULT="${RESAMPLE_N:-3}"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --max-iters) MAX_ITERS="$2"; shift ;;
    --help|-h)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

WORKDIR="$(mktemp -d)"
LOOP_START_SHA="$(git rev-parse HEAD 2>/dev/null || echo "")"

# --- salvage on kill: never discard uncommitted work -----------------------
salvage() {
  local rc=$?
  if [ -n "$LOOP_START_SHA" ] && ! git diff --quiet HEAD 2>/dev/null; then
    local br="wip/salvage-$(date -u +%Y%m%dT%H%M%SZ)"
    echo "[nightshift] killed with uncommitted work — salvaging to $br" >&2
    git checkout -q -b "$br" 2>/dev/null
    # -A is deliberate here and ONLY here: salvage must lose nothing.
    #
    # EXCEPT the sandbox directory. A leftover .foreman-sandbox/ (from a
    # --keep-sandbox run, or from running the loop in the main checkout while a
    # sealed launch sits next to it) is a nested git WORKTREE, and `git add -A`
    # records it as a gitlink — a mode-160000 entry with no submodule config.
    # The branch then looks like it contains a project inside the project, and
    # the next `git add` of that path fails outright. Losing nothing means losing
    # no WORK, not preserving a checkout artifact.
    git add -A -- . ':(exclude).foreman-sandbox' && git commit -q -m "factory: salvage WIP from interrupted night shift" 2>/dev/null
    log_append "nightshift" "salvage" "$br"
  fi
  rm -rf "$WORKDIR"
  exit $rc
}
trap salvage INT TERM

# --- task graph ------------------------------------------------------------

task_ids() { ls -1 factory/tasks/*.md 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.md$//' | sort; }

task_field() { # task_field <id> <Field>
  awk -v k="$2" -F': *' 'tolower($1)==tolower(k){sub(/^[^:]*: */,"");print;exit}' "factory/tasks/$1.md" 2>/dev/null
}

# resolved = terminal state recorded in the append-only diary
task_resolved() {
  grep -qE "^$1\|(DONE|PARKED)\|" factory/progress.md 2>/dev/null
}
task_done() {
  grep -qE "^$1\|DONE\|" factory/progress.md 2>/dev/null
}

deps_satisfied() {
  local d
  for d in $(task_field "$1" "Depends" | tr ',' ' '); do
    [ -z "$d" ] && continue
    [ "$d" = "-" ] && continue
    task_done "$d" || return 1
  done
  return 0
}

next_task() {
  local id
  for id in $(task_ids); do
    task_resolved "$id" && continue
    deps_satisfied "$id" || continue
    printf '%s' "$id"; return 0
  done
  return 1
}

all_resolved() {
  # A night with NO task files is not "all tasks resolved" — it is a night that
  # never saw the plan. This function used to return 0 on an empty list, so when
  # bootstrap's artifacts were uncommitted (and therefore absent from the sealed
  # worktree, which is built from HEAD) the loop exited in one iteration reporting
  # `all tasks resolved` and STATUS: DONE, and the launch printed 0 commits as
  # though a night had happened. Zero inputs must be a BLOCKED condition.
  local id n=0
  for id in $(task_ids); do
    n=$((n + 1))
    task_resolved "$id" || return 1
  done
  [ "$n" -gt 0 ]
}

# --- verification ----------------------------------------------------------

# run_visible <receipt> [cmd] : run the verification command, output to <receipt>.
#
# `cmd` overrides the project-wide VISIBLE_CMD so a task can be gated on the
# slice of the suite it is responsible for — e.g. `swift test --filter T03`
# from the work order — instead of the whole thing. The SAME command must be
# used for a task's baseline and its post-check, or the no-regression
# comparison is measuring two different sets.
#
# EXTRA_GATE_CMD (from factory/toolchain.env) is a project-level invariant that
# runs alongside every verification — a target-graph check, a lint, a schema
# check. It fails the task even when the tests are green.
run_visible() {
  local out="$1" cmd="${2:-$VISIBLE_CMD}" rc
  if [ -z "$cmd" ] || { [ "$cmd" = "bash factory/tests/run-visible.sh" ] && [ ! -f factory/tests/run-visible.sh ]; }; then
    echo "no verification command — cannot verify" > "$out"; return 127
  fi
  ( eval "$cmd" ) > "$out" 2>&1; rc=$?
  if [ -n "${EXTRA_GATE_CMD:-}" ]; then
    printf '\n--- extra gate: %s ---\n' "$EXTRA_GATE_CMD" >> "$out"
    if ! ( eval "$EXTRA_GATE_CMD" ) >> "$out" 2>&1; then
      printf '** EXTRA GATE FAILED **\n' >> "$out"
      [ "$rc" = "0" ] && rc=1
    fi
  fi
  return $rc
}

# task_verify_cmd <task_id> : the task's own verification command, if the work
# order gave it one (a `Verify:` line in factory/tasks/<id>.md).
task_verify_cmd() {
  local v; v="$(task_field "$1" "Verify")"
  case "$v" in ""|"-") printf '%s' "$VISIBLE_CMD" ;; *) printf '%s' "$v" ;; esac
}


# --- worker prompt ---------------------------------------------------------

build_prompt() { # build_prompt <task_id> [repair_context_file]
  local id="$1" repair="${2:-}"
  cat skills/night-task/SKILL.md
  printf '\n\n===== YOUR TASK =====\n'
  cat "factory/tasks/$id.md"
  printf '\n\n===== HANDOFF =====\n'
  sed -n '1,120p' factory/HANDOFF.md 2>/dev/null
  printf '\n\n===== CONTRACT =====\n'
  sed -n '1,120p' factory/CONTRACT.md 2>/dev/null
  # The task's own command, not the project-wide suite: this is exactly what the
  # gate re-runs afterwards. Telling the worker to run something broader means
  # it optimises for a signal it is not judged on — and on a compiled project it
  # pays the full build every iteration for no reason.
  printf '\n\n===== HOW TO VERIFY =====\nRun: %s\n' "$(task_verify_cmd "$id")"
  [ -n "${BUILD_CMD:-}" ] && printf 'Build with: %s\n' "$BUILD_CMD"
  [ -n "${EXTRA_GATE_CMD:-}" ] && \
    printf 'This also runs and must pass: %s\n' "$EXTRA_GATE_CMD"
  if [ -n "$repair" ] && [ -f "$repair" ]; then
    printf '\n\n===== PREVIOUS ATTEMPT FAILED — REPAIR =====\n'
    printf 'The visible suite did not pass. Fix the cause, not the test.\n\n'
    tail -c 4000 "$repair"
  fi
  printf '\n\nWork in the repository at %s. Edit files directly. Do not commit.\n' "$FACTORY_ROOT"
  printf 'End your response with the FACTORY_STATUS block.\n'
}

attempt() { # attempt <task_id> <outfile> [repair_ctx] [role] -> exit status
  # The role defaults to executor but is set by the escalation ladder: rung 1 is
  # the planner, rung 2 the plan_judge, rung 3 the local fallback. Whoever the
  # rung names, that family is recorded as an AUTHOR of the tree — the inspector
  # picks its judge from that set, which is the only way "Opus fixed it, Opus
  # judged it" can be caught.
  local id="$1" out="$2" repair="${3:-}" role="${4:-executor}" prompt
  prompt="$(build_prompt "$id" "$repair")"
  if [ "$DRY_RUN" = "1" ]; then
    status_emit "night-task" "$id" "DONE" "dry-run: no $role invoked" \
      "TESTS: 0/0" "FILES: -" "EXIT_SIGNAL: false" > "$out"
    return 0
  fi
  run_role "$role" "$prompt" > "$out" 2>>factory/log.md
}

# --- resample: N parallel worktrees, execution-selected --------------------

resample() { # resample <task_id> -> 0 if a winner was merged
  local id="$1" i pids=() dirs=() base RS_CMD
  RS_CMD="$(task_verify_cmd "$id")"
  base="$(git rev-parse HEAD)"
  echo "[nightshift] $id: resampling N=$RESAMPLE_N (execution-selected)" >&2
  log_append "nightshift" "resample_start" "$id N=$RESAMPLE_N"
  # Sample receipts live OUTSIDE the worktree. Written inside it they become
  # untracked files in the sample's own tree, which makes every sample look
  # dirty to the did-it-do-anything check below and puts the receipts
  # themselves into the winner's patch.
  for i in $(seq 1 "$RESAMPLE_N"); do
    local wt="$WORKDIR/rs-$id-$i" sp="$WORKDIR/sample-$id-$i"
    git worktree add -q --detach "$wt" "$base" 2>/dev/null || continue
    dirs+=("$wt")
    (
      cd "$wt" || exit 1
      FACTORY_ROOT="$wt" run_role executor "$(build_prompt "$id")" \
        > "$sp.out" 2>/dev/null
      # run_visible, not a bare eval: the sample has to face the SAME gate as
      # the attempt it is replacing, extra gate included. Judging samples by a
      # weaker standard is how a task that breaks a project invariant fails the
      # main path and then wins on resample. cwd is the worktree, so the gate
      # runs against this sample's tree.
      run_visible "$sp.test" "$RS_CMD"
      echo $? > "$sp.rc"
      LAST_TEST_RC=$(cat "$sp.rc")
      fail_count "$sp.test" > "$sp.fails"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null

  # Execution-selected: the winner is decided by test results, not by reading the
  # samples. Same no-regression rule the main path uses.
  local wt rc fails sp
  for wt in "${dirs[@]}"; do
    sp="$WORKDIR/sample-$id-${wt##*-}"
    rc="$(cat "$sp.rc" 2>/dev/null || echo 1)"
    fails="$(cat "$sp.fails" 2>/dev/null || echo 999)"
    # A sample that changed nothing is not a fix, it is an absence of work —
    # and doing nothing trivially satisfies no-regression, so without this it
    # WINS. The main path already refuses to credit an empty diff (the circuit
    # breaker); the resample path has to hold the same line.
    if [ -z "$( cd "$wt" && git status --porcelain 2>/dev/null | head -1 )" ]; then
      echo "[nightshift] $id: sample $(basename "$wt") changed nothing — not a winner" >&2
      log_append "nightshift" "resample_empty" "$id $(basename "$wt") produced no diff"
      continue
    fi
    if verify_ok "${BASE_FAILS:-999}" "$fails" "$rc"; then
      echo "[nightshift] $id: sample $(basename "$wt") won ($fails failing vs baseline ${BASE_FAILS:-?})" >&2
      # Port the winner in. `git add -A` first: a file the sample CREATED is
      # untracked and invisible to plain `git diff`, which used to leave the
      # patch empty and fall through to a tar copy of the whole worktree — and
      # that copied the sample's stale factory/ bookkeeping over the live one,
      # erasing the night's log and progress diary. Never restore factory/ from
      # a sample: the loop owns it, the task does not.
      ( cd "$wt" && git add -A >/dev/null 2>&1
        git diff --cached "$base" -- . ':(exclude)factory' ) > "$WORKDIR/winner.patch" 2>/dev/null
      if [ -s "$WORKDIR/winner.patch" ]; then
        git apply --whitespace=nowarn "$WORKDIR/winner.patch" 2>/dev/null || true
      fi
      log_append "nightshift" "resample_win" "$id $(basename "$wt")"
      for wt in "${dirs[@]}"; do git worktree remove --force "$wt" 2>/dev/null; done
      return 0
    fi
  done
  log_append "nightshift" "resample_fail" "$id all $RESAMPLE_N samples failed"
  for wt in "${dirs[@]}"; do git worktree remove --force "$wt" 2>/dev/null; done
  return 1
}

# --- escalation ladder -----------------------------------------------------
#
# climb_ladder <task_id> <status_file> <test_receipt> -> 0 when the verify now
# passes, 1 when every rung was spent.
#
# Rung 0 is the resample the loop already ran, so this starts at index 1. Each
# rung is a NEW HYPOTHESIS, chosen by routing.yaml / models.env:
#
#   single:planner      the model that wrote the spec, with tools
#   single:plan_judge   a third family
#   single:fallback     a fourth family, local, for when hosted quota dies
#
# Two invariants the old code did not have:
#   * The ladder fires on a VERIFY FAILURE and nothing else (may_escalate).
#   * Before a rung runs, the tree is reset to the task's baseline. Otherwise a
#     failed planner attempt leaves its damage for the next family to trip over,
#     and the baseline count no longer describes what is on disk.
climb_ladder() { # climb_ladder <task_id> <SF> <TO> <task_cmd> <base_fails> [start_rung]
  local id="$1" sf="$2" to="$3" cmd="$4" base="$5"
  local rung_spec strategy role out rc fails i
  i="${6:-1}"
  while rung_spec="$(ladder_rung "$i")"; do
    strategy="$(rung_field "$rung_spec" 1)"
    role="$(rung_field "$rung_spec" 2)"
    if ! may_escalate "verify_failure"; then
      log_append "nightshift" "ladder_refused" "$id rung $i reason_not_verify_failure"
      return 1
    fi
    # An unset role command must SKIP, not fail. `role_cmd` prints the empty
    # string and returns 0 for `GLUE_CMD=''`, so testing the exit status alone
    # let unconfigured rungs through to run_role, which then produced no status
    # block and burned the rung.
    if [ -z "$(role_cmd "$role" 2>/dev/null)" ]; then
      echo "[nightshift] $id: ladder rung $i ($role) has no command — skipping" >&2
      log_append "nightshift" "ladder_skip" "$id rung $i $role unconfigured"
      i=$((i + 1)); continue
    fi
    echo "[nightshift] $id: escalation rung $i — $strategy via $role ($(role_family "$role"))" >&2
    log_append "nightshift" "ladder_start" "$id rung $i $strategy $role"
    # Reset the tree to the pre-task state so this family starts where the
    # baseline was measured. factory/ is excluded for the same reason the park
    # path excludes it: the diary belongs to the loop, not to the task.
    git checkout -q -- . ':(exclude)factory' 2>/dev/null
    git clean -qfd --exclude=factory 2>/dev/null
    out="$WORKDIR/$id.rung$i"
    attempt "$id" "$out" "$to" "$role"
    if ! status_valid "$out" 2>/dev/null; then
      echo "[nightshift] $id: rung $i ($role) returned no status block" >&2
      log_append "nightshift" "ladder_no_status" "$id rung $i $role"
      i=$((i + 1)); continue
    fi
    if [ "$(status_field "$out" STATUS)" != "DONE" ]; then
      log_append "nightshift" "ladder_blocked" "$id rung $i $role $(status_field "$out" STATUS)"
      i=$((i + 1)); continue
    fi
    run_visible "$to" "$cmd"; rc=$?; LAST_TEST_RC=$rc
    fails="$(fail_count "$to")"
    if verify_ok "$base" "$fails" "$rc"; then
      echo "[nightshift] $id: rung $i ($role) cleared the verify ($fails failing vs $base)" >&2
      log_append "nightshift" "ladder_win" "$id rung $i $role family $(role_family "$role")"
      # The rung's own status block becomes the task's: commit_task reads FILES
      # from it, and the summary line records which family actually shipped it.
      cp "$out" "$sf"
      record_author_family "$(role_family "$role")"
      return 0
    fi
    echo "[nightshift] $id: rung $i ($role) still failing ($fails vs baseline $base)" >&2
    log_append "nightshift" "ladder_fail" "$id rung $i $role $fails vs $base"
    record_author_family "$(role_family "$role")"
    i=$((i + 1))
  done
  return 1
}

# --- commit ----------------------------------------------------------------

commit_task() { # commit_task <task_id> <status_file> -> prints SHA or -
  # Seal enforcement, at the one point where the loop still has authority.
  #
  # Only when the launcher DECLARED the tree sealed (BODEGA_SEALED=1, set by
  # `foreman launch`). A plain nightshift.sh run in the main checkout has no
  # sparse patterns to check, so requiring them there would refuse every commit
  # and break a path that works today.
  #
  # What it catches: a worker that loosens the seal mid-task — `git
  # sparse-checkout disable`, measured — cannot then have its work committed.
  # The task parks and log.md records seal_broken: evidence, not a shrug.
  # Detection, not containment; the README states the difference.
  local id="$1" sf="$2" files f added=0
  if [ "${SEAL_MODE:-none}" = "physical" ] && ! seal_intact "$FACTORY_ROOT"; then
    echo "[nightshift] SEAL NOT INTACT — refusing to commit $id" >&2
    log_append "nightshift" "seal_broken" "$id heldout=$HELDOUT_DIR"
    # A DISTINCT sentinel. Returning "-" here would land in the empty-diff
    # branch and park the task as "no file changes produced" — a wrong
    # diagnosis for a security event, and one that also feeds the no-progress
    # circuit breaker, so a broken seal could quietly stop the whole night.
    printf '%s' "SEAL_BROKEN"
    return 1
  fi
  files="$(status_field "$sf" FILES)"
  if [ -z "$files" ] || [ "$files" = "-" ]; then
    files="$(task_field "$id" "Boundary")"
  fi
  # SELECTIVE ADD ONLY — never -A (hard rule; salvage is the sole exception)
  for f in $(printf '%s' "$files" | tr ',' ' '); do
    [ -e "$f" ] || continue
    git add -- "$f" 2>/dev/null && added=1
  done
  if [ "$added" = "0" ] || git diff --cached --quiet; then printf '%s' "-"; return 1; fi
  git commit -q -m "factory: $id — $(status_field "$sf" SUMMARY)" 2>/dev/null
  git rev-parse --short HEAD
}

# --- main loop -------------------------------------------------------------

state_set "NIGHT_SHIFT" "loop started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log_append "nightshift" "start" "max_iters=$MAX_ITERS dry_run=$DRY_RUN"
# Report the ACTUAL seal state, measured, not the flag we were handed. A launcher
# can set BODEGA_SEALED=1 and still point at a tree where the exam is readable
# (wrong FACTORY_ROOT, a failed sparse-checkout, an older git), and asserting
# "sealed" from a flag is how the hole stayed invisible: every log line claimed
# the seal was verified while the patterns had never been written at all.
if [ -e "$FACTORY_ROOT/$HELDOUT_DIR" ]; then
  SEAL_MODE="NONE"
  echo "[nightshift] seal: NONE -- $HELDOUT_DIR is readable in $FACTORY_ROOT" >&2
  echo "[nightshift]        every worker can read its own exam." >&2
  echo "[nightshift]        run 'bash scripts/foreman.sh launch' for a sealed night." >&2
  log_append "nightshift" "unsealed" "FACTORY_ROOT=$FACTORY_ROOT dir=$HELDOUT_DIR"
elif [ "${BODEGA_SEALED:-0}" = "1" ] && seal_intact "$FACTORY_ROOT"; then
  SEAL_MODE="physical"
  echo "[nightshift] seal: PHYSICAL -- sparse-checkout excludes $HELDOUT_DIR, re-checked at each commit" >&2
else
  SEAL_MODE="unverified"
  echo "[nightshift] seal: $HELDOUT_DIR is absent but no sparse patterns are active" >&2
  echo "[nightshift]        absence may only mean the exam board has not run yet." >&2
fi
export SEAL_MODE


no_progress=0
iters=0
last_exit_signal="false"

while [ "$iters" -lt "$MAX_ITERS" ]; do
  iters=$((iters + 1))

  # dual-condition exit
  if all_resolved && [ "$last_exit_signal" = "true" ]; then
    echo "[nightshift] all tasks resolved AND EXIT_SIGNAL true — exiting" >&2
    log_append "nightshift" "exit" "dual-condition satisfied after $iters iters"
    state_set "NIGHT_SHIFT_COMPLETE" "all tasks resolved; run the inspector"
    break
  fi

  TASK="$(next_task)" || {
    if [ -z "$(task_ids)" ]; then
      # Not a deadlock: this tree has no plan at all. Almost always means the
      # bootstrap artifacts were never committed, because a sealed worktree is
      # built from HEAD and sees nothing that only exists in the main checkout's
      # working directory.
      echo "[nightshift] FATAL: no factory/tasks/*.md in $FACTORY_ROOT" >&2
      echo "[nightshift]        the plan is not in this tree. If you launched a" >&2
      echo "[nightshift]        sealed night, HEAD is what it got — commit the" >&2
      echo "[nightshift]        bootstrap artifacts (factory/) and relaunch." >&2
      log_append "nightshift" "blocked" "no task files in tree (plan not committed?)"
      state_set "BLOCKED" "no factory/tasks/*.md — nothing to run (uncommitted plan?)"
      break
    fi
    if all_resolved; then
      echo "[nightshift] all tasks resolved, awaiting EXIT_SIGNAL — exiting" >&2
      log_append "nightshift" "exit" "all resolved (no EXIT_SIGNAL)"
      state_set "NIGHT_SHIFT_COMPLETE" "all tasks resolved; run the inspector"
    else
      echo "[nightshift] no runnable task (unmet dependencies) — BLOCKED" >&2
      log_append "nightshift" "blocked" "dependency deadlock"
      state_set "BLOCKED" "dependency deadlock: no task has satisfied deps"
    fi
    break
  }

  echo "[nightshift] === $TASK (iter $iters) ===" >&2
  SHA_BEFORE="$(git rev-parse HEAD)"
  SF="$WORKDIR/$TASK.status"; TO="$WORKDIR/$TASK.test"

  # The task's own verification command (work-order `Verify:` line, else the
  # project default). Computed ONCE and reused for the baseline, every repair
  # round and the resample — comparing counts from two different commands
  # would make "no regression" meaningless.
  TASK_CMD="$(task_verify_cmd "$TASK")"
  [ "$TASK_CMD" = "$VISIBLE_CMD" ] || echo "[nightshift] $TASK: verify = $TASK_CMD" >&2

  # Baseline BEFORE the worker touches anything: how many checks already fail.
  # This is what "no regression" is measured against.
  run_visible "$WORKDIR/$TASK.base" "$TASK_CMD"; LAST_TEST_RC=$?
  BASE_FAILS="$(fail_count "$WORKDIR/$TASK.base")"
  echo "[nightshift] $TASK: baseline $BASE_FAILS failing check(s)" >&2

  # A missing status block is a TRANSPORT failure, not a verification failure:
  # a dropped socket or a killed adapter says nothing about the work. Observed
  # on omp, where the connection died after the worker had already written 141
  # lines that took the suite from 10 failures to 2 — and the task was parked
  # anyway. Retry the invocation before spending the task's only chance.
  # This counter is separate from REPAIR_CAP, which is about failing tests.
  adapter_tries=0
  attempt "$TASK" "$SF"
  while ! status_valid "$SF" 2>/dev/null && [ "$adapter_tries" -lt "${ADAPTER_RETRIES:-2}" ]; do
    adapter_tries=$((adapter_tries + 1))
    echo "[nightshift] $TASK: no status block — adapter retry $adapter_tries/${ADAPTER_RETRIES:-2}" >&2
    log_append "nightshift" "adapter_retry" "$TASK attempt $adapter_tries"
    attempt "$TASK" "$SF"
  done
  if ! status_valid "$SF" 2>/dev/null; then
    echo "[nightshift] $TASK: unparseable status block after ${ADAPTER_RETRIES:-2} retries" >&2
    progress_append "$TASK" "PARKED" "-" "-" "worker returned no valid status block after ${ADAPTER_RETRIES:-2} adapter retries"
    log_append "nightshift" "park" "$TASK unparseable status"
    continue
  fi

  WSTATUS="$(status_field "$SF" STATUS)"
  last_exit_signal="$(status_field "$SF" EXIT_SIGNAL)"; last_exit_signal="${last_exit_signal:-false}"

  if [ "$WSTATUS" = "BLOCKED" ] || [ "$WSTATUS" = "NEEDS_CONTEXT" ]; then
    progress_append "$TASK" "PARKED" "-" "-" "$WSTATUS: $(status_field "$SF" SUMMARY)"
    log_append "nightshift" "park" "$TASK $WSTATUS"
    continue
  fi

  # verify — the worker's word is never the evidence
  run_visible "$TO" "$TASK_CMD"; TRC=$?; LAST_TEST_RC=$TRC
  CUR="$(fail_count "$TO")"
  repairs=0
  while ! verify_ok "$BASE_FAILS" "$CUR" "$TRC" && [ "$repairs" -lt "$REPAIR_CAP" ]; do
    repairs=$((repairs + 1))
    echo "[nightshift] $TASK: regression ($CUR failing vs $BASE_FAILS before) — repair $repairs/$REPAIR_CAP" >&2
    log_append "nightshift" "repair" "$TASK round $repairs ($CUR vs baseline $BASE_FAILS)"
    attempt "$TASK" "$SF" "$TO"
    run_visible "$TO" "$TASK_CMD"; TRC=$?; LAST_TEST_RC=$TRC
    CUR="$(fail_count "$TO")"
  done

  # Escalation. The ladder is data, not code: rung 0 is the resample, later
  # rungs are other families. Every rung that runs is recorded as an authoring
  # family so the inspector can refuse to be judged by the one that wrote it.
  record_author_family "$(role_family executor)"
  if ! verify_ok "$BASE_FAILS" "$CUR" "$TRC"; then
    # Walk the ladder from rung 0. Whichever rung has already spent itself here
    # (resample, or a single-role attempt) re-verifies and the loop stops the
    # moment the gate passes — so the ladder cannot skip a rung or run one twice.
    rung=0
    while ! verify_ok "$BASE_FAILS" "$CUR" "$TRC"; do
      rung_spec="$(ladder_rung "$rung")" || break
      strategy="$(rung_field "$rung_spec" 1)"
      role="$(rung_field "$rung_spec" 2)"
      rung=$((rung + 1))
      if ! may_escalate "verify_failure"; then
        log_append "nightshift" "ladder_refused" "$TASK reason_not_verify_failure"
        break
      fi
      if [ "$strategy" = "resample" ]; then
        # The rung's N wins over the global default for this task. Not `local`:
        # this block is the top-level loop, where `local` is a bash error.
        rung_n="$(rung_field "$rung_spec" 3)"
        RESAMPLE_N="${rung_n:-${RESAMPLE_N_DEFAULT:-3}}"
        if resample "$TASK"; then
          run_visible "$TO" "$TASK_CMD"; TRC=$?; LAST_TEST_RC=$TRC
          CUR="$(fail_count "$TO")"
        fi
        continue
      fi
      # Re-verify AFTER the climb no matter how it returned. climb_ladder keeps
      # its own rc/fails as locals, so skipping this left TRC/CUR holding the
      # pre-climb values: a rung that WON was then parked as a regression, which
      # is exactly what test-ladder.sh caught.
      climb_ladder "$TASK" "$SF" "$TO" "$TASK_CMD" "$BASE_FAILS" "$((rung - 1))" || true
      run_visible "$TO" "$TASK_CMD"; TRC=$?; LAST_TEST_RC=$TRC
      CUR="$(fail_count "$TO")"
      break   # climb_ladder walks the remaining rungs itself
    done
  fi

  if ! verify_ok "$BASE_FAILS" "$CUR" "$TRC"; then
    progress_append "$TASK" "PARKED" "-" "$(test_counts "$TO")" "regression: $CUR failing vs $BASE_FAILS at task start, after $REPAIR_CAP repairs + escalation ladder ($(ladder_length) rungs)"
    log_append "nightshift" "park" "$TASK verification failed"
    # Throw away the failed task's edits — but NOT factory/. progress.md and
    # log.md are tracked, so a bare `git checkout -- .` reverts the park record
    # written on the two lines above. The task then reads as unresolved, gets
    # retried against a baseline its own damage has already degraded, and is
    # marked DONE for leaving things exactly as broken as it found them.
    git checkout -q -- . ':(exclude)factory' 2>/dev/null
    continue
  fi

  SHA="$(commit_task "$TASK" "$SF")"
  if [ "$SHA" = "SEAL_BROKEN" ]; then
    # Stop the night rather than continue in a tree that just proved it can
    # reach its own exam: every later task would be executed in the same tree.
    echo "[nightshift] halting: the held-out seal was broken during $TASK" >&2
    progress_append "$TASK" "PARKED" "-" "$(test_counts "$TO")" \
      "seal broken mid-task: $HELDOUT_DIR became reachable — night halted, inspect before rerunning"
    log_append "nightshift" "halt" "$TASK seal_broken"
    state_set "BLOCKED" "held-out seal broken during $TASK; see factory/log.md"
    break
  fi
  if [ "$SHA" = "-" ]; then
    no_progress=$((no_progress + 1))
    echo "[nightshift] $TASK: empty diff ($no_progress/$NO_PROGRESS_LIMIT)" >&2
    log_append "nightshift" "no_progress" "$TASK empty diff $no_progress"
    if [ "$no_progress" -ge "$NO_PROGRESS_LIMIT" ]; then
      echo "[nightshift] circuit breaker: $NO_PROGRESS_LIMIT empty diffs — stopping" >&2
      log_append "nightshift" "circuit_breaker" "$no_progress consecutive empty diffs"
      state_set "BLOCKED" "circuit breaker: $NO_PROGRESS_LIMIT consecutive no-progress iterations"
      break
    fi
    progress_append "$TASK" "PARKED" "-" "$(test_counts "$TO")" "no file changes produced"
    continue
  fi

  no_progress=0
  progress_append "$TASK" "DONE" "$SHA" "$(test_counts "$TO")" "$(status_field "$SF" SUMMARY)"
  log_append "nightshift" "done" "$TASK $SHA"
  [ "$SHA_BEFORE" = "$(git rev-parse HEAD)" ] || true
done

if [ "$iters" -ge "$MAX_ITERS" ]; then
  log_append "nightshift" "exit" "max iterations ($MAX_ITERS) reached"
  state_set "BLOCKED" "max iterations reached without dual-condition exit"
fi

rm -rf "$WORKDIR"
trap - INT TERM

status_emit "nightshift" "-" "DONE" \
  "loop finished after $iters iterations; stage=$(state_stage)" \
  "EXIT_SIGNAL: $last_exit_signal"
