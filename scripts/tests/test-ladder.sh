#!/usr/bin/env bash
# test-ladder.sh — prove the escalation ladder RUNS, and that the judge is
# chosen against the family that ACTUALLY wrote the code.
#
# Both were dead before: Router.escalate() had no caller, the night loop stopped
# after resample and parked, and `assert_cross_family judge executor` compared
# two ROLE NAMES once at startup — so an Opus rung fixing code that an Opus
# judge then approved passed the check and voided hard rule 2.
#
# Stubs only. No model calls, no network.
#
# Usage: bash scripts/tests/test-ladder.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
. "$SRC/scripts/lib/status.sh"

echo "escalation ladder — parsing"

# --- 1. the ladder is data the shell can actually read ---------------------
[ "$(ladder_length)" -ge 4 ] \
  && ok "ladder has $(ladder_length) rungs (was: unreachable from the shell at all)" \
  || bad "ladder_length=$(ladder_length) — models.env's ESCALATION_LADDER is not loading"
[ "$(rung_field "$(ladder_rung 0)" 1)" = "resample" ] \
  && ok "rung 0 is the resample" || bad "rung 0 is '$(ladder_rung 0)'"
[ "$(rung_field "$(ladder_rung 1)" 2)" = "planner" ] \
  && ok "rung 1 is the planner" || bad "rung 1 is '$(ladder_rung 1)'"
[ "$(rung_field "$(ladder_rung 3)" 2)" = "fallback" ] \
  && ok "rung 3 is the local fallback" || bad "rung 3 is '$(ladder_rung 3)'"
ladder_rung 99 >/dev/null 2>&1 && bad "rung 99 resolved (past-the-end must fail)" \
  || ok "past-the-end rung fails, so the loop terminates"

# --- 2. the trigger is a verify failure and nothing else -------------------
may_escalate verify_failure && ok "may_escalate: verify_failure escalates" \
  || bad "may_escalate refused verify_failure"
ESC_REFUSED=1
for excuse in low_confidence elapsed_time agent_asked "user request" ""; do
  may_escalate "$excuse" && ESC_REFUSED=0
done
[ "$ESC_REFUSED" = 1 ] && ok "may_escalate refuses every non-verify trigger" \
  || bad "may_escalate accepted an excuse a failing worker could manufacture"

# --- 3. judge selection against the AUTHORING family -----------------------
J1="$(judge_for_family "$(role_family executor)")"
[ "$J1" = "judge" ] && ok "author=xai -> judge role '$J1' ($(role_family "$J1"))" \
  || bad "expected 'judge' for an xai author, got '$J1'"
J2="$(judge_for_family "$(role_family planner)")"
[ -n "$J2" ] && [ "$J2" != "judge" ] \
  && ok "author=anthropic -> picks a DIFFERENT role ('$J2', $(role_family "$J2"))" \
  || bad "judge_for_family returned '$J2' for an anthropic author — same-family judge"
[ "$(role_family "$J2")" != "$(role_family planner)" ] \
  && ok "Opus-authored work is NOT judged by Opus" \
  || bad "the planner and the picked judge share a family"
J3="$(judge_for_family "$(role_family planner),$(role_family executor)")"
[ -n "$J3" ] && ok "multi-author set still resolves ('$J3', $(role_family "$J3"))" \
  || bad "no judge for a two-family night"
ALLFAMS="$(for r in ${JUDGE_ROLES:-judge}; do printf '%s,' "$(role_family "$r")"; done | sed 's/,$//')"
judge_for_family "$ALLFAMS" >/dev/null 2>&1 \
  && bad "judge_for_family found a judge when EVERY judge family authored code" \
  || ok "judge_for_family REFUSES when all judge families are authors (no self-grading)"
assert_judge_for judge "$(role_family planner)" >/dev/null 2>&1 \
  && bad "assert_judge_for passed an anthropic author against the anthropic judge" \
  || ok "assert_judge_for catches judge==author family"

