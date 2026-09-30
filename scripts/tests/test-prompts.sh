#!/usr/bin/env bash
# test-prompts.sh — capture the prompt a worker ACTUALLY receives and assert what
# is and is not in it.
#
# The old check was `grep -E "(cat|sed|head|tail).*tests/heldout" nightshift.sh`,
# i.e. it looked for a shell command that reads the directory. A prompt can leak
# the exam without any such command — by interpolating a file's contents, by
# naming a test, by quoting a contract line — and the grep would not notice.
# Likewise a grep for "python3" in bootstrap.sh cannot tell you whether the exam
# board was TOLD python3; this captures the string that reaches the adapter.
#
# Method: the stub executor/role dumps its own prompt to a file, so the assertion
# runs against the assembled bytes, not against the source that built them.
#
# Usage: bash scripts/tests/test-prompts.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

CANARY="HELDOUT_CANARY_do_not_leak_9c2a"

mkproj() { # mkproj <name>
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/factory/tasks" "$d/factory/.planning" \
    "$d/skills/night-task" "$d/skills/exam-board" "$d/bin" "$d/src"
  cp "$SRC"/scripts/*.sh "$d/scripts/"; cp "$SRC"/scripts/lib/*.sh "$d/scripts/lib/"
  for st in night-task exam-board; do
    mkdir -p "$d/skills/$st"; cp "$SRC/skills/$st/SKILL.md" "$d/skills/$st/" 2>/dev/null || printf 'skill\n' > "$d/skills/$st/SKILL.md"
  done
  : > "$d/factory/progress.md"; : > "$d/factory/log.md"
  printf 'STAGE: IDLE\nPOINTER: -\n' > "$d/factory/STATE.md"
  printf '%s' "$d"
}

echo "worker prompt hygiene (night shift)"

# --- 1. the night-task prompt must not carry held-out content --------------
D="$(mkproj night)"
mkdir -p "$D/factory/tests/heldout" "$D/factory/tests/visible"
printf 'def test_x():  # %s\n    assert trim("  a ") == "a"\n' "$CANARY" \
  > "$D/factory/tests/heldout/test_secret.py"
printf 'def test_v(): assert True\n' > "$D/factory/tests/visible/test_v.py"
printf '#!/usr/bin/env bash\nif [ -f src/fix.txt ]; then echo "Ran 1 test"; echo OK; exit 0; fi\necho "Ran 1 test"; echo "FAILED (failures=1)"; exit 1\n' \
  > "$D/factory/tests/run-visible.sh"
printf '#!/usr/bin/env bash\necho "Ran 1 test"; echo OK\n' > "$D/factory/tests/run-heldout.sh"
chmod +x "$D"/factory/tests/run-*.sh
printf "HELDOUT_DIR='factory/tests/heldout'\n" > "$D/factory/toolchain.env"
printf '# contract\nAC-1 checked by heldout/test_secret.py\n' > "$D/factory/CONTRACT.md"
printf '# handoff\n' > "$D/factory/HANDOFF.md"
printf 'Id: T01\nGoal: g\nBoundary: src/fix.txt\nDepends: -\nExam_refs: AC-1\nRisk: low\n' \
  > "$D/factory/tasks/T01.md"
# the stub DUMPS the prompt it was handed, then does the work
cat > "$D/bin/dumper" <<STUB
#!/usr/bin/env bash
printf '%s' "\$*" > "$D/prompt.txt"
mkdir -p "\$PWD/src"; echo fixed > "\$PWD/src/fix.txt"
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: ok\nTESTS: 1/1\nFILES: src/fix.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
chmod +x "$D/bin/dumper"
cat > "$D/models.env" <<ENV
EXECUTOR_CMD='$D/bin/dumper'
EXECUTOR_FAMILY='xai'
EXECUTOR_INPUT='arg'
JUDGE_FAMILY='anthropic'
PLANNER_FAMILY='anthropic'
REPAIR_CAP=0
RESAMPLE_N=1
NO_PROGRESS_LIMIT=9
ENV
( cd "$D" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 3 >/dev/null 2>&1 )

[ -s "$D/prompt.txt" ] && ok "captured the real prompt the executor received ($(wc -c < "$D/prompt.txt" | tr -d ' ') bytes)" \
  || { bad "no prompt captured — the fixture did not exercise the builder"; exit 1; }
if grep -q "$CANARY" "$D/prompt.txt"; then
  bad "the held-out assertion text LEAKED into the worker prompt"
else
  ok "held-out assertion text is absent from the worker prompt"
fi
grep -q "Id: T01" "$D/prompt.txt" \
  && ok "the task file IS in the prompt (so the absence above is not an empty prompt)" \
  || bad "task file missing from the prompt — the leak assertion was vacuous"
grep -qi "HOW TO VERIFY" "$D/prompt.txt" \
  && ok "the prompt carries the verification command" || bad "no verification instruction in the prompt"

# A leak that WOULD be caught: prove the probe is not inert.
cp "$D/prompt.txt" "$D/prompt.leak"
printf '\n# %s\n' "$CANARY" >> "$D/prompt.leak"
grep -q "$CANARY" "$D/prompt.leak" \
  && ok "the canary probe fires when the text IS present (probe is not inert)" \
  || bad "canary probe cannot detect a leak — this test proves nothing"

echo "exam-board prompt (bootstrap)"

# --- 2. the exam station must be told the DECLARED dirs, not python --------
E="$(mkproj exam)"
mkdir -p "$E/factory/.planning" "$E/skills/spec-freeze"
printf '{"actors":[],"criteria":[{"id":"AC-1","text":"trims","check":{"kind":"test"}}],"non_goals":[{"id":"NG-1","text":"none"}]}\n' \
  > "$E/factory/.planning/spec.json"
printf '# brief\n\n## Decisions made\n- D-1: x\n\n## Non-goals\n- NG-1: y\n\n## Riskiest part\nz\n' \
  > "$E/factory/BRIEF.md"
# A declared NON-default toolchain: if the exam prompt still says "python3
# standard library only" or hard-names factory/tests/, this catches it.
mkdir -p "$E/custom/visible" "$E/custom/heldout"
cat > "$E/factory/toolchain.env" <<'EOF'
HELDOUT_DIR='custom/heldout'
VISIBLE_DIR='custom/visible'
VISIBLE_CMD='bash custom/visible/run.sh'
HELDOUT_CMD='bash custom/heldout/run.sh'
BUILD_CMD=''
EOF
cat > "$E/models.env" <<ENV
PLANNER_CMD='$E/bin/examiner'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
PLAN_JUDGE_FAMILY='openai'
EXECUTOR_FAMILY='xai'
JUDGE_FAMILY='moonshot'
ENV
# the stub writes the suites INTO THE DECLARED dirs and dumps its prompt
cat > "$E/bin/examiner" <<STUB
#!/usr/bin/env bash
# Capture the FIRST planner prompt only. bootstrap --from exam keeps going into
# WORKORDER and PLAN REVIEW, which reuse this same stub; writing unconditionally
# meant the file held the last prompt of the run and every assertion below
# described the wrong station.
if [ ! -s "$E/exam-prompt.txt" ]; then printf '%s' "\$*" > "$E/exam-prompt.txt"; fi
printf '# CONTRACT\n\n## What this must do\n- AC-1: trims — checked by: visible\n\n## What this must not do\n- NG-1: none\n\n## Definition of done\nsuites green\n' > "$E/factory/CONTRACT.md"
for i in 1 2 3; do printf 'assert %s\n' "\$i" > "$E/custom/visible/t\${i}.txt"; done
for i in 1 2;   do printf 'assert %s\n' "\$i" > "$E/custom/heldout/h\${i}.txt"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$E/custom/visible/run.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$E/custom/heldout/run.sh"
chmod +x "$E"/custom/visible/run.sh "$E"/custom/heldout/run.sh
printf -- '---FACTORY_STATUS---\nSTATION: exam-board\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: wrote both suites\n---END---\n'
STUB
chmod +x "$E/bin/examiner"
( cd "$E" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init ) >/dev/null 2>&1
( cd "$E" && env -u FACTORY_ROOT bash scripts/bootstrap.sh --from exam >"$E/boot.log" 2>&1 )
BRC=$?

[ -s "$E/exam-prompt.txt" ] && ok "captured the real prompt the exam board received" \
  || { bad "exam prompt never built: $(tail -3 "$E/boot.log" | tr '\n' '|')"; }
if [ -s "$E/exam-prompt.txt" ]; then
  grep -q "custom/heldout" "$E/exam-prompt.txt" \
    && ok "the exam prompt names the DECLARED held-out directory" \
    || bad "exam prompt never mentions custom/heldout — the board would write to the default path"
  grep -q "custom/visible" "$E/exam-prompt.txt" \
    && ok "the exam prompt names the DECLARED visible directory" \
    || bad "exam prompt never mentions custom/visible"
  if grep -qi "standard library" "$E/exam-prompt.txt"; then
    bad "exam prompt still says \"python3 standard library only\""
  else
    ok "exam prompt no longer assumes the python standard library"
  fi
  grep -q "HELDOUT_CMD=" "$E/exam-prompt.txt" \
    && ok "the exam prompt is given the resolved HELDOUT_CMD" \
    || bad "HELDOUT_CMD was never passed to the exam board"
fi
# The gate must COUNT files under the declared dirs. bootstrap continues into
# WORKORDER/PLAN REVIEW (which this stub does not satisfy), so assert on the
# exam_gate line rather than on the whole run.
grep -q "exam_gate" "$E/boot.log" \
  && ! grep -q "GATE FAILED: exam" "$E/boot.log" \
  && ok "exam_gate passed counting files under the DECLARED dirs" \
  || bad "exam_gate did not accept the declared layout: $(grep -m1 'GATE FAILED' "$E/boot.log" | head -c 160)"

# A suite of the right SIZE in the WRONG place must FAIL the gate. This is the
# vacuous-pass case the old grep checks could never see: files exist, counts are
# satisfied, and the builder can still read the exam because the seal looks at a
# different directory.
W="$(mkproj wrongplace)"
mkdir -p "$W/factory/tests/heldout" "$W/factory/tests/visible" \
         "$W/custom/heldout" "$W/custom/visible" "$W/factory/.planning" "$W/bin"
printf "HELDOUT_DIR='custom/heldout'\nVISIBLE_DIR='custom/visible'\nVISIBLE_CMD='true'\nHELDOUT_CMD='true'\n" \
  > "$W/factory/toolchain.env"
for i in 1 2 3; do echo x > "$W/factory/tests/visible/t$i.py"; done
for i in 1 2;   do echo x > "$W/factory/tests/heldout/h$i.py"; done
printf '{"actors":[],"criteria":[{"id":"AC-1","text":"t","check":{"kind":"test"}}],"non_goals":[{"id":"NG-1","text":"n"}]}\n' \
  > "$W/factory/.planning/spec.json"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/factory/tests/run-visible.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/factory/tests/run-heldout.sh"
chmod +x "$W"/factory/tests/run-*.sh
cat > "$W/bin/examiner" <<STUB
#!/usr/bin/env bash
printf '# CONTRACT\n' > "$W/factory/CONTRACT.md"
printf -- '---FACTORY_STATUS---\nSTATION: exam-board\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: wrote to the wrong place\n---END---\n'
STUB
chmod +x "$W/bin/examiner"
cat > "$W/models.env" <<ENV
PLANNER_CMD='$W/bin/examiner'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
PLAN_JUDGE_FAMILY='openai'
ENV
printf 'STAGE: IDLE\nPOINTER: -\n' > "$W/factory/STATE.md"
: > "$W/factory/log.md"; : > "$W/factory/progress.md"
( cd "$W" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm i ) >/dev/null 2>&1
( cd "$W" && env -u FACTORY_ROOT bash scripts/bootstrap.sh --from exam >"$W/w.log" 2>&1 )
# The gate must fail, and name the DECLARED directory it counted (visible is
# checked first, so either message proves the count came from custom/*).
grep -qE "exam_gate: only 0 (visible|held-out) check files in custom/" "$W/w.log" \
  && ok "exam_gate REJECTS a full-size suite written to the wrong directory" \
  || bad "gate accepted default-dir suites while HELDOUT_DIR says custom/heldout: $(grep -m1 'GATE FAILED' "$W/w.log" | head -c 140)"
# ...and it must NOT have counted the default directories, which are full.
grep -q "only 0" "$W/w.log" && ! grep -q "in factory/tests/" "$W/w.log" \
  && ok "the gate counted the declared dirs, not the (populated) default ones" \
  || bad "gate reported a default-dir count"

echo "work-order prompt (verify command)"

# --- 3. the work order must be told the PROJECT's verify command ----------
# This station used to be handed the literal `bash factory/tests/run-visible.sh`.
# That string lands verbatim in a task's `Verify:` line, nightshift's
# task_verify_cmd uses it unchanged, and in a compiled project every task is then
# gated on a file that does not exist: exit 127, no receipt, and (before the
# parser was fixed) a failure count of zero. Asserting on the assembled prompt is
# the only check that catches it, because the source can contain the right
# variable and still interpolate the wrong value.
O="$(mkproj workorder)"
mkdir -p "$O/skills/work-order" "$O/custom/visible"
cp "$SRC/skills/work-order/SKILL.md" "$O/skills/work-order/" 2>/dev/null \
  || printf 'skill\n' > "$O/skills/work-order/SKILL.md"
# One heredoc, not two printf arguments: `printf "fmt" "extra"` with no
# remaining specifier SILENTLY DROPS the extra string, which is how this fixture
# first shipped a toolchain.env with no VISIBLE_CMD in it — and then correctly
# reported that the station was given the python default.
cat > "$O/factory/toolchain.env" <<'TC'
HELDOUT_DIR='custom/heldout'
VISIBLE_DIR='custom/visible'
VISIBLE_CMD='swift test --filter VisibleTests'
HELDOUT_CMD='swift test --manifest-cache none --filter HeldoutTests'
TC
printf '{"tasks":[{"id":"T01","goal":"g","boundary":["src/a"],"depends":[],"exam_refs":["AC-1"],"risk":"low","context_estimate":1000}]}' \
  > "$O/factory/.planning/decompose.json"
printf '# CONTRACT\n\n## What this must do\n- AC-1: t\n' > "$O/factory/CONTRACT.md"
cat > "$O/bin/orderwriter" <<STUB
#!/usr/bin/env bash
printf '%s' "\$*" > "$O/prompt.txt"
printf '{"slices":[{"id":"T01","claim":"c","warrant":"w","rebuttal":"r","qualifier":"weak","manifest":["src/a.py"],"exam_refs":["AC-1"]}]}' \
  > "$O/factory/.planning/plan.json"
printf '# handoff\n' > "$O/factory/HANDOFF.md"
printf -- '---FACTORY_STATUS---\nSTATION: work-order\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: planned\n---END---\n'
STUB
chmod +x "$O/bin/orderwriter"
cat > "$O/models.env" <<ENV
PLANNER_CMD='$O/bin/orderwriter'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
PLAN_JUDGE_CMD='$O/bin/orderwriter'
PLAN_JUDGE_FAMILY='openai'
PLAN_JUDGE_INPUT='arg'
EXECUTOR_FAMILY='xai'
JUDGE_FAMILY='moonshot'
ENV
printf 'STAGE: IDLE\nPOINTER: -\n' > "$O/factory/STATE.md"
: > "$O/factory/log.md"; : > "$O/factory/progress.md"
( cd "$O" && env -u FACTORY_ROOT bash scripts/bootstrap.sh --from workorder >"$O/o.log" 2>&1 )
if [ -s "$O/prompt.txt" ]; then
  ok "captured the real prompt the work order received"
  grep -q "swift test --filter VisibleTests" "$O/prompt.txt" \
    && ok "the work order is told the DECLARED verify command" \
    || bad "work-order prompt never names the project's VISIBLE_CMD — it would write a python runner into a Swift task"
  if grep -q "The verify command is:" "$O/prompt.txt"; then
    bad "work-order prompt still dictates a fixed verify command"
  else
    ok "the hard-coded 'bash factory/tests/run-visible.sh' instruction is gone"
  fi
  # The literal must not appear as an INSTRUCTION. It may legitimately appear as
  # the value of VISIBLE_CMD for a python project, which is why this fixture
  # declares a Swift command: any occurrence here is the old hardcoded sentence.
  if grep -q "factory/tests/run-visible.sh" "$O/prompt.txt"; then
    bad "work-order prompt still references the python runner script: $(grep -n 'factory/tests/run-visible.sh' "$O/prompt.txt" | head -2 | tr '\n' '|')"
  else
    ok "no python runner path in a compiled project's work-order prompt"
  fi
else
  bad "work-order prompt never built: $(tail -3 "$O/o.log" | tr '\n' '|')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
