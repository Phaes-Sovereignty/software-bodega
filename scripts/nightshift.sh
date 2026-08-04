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

run_visible() { # -> exit code; output to $1
  local out="$1"
  if [ ! -f factory/tests/run-visible.sh ]; then
    echo "no factory/tests/run-visible.sh — cannot verify" > "$out"; return 127
  fi
  ( eval "$VISIBLE_CMD" ) > "$out" 2>&1
}

test_counts() { # crude pass/total from the receipt, best-effort
  local out="$1" p t
  p=$(grep -cE '^(ok|PASS|passed)' "$out" 2>/dev/null || echo 0)
  t=$(grep -cE '^(ok|not ok|PASS|FAIL)' "$out" 2>/dev/null || echo 0)
  [ "$t" = "0" ] && { printf '?/?'; return; }
  printf '%s/%s' "$p" "$t"
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
  printf '\n\n===== HOW TO VERIFY =====\nRun: %s\n' "$VISIBLE_CMD"
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
  local id="$1" i pids=() dirs=() base
  base="$(git rev-parse HEAD)"
  echo "[nightshift] $id: resampling N=$RESAMPLE_N (execution-selected)" >&2
  log_append "nightshift" "resample_start" "$id N=$RESAMPLE_N"
  for i in $(seq 1 "$RESAMPLE_N"); do
    local wt="$WORKDIR/rs-$id-$i"
    git worktree add -q --detach "$wt" "$base" 2>/dev/null || continue
    dirs+=("$wt")
    (
      cd "$wt" || exit 1
      FACTORY_ROOT="$wt" run_role executor "$(build_prompt "$id")" \
        > "$wt/.sample-out" 2>/dev/null
      ( eval "$VISIBLE_CMD" ) > "$wt/.sample-test" 2>&1
      echo $? > "$wt/.sample-rc"
    ) &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null

  local wt rc
  for wt in "${dirs[@]}"; do
    rc="$(cat "$wt/.sample-rc" 2>/dev/null || echo 1)"
    if [ "$rc" = "0" ]; then
      echo "[nightshift] $id: sample $(basename "$wt") won (tests exit 0)" >&2
      # port the winner's working tree changes back into the main checkout
      ( cd "$wt" && git diff "$base" -- . ) > "$WORKDIR/winner.patch" 2>/dev/null
      if [ -s "$WORKDIR/winner.patch" ]; then
        git apply --whitespace=nowarn "$WORKDIR/winner.patch" 2>/dev/null || true
      else
        ( cd "$wt" && tar cf - --exclude=.git --exclude='.sample-*' . ) | tar xf - -C "$FACTORY_ROOT"
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

  attempt "$TASK" "$SF"
  if ! status_valid "$SF" 2>/dev/null; then
    echo "[nightshift] $TASK: unparseable status block" >&2
    progress_append "$TASK" "PARKED" "-" "-" "worker returned no valid status block"
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
  run_visible "$TO"; TRC=$?
  repairs=0
  while [ "$TRC" -ne 0 ] && [ "$repairs" -lt "$REPAIR_CAP" ]; do
    repairs=$((repairs + 1))
    echo "[nightshift] $TASK: visible suite failed — repair $repairs/$REPAIR_CAP" >&2
    log_append "nightshift" "repair" "$TASK round $repairs"
    attempt "$TASK" "$SF" "$TO"
    run_visible "$TO"; TRC=$?
  done

  if [ "$TRC" -ne 0 ]; then
    if resample "$TASK"; then
      run_visible "$TO"; TRC=$?
    fi
  fi

  if [ "$TRC" -ne 0 ]; then
    progress_append "$TASK" "PARKED" "-" "$(test_counts "$TO")" "visible suite failed after $REPAIR_CAP repairs + resample N=$RESAMPLE_N"
    log_append "nightshift" "park" "$TASK verification failed"
    git checkout -q -- . 2>/dev/null
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
