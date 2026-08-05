#!/usr/bin/env bash
# interview.sh — Software Bodega: start (or resume) a project.
#
# The INTERVIEW is the one conversational station, so this is the one script
# that launches an interactive session rather than a headless one. Everything
# after it runs unattended.
#
# It hands the planner the interview skill as the opening prompt, because
# nothing is auto-discovered: the skill file IS the instruction set.
#
# Usage: bash scripts/interview.sh [--resume]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 1

# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh" 2>/dev/null || true

MODEL="${BODEGA_PLANNER_MODEL:-claude-opus-5}"
STAGE="$(awk -F': *' '/^STAGE:/{print $2; exit}' factory/STATE.md 2>/dev/null || echo IDLE)"

printf '\033[1m Software Bodega \033[0m\n'
printf '  project : %s\n' "$ROOT"
printf '  stage   : %s\n' "${STAGE:-IDLE}"
printf '  planner : %s (interactive)\n\n' "$MODEL"

if [ "${1:-}" = "--resume" ] || [ -s factory/BRIEF.md ] && grep -q '^## Decisions made' factory/BRIEF.md 2>/dev/null; then
  printf '  A brief already exists. Resuming — say what you want to change,\n'
  printf '  or run the next station:  bash scripts/bootstrap.sh --from spec\n\n'
fi

# Sanity: the skill file is the instruction set. Without it this is just a chat.
SKILL="skills/factory-interview/SKILL.md"
if [ ! -s "$SKILL" ]; then
  echo "FATAL: $SKILL is missing — without it there is no interview, just a chat." >&2
  exit 1
fi

PROMPT="$(
  cat "$SKILL"
  printf '\n\n===== YOUR SESSION =====\n'
  printf 'You are running the INTERVIEW station of Software Bodega, interactively,\n'
  printf 'with a human present. Follow the skill above exactly:\n'
  printf '  - ONE question at a time, each with a recommended answer\n'
  printf '  - stop when two engineers would ship the same behaviour\n'
  printf '  - then write factory/BRIEF.md and ask the human to sign it\n\n'
  printf 'Working directory: %s\n' "$ROOT"
  printf 'Write the brief to factory/BRIEF.md when you are done.\n\n'
  printf 'Open by asking the human what they want to build. Ask your first\n'
  printf 'question immediately; do not summarise these instructions back.\n'
)"

exec omp --model "$MODEL" "$PROMPT"
