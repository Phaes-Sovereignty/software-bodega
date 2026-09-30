#!/usr/bin/env bash
# test-fixround.sh — the fix round on a COMPILED project must be able to do
# anything at all, and its tamper guard must actually revert.
#
# Three defects this pins, none of which a grep could see:
#
#  1. fix-round counted failures with a python-unittest grep. A Swift receipt has
#     no `failures=N` marker, so awk's `END{print s+0}` reports ZERO. BASE and
#     AFTER were both 0, the regression test `0 > 0` was false, and a round that
#     broke the suite — or could not compile it — was credited with a clean result
#     and COMMITTED.
#
#  2. The guard ran `git checkout -- "$VISIBLE_DIR" "$HELDOUT_DIR" factory/tests
#     factory/CONTRACT.md`. git diff tolerates an absent pathspec; git checkout
#     ERRORS on one and reverts nothing. In a Swift project `factory/tests` does
#     not exist, so the revert was a no-op on exactly the paths that mattered.
#
#  3. `git diff` only sees tracked files, and a real project .gitignores its
#     held-out directory — so a worker ADDING an exam file was invisible to the
#     guard and the selective commit then added it by name.
#
# Usage: bash scripts/tests/test-fixround.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mkproj() { # mkproj <name> <behaviour>
  local d="$TMP/$1" behaviour="$2"
  rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/skills/night-task" "$d/factory" \
    "$d/Tests/VisibleTests" "$d/Tests/HeldoutTests" "$d/src" "$d/bin"
  cp "$SRC"/scripts/fix-round.sh "$d/scripts/"
  cp "$SRC"/scripts/lib/*.sh "$d/scripts/lib/"
  printf 'worker skill\n' > "$d/skills/night-task/SKILL.md"
  : > "$d/factory/progress.md"; : > "$d/factory/log.md"
  printf 'STAGE: INSPECTED\nPOINTER: -\n' > "$d/factory/STATE.md"
  printf '# contract\nAC-1 trims\n' > "$d/factory/CONTRACT.md"
  printf 'Verdict on abc: FIX FIRST\n\n- AC-1 violated\n' > "$d/factory/REVIEW.md"
  {
    printf "HELDOUT_DIR='Tests/HeldoutTests'\n"
    printf "VISIBLE_DIR='Tests/VisibleTests'\n"
    printf "VISIBLE_CMD='bash Tests/VisibleTests/run.sh'\n"
    printf "HELDOUT_CMD='true'\n"
  } > "$d/factory/toolchain.env"
  # XCTest-shaped receipt: no `failures=N` anywhere. This is the input the old
  # grep could not read.
  cat > "$d/Tests/VisibleTests/run.sh" <<'GATE'
#!/usr/bin/env bash
if [ -f src/fix.txt ]; then
  printf "Test Suite 'Selected tests' passed\n\tExecuted 1 test, with 0 failures\n"
  exit 0
fi
printf "Test Suite 'Selected tests' failed\n\tExecuted 1 test, with 1 failure\n"
exit 1
GATE
  chmod +x "$d/Tests/VisibleTests/run.sh"
  # A tracked visible test, and a gitignored held-out dir (the documented layout).
  printf '// visible check\n' > "$d/Tests/VisibleTests/V.swift"
  printf '// held-out check\n' > "$d/Tests/HeldoutTests/H.swift"
  printf 'Tests/HeldoutTests/\n' > "$d/.gitignore"
  case "$behaviour" in
    fix)
      cat > "$d/bin/worker" <<'S'
#!/usr/bin/env bash
mkdir -p "$PWD/src"; echo fixed > "$PWD/src/fix.txt"
printf -- '---FACTORY_STATUS---\nSTATION: fix-round\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: implemented AC-1\nFILES: src/fix.txt\n---END---\n'
S
      ;;
    breakit)
      # ships a regression AND adds a file to the (gitignored) exam dir
      cat > "$d/bin/worker" <<'S'
#!/usr/bin/env bash
rm -f "$PWD/src/fix.txt"
printf '// ADDED BY WORKER to make the exam pass\n' > "$PWD/Tests/HeldoutTests/SNEAK.swift"
printf -- '---FACTORY_STATUS---\nSTATION: fix-round\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: simplified the exam\nFILES: Tests/HeldoutTests/SNEAK.swift\n---END---\n'
S
      ;;
  esac
  chmod +x "$d/bin/worker"
  cat > "$d/models.env" <<ENV
EXECUTOR_CMD='$d/bin/worker'
EXECUTOR_FAMILY='xai'
EXECUTOR_INPUT='arg'
JUDGE_FAMILY='anthropic'
PLANNER_FAMILY='anthropic'
ENV
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$d"
}

echo "fix round — receipt parsing on a compiled project"

# --- 0. the two parsers disagree, and the old one is blind ------------------
D="$(mkproj good fix)"
# NOT in a subshell: ok/bad increment PASS/FAIL, and a subshell discards them, so
# a failing assertion in here would print ✗ and still exit 0.
cd "$D" || exit 1
# shellcheck disable=SC1091
. scripts/lib/verify.sh
printf "Executed 1 test, with 1 failure\n" > "$TMP/sw.log"
LAST_TEST_RC=1
shared="$(fail_count "$TMP/sw.log")"
old="$(grep -oE '(failures|errors)=[0-9]+' "$TMP/sw.log" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')"
[ "$shared" = "1" ] && ok "shared fail_count reads the Swift receipt as 1 failure" \
  || bad "fail_count returned '$shared' on a Swift receipt"
[ "$old" = "0" ] && ok "confirmed: the old grep reports 0 failures for a FAILING Swift run (the defect)" \
  || bad "old grep returned '$old' — this test would no longer pin the defect"
cd "$SRC" || exit 1

# --- 1. a real fix commits --------------------------------------------------
( cd "$D" && env -u FACTORY_ROOT bash scripts/fix-round.sh --max-rounds 1 >"$D/fix.log" 2>&1 )
grep -q "REGRESSED" "$D/fix.log" \
  && bad "a correct fix was called a regression: $(grep -m1 REGRESSED "$D/fix.log")" \
  || ok "no phantom regression on a Swift-style receipt"
grep -qE "^FIX-1\|DONE\|" "$D/factory/progress.md" \
  && ok "the fix round committed its work (FIX-1 DONE in progress.md)" \
  || { bad "fix round recorded nothing: $(tail -2 "$D/factory/progress.md" | tr '\n' '|')"; \
       sed -n '1,10p' "$D/fix.log" | sed 's/^/      /'; }
git -C "$D" show --name-only --format= HEAD 2>/dev/null | grep -q "src/fix.txt" \
  && ok "the commit contains the worker's fix" || bad "the fix never reached a commit"

echo "fix round — tamper guard"

# --- 2. a regressing worker is caught, not credited -------------------------
E="$(mkproj bad breakit)"
( cd "$E" && env -u FACTORY_ROOT bash scripts/fix-round.sh --max-rounds 1 >"$E/fix.log" 2>&1 )
# With the old parser this run looked clean (0 vs 0). It must now be refused.
if grep -qE "REGRESSED|TAMPERED|untracked" "$E/factory/log.md" "$E/fix.log" 2>/dev/null; then
  ok "the breaking round was caught (regression or tamper recorded)"
else
  bad "the breaking round passed unchallenged — the parser or the guard is blind again"
  sed -n '1,12p' "$E/fix.log" | sed 's/^/      /'
fi

# --- 3. an ADDED file in the gitignored exam dir is removed -----------------
if [ -f "$E/Tests/HeldoutTests/SNEAK.swift" ]; then
  bad "the added held-out file SURVIVED — git diff cannot see untracked files"
else
  ok "an added file under the declared held-out dir was REMOVED"
fi
grep -q "tamper_untracked_removed" "$E/factory/log.md" 2>/dev/null \
  && ok "the untracked-exam addition is recorded in the diary" \
  || bad "no tamper_untracked_removed record — the addition was not noticed"
# and it must not have been committed
if git -C "$E" log --name-only --format= | grep -q "SNEAK.swift"; then
  bad "the smuggled exam file was COMMITTED"
else
  ok "the smuggled exam file never reached a commit"
fi

# --- 4. existing_pathspecs behaves ------------------------------------------
cd "$E" || exit 1
# shellcheck disable=SC1091
. scripts/lib/status.sh
existing_pathspecs A "Tests/HeldoutTests" "factory/tests" "factory/CONTRACT.md"
[ "${#A[@]}" = "2" ] \
  && ok "existing_pathspecs keeps the 2 real paths and drops the absent one" \
  || bad "expected 2 kept paths, got ${#A[@]}: [${A[*]-}]"
existing_pathspecs B "nope1" "nope2"
[ "${#B[@]}" = "0" ] \
  && ok "all-missing yields an EMPTY array, not one blank element" \
  || bad "empty case gave ${#B[@]} element(s): [${B[*]-}] — a blank pathspec aborts the revert"
# The regression this exists for: checkout on a missing pathspec is an error.
if git checkout -q -- "factory/tests" 2>/dev/null; then
  bad "git checkout accepted a missing pathspec — the old guard would not have been broken"
else
  ok "confirmed: git checkout ERRORS on a missing pathspec (why the filter is required)"
fi
cd "$SRC" || exit 1

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
