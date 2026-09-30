#!/usr/bin/env bash
# scripts/lib/status.sh — status-block parser, diary helpers, role dispatch.
# Source this; do not execute it.
#
# The status block contract (FACTORY-BUILD.md §0 rule 6):
#   ---FACTORY_STATUS---
#   STATION: <name>
#   TASK_ID: <id or ->
#   STATUS: DONE | BLOCKED | NEEDS_CONTEXT
#   SUMMARY: <one line>
#   ---END---
# Optional trailing fields (night-task adds these): EXIT_SIGNAL, TESTS, FILES.

set -uo pipefail

FACTORY_ROOT="${FACTORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export FACTORY_ROOT

# Callers normally set HERE before sourcing; derive it when they do not so this
# file is safe to source standalone (CI, the behaviour tests).
: "${HERE:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck disable=SC1091
[ -f "$FACTORY_ROOT/models.env" ] && . "$FACTORY_ROOT/models.env"

# Per-project toolchain profile: how THIS project is built and verified
# (VISIBLE_CMD, HELDOUT_CMD, HELDOUT_DIR, BUILD_CMD, EXTRA_GATE_CMD). Separate
# from models.env, which says who does the work. toolchain.sh owns the defaults
# AND the one question that used to be answered differently in six places: where
# the held-out suite lives. Source it instead of sourcing toolchain.env directly,
# or you get the project's declarations without the fallbacks that make them
# safe to eval.
# shellcheck disable=SC1091
. "$HERE/lib/toolchain.sh"

STATUS_VALID_STATES="DONE BLOCKED NEEDS_CONTEXT"

# --- parsing --------------------------------------------------------------

# status_block <file|-> : print the body of the LAST complete status block.
# Last, not first: models often echo the template before emitting the real one.
status_block() {
  local src="${1:--}"
  awk '
    /^[[:space:]]*---FACTORY_STATUS---[[:space:]]*$/ { inblk=1; buf=""; next }
    inblk && /^[[:space:]]*---END---[[:space:]]*$/   { last=buf; inblk=0; next }
    inblk                                            { buf = buf $0 "\n" }
    END                                              { printf "%s", last }
  ' "$src"
}

# status_field <file|-> <FIELD> : print the value of FIELD from the last block.
status_field() {
  local src="${1:--}" key="$2"
  status_block "$src" | awk -v k="$key" '
    {
      idx = index($0, ":")
      if (idx == 0) next
      name = substr($0, 1, idx - 1)
      val  = substr($0, idx + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (name == k) { print val; found = 1; exit }
    }
    END { if (!found) exit 0 }
  '
}

# status_valid <file|-> : 0 if the last block is well formed, else 1 + reason.
status_valid() {
  local src="${1:--}" body station status summary
  body="$(status_block "$src")"
  if [ -z "$body" ]; then
    echo "no complete status block found" >&2; return 1
  fi
  station="$(printf '%s' "$body" | awk -F: '/^[[:space:]]*STATION[[:space:]]*:/{sub(/^[^:]*:/,"");gsub(/^[[:space:]]+|[[:space:]]+$/,"");print;exit}')"
  status="$(status_field "$src" STATUS)"
  summary="$(status_field "$src" SUMMARY)"
  [ -n "$station" ] || { echo "STATION missing" >&2; return 1; }
  [ -n "$summary" ] || { echo "SUMMARY missing" >&2; return 1; }
  case " $STATUS_VALID_STATES " in
    *" $status "*) ;;
    *) echo "STATUS invalid: '${status:-<empty>}'" >&2; return 1 ;;
  esac
  return 0
}

