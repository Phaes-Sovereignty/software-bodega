#!/usr/bin/env bash
# runner.sh — the Small Loop. One issue at a time. Never merges.
#
# Pick the oldest `ready` issue -> isolated worktree (held-out tests physically
# excluded via sparse checkout) -> executor implements -> visible checks ->
# push branch -> gh pr create with a scope ledger. Then it stops. A human merges.
#
# This is scripts + CI forever, by design. Do NOT build an FSM for it.
#
# Usage: bash scripts/runner.sh [--issue N] [--dry-run]

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

DRY_RUN=0
ISSUE=""
VISIBLE_CMD="${VISIBLE_CMD:-bash factory/tests/run-visible.sh}"

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)   ISSUE="$2"; shift ;;
    --dry-run) DRY_RUN=1 ;;
    --help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- pick the oldest ready issue ------------------------------------------
if [ -z "$ISSUE" ]; then
  ISSUE="$(gh issue list --label ready --state open --json number,createdAt \
    --jq 'sort_by(.createdAt) | .[0].number' 2>/dev/null)"
fi
if [ -z "$ISSUE" ] || [ "$ISSUE" = "null" ]; then
  echo "[runner] no ready issues" >&2
  status_emit "runner" "-" "DONE" "no ready issues to work"
  exit 0
fi

TITLE="$(gh issue view "$ISSUE" --json title --jq .title 2>/dev/null)"
BODY="$(gh issue view "$ISSUE" --json body --jq .body 2>/dev/null)"
echo "[runner] issue #$ISSUE: $TITLE" >&2
log_append "runner" "start" "issue #$ISSUE"

BRANCH="issue-$ISSUE"
WT="$(mktemp -d)/wt-$ISSUE"
BASE_SHA="$(git rev-parse HEAD)"

cleanup() { git worktree remove --force "$WT" 2>/dev/null; }
trap cleanup EXIT

# --- isolated worktree with held-out tests PHYSICALLY absent ---------------
# Not a prompt promise — the files are not on disk in the worker's checkout.
git worktree add -q --no-checkout -b "$BRANCH" "$WT" "$BASE_SHA" 2>/dev/null || {
  git worktree add -q --no-checkout --detach "$WT" "$BASE_SHA" || { echo "[runner] worktree failed" >&2; exit 1; }
}
(
  cd "$WT" || exit 1
  git sparse-checkout init --no-cone -q 2>/dev/null
  git sparse-checkout set '/*' '!/factory/tests/heldout/' '!/factory/tests/heldout/*' -q 2>/dev/null
  git checkout -q 2>/dev/null
  rm -rf factory/tests/heldout 2>/dev/null   # belt and braces
)

if [ -d "$WT/factory/tests/heldout" ]; then
  echo "[runner] FATAL: held-out seal broken — heldout/ present in worker tree" >&2
  log_append "runner" "seal_broken" "issue #$ISSUE"
  status_emit "runner" "$ISSUE" "BLOCKED" "held-out seal broken; refusing to run worker"
  exit 1
fi
echo "[runner] seal verified: factory/tests/heldout absent from worker tree" >&2

# --- worker ---------------------------------------------------------------
PROMPT="$(
  cat skills/night-task/SKILL.md
  printf '\n\n===== ISSUE #%s: %s =====\n%s\n' "$ISSUE" "$TITLE" "$BODY"
  printf '\n===== HOW TO VERIFY =====\nRun: %s\n' "$VISIBLE_CMD"
  printf '\nWork in %s. Edit files directly. Do not commit, do not push.\n' "$WT"
  printf 'End your response with the FACTORY_STATUS block.\n'
)"

SF="$WT/.status"
if [ "$DRY_RUN" = "1" ]; then
  status_emit "runner" "$ISSUE" "DONE" "dry-run: no executor invoked" "FILES: -" > "$SF"
else
  ( cd "$WT" && FACTORY_ROOT="$WT" run_role executor "$PROMPT" ) > "$SF" 2>>factory/log.md
fi

if ! status_valid "$SF" 2>/dev/null; then
  echo "[runner] worker returned no valid status block" >&2
  log_append "runner" "bad_status" "issue #$ISSUE"
  status_emit "runner" "$ISSUE" "BLOCKED" "worker returned no parseable status block"
  exit 1
fi
WSTATUS="$(status_field "$SF" STATUS)"
if [ "$WSTATUS" != "DONE" ]; then
  echo "[runner] worker $WSTATUS: $(status_field "$SF" SUMMARY)" >&2
  gh issue comment "$ISSUE" --body "Runner stopped: **$WSTATUS** — $(status_field "$SF" SUMMARY)" 2>/dev/null
  status_emit "runner" "$ISSUE" "BLOCKED" "worker reported $WSTATUS"
  exit 1
fi

# --- verify ---------------------------------------------------------------
TO="$WT/.test"
( cd "$WT" && eval "$VISIBLE_CMD" ) > "$TO" 2>&1; TRC=$?
if [ "$TRC" -ne 0 ] && [ "$DRY_RUN" != "1" ]; then
  echo "[runner] visible checks failed — no PR opened" >&2
  gh issue comment "$ISSUE" --body "Runner: visible checks failed, no PR opened.

\`\`\`
$(tail -c 2000 "$TO")
\`\`\`" 2>/dev/null
  log_append "runner" "verify_fail" "issue #$ISSUE"
  status_emit "runner" "$ISSUE" "BLOCKED" "visible checks failed; no PR opened"
  exit 1
fi

# --- commit (selective) + push + PR ---------------------------------------
FILES="$(status_field "$SF" FILES)"
(
  cd "$WT" || exit 1
  if [ -n "$FILES" ] && [ "$FILES" != "-" ]; then
    for f in $(printf '%s' "$FILES" | tr ',' ' '); do [ -e "$f" ] && git add -- "$f"; done
  else
    git add -u   # tracked modifications only; never -A
  fi
  git diff --cached --quiet && { echo "[runner] empty diff" >&2; exit 3; }
  git commit -q -m "fix #$ISSUE: $TITLE"
) || { status_emit "runner" "$ISSUE" "BLOCKED" "nothing to commit"; exit 1; }

CHANGED="$(cd "$WT" && git diff --name-only "$BASE_SHA"..HEAD | sed 's/^/- /')"
SHA="$(cd "$WT" && git rev-parse HEAD)"

if [ "$DRY_RUN" = "1" ]; then
  echo "[runner] dry-run: would push $BRANCH and open a PR" >&2
else
  ( cd "$WT" && git push -q -u origin "$BRANCH" ) || echo "[runner] push failed" >&2
  gh pr create --head "$BRANCH" --title "fix #$ISSUE: $TITLE" --body "$(cat <<PRBODY
Closes #$ISSUE

## Scope ledger
Files changed:
$CHANGED

Evidence per check:
\`\`\`
$(tail -c 2000 "$TO")
\`\`\`

Other behavior changes: None

## Seal
Held-out tests were absent from the worker checkout (sparse checkout excluded
\`factory/tests/heldout/\`). CI fetches them independently.
PRBODY
)" 2>/dev/null || echo "[runner] gh pr create failed" >&2
fi

log_append "runner" "pr_opened" "issue #$ISSUE sha=$SHA"
status_emit "runner" "$ISSUE" "DONE" "PR opened for issue #$ISSUE at $SHA" "FILES: $FILES"
