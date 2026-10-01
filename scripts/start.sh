#!/usr/bin/env bash
# start.sh — Software Bodega: the single front door.
#
# Launches ONE interactive oh-my-pi session running the conductor. It interviews
# you, then runs every unattended station itself and reports back. You never
# need another command.
#
# The conductor runs stations as subprocesses, so each still gets a fresh
# headless session — the isolation the gates depend on is preserved.
#
# Usage:
#   bash scripts/start.sh              interview, then run the pipeline
#   bash scripts/start.sh --resume     pick up an in-flight project
#   bash scripts/start.sh --print      print the prompt and exit (no session)
#   bash scripts/start.sh --yolo       unattended test run: no human stops

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

MODEL="${BODEGA_CONDUCTOR_MODEL:-claude-opus-4-8}"
MODE="new"
YOLO=0
PRINT=0
for a in "$@"; do
  case "$a" in
    --resume) MODE="resume" ;;
    # --print is an OUTPUT mode, not a starting state. Setting MODE="print" used
    # to disable the auto-detection below entirely, so `--print` always showed the
    # "new project, begin the interview" branch even when a brief or a finished
    # night was on disk — which is exactly how the handoff bug hid during
    # development: the probe disagreed with the real launch.
    --print)  PRINT=1 ;;
    --yolo)   YOLO=1 ;;
  esac
done

CONDUCTOR="skills/conductor/SKILL.md"
INTERVIEW="skills/factory-interview/SKILL.md"
for f in "$CONDUCTOR" "$INTERVIEW"; do
  [ -s "$f" ] || { echo "FATAL: $f is missing — without it this is just a chat." >&2; exit 1; }
done

STAGE="$(awk -F': *' '/^STAGE:/{print $2; exit}' factory/STATE.md 2>/dev/null || echo INTERVIEW)"
HAS_BRIEF=no
grep -q '^## Decisions made' factory/BRIEF.md 2>/dev/null && HAS_BRIEF=yes

# Three starting points, not two. The old code collapsed "the human prepared a
# brief" into "resume", which tells the conductor to read the artifacts and then
# "ask what they want to do next". With a handoff that question has already been
# answered, and under --yolo nobody is there to answer it: the run opens, prints
# a status paragraph, and waits. A prepared brief with nothing run yet is its own
# case — skip the interview, start at spec.
HAS_WORK=no
if [ -f factory/progress.md ] && grep -qE '^[^#|]+\|' factory/progress.md 2>/dev/null; then
  HAS_WORK=yes
fi
[ "$STAGE" = "INTERVIEW" ] || HAS_WORK=yes
if [ "$MODE" = "new" ]; then
  if [ "$HAS_WORK" = yes ]; then
    MODE="resume"
  elif [ "$HAS_BRIEF" = yes ]; then
    MODE="handoff"
  fi
fi

