#!/usr/bin/env bash
# scripts/lib/toolchain.sh — one place that knows HOW this project is verified.
# Source this; do not execute it.
#
# Before this file existed, "where are the held-out tests" was answered in six
# places (the seal, CI's tarball, CI's scope check, runner.sh, inspect.sh and
# foreman/contracts.py) and every one of them said `factory/tests/heldout`. The
# exam-board skill tells a Swift project to write `Tests/HeldoutTests` instead,
# so the seal sealed a directory that would never exist and the held-out half of
# the design silently evaporated. Same root cause as the Sancho thesis: the
# declaration and the mechanism had no single source of truth.
#
# So: a project declares its toolchain in `factory/toolchain.env`, and everything
# downstream asks THIS file. The four values that matter:
#
#   HELDOUT_DIR   path (repo-root relative) the seal must remove and CI must
#                 reject in a PR. Default: factory/tests/heldout
#   VISIBLE_CMD   command that runs the visible suite. Default: the runner script
#   HELDOUT_CMD   command that runs the held-out suite. Default: the runner script
#   BUILD_CMD     optional; given to workers so they know how to compile
#
# Defaults preserve the Python path exactly, so a project with no
# factory/toolchain.env behaves precisely as it did before.

# --- load the project's declaration ---------------------------------------

# Remember where this library lives so reload_toolchain can re-source itself;
# inside a function BASH_SOURCE[0] is the CALLER, which is how a naive reload
# silently keeps serving the defaults it loaded before the profile existed.
TOOLCHAIN_LIB="${BASH_SOURCE[0]}"

# FACTORY_ROOT is set by status.sh; when this is sourced standalone (CI, tests)
# fall back to two directories up.
: "${FACTORY_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# The profile path is DERIVED from the project and recomputed on every source.
# It used to be `${TOOLCHAIN_ENV:-...}`, and exporting it meant the first shell
# that sourced this file pinned the answer for every child shell after it: the
# selftest sources status.sh, then runs the night-shift fixtures in subshells,
# and each fixture silently inherited the TEMPLATE's profile instead of loading
# its own. Same class of bug in production — resample worktrees run as child
# shells of the loop, so a worktree with a different toolchain.env would verify
# against the parent's commands. Point at another file with BODEGA_TOOLCHAIN_ENV.
TOOLCHAIN_ENV="${BODEGA_TOOLCHAIN_ENV:-$FACTORY_ROOT/factory/toolchain.env}"

# Every value below is reset before it is resolved, for the same reason: an
# inherited HELDOUT_DIR from a parent shell is a stale answer about a DIFFERENT
# project, and a stale HELDOUT_DIR is a seal that removes the wrong directory.
unset HELDOUT_DIR VISIBLE_DIR VISIBLE_CMD HELDOUT_CMD BUILD_CMD EXTRA_GATE_CMD 2>/dev/null

# Defaults for anything the project did not declare.
HELDOUT_DIR='factory/tests/heldout'
VISIBLE_DIR='factory/tests/visible'
EXTRA_GATE_CMD=''
BUILD_CMD=''
VISIBLE_CMD=''
HELDOUT_CMD=''
# A floor, not a decision: models.env normally sets this and the profile may
# override it. run_role's watchdog reads it, and an unset value there falls back
# to 1800s — which killed real exam-board work during the Phase B dry run.
FACTORY_ROLE_TIMEOUT="${FACTORY_ROLE_TIMEOUT:-3600}"

# shellcheck disable=SC1090
[ -f "$TOOLCHAIN_ENV" ] && . "$TOOLCHAIN_ENV"

# A declared empty value still means "fall back to the runner script".
[ -n "$VISIBLE_CMD" ] || VISIBLE_CMD='bash factory/tests/run-visible.sh'
[ -n "$HELDOUT_CMD" ] || HELDOUT_CMD='bash factory/tests/run-heldout.sh'
# An empty declared dir is a typo, not a choice: fall back, or every
# seal pattern below would exclude the repo root.
[ -n "$HELDOUT_DIR" ] || HELDOUT_DIR='factory/tests/heldout'

# Trailing slashes would break the sparse-checkout patterns and the path
# comparisons in CI.
HELDOUT_DIR="${HELDOUT_DIR%/}"
VISIBLE_DIR="${VISIBLE_DIR%/}"

# Deliberately NOT exported. FACTORY_ROOT is exported because it identifies the
# project to child processes; the resolved values must be re-derived there from
# that project's own profile, never inherited.
export FACTORY_ROOT

# reload_toolchain : re-read factory/toolchain.env after it has been written.
#
# The bootstrap pipeline writes the profile at the TOOLCHAIN stage and then needs
# it in the SAME shell for the exam stage. Sourcing again is not enough on its
# own: every default below is a `:=` assignment, so a stale value from the first
# source would survive. Unset first, then source.
reload_toolchain() {
  # shellcheck disable=SC1090
  . "$TOOLCHAIN_LIB"
}

# --- queries ---------------------------------------------------------------

# toolchain_is_declared : 0 when the project actually wrote a toolchain.env.
toolchain_is_declared() { [ -f "$TOOLCHAIN_ENV" ]; }

