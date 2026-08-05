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

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

MODEL="${BODEGA_CONDUCTOR_MODEL:-claude-opus-5}"
MODE="new"
for a in "$@"; do
  case "$a" in
    --resume) MODE="resume" ;;
    --print)  MODE="print" ;;
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
[ "$HAS_BRIEF" = yes ] && [ "$MODE" = "new" ] && MODE="resume"

PROMPT="$(
  cat "$CONDUCTOR"
  printf '\n\n===== THE INTERVIEW SKILL (for step 1) =====\n'
  cat "$INTERVIEW"
  printf '\n\n===== THIS SESSION =====\n'
  printf 'Project directory : %s\n' "$ROOT"
  printf 'Current stage     : %s\n' "${STAGE:-INTERVIEW}"
  printf 'Brief already written: %s\n\n' "$HAS_BRIEF"
  if [ "$MODE" = "resume" ]; then
    printf 'This project is ALREADY IN FLIGHT. Do not restart the interview.\n'
    printf 'Read factory/STATE.md, factory/progress.md and factory/REVIEW.md\n'
    printf '(if present), tell the human in one short paragraph where things\n'
    printf 'stand, and ask what they want to do next.\n'
  else
    printf 'This is a NEW project. Begin the interview now.\n'
    printf 'Ask your FIRST question immediately — do not summarise these\n'
    printf 'instructions back at the human, and do not explain the pipeline\n'
    printf 'unless they ask. Open by asking what they want to build.\n'
  fi
  printf '\nYou have a shell. Run the station scripts yourself; long ones with\n'
  printf 'nohup ... & and poll. Never write spec.json, decompose.json,\n'
  printf 'plan.json, CONTRACT.md, any test, or any source file yourself.\n'
)"

if [ "$MODE" = "print" ]; then printf '%s\n' "$PROMPT"; exit 0; fi

printf '\033[1m  Software Bodega \033[0m\n'
printf '  project : %s\n' "$ROOT"
printf '  stage   : %s\n' "${STAGE:-INTERVIEW}"
printf '  mode    : %s\n\n' "$MODE"

command -v omp >/dev/null 2>&1 || { echo "oh-my-pi (omp) is not on PATH." >&2; exit 1; }
exec omp --model "$MODEL" "$PROMPT"
