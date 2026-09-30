#!/usr/bin/env bash
# test-launcher.sh — prove the launcher's promise: nothing of yours is replaced.
#
# The dialog used to say "nothing will be deleted" while the code ran
# `cp -R "$TEMPLATE/$item" "$DIR/"`, which overwrites README.md, AGENTS.md, any
# same-named file under .github/, and any scripts/*.sh whose name collides. This
# test puts files in the way and checks the BYTES afterwards — not that the word
# "never" appears in a comment.
#
# Usage: bash scripts/tests/test-launcher.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A human project: exactly the files the old cp -R destroyed, plus a marker
# inside a nested one so we can tell "kept" from "recreated".
mkhuman() {
  local d="$1"
  mkdir -p "$d/.github/workflows" "$d/scripts" "$d/src"
  printf '# My project README\nDO NOT LOSE THIS LINE\n' > "$d/README.md"
  printf '# My agent rules\nMY RULE ONE\n'              > "$d/AGENTS.md"
  printf 'name: my-ci\njobs:\n  mine:\n    runs-on: ubuntu-latest\n' \
    > "$d/.github/workflows/ci.yml"
  printf '#!/usr/bin/env bash\n# my deploy script\necho deploy\n' > "$d/scripts/deploy.sh"
  printf 'package body\n' > "$d/src/main.py"
  printf '%s' "$d"
}

