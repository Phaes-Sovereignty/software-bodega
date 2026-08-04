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

# hard rule 2: the judge must not share a family with the author of the work
assert_cross_family judge executor || {
  echo "[inspect] REFUSING: judge shares a model family with the executor" >&2
  status_emit "inspector" "-" "BLOCKED" "judge/executor family collision"; exit 1
}

SHA="$(git rev-parse HEAD)"
R="$(mktemp -d)"
# The night shift's first commit is the natural base if none is given.
[ -n "$BASE" ] || BASE="$(awk -F'|' '/\|DONE\|/{print $3; exit}' factory/progress.md 2>/dev/null)"
[ -n "$BASE" ] && BASE="$(git rev-parse "$BASE"^ 2>/dev/null || git rev-parse "$BASE")"
[ -n "$BASE" ] || BASE="$(git rev-list --max-parents=0 HEAD | head -1)"

echo "[inspect] head=$SHA base=$BASE" >&2
log_append "inspector" "start" "head=$SHA"

# --- 1. visible suite, TWICE ----------------------------------------------
echo "[inspect] running visible suite (run 1 of 2)" >&2
bash factory/tests/run-visible.sh > "$R/vis1.log" 2>&1; V1=$?
echo "[inspect] running visible suite (run 2 of 2)" >&2
bash factory/tests/run-visible.sh > "$R/vis2.log" 2>&1; V2=$?
FLAKY="no"
if [ "$V1" != "$V2" ]; then
  FLAKY="YES — run1 exit $V1, run2 exit $V2"
  echo "[inspect] FLAKY: visible suite disagreed with itself" >&2
fi

# --- 2. held-out suite — the checks the builder never saw ------------------
echo "[inspect] running held-out suite" >&2
if [ -f factory/tests/run-heldout.sh ]; then
  bash factory/tests/run-heldout.sh > "$R/held.log" 2>&1; H=$?
else
  echo "no held-out runner present" > "$R/held.log"; H=127
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
  git diff --name-only "$BASE".."$SHA" -- factory/tests/ | sed 's/^/  /' || true
  git diff --quiet "$BASE".."$SHA" -- factory/tests/ 2>/dev/null && echo "  NONE — exam suites untouched."
  echo
  echo "### Weakening markers introduced in the diff"
  git diff "$BASE".."$SHA" -- factory/tests/ | grep -E '^\+' \
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

echo "[inspect] invoking judge ($(role_family judge), artifact-only)" >&2
run_role judge "$PROMPT" > "$R/verdict.out" 2>>factory/log.md

VERDICT="$(grep -m1 -oE "Verdict on [0-9a-f]+: *(SHIP|FIX FIRST|NOT DONE)" factory/REVIEW.md "$R/verdict.out" 2>/dev/null | head -1 | sed 's/^[^:]*://')"
[ -s factory/REVIEW.md ] || cp "$R/verdict.out" factory/REVIEW.md

mkdir -p factory/.planning/gate-results
jq -n --arg sha "$SHA" --arg v "${VERDICT:-UNPARSEABLE}" --arg f "$FLAKY" \
      --argjson v1 "$V1" --argjson v2 "$V2" --argjson h "$H" \
      --arg jf "$(role_family judge)" --arg ef "$(role_family executor)" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{gate:"inspection",sha:$sha,verdict:$v,visible_run1:$v1,visible_run2:$v2,
    heldout:$h,flaky:$f,judge_family:$jf,executor_family:$ef,ts:$ts,
    pass:(($v|test("SHIP")) and $v1==0 and $v2==0 and $h==0)}' \
  > "factory/.planning/gate-results/inspection-$SHA.json"

echo "[inspect] visible: $V1/$V2  held-out: $H  flaky: $FLAKY" >&2
echo "[inspect] verdict: ${VERDICT:-<unparseable>}" >&2
log_append "inspector" "verdict" "${VERDICT:-unparseable} (visible $V1/$V2, heldout $H)"
state_set "INSPECTED" "verdict ${VERDICT:-unparseable}; see factory/REVIEW.md"
cp "$R/vis1.log" "$R/vis2.log" "$R/held.log" "$R/tamper.txt" "$R/scope.txt" factory/.planning/ 2>/dev/null
rm -rf "$R"

status_emit "inspector" "-" "DONE" "verdict ${VERDICT:-unparseable} on $SHA"
