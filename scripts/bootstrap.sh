#!/usr/bin/env bash
# bootstrap.sh — drive the bootstrap pipeline's non-interactive stations.
#
#   SPEC -> BLUEPRINT -> EXAM BOARD -> WORK ORDER (+ cross-family plan review)
#
# Each station is a FRESH headless session (hard rule 1: one agent per station,
# one task per context window). Gates run between stations and stop the line on
# failure — a station never inherits a broken artifact.
#
# The INTERVIEW is normally interactive; --answers replays scripted answers so
# the whole pipeline can be exercised unattended (used by the dry run).
#
# Usage:
#   bash scripts/bootstrap.sh --idea "<one line>" --answers <file>   # from scratch
#   bash scripts/bootstrap.sh --from spec                            # resume at a station

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

IDEA=""; ANSWERS=""; FROM="interview"
while [ $# -gt 0 ]; do
  case "$1" in
    --idea)    IDEA="$2"; shift ;;
    --answers) ANSWERS="$2"; shift ;;
    --from)    FROM="$2"; shift ;;
    --help|-h) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

RUN="$FACTORY_ROOT/factory/.planning/station-logs"
mkdir -p "$RUN"

# Single-writer lock. Two bootstraps racing on the same factory/ silently
# interleave station writes and corrupt artifacts — observed during the Phase B
# dry run when a long station outlived its caller. mkdir is atomic.
LOCK="$FACTORY_ROOT/factory/.planning/.bootstrap.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "[bootstrap] another bootstrap holds the lock: $LOCK" >&2
  echo "[bootstrap] pid $(cat "$LOCK/pid" 2>/dev/null || echo '?'). If it is dead, rm -rf the lock dir." >&2
  exit 1
fi
echo "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

die() {
  echo "[bootstrap] GATE FAILED: $*" >&2
  log_append "bootstrap" "gate_failed" "$*"
  state_set "BLOCKED" "gate failed: $*"
  status_emit "bootstrap" "-" "BLOCKED" "$*"
  exit 1
}

run_station() { # run_station <name> <role> <prompt>
  local name="$1" role="$2" prompt="$3" out="$RUN/$1.out"
  echo "[bootstrap] === $name ($role) ===" >&2
  state_set "$(printf '%s' "$name" | tr 'a-z-' 'A-Z_')" "station running"
  log_append "$name" "start" "role=$role"
  run_role "$role" "$prompt" > "$out" 2>>factory/log.md
  if ! status_valid "$out" 2>/dev/null; then
    echo "[bootstrap] warning: $name emitted no valid status block" >&2
    log_append "$name" "no_status_block" "-"
  else
    log_append "$name" "$(status_field "$out" STATUS)" "$(status_field "$out" SUMMARY)"
  fi
}

ORDER="interview spec blueprint exam workorder planreview"
started=0

