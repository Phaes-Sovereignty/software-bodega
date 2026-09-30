#!/usr/bin/env bash
# Software Bodega — launcher (macOS)
#
# Double-click from Finder, or run from a shell. Asks for a project folder,
# sets it up as a Bodega project if it isn't one already, then opens iTerm
# (or Terminal) there with ONE oh-my-pi session running the conductor.
#
# The conductor interviews you and then runs every other station itself.
# You never type another command.
#
# Usage:
#   ./Software-Bodega-mac.command                    pick a folder, set up, launch
#   ./Software-Bodega-mac.command <dir>              skip the picker
#   ./Software-Bodega-mac.command <dir> --no-launch  set up only (scriptable/testable)

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
  osascript -e "display alert \"Software Bodega\" message \"$1\" as critical" >/dev/null 2>&1
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
  set f to choose folder with prompt "Software Bodega — pick a project folder"
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
  set r to button returned of (display dialog "Set up a new Software Bodega project in:

$DIR

($COUNT existing item(s) — nothing will be overwritten.)" buttons {"Cancel", "Set up"} default button "Set up" with title "Software Bodega")
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
  # Never destructive, and now provably so. `cp -R` used to overwrite any
  # same-named file the human already had — README.md, AGENTS.md, anything under
  # .github/, and any scripts/*.sh with a matching name — while the dialog above
  # said "nothing will be deleted". scripts/lib/merge.sh scans first, refuses
  # (writing nothing) when Bodega machinery would be replaced, installs docs and
  # workflows under distinct names otherwise, and verifies the result by bytes.
  # shellcheck disable=SC1091
  . "$TEMPLATE/scripts/lib/merge.sh"
  # The full conflict list goes to the terminal; the alert gets one line because
  # a newline inside an AppleScript string literal is a syntax error, and a
  # silently-failing alert would hide the refusal entirely.
  if ! bodega_merge "$TEMPLATE" "$DIR"; then
    printf '%s\n' "$(bodega_merge_conflict_message)" >&2
    die "Cannot set up here without overwriting your files. Nothing was written — see the terminal for which paths conflict."
  fi
  bodega_merge_report
  # The suite directories are NOT created here. Which ones exist is a property of
  # the project's toolchain, decided by `scripts/toolchain.sh resolve` before the
  # exam board; pre-creating factory/tests/heldout in a Swift project leaves an
  # empty directory that makes the seal test pass vacuously.
  mkdir -p "$DIR/factory/.planning/gate-results" "$DIR/factory/tasks" "$DIR/factory/adr"
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
  echo "Software Bodega: prepared $DIR ($MODE) — not launching a terminal (--no-launch)"
  exit 0
fi

if [ -d "/Applications/iTerm.app" ]; then
  /usr/bin/osascript <<OSA >/dev/null 2>&1
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    set name to "Software Bodega — $(basename "$DIR")"
    write text "cd " & quoted form of "$DIR" & " && bash scripts/start.sh"
  end tell
end tell
OSA
else
  /usr/bin/osascript <<OSA >/dev/null 2>&1
tell application "Terminal"
  activate
  do script "cd " & quoted form of "$DIR" & " && bash scripts/start.sh"
end tell
OSA
fi

echo "Software Bodega: launched at $DIR ($MODE)"
