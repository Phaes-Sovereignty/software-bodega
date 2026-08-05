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

DRY_RUN=0
MAX_ITERS=${MAX_ITERS:-40}
VISIBLE_CMD="${VISIBLE_CMD:-bash factory/tests/run-visible.sh}"
REPAIR_CAP="${REPAIR_CAP:-2}"
RESAMPLE_N="${RESAMPLE_N:-3}"
NO_PROGRESS_LIMIT="${NO_PROGRESS_LIMIT:-3}"

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
    git add -A && git commit -q -m "factory: salvage WIP from interrupted night shift" 2>/dev/null
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
  local id
  for id in $(task_ids); do task_resolved "$id" || return 1; done
  return 0
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

test_counts() { # crude pass/total from the receipt, best-effort
  # No `|| echo 0`: grep -c prints 0 and exits 1 when it matches nothing, which
  # would append a second zero and corrupt the progress.md line.
  local out="$1" p t ran
  # Swift/XCTest: "Executed N tests, with M failures" — last occurrence is the
  # "All tests" rollup, same reason as swift_fail_count.
  ran=$(grep -oE 'Executed [0-9]+ tests?, with' "$out" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
  if [ -n "$ran" ]; then
    printf '%s/%s' "$(( ran - $(fail_count "$out") ))" "$ran"; return
  fi
  ran=$(grep -oE '^Ran ([0-9]+) test' "$out" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [ -n "$ran" ]; then
    printf '%s/%s' "$(( ran - $(fail_count "$out") ))" "$ran"; return
  fi
  p=$(grep -cE '^(ok|PASS|passed)' "$out" 2>/dev/null); p="${p:-0}"
  t=$(grep -cE '^(ok|not ok|PASS|FAIL)' "$out" 2>/dev/null); t="${t:-0}"
  [ "$t" = "0" ] && { printf '?/?'; return; }
  printf '%s/%s' "$p" "$t"
}

# swift_fail_count <receipt> : failing checks from `swift test` / `xcodebuild
# test`, or non-zero return if this receipt is not Swift at all.
#
# Three properties of real Swift output that a naive parser gets wrong:
#
#  1. XCTest prints "Executed N tests, with M failures" once per suite AND
#     again for the "All tests" rollup — summing them multiplies the count.
#     Take the LAST occurrence, which is the rollup.
#  2. Swift 6 runs swift-testing alongside XCTest and prints its own line even
#     for an XCTest-only package ("Test run with 0 tests ... passed"). Reading
#     that line as the whole result reports success while XCTest is failing.
#     The two frameworks are counted separately and ADDED.
#  3. A compile failure produces NO count line at all. That must fall through
#     to the exit code, never to zero.
swift_fail_count() {
  local out="$1" total=0 found=0 n
  # 1. XCTest rollup — last occurrence only.
  n=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failure' "$out" 2>/dev/null \
      | tail -1 | sed -E 's/.*with ([0-9]+) failure.*/\1/')
  if [ -n "$n" ]; then total=$((total + n)); found=1; fi
  # 2. swift-testing, which reports "issues" rather than failures.
  if grep -qE 'Test run with .*failed.*with [0-9]+ issue' "$out" 2>/dev/null; then
    n=$(grep -oE 'with [0-9]+ issue' "$out" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
    total=$((total + ${n:-1})); found=1
  elif grep -qE 'Test run with .*passed' "$out" 2>/dev/null; then
    found=1
  fi
  # 3. xcodebuild banner: a backstop when the Executed line is absent or 0 but
  #    the run still failed (a crashed bundle, a failed build phase).
  if grep -q '\*\* TEST FAILED \*\*' "$out" 2>/dev/null; then
    [ "$total" = "0" ] && total=1
    found=1
  fi
  [ "$found" = "1" ] || return 1
  printf '%s' "$total"
}

# fail_count <receipt> : how many checks are currently failing.
# 0 when the suite is green. Falls back to the exit code when the format is
# unrecognised, so an unparseable receipt is never mistaken for success.
fail_count() {
  local out="$1" n g=0
  # The extra gate is a failing CHECK, counted alongside the tests. It has to
  # enter the arithmetic or it is invisible: a task that breaks the invariant
  # while keeping the suite green would score 0 against a baseline of 0 and
  # read as "no regression". Counting it means breaking the invariant IS a
  # regression, while an invariant already broken before the task started
  # stays that task's inherited problem — the same rule as every other check.
  if grep -q '^\*\* EXTRA GATE FAILED \*\*' "$out" 2>/dev/null; then g=1; fi
  # Swift first: its receipts contain no unittest/TAP markers, so there is no
  # ambiguity, and a Swift build failure must reach the exit-code fallback
  # rather than being read as a green suite.
  if n=$(swift_fail_count "$out"); then printf '%s' "$((n + g))"; return; fi
  # python unittest: "FAILED (failures=3, errors=1)"
  n=$(grep -oE '(failures|errors)=[0-9]+' "$out" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  if [ -n "$n" ] && [ "$n" != "0" ]; then printf '%s' "$((n + g))"; return; fi
  grep -qE '^OK\b|^OK$' "$out" 2>/dev/null && { printf '%s' "$g"; return; }
  # TAP. No `|| echo 0` here: grep -c already prints 0 when it matches nothing,
  # and it exits 1 doing so, which would append a second zero.
  n=$(grep -cE '^not ok' "$out" 2>/dev/null); n="${n:-0}"
  if [ "$n" != "0" ]; then printf '%s' "$((n + g))"; return; fi
  grep -qE '^ok ' "$out" 2>/dev/null && { printf '%s' "$g"; return; }
  printf '%s' "${LAST_TEST_RC:-1}"
}

# The night shift builds a system incrementally: a walking skeleton cannot make
# the whole suite green, and later tasks turn on the rest. Demanding an all-green
# suite after every task would park every task but the last. The real rule is
# NO REGRESSION — a task must not break a check that was already passing, and the
# suite must reach zero failures by the end (the inspector enforces that).
verify_ok() { # verify_ok <baseline_failures> <current_failures> <exit_rc>
  local base="$1" cur="$2" rc="$3"
  [ "$rc" = "0" ] && return 0                 # fully green: always fine
  [ "$cur" = "127" ] && return 1              # no runner at all
  [ "$cur" -le "$base" ] 2>/dev/null && return 0
  return 1
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

attempt() { # attempt <task_id> <outfile> [repair_ctx] -> executor exit
  local id="$1" out="$2" repair="${3:-}" prompt
  prompt="$(build_prompt "$id" "$repair")"
  if [ "$DRY_RUN" = "1" ]; then
    status_emit "night-task" "$id" "DONE" "dry-run: no executor invoked" \
      "TESTS: 0/0" "FILES: -" "EXIT_SIGNAL: false" > "$out"
    return 0
  fi
  run_role executor "$prompt" > "$out" 2>>factory/log.md
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

# --- commit ----------------------------------------------------------------

commit_task() { # commit_task <task_id> <status_file> -> prints SHA or -
  local id="$1" sf="$2" files f added=0
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

  if ! verify_ok "$BASE_FAILS" "$CUR" "$TRC"; then
    if resample "$TASK"; then
      run_visible "$TO" "$TASK_CMD"; TRC=$?; LAST_TEST_RC=$TRC
      CUR="$(fail_count "$TO")"
    fi
  fi

  if ! verify_ok "$BASE_FAILS" "$CUR" "$TRC"; then
    progress_append "$TASK" "PARKED" "-" "$(test_counts "$TO")" "regression: $CUR failing vs $BASE_FAILS at task start, after $REPAIR_CAP repairs + resample N=$RESAMPLE_N"
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