for STAGE in $ORDER; do
  [ "$STAGE" = "$FROM" ] && started=1
  [ "$started" = "1" ] || continue

  case "$STAGE" in

  interview)
    [ -n "$ANSWERS" ] || { echo "[bootstrap] interview is interactive; use skills/factory-interview, or pass --answers" >&2; continue; }
    run_station "interview" planner "$(
      cat skills/factory-interview/SKILL.md
      printf '\n\n===== MODE: SCRIPTED =====\n'
      printf 'You are NOT talking to a human. The idea and the answers the human\n'
      printf 'would have given are below. Do not ask questions. Synthesize the\n'
      printf 'brief directly from them.\n\n'
      printf 'IDEA: %s\n\nANSWERS:\n' "$IDEA"
      cat "$ANSWERS"
      printf '\nWrite factory/BRIEF.md now, in the exact structure the skill specifies\n'
      printf '(## Decisions made with D-N ids, ## Non-goals with NG-N ids, ## Riskiest part).\n'
      printf 'Then end with the FACTORY_STATUS block.\n'
    )"
    [ -s factory/BRIEF.md ] || die "interview produced no BRIEF.md"
    grep -q "^## Non-goals" factory/BRIEF.md || die "BRIEF.md has no ## Non-goals section"
    grep -qE "^- ?NG-[0-9]" factory/BRIEF.md || die "BRIEF.md declares no NG-N non-goals"
    grep -q "^## Riskiest part" factory/BRIEF.md || die "BRIEF.md names no riskiest part"
    echo "[bootstrap] ✓ brief gate" >&2
    ;;

  spec)
    run_station "spec" planner "$(
      cat skills/spec-freeze/SKILL.md
      printf '\n\n===== INPUT: factory/BRIEF.md =====\n'; cat factory/BRIEF.md
      printf '\nWrite factory/.planning/spec.json now. Every criterion needs a check\n'
      printf 'kind of test|type|cli. non_goals must be non-empty. Then report each\n'
      printf 'spec_gate checklist line as pass/fail, and end with the status block.\n'
    )"
    python3 scripts/lib/schemas.py spec factory/.planning/spec.json || die "spec.json failed schema validation"
    [ "$(jq '.non_goals | length' factory/.planning/spec.json)" -gt 0 ] || die "spec_gate: non_goals is empty"
    [ "$(jq '.criteria | length' factory/.planning/spec.json)" -gt 0 ] || die "spec_gate: no criteria"
    echo "[bootstrap] ✓ spec_gate ($(jq '.criteria|length' factory/.planning/spec.json) criteria, $(jq '.non_goals|length' factory/.planning/spec.json) non-goals)" >&2
    ;;

  blueprint)
    run_station "blueprint" planner "$(
      cat skills/blueprint/SKILL.md
      printf '\n\n===== INPUT: factory/.planning/spec.json =====\n'; cat factory/.planning/spec.json
      printf '\n\n===== INPUT: factory/BRIEF.md =====\n'; cat factory/BRIEF.md
      printf '\nWrite factory/.planning/decompose.json AND one factory/tasks/<id>.md per\n'
      printf 'NON-BACKLOG task. Each task file uses these exact field lines:\n'
      printf '  Id: T01\n  Goal: <one sentence>\n  Boundary: <comma-separated paths>\n'
      printf '  Depends: <comma-separated ids or ->\n  Exam_refs: <comma-separated AC ids>\n  Risk: low|high\n'
      printf 'followed by any prose. T01 must be a walking skeleton. Also write\n'
      printf 'factory/BLUEPRINT.md summarizing the DAG. Then the status block.\n'
    )"
    python3 scripts/lib/schemas.py decompose factory/.planning/decompose.json || die "decompose.json failed schema validation"
    python3 - <<'PY' || die "decompose_gate failed"
import json, sys, itertools
d = json.load(open("factory/.planning/decompose.json"))
s = json.load(open("factory/.planning/spec.json"))
tasks = d["tasks"]; ids = {t["id"] for t in tasks}
errs = []
# acyclic
adj = {t["id"]: list(t.get("depends", [])) for t in tasks}
state = {}
def visit(n, stack):
    if state.get(n) == 2: return
    if state.get(n) == 1:
        errs.append(f"cycle: {' -> '.join(stack + [n])}"); return
    state[n] = 1
    for m in adj.get(n, []):
        if m in adj: visit(m, stack + [n])
    state[n] = 2
for t in tasks: visit(t["id"], [])
# AC coverage BOTH directions
acs = {c["id"] for c in s["criteria"]}
covered = set(itertools.chain.from_iterable(t.get("exam_refs", []) for t in tasks))
if acs - covered: errs.append(f"AC not covered by any task: {sorted(acs - covered)}")
if covered - acs: errs.append(f"exam_refs name unknown ACs: {sorted(covered - acs)}")
# context cap
cap = 100000
for t in tasks:
    if t.get("context_estimate", 0) >= cap:
        errs.append(f"{t['id']}: context_estimate {t['context_estimate']} >= cap {cap}")
# ADR for risk:high
import os
for t in tasks:
    if t.get("risk") == "high":
        adr = t.get("adr")
        if not adr: errs.append(f"{t['id']}: risk=high but no adr")
        elif not os.path.exists(f"factory/adr/{adr}.md"): errs.append(f"{t['id']}: adr {adr} file missing")
if errs:
    for e in errs: print(f"  ✗ {e}", file=sys.stderr)
    sys.exit(1)
