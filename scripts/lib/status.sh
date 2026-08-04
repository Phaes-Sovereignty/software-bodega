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

# shellcheck disable=SC1091
[ -f "$FACTORY_ROOT/models.env" ] && . "$FACTORY_ROOT/models.env"

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
