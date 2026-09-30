#!/usr/bin/env bash
# inspect.sh — run the INSPECTOR station over a completed night.
#
# Artifact-only: the judge receives CONTRACT.md, the diff, and test receipts.
# It never receives a worker transcript or Implementation Notes — a worker that
# can explain its failure is a worker whose failure gets excused.
#
# Mechanical work happens HERE, not in the model: the suite runs twice (a flaky
# green is a finding), the held-out suite runs, and the tamper audit is a real
# git diff. The judge interprets evidence it cannot fabricate.
#
# Usage: bash scripts/inspect.sh [--base <sha>]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="$2"; shift ;;
    --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# hard rule 2: the judge must not share a family with the author of the work.
#
# NOT `assert_cross_family judge executor`. That compares a role against a role,
# once, and still passes when the escalation ladder had the planner (same family
# as the judge) write the code under review. The author here is whoever actually
# produced the accepted commits — recorded per rung in
# factory/.planning/author-families.txt — and the judge is chosen against that
# set. When no cross-family judge exists this REFUSES rather than quietly grading
# its own homework.
AUTHOR_FAMS="$(author_families)"
[ -n "$AUTHOR_FAMS" ] || AUTHOR_FAMS="$(role_family executor)"
JUDGE_ROLE="$(judge_for_family "$AUTHOR_FAMS")" || {
  echo "[inspect] REFUSING: every configured judge role shares a family with the authors ($AUTHOR_FAMS)" >&2
  status_emit "inspector" "-" "BLOCKED" "no cross-family judge available for authors $AUTHOR_FAMS"; exit 1
}
echo "[inspect] authors: $AUTHOR_FAMS -> judge: $JUDGE_ROLE ($(role_family "$JUDGE_ROLE"))" >&2
log_append "inspector" "judge_selected" "$JUDGE_ROLE ($(role_family "$JUDGE_ROLE")) vs authors $AUTHOR_FAMS"

SHA="$(git rev-parse HEAD)"
R="$(mktemp -d)"
# The night shift's first commit is the natural base if none is given.
[ -n "$BASE" ] || BASE="$(awk -F'|' '/\|DONE\|/{print $3; exit}' factory/progress.md 2>/dev/null)"
[ -n "$BASE" ] && BASE="$(git rev-parse "$BASE"^ 2>/dev/null || git rev-parse "$BASE")"
[ -n "$BASE" ] || BASE="$(git rev-list --max-parents=0 HEAD | head -1)"

echo "[inspect] head=$SHA base=$BASE" >&2
log_append "inspector" "start" "head=$SHA"

# --- 1. visible suite, TWICE ----------------------------------------------
# Both suites come from scripts/lib/toolchain.sh, not from a hard-coded
# run-visible.sh. A Swift project's visible suite is `swift test --filter
# VisibleTests`; inspecting it with the shell runner reads a file the project
# does not have and reports 127 as though it were a test result.
echo "[inspect] visible: $VISIBLE_CMD" >&2
echo "[inspect] running visible suite (run 1 of 2)" >&2
run_visible_suite "$R/vis1.log"; V1=$?
echo "[inspect] running visible suite (run 2 of 2)" >&2
run_visible_suite "$R/vis2.log"; V2=$?
FLAKY="no"
if [ "$V1" != "$V2" ]; then
  FLAKY="YES — run1 exit $V1, run2 exit $V2"
  echo "[inspect] FLAKY: visible suite disagreed with itself" >&2
fi

# --- 2. held-out suite — the checks the builder never saw ------------------
# Where HELDOUT_CMD finally gets read. It was declared in
# docs/toolchains/swift.env and referenced by nothing, so a Swift night was
# inspected against the visible suite only and the most important mechanism in
# the design never ran.
echo "[inspect] held-out: $HELDOUT_CMD (dir $HELDOUT_DIR)" >&2
if [ ! -d "$HELDOUT_DIR" ]; then
  printf 'held-out suite directory %s is absent — cannot prove the held-out checks ran\n' \
    "$HELDOUT_DIR" > "$R/held.log"
  H=127
else
  run_heldout_suite "$R/held.log"; H=$?
fi
if [ "$H" = "127" ]; then
  echo "[inspect] NO HELD-OUT EVIDENCE — missing evidence is not green" >&2
  log_append "inspector" "heldout_missing" "$HELDOUT_CMD"
fi

# --- 3. tamper audit — mechanical, not an opinion --------------------------
{
  echo "### CONTRACT.md changes since base"
  if git diff --quiet "$BASE".."$SHA" -- factory/CONTRACT.md 2>/dev/null; then
    echo "NONE — contract untouched."
  else
    echo "!!! CONTRACT.md WAS MODIFIED — this is a NOT DONE condition:"
    git diff "$BASE".."$SHA" -- factory/CONTRACT.md | head -100
  fi
  echo
  echo "### Test files changed since base (any change here needs justification)"
  # $VISIBLE_DIR and $HELDOUT_DIR, not a hard-coded factory/tests/ — in a Swift
  # package the exams live under Tests/ and a tamper there would have been
  # invisible to this audit.
  git diff --name-only "$BASE".."$SHA" -- "$VISIBLE_DIR" "$HELDOUT_DIR" factory/tests/ | sed 's/^/  /' || true
  git diff --quiet "$BASE".."$SHA" -- "$VISIBLE_DIR" "$HELDOUT_DIR" factory/tests/ 2>/dev/null \
    && echo "  NONE — exam suites untouched."
  echo
  echo "### Held-out seal audit — did any commit add files under $HELDOUT_DIR after the exam board?"
  if git diff --name-only "$BASE".."$SHA" -- "$HELDOUT_DIR" 2>/dev/null | grep -q .; then
    echo "!!! files under $HELDOUT_DIR changed since base:"
    git diff --name-only "$BASE".."$SHA" -- "$HELDOUT_DIR" | sed 's/^/  /'
  else
    echo "  none — held-out suite untouched."
  fi
  echo
  echo "### Weakening markers introduced in the diff"
  git diff "$BASE".."$SHA" -- "$VISIBLE_DIR" "$HELDOUT_DIR" factory/tests/ | grep -E '^\+' \
    | grep -nE 'skip|xfail|assert True|pass *$|TODO|@unittest.skip' | head -20 \
    || echo "  none found"
} > "$R/tamper.txt" 2>&1