print(f"  decompose_gate: {len(tasks)} tasks, DAG acyclic, {len(acs)} ACs covered both directions", file=sys.stderr)
PY
    NT=$(ls -1 factory/tasks/*.md 2>/dev/null | wc -l | tr -d ' ')
    [ "$NT" -ge 1 ] || die "blueprint wrote no factory/tasks/*.md files"
    echo "[bootstrap] ✓ decompose_gate ($NT task files)" >&2
    ;;

  exam)
    # FRESH, SPEC-BLIND session: gets spec.json ONLY. No blueprint, no tasks,
    # no code. That isolation is what makes the held-out half meaningful.
    run_station "exam" planner "$(
      cat skills/exam-board/SKILL.md
      printf '\n\n===== INPUT: factory/.planning/spec.json (your ONLY input) =====\n'
      cat factory/.planning/spec.json
      printf '\nWrite:\n'
      printf '  factory/CONTRACT.md\n'
      printf '  factory/tests/visible/   (>=3 checks the builder may see)\n'
      printf '  factory/tests/heldout/   (>=2 checks the builder must NEVER see)\n'
      printf '  factory/tests/run-visible.sh  — runs ONLY tests/visible, exits 0/non-0\n'
      printf '  factory/tests/run-heldout.sh  — runs ONLY tests/heldout, exits 0/non-0\n'
      printf 'Both runners must work from the repo root and must not depend on any\n'
      printf 'package being installed beyond the python3 standard library.\n'
      printf 'Tests must FAIL now (no implementation exists yet) and pass once the\n'
      printf 'described behavior exists. Then end with the status block.\n'
    )"
    [ -s factory/CONTRACT.md ] || die "exam board produced no CONTRACT.md"
    NV=$(find factory/tests/visible -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
    NH=$(find factory/tests/heldout -type f ! -name '.gitkeep' 2>/dev/null | wc -l | tr -d ' ')
    [ -x factory/tests/run-visible.sh ] || chmod +x factory/tests/run-visible.sh 2>/dev/null
    [ -x factory/tests/run-heldout.sh ] || chmod +x factory/tests/run-heldout.sh 2>/dev/null
    [ -f factory/tests/run-visible.sh ] || die "exam board wrote no run-visible.sh"
    [ -f factory/tests/run-heldout.sh ] || die "exam board wrote no run-heldout.sh"
    [ "$NV" -ge 3 ] || die "exam_gate: only $NV visible check files (need >=3)"
    [ "$NH" -ge 2 ] || die "exam_gate: only $NH held-out check files (need >=2)"
    # Tests must fail before the implementation exists. A suite that is green on
    # an empty repo is testing nothing.
    if bash factory/tests/run-visible.sh >/dev/null 2>&1; then
      die "exam_gate: visible suite passes against an empty repo — it tests nothing"
    fi
    echo "[bootstrap] ✓ exam_gate ($NV visible files, $NH held-out files, suite red on empty repo)" >&2
    ;;

  workorder)
    run_station "workorder" planner "$(
      cat skills/work-order/SKILL.md
      printf '\n\n===== INPUT: decompose.json =====\n'; cat factory/.planning/decompose.json
      printf '\n\n===== INPUT: CONTRACT.md =====\n'; cat factory/CONTRACT.md
      printf '\nWrite factory/.planning/plan.json (one slice per non-backlog task) and\n'
      printf 'factory/HANDOFF.md with the Orientation Q&A. The verify command is:\n'
      printf '  bash factory/tests/run-visible.sh\n'
      printf 'Be honest with qualifier: mark weak where you are guessing.\n'
      printf 'Then end with the status block.\n'
    )"
    python3 scripts/lib/schemas.py plan factory/.planning/plan.json || die "plan.json failed schema validation"
    [ -s factory/HANDOFF.md ] || die "work order produced no HANDOFF.md"
    echo "[bootstrap] ✓ plan_gate ($(jq '.slices|length' factory/.planning/plan.json) slices)" >&2
    ;;

  planreview)
    # Resume point: plan.json already exists and passed plan_gate. Re-authoring a
    # plan just to re-review it costs ~30 minutes for nothing.
    python3 scripts/lib/schemas.py plan factory/.planning/plan.json || die "plan.json failed schema validation"
    # ◈ cross-family plan review — mandatory independence check.
    # A REJECT is repairable: the planner gets the review back and revises, up to
    # PLAN_REVISE_CAP rounds (hard rule 4), then it escalates to the human. Each
    # round is a fresh verdict bound to the NEW plan SHA; old verdicts are stale
    # by construction because the SHA moved.
    assert_cross_family plan_judge planner || die "plan reviewer shares a family with the plan author"
    PLAN_REVISE_CAP="${PLAN_REVISE_CAP:-2}"
    round=0
    mkdir -p factory/.planning/gate-results
    while :; do
      PLAN_SHA="$(git hash-object factory/.planning/plan.json)"
      echo "[bootstrap] === plan_review round $round (plan_judge, artifact-only) ===" >&2
      REVIEW_OUT="$RUN/plan_review-r$round.out"
      run_role plan_judge "$(
        printf 'You are reviewing a work-order plan. Artifact-only: you get the plan\n'
        printf 'and the contract, no transcript and no implementation notes.\n\n'
        printf 'Check each slice: does the warrant actually support the claim? Is any\n'
        printf 'slice marked strong that should be weak? Is any rebuttal missing a real\n'
        printf 'failure mode? Is the file manifest inside the task boundary?\n\n'
        printf 'Your FIRST LINE must be exactly:\n'
        printf 'Verdict on plan@%s: APPROVE | APPROVE WITH NOTES | REJECT\n\n' "$PLAN_SHA"
        printf 'Then per-slice notes, briefly.\n\n'
        printf '===== PLAN =====\n'; cat factory/.planning/plan.json
        printf '\n===== CONTRACT =====\n'; cat factory/CONTRACT.md
      )" > "$REVIEW_OUT" 2>>factory/log.md
      VERDICT="$(grep -m1 -oE 'Verdict on plan@[0-9a-f]+: *(APPROVE WITH NOTES|APPROVE|REJECT)' "$REVIEW_OUT" | head -1)"
      jq -n --arg v "${VERDICT:-UNPARSEABLE}" --arg sha "$PLAN_SHA" --arg r "$round" \
            --arg judge "$(role_family plan_judge)" --arg author "$(role_family planner)" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{gate:"plan_review",sha:$sha,round:($r|tonumber),verdict:$v,judge_family:$judge,
          author_family:$author,ts:$ts,pass:($v|test("APPROVE"))}' \
        > "factory/.planning/gate-results/plan_review-$PLAN_SHA.json"
      echo "[bootstrap] plan_review: ${VERDICT:-<unparseable>}" >&2
      log_append "plan_review" "round$round" "${VERDICT:-unparseable}"

      case "$VERDICT" in
        *APPROVE*) break ;;
      esac
      if [ "$round" -ge "$PLAN_REVISE_CAP" ]; then
        die "plan_review did not approve after $PLAN_REVISE_CAP revision round(s) — needs a human"
      fi
      round=$((round + 1))
      echo "[bootstrap] === plan revision round $round (planner) ===" >&2
      run_station "workorder-revise-$round" planner "$(
        printf 'Your work-order plan was REJECTED by an independent reviewer from a\n'
        printf 'different model family. Revise factory/.planning/plan.json to address\n'
        printf 'every point below.\n\n'
        printf 'Rules for the revision:\n'
        printf '  - Fix the substance. Do NOT just downgrade qualifiers to weak to make\n'
        printf '    objections go away — a claim the warrant cannot support must change.\n'
        printf '  - If a manifest falls outside its task boundary, either move the file\n'
        printf '    into the right slice or fix the boundary in factory/tasks/<id>.md\n'
        printf '    and say so.\n'
        printf '  - Keep the schema identical. Update factory/HANDOFF.md if a slice changed.\n\n'
        printf '===== REVIEWER VERDICT =====\n'; cat "$REVIEW_OUT"
        printf '\n===== CURRENT PLAN =====\n'; cat factory/.planning/plan.json
        printf '\n===== CONTRACT =====\n'; cat factory/CONTRACT.md
        printf '\nRewrite factory/.planning/plan.json now, then end with the status block.\n'
      )"
      python3 scripts/lib/schemas.py plan factory/.planning/plan.json \
        || die "revised plan.json failed schema validation"
    done
    ;;
  esac
done

state_set "READY_FOR_NIGHT_SHIFT" "bootstrap complete; run scripts/nightshift.sh"
status_emit "bootstrap" "-" "DONE" "bootstrap pipeline complete through work order"
