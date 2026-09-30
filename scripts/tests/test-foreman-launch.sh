#!/usr/bin/env bash
# test-foreman-launch.sh — prove the night shift's held-out seal is PHYSICAL when
# it is launched through `python -m foreman launch`, and that the night's work
# survives on a branch.
#
# The bug this closes: the conductor called scripts/nightshift.sh directly, which
# runs in the MAIN checkout — where the held-out suite is readable and the only
# protection was a sentence in a prompt. Measured: workers write outside the
# project and reach around the bash gate, so "please don't read that folder" is
# not a control. foreman launch builds a sparse-checkout worktree instead.
#
# Skips cleanly (exit 0) when PyYAML is unavailable, because the foreman needs it.
#
# Usage: bash scripts/tests/test-foreman-launch.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

PY="${PYTHON:-python3}"
if ! "$PY" -c 'import yaml' >/dev/null 2>&1; then
  printf '  \033[33m–\033[0m PyYAML unavailable for %s — skipping the foreman seal tests\n' "$PY"
  printf '\n0 passed, 0 failed (skipped)\n'
  exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- build a project with a real held-out secret and a stub executor --------
P="$TMP/proj"
mkdir -p "$P/scripts/lib" "$P/foreman" "$P/skills/night-task" "$P/factory/tasks" \
         "$P/factory/tests/visible" "$P/factory/tests/heldout" "$P/bin" "$P/src"