# status_emit STATION TASK_ID STATUS SUMMARY [EXTRA_LINE...] : write a block.
# Exists so the round-trip test has a producer to pair with the parser.
status_emit() {
  local station="$1" task="$2" status="$3" summary="$4"; shift 4
  printf -- '---FACTORY_STATUS---\n'
  printf -- 'STATION: %s\n' "$station"
  printf -- 'TASK_ID: %s\n' "$task"
  printf -- 'STATUS: %s\n' "$status"
  printf -- 'SUMMARY: %s\n' "$summary"
  local extra
  for extra in "$@"; do printf -- '%s\n' "$extra"; done
  printf -- '---END---\n'
}

# --- diaries (append-only; never rewrite) ---------------------------------

# progress_append TASK STATUS SHA TESTS NOTE
progress_append() {
  local f="$FACTORY_ROOT/factory/progress.md"
  printf '%s|%s|%s|%s|%s\n' "${1:--}" "${2:--}" "${3:--}" "${4:--}" "${5:-}" >> "$f"
}

# log_append STATION EVENT DETAIL
log_append() {
  local f="$FACTORY_ROOT/factory/log.md"
  printf '%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:--}" "${2:--}" "${3:-}" >> "$f"
}

# state_set STAGE POINTER : STATE.md is a pointer, not a log.
state_set() {
  printf 'STAGE: %s\nPOINTER: %s\n' "$1" "${2:-}" > "$FACTORY_ROOT/factory/STATE.md"
  log_append "$1" "state_set" "${2:-}"
}

state_stage() { awk -F': *' '/^STAGE:/{print $2; exit}' "$FACTORY_ROOT/factory/STATE.md" 2>/dev/null; }

# --- role dispatch --------------------------------------------------------

role_cmd() {
  case "$1" in
    executor)   printf '%s' "${EXECUTOR_CMD:-}" ;;
    planner)    printf '%s' "${PLANNER_CMD:-}" ;;
    judge)      printf '%s' "${JUDGE_CMD:-}" ;;
    plan_judge) printf '%s' "${PLAN_JUDGE_CMD:-}" ;;
    glue)       printf '%s' "${GLUE_CMD:-}" ;;
    triage)     printf '%s' "${TRIAGE_CMD:-}" ;;
    fallback)   printf '%s' "${FALLBACK_CMD:-}" ;;
    *) return 2 ;;
  esac
}

role_family() {
  case "$1" in
    executor)   printf '%s' "${EXECUTOR_FAMILY:-}" ;;
    planner)    printf '%s' "${PLANNER_FAMILY:-}" ;;
    judge)      printf '%s' "${JUDGE_FAMILY:-}" ;;
    plan_judge) printf '%s' "${PLAN_JUDGE_FAMILY:-}" ;;
    glue)       printf '%s' "${GLUE_FAMILY:-}" ;;
    triage)     printf '%s' "${TRIAGE_FAMILY:-}" ;;
    fallback)   printf '%s' "${FALLBACK_FAMILY:-}" ;;
    *) return 2 ;;
  esac
}

# assert_cross_family JUDGE_ROLE AUTHOR_ROLE : hard rule 2. Fails loudly.
assert_cross_family() {
  local jf af
  jf="$(role_family "$1")" || { echo "unknown role $1" >&2; return 2; }
  af="$(role_family "$2")" || { echo "unknown role $2" >&2; return 2; }
  if [ "$jf" = "$af" ]; then
    echo "FAMILY VIOLATION: judge '$1' ($jf) same family as author '$2' ($af)" >&2
    return 1
  fi
  return 0
}

role_input_mode() {
  case "$1" in
    executor)   printf '%s' "${EXECUTOR_INPUT:-arg}" ;;
    planner)    printf '%s' "${PLANNER_INPUT:-stdin}" ;;
    judge)      printf '%s' "${JUDGE_INPUT:-stdin}" ;;
    plan_judge) printf '%s' "${PLAN_JUDGE_INPUT:-stdin}" ;;
    glue)       printf '%s' "${GLUE_INPUT:-arg}" ;;
    triage)     printf '%s' "${TRIAGE_INPUT:-stdin}" ;;
    fallback)   printf '%s' "${FALLBACK_INPUT:-arg}" ;;
    *) printf 'stdin' ;;
  esac
}

