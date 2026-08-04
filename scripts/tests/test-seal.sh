#!/usr/bin/env bash
# test-seal.sh — prove the held-out seal is physical, not a prompt promise.
#
# Builds a repo containing both suites, creates a worker worktree the way
# runner.sh does, and asserts the held-out directory is NOT THERE while the
# visible suite IS. The assertion the spec asks for is literally
# `ls factory/tests/heldout` failing inside the worker environment.
#
# Usage: bash scripts/tests/test-seal.sh

set -uo pipefail
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'git -C "$TMP/repo" worktree remove --force "$TMP/wt" 2>/dev/null; rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO/factory/tests/visible" "$REPO/factory/tests/heldout" "$REPO/src"
cd "$REPO"
git init -q; git config user.email t@t; git config user.name t
echo "print('app')"                        > src/app.py
echo "assert True  # visible check"        > factory/tests/visible/test_basic.py
echo "assert True  # SECRET held-out check" > factory/tests/heldout/test_leak.py
echo "assert True  # SECRET perf check"     > factory/tests/heldout/test_perf.py
git add -A && git commit -qm init

echo "held-out seal"

# Both suites are in the repo to begin with — otherwise this proves nothing.
[ -f factory/tests/heldout/test_leak.py ] \
  && ok "held-out tests exist in the main checkout (baseline)" \
  || bad "baseline wrong: no held-out tests to hide"

# --- create the worker worktree exactly as runner.sh does -----------------
WT="$TMP/wt"
git worktree add -q --no-checkout -b worker "$WT" HEAD 2>/dev/null \
  || git worktree add -q --no-checkout --detach "$WT" HEAD
(
  cd "$WT" || exit 1
  git sparse-checkout init --no-cone -q 2>/dev/null
  git sparse-checkout set '/*' '!/factory/tests/heldout/' '!/factory/tests/heldout/*' -q 2>/dev/null
  git checkout -q 2>/dev/null
  rm -rf factory/tests/heldout 2>/dev/null
)

# --- the assertion the spec names ----------------------------------------
if ( cd "$WT" && ls factory/tests/heldout ) >/dev/null 2>&1; then
  bad "\`ls factory/tests/heldout\` SUCCEEDED in the worker tree — seal broken"
else
  ok "\`ls factory/tests/heldout\` fails in the worker tree (seal holds)"
fi

# No held-out file reachable by any path, including by content search.
LEAKED="$(find "$WT" -path '*/heldout/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEAKED" = "0" ] && ok "no held-out file anywhere under the worker tree" \
  || bad "$LEAKED held-out files found in the worker tree"
if grep -rq "SECRET" "$WT" 2>/dev/null; then
  bad "held-out test CONTENT is readable in the worker tree"
else
  ok "held-out test content is unreachable by content search"
fi

# The worker must still get everything it legitimately needs.
[ -f "$WT/factory/tests/visible/test_basic.py" ] \
  && ok "visible suite IS present in the worker tree" \
  || bad "visible suite missing — worker cannot drive TDD"
[ -f "$WT/src/app.py" ] && ok "source tree is present in the worker tree" \
  || bad "source missing from worker tree"

# A worker that re-creates the directory must not thereby smuggle anything in:
# the seal is about what it can READ, and a fresh empty dir carries no content.
( cd "$WT" && mkdir -p factory/tests/heldout && echo "assert False" > factory/tests/heldout/fake.py )
if grep -rq "SECRET" "$WT" 2>/dev/null; then
  bad "recreating the directory exposed real held-out content"
else
  ok "a worker recreating heldout/ still cannot see the real checks"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