# heldout_basename : the last path segment, used by the leak scan.
heldout_basename() { printf '%s' "${HELDOUT_DIR##*/}"; }

# sparse_patterns : print the sealing patterns, one per line. Display and test
# only — see sparse_args for the form callers must use.
sparse_patterns() {
  printf '%s\n' '/*' "!/${HELDOUT_DIR}/" "!/${HELDOUT_DIR}/*"
}

# sparse_args : fill the array SPARSE_ARGS with the patterns, as separate words.
#
# Callers MUST use this rather than `git sparse-checkout set $(sparse_patterns)`.
# Unquoted command substitution word-splits AND glob-expands, and the first
# pattern is `/*` — which the shell happily expands to /Applications /Library
# /System /Users ... The result is a sparse file that excludes the entire
# filesystem except the repo's own top level, so the checkout comes back nearly
# empty and the "seal verified" line prints over a tree that has no source in it.
# Measured while writing scripts/tests/test-swift-cycle.sh.
sparse_args() {
  SPARSE_ARGS=('/*' "!/${HELDOUT_DIR}/" "!/${HELDOUT_DIR}/*")
}

# --- verification ----------------------------------------------------------

# run_visible_suite <outfile> : run the visible suite, capture the receipt.
# The exit code is the suite's. 127 means there is nothing to run — which is
# NEVER a pass.
run_visible_suite() {
  local out="${1:-/dev/null}"
  if [ -z "$VISIBLE_CMD" ] || { [ "$VISIBLE_CMD" = "bash factory/tests/run-visible.sh" ] \
      && [ ! -f factory/tests/run-visible.sh ]; }; then
    echo "no visible verification command — cannot verify" > "$out"
    return 127
  fi
  # Run in the CALLER's cwd, not $FACTORY_ROOT: a sealed worktree sets
  # FACTORY_ROOT to itself and must verify its own tree. Declared commands are
  # documented to run from the repo root of whatever tree they are invoked in.
  ( eval "$VISIBLE_CMD" ) > "$out" 2>&1
}

# run_heldout_suite <outfile> : run the HELD-OUT suite.
#
# This is the function that did not exist, which is why HELDOUT_CMD was declared
# and never read. It is called by the inspector and by CI — never by a worker,
# and never from inside a sealed tree (the files are not there by design).
run_heldout_suite() {
  local out="${1:-/dev/null}"
  if [ -z "$HELDOUT_CMD" ] || { [ "$HELDOUT_CMD" = "bash factory/tests/run-heldout.sh" ] \
      && [ ! -f factory/tests/run-heldout.sh ]; }; then
    echo "no held-out verification command — cannot verify" > "$out"
    return 127
  fi
  ( eval "$HELDOUT_CMD" ) > "$out" 2>&1
}

# --- the seal --------------------------------------------------------------

# seal_tree <tree> : physically remove the held-out suite from a worker checkout.
# Idempotent; safe to call on a tree that was already sealed.
seal_tree() {
  local tree="$1"
  [ -n "$tree" ] && [ -d "$tree" ] || return 1
  rm -rf "${tree:?}/$HELDOUT_DIR" 2>/dev/null
}

# tree_is_sealed <tree> : 0 when NO held-out file is reachable inside <tree>.
# Checks the declared directory AND any path segment named like it, because a
# Swift package might be sealed as Tests/HeldoutTests while a stale copy of the
# Python default is still lying around.
tree_is_sealed() {
  local tree="$1"
  [ -n "$tree" ] && [ -d "$tree" ] || return 1
  if [ -e "$tree/$HELDOUT_DIR" ]; then
    echo "seal broken: $tree/$HELDOUT_DIR exists" >&2
    return 1
  fi
  local base hits
  base="$(heldout_basename)"
  hits="$(find "$tree" -type d -name "$base" -not -path '*/.git/*' 2>/dev/null | head -1)"
  if [ -n "$hits" ]; then
    echo "seal broken: a directory named $base is reachable at $hits" >&2
    return 1
  fi
  return 0
}

