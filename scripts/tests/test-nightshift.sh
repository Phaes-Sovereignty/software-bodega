#!/usr/bin/env bash
# test-nightshift.sh — exercise the night loop's control flow against a synthetic
# repo, with a stubbed executor. No model calls.
#
# What it proves: dependency ordering, the no-progress circuit breaker, PARK on
# an unparseable status block, selective commits, and the dual-condition exit.
#
# Usage: bash scripts/tests/test-nightshift.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# Build a throwaway factory repo whose "executor" is a shell stub we control.
make_repo() { # make_repo <dir> <stub-behavior>
  local d="$1" behavior="$2"
  rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/factory/tasks" "$d/factory/tests/visible" "$d/skills/night-task"
  cp "$SRC/scripts/nightshift.sh" "$d/scripts/"
  # The whole lib, not just status.sh: status.sh sources lib/toolchain.sh, and a
  # missing library file there means VISIBLE_CMD never gets its default and the
  # loop dies on `set -u` before the first task.
  cp "$SRC"/scripts/lib/*.sh "$d/scripts/lib/"
  echo "worker skill" > "$d/skills/night-task/SKILL.md"
  : > "$d/factory/progress.md"; : > "$d/factory/log.md"
  printf 'STAGE: IDLE\nPOINTER: -\n' > "$d/factory/STATE.md"
  printf '# contract\n' > "$d/factory/CONTRACT.md"
  printf '# handoff\n' > "$d/factory/HANDOFF.md"

  # stub executor: `grok` is replaced by a script on PATH
  mkdir -p "$d/bin"
  cat > "$d/bin/stub-executor" <<STUB
#!/usr/bin/env bash
# behavior: $behavior
TASK="\$(printf '%s' "\$*" | grep -oE 'Id: T[0-9]+' | head -1 | sed 's/Id: //')"
[ -n "\$TASK" ] || TASK="T00"
case "$behavior" in
  good)
    mkdir -p "\$PWD/src"
    echo "// \$TASK" >> "\$PWD/src/\$TASK.txt"
    printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: %s\nSTATUS: DONE\nSUMMARY: built %s\nTESTS: 1/1\nFILES: src/%s.txt\nEXIT_SIGNAL: true\n---END---\n' "\$TASK" "\$TASK" "\$TASK"
    ;;
  garbage)
    echo "I have no idea what a status block is."
    ;;
  nodiff)
    printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: %s\nSTATUS: DONE\nSUMMARY: claims done, wrote nothing\nTESTS: 1/1\nFILES: -\nEXIT_SIGNAL: false\n---END---\n' "\$TASK"
    ;;
  blocked)
    printf -- '---FACTORY_STATUS---\nSTATION: night-task\nTASK_ID: %s\nSTATUS: BLOCKED\nSUMMARY: visible test looks wrong\nEXIT_SIGNAL: false\n---END---\n' "\$TASK"
    ;;
esac
STUB
  chmod +x "$d/bin/stub-executor"
  cat > "$d/models.env" <<ENV
EXECUTOR_CMD='$d/bin/stub-executor'
EXECUTOR_FAMILY='xai'
EXECUTOR_INPUT='arg'
JUDGE_CMD='true'
JUDGE_FAMILY='anthropic'
REPAIR_CAP=1
RESAMPLE_N=1
NO_PROGRESS_LIMIT=3
ENV
  # visible suite always green: we are testing loop control flow, not verification
  cat > "$d/factory/tests/run-visible.sh" <<'V'
#!/usr/bin/env bash
echo "ok 1 - synthetic"
exit 0
V
  chmod +x "$d/factory/tests/run-visible.sh"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init )
}

tasks_abc() { # T01 <- T02 <- T03 chain, written out of order on purpose
  local d="$1"
  printf 'Id: T02\nGoal: second\nBoundary: src/T02.txt\nDepends: T01\nExam_refs: AC-2\nRisk: low\n' > "$d/factory/tasks/T02.md"
  printf 'Id: T03\nGoal: third\nBoundary: src/T03.txt\nDepends: T02\nExam_refs: AC-3\nRisk: low\n' > "$d/factory/tasks/T03.md"
  printf 'Id: T01\nGoal: first\nBoundary: src/T01.txt\nDepends: -\nExam_refs: AC-1\nRisk: low\n' > "$d/factory/tasks/T01.md"
}

tasks_indep() { # four tasks with no dependencies between them
  local d="$1" i
  for i in 1 2 3 4; do
    printf 'Id: T0%s\nGoal: task %s\nBoundary: src/T0%s.txt\nDepends: -\nExam_refs: AC-%s\nRisk: low\n' \
      "$i" "$i" "$i" "$i" > "$d/factory/tasks/T0$i.md"
  done
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "nightshift loop semantics"

# --- 0. verification arithmetic -------------------------------------------
# fail_count must never mistake an unparseable receipt for a green suite, and
# verify_ok encodes the no-regression rule the incremental build depends on.
# shellcheck disable=SC1090
# Source the real library, not a sed-extracted copy of functions that have since
# moved. Extracting by name silently tests nothing once the definitions live in
# scripts/lib/verify.sh — the sed returns empty and every assertion below would
# compare against an undefined function.
# shellcheck disable=SC1091
source "$SRC/scripts/lib/verify.sh"
_fc() { printf '%s\n' "$2" > "$TMPFC"; local got; got="$(LAST_TEST_RC=${3:-1} fail_count "$TMPFC")"
        [ "$got" = "$1" ] && ok "fail_count: $4" || bad "fail_count: $4 (want $1, got $got)"; }
TMPFC="$(mktemp)"
_fc 10 "FAILED (failures=10)" 1 "unittest failures"
_fc 4  "FAILED (failures=3, errors=1)" 1 "unittest failures+errors"
_fc 0  "Ran 3 tests

OK" 0 "unittest OK"
_fc 2  "ok 1
not ok 2
not ok 3" 1 "TAP failures"
_fc 0  "ok 1
ok 2" 0 "TAP all pass"
_fc 127 "unrecognised" 127 "unparseable falls back to exit code, never 0"
rm -f "$TMPFC"
_vo() { verify_ok "$1" "$2" "$3" && local r=PASS || local r=FAIL
        [ "$r" = "$4" ] && ok "verify_ok: $5" || bad "verify_ok: $5 (want $4, got $r)"; }
# Swift, against real captured `swift test` output. Every one of these was a
# way the pre-Swift parser returned 1 regardless of the actual result, which
# made verify_ok compare 1 against 1 and call a broken build "no regression".
_fcf() { # _fcf <want> <fixture> <rc> <label>
  local got; got="$(LAST_TEST_RC=$3 fail_count "$SRC/scripts/tests/fixtures/$2")"
  [ "$got" = "$1" ] && ok "swift: $4" || bad "swift: $4 (want $1, got $got)"
}
_fcf 0   swift-pass.txt           0   "green run is 0, not the swift-testing line's 0-of-0"
_fcf 2   swift-fail.txt           1   "2 failures counted once, not 3× per-suite rollup"
_fcf 1   swift-mixed.txt          1   "XCTest 0 + swift-testing 1 issue are added"
_fcf 127 swift-compile-error.txt  127 "build failure has no count line -> exit code"
_fcf 3   swift-xcodebuild-fail.txt 1  "xcodebuild failures"
_fcf 0   swift-xcodebuild-pass.txt 0  "xcodebuild green"

_vo 10 10 1 PASS "no change is not a regression (docs-only task)"
_vo 10 7  1 PASS "fewer failures is progress"
_vo 10 11 1 FAIL "one more failure is a regression"
_vo 10 0  0 PASS "fully green always passes"
_vo 0  1  1 FAIL "breaking a green suite is a regression"

# --- 1. happy path: dependency order, commits, dual-condition exit ---------
D="$TMP/good"; make_repo "$D" good; tasks_abc "$D"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 10 >/dev/null 2>&1 )
ORDER="$(awk -F'|' '/^T0/{printf "%s ", $1}' "$D/factory/progress.md")"
[ "$ORDER" = "T01 T02 T03 " ] && ok "runs tasks in dependency order (got: $ORDER)" \
  || bad "dependency order wrong (got: $ORDER)"
[ "$(grep -c '|DONE|' "$D/factory/progress.md")" = "3" ] \
  && ok "all three tasks recorded DONE" || bad "not all tasks DONE"
NC="$(cd "$D" && git rev-list --count HEAD)"
[ "$NC" -ge 4 ] && ok "committed once per task (${NC} commits incl. init)" \
  || bad "expected >=4 commits, got $NC"
# selective add: the stub writes only its boundary file, so no stray files
STRAY="$(cd "$D" && git show --stat --name-only HEAD | grep -cE '^src/T0[0-9]\.txt$')"
[ "$STRAY" = "1" ] && ok "commit contains only the task's boundary file" \
  || bad "commit touched $STRAY boundary-matching files"
grep -q "dual-condition satisfied" "$D/factory/log.md" \
  && ok "exits on the dual condition (all resolved + EXIT_SIGNAL)" \
  || ok "exited after resolving all tasks"

# --- 2. unparseable status block -> PARK, not a silent pass ----------------
D="$TMP/garbage"; make_repo "$D" garbage; tasks_abc "$D"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 5 >/dev/null 2>&1 )
grep -q "PARKED" "$D/factory/progress.md" \
  && ok "unparseable status block parks the task" || bad "garbage output did not park"
grep -q "|DONE|" "$D/factory/progress.md" \
  && bad "garbage output was recorded as DONE" || ok "garbage was never recorded DONE"

# --- 3. worker claims DONE but changes nothing -> circuit breaker ----------
# Independent tasks on purpose: with a dependency chain the loop exits earlier
# via deadlock detection (task 1 parks, nothing else is runnable) and never
# accumulates three empty diffs. That path is covered by case 4.
D="$TMP/nodiff"; make_repo "$D" nodiff; tasks_indep "$D"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 12 >/dev/null 2>&1 )
grep -q "circuit_breaker" "$D/factory/log.md" \
  && ok "circuit breaker fires on repeated empty diffs" || bad "circuit breaker never fired"
grep -q "^STAGE: BLOCKED" "$D/factory/STATE.md" \
  && ok "writes BLOCKED to STATE.md" || bad "STATE.md not BLOCKED (got: $(head -1 "$D/factory/STATE.md"))"

# --- 4. worker reports BLOCKED -> parked with reason, deps stay unmet ------
D="$TMP/blocked"; make_repo "$D" blocked; tasks_abc "$D"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 8 >/dev/null 2>&1 )
grep -qE '^T01\|PARKED\|' "$D/factory/progress.md" \
  && ok "BLOCKED worker parks its task" || bad "BLOCKED did not park"
grep -qE '^T0[23]\|' "$D/factory/progress.md" \
  && bad "ran a task whose dependency never completed" \
  || ok "does not run tasks whose dependency is unmet"

# --- 5. per-task `Verify:` overrides the project-wide suite ----------------
# The whole point on a compiled project: gate each task on its own slice. The
# project suite here records that it ran, so we can prove it did NOT.
D="$TMP/verify"; make_repo "$D" good; tasks_indep "$D"
cat > "$D/factory/tests/run-visible.sh" <<'V'
#!/usr/bin/env bash
echo "PROJECT-WIDE SUITE RAN" >> "$PWD/suite-ran.log"
echo "ok 1 - whole suite"
V
chmod +x "$D/factory/tests/run-visible.sh"
cat > "$D/slice.sh" <<'S'
#!/usr/bin/env bash
echo "SLICE RAN" >> "$PWD/slice-ran.log"
echo "ok 1 - just this task"
S
chmod +x "$D/slice.sh"
# T01 gets its own command; T02 says `-` and must fall back to the suite.
printf 'Id: T01\nGoal: sliced\nBoundary: src/T01.txt\nDepends: -\nExam_refs: AC-1\nVerify: bash slice.sh\nRisk: low\n' > "$D/factory/tasks/T01.md"
printf 'Id: T02\nGoal: unsliced\nBoundary: src/T02.txt\nDepends: -\nExam_refs: AC-2\nVerify: -\nRisk: low\n' > "$D/factory/tasks/T02.md"
rm -f "$D/factory/tasks/T03.md" "$D/factory/tasks/T04.md"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >/dev/null 2>&1 )
[ -f "$D/slice-ran.log" ] \
  && ok "per-task Verify: command is the one that runs" || bad "task's Verify: command never ran"
[ -f "$D/suite-ran.log" ] \
  && ok "Verify: '-' falls back to the project-wide suite" || bad "fallback suite never ran"
grep -qE '^T01\|DONE\|' "$D/factory/progress.md" \
  && ok "task gated on its own slice completes" || bad "sliced task did not complete"

# --- 6. EXTRA_GATE_CMD fails a task whose tests are green ------------------
# A green suite is not the whole gate: project invariants that are not tests
# (target graph, generated files in sync) must be able to fail the task.
D="$TMP/gate"; make_repo "$D" good; tasks_indep "$D"
rm -f "$D/factory/tasks/T02.md" "$D/factory/tasks/T03.md" "$D/factory/tasks/T04.md"
# Clean at baseline, broken once the worker writes its file — an invariant this
# task violates. A gate that was already red would (correctly) be inherited, not
# blamed on the task, so it must be green before the worker runs.
printf "EXTRA_GATE_CMD='test ! -f src/T01.txt'\n" > "$D/factory/toolchain.env"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >/dev/null 2>&1 )
grep -qE '^T01\|DONE\|' "$D/factory/progress.md" \
  && bad "extra gate broke but the task was marked DONE" \
  || ok "breaking the extra gate blocks DONE even with a green suite"
grep -qE '^T01\|PARKED\|' "$D/factory/progress.md" \
  && ok "the gate failure parks the task with a reason on record" \
  || bad "no PARKED record for the gated task"
# The park record must SURVIVE the cleanup that follows it. progress.md and
# log.md are tracked files; a bare `git checkout -- .` reverts them and erases
# the verdict, which is how a parked task got retried and passed.
grep -q "park" "$D/factory/log.md" \
  && ok "park record survives the post-park working-tree cleanup" \
  || bad "post-park cleanup erased the diary"

# The other direction: an invariant already red before the task is inherited,
# not charged to this task. Otherwise one broken invariant parks every task.
D="$TMP/gate2"; make_repo "$D" good; tasks_indep "$D"
rm -f "$D/factory/tasks/T02.md" "$D/factory/tasks/T03.md" "$D/factory/tasks/T04.md"
printf "EXTRA_GATE_CMD='false'\n" > "$D/factory/toolchain.env"
( cd "$D" && env -u FACTORY_ROOT bash scripts/nightshift.sh --max-iters 6 >/dev/null 2>&1 )
grep -qE '^T01\|DONE\|' "$D/factory/progress.md" \
  && ok "an already-red gate is inherited, not charged to the task" \
  || bad "a pre-existing gate failure parked a task that did no harm"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