# --- 4. scope ledger — declared boundaries vs what actually changed --------
{
  echo "### Files changed per task (declared boundary vs actual)"
  while IFS='|' read -r tid st sha tests note; do
    case "$tid" in \#*|"") continue ;; esac
    [ "$st" = "DONE" ] || { echo "  $tid: $st — $note"; continue; }
    echo "  $tid (declared): $(awk -F': *' 'tolower($1)=="boundary"{print $2}' "factory/tasks/$tid.md" 2>/dev/null)"
    echo "  $tid (actual)  : $(git show --name-only --format= "$sha" 2>/dev/null | tr '\n' ' ')"
  done < factory/progress.md
} > "$R/scope.txt" 2>&1

# --- 5. the judge: artifact-only ------------------------------------------
PROMPT="$(
  cat skills/inspector/SKILL.md
  printf '\n\n===== CONTRACT (immutable) =====\n'; cat factory/CONTRACT.md
  printf '\n\n===== DIFF %s..%s =====\n' "$BASE" "$SHA"; git diff "$BASE".."$SHA" | head -c 90000
  printf '\n\n===== VISIBLE SUITE, RUN 1 (exit %s) =====\n' "$V1"; tail -c 4000 "$R/vis1.log"
  printf '\n\n===== VISIBLE SUITE, RUN 2 (exit %s) =====\n' "$V2"; tail -c 4000 "$R/vis2.log"
  printf '\nFLAKY: %s\n' "$FLAKY"
  printf '\n\n===== HELD-OUT SUITE (exit %s) — the builder never saw these =====\n' "$H"; tail -c 6000 "$R/held.log"
  printf '\n\n===== TAMPER AUDIT =====\n'; cat "$R/tamper.txt"
  printf '\n\n===== SCOPE LEDGER =====\n'; cat "$R/scope.txt"
  printf '\n\n===== NIGHT DIARY =====\n'; cat factory/progress.md
  printf '\nWrite factory/REVIEW.md now. Its FIRST LINE must be exactly:\n'
  printf 'Verdict on %s: SHIP\n' "$SHA"
  printf 'or FIX FIRST, or NOT DONE, in that same form.\n'
  printf 'Then: findings, flaky tests, parked tasks, and what a human must decide.\n'
  printf 'You did not receive any worker transcript. Judge the artifacts.\n'
  printf 'End with the FACTORY_STATUS block.\n'
)"

echo "[inspect] invoking $JUDGE_ROLE ($(role_family "$JUDGE_ROLE"), artifact-only)" >&2
run_role "$JUDGE_ROLE" "$PROMPT" > "$R/verdict.out" 2>>factory/log.md

VERDICT="$(grep -m1 -oE "Verdict on [0-9a-f]+: *(SHIP|FIX FIRST|NOT DONE)" factory/REVIEW.md "$R/verdict.out" 2>/dev/null | head -1 | sed 's/^[^:]*://')"
[ -s factory/REVIEW.md ] || cp "$R/verdict.out" factory/REVIEW.md

mkdir -p factory/.planning/gate-results
jq -n --arg sha "$SHA" --arg v "${VERDICT:-UNPARSEABLE}" --arg f "$FLAKY" \
      --argjson v1 "$V1" --argjson v2 "$V2" --argjson h "$H" \
      --arg jf "$(role_family "$JUDGE_ROLE")" --arg ef "$AUTHOR_FAMS" \
      --arg jr "$JUDGE_ROLE" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{gate:"inspection",sha:$sha,verdict:$v,visible_run1:$v1,visible_run2:$v2,
    heldout:$h,flaky:$f,judge_role:$jr,judge_family:$jf,author_families:$ef,ts:$ts,
    pass:(($v|test("SHIP")) and $v1==0 and $v2==0 and $h==0)}' \
  > "factory/.planning/gate-results/inspection-$SHA.json"

echo "[inspect] visible: $V1/$V2  held-out: $H  flaky: $FLAKY" >&2
echo "[inspect] verdict: ${VERDICT:-<unparseable>}" >&2
log_append "inspector" "verdict" "${VERDICT:-unparseable} (visible $V1/$V2, heldout $H)"
state_set "INSPECTED" "verdict ${VERDICT:-unparseable}; see factory/REVIEW.md"
cp "$R/vis1.log" "$R/vis2.log" "$R/held.log" "$R/tamper.txt" "$R/scope.txt" factory/.planning/ 2>/dev/null
rm -rf "$R"

status_emit "inspector" "-" "DONE" "verdict ${VERDICT:-unparseable} on $SHA"
