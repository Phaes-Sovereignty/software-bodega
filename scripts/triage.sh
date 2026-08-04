#!/usr/bin/env bash
# triage.sh — classify new unlabeled issues as OBVIOUS (ready) or AMBIGUOUS.
#
# 30 seconds per item. OBVIOUS issues get labelled `ready` and the runner starts
# on them with no human wait. AMBIGUOUS issues get 1-3 questions posted and wait.
#
# Usage: bash scripts/triage.sh [--issue N] [--dry-run]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

DRY_RUN=0
ONE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --issue)   ONE="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$ONE" ]; then
  ISSUES="$ONE"
else
  # untriaged = open, and carries neither `ready` nor `needs-info`
  ISSUES="$(gh issue list --state open --json number,labels \
    --jq '.[] | select([.labels[].name] | (index("ready") or index("needs-info")) | not) | .number' 2>/dev/null)"
fi

if [ -z "$ISSUES" ]; then
  echo "[triage] nothing to triage" >&2
  status_emit "triage" "-" "DONE" "no untriaged issues"
  exit 0
fi

COUNT=0
for n in $ISSUES; do
  TITLE="$(gh issue view "$n" --json title --jq .title 2>/dev/null)"
  BODY="$(gh issue view "$n" --json body --jq .body 2>/dev/null)"
  echo "[triage] #$n: $TITLE" >&2

  PROMPT="$(
    cat skills/triage/SKILL.md
    printf '\n\n===== ISSUE #%s =====\nTitle: %s\n\n%s\n' "$n" "$TITLE" "$BODY"
    printf '\n===== PROJECT NON-GOALS (touching one of these is AMBIGUOUS) =====\n'
    jq -r '.non_goals[]? | "\(.id): \(.text)"' factory/.planning/spec.json 2>/dev/null
    printf '\nClassify this issue now. End with the FACTORY_STATUS block.\n'
  )"

  OUT="$(mktemp)"
  if [ "$DRY_RUN" = "1" ]; then
    { printf 'CLASSIFICATION: AMBIGUOUS\nLABEL: needs-info\n'
      status_emit "triage" "$n" "DONE" "dry-run: not classified"; } > "$OUT"
  else
    run_role triage "$PROMPT" > "$OUT" 2>>factory/log.md
  fi

  CLASS="$(grep -m1 '^CLASSIFICATION:' "$OUT" | sed 's/^CLASSIFICATION: *//' | tr -d '\r')"
  case "$CLASS" in
    OBVIOUS)
      echo "[triage] #$n -> OBVIOUS (ready)" >&2
      [ "$DRY_RUN" = "1" ] || {
        gh issue edit "$n" --add-label ready 2>/dev/null
        gh issue comment "$n" --body "Triage: **OBVIOUS** — labelled \`ready\`, work starts on the next runner pass.

$(sed -n '/^CHECKS:/,/^BOUNDARY:/p' "$OUT")" 2>/dev/null
      }
      log_append "triage" "obvious" "#$n"
      ;;
    AMBIGUOUS)
      echo "[triage] #$n -> AMBIGUOUS (needs-info)" >&2
      [ "$DRY_RUN" = "1" ] || {
        gh issue edit "$n" --add-label needs-info 2>/dev/null
        gh issue comment "$n" --body "Triage: **AMBIGUOUS** — a few questions before this can start.

$(sed -n '/^QUESTIONS:/,$p' "$OUT" | head -20)" 2>/dev/null
      }
      log_append "triage" "ambiguous" "#$n"
      ;;
    *)
      # Unparseable classification defaults to the safe bucket, per the skill's
      # tie-breaker: a wrong AMBIGUOUS costs 30 seconds, a wrong OBVIOUS costs a night.
      echo "[triage] #$n -> unparseable, defaulting to AMBIGUOUS" >&2
      [ "$DRY_RUN" = "1" ] || gh issue edit "$n" --add-label needs-info 2>/dev/null
      log_append "triage" "unparseable" "#$n defaulted to needs-info"
      ;;
  esac
  rm -f "$OUT"
  COUNT=$((COUNT + 1))
done

status_emit "triage" "-" "DONE" "triaged $COUNT issue(s)"
