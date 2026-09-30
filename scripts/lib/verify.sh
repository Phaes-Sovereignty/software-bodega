#!/usr/bin/env bash
# scripts/lib/verify.sh — how a test receipt is turned into a number.
# Source this; do not execute it.
#
# One implementation on purpose. This arithmetic decides whether a task is DONE
# or PARKED, so a second copy that parses one format (python unittest) silently
# disagrees with the first on every other format (Swift, TAP, xcodebuild). The
# original duplication in fix-round.sh counted a Swift build failure as zero
# failures, which is how "no regression" became unfalsifiable.
#
# Depends on nothing but grep/awk/sed. LAST_TEST_RC is the caller's exit code of
# the run that produced the receipt, used only as the unparseable fallback.

test_counts() { # crude pass/total from the receipt, best-effort
  # No `|| echo 0`: grep -c prints 0 and exits 1 when it matches nothing, which
  # would append a second zero and corrupt the progress.md line.
  local out="$1" p t ran
  # Swift/XCTest: "Executed N tests, with M failures" — last occurrence is the
  # "All tests" rollup, same reason as swift_fail_count.
  ran=$(grep -oE 'Executed [0-9]+ tests?, with' "$out" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
  if [ -n "$ran" ]; then
    printf '%s/%s' "$(( ran - $(fail_count "$out") ))" "$ran"; return
  fi
  ran=$(grep -oE '^Ran ([0-9]+) test' "$out" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [ -n "$ran" ]; then
    printf '%s/%s' "$(( ran - $(fail_count "$out") ))" "$ran"; return
  fi
  p=$(grep -cE '^(ok|PASS|passed)' "$out" 2>/dev/null); p="${p:-0}"
  t=$(grep -cE '^(ok|not ok|PASS|FAIL)' "$out" 2>/dev/null); t="${t:-0}"
  [ "$t" = "0" ] && { printf '?/?'; return; }
  printf '%s/%s' "$p" "$t"
}

# swift_fail_count <receipt> : failing checks from `swift test` / `xcodebuild
# test`, or non-zero return if this receipt is not Swift at all.
#
# Three properties of real Swift output that a naive parser gets wrong:
#
#  1. XCTest prints "Executed N tests, with M failures" once per suite AND
#     again for the "All tests" rollup — summing them multiplies the count.
#     Take the LAST occurrence, which is the rollup.
#  2. Swift 6 runs swift-testing alongside XCTest and prints its own line even
#     for an XCTest-only package ("Test run with 0 tests ... passed"). Reading
#     that line as the whole result reports success while XCTest is failing.
#     The two frameworks are counted separately and ADDED.
#  3. A compile failure produces NO count line at all. That must fall through
#     to the exit code, never to zero.
swift_fail_count() {
  local out="$1" total=0 found=0 n
  # 1. XCTest rollup — last occurrence only.
  n=$(grep -oE 'Executed [0-9]+ tests?, with [0-9]+ failure' "$out" 2>/dev/null \
      | tail -1 | sed -E 's/.*with ([0-9]+) failure.*/\1/')
  if [ -n "$n" ]; then total=$((total + n)); found=1; fi
  # 2. swift-testing, which reports "issues" rather than failures.
  if grep -qE 'Test run with .*failed.*with [0-9]+ issue' "$out" 2>/dev/null; then
    n=$(grep -oE 'with [0-9]+ issue' "$out" 2>/dev/null | tail -1 | grep -oE '[0-9]+')
    total=$((total + ${n:-1})); found=1
  elif grep -qE 'Test run with .*passed' "$out" 2>/dev/null; then
    found=1
  fi
  # 3. xcodebuild banner: a backstop when the Executed line is absent or 0 but
  #    the run still failed (a crashed bundle, a failed build phase).
  if grep -q '\*\* TEST FAILED \*\*' "$out" 2>/dev/null; then
    [ "$total" = "0" ] && total=1
    found=1
  fi
  [ "$found" = "1" ] || return 1
  printf '%s' "$total"
}

# fail_count <receipt> : how many checks are currently failing.
# 0 when the suite is green. Falls back to the exit code when the format is
# unrecognised, so an unparseable receipt is never mistaken for success.
fail_count() {
  local out="$1" n g=0
  # The extra gate is a failing CHECK, counted alongside the tests. It has to
  # enter the arithmetic or it is invisible: a task that breaks the invariant
  # while keeping the suite green would score 0 against a baseline of 0 and
  # read as "no regression". Counting it means breaking the invariant IS a
  # regression, while an invariant already broken before the task started
  # stays that task's inherited problem — the same rule as every other check.
  if grep -q '^\*\* EXTRA GATE FAILED \*\*' "$out" 2>/dev/null; then g=1; fi
  # Swift first: its receipts contain no unittest/TAP markers, so there is no
  # ambiguity, and a Swift build failure must reach the exit-code fallback
  # rather than being read as a green suite.
  if n=$(swift_fail_count "$out"); then printf '%s' "$((n + g))"; return; fi
  # python unittest: "FAILED (failures=3, errors=1)"
  n=$(grep -oE '(failures|errors)=[0-9]+' "$out" 2>/dev/null | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  if [ -n "$n" ] && [ "$n" != "0" ]; then printf '%s' "$((n + g))"; return; fi
  grep -qE '^OK\b|^OK$' "$out" 2>/dev/null && { printf '%s' "$g"; return; }
  # TAP. No `|| echo 0` here: grep -c already prints 0 when it matches nothing,
  # and it exits 1 doing so, which would append a second zero.
  n=$(grep -cE '^not ok' "$out" 2>/dev/null); n="${n:-0}"
  if [ "$n" != "0" ]; then printf '%s' "$((n + g))"; return; fi
  grep -qE '^ok ' "$out" 2>/dev/null && { printf '%s' "$g"; return; }
  printf '%s' "${LAST_TEST_RC:-1}"
}

# The night shift builds a system incrementally: a walking skeleton cannot make
# the whole suite green, and later tasks turn on the rest. Demanding an all-green
# suite after every task would park every task but the last. The real rule is
# NO REGRESSION — a task must not break a check that was already passing, and the
# suite must reach zero failures by the end (the inspector enforces that).
verify_ok() { # verify_ok <baseline_failures> <current_failures> <exit_rc>
  local base="$1" cur="$2" rc="$3"
  [ "$rc" = "0" ] && return 0                 # fully green: always fine
  [ "$cur" = "127" ] && return 1              # no runner at all
  [ "$cur" -le "$base" ] 2>/dev/null && return 0
  return 1
}

# verify_ok <baseline_failures> <current_failures> <exit_rc> is defined above.
