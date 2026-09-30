#!/usr/bin/env bash
# fix-round.sh — work the inspector's FIX FIRST list, then re-inspect.
#
# The worker is given the CONTRACT and the inspector's findings — NOT the
# held-out tests. A finding says "AC-12 is violated"; it never says "here is the
# check that caught you". The builder fixes the behaviour the contract requires,
# or it does not get to pass.
#
# Two strikes and it parks (hard rule 4). Usage:
#   bash scripts/fix-round.sh [--max-rounds N]

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/status.sh
. "$HERE/lib/status.sh"
cd "$FACTORY_ROOT" || exit 1

# The receipt parser is shared with the night loop (scripts/lib/verify.sh) rather
# than re-typed here. This script counted failures with a python-unittest-only
# grep, which finds no `failures=N` marker in a Swift receipt and so reports ZERO
# failures for any output. The regression test below compares 0 against 0 and
# passes: a fix round that broke the suite, or failed to compile it at all, was
# credited with a clean result and committed. A gate that cannot see the failure
# it exists to catch is worse than no gate, because it looks like one.
. "$HERE/lib/verify.sh"

MAX_ROUNDS=2
while [ $# -gt 0 ]; do
  case "$1" in
    --max-rounds) MAX_ROUNDS="$2"; shift ;;
    --help|-h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -s factory/REVIEW.md ] || { echo "[fix] no REVIEW.md — run scripts/inspect.sh first" >&2; exit 1; }

VERDICT="$(head -1 factory/REVIEW.md)"
case "$VERDICT" in
  *SHIP*) echo "[fix] already SHIP — nothing to do: $VERDICT" >&2
          status_emit "fix-round" "-" "DONE" "already SHIP"; exit 0 ;;
esac

