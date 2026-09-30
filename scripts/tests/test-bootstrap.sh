#!/usr/bin/env bash
# test-bootstrap.sh — prove bootstrap LANDS its artifacts in HEAD, so a sealed
# night can actually see them.
#
# The bug: bootstrap.sh wrote factory/ and stopped. `foreman launch` builds its
# sandbox from HEAD (a sparse-checkout worktree), so anything living only in the
# main checkout's working directory does not exist for the night at all.
# Measured on a scaffolded project run exactly as the conductor skill describes:
# the sandbox had no factory/tasks/, the loop exited on its first iteration
# reporting "all tasks resolved", and the run printed STATUS: DONE with 0
# commits. The plan was real and invisible.
#
# BEHAVIOURAL, not a grep for `git commit`: it runs the pipeline with stub
# stations that write real schema-valid artifacts, then asks git what HEAD
# contains, then seals a worktree from HEAD and asks whether the night can see
# the work order. A grep would have passed on a comment that says "commit here".
#
# Usage: bash scripts/tests/test-bootstrap.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

D="$TMP/proj"
mkdir -p "$D/scripts/lib" "$D/skills/spec-freeze" "$D/skills/blueprint" \
       "$D/skills/exam-board" "$D/skills/work-order" "$D/factory/tasks" \
       "$D/factory/.planning" "$D/bin" "$D/src"
cp "$SRC"/scripts/*.sh "$D/scripts/"; cp "$SRC"/scripts/lib/*.sh "$D/scripts/lib/"
cp "$SRC"/scripts/lib/schemas.py "$D/scripts/lib/" 2>/dev/null
for st in spec-freeze blueprint exam-board work-order; do
  cp "$SRC/skills/$st/SKILL.md" "$D/skills/$st/" 2>/dev/null || printf 'skill\n' > "$D/skills/$st/SKILL.md"
done
: > "$D/factory/progress.md"; : > "$D/factory/log.md"
printf 'STAGE: IDLE\nPOINTER: -\n' > "$D/factory/STATE.md"
printf '# brief\n\n## Decisions made\n- D-1: ship it\n\n## Non-goals\n- NG-1: no UI\n\n## Riskiest part\nthe parser\n' > "$D/factory/BRIEF.md"
printf 'node_modules/\n' > "$D/.gitignore"

# One stub for every planner station, dispatched on the instruction the station
# was actually given. It writes real artifacts, so the gates downstream of it
# have something true to validate.
cat > "$D/bin/maker" <<'STUB'
#!/usr/bin/env bash
P="${1:-}"; [ -n "$P" ] || P="$(cat)"
st=unknown
case "$P" in
  # Dispatch on the prompt scaffolding bootstrap.sh adds, which is unique per
  # station. NOT on "Verdict on plan@": skills/work-order/SKILL.md documents that
  # same verdict line, and since every prompt is `cat skills/<station>/SKILL.md`
  # followed by the instructions, the work-order prompt matched the plan-judge
  # pattern first and the station wrote no plan at all.
  *"===== PLAN ====="*)                     st=plan_judge ;;
  *"Write the two suites"*)                 st=exam ;;
  *"decompose.json AND one factory/tasks"*) st=blueprint ;;
  *"Write factory/.planning/spec.json now"*) st=spec ;;
  *"===== INPUT: decompose.json ====="*)    st=workorder ;;
esac
emit() { printf -- '---FACTORY_STATUS---\nSTATION: %s\nTASK_ID: -\nSTATUS: DONE\nSUMMARY: wrote %s\n---END---\n' "$1" "$2"; }
case "$st" in
spec)
  cat > factory/.planning/spec.json <<'J'
{"actors":[{"id":"A1","text":"operator"}],
 "criteria":[{"id":"AC-1","text":"trims input","check":"test"}],
 "non_goals":[{"id":"NG-1","text":"no UI"}]}
J
  emit spec spec.json ;;
blueprint)
  cat > factory/.planning/decompose.json <<'J'
{"tasks":[{"id":"T01","goal":"walking skeleton","boundary":["src/trim.py"],
  "depends":[],"exam_refs":["AC-1"],"risk":"low","context_estimate":1000}]}
J
  mkdir -p factory/tasks
  printf 'Id: T01\nGoal: walking skeleton\nBoundary: src/trim.py\nDepends: -\nExam_refs: AC-1\nRisk: low\n' \
    > factory/tasks/T01.md
  printf '# blueprint\nT01 -> AC-1\n' > factory/BLUEPRINT.md
  emit blueprint decompose.json ;;
exam)
  HD=factory/tests/heldout; VD=factory/tests/visible
  mkdir -p "$HD" "$VD" factory/tests
  printf '# contract\n\n## What this must do\n- AC-1: trim() strips surrounding space\n' > factory/CONTRACT.md
  for i in 1 2 3; do printf 'def test_v%s():\n    from src.trim import trim\n    assert trim(" a ") == "a"\n' "$i" > "$VD/test_v$i.py"; done
  for i in 1 2; do printf 'def test_h%s():\n    from src.trim import trim\n    assert trim("") == ""\n' "$i" > "$HD/test_h$i.py"; done
  # Red now (no implementation), green once src/trim.py exists: the exam gate
  # requires a suite that fails against an empty repo.
  cat > factory/tests/run-visible.sh <<'R'
#!/usr/bin/env bash
[ -f src/trim.py ] || { echo "Ran 3 tests"; echo "FAILED (failures=3)"; exit 1; }
echo "Ran 3 tests"; echo OK; exit 0
R
  cat > factory/tests/run-heldout.sh <<'R'
#!/usr/bin/env bash
[ -f src/trim.py ] || { echo "Ran 2 tests"; echo "FAILED (failures=2)"; exit 1; }
echo "Ran 2 tests"; echo OK; exit 0
R
  chmod +x factory/tests/run-visible.sh factory/tests/run-heldout.sh
  emit exam "3 visible / 2 held-out" ;;
workorder)
  cat > factory/.planning/plan.json <<'J'
{"slices":[{"plan_id":"T01","claim":"trim() strips space","warrant":"implemented and tested",
  "qualifier":"weak","rebuttal":["empty string mishandled"],
  "grounds":{"file_manifest":["src/trim.py"],"acceptance_criteria":["AC-1"]}}]}
J
  printf '# handoff\n\n## Orientation\nQ: where does trimming live? A: src/trim.py\n' > factory/HANDOFF.md
  emit work-order plan.json ;;
plan_judge)
  sha="$(printf '%s' "$P" | sed -n 's/.*Verdict on plan@\([0-9a-f]*\):.*/\1/p' | head -1)"
  printf 'Verdict on plan@%s: APPROVE\n\nEvery slice is inside its boundary.\n' "$sha" ;;
