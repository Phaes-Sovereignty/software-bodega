#!/usr/bin/env bash
# selftest.sh — Software Bodega: definition-of-done checks. Run this before trusting the
# factory with a night. Exits non-zero if any check fails.
#
# Usage: bash scripts/selftest.sh [--offline]   (--offline skips live model calls)

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

OFFLINE=0
[ "${1:-}" = "--offline" ] && OFFLINE=1

# One interpreter for every python check here, exported as $PYTHON so the
# fixtures skip or run on the SAME thing (a fixture that probes a different
# python than the suite reports on will disagree about whether PyYAML exists).
PY="${PYTHON:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY=python3
export PYTHON="$PY"

PASS=0; FAIL=0; SKIP=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# --- 1. shell syntax -------------------------------------------------------
head_ "1. Shell syntax (bash -n)"
for f in scripts/*.sh scripts/lib/*.sh; do
  [ -e "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; bash -n "$f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
  for f in scripts/*.sh scripts/lib/*.sh; do
    if shellcheck -S warning "$f" >/dev/null 2>&1; then ok "shellcheck $f"; else bad "shellcheck $f"; fi
  done
else
  printf '  \033[33m–\033[0m shellcheck not installed (optional; see README deviations)\n'
  SKIP=$((SKIP + 1))
fi

# --- 1b. entry points guard the leading-dash trap ---------------------------
head_ "1b. Entry-point prompt guards"
# Every skill file opens with YAML frontmatter, so any prompt built from one
# starts with '---'. A CLI in argument mode reads that as a flag and exits
# before the model sees anything. run_role guards it; scripts that call a CLI
# directly must guard it too, and this is the third time it has bitten.
# Assert on the BYTES the CLI would receive, via --print. The old check grepped
# each script for the literal guard line: that passes when the guard exists but is
# unreachable, passes when the string only appears in a comment, and fails when
# someone writes an equivalent guard a different way. --print runs the real
# assembly, so it can only pass if the guard actually fired.
for f in scripts/start.sh scripts/interview.sh; do
  [ -e "$f" ] || continue
  if ! bash "$f" --print >/dev/null 2>&1; then
    bad "$f --print failed — cannot inspect the prompt it assembles"
    continue
  fi
  nbytes="$(bash "$f" --print 2>/dev/null | wc -c | tr -d ' ')"
  first="$(bash "$f" --print 2>/dev/null | head -c 1)"
  if [ "$first" = "-" ]; then
    bad "$f emits a prompt starting with a dash — an arg-mode CLI reads it as a flag and exits before the model sees anything"
  elif [ "${nbytes:-0}" -lt 200 ]; then
    bad "$f --print emitted only $nbytes bytes — a short prompt makes the dash check vacuous"
  else
    ok "$f's assembled prompt is $nbytes bytes and does not begin with a dash"
  fi
done
# The skill files really do open with '---', which is what makes the guard load-
# bearing. If that stops being true the check above proves nothing, so pin it.
if [ "$(head -c 3 skills/conductor/SKILL.md)" = "---" ]; then
  ok "skill files still open with YAML frontmatter (the reason the guard exists)"
else
  bad "skills/conductor/SKILL.md no longer starts with '---' — re-check the dash guard"
fi

# --- 2. JSON schemas -------------------------------------------------------
head_ "2. JSON schemas validate against fixtures"
for k in spec decompose plan; do
  if python3 scripts/lib/schemas.py "$k" "scripts/fixtures/$k.valid.json" 2>/dev/null; then
    ok "$k: valid fixture accepted"
  else bad "$k: valid fixture REJECTED"; fi
  if python3 scripts/lib/schemas.py "$k" "scripts/fixtures/$k.invalid.json" 2>/dev/null; then
    bad "$k: invalid fixture ACCEPTED"
  else ok "$k: invalid fixture rejected"; fi
  if python3 scripts/lib/schemas.py "$k" "factory/.planning/$k.json" 2>/dev/null; then
    ok "$k: live factory/.planning/$k.json valid"
  else bad "$k: live factory/.planning/$k.json invalid"; fi
done

# --- 3. status block round-trip -------------------------------------------
head_ "3. Status-block parser round-trips all three statuses"
T="$(mktemp)"
for s in DONE BLOCKED NEEDS_CONTEXT; do
  status_emit "selftest" "T-$s" "$s" "round trip $s" > "$T"
  got_s="$(status_field "$T" STATUS)"; got_t="$(status_field "$T" TASK_ID)"
  if [ "$got_s" = "$s" ] && [ "$got_t" = "T-$s" ] && status_valid "$T" 2>/dev/null; then
    ok "round-trip $s"
  else bad "round-trip $s (status=$got_s task=$got_t)"; fi
done
# last-block-wins: a decoy template must not shadow the real block
{ status_emit "decoy" "-" "BLOCKED" "template echo"; echo noise; \
  status_emit "real" "T9" "DONE" "actual result"; } > "$T"
[ "$(status_field "$T" STATION)" = "real" ] && ok "last block wins over an echoed template" \
  || bad "last block wins"
# malformed blocks must be rejected, not silently parsed
printf 'nothing here\n' > "$T"
status_valid "$T" 2>/dev/null && bad "empty input accepted" || ok "no-block input rejected"
status_emit "x" "T1" "MAYBE" "bad status" > "$T"
status_valid "$T" 2>/dev/null && bad "invalid STATUS accepted" || ok "invalid STATUS rejected"
printf -- '---FACTORY_STATUS---\nSTATION: x\nSTATUS: DONE\n' > "$T"
status_valid "$T" 2>/dev/null && bad "unterminated block accepted" || ok "unterminated block rejected"
rm -f "$T"

# --- 4. family independence -----------------------------------------------
head_ "4. Judge independence (hard rule 2)"
assert_cross_family judge executor 2>/dev/null \
  && ok "judge ($(role_family judge)) != executor ($(role_family executor))" \
  || bad "judge shares a family with the executor"
assert_cross_family plan_judge planner 2>/dev/null \
  && ok "plan_judge ($(role_family plan_judge)) != planner ($(role_family planner))" \
  || bad "plan_judge shares a family with the planner"
assert_cross_family judge planner 2>/dev/null \
  && bad "same-family pair was NOT flagged" \
  || ok "same-family pair correctly flagged"

# run_fixture <script> <label> : execute a behavioural suite and fold its own
# ✓/– lines into this run's tally.
#
# Skips are COUNTED and SHOWN. A suite that silently no-ops (no Swift toolchain,
# no PyYAML) must not roll up into "all N checks passed" — that is precisely how
# the Swift gap shipped: every check that could have caught it either grepped a
# string or quietly did not run.
run_fixture() {
  local script="$1" label="$2" out rc n
  if [ ! -f "scripts/tests/$script" ]; then
    bad "$label: scripts/tests/$script is missing"
    return 1
  fi
  out="$(bash "scripts/tests/$script" 2>&1)"; rc=$?
  # surface the suite's own skip notices, then count them
  n="$(printf '%s\n' "$out" | grep -c '–' 2>/dev/null)"; n="${n:-0}"
  if [ "$n" -gt 0 ]; then
    printf '%s\n' "$out" | grep '–' | sed 's/^/  /'
    SKIP=$((SKIP + n))
  fi
  printf '%s\n' "$out" | grep '✓' | sed 's/^/  /'
  while IFS= read -r l; do case "$l" in *"✓"*) PASS=$((PASS+1));; esac; done <<< "$out"
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -v '✓' | grep -v '–' | sed 's/^/  /'
    bad "$label"
    return 1
  fi
  return 0
}


# --- 5. held-out seal: behaviour, not text ---------------------------------
head_ "5. Held-out seal — behavioural"
# These checks used to be greps over source files. One of them,
# `grep -q "sparse-checkout" scripts/runner.sh`, FAILED the moment runner.sh was
# improved to call the shared create_sealed_tree — while the real seal test two
# lines below passed. That is the whole argument for this section: a grep
# measures how code is written, and it breaks in both directions when the code
# gets better. Everything here runs something and asserts on what happened.
run_fixture test-seal.sh "physical seal (create_sealed_tree)"
run_fixture test-prompts.sh "worker/exam prompt hygiene"

# What a grep still legitimately does: check that a PROMPT-FACING document does
# not instruct the builder to use the held-out suite. That is a property of the
# text, so reading the text is the right instrument — but it is scoped to the
# executor-facing skills, and it is never the seal.
for f in skills/night-task/SKILL.md; do
  if grep -n "heldout\|held-out" "$f" 2>/dev/null \
     | grep -vqE "does not exist|do not|never|NEVER|not there|HELDOUT_DIR|is not in your|absent"; then
    bad "$f mentions the held-out suite in non-prohibiting terms"
  else
    ok "$f references the held-out suite only to forbid it"
  fi
done

# --- 5b. compiled toolchains: BEHAVIOUR, not text --------------------------
head_ "5b. Compiled toolchains (Swift) — behavioural"
# Every check in this section used to be `grep -q` for a string in a file:
# "toolchain.env", "manifest-cache none", "FileManager". All of them passed while
# HELDOUT_CMD was read by nothing and the seal removed a directory a Swift
# project does not use. A string in a file proves someone wrote the intent down;
# it says nothing about whether the mechanism works. These run fixtures instead.
run_fixture test-toolchain.sh "toolchain resolution and sealing"
run_fixture test-swift-cycle.sh "swift sealed exam-and-verify cycle"
run_fixture test-ladder.sh "escalation ladder and judge independence"
run_fixture test-foreman-launch.sh "foreman launch physical seal"
run_fixture test-launcher.sh "launcher no-clobber merge"
run_fixture test-fixround.sh "fix round on a compiled project"
# bootstrap -> HEAD -> sealed worktree, end to end. The commit gate is the step
# that makes the whole sealed design reachable: launch builds its sandbox from
# HEAD, so a plan that was only ever written to the working directory does not
# exist for the night. Nothing else in this suite covers that handoff, which is
# why the failure presented as "STATUS: DONE, 0 commits" instead of an error.
run_fixture test-bootstrap.sh "bootstrap artifacts reach HEAD and a sealed night"

# --- 6. CI workflow --------------------------------------------------------
# Parsed structurally in scripts/tests/test-workflow.sh, which skips LOUDLY when
# PyYAML is missing. Reporting "factory.yml invalid" because a dependency is
# absent is how red output stops meaning anything — and it hides the real
# failures, which is exactly how the Swift gap shipped.
run_fixture test-workflow.sh "CI workflow structure and toolchain wiring"

# The scope + seal check: run THE SCRIPT CI RUNS. This used to re-implement the
# workflow's inline logic in a local `_scope()` function, so it validated a
# transcription — a change to the YAML could not possibly break it.
head_ "6b. Scope + seal check (scripts/ci-scope.sh)"
SCOPE_DIR="$(mktemp -d)"
# A throwaway project so HELDOUT_DIR resolves to something known, and so the
# Swift case can be exercised against a declared non-default path.
SP="$SCOPE_DIR/proj"; mkdir -p "$SP/scripts/lib" "$SP/factory/tests/heldout"
cp scripts/ci-scope.sh "$SP/scripts/"; cp scripts/lib/*.sh "$SP/scripts/lib/"
cp models.env "$SP/"
BODY_OK="$SCOPE_DIR/body-ok.txt"
printf 'Files changed:\n- src/a.py\n- tests/test_a.py\n\nOther behavior changes: None\n' > "$BODY_OK"
BODY_NOMAN="$SCOPE_DIR/body-none.txt"; printf 'nothing here\n' > "$BODY_NOMAN"
BODY_NOLEDGER="$SCOPE_DIR/body-noledger.txt"
printf 'Files changed:\n- src/a.py\n\n' > "$BODY_NOLEDGER"

scope_case() { # scope_case <label> <expect pass|fail> <changed-lines...> -- uses $BODY_VAR
  local label="$1" expect="$2"; shift 2
  local cf="$SCOPE_DIR/changed.$$.txt"
  printf '%s\n' "$@" > "$cf"
  local out rc
  out="$( cd "$SP" && FACTORY_ROOT="$SP" bash scripts/ci-scope.sh check "$cf" "$BODY_VAR" 2>&1 )"; rc=$?
  case "$expect" in
    pass) [ "$rc" = "0" ] && ok "$label" || bad "$label (rc=$rc: $(printf '%s' "$out" | head -1))" ;;
    fail) [ "$rc" != "0" ] && ok "$label" || bad "$label — ACCEPTED what it must reject" ;;
  esac
}
BODY_VAR="$BODY_OK"
scope_case "accepts an in-manifest diff"        pass "src/a.py" "tests/test_a.py"
scope_case "rejects an undeclared file"         fail "src/a.py" "src/sneaky.py"
scope_case "rejects a PR that touches heldout/" fail "src/a.py" "factory/tests/heldout/test_x.py"
BODY_VAR="$BODY_NOMAN"
scope_case "rejects a body with no manifest"    fail "src/a.py"
BODY_VAR="$BODY_NOLEDGER"
scope_case "rejects a missing ledger line"      fail "src/a.py"

# The declared-path case: a Swift project's exam lives at Tests/HeldoutTests, so
# a check hard-wired to the default path prints "seal OK" while the PR smuggles
# the exam in. Real files, not process substitution: <( ... ) yields /dev/fd/N,
# which is not a regular file, so the script's own existence check rejects it and
# the test would exercise the wrong branch and look like a product bug.
printf "HELDOUT_DIR='Tests/HeldoutTests'\n" > "$SP/factory/toolchain.env"
printf 'src/a.py\nTests/HeldoutTests/Leak.swift\n' > "$SCOPE_DIR/changed-leak.txt"
printf 'src/a.py\nfactory/tests/heldout/old.py\n'  > "$SCOPE_DIR/changed-stale.txt"
out="$( cd "$SP" && FACTORY_ROOT="$SP" bash scripts/ci-scope.sh check \
         "$SCOPE_DIR/changed-leak.txt" "$BODY_OK" 2>&1 )"
printf '%s' "$out" | grep -q "Tests/HeldoutTests" \
  && ok "seal check uses the DECLARED dir (rejects Tests/HeldoutTests in a PR)" \
  || bad "seal check ignored the declared HELDOUT_DIR: $(printf '%s' "$out" | head -2 | tr '\n' '|')"
out2="$( cd "$SP" && FACTORY_ROOT="$SP" bash scripts/ci-scope.sh check \
          "$SCOPE_DIR/changed-stale.txt" "$BODY_OK" 2>&1 )"
# Declare both files in the body so the ONLY question left is whether the seal
# check fires: otherwise the scope rule rejects the undeclared path first and the
# assertion tests the wrong gate.
BODY_SWIFT="$SCOPE_DIR/body-swift.txt"
printf 'Files changed:\n- src/a.py\n- factory/tests/heldout/old.py\n\nOther behavior changes: None\n' \
  > "$BODY_SWIFT"
out2="$( cd "$SP" && FACTORY_ROOT="$SP" bash scripts/ci-scope.sh check \
          "$SCOPE_DIR/changed-stale.txt" "$BODY_SWIFT" 2>&1 )"
printf '%s' "$out2" | grep -q "seal OK" \
  && ok "a stale default-path heldout/ no longer trips the Swift project's seal check" \
  || bad "unexpected: $(printf '%s' "$out2" | head -2 | tr '\n' '|')"
rm -rf "$SCOPE_DIR"

# --- 7. night-shift loop semantics (stubbed executor, no model calls) ------
head_ "7. Night-shift loop semantics"
run_fixture test-nightshift.sh "night-shift loop semantics"
# --- 8. foreman (Phase C) --------------------------------------------------
if [ -d foreman ]; then
  head_ "8. Foreman (Phase C)"
  if ! "$PY" -c 'import yaml' 2>/dev/null; then
    printf '  \033[33m–\033[0m %s has no PyYAML — foreman suite and CLI UNVERIFIED\n' "$PY"
    printf '  \033[33m–\033[0m install pyyaml (or run: PYTHON=/path/to/venv/bin/python bash scripts/selftest.sh)\n'
  SKIP=$((SKIP + 1))
  elif FO="$("$PY" -m unittest foreman.tests.test_foreman 2>&1)"; then
    n="$(printf '%s' "$FO" | grep -oE 'Ran [0-9]+ tests' | grep -oE '[0-9]+')"
    ok "foreman unit suite: ${n:-?} tests pass"
    PASS=$((PASS + ${n:-0} - 1))
  else
    printf '%s\n' "$FO" | tail -20 | sed 's/^/  /'
    bad "foreman unit suite failed"
  fi
  if "$PY" -c 'import yaml' 2>/dev/null; then
    if "$PY" -m foreman --root . status >/dev/null 2>&1; then
      ok "foreman CLI runs against this repo"
    else bad "foreman CLI failed"; fi
  fi
fi

# --- 9. headless adapters --------------------------------------------------
head_ "9. Headless adapter smoke tests"
if [ "$OFFLINE" = "1" ]; then
  printf '  \033[33m–\033[0m skipped (--offline)\n'
  SKIP=$((SKIP + 1))
else
  PROBE='Reply with ONLY this exact block and nothing else:
---FACTORY_STATUS---
STATION: probe
TASK_ID: T00
STATUS: DONE
SUMMARY: adapter reachable
---END---'
  # fallback is the last escalation rung, not a required adapter: an outage
  # there degrades the ladder, it does not stop a night. Warn, do not fail.
  for role in executor planner judge plan_judge fallback; do
    O="$(mktemp)"; E="$(mktemp)"
    if run_role "$role" "$PROBE" > "$O" 2>"$E" && status_valid "$O" 2>/dev/null; then
      ok "$role ($(role_family "$role")) returned a parseable status block"
    elif [ "$role" = "fallback" ]; then
      printf '  \033[33m–\033[0m %s (%s) UNAVAILABLE — escalation rung only: %s\n' \
        "$role" "$(role_family "$role")" "$(head -c 90 "$E" | tr '\n' ' ')"
      SKIP=$((SKIP + 1))
    else
      bad "$role ($(role_family "$role")) failed: $(head -c 120 "$O" | tr '\n' ' ')"
    fi
    rm -f "$O" "$E"
  done
  # Regression: every real worker prompt starts with a skill file's YAML
  # frontmatter, so the first characters are `---`. An arg-mode CLI parses that
  # as a flag and exits 2 before the model ever sees it.
  O="$(mktemp)"
  if run_role executor "---
name: frontmatter-probe
---

$PROBE" > "$O" 2>/dev/null && status_valid "$O" 2>/dev/null; then
    ok "executor accepts a prompt starting with YAML frontmatter"
  else
    bad "executor rejects a prompt starting with '---' (worker prompts all do)"
  fi
  rm -f "$O"
fi

# --- summary ---------------------------------------------------------------
printf '\n\033[1m%d passed, %d failed\033[0m' "$PASS" "$FAIL"
if [ "$SKIP" -gt 0 ]; then
  # A skip is not a pass. If the Swift cycle or the workflow check did not run,
  # the number above does not describe the system you are about to trust.
  printf ' \033[33m(%d skipped)\033[0m' "$SKIP"
fi
printf '\n'
if [ "$FAIL" -gt 0 ]; then
  status_emit "selftest" "-" "BLOCKED" "$FAIL check(s) failed"
  exit 1
fi
# The status block must not claim more than the run proved. "all N checks
# passed" while the Swift cycle skipped is the same category of overclaim this
# pass is fixing: a downstream reader (the conductor, the foreman, a human
# skimming factory/log.md) sees DONE and stops looking.
if [ "$SKIP" -gt 0 ]; then
  status_emit "selftest" "-" "DONE" \
    "$PASS passed, $SKIP SKIPPED - the skipped checks proved nothing" \
    "SKIPPED: $SKIP"
else
  status_emit "selftest" "-" "DONE" "all $PASS checks passed"
fi