MERGE="$SRC/scripts/lib/merge.sh"
[ -f "$MERGE" ] || { bad "scripts/lib/merge.sh is missing"; printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

echo "launcher merge — no-clobber"

# --- 1. the machinery installs, the human files survive -------------------
D="$(mkhuman "$TMP/a")
"
D="$TMP/a"
OUT="$(bash "$MERGE" "$SRC" "$D" 2>&1)"; RC=$?
[ "$RC" = "0" ] && ok "merge into a folder with colliding docs succeeds (rc=0)" \
  || bad "merge refused a folder it should have handled: $OUT"
grep -q "DO NOT LOSE THIS LINE" "$D/README.md" \
  && ok "the human's README.md is byte-identical (not Bodega's)" \
  || bad "README.md WAS replaced — the exact defect the dialog denied"
grep -q "MY RULE ONE" "$D/AGENTS.md" \
  && ok "the human's AGENTS.md is byte-identical" \
  || bad "AGENTS.md WAS replaced"
grep -q "my-ci" "$D/.github/workflows/ci.yml" \
  && ok "the human's own workflow survived" \
  || bad "the human's .github/workflows/ci.yml was replaced"
grep -q "my deploy script" "$D/scripts/deploy.sh" \
  && ok "a same-named scripts/*.sh of the human's survived" \
  || bad "scripts/deploy.sh was clobbered"
grep -q "package body" "$D/src/main.py" \
  && ok "unrelated source is untouched" || bad "src/main.py changed"

# --- 2. Bodega's files are all present, not skipped into nothingness -------
for must in scripts/start.sh scripts/nightshift.sh scripts/toolchain.sh \
            scripts/lib/toolchain.sh scripts/lib/merge.sh scripts/lib/verify.sh \
            skills/conductor/SKILL.md models.env; do
  [ -f "$D/$must" ] || bad "MISSING after merge: $must"
done
[ -f "$D/scripts/start.sh" ] && cmp -s "$SRC/scripts/start.sh" "$D/scripts/start.sh" \
  && ok "Bodega machinery installed AND byte-identical to the template" \
  || bad "Bodega's scripts/start.sh is missing or differs from the template"
# The workflow that runs the held-out gates must exist under a distinct name.
[ -f "$D/.github/workflows/factory.yml" ] \
  && ok "Bodega's CI workflow installed (a skipped one would silently kill the gates)" \
  || bad "factory.yml is absent — skipping it is as bad as clobbering the human's"
[ -f "$D/README.bodega.md" ] && ok "Bodega's README landed alongside as README.bodega.md" \
  || bad "Bodega's README was dropped entirely (silently skipped)"
[ -f "$D/AGENTS.bodega.md" ] && ok "Bodega's AGENTS.md landed alongside as AGENTS.bodega.md" \
  || bad "Bodega's AGENTS.md was dropped entirely"
printf '%s' "$OUT" | grep -q "left exactly as they are" \
  && ok "the merge REPORTS what it protected (receipts, not a promise)" \
  || bad "the merge reported nothing about the collisions"

# --- 3. a collision on MACHINERY aborts with nothing written --------------
E="$(mkhuman "$TMP/b")"
printf '# somebody elses start.sh\n' > "$E/scripts/start.sh"
OUT2="$(bash "$MERGE" "$SRC" "$E" 2>&1)"; RC2=$?
[ "$RC2" != "0" ] && ok "a colliding scripts/start.sh ABORTS the merge (rc=$RC2)" \
  || bad "merge overwrote somebody's scripts/start.sh and reported success"
printf '%s' "$OUT2" | grep -q "start.sh" \
  && ok "the refusal names the conflicting path" \
  || bad "refusal did not say what conflicted"
printf '%s' "$OUT2" | grep -qi "nothing was written" \
  && ok "the refusal states that nothing was written" \
  || bad "refusal text does not reassure (and must, because it is true)"
[ ! -e "$E/skills/conductor/SKILL.md" ] \
  && ok "nothing half-installed: skills/ was not created" \
  || bad "merge wrote files AFTER deciding to abort — a half-project is worse"
grep -q "somebody elses start.sh" "$E/scripts/start.sh" \
  && ok "the existing start.sh is exactly as found" || bad "start.sh was modified anyway"

# --- 4. idempotence: running it twice changes nothing ---------------------
F="$(mkhuman "$TMP/c")"
bash "$MERGE" "$SRC" "$F" >/dev/null 2>&1
BEFORE="$(cd "$F" && find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum)"
bash "$MERGE" "$SRC" "$F" >/dev/null 2>&1; RC3=$?
AFTER="$(cd "$F" && find . -type f -not -path './.git/*' | sort | xargs shasum 2>/dev/null | shasum)"
[ "$RC3" = "0" ] && ok "the second merge exits clean (a resume, not a re-scaffold)" \
  || bad "re-running the merge failed: rc=$RC3"
[ "$BEFORE" = "$AFTER" ] && ok "the second merge changed zero bytes" \
  || bad "re-running the merge mutated the project"

# --- 5. an empty folder gets a complete project ---------------------------
G="$TMP/d"; mkdir -p "$G"
bash "$MERGE" "$SRC" "$G" >/dev/null 2>&1
[ -f "$G/scripts/lib/toolchain.sh" ] && [ -f "$G/foreman/contracts.py" ] \
  && ok "an empty folder receives the full machinery (lib + foreman)" \
  || bad "empty-folder install incomplete"
# The installed project must be able to resolve its own toolchain — the real
# acceptance test for a scaffold: does the thing it installed actually run?
( cd "$G" && FACTORY_ROOT="$G" bash scripts/toolchain.sh get HELDOUT_DIR ) >/dev/null 2>&1 \
  && ok "the installed project's own scripts/toolchain.sh runs" \
  || bad "installed toolchain.sh is not runnable in the new project"

# --- 6. the launchers actually CALL the merge (not just ship it) -----------
# A library nobody sources is how HELDOUT_CMD sat unread: present, correct, inert.
#
# CODE ONLY, never comments: these files now contain prose describing the old
# clobbering command, and a grep over the whole file flags its own changelog.
# `code_lines` strips comment lines and heredoc-free prose before matching.
code_lines() { grep -vE '^[[:space:]]*(#|//)' "$1"; }

for L in Software-Bodega-mac.command Software-Bodega-mac-YOLO.command \
         Software-Bodega-linux.sh Software-Bodega-linux-YOLO.sh \
         Software-Bodega-windows.ps1 Software-Bodega-windows-YOLO.ps1; do
  [ -f "$SRC/$L" ] || { bad "$L missing"; continue; }
  case "$L" in
    *.ps1)
      code_lines "$SRC/$L" | grep -q "scripts/lib/merge.sh" \
        && ok "$L invokes the shared merge policy" \
        || bad "$L does not call merge.sh — its no-clobber promise is unenforced"
      code_lines "$SRC/$L" | grep -qE "Copy-Item.*-Force" \
        && bad "$L still CONTAINS a clobbering Copy-Item -Force" \
        || ok "$L has no clobbering copy left" ;;
    *)
      code_lines "$SRC/$L" | grep -qE "bodega_merge|lib/merge\\.sh" \
        && ok "$L invokes the shared merge policy" \
        || bad "$L does not call bodega_merge — its promise is unenforced"
      code_lines "$SRC/$L" | grep -qE 'cp -R "\$TEMPLATE/\$item"' \
        && bad "$L still CONTAINS the raw clobbering cp -R" \
        || ok "$L has no raw cp -R of template items left" ;;
  esac