*)
  printf -- '---FACTORY_STATUS---\nSTATION: unknown\nTASK_ID: -\nSTATUS: BLOCKED\nSUMMARY: stub did not recognise its station\n---END---\n' ;;
esac
STUB
chmod +x "$D/bin/maker"
cat > "$D/models.env" <<ENV
PLANNER_CMD='$D/bin/maker'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
PLAN_JUDGE_CMD='$D/bin/maker'
PLAN_JUDGE_FAMILY='openai'
PLAN_JUDGE_INPUT='arg'
EXECUTOR_FAMILY='xai'
JUDGE_FAMILY='moonshot'
FACTORY_ROLE_TIMEOUT=120
ENV

( cd "$D" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm "scaffold" ) >/dev/null 2>&1
# The human's own uncommitted work, created AFTER the base commit so it is
# genuinely untracked. Hard rule 6: the commit gate stages factory/ explicitly
# and must never sweep the human's files into the factory's history. Writing this
# before `git add -A` would commit it as part of the scaffold and make the
# assertion below measure the fixture instead of the gate.
mkdir -p "$D/notes" && printf 'my private scratch\n' > "$D/notes/human.txt"

echo "bootstrap — artifacts reach HEAD, and a sealed night can see them"

( cd "$D" && env -u FACTORY_ROOT bash scripts/bootstrap.sh --from spec >"$D/boot.log" 2>&1 )
BRC=$?
if [ "$BRC" = "0" ]; then ok "the pipeline runs to completion (rc=0)"
else bad "bootstrap failed rc=$BRC: $(grep -iE 'gate|error|missing|refus' "$D/boot.log" | tail -3 | tr '\n' '|')"; fi