# --- escalation ladder ----------------------------------------------------
#
# The ladder used to exist only in foreman/routing.yaml, which the night shift
# cannot read, and Router.escalate() had no caller. Result: nightshift.sh ran
# repair -> resample -> PARK and the planner rung, the plan_judge rung and the
# local fallback were pure decoration.
#
# Format (models.env:ESCALATION_LADDER): space-separated rungs,
# each `strategy:role[:n[:select]]`.

ladder_length() {
  local n=0 r
  for r in ${ESCALATION_LADDER:-}; do n=$((n + 1)); done
  printf '%s' "$n"
}

# ladder_rung <index> : echo the rung spec, or empty past the end.
ladder_rung() {
  local want="$1" i=0 r
  for r in ${ESCALATION_LADDER:-}; do
    if [ "$i" = "$want" ]; then printf '%s' "$r"; return 0; fi
    i=$((i + 1))
  done
  return 1
}

# rung_field <spec> <n> : the n-th ':'-separated field of a rung spec.
rung_field() { printf '%s' "$1" | cut -d: -f"$2"; }

# may_escalate <reason> : the ladder fires on a verify failure and nothing else.
# Not a low-confidence self-report, not elapsed time, not an agent asking — all
# three are things a failing worker can manufacture. Mirrors Router.may_escalate.
may_escalate() {
  local trigger
  trigger="${ESCALATION_TRIGGER:-verify_failure_only}"
  [ "$trigger" = "verify_failure_only" ] && { [ "${1:-}" = "verify_failure" ] && return 0 || return 1; }
  return 0
}

# --- who actually wrote the code ------------------------------------------
#
# progress.md's 5th field is a free-text note; the author family needs to be
# machine-readable because the inspector picks its judge from the UNION of
# families that touched the night's accepted commits. Kept as a set file so a
# 40-task night records 40 lines and the inspector still reads one list.
AUTHOR_SET_FILE="factory/.planning/author-families.txt"

record_author_family() { # record_author_family <family>
  local fam="$1" f="$FACTORY_ROOT/$AUTHOR_SET_FILE"
  [ -n "$fam" ] || return 0
  mkdir -p "$(dirname "$f")" 2>/dev/null
  grep -qxF "$fam" "$f" 2>/dev/null && return 0
  printf '%s\n' "$fam" >> "$f"
}

author_families() { # -> comma-separated set, empty if none recorded
  local f="$FACTORY_ROOT/$AUTHOR_SET_FILE"
  [ -f "$f" ] || return 0
  tr '\n' ',' < "$f" | sed 's/,$//'
}

# --- judge selection against the family that ACTUALLY wrote the code -------
#
# Hard rule 2 says a judge must be a different family from the author. Checking
# `judge` against `executor` once at startup does not hold when the author is
# whoever the escalation ladder happened to use: if Opus fixes the code and the
# judge role is also Opus, the system grades its own homework and the verdict
# looks exactly like a real one.
#
# So the judge is chosen PER VERDICT, from JUDGE_ROLES, against the family that
# produced the change. Returns 2 when no cross-family judge is configured — the
# caller must then refuse to judge, never fall back to a same-family one.
judge_for_family() { # judge_for_family <author_family[,family...]> -> role name
  local authors="$1" role fam bad
  [ -n "$authors" ] || { echo "judge_for_family: empty author family list" >&2; return 2; }
  for role in ${JUDGE_ROLES:-judge}; do
    fam="$(role_family "$role" 2>/dev/null)" || continue
    [ -n "$fam" ] || continue
    bad=0
    for a in $(printf '%s' "$authors" | tr ',' ' '); do
      [ "$fam" = "$a" ] && bad=1
    done
    if [ "$bad" = "0" ]; then printf '%s' "$role"; return 0; fi
  done
  echo "no judge role configured outside the authoring families ($authors)" >&2
  return 2
}

