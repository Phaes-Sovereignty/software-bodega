#!/usr/bin/env bash
# test-seal.sh — prove the held-out seal is PHYSICAL, and prove it via the same
# function the product calls.
#
# This file used to re-type four git commands to build its own worktree, then
# assert the directory was gone. That tested the transcription: widening or
# breaking runner.sh's pattern list left this green. Now it calls
# create_sealed_tree from scripts/lib/toolchain.sh, which scripts/runner.sh calls
# too — one implementation, one test of it.
#
# Usage: bash scripts/tests/test-seal.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
REPO="$TMP/repo"; WT="$TMP/wt"
trap 'git -C "$REPO" worktree remove --force "$WT" 2>/dev/null; rm -rf "$TMP"' EXIT

mkdir -p "$REPO/factory/tests/visible" "$REPO/factory/tests/heldout" "$REPO/src"
cd "$REPO" || exit 1
git init -q; git config user.email t@t; git config user.name t
echo "print('app')"                         > src/app.py
echo "assert True  # visible check"         > factory/tests/visible/test_basic.py
echo "assert True  # SECRET heldout check"  > factory/tests/heldout/test_leak.py
echo "assert True  # SECRET perf check"     > factory/tests/heldout/test_perf.py
git add -A && git commit -qm init

# shellcheck disable=SC1091
. "$SRC/scripts/lib/status.sh"

echo "held-out seal (via create_sealed_tree)"

[ -f factory/tests/heldout/test_leak.py ] \
  && ok "held-out tests exist in the main checkout (baseline)" \
  || { bad "baseline wrong: no held-out tests to hide"; exit 1; }

# --- the product's own function --------------------------------------------
if create_sealed_tree "$REPO" "$WT" "worker" HEAD; then
  ok "create_sealed_tree succeeded"
else
  bad "create_sealed_tree failed: $(create_sealed_tree "$REPO" "$WT2" "worker2" HEAD 2>&1 | head -1)"
fi

# The assertion the spec names, literally.
if ( cd "$WT" && ls factory/tests/heldout ) >/dev/null 2>&1; then
  bad "\`ls factory/tests/heldout\` SUCCEEDED in the worker tree — seal broken"
else
  ok "\`ls factory/tests/heldout\` fails in the worker tree (seal holds)"
fi

LEAKED="$(find "$WT" -path '*/heldout/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
[ "$LEAKED" = "0" ] && ok "no held-out file anywhere under the worker tree" \
  || bad "$LEAKED held-out file(s) found in the worker tree"

if grep -rq "SECRET" "$WT" 2>/dev/null; then
  bad "held-out test CONTENT is readable in the worker tree"
else
  ok "held-out test content is unreachable by content search"
fi

# The worker must still get everything it legitimately needs — and this is the
# check that makes the seal non-vacuous. An empty checkout "passes" every
# assertion above while leaving the worker with no code.
[ -f "$WT/factory/tests/visible/test_basic.py" ] \
  && ok "visible suite IS present in the worker tree" \
  || bad "visible suite missing — worker cannot drive TDD"
[ -f "$WT/src/app.py" ] && ok "source tree is present in the worker tree" \
  || bad "source missing from worker tree"

# --- the two historical seal bugs, reproduced ------------------------------
# Both were real, both were invisible, and they fail in OPPOSITE directions.
#
#   BUG A (`-q` on sparse-checkout init/set, which git rejects with 129, into
#   /dev/null): the patterns are never written, so the checkout materialises
#   EVERYTHING. The exam is present and readable, while the log says "seal
#   verified". A security hole that reports itself as closed.
#
#   BUG B (`git sparse-checkout set $(sparse_patterns)`, unquoted): the shell
#   glob-expands the leading `/*` into /Applications /Library /Users ..., the
#   checkout comes back EMPTY, and "the held-out directory is absent" is
#   trivially true. A vacuous pass that also leaves the worker with no code.

echo "  bug A: -q on sparse-checkout init/set"
AWT="$TMP/leakwt"
git worktree add -q --no-checkout --detach "$AWT" HEAD 2>/dev/null
(
  cd "$AWT" || exit 1
  git sparse-checkout init --no-cone -q 2>/dev/null       # rejected, rc 129
  git sparse-checkout set -q '/*' '!/factory/tests/heldout/' 2>/dev/null
  git checkout -q 2>/dev/null
) >/dev/null 2>&1
if grep -rq "SECRET" "$AWT" 2>/dev/null; then
  ok "reproduced: with -q the patterns never apply and the EXAM IS READABLE"
else
  bad "could not reproduce bug A — the -q guard would be untested"