done

# --- 6b. build junk is not installed ---------------------------------------
# A template picks up __pycache__/ and .DS_Store from local runs. The merge walks
# every file under scripts/ and foreman/, so without a filter those bytes ship to
# every project you initialize — and nothing downstream would notice.
JUNK="$(find "$G" \( -name '*.pyc' -o -name '*.pyo' -o -name '.DS_Store' -o -path '*__pycache__*' \) 2>/dev/null | wc -l | tr -d ' ')"
[ "${JUNK:-0}" = "0" ] \
  && ok "a fresh project receives zero build junk (.pyc/.DS_Store/__pycache__)" \
  || bad "$JUNK junk file(s) installed into the new project"
# the machinery is still complete after filtering
[ -f "$G/foreman/contracts.py" ] && [ -f "$G/scripts/lib/schemas.py" ] \
  && ok "filtering did not drop real python sources" || bad "real sources missing after the junk filter"

# --- 6c. .gitignore is APPENDED, not skipped or renamed --------------------
# .gitignore is a set, not a document. The general no-clobber policy would either
# leave the human's file untouched (so .foreman-sandbox/ is never ignored and the
# salvage path commits a nested worktree as a gitlink) or install it at
# .gitignore.bodega, which git reads as nothing at all.
H="$TMP/e"; mkdir -p "$H"
printf 'node_modules/\n.env\n' > "$H/.gitignore"
bash "$MERGE" "$SRC" "$H" >/dev/null 2>&1
grep -q '^node_modules/$' "$H/.gitignore" && grep -q '^\.env$' "$H/.gitignore" \
  && ok "the human's own ignore rules are still there" \
  || bad "existing .gitignore lines were lost: $(tr '\n' '|' < "$H/.gitignore")"
grep -q '^\.foreman-sandbox/$' "$H/.gitignore" \
  && ok "the template's sandbox ignore rule reached the project" \
  || bad ".foreman-sandbox/ not installed — a sealed night could commit a gitlink"
[ -e "$H/.gitignore.bodega" ] \
  && bad "the template .gitignore was renamed aside — an ignored ignore file does nothing" \
  || ok "no useless .gitignore.bodega was created"
# Idempotence: a second merge must not duplicate lines.
bash "$MERGE" "$SRC" "$H" >/dev/null 2>&1
[ "$(grep -c '^\.foreman-sandbox/$' "$H/.gitignore")" = "1" ] \
  && ok "re-merging does not duplicate the ignore entry" \
  || bad "duplicate .foreman-sandbox/ lines after a second merge"

# --- 7. the dialog text matches the behaviour ------------------------------
# The dialog is a string literal, not a comment: match the lines the user sees.
for L in Software-Bodega-mac.command Software-Bodega-mac-YOLO.command \
         Software-Bodega-linux.sh Software-Bodega-linux-YOLO.sh \
         Software-Bodega-windows.ps1 Software-Bodega-windows-YOLO.ps1; do
  if grep -nE 'existing item' "$SRC/$L" | grep -q "nothing will be deleted"; then
    bad "$L's USER-FACING dialog still says 'nothing will be deleted'"
  else
    ok "$L's dialog text describes what the merge actually does"
  fi
  grep -nE 'existing item' "$SRC/$L" | grep -q "nothing will be overwritten" \
    && : || bad "$L's dialog does not state the real guarantee"
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
