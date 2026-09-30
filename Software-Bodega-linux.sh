#!/usr/bin/env bash
# Software Bodega — launcher (Linux)
#
# Asks for a project folder, sets it up as a Bodega project if it isn't one
# already, then opens a terminal there with ONE oh-my-pi session running the
# conductor. The conductor interviews you and then runs every other station
# itself — you never type another command.
#
# Folder picker: zenity, else kdialog, else a plain terminal prompt.
# Terminal: gnome-terminal / konsole / xfce4-terminal / alacritty / kitty /
# x-terminal-emulator / xterm — whichever is installed. With none of them
# (headless, SSH, WSL) it runs the conductor in the current terminal.
#
# Usage:
#   ./Software-Bodega-linux.sh                    pick a folder, set up, launch
#   ./Software-Bodega-linux.sh <dir>              skip the picker
#   ./Software-Bodega-linux.sh <dir> --no-launch  set up only
#
# ⚠️  UNTESTED ON THIS PLATFORM. Written and syntax-checked, but never run on a
#     real Linux desktop — only the macOS launcher has been exercised end to
#     end. The setup logic is shared and verified; what is unproven here is the
#     folder picker (zenity/kdialog) and the terminal launch. If it misbehaves,
#     the fallback is exact and safe:
#         bash Software-Bodega-linux.sh <dir> --no-launch   # set up only
#         cd <dir> && bash scripts/start.sh                 # then start it
#     Please report what broke.

set -uo pipefail

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
  if command -v zenity >/dev/null 2>&1; then
    zenity --error --title="Software Bodega" --text="$1" >/dev/null 2>&1
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --error "$1" >/dev/null 2>&1
  fi
  echo "$1" >&2
  exit 1
}

[ -f "$TEMPLATE/scripts/start.sh" ] || die "This does not look like a Software Bodega checkout:
$TEMPLATE

Run the launcher from inside the cloned repo, or set BODEGA_TEMPLATE."

# --- 1. pick a folder ------------------------------------------------------
if [ -n "$ARG_DIR" ]; then
  DIR="$ARG_DIR"
elif command -v zenity >/dev/null 2>&1; then
  DIR="$(zenity --file-selection --directory \
        --title="Software Bodega — pick a project folder" 2>/dev/null)"
elif command -v kdialog >/dev/null 2>&1; then
  DIR="$(kdialog --getexistingdirectory "$HOME" \
        --title "Software Bodega — pick a project folder" 2>/dev/null)"
else
  printf 'Software Bodega — project folder path: ' >&2
  read -r DIR
fi
[ -n "$DIR" ] || exit 0                     # cancelled
DIR="${DIR%/}"

# --- 2. is it already a Bodega project? ------------------------------------
if [ -f "$DIR/factory/STATE.md" ] && [ -f "$DIR/scripts/start.sh" ]; then
  MODE="resume"
else
  COUNT="$(find "$DIR" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')"
  MSG="Set up a new Software Bodega project in:

$DIR

($COUNT existing item(s) — nothing will be overwritten.)"
  if [ -n "$ARG_DIR" ]; then
    OK=0
  elif command -v zenity >/dev/null 2>&1; then
    zenity --question --title="Software Bodega" --text="$MSG" >/dev/null 2>&1; OK=$?
  elif command -v kdialog >/dev/null 2>&1; then
    kdialog --yesno "$MSG" >/dev/null 2>&1; OK=$?
  else
    printf '%s\n\nSet up? [y/N] ' "$MSG" >&2
    read -r reply
    case "$reply" in [Yy]*) OK=0 ;; *) OK=1 ;; esac
  fi
  [ "$OK" = "0" ] || exit 0
  MODE="init"
fi

# --- 3. initialise from the template (never destructive) -------------------
if [ "$MODE" = "init" ]; then
  mkdir -p "$DIR" || die "Cannot create $DIR"
  # Never destructive, and now provably so. `cp -R` used to overwrite any
  # same-named file the human already had — README.md, AGENTS.md, anything under
  # .github/, and any scripts/*.sh with a matching name — while the dialog above
  # said "nothing will be deleted". scripts/lib/merge.sh scans first, refuses
  # (writing nothing) when Bodega machinery would be replaced, installs docs and
  # workflows under distinct names otherwise, and verifies the result by bytes.
  # shellcheck disable=SC1091
  . "$TEMPLATE/scripts/lib/merge.sh"
  bodega_merge "$TEMPLATE" "$DIR" || die "$(bodega_merge_conflict_message)"
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

TITLE="Software Bodega — $(basename "$DIR")"
CMD="cd $(printf '%q' "$DIR") && bash scripts/start.sh"

if   command -v gnome-terminal    >/dev/null 2>&1; then gnome-terminal --title="$TITLE" -- bash -lc "$CMD; exec bash"
elif command -v konsole           >/dev/null 2>&1; then konsole -p tabtitle="$TITLE" -e bash -lc "$CMD; exec bash" &
elif command -v xfce4-terminal    >/dev/null 2>&1; then xfce4-terminal --title="$TITLE" -e "bash -lc '$CMD; exec bash'" &
elif command -v alacritty         >/dev/null 2>&1; then alacritty -t "$TITLE" -e bash -lc "$CMD; exec bash" &
elif command -v kitty             >/dev/null 2>&1; then kitty --title "$TITLE" bash -lc "$CMD; exec bash" &
elif command -v x-terminal-emulator >/dev/null 2>&1; then x-terminal-emulator -e bash -lc "$CMD; exec bash" &
elif command -v xterm             >/dev/null 2>&1; then xterm -T "$TITLE" -e bash -lc "$CMD; exec bash" &
else
  # Headless, SSH, or WSL — run here rather than failing.
  echo "Software Bodega: no terminal emulator found; running in this shell."
  cd "$DIR" && exec bash scripts/start.sh
fi

echo "Software Bodega: launched at $DIR ($MODE)"
