#!/usr/bin/env bash
# ci-scope.sh — the PR scope + seal checks, as ONE script that CI calls and the
# selftest exercises.
#
#   bash scripts/ci-scope.sh check <changed-file-list> <pr-body-file>
#
# exit 0 = the diff is inside its declared manifest and touches no held-out file.
#
# Why a file and not an inline YAML block: the scope logic used to live inside
# .github/workflows/factory.yml, and scripts/selftest.sh re-implemented it in a
# shell function to "test" it. That test could never fail when CI's copy changed,
# because it was not running CI's copy — it was running a transcription. Same
# class of mistake as grepping for "toolchain.env" instead of executing it.
# Extracted, both sides now call the same code.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"   # gives HELDOUT_DIR from the project's toolchain.env

# CI calls `bash scripts/ci-scope.sh check <changed> <body>`; the bare form is
# also accepted. Normalise so a missing/renamed subcommand can never shift the
# positional args and make the script read the literal word "check" as a path —
# which fails closed (good) but for the wrong reason, and a check that passes for
# the wrong reason is the failure mode this whole repo exists to remove.
if [ "${1:-}" = "check" ]; then shift; fi
CHANGED="${1:-/dev/stdin}"
BODY="${2:-}"

fail() { printf '::error::%s\n' "$1" >&2; exit 1; }

[ -f "$CHANGED" ] || fail "no changed-file list at $CHANGED"
[ -n "$BODY" ] && [ -f "$BODY" ] || fail "no PR body file"

# HELDOUT_DIR is read from the project, so a Swift PR is checked against
# Tests/HeldoutTests. Hard-coding factory/tests/heldout here meant a Swift PR
# could commit its own exam and the seal check printed "seal OK".
if [ ! -f "$TOOLCHAIN_ENV" ]; then
  printf '::warning::no factory/toolchain.env — falling back to the default held-out path\n' >&2
fi

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
sort -u "$CHANGED" > "$TMPD/changed.txt"
sed -n '/Files changed:/,/^$/p' "$BODY" \
  | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | sort -u > "$TMPD/declared.txt"

if [ ! -s "$TMPD/declared.txt" ]; then
  printf '::error::PR body declares no file manifest — scope cannot be checked.\n' >&2
  printf '::error::Missing evidence is not a pass. Failing.\n' >&2
  exit 1
fi
if comm -23 "$TMPD/changed.txt" "$TMPD/declared.txt" | grep -q .; then
  printf '::error::files changed outside the declared manifest:\n' >&2
  comm -23 "$TMPD/changed.txt" "$TMPD/declared.txt" >&2
  exit 1
fi
grep -q "Other behavior changes:" "$BODY" || fail "PR body has no scope ledger line"

# The seal: a PR must never carry held-out files.
if grep -q "^$HELDOUT_DIR/" "$TMPD/changed.txt"; then
  printf '::error::PR touches %s/ — seal broken\n' "$HELDOUT_DIR" >&2
  exit 1
fi

printf 'scope OK\n'
printf 'seal OK (%s untouched)\n' "$HELDOUT_DIR"
