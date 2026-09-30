#!/usr/bin/env bash
# scripts/lib/merge.sh — install Bodega's machinery into a project folder without
# overwriting a single existing file. Source this; do not execute it.
#
# The launcher dialog says "nothing will be deleted". `cp -R` made that a lie:
# pointed at a folder that already had README.md, AGENTS.md,
# .github/workflows/*.yml or scripts/deploy.sh, it silently replaced them with
# Bodega's copies. The user's content was gone and the only record was the
# sentence promising the opposite.
#
# Policy, decided per file BEFORE anything is written:
#
#   1. MACHINERY (scripts/, skills/, foreman/, models.env, docs/) — these must
#      be Bodega's bytes or the factory is not the factory. A collision aborts
#      the whole merge with nothing written. Half-merging into a folder whose
#      scripts/start.sh is somebody else's file yields a project that runs the
#      human's script while believing it is Bodega's: worse than refusing.
#   2. DOCUMENTS AND WORKFLOWS (README.md, AGENTS.md, .github/**) — installed
#      side by side under a distinct name and REPORTED. Renamed rather than
#      skipped, because a skipped .github/workflows/factory.yml means the held-out
#      CI gates quietly never exist, and silence about that is the same bug.
#   3. Nothing is ever overwritten. `cp -R -n` enforces it even if the pre-flight
#      scan above misses a case.
#
# Every skipped or renamed path is recorded so the launcher can show receipts for
# its promise instead of asserting it.

# Paths whose absence or collision makes the factory unrunnable. ONE PER LINE —
# membership is tested with `grep -qxF`, and a space-separated list would match
# nothing, quietly reclassifying every machinery collision as a harmless rename.
BODEGA_REQUIRED='scripts/start.sh
scripts/bootstrap.sh
scripts/nightshift.sh
scripts/inspect.sh
scripts/runner.sh
scripts/selftest.sh
scripts/toolchain.sh
scripts/triage.sh
scripts/fix-round.sh
scripts/lib/status.sh
scripts/lib/toolchain.sh
scripts/lib/verify.sh
scripts/lib/merge.sh
scripts/lib/schemas.py
scripts/lib/local-model.sh
scripts/tests/test-seal.sh
scripts/tests/test-nightshift.sh
scripts/tests/test-toolchain.sh
skills/conductor/SKILL.md
skills/night-task/SKILL.md
skills/exam-board/SKILL.md
skills/work-order/SKILL.md
skills/inspector/SKILL.md
skills/blueprint/SKILL.md
skills/spec-freeze/SKILL.md
skills/triage/SKILL.md
skills/factory-interview/SKILL.md
models.env'


# Top-level entries a Bodega project needs.
bodega_merge_items() { printf '%s\n' skills scripts foreman docs models.env AGENTS.md README.md .github; }

# bodega_is_junk <rel-path> : build artifacts that must never be installed.
#
# A template accumulates __pycache__/ and .DS_Store from local test runs, and the
# merge walks EVERY file under scripts/ and foreman/ — so 28 stale .pyc files
# from my own verification run would otherwise ship into every project you
# initialize. The byte-for-byte machinery check still passes on such a project;
# it is just polluted, and the junk is what the copy loop would faithfully copy.
bodega_is_junk() {
  case "$1" in
    *__pycache__*|*.pyc|*.pyo|.DS_Store|*/.DS_Store) return 0 ;;
    *) return 1 ;;
  esac
}

# bodega_list_files <template> <item> : regular files under <item>, junk filtered
bodega_list_files() {
  ( cd "$1" && find "$2" -type f 2>/dev/null ) | while IFS= read -r r; do
    bodega_is_junk "$r" || printf '%s\n' "$r"
  done
}

