#!/usr/bin/env bash
# selftest.sh — Phase B definition-of-done checks. Run this before trusting the
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

PASS=0; FAIL=0
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

# --- 5. held-out seal ------------------------------------------------------
head_ "5. Held-out seal"
# Only EXECUTOR-facing skills are constrained. exam-board authors the held-out
# suite and inspector runs it — both must name it. The seal is about what the
# builder can reach, not about the word appearing in the repo.
EXECUTOR_SKILLS="skills/night-task/SKILL.md"
seal_leak=0
for f in $EXECUTOR_SKILLS; do
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qE "does not exist|do not|never|NEVER|not there" || seal_leak=1
  done < <(grep -n "tests/heldout" "$f" 2>/dev/null)
done
[ "$seal_leak" = "0" ] && ok "executor-facing skills mention heldout/ only to forbid it" \
  || bad "an executor-facing skill references heldout/ as usable"
# Stronger check: the prompt builders must never read held-out content into a
# worker prompt. This is the leak that would actually matter.
if grep -nE "(cat|sed|head|tail|<).*tests/heldout" scripts/nightshift.sh scripts/runner.sh 2>/dev/null | grep -q .; then
  bad "a worker prompt builder reads from tests/heldout/"
else
  ok "no worker prompt builder reads tests/heldout/"
fi
grep -q "sparse-checkout" scripts/runner.sh && ok "runner.sh excludes heldout/ by sparse checkout" \
  || bad "runner.sh does not seal heldout/"
grep -q "HELDOUT_TESTS" .github/workflows/factory.yml && ok "CI fetches held-out suite from secrets" \
  || bad "CI has no held-out fetch"
# The physical proof: build a worker worktree and assert heldout/ is not there.
if SEAL_OUT="$(bash scripts/tests/test-seal.sh 2>&1)"; then
  printf '%s\n' "$SEAL_OUT" | grep "✓" | sed 's/^/  /'
  while IFS= read -r l; do case "$l" in *"✓"*) PASS=$((PASS+1));; esac; done <<< "$SEAL_OUT"
else
  printf '%s\n' "$SEAL_OUT" | sed 's/^/  /'; bad "seal tests failed"
fi

# --- 6. CI workflow --------------------------------------------------------
head_ "6. CI workflow"
if python3 - <<'PY' 2>/dev/null
import yaml, sys
d = yaml.safe_load(open('.github/workflows/factory.yml'))
j = d['jobs']
assert set(j) == {'build','visible','heldout','scope','review'}, f"job set: {sorted(j)}"
assert j['review']['needs'] == ['visible','heldout','scope'], "review must gate on all three"
PY
then ok "factory.yml parses; job graph correct"; else bad "factory.yml invalid or job graph wrong"; fi

# Every run: block must be valid shell. A YAML block scalar silently swallows
# under-indented lines, which is how a broken script reaches CI looking fine.
if python3 - <<'PY' 2>/dev/null
import yaml, subprocess, tempfile, os, sys
d = yaml.safe_load(open('.github/workflows/factory.yml'))
bad = []
for jn, j in d['jobs'].items():
    for i, s in enumerate(j['steps']):
        if 'run' not in s: continue
        src = s['run'].replace('${{', '$OPEN').replace('}}', '')
        with tempfile.NamedTemporaryFile('w', suffix='.sh', delete=False) as f:
            f.write(src); p = f.name
        r = subprocess.run(['bash', '-n', p], capture_output=True, text=True)
        if r.returncode: bad.append(f"{jn}.step[{i}]")
        os.unlink(p)
sys.exit(1 if bad else 0)
PY
then ok "every CI run-block parses as bash"; else bad "a CI run-block is not valid shell"; fi

# The scope check must reject a diff that strays outside the declared manifest.
_scope() {
  printf '%s\n' "$2" | sort -u > "$T1"
  printf '%s\n' "$1" | sed -n '/Files changed:/,/^$/p' | sed -n 's/^[[:space:]]*-[[:space:]]*//p' | sort -u > "$T2"
  [ -s "$T2" ] || return 1
  comm -23 "$T1" "$T2" | grep -q . && return 1
  printf '%s\n' "$1" | grep -q "Other behavior changes:" || return 1
  return 0
}
T1="$(mktemp)"; T2="$(mktemp)"
BODY_OK='Files changed:
- src/a.py
- tests/test_a.py

Other behavior changes: None'
_scope "$BODY_OK" "src/a.py
tests/test_a.py" && ok "scope check accepts an in-manifest diff" || bad "scope check rejects a clean diff"
_scope "$BODY_OK" "src/a.py
src/sneaky.py" && bad "scope check accepted an out-of-manifest file" || ok "scope check rejects an undeclared file"
_scope "no manifest here" "src/a.py" && bad "scope check accepted a body with no manifest" || ok "scope check rejects a missing manifest"
_scope 'Files changed:
- src/a.py' "src/a.py" && bad "scope check accepted a missing ledger line" || ok "scope check rejects a missing ledger line"
rm -f "$T1" "$T2"

# --- 7. night-shift loop semantics (stubbed executor, no model calls) ------
head_ "7. Night-shift loop semantics"
if NS_OUT="$(bash scripts/tests/test-nightshift.sh 2>&1)"; then
  while IFS= read -r l; do case "$l" in *"✓"*) PASS=$((PASS+1));; esac; done <<< "$NS_OUT"
  printf '%s\n' "$NS_OUT" | grep "✓" | sed 's/^/  /'
else
  printf '%s\n' "$NS_OUT" | sed 's/^/  /'
  bad "night-shift loop tests failed"
fi

# --- 8. foreman (Phase C) --------------------------------------------------
if [ -d foreman ]; then
  head_ "8. Foreman (Phase C)"
  if FO="$(python3 -m unittest foreman.tests.test_foreman 2>&1)"; then
    n="$(printf '%s' "$FO" | grep -oE 'Ran [0-9]+ tests' | grep -oE '[0-9]+')"
    ok "foreman unit suite: ${n:-?} tests pass"
    PASS=$((PASS + ${n:-0} - 1))
  else
    printf '%s\n' "$FO" | tail -20 | sed 's/^/  /'
    bad "foreman unit suite failed"
  fi
  if python3 -m foreman --root . status >/dev/null 2>&1; then
    ok "foreman CLI runs against this repo"
  else bad "foreman CLI failed"; fi
fi

# --- 9. headless adapters --------------------------------------------------
head_ "9. Headless adapter smoke tests"
if [ "$OFFLINE" = "1" ]; then
  printf '  \033[33m–\033[0m skipped (--offline)\n'
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
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  status_emit "selftest" "-" "BLOCKED" "$FAIL check(s) failed"
  exit 1
fi
status_emit "selftest" "-" "DONE" "all $PASS checks passed"