# --- 1. HEAD holds every artifact the night needs --------------------------
for f in factory/.planning/spec.json factory/.planning/decompose.json \
         factory/.planning/plan.json factory/tasks/T01.md factory/CONTRACT.md \
         factory/HANDOFF.md factory/toolchain.env; do
  if git -C "$D" ls-tree -r --name-only HEAD 2>/dev/null | grep -qxF "$f"; then
    ok "HEAD contains $f"
  else
    bad "$f is not in HEAD — a sealed launch would run without it"
  fi
done

# --- 2. the held-out suite is committed too --------------------------------
# It rides along deliberately: that copy is the only one that exists until the
# human moves it into the HELDOUT_TESTS secret. Losing it loses the exam.
git -C "$D" ls-tree -r --name-only HEAD 2>/dev/null | grep -q "factory/tests/heldout/test_h1.py" \
  && ok "the held-out exam is in HEAD (recoverable until it becomes a CI secret)" \
  || bad "the held-out exam was never committed"

# --- 3. the human's files stayed out ---------------------------------------
if git -C "$D" ls-tree -r --name-only HEAD 2>/dev/null | grep -q "notes/human.txt"; then
  bad "the commit gate swept an unrelated human file into factory history"
else
  ok "the commit gate staged factory/ only — the human's untracked file is untouched"
fi

# --- 4. THE POINT: a sealed worktree from HEAD sees the work order ---------
WT="$TMP/wt"; rm -rf "$WT"
( cd "$D" && . ./scripts/lib/status.sh && . ./scripts/lib/toolchain.sh && create_sealed_tree "$D" "$WT" "boot/night" HEAD ) >"$TMP/seal.log" 2>&1
if [ -d "$WT" ]; then
  ok "sealed a worktree from HEAD"
  [ -f "$WT/factory/tasks/T01.md" ] \
    && ok "the night's sandbox contains the task files" \
    || bad "no factory/tasks/ in the sandbox — the loop reports 'all tasks resolved' having seen nothing"
  [ -f "$WT/factory/.planning/plan.json" ] \
    && ok "the sandbox contains the plan" || bad "no plan.json in the sandbox"
  [ -f "$WT/scripts/nightshift.sh" ] \
    && ok "the sandbox contains the loop itself" || bad "no nightshift.sh in the sandbox"
  [ ! -e "$WT/factory/tests/heldout" ] \
    && ok "the held-out suite is physically absent from the sandbox" \
    || bad "the sandbox kept the held-out suite — seal broken on the bootstrap path"
  rm -rf "$WT"
else
  bad "could not seal a worktree from HEAD: $(tail -3 "$TMP/seal.log" | tr '\n' '|')"
fi

# --- 5. per-stage commits, so a mid-pipeline gate failure is recoverable ----
NSTAGES="$(git -C "$D" rev-list --count HEAD 2>/dev/null || echo 0)"
[ "${NSTAGES:-0}" -ge 3 ] \
  && ok "the pipeline left $NSTAGES commits (one per passing stage), not one blob" \
  || bad "expected per-stage commits, found $NSTAGES total"
# Capture first, then match. `git log | grep -q` is a trap under `set -o
# pipefail`: grep exits at the first match, git dies on SIGPIPE (rc 141), and
# the pipeline reports failure even though the line was found. Measured here with
# 200 commits in the history.
SUBJECTS="$(git -C "$D" log --format=%s HEAD 2>/dev/null)"
case "$SUBJECTS" in
  *"factory: planreview"*) ok "the final stage is recorded by name in history" ;;
  *) bad "no per-stage commit messages: $(printf '%s' "$SUBJECTS" | tr '\n' '|')" ;;
esac

# --- 6. resolve installs the sandbox ignore rules ---------------------------
grep -qxF '.foreman-sandbox/' "$D/.gitignore" 2>/dev/null \
  && ok "resolve added .foreman-sandbox/ to the project's .gitignore" \
  || bad ".gitignore has no .foreman-sandbox/ — a salvage commit could record a nested worktree as a gitlink"
grep -qxF 'node_modules/' "$D/.gitignore" 2>/dev/null \
  && ok "the human's own ignore rule survived (append, not rewrite)" \
  || bad "resolve replaced .gitignore instead of appending to it"
[ "$(grep -c '^\.foreman-sandbox/$' "$D/.gitignore" 2>/dev/null)" = "1" ] \
  && ok "the ignore entry is not duplicated" || bad "duplicate .foreman-sandbox/ entries"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