fi
# ...and the shipped function must refuse to produce such a tree.
tree_is_sealed "$AWT" >/dev/null 2>&1 \
  && bad "tree_is_sealed ACCEPTED a tree containing the exam" \
  || ok "tree_is_sealed refuses that tree (it checks the declared directory)"

echo "  bug B: unquoted \$(sparse_patterns) glob-expands"
BWT="$TMP/badwt"
git worktree add -q --no-checkout --detach "$BWT" HEAD 2>/dev/null
(
  cd "$BWT" || exit 1
  # init WITHOUT -q so it succeeds: otherwise bug A masks bug B and the glob
  # never gets a chance to fire. Each bug is reproduced in isolation.
  git sparse-checkout init --no-cone 2>/dev/null
  # shellcheck disable=SC2046
  git sparse-checkout set $(sparse_patterns) 2>/dev/null   # /* -> /Applications ...
  git checkout -q 2>/dev/null
) >/dev/null 2>&1
BADCOUNT="$(find "$BWT" -type f -not -path '*/.git/*' -not -name .git 2>/dev/null | wc -l | tr -d ' ')"
BADPAT="$(head -1 "$(cd "$BWT" && git rev-parse --absolute-git-dir)/info/sparse-checkout" 2>/dev/null)"
if [ "${BADCOUNT:-99}" -eq 0 ]; then
  ok "reproduced: the glob bug yields an EMPTY tree (first pattern: '$BADPAT')"
else
  bad "could not reproduce bug B (got $BADCOUNT file(s), pattern '$BADPAT')"
fi
if tree_is_sealed "$BWT" >/dev/null 2>&1; then
  ok "absence alone calls that empty tree SEALED — which is why the count guard exists"
else
  bad "tree_is_sealed unexpectedly rejected the empty tree"
fi
# create_sealed_tree adds the count guard, so it must refuse the same outcome.
if ( cd "$REPO" && create_sealed_tree "$REPO" "$TMP/countwt" "" HEAD ) >/dev/null 2>&1 \
   && [ -f "$TMP/countwt/src/app.py" ]; then
  ok "create_sealed_tree yields a sealed tree that still HAS the source"
else
  bad "create_sealed_tree could not produce a usable sealed tree"
fi

# --- a worker re-creating the directory smuggles nothing --------------------
( cd "$WT" && mkdir -p factory/tests/heldout && echo "assert False" > factory/tests/heldout/fake.py )
grep -rq "SECRET" "$WT" 2>/dev/null \
  && bad "recreating the directory exposed real held-out content" \
  || ok "a worker recreating heldout/ still cannot see the real checks"

# --- the DECLARED path is what gets sealed ---------------------------------
# Same repo, different declaration: this is the Swift case. Sealing the default
# path here would leave the exam readable while reporting success.
SWREPO="$TMP/sw"; mkdir -p "$SWREPO/Tests/HeldoutTests" "$SWREPO/Tests/VisibleTests" "$SWREPO/src"
cd "$SWREPO" || exit 1
git init -q; git config user.email t@t; git config user.name t
echo "func a() {}" > src/A.swift
echo "// visible"   > Tests/VisibleTests/V.swift
echo "// SECRET heldout" > Tests/HeldoutTests/H.swift
mkdir -p factory && printf "HELDOUT_DIR='Tests/HeldoutTests'\n" > factory/toolchain.env
git add -A && git commit -qm init
SWT="$TMP/swt"
# FACTORY_ROOT must name the SWIFT repo. Sourcing the lib while FACTORY_ROOT still
# points at the template loads the TEMPLATE's toolchain.env, and the seal then
# removes a directory this project does not use while the test believes it proved
# the declared path works. (status.sh exports FACTORY_ROOT, so a parent shell
# that sourced it leaks the value into every child — the same reason
# toolchain.sh recomputes rather than inherits.)
( FACTORY_ROOT="$SWREPO" . "$SRC/scripts/lib/status.sh"
  create_sealed_tree "$SWREPO" "$SWT" "" HEAD ) \
  && ok "declared HELDOUT_DIR=Tests/HeldoutTests seals the SWIFT path" \
  || bad "could not seal using the declared directory"
[ -d "$SWT/Tests/HeldoutTests" ] && bad "Swift held-out target survived the seal" \
  || ok "Swift held-out target absent from the worker tree"
grep -rq "SECRET heldout" "$SWT" 2>/dev/null && bad "Swift held-out CONTENT reachable" \
  || ok "Swift held-out content unreachable by content search"
[ -f "$SWT/Tests/VisibleTests/V.swift" ] && ok "Swift visible target present in worker tree" \
  || bad "Swift visible target missing — worker cannot build its tests"
[ -f "$SWT/src/A.swift" ] && ok "Swift source present (seal is not an empty checkout)" \
  || bad "Swift source missing — vacuous seal"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