PROMPT="$(
  cat "$CONDUCTOR"
  printf '\n\n===== THE INTERVIEW SKILL (for step 1) =====\n'
  cat "$INTERVIEW"
  printf '\n\n===== THIS SESSION =====\n'
  printf 'Project directory : %s\n' "$ROOT"
  printf 'Current stage     : %s\n' "${STAGE:-INTERVIEW}"
  printf 'Brief already written: %s\n\n' "$HAS_BRIEF"
  if [ "$MODE" = "handoff" ]; then
    printf 'The human has ALREADY DONE THE INTERVIEW. factory/BRIEF.md is their\n'
    printf 'prepared handoff — read it now and treat it as the source of truth.\n'
    printf 'Do NOT interview them and do NOT rewrite the brief from questions.\n\n'
    printf 'Steps:\n'
    printf '  1. Read factory/BRIEF.md.\n'
    if [ "$YOLO" = "1" ]; then
      printf '  2. YOLO: record the brief as auto-accepted in factory/log.md and\n'
      printf '     continue without asking.\n'
    else
      printf '  2. Read it back to them in a few lines and ask: does this describe\n'
      printf '     what you want? (sign / edit). Do not continue without a yes.\n'
    fi
    printf '  3. Then run the pipeline from spec:\n'
    printf '       nohup bash scripts/bootstrap.sh --from spec > /tmp/bodega-boot.log 2>&1 &\n'
    printf '     and poll it. Long station, 1-2 hours.\n\n'
    printf 'If the brief is missing a section the gates need (## Non-goals with\n'
    printf 'NG-N ids, ## Riskiest part), say so and ask ONE question to fill the\n'
    printf 'gap rather than inventing the answer.\n'
  elif [ "$MODE" = "resume" ]; then
    printf 'This project is ALREADY IN FLIGHT. Do not restart the interview.\n'
    printf 'Read factory/STATE.md, factory/progress.md and factory/REVIEW.md\n'
    printf '(if present), tell the human in one short paragraph where things\n'
    printf 'stand, and ask what they want to do next.\n'
    if [ "$YOLO" = "1" ]; then
      printf '\nYOLO OVERRIDE: nobody is watching, so do not ask. Pick up at the\n'
      printf 'stage in factory/STATE.md and run the pipeline to the end, then stop\n'
      printf 'before merging as usual.\n'
    fi
  else
    printf 'This is a NEW project. Begin the interview now.\n'
    printf 'Ask your FIRST question immediately — do not summarise these\n'
    printf 'instructions back at the human, and do not explain the pipeline\n'
    printf 'unless they ask. Open by asking what they want to build.\n'
  fi
  printf '\nYou have a shell. Run the station scripts yourself; long ones with\n'
  printf 'nohup ... & and poll. Never write spec.json, decompose.json,\n'
  printf 'plan.json, CONTRACT.md, any test, or any source file yourself.\n'
  if [ "$YOLO" = "1" ]; then
    printf '\n===== YOLO TEST MODE =====\n'
    printf 'Nobody is watching. Run the WHOLE pipeline unattended, end to end.\n\n'
    printf 'What YOLO changes -- the human STOPS only:\n'
    printf '  - Do not wait for a signature on BRIEF.md. Write it, note in\n'
    printf '    factory/log.md that it was auto-accepted under YOLO, continue.\n'
    printf '  - Same for CONTRACT.md: record the auto-signature, continue.\n'
    printf '  - Do not ask permission between stations. Just run the next one.\n'
    printf '  - If the plan review escalates after its revisions, pick the most\n'
    printf '    defensible option yourself, WRITE DOWN which and why, continue.\n\n'
    printf 'What YOLO does NOT change -- these are the thing being tested:\n'
    printf '  - Never edit CONTRACT.md after writing it. Never weaken, skip or\n'
    printf '    delete a test. Never touch the held-out suite (HELDOUT_DIR from\n'
    printf '    factory/toolchain.env — ask scripts/toolchain.sh get HELDOUT_DIR).\n'
    printf '  - Never claim a gate passed that did not. A failing suite is a\n'
    printf '    failing suite; report it.\n'
    printf '  - STOP BEFORE MERGING. Run the inspector, report the verdict, and\n'
    printf '    leave the merge to the human. A test that merges itself has\n'
    printf '    removed the last thing standing between a bad night and main.\n\n'
    printf 'Finish by printing: the verdict line, tasks done/parked, and every\n'
    printf 'decision you made that a human would normally have made.\n'
  fi
)"

# An argument-mode prompt must not START with a dash or omp's parser claims it
# as a flag and exits before the model sees anything. Every skill file opens
# with YAML frontmatter (`---`), so this fires on EVERY prompt built here.
# run_role has the same guard; these scripts call omp directly and need it too.
case "$PROMPT" in -*) PROMPT="
$PROMPT" ;; esac

if [ "$PRINT" = "1" ]; then printf '%s\n' "$PROMPT"; exit 0; fi

printf '\033[1m  Software Bodega \033[0m\n'
printf '  project : %s\n' "$ROOT"
printf '  stage   : %s\n' "${STAGE:-INTERVIEW}"
printf '  mode    : %s%s\n\n' "$MODE" "$([ "$YOLO" = 1 ] && echo ' (YOLO)')"

command -v omp >/dev/null 2>&1 || { echo "oh-my-pi (omp) is not on PATH." >&2; exit 1; }

if [ "$YOLO" = "1" ]; then
  # Headless stations inherit this through models.env, so nothing in the
  # pipeline pauses on a tool gate either.
  export BODEGA_APPROVAL=yolo
  printf '\033[33m  YOLO: no human stops, no tool prompts. Verification unchanged.\033[0m\n\n'
  exec omp --approval-mode yolo --model "$MODEL" "$PROMPT"
fi
exec omp --model "$MODEL" "$PROMPT"