round=0
while [ "$round" -lt "$MAX_ROUNDS" ]; do
  round=$((round + 1))
  echo "[fix] === round $round/$MAX_ROUNDS ===" >&2
  state_set "FIX_ROUND_$round" "working the inspector's list"
  log_append "fix-round" "start" "round $round"

  BEFORE="$(git rev-parse HEAD)"
  TO="$(mktemp)"; SF="$(mktemp)"
  run_visible_suite "$TO"; LAST_TEST_RC=$?
  BASE_FAILS="$(fail_count "$TO")"

  run_role executor "$(
    cat skills/night-task/SKILL.md
    printf '\n\n===== THIS IS A FIX ROUND =====\n'
    printf 'A reviewer ran checks you have never seen against the contract and found\n'
    printf 'defects. Fix the behaviour the CONTRACT requires. You are NOT being shown\n'
    printf 'the failing checks themselves, and you must not go looking for them.\n\n'
    printf 'Do not weaken, skip or delete any test. Do not edit factory/CONTRACT.md.\n'
    printf 'Do not touch anything under factory/tests/.\n'
    printf 'Make the smallest change that makes the required behaviour true.\n'
    printf '\n===== INSPECTOR FINDINGS =====\n'
    sed -n '1,120p' factory/REVIEW.md
    printf '\n===== CONTRACT =====\n'; cat factory/CONTRACT.md
    printf '\n===== HOW TO VERIFY YOUR OWN WORK =====\nRun: %s\n' "$VISIBLE_CMD"
    printf 'It must not regress: %s check(s) fail right now.\n' "${BASE_FAILS:-0}"
    printf '\nWork in %s. Edit source files directly. Do not commit.\n' "$FACTORY_ROOT"
    printf 'End with the FACTORY_STATUS block, STATION: fix-round.\n'
  )" > "$SF" 2>>factory/log.md

  if ! status_valid "$SF" 2>/dev/null; then
    echo "[fix] round $round: no valid status block" >&2
    log_append "fix-round" "bad_status" "round $round"; rm -f "$SF" "$TO"; continue
  fi

  # verification: no regression on the visible suite.
  # fail_count from the shared parser. The old inline grep returned 0 for a Swift
  # receipt, so a round that REGRESSED compared 0 > 0, saw no regression, and
  # committed the damage. Both numbers must come from the same function the night
  # loop uses or the two gates disagree about what "worse" means.
  run_visible_suite "$TO"; RC=$?
  LAST_TEST_RC=$RC
  AFTER_FAILS="$(fail_count "$TO")"
  if [ "$RC" != "0" ] && [ "${AFTER_FAILS:-1}" -gt "${BASE_FAILS:-0}" ]; then
    echo "[fix] round $round REGRESSED (${AFTER_FAILS} failing vs ${BASE_FAILS}) — reverting" >&2
    git checkout -q -- . 2>/dev/null
    log_append "fix-round" "regressed" "round $round"; rm -f "$SF" "$TO"; continue
  fi

  # tamper guard: a fix round may not touch the exams or the contract
  #
  # `git diff` tolerates a pathspec that does not exist; `git checkout` ERRORS on
  # one and reverts nothing. Handing checkout the declared dirs plus the default
  # `factory/tests` therefore silently no-ops in every Swift project — the
  # tampered exam stays in the tree and the next lines commit it. Filter to paths
  # that exist, and only run checkout when at least one does.
  existing_pathspecs GUARD "$VISIBLE_DIR" "$HELDOUT_DIR" factory/tests factory/CONTRACT.md
  # `git diff` only sees TRACKED files. A worker that writes a brand-new file into
  # the exam directory — the cheapest way to "fix" a failing check — is invisible
  # to it, and the selective commit below would happily `git add` it by name from
  # the FILES line. So check untracked paths under the guarded dirs as well.
  UNTRACKED=""
  if [ "${#GUARD[@]}" -gt 0 ]; then
    # NO --exclude-standard: the held-out directory is usually in .gitignore (the
    # README tells you to put it there so the builder cannot commit it), and
    # --exclude-standard would hide precisely the files this check exists to find.
    UNTRACKED="$(git ls-files --others -- "${GUARD[@]}" 2>/dev/null)"
  fi
  if [ -n "$UNTRACKED" ]; then
    echo "[fix] round $round ADDED files under the exams — removing: $(printf '%s' "$UNTRACKED" | tr '\n' ' ')" >&2
    printf '%s\n' "$UNTRACKED" | while IFS= read -r u; do [ -n "$u" ] && rm -f -- "$u"; done
    log_append "fix-round" "tamper_untracked_removed" "round $round $(printf '%s' "$UNTRACKED" | tr '\n' ' ')"
  fi
  if [ "${#GUARD[@]}" -gt 0 ] && ! git diff --quiet -- "${GUARD[@]}" 2>/dev/null; then
    echo "[fix] round $round TAMPERED with exams/contract — reverting: ${GUARD[*]}" >&2
    git checkout -q -- "${GUARD[@]}" 2>/dev/null
    log_append "fix-round" "tamper_reverted" "round $round paths=${GUARD[*]}"
    # If the revert could not be performed, say so instead of continuing as if
    # the exam were clean.
    if ! git diff --quiet -- "${GUARD[@]}" 2>/dev/null; then
      echo "[fix] round $round REVERT FAILED — halting, exam still modified" >&2
      log_append "fix-round" "tamper_unreverted" "round $round"
      rm -f "$SF" "$TO"
      break
    fi
  fi

  # selective commit
  FILES="$(status_field "$SF" FILES)"
  if [ -n "$FILES" ] && [ "$FILES" != "-" ]; then
    for f in $(printf '%s' "$FILES" | tr ',' ' '); do [ -e "$f" ] && git add -- "$f"; done
  else
    git add -u -- src tests 2>/dev/null
  fi
  if git diff --cached --quiet; then
    echo "[fix] round $round produced no change" >&2
    log_append "fix-round" "empty" "round $round"; rm -f "$SF" "$TO"; continue
  fi
  git commit -q -m "factory: fix round $round — $(status_field "$SF" SUMMARY)"
  SHA="$(git rev-parse --short HEAD)"
  progress_append "FIX-$round" "DONE" "$SHA" "$(( ${AFTER_FAILS:-0} == 0 ? 1 : 0 ))" "$(status_field "$SF" SUMMARY)"
  log_append "fix-round" "committed" "round $round $SHA"
  rm -f "$SF" "$TO"

  # re-inspect: a fresh verdict bound to the NEW sha
  echo "[fix] re-inspecting at $SHA" >&2
  bash scripts/inspect.sh || true
  NEW="$(head -1 factory/REVIEW.md)"
  echo "[fix] $NEW" >&2
  case "$NEW" in
    *SHIP*) status_emit "fix-round" "-" "DONE" "reached SHIP after $round round(s)"; exit 0 ;;
  esac
  [ "$BEFORE" = "$(git rev-parse HEAD)" ] && break
done

state_set "PARKED" "fix rounds exhausted after $MAX_ROUNDS; see factory/REVIEW.md"
status_emit "fix-round" "-" "BLOCKED" "still not SHIP after $MAX_ROUNDS round(s) — needs a human"