# create_sealed_tree <repo> <dest> [branch] [ref] : the ONE implementation of the
# physical seal, used by runner.sh, scripts/tests/test-seal.sh and (via
# foreman/contracts.py) the night shift.
#
# It used to be three hand-written copies of the same four git commands. A test
# that re-types the procedure proves the procedure it typed, not the one shipped,
# so widening runner.sh's pattern list would have kept the test green. Now the
# test calls this function and the product calls this function.
create_sealed_tree() {
  local repo="$1" dest="$2" branch="${3:-}" ref="${4:-HEAD}"
  [ -n "$repo" ] && [ -n "$dest" ] || { echo "create_sealed_tree: need <repo> <dest>" >&2; return 2; }
  [ -d "$dest" ] && { echo "create_sealed_tree: $dest already exists" >&2; return 1; }
  local -a add=(worktree add -q --no-checkout)
  if [ -n "$branch" ]; then add+=(-b "$branch"); else add+=(--detach); fi
  # $ref is explicit because runner.sh pins the base SHA it later diffs the PR
  # against; re-resolving to HEAD here could drift by a commit between the two.
  git -C "$repo" "${add[@]}" "$dest" "$ref" 2>/dev/null || {
    git -C "$repo" worktree add -q --no-checkout --detach "$dest" "$ref" || return 1
  }
  (
    cd "$dest" || exit 1
    # NO `-q`, NO swallowed stderr. `git sparse-checkout init` accepts no -q and
    # neither does `set`: each exited 129 into /dev/null, so the pattern list was
    # NEVER written and the whole seal degraded to the `rm -rf` below - which any
    # worker reverses with one `git checkout -- <dir>`, then reads its own exam.
    # Measured: the exam file reappears while every log line says the seal was
    # verified. Each step is checked now; a nonzero rc aborts instead of lying.
    git sparse-checkout init --no-cone \
      || { echo "seal: sparse-checkout init failed" >&2; exit 1; }
    sparse_args
    git sparse-checkout set "${SPARSE_ARGS[@]}" \
      || { echo "seal: sparse-checkout set failed" >&2; exit 1; }
    # The patterns must be LIVE before the checkout, or the checkout materialises
    # every tracked file including the held-out one.
    git sparse-checkout list 2>/dev/null | grep -qF "!/${HELDOUT_DIR}/" \
      || { echo "seal: patterns not active: $(git sparse-checkout list 2>&1 | head -1)" >&2; exit 1; }
    git checkout -q || { echo "seal: checkout failed" >&2; exit 1; }
  ) || return 1
  # A sparse pattern can be widened by anything that runs
  # `git sparse-checkout disable`; a deleted directory cannot be un-deleted
  # without the objects.
  seal_tree "$dest"
  # Anti-vacuous check. A broken sparse pattern (see sparse_args: the unquoted
  # form glob-expands `/*` into /Applications /Library ...) yields an EMPTY
  # checkout, in which "the held-out directory is absent" is trivially true and
  # every seal assertion passes while the worker has no code to work on. So:
  # require the tree to still contain the tracked files that are not held out.
  local want have
  want="$(git -C "$repo" ls-tree -r --name-only "$ref" 2>/dev/null \
            | grep -v "^$HELDOUT_DIR/" | wc -l | tr -d ' ')"
  # `-not -name .git`: in a LINKED worktree .git is a file, not a directory, so
  # the path filter alone would count it and inflate the number.
  have="$(cd "$dest" && find . -type f -not -path './.git/*' -not -name .git 2>/dev/null \
            | wc -l | tr -d ' ')"
  if [ "${want:-0}" -gt 0 ] && [ "${have:-0}" -lt "${want:-0}" ]; then
    echo "seal incomplete: repo has $want non-held-out tracked file(s), tree has $have" >&2
    return 1
  fi
  tree_is_sealed "$dest"
}

# seal_intact <tree> : is the seal still in force in <tree>, right now?
#
# Checks the PATTERNS, not merely the absence of the directory. A linked worktree
# shares the parent's object store, so a worker that runs
# `git sparse-checkout disable` and then `git checkout -- .` gets the held-out
# suite back — measured. Absence alone reports that tree as sealed.
#
# This is a DETECTION control, not containment. Real containment needs a second
# clone without the objects, or a container; the README says so plainly rather
# than claiming the seal is a wall.
seal_intact() {
  local tree="$1" want
  [ -d "$tree" ] || return 1
  if [ -e "$tree/$HELDOUT_DIR" ]; then
    echo "seal: $HELDOUT_DIR reappeared in $tree" >&2
    return 1
  fi
  want="$(git -C "$tree" sparse-checkout list 2>/dev/null | tr '\n' ' ')"
  case "$want" in
    *"!/${HELDOUT_DIR}/"*) return 0 ;;
    *) echo "seal: patterns no longer exclude $HELDOUT_DIR (got: ${want:-<none>})" >&2; return 1 ;;
  esac
}

# existing_pathspecs OUT_VAR <path...> : keep only paths that exist in the tree.
#
# `git diff --quiet -- <missing>` tolerates a missing pathspec, but
# `git checkout -- <missing>` ERRORS and reverts nothing. So a tamper guard that
# hands checkout a list of declared directories silently does nothing the moment
# one of them is absent — which is every Swift project, where `factory/tests/`
# does not exist and the reverted paths were exactly the ones that mattered.
# Measured: rc 128, stderr swallowed, tampered exam left in the tree and then
# committed by the very round that was supposed to guard against it.
existing_pathspecs() {
  local __out="$1"; shift
  local __p __keep=()
  for __p in "$@"; do
    [ -e "$__p" ] && __keep+=("$__p")
  done
  # Declare first, then assign: `local -n` would be cleaner but bash 3.2 (the
  # macOS default) has no nameref, and printf -v on an array name leaves a
  # one-element array holding the empty string — which callers would expand into
  # an argument list containing "".
  eval "$__out=()"
  [ "${#__keep[@]}" -gt 0 ] && eval "$__out=(\"\${__keep[@]}\")"
  return 0
}