cp "$SRC"/scripts/*.sh "$P/scripts/"; cp "$SRC"/scripts/lib/*.sh "$P/scripts/lib/"
cp -R "$SRC"/foreman/*.py "$P/foreman/"; cp "$SRC"/foreman/routing.yaml "$P/foreman/"
cp "$SRC"/models.env "$P/"
printf 'worker skill\n' > "$P/skills/night-task/SKILL.md"
: > "$P/factory/progress.md"; : > "$P/factory/log.md"
printf 'STAGE: NIGHT_SHIFT\nPOINTER: test\n' > "$P/factory/STATE.md"
printf '# contract\n' > "$P/factory/CONTRACT.md"; printf '# handoff\n' > "$P/factory/HANDOFF.md"

# The secret the builder must never see. Content-searchable, so a leak is loud.
printf 'HELDOUT_SECRET_CANARY_4f19\n' > "$P/factory/tests/heldout/test_secret.py"
printf 'def test_visible():\n    assert True\n' > "$P/factory/tests/visible/test_v.py"
cat > "$P/factory/tests/run-visible.sh" <<'G'
#!/usr/bin/env bash
echo "Ran 1 test"; echo "OK"; exit 0
G
cat > "$P/factory/tests/run-heldout.sh" <<'G'
#!/usr/bin/env bash
echo "Ran 1 test"; echo "OK"; exit 0
G
chmod +x "$P/factory/tests/run-"*.sh
printf "HELDOUT_DIR='factory/tests/heldout'\n" > "$P/factory/toolchain.env"

# Stub executor that LOOKS for the held-out suite and reports what it finds.
# This is the honest version of the test: it does not trust the seal's log line,
# it has the worker try to read the exam.
cat > "$P/bin/peeker" <<'STUB'
#!/usr/bin/env bash
# The canary is ASSEMBLED at runtime and never written whole into this script.
# It used to be a literal, and `grep -rl` over $PWD matched the seeker's OWN
# source file — reporting LEAKED in a tree where the held-out directory had been
# correctly removed. A seal probe that reads itself as a leak is worthless in
# both directions: it cannot certify a seal, and it cannot trust its own pass.
CANARY="HELDOUT_SECRET""_CANARY_""4f19"
HITS="$(grep -rl "$CANARY" "$PWD" 2>/dev/null | grep -v 'bin/peeker$' | head -1)"
if [ -n "$HITS" ]; then
  echo "LEAKED:$HITS" > "$PWD/.seal-verdict"
elif [ -e "$PWD/factory/tests/heldout" ]; then
  echo "LEAKED:directory-present" > "$PWD/.seal-verdict"
else
  echo "SEALED" > "$PWD/.seal-verdict"
fi
mkdir -p "$PWD/src"
echo "work $$ $RANDOM" > "$PWD/src/T01.txt"
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: wrote one file\nTESTS: 1/1\nFILES: src/T01.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
chmod +x "$P/bin/peeker"
cat > "$P/models.env" <<ENV
EXECUTOR_CMD='$P/bin/peeker'
EXECUTOR_FAMILY='xai'
EXECUTOR_INPUT='arg'
PLANNER_CMD='$P/bin/peeker'
PLANNER_FAMILY='anthropic'
PLANNER_INPUT='arg'
JUDGE_CMD='$P/bin/peeker'
JUDGE_FAMILY='openai'
JUDGE_INPUT='arg'
PLAN_JUDGE_CMD='$P/bin/peeker'
PLAN_JUDGE_FAMILY='moonshot'
PLAN_JUDGE_INPUT='arg'
GLUE_CMD='$P/bin/peeker'
GLUE_FAMILY='moonshot'
TRIAGE_CMD='$P/bin/peeker'
TRIAGE_FAMILY='moonshot'
FALLBACK_CMD='$P/bin/peeker'
FALLBACK_FAMILY='local'
ESCALATION_LADDER='resample:executor:1:execution single:planner'
REPAIR_CAP=0
RESAMPLE_N=1
NO_PROGRESS_LIMIT=9
ADAPTER_RETRIES=0
ENV
# src/ must contain a TRACKED file: git does not track directories, so a fresh
# worktree has no src/ at all and a worker writing src/T01.txt fails on a missing
# parent — which then reads as "no file changes produced" and the branch test
# silently checks an empty branch.
echo "keep me" > "$P/src/keep.txt"
printf 'Id: T01\nGoal: write a file\nBoundary: src/T01.txt\nDepends: -\nExam_refs: AC-1\nRisk: low\n' \
  > "$P/factory/tasks/T01.md"
printf '.seal-verdict\n' >> "$P/.gitignore" 2>/dev/null || printf '.seal-verdict\n' > "$P/.gitignore"
( cd "$P" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm "exam board + task" ) >/dev/null 2>&1

echo "foreman launch — the physical seal"

# --- 1. baseline: the secret IS in the main checkout (otherwise this proves 0)
grep -rq "HELDOUT_SECRET_CANARY_4f19" "$P" 2>/dev/null \
  && ok "held-out suite is present in the main checkout (the thing to hide)" \
  || { bad "fixture wrong: no held-out content to seal"; exit 1; }

# --- 2. the UNSEALED path leaks, exactly as the bug report says ------------
# Run nightshift.sh directly in the main checkout — the conductor's old behaviour.
( cd "$P" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 2 >/dev/null 2>&1 )
if [ -f "$P/.seal-verdict" ]; then
  V="$(cat "$P/.seal-verdict")"
  case "$V" in
    LEAKED*) ok "regression proof: a direct nightshift.sh run lets the worker READ the exam ($V)" ;;
    *)       bad "expected the unsealed path to leak, got '$V' — this test would stop catching the bug" ;;
  esac
  # Hard reset: the leak demo COMMITTED src/T01.txt, and if that commit is left
  # in place the sealed run writes identical content, shows an empty diff, and
  # every "the branch carries the work" assertion below passes for the wrong
  # reason. Delete the file from the tree AND the index.
  rm -f "$P/.seal-verdict" "$P/src/T01.txt"
  git -C "$P" rm -q --cached src/T01.txt 2>/dev/null
  git -C "$P" checkout -q -- . 2>/dev/null
  git -C "$P" clean -qfd 2>/dev/null
  printf '# progress.md\n' > "$P/factory/progress.md"
  printf '# log.md\n'     > "$P/factory/log.md"
  ( cd "$P" && git add -A && git commit -qm "reset fixture" ) >/dev/null 2>&1
  [ ! -f "$P/src/T01.txt" ] \
    && ok "fixture reset: the worker's file is gone before the sealed run" \
    || bad "reset failed — src/T01.txt still tracked, so later assertions prove nothing"
else
  bad "unsealed run produced no verdict file — the fixture is not exercising the worker"
fi

# --- 3. foreman launch seals it physically ---------------------------------
BR="bodega/test-night"
ROUTING="$SRC/foreman/routing.yaml"
OUT="$("$PY" -m foreman --root "$P" launch --max-iters 3 --branch "$BR" --no-probe --keep-sandbox 2>&1)"
LRC=$?
printf '%s\n' "$OUT" | sed 's/^/    launch| /' | head -12
[ "$LRC" = "0" ] && ok "foreman launch exits clean (rc=0)" \
  || bad "foreman launch failed rc=$LRC"
printf '%s' "$OUT" | grep -q "sealed sandbox" \
  && ok "launch reports the sealed sandbox" || bad "launch did not report sealing"
printf '%s' "$OUT" | grep -q "night branch: $BR" \
  && ok "launch reports the BRANCH the night landed on" \
  || bad "launch did not report a branch — results would be unreachable"

SB="$P/.foreman-sandbox"
[ -d "$SB" ] && ok "the sandbox worktree exists" || bad "no sandbox worktree at $SB"
if [ -d "$SB" ]; then
  [ ! -e "$SB/factory/tests/heldout" ] \
    && ok "held-out directory is ABSENT from the sandbox" \
    || bad "held-out directory present in the sandbox — seal broken"
  # The strongest check: the worker itself reports what it could reach.
  if [ -f "$SB/.seal-verdict" ]; then
    SV="$(cat "$SB/.seal-verdict")"
    [ "$SV" = "SEALED" ] \
      && ok "the WORKER could not read the held-out content (it reported SEALED)" \
      || bad "the worker reported '$SV' — the seal is prompt-level only"
  else
    bad "worker left no seal verdict — it may not have run in the sandbox at all"
  fi
  # And the sandbox must not be an empty shell.
  if [ -d "$SB/src" ] && [ -f "$SB/scripts/nightshift.sh" ]; then
    ok "sandbox contains the project source and the loop itself (not an empty checkout)"
  else
    bad "sandbox incomplete: src=$([ -d "$SB/src" ] && echo y || echo n) loop=$([ -f "$SB/scripts/nightshift.sh" ] && echo y || echo n) listing=$(ls -a "$SB" 2>&1 | tr '\n' ' ')"
  fi
  [ -f "$SB/factory/tests/visible/test_v.py" ] \
    && ok "visible suite present in the sandbox" || bad "visible suite missing from sandbox"
fi

# --- 4. the work SURVIVES on a branch --------------------------------------
if git -C "$P" rev-parse --verify -q "$BR" >/dev/null; then
  ok "the night's branch exists in the repo"
  [ "$(git -C "$P" rev-parse "$BR")" != "$(git -C "$P" rev-parse HEAD)" ] \
    && ok "the branch is AHEAD of the base commit (not a pointer to where we started)" \
    || bad "branch and base are the same commit — the night landed nothing"
  N="$(git -C "$P" rev-list --count "HEAD..$BR" 2>/dev/null || echo 0)"
  if [ "${N:-0}" -lt 1 ]; then
    printf '    diag: HEAD=%s BR=%s\\n' "$(git -C "$P" rev-parse --short HEAD)" \
      "$(git -C "$P" rev-parse --short "$BR" 2>/dev/null)"
    printf '    diag: progress=%s\\n' "$(tr '\n' '|' < "$P/factory/progress.md" 2>/dev/null | head -c 200)"
    printf '    diag: sbprogress=%s\\n' "$(tr '\n' '|' < "$SB/factory/progress.md" 2>/dev/null | head -c 200)"
    printf '    diag: branchlog=%s\\n' "$(git -C "$P" log --oneline "$BR" 2>&1 | head -3 | tr '\n' '|')"
  fi
  [ "$N" -ge 1 ] && ok "branch carries $N commit(s) beyond the base" \
    || bad "branch exists but has no commits — the night produced nothing reachable"
  # --name-status, and require an ADD. `git show --name-only` on the commit that
  # DELETED src/T01.txt also prints the path, which made this assertion pass on
  # a branch carrying no work at all.
  #
  # Across the RANGE, not the tip. The launcher appends a diary commit after the
  # work commits, so the tip legitimately touches only factory/ — asserting on the
  # tip alone fails a night that shipped everything correctly.
  git -C "$P" log --name-status --format= "HEAD..$BR" 2>/dev/null \
    | grep -qE '^A[a-z]*[[:space:]]+src/T01.txt' \
    && ok "a commit in the night's range ADDS the worker's file" \
    || bad "no commit in $BR adds the work: $(git -C "$P" log --name-status --format= "HEAD..$BR" 2>/dev/null | tr '\n' '|')"
  # The base must NOT contain it — otherwise "the branch carries the work" is
  # true of an empty branch and the test is vacuous.
  if git -C "$P" ls-tree -r --name-only "HEAD" 2>/dev/null | grep -q "^src/T01.txt$"; then
    bad "base already contains src/T01.txt — the branch assertion is vacuous"
  else
    ok "base does NOT contain the file, so the branch genuinely carries the night"
  fi
else
  bad "no branch after launch — the night's commits are unreachable (detached HEAD)"
fi
# --- 4b. the DIARY survives the sandbox ------------------------------------
# commit_task stages only a task's boundary files, so progress.md, STATE.md and
# author-families.txt reach neither the branch nor the main checkout: they sit in
# the sandbox and remove_worktree deletes them with it. Measured consequences --
# inspect.sh finds no |DONE| row, so BASE falls back to the ROOT commit and the
# scope/tamper audit diffs all of history instead of the night; and with
# author-families.txt gone the judge is checked against `role_family executor`
# rather than the ladder rung that actually wrote the code. Asserted on the
# ARTIFACTS, never on a log line.
if git -C "$P" show "$BR:factory/progress.md" 2>/dev/null | grep -qE '^T01\|DONE\|'; then
  ok "the branch's progress.md carries the T01 DONE row (inspect.sh can derive BASE)"
else
  bad "branch progress.md has no DONE row: $(git -C "$P" show "$BR:factory/progress.md" 2>/dev/null | tr '\n' '|' | head -c 200)"
fi
git -C "$P" show "$BR:factory/.planning/author-families.txt" 2>/dev/null | grep -qx "xai" \
  && ok "the branch records the author family (xai) -- judge selection has real input" \
  || bad "branch has no author-families.txt -- the cross-family check would fall back to the executor ROLE"
grep -qE '^T01\|DONE\|' "$P/factory/progress.md" 2>/dev/null \
  && ok "the MAIN CHECKOUT's progress.md shows the night's work" \
  || bad "main checkout progress.md is still header-only: $(tr '\n' '|' < "$P/factory/progress.md" 2>/dev/null | head -c 160)"
[ -s "$P/factory/.planning/author-families.txt" ] \
  && ok "the MAIN CHECKOUT has a non-empty author-families.txt" \
  || bad "no author-families.txt in the main checkout"

# A sandbox that gets REMOVED must not take the diary with it. The block above
# runs with --keep-sandbox, so it would also pass if publish_diary only copied
# into a tree that happens to still be on disk. This is the discard path:
# remove_worktree() runs, the directory is gone, and the main checkout is the
# only place left for the morning to read.
rm -f "$P/.seal-verdict" "$P/src/T01.txt"
git -C "$P" rm -q --cached src/T01.txt 2>/dev/null
git -C "$P" checkout -q -- . 2>/dev/null
git -C "$P" clean -qfd -e .foreman-sandbox 2>/dev/null
printf '# progress.md\n' > "$P/factory/progress.md"
printf '# log.md\n'     > "$P/factory/log.md"
rm -f "$P/factory/.planning/author-families.txt"
( cd "$P" && git add -A && git commit -qm "reset fixture for the discard run" ) >/dev/null 2>&1
OUTD="$("$PY" -m foreman --root "$P" launch --max-iters 3 --branch "bodega/test-discard" --no-probe 2>&1)"
printf '%s\n' "$OUTD" | grep -q "sandbox removed" \
  && ok "fixture took the discard path (sandbox removed, not kept)" \
  || bad "expected the sandbox to be removed: $(printf '%s' "$OUTD" | tail -2 | tr '\n' '|' | head -c 200)"
[ ! -d "$P/.foreman-sandbox" ] \
  && ok "the sandbox directory is genuinely gone" \
  || bad "sandbox still on disk — this run did not exercise the discard path"
grep -qE '^T01\|DONE\|' "$P/factory/progress.md" 2>/dev/null \
  && ok "diary SURVIVES sandbox removal in the main checkout" \
  || bad "diary was discarded with the sandbox — the morning has no record of the night"
[ -s "$P/factory/.planning/author-families.txt" ] \
  && ok "author-families.txt survives sandbox removal" \
  || bad "author-families.txt was discarded with the sandbox"
git -C "$P" show "bodega/test-discard:factory/progress.md" 2>/dev/null | grep -qE '^T01\|DONE\|' \
  && ok "the discarded run's BRANCH also carries the diary" \
  || bad "branch from the discard run has no DONE row"

# --- 5. routing.yaml's heldout path must not silently win over the project --
# The pre-fix code passed router.path("heldout") explicitly, so a project that
# declared a different HELDOUT_DIR was sealed at routing.yaml's constant.
printf "HELDOUT_DIR='custom/secret'\n" > "$P/factory/toolchain.env"
mkdir -p "$P/custom/secret" && printf 'CANARY_CUSTOM_77\n' > "$P/custom/secret/x.py"
( cd "$P" && git add -A && git commit -qm "declared custom heldout dir" ) >/dev/null 2>&1
OUT2="$("$PY" -m foreman --root "$P" launch --max-iters 1 --branch "bodega/test-custom" --no-probe 2>&1)"
printf '%s\n' "$OUT2" | grep -q "custom/secret" \
  && ok "launch seals the PROJECT-DECLARED directory (custom/secret)" \
  || { printf '    launch2| %s\n' "$(printf '%s\n' "$OUT2" | head -4 | tr '\n' '|')"; \
       bad "launch did not use the declared HELDOUT_DIR — routing.yaml still wins"; }
[ -d "$P/.foreman-sandbox/custom/secret" ] \
  && bad "custom/secret survived in the sandbox" \
  || ok "custom/secret is absent from the new sandbox"

# --- 5b. the loop states its seal mode, measured not asserted --------------
# The unsealed path is the one the conductor used to take by default, and every
# log line implied the seal was on. It must now say, in its own output and in the
# diary, that the exam is readable.
DIRECT_LOG="$( cd "$P" && env -u FACTORY_ROOT -u BODEGA_SEALED -u SEAL_MODE \
                bash scripts/nightshift.sh --max-iters 1 2>&1 )"
printf '%s' "$DIRECT_LOG" | grep -q "seal: NONE" \
  && ok "a direct nightshift.sh run ANNOUNCES the exam is readable" \
  || bad "unsealed run did not report its seal mode"
# The loop points at scripts/foreman.sh, the interpreter-resolving entry point —
# not at `python -m foreman`, which is the command that silently fails on a host
# with no PyYAML and sends the conductor back to the unsealed path.
printf '%s' "$DIRECT_LOG" | grep -qiE 'foreman(\.sh)?[[:space:]]+launch' \
  && ok "it names the fix (the sealed launcher) rather than just complaining" \
  || bad "unsealed warning does not point at the sealed path: $(printf '%s' "$DIRECT_LOG" | grep -i seal | head -3 | tr '\n' '|')"
printf '%s' "$OUT" | grep -q "seal: PHYSICAL" \
  && ok "the launched night reports seal: PHYSICAL (measured, not taken on trust)" \
  || bad "sealed night did not report PHYSICAL"
( cd "$P" && git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null )

# --- 6. a worker that breaks the seal mid-task cannot commit ---------------
# seal_intact is a DETECTION control, not containment: a linked worktree shares
# the parent's object store, so `git sparse-checkout disable` + checkout does
# bring the exam back. What must not happen is that work landing on the branch
# looks like a normal night. This asserts the escape is caught at commit time and
# halts the loop.
ESC="$TMP/escape"
rm -rf "$ESC"; cp -R "$P" "$ESC" 2>/dev/null
( cd "$ESC" && git worktree prune ) >/dev/null 2>&1
rm -rf "$ESC/.foreman-sandbox"
( cd "$ESC" && git add -A && git commit -qm "escape fixture" ) >/dev/null 2>&1
# worker: unseal, read the exam, then write code that "passes"
cat > "$ESC/bin/escaper" <<'STUB'
#!/usr/bin/env bash
git sparse-checkout disable >/dev/null 2>&1
git checkout -- . >/dev/null 2>&1
if [ -f factory/tests/heldout/test_secret.py ]; then
  echo "I READ THE EXAM" > "$PWD/src/studied.txt"
else
  echo "no exam" > "$PWD/src/studied.txt"
fi
printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: T01\nSTATUS: DONE\nSUMMARY: cheated\nTESTS: 1/1\nFILES: src/studied.txt\nEXIT_SIGNAL: true\n---END---\n'
STUB
chmod +x "$ESC/bin/escaper"
python3 - "$ESC" <<'PY'
import sys, pathlib, re
d = sys.argv[1]
f = pathlib.Path(d) / "models.env"
t = f.read_text()
t = re.sub(r"^EXECUTOR_CMD=.*$", "EXECUTOR_CMD='%s/bin/escaper'" % d, t, flags=re.M)
f.write_text(t)
PY
# task must be runnable: reset the diary so T01 is unresolved
printf '# progress.md\n' > "$ESC/factory/progress.md"
printf '# log.md\n' > "$ESC/factory/log.md"
printf 'Id: T01\nGoal: cheat\nBoundary: src/studied.txt\nDepends: -\nExam_refs: AC-1\nRisk: low\n' \
  > "$ESC/factory/tasks/T01.md"
( cd "$ESC" && git add -A && git commit -qm "escape task" ) >/dev/null 2>&1
EOUT="$("$PY" -m foreman --root "$ESC" launch --max-iters 3 --branch bodega/escape --no-probe --keep-sandbox 2>&1)"; ERC=$?
printf '%s\n' "$EOUT" | grep -q "SEAL NOT INTACT" \
  && ok "the escape is CAUGHT: commit refused (SEAL NOT INTACT)" \
  || bad "escape not caught (rc=$ERC): $(printf '%s' "$EOUT" | grep -iE "seal|empty diff|DONE" | head -2 | tr '\n' '|')"
grep -q "seal_broken" "$ESC/.foreman-sandbox/factory/log.md" 2>/dev/null \
  && ok "log.md records seal_broken — the diary explains the halt" \
  || bad "no seal_broken entry in the sandbox log"
grep -qE "^T01\|PARKED\|" "$ESC/.foreman-sandbox/factory/progress.md" 2>/dev/null \
  && ok "the cheating task is PARKED, not DONE" \
  || bad "task not parked: $(tail -1 "$ESC/.foreman-sandbox/factory/progress.md" 2>/dev/null)"
if git -C "$ESC" rev-parse -q --verify bodega/escape >/dev/null 2>&1 \
   && git -C "$ESC" show --name-only --format= bodega/escape 2>/dev/null | grep -q "src/studied.txt"; then
  bad "the escapee's work landed on the branch — enforcement did not hold"
else
  ok "the cheated work never reached a branch"
fi
# And the exam WAS reachable, proving this is detection of a real escape rather
# than a test where nothing could leak.
grep -q "I READ THE EXAM" "$ESC/.foreman-sandbox/src/studied.txt" 2>/dev/null \
  && ok "confirmed: sparse-checkout disable DOES expose the exam (detection, not containment)" \
  || printf '  \033[33m–\033[0m escape did not expose the exam here; detection path still asserted\n'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