# --- fixture builder -------------------------------------------------------
# The gate is a script that reports unittest-style counts, so fail_count parses
# it. Baseline is GREEN. The executor DELETES the file the gate needs — a real
# regression with a real diff, which is the only situation that reaches the
# ladder (an empty diff is caught earlier by the no-progress breaker).
mknight() { # mknight <name> <ladder>
  local d="$TMP/$1" ladder="$2"
  rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/factory/tasks" "$d/factory/tests/visible" \
                   "$d/factory/tests/heldout" "$d/skills/night-task" "$d/bin" "$d/src"
  cp "$SRC"/scripts/*.sh "$d/scripts/"; cp "$SRC"/scripts/lib/*.sh "$d/scripts/lib/"
  printf 'worker skill\n' > "$d/skills/night-task/SKILL.md"
  : > "$d/factory/progress.md"; : > "$d/factory/log.md"
  printf 'STAGE: IDLE\nPOINTER: -\n' > "$d/factory/STATE.md"
  printf '# contract\n' > "$d/factory/CONTRACT.md"; printf '# handoff\n' > "$d/factory/HANDOFF.md"
  echo "working" > "$d/src/fix.txt"
  cat > "$d/factory/tests/run-visible.sh" <<'GATE'
#!/usr/bin/env bash
# One check: does the behaviour the contract requires still exist?
if [ -f src/fix.txt ]; then echo "Ran 1 test"; echo "OK"; exit 0; fi
echo "Ran 1 test"; echo "FAILED (failures=1)"; exit 1
GATE
  cat > "$d/factory/tests/run-heldout.sh" <<'GATE'
#!/usr/bin/env bash
echo "Ran 1 test"; echo "OK"; exit 0
GATE
  chmod +x "$d"/factory/tests/run-*.sh
  : > "$d/factory/tests/heldout/.gitkeep"
  printf "HELDOUT_DIR='factory/tests/heldout'\n" > "$d/factory/toolchain.env"

  # executor: ships a REGRESSION — removes the file the gate needs
  cat > "$d/bin/bad-executor" <<'STUB'
#!/usr/bin/env bash
rm -f "$PWD/src/fix.txt"
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: refactored (broke it)\nTESTS: 0/1\nFILES: src/fix.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
  # planner: restores the behaviour
  cat > "$d/bin/good-planner" <<'STUB'
#!/usr/bin/env bash
echo fixed > "$PWD/src/fix.txt"
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: ladder rung restored the behaviour\nTESTS: 1/1\nFILES: src/fix.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
  # never helps: used for the fallback/glue rungs and for resample samples
  cat > "$d/bin/bad-fallback" <<'STUB'
#!/usr/bin/env bash
rm -f "$PWD/src/fix.txt"
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: also broken\nTESTS: 0/1\nFILES: src/fix.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
  chmod +x "$d"/bin/*
  cat > "$d/models.env" <<ENV
EXECUTOR_CMD='$d/bin/bad-executor'
EXECUTOR_FAMILY='xai'
EXECUTOR_INPUT='arg'
PLANNER_CMD='$d/bin/good-planner'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
PLAN_JUDGE_CMD='$d/bin/bad-fallback'
PLAN_JUDGE_FAMILY='openai'
PLAN_JUDGE_INPUT='arg'
JUDGE_CMD='$d/bin/good-planner'
JUDGE_FAMILY='anthropic'
JUDGE_INPUT='arg'
GLUE_CMD='$d/bin/bad-fallback'
GLUE_FAMILY='moonshot'
GLUE_INPUT='arg'
TRIAGE_CMD='$d/bin/bad-fallback'
TRIAGE_FAMILY='moonshot'
TRIAGE_INPUT='arg'
FALLBACK_CMD='$d/bin/bad-fallback'
FALLBACK_FAMILY='local'
FALLBACK_INPUT='arg'
ESCALATION_LADDER='$ladder'
JUDGE_ROLES='judge plan_judge glue triage'
REPAIR_CAP=0
RESAMPLE_N=1
NO_PROGRESS_LIMIT=9
ADAPTER_RETRIES=0
ENV
  printf 'Id: T01\nGoal: make the behaviour exist\nBoundary: src/fix.txt\nDepends: -\nExam_refs: AC-1\nRisk: low\n' \
    > "$d/factory/tasks/T01.md"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$d"
}

diag() { # diag <dir> <label>
  printf '    diag[%s]: toolchain=%s\n' "$2" "$(tr '\n' ';' < "$1/factory/toolchain.env" 2>/dev/null)"
  printf '    diag[%s]: visible=[%s]\n' "$2" \
    "$( cd "$1" && env -u FACTORY_ROOT bash -c '. scripts/lib/status.sh >/dev/null 2>&1; printf %s "$VISIBLE_CMD"' )"
  printf '    diag[%s]: loop=%s\n' "$2" "$(grep -E 'baseline|verify|regression|empty diff|ladder|resample' "$1/night.out" 2>/dev/null | head -6 | sed 's/\[nightshift\] //' | tr '\n' '|')"
  printf '    diag[%s]: progress=%s\n' "$2" "$(tail -2 "$1/factory/progress.md" 2>/dev/null | tr '\n' '|')"
}

# --- 4. the night shift actually CLIMBS ------------------------------------
echo "escalation ladder — the night shift runs it"
D="$(mknight climb 'resample:executor:1:execution single:planner single:plan_judge')"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >"$D/night.out" 2>&1 )

grep -q "resample_start" "$D/factory/log.md" \
  && ok "rung 0 (resample) ran" || { bad "resample never ran"; diag "$D" climb; }
grep -q "ladder_start.*single planner" "$D/factory/log.md" \
  && ok "rung 1 (planner) RAN — the ladder is no longer dead config" \
  || { bad "planner rung never ran"; diag "$D" climb; }
grep -q "ladder_win.*planner" "$D/factory/log.md" \
  && ok "the planner rung cleared the verify and was credited" \
  || { bad "no ladder_win recorded"; diag "$D" climb; }
grep -qE "^T01\|DONE\|" "$D/factory/progress.md" \
  && ok "task ends DONE via escalation (the old loop parked it)" \
  || { bad "task did not complete"; diag "$D" climb; }
grep -q anthropic "$D/factory/.planning/author-families.txt" 2>/dev/null \
  && ok "the rung's family (anthropic) is RECORDED as an author" \
  || bad "author families not recorded — the inspector cannot pick a cross-family judge"
grep -qx xai "$D/factory/.planning/author-families.txt" 2>/dev/null \
  && ok "the executor's family is on record too (both authors, not just the winner)" \
  || bad "executor family missing from the author set"
git -C "$D" show --name-only --format= HEAD 2>/dev/null | grep -q "src/fix.txt" \
  && ok "the committed change is the rung's actual fix" \
  || bad "commit does not contain the rung's work"
# The rung that won must be the one that made the gate green, not a stale receipt.
grep -q "ladder_win.*family anthropic" "$D/factory/log.md" \
  && ok "the win is logged with the family that produced it" \
  || bad "ladder_win does not name the winning family"

# --- 5. a green verify spends no rung --------------------------------------
E="$(mknight green 'resample:executor:1:execution single:planner')"
sed -i.bak "s|EXECUTOR_CMD='$E/bin/bad-executor'|EXECUTOR_CMD='$E/bin/good-planner'|" "$E/models.env" && rm -f "$E/models.env.bak"
( cd "$E" && git add -A && git commit -qm "executor that works" ) >/dev/null 2>&1
( cd "$E" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 4 >"$E/night.out" 2>&1 )
grep -q "ladder_start\|resample_start" "$E/factory/log.md" \
  && { bad "the ladder ran on a task that already verified"; diag "$E" green; } \
  || ok "a green verify spends no escalation rung (no silent token burn)"

# --- 6. every rung failing still PARKS, with the reason --------------------
F="$(mknight park 'resample:executor:1:execution single:fallback single:glue')"
( cd "$F" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 8 >"$F/night.out" 2>&1 )
grep -qE "^T01\|PARKED\|" "$F/factory/progress.md" \
  && ok "a task no rung can fix parks (no infinite loop)" \
  || { bad "expected PARKED"; diag "$F" park; }
NSTART="$(grep -c 'ladder_start' "$F/factory/log.md")"
[ "$NSTART" -ge 2 ] && ok "both later rungs were attempted ($NSTART)" \
  || { bad "rungs were not attempted ($NSTART)"; diag "$F" park; }
grep -q "escalation ladder" "$F/factory/progress.md" \
  && ok "the park note names the ladder, so the diary explains itself" \
  || { bad "park note omits the ladder"; diag "$F" park; }

# --- 7. an unconfigured rung is skipped, not fatal ------------------------
G="$(mknight unconfigured 'resample:executor:1:execution single:glue single:planner')"
printf "\nGLUE_CMD=''\n" >> "$G/models.env"
( cd "$G" && git add -A && git commit -qm noglue ) >/dev/null 2>&1
( cd "$G" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >"$G/night.out" 2>&1 )
grep -q "ladder_skip" "$G/factory/log.md" \
  && ok "a rung with no command is SKIPPED and logged" \
  || { bad "unconfigured rung was not skipped"; diag "$G" unconfigured; }
grep -q "ladder_win.*planner" "$G/factory/log.md" \
  && ok "the ladder continued past it to the next rung and still won" \
  || { bad "skipping a rung stopped the climb"; diag "$G" unconfigured; }

# --- 8. each rung starts from a clean tree --------------------------------
# If the failed planner's damage were left in place, the next family would be
# verified against a baseline it did not produce.
H="$(mknight clean 'resample:executor:1:execution single:glue single:planner')"
( cd "$H" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >"$H/night.out" 2>&1 )
[ "$(grep -c 'ladder_start' "$H/factory/log.md")" -ge 2 ] \
  && ok "two rungs ran in sequence (a reset between them is exercised)" \
  || { bad "second rung never ran"; diag "$H" clean; }
grep -qE "^T01\|DONE\|" "$H/factory/progress.md" \
  && ok "the tree still ends correct after a failed rung then a good one" \
  || { bad "rung ordering/reset left the task unfinished"; diag "$H" clean; }

echo "inspector judge selection"

# --- 9. inspect.sh picks against the authors, not the roles ---------------
I="$(mknight inspect 'resample:executor:1:execution single:planner')"
( cd "$I" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >"$I/night.out" 2>&1 )
grep -q anthropic "$I/factory/.planning/author-families.txt" 2>/dev/null \
  && ok "fixture night records two authoring families (xai + anthropic)" \
  || { bad "fixture did not record the planner as an author"; diag "$I" inspect; }
IOUT="$( cd "$I" && env -u FACTORY_ROOT bash scripts/inspect.sh 2>&1 )"; IRC=$?
# judge role is anthropic and anthropic authored, so the OLD startup check
# (judge vs executor) would have passed. The author-aware check must not pick it.
if printf '%s' "$IOUT" | grep -q "judge: judge (anthropic)"; then
  bad "inspector chose the anthropic judge for an anthropic-authored night"
else
  ok "inspector refused the same-family judge (picked: $(printf '%s' "$IOUT" | sed -n 's/.*judge: \([^ ]*\).*/\1/p' | head -1))"
fi
printf '%s' "$IOUT" | grep -q "authors: xai,anthropic" \
  && ok "the inspector prints the author set it judged against" \
  || bad "inspector did not report the author families: $(printf '%s' "$IOUT" | head -2 | tr '\n' '|')"
# And with a third family available it must proceed rather than refuse.
sed -i.bak "s|JUDGE_FAMILY='anthropic'|JUDGE_FAMILY='openai'|" "$I/models.env" && rm -f "$I/models.env.bak"
printf '%s' "$( cd "$I" && env -u FACTORY_ROOT bash -c '
  . scripts/lib/status.sh
  judge_for_family "$(author_families)"' )" | grep -q . \
  && ok "a third-family judge is available, so the night is still inspectable" \
  || bad "no judge resolvable once a third family authored code"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