# bodega_is_required <rel-path>
bodega_is_required() {
  case "$1" in
    scripts/*|skills/*|foreman/*|models.env) printf '%s\n' "$BODEGA_REQUIRED" | grep -qxF "$1" ;;
    *) return 1 ;;
  esac
}

# bodega_alt_name <rel-path> : where a colliding non-required file goes instead.
bodega_alt_name() {
  case "$1" in
    *.md)                 printf '%s' "${1%.md}.bodega.md" ;;
    .github/workflows/*)  printf '.github/workflows/bodega-%s' "${1#.github/workflows/}" ;;
    *)                    printf '%s.bodega' "$1" ;;
  esac
}

# bodega_merge_check <template> <dest>
# -> 0 when the merge is safe. 1 with the blocking conflicts on stderr.
# Sets BODEGA_MERGE_CONFLICTS (blocking) and BODEGA_MERGE_RENAMES (a->b pairs).
bodega_merge_check() {
  local tpl="$1" dest="$2" item rel conflicts="" renames=""
  BODEGA_MERGE_CONFLICTS=""; BODEGA_MERGE_RENAMES=""; BODEGA_MERGE_IGNORE=""
  for item in $(bodega_merge_items); do
    [ -e "$tpl/$item" ] || continue
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -e "$dest/$rel" ] || continue
      # Same bytes already there? Then there is nothing to do and nothing to say.
      if [ -f "$tpl/$rel" ] && cmp -s "$tpl/$rel" "$dest/$rel"; then continue; fi
      if bodega_is_required "$rel"; then
        conflicts="${conflicts}${rel}\n"
      else
        renames="${renames}${rel}->$(bodega_alt_name "$rel")\n"
      fi
    done < <(bodega_list_files "$tpl" "$item")
  done
  BODEGA_MERGE_CONFLICTS="$(printf '%b' "$conflicts" | sed '/^$/d')"
  BODEGA_MERGE_RENAMES="$(printf '%b' "$renames" | sed '/^$/d')"
  [ -n "$BODEGA_MERGE_CONFLICTS" ] && return 1
  return 0
}

# bodega_merge <template> <dest> : the no-clobber install.
# Returns 1, having written NOTHING, when required machinery would collide.
bodega_merge() {
  local tpl="$1" dest="$2" item rel alt copy_fail=""
  bodega_merge_check "$tpl" "$dest" || return 1
  BODEGA_MERGE_IGNORE=""
  # Explicit per-file walk, NOT `cp -R -n`. BSD cp exits NON-ZERO when -n skips
  # a file, so the natural-looking `cp -R -n a b || cp -R a b` fallback runs the
  # clobbering copy on exactly the case it was there to prevent — measured: the
  # human's README.md was replaced by Bodega's and the launcher still reported a
  # clean merge. Copying file by file is portable and there is nothing to fall
  # back to.
  for item in $(bodega_merge_items); do
    [ -e "$tpl/$item" ] || { copy_fail="$copy_fail $item(missing-in-template)"; continue; }
    if [ -f "$tpl/$item" ]; then
      [ -e "$dest/$item" ] || cp -p "$tpl/$item" "$dest/$item" || copy_fail="$copy_fail $item"
      continue
    fi
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -e "$dest/$rel" ] && continue
      mkdir -p "$(dirname "$dest/$rel")" || { copy_fail="$copy_fail $rel"; continue; }
      cp -p "$tpl/$rel" "$dest/$rel" || copy_fail="$copy_fail $rel"
    done < <(bodega_list_files "$tpl" "$item")
  done
  [ -n "$copy_fail" ] && { printf 'could not copy into %s:%s\n' "$dest" "$copy_fail" >&2; return 1; }
  # Colliding documents were skipped by -n; install them under their alt names.
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    rel="${pair%%->*}"; alt="${pair##*->}"
    mkdir -p "$(dirname "$dest/$alt")" 2>/dev/null
    # If the alt name is ALSO taken, do not overwrite that either — report it.
    if [ -e "$dest/$alt" ]; then
      if cmp -s "$tpl/$rel" "$dest/$alt"; then continue; fi
      printf 'could not install %s: %s already exists and differs\n' "$rel" "$alt" >&2
      return 1
    fi
    cp -p "$tpl/$rel" "$dest/$alt" || { printf 'could not install %s as %s\n' "$rel" "$alt" >&2; return 1; }
  done <<PAIRS
$BODEGA_MERGE_RENAMES
PAIRS
  # Post-condition, checked not assumed: the required machinery must exist AND be
  # the template's bytes.
  local req
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    # A required path missing from the TEMPLATE is a broken checkout, not a
    # collision — say which so the fix is obvious instead of blaming $dest.
    [ -e "$tpl/$req" ] || { printf 'template is missing required file: %s/%s\n' "$tpl" "$req" >&2; return 1; }
    [ -e "$dest/$req" ] || { printf 'setup incomplete: %s/%s missing after copy\n' "$dest" "$req" >&2; return 1; }
    if [ -f "$tpl/$req" ] && ! cmp -s "$tpl/$req" "$dest/$req"; then
      printf 'setup incomplete: %s/%s exists but is not the template copy\n' "$dest" "$req" >&2
      return 1
    fi
  done <<REQ
$BODEGA_REQUIRED
REQ
  # Machinery verified, so the ignore rules can be appended: a project whose
  # sandbox is not ignored is a project that commits its own nested worktree.
  bodega_merge_gitignore "$tpl" "$dest" || {
    printf 'could not update %s/.gitignore\n' "$dest" >&2; return 1; }
  return 0
}

# bodega_merge_report : what the human needs to know about their own files.
bodega_merge_gitignore() {
  local tpl="$1" dest="$2" line
  [ -f "$tpl/.gitignore" ] || return 0
  # A .gitignore is a SET, not a document: appending Bodega's lines keeps every
  # line the human already wrote, and dropping the file would leave the sealed
  # sandbox (.foreman-sandbox/) visible to `git add -A` in the salvage path,
  # where it lands as a mode-160000 gitlink. Never -n-skip, never rename: an
  # ignored file at .gitignore.bodega does nothing at all.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    if [ -f "$dest/.gitignore" ]; then
      grep -qxF "$line" "$dest/.gitignore" 2>/dev/null && continue
      printf '%s\n' "$line" >> "$dest/.gitignore" || return 1
    else
      printf '%s\n' "$line" > "$dest/.gitignore" || return 1
    fi
    BODEGA_MERGE_IGNORE="${BODEGA_MERGE_IGNORE}${line}\n"
  done < "$tpl/.gitignore"
  return 0
}

bodega_merge_report() {
  local n
  if [ -n "$(printf '%b' "${BODEGA_MERGE_IGNORE:-}" | sed '/^$/d')" ]; then
    printf 'Software Bodega: appended these to your .gitignore (nothing removed):\n'
    printf '%b' "${BODEGA_MERGE_IGNORE:-}" | sed '/^$/d' | sed 's/^/    /'
  fi
  n="$(printf '%s\n' "$BODEGA_MERGE_RENAMES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$n" = "0" ]; then
    printf 'Software Bodega: no existing files were in the way.\n'
    return 0
  fi
  printf 'Software Bodega: your %s existing file(s) were left exactly as they are;\n' "$n"
  printf '  Bodega installed these alongside them:\n' 
  printf '%s\n' "$BODEGA_MERGE_RENAMES" | sed '/^$/d' | sed 's/^/    /'
  printf '  (merge AGENTS.bodega.md into your AGENTS.md if you want the station rules there)\n'
}

# bodega_merge_conflict_message : the abort text for a required collision.
bodega_merge_conflict_message() {
  printf 'Software Bodega cannot set up here without overwriting your files.\n\n'
  printf 'These paths already exist, and the factory cannot run as anything else:\n'
  printf '%s\n' "$BODEGA_MERGE_CONFLICTS" | sed '/^$/d' | sed 's/^/    /'
  printf '\nNothing was written. Options:\n'
  printf '  1. Move those files aside, then run the launcher again.\n'
  printf '  2. Set up in an empty folder and copy your work in afterwards.\n'
}

# --- command line ----------------------------------------------------------
# Callable as `bash scripts/lib/merge.sh <template> <dest>` so the Windows
# launcher enforces the SAME no-clobber policy through the bash it already
# requires, instead of re-implementing it in PowerShell and drifting. The guard
# keeps this inert when the file is sourced, which is how the shell launchers
# use it.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  mode="${1:-}"
  case "$mode" in
    check)
      if bodega_merge_check "${2:-.}" "${3:-.}"; then
        bodega_merge_report
        exit 0
      fi
      bodega_merge_conflict_message
      exit 1
      ;;
    "")
      printf 'usage: merge.sh <template> <dest> | merge.sh check <template> <dest>\n' >&2
      exit 2
      ;;
    *)
      tpl="$mode"
      dest="${2:-}"
      if [ -z "$dest" ]; then
        printf 'merge.sh: need <template> <dest>\n' >&2
        exit 2
      fi
      if bodega_merge "$tpl" "$dest"; then
        bodega_merge_report
        exit 0
      fi
      bodega_merge_conflict_message
      exit 1
      ;;
  esac
fi