# assert_judge_for JUDGE_ROLE AUTHOR_FAMILY : hard rule 2, evaluated at call time.
assert_judge_for() {
  local jf
  jf="$(role_family "$1" 2>/dev/null)" || { echo "unknown judge role $1" >&2; return 2; }
  if [ "$jf" = "$2" ]; then
    echo "FAMILY VIOLATION: judge '$1' ($jf) shares a family with the author ($2)" >&2
    return 1
  fi
  return 0
}

# run_role ROLE PROMPT : invoke a role headless, print normalized model text.
# Normalizes claude's --output-format json envelope down to .result.
#
# Prompt delivery differs per CLI and is declared in models.env, not sniffed:
#   stdin — required for claude (its --allowedTools is variadic and would eat a
#           trailing prompt argument) and safe for codex.
#   arg   — required for grok, which errors on an empty prompt argument.
run_role() {
  local role="$1" prompt="$2" cmd raw rc mode err
  cmd="$(role_cmd "$role")" || { echo "unknown role: $role" >&2; return 2; }
  [ -n "$cmd" ] || { echo "no command configured for role: $role" >&2; return 2; }
  mode="$(role_input_mode "$role")"
  err="$(mktemp)"
  local out; out="$(mktemp)"
  local -a argv=()
  read -r -a argv <<< "$cmd"

  # Watchdog. An adapter that hangs on a stalled stream defeats every repair cap
  # in the design — observed during the Phase B dry run, where a station sat
  # idle for 23 minutes after writing all its artifacts. macOS ships no
  # timeout(1), so this is a plain background killer.
  local limit="${FACTORY_ROLE_TIMEOUT:-1800}" pid wd
  if [ "$mode" = "stdin" ]; then
    printf '%s' "$prompt" | "${argv[@]}" >"$out" 2>"$err" & pid=$!
  else
    # A prompt passed as an argument must not START with a dash, or the CLI's
    # own parser claims it as a flag. Every skill file opens with YAML
    # frontmatter (`---`), so this fires on essentially every worker prompt;
    # `--` does not help because the parser rejects it before that. A leading
    # newline is inert to the model and fixes it.
    local argprompt="$prompt"
    case "$argprompt" in -*) argprompt="
$argprompt" ;; esac
    "${argv[@]}" "$argprompt" >"$out" 2>"$err" & pid=$!
  fi
  ( sleep "$limit"; kill -TERM "$pid" 2>/dev/null; sleep 5; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 & wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  raw="$(cat "$out")"; rm -f "$out"
  if [ $rc -ge 124 ] || { [ $rc -ne 0 ] && [ ! -s "$err" ] && [ -z "$raw" ]; }; then
    echo "role '$role' timed out or was killed after ${limit}s (rc=$rc)" >&2
  fi
  if [ $rc -ne 0 ]; then
    # Adapter failures are loud. A silent empty result becomes a bogus gate
    # failure three stations downstream, which is far more expensive to debug.
    echo "role '$role' exited $rc: $(head -c 300 "$err" | tr '\n' ' ')" >&2
    rm -f "$err"
    printf '%s' "$raw"
    return $rc
  fi
  rm -f "$err"
  case "$cmd" in
    *"--output-format json"*)
      local parsed
      parsed="$(printf '%s' "$raw" | jq -r '.result // empty' 2>/dev/null)"
      if [ -n "$parsed" ]; then printf '%s' "$parsed"; else printf '%s' "$raw"; fi
      ;;
    *) printf '%s' "$raw" ;;
  esac
}

# run_role_file ROLE PROMPT OUTFILE : run_role but tee to a file, validate block.
run_role_file() {
  local role="$1" prompt="$2" out="$3"
  run_role "$role" "$prompt" > "$out"
  status_valid "$out"
}
