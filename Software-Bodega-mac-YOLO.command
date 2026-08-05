#!/usr/bin/env bash
# Software Bodega — launcher (macOS, YOLO / unattended test mode)
#
# Double-click from Finder, or run from a shell. Asks for a project folder,
# sets it up as a Bodega project if it isn't one already, then opens iTerm
# (or Terminal) there with ONE oh-my-pi session running the conductor.
#
# Same as the standard launcher, except the run does not stop for you:
# no tool-approval prompts, no signature gates, no between-station questions.
# For TESTING the pipeline end to end.#
# YOLO changes the human STOPS only. It does NOT relax verification: the
# contract is still immutable, tests are still never weakened, held-out exams
# are still sealed, and the run still STOPS BEFORE MERGING. A test run that
# merges itself has removed the last thing between a bad night and main.
#
# Point it at a scratch folder. Workers write with your user's permissions and
# nothing here confines them to the project directory.
#
# Usage:
#   ./Software-Bodega-mac-YOLO.command                    pick a folder, set up, launch
#   ./Software-Bodega-mac-YOLO.command <dir>              skip the picker
#   ./Software-Bodega-mac-YOLO.command <dir> --no-launch  set up only (scriptable/testable)

set -uo pipefail

# The template is this script's own directory — the checked-out repo. Override
# with BODEGA_TEMPLATE only if you keep the launcher somewhere else.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${BODEGA_TEMPLATE:-$HERE}"

ARG_DIR=""; NO_LAUNCH=0
for a in "$@"; do
  case "$a" in
    --no-launch) NO_LAUNCH=1 ;;
    -*) ;;
    *) ARG_DIR="$a" ;;
  esac
done

die() {
  osascript -e "display alert \"Software Bodega YOLO\" message \"$1\" as critical" >/dev/null 2>&1
  echo "$1" >&2
  exit 1
}

[ -f "$TEMPLATE/scripts/start.sh" ] || die "This does not look like a Software Bodega checkout:
$TEMPLATE

Run the launcher from inside the cloned repo, or set BODEGA_TEMPLATE."

# --- 1. pick a folder ------------------------------------------------------
if [ -n "$ARG_DIR" ]; then
  DIR="$ARG_DIR"
else
  DIR="$(osascript <<'OSA' 2>/dev/null
try
  set f to choose folder with prompt "Software Bodega YOLO — pick a SCRATCH folder (unattended)"
  return POSIX path of f
on error
  return ""
end try
OSA
)"
fi
[ -n "$DIR" ] || exit 0                     # cancelled
DIR="${DIR%/}"

# --- 2. is it already a Bodega project? ------------------------------------
if [ -f "$DIR/factory/STATE.md" ] && [ -f "$DIR/scripts/start.sh" ]; then
  MODE="resume"
else
  COUNT="$(find "$DIR" -mindepth 1 -maxdepth 1 ! -name '.DS_Store' 2>/dev/null | wc -l | tr -d ' ')"
  if [ -n "$ARG_DIR" ]; then ANSWER="Set up"; else
  ANSWER="$(osascript <<OSA 2>/dev/null
try
  set r to button returned of (display dialog "YOLO TEST RUN — unattended, no approval prompts, no signature gates.

Set up a new Software Bodega project in:

$DIR

($COUNT existing item(s) — nothing will be deleted.)" buttons {"Cancel", "Set up"} default button "Set up" with title "Software Bodega — YOLO")
  return r
on error
  return "Cancel"
end try
OSA
)"
  fi
  [ "$ANSWER" = "Set up" ] || exit 0
  MODE="init"
fi

# --- 3. initialise from the template (never destructive) -------------------
if [ "$MODE" = "init" ]; then
  mkdir -p "$DIR" || die "Cannot create $DIR"
  # Loud, not silent: a swallowed cp error once left a project with no
  # scripts/ and only surfaced later as "No such file or directory".
  COPY_FAIL=""
  for item in skills scripts foreman docs models.env AGENTS.md README.md .github; do
    [ -e "$TEMPLATE/$item" ] || { COPY_FAIL="$COPY_FAIL $item(missing-in-template)"; continue; }
    cp -R "$TEMPLATE/$item" "$DIR/" || COPY_FAIL="$COPY_FAIL $item"
  done
  [ -n "$COPY_FAIL" ] && die "Could not copy into $DIR:$COPY_FAIL"
  for must in scripts/start.sh scripts/nightshift.sh skills/conductor/SKILL.md models.env; do
    [ -e "$DIR/$must" ] || die "Setup incomplete: $DIR/$must is missing after copy."
  done
  mkdir -p "$DIR/factory/.planning/gate-results" "$DIR/factory/tasks" \
           "$DIR/factory/tests/visible" "$DIR/factory/tests/heldout" "$DIR/factory/adr"
  printf 'STAGE: INTERVIEW\nPOINTER: new project — run the interview\n' > "$DIR/factory/STATE.md"
  printf '# progress.md — append-only. Format: TASK|status|SHA|tests|note\n' > "$DIR/factory/progress.md"
  printf '# log.md — append-only station diary. Format: ISO8601|station|event|detail\n' > "$DIR/factory/log.md"
  for f in BRIEF BLUEPRINT CONTRACT HANDOFF REVIEW GUIDE; do
    [ -f "$DIR/factory/$f.md" ] || printf '# %s.md\n\n_Not yet produced._\n' "$f" > "$DIR/factory/$f.md"
  done
  printf '%s\n' '{"actors":[],"criteria":[],"non_goals":[]}' > "$DIR/factory/.planning/spec.json"
  printf '%s\n' '{"tasks":[]}'   > "$DIR/factory/.planning/decompose.json"
  printf '%s\n' '{"slices":[]}'  > "$DIR/factory/.planning/plan.json"
  chmod +x "$DIR"/scripts/*.sh "$DIR"/scripts/lib/*.sh "$DIR"/scripts/tests/*.sh 2>/dev/null
  # git from the first commit: the night shift commits per task and needs a base.
  if [ ! -d "$DIR/.git" ]; then
    git -C "$DIR" init -q 2>/dev/null
    git -C "$DIR" config user.name  "$(git config --global user.name  || echo bodega)" 2>/dev/null
    git -C "$DIR" config user.email "$(git config --global user.email || echo bodega@localhost)" 2>/dev/null
    git -C "$DIR" add -A 2>/dev/null
    git -C "$DIR" commit -qm "Software Bodega: scaffold" 2>/dev/null
  fi
fi

# --- 4. open a terminal there and start the conductor ----------------------
command -v omp >/dev/null 2>&1 || die "oh-my-pi (omp) is not on PATH.
See the README for swapping in a different agent harness."
if [ "$NO_LAUNCH" = "1" ]; then
  echo "Software Bodega YOLO: prepared $DIR ($MODE) — not launching a terminal (--no-launch)"
  exit 0
fi

if [ -d "/Applications/iTerm.app" ]; then
  /usr/bin/osascript <<OSA >/dev/null 2>&1
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "Software Bodega YOLO — $(basename "$DIR")"
    write text "cd " & quoted form of "$DIR" & " && bash scripts/start.sh --yolo"
  end tell
end tell
OSA
else
  /usr/bin/osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
  activate
  do script "cd " & quoted form of "$DIR" & " && bash scripts/start.sh --yolo"
end tell
OSA
fi

echo "Software Bodega YOLO: launched (unattended) at $DIR ($MODE)"
