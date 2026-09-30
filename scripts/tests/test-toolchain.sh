#!/usr/bin/env bash
# test-toolchain.sh — BEHAVIOURAL tests for the toolchain layer and the seal.
#
# Replaces the grep-for-a-string checks that let the Swift gap ship. Those
# assertions asked "does the file contain the words 'toolchain.env'"; the answer
# was yes while HELDOUT_CMD was read by nothing and the seal removed a directory
# a Swift project does not use. A string in a file proves the intent was written
# down, never that the mechanism works. Everything below RUNS something and
# asserts on what happened.
#
# Usage: bash scripts/tests/test-toolchain.sh

set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# A throwaway project with the factory machinery available.
mkproj() { # mkproj <name> -> echoes dir
  local d="$TMP/$1"
  rm -rf "$d"; mkdir -p "$d/scripts/lib" "$d/factory" "$d/skills/night-task"
  cp "$SRC"/scripts/*.sh "$d/scripts/"
  cp "$SRC"/scripts/lib/*.sh "$d/scripts/lib/"
  cp "$SRC"/models.env "$d/"
  printf 'worker skill\n' > "$d/skills/night-task/SKILL.md"
  : > "$d/factory/progress.md"; : > "$d/factory/log.md"
  printf 'STAGE: IDLE\nPOINTER: -\n' > "$d/factory/STATE.md"
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm init ) >/dev/null 2>&1
  printf '%s' "$d"
}

# Every child is spawned with FACTORY_ROOT cleared. selftest.sh sources
# status.sh, which EXPORTS FACTORY_ROOT pointing at the template repo; a fixture
# that inherits it resolves its toolchain against the wrong project and every
# assertion below silently describes the template instead of the fixture.
tc_get() { # tc_get <proj> <KEY>
  ( cd "$1" && env -u FACTORY_ROOT bash scripts/toolchain.sh get "$2" 2>/dev/null )
}
in_proj() { # in_proj <proj> <args...>
  ( cd "$1" && shift && env -u FACTORY_ROOT bash "$@" )
}

echo "toolchain resolution"

# --- 1. defaults: no profile at all still resolves a usable answer ----------
P="$(mkproj defaults)"
[ "$(tc_get "$P" HELDOUT_DIR)" = "factory/tests/heldout" ] \
  && ok "no profile -> HELDOUT_DIR defaults to factory/tests/heldout" \
  || bad "default HELDOUT_DIR wrong: got '$(tc_get "$P" HELDOUT_DIR)'"
[ "$(tc_get "$P" HELDOUT_CMD)" = "bash factory/tests/run-heldout.sh" ] \
  && ok "no profile -> HELDOUT_CMD defaults to the runner script" \
  || bad "default HELDOUT_CMD wrong: got '$(tc_get "$P" HELDOUT_CMD)'"

# --- 2. detection drives the profile ---------------------------------------
# This is the item-1 defect: a Package.swift project must NOT be told Python.
S="$(mkproj swift)"; touch "$S/Package.swift"
in_proj "$S" scripts/toolchain.sh resolve >/dev/null 2>&1
[ -f "$S/factory/toolchain.env" ] && ok "resolve writes factory/toolchain.env when absent" \
  || bad "resolve wrote no toolchain.env"
[ "$(tc_get "$S" HELDOUT_DIR)" = "Tests/HeldoutTests" ] \
  && ok "Package.swift detected -> HELDOUT_DIR=Tests/HeldoutTests" \
  || bad "swift detection wrong: HELDOUT_DIR='$(tc_get "$S" HELDOUT_DIR)'"
case "$(tc_get "$S" HELDOUT_CMD)" in
  *"manifest-cache none"*) ok "swift HELDOUT_CMD carries --manifest-cache none" ;;
  *) bad "swift HELDOUT_CMD lost the manifest-cache flag: '$(tc_get "$S" HELDOUT_CMD)'" ;;
esac
[ "$(tc_get "$S" FACTORY_ROLE_TIMEOUT)" = "5400" ] \
  && ok "swift profile raises the role timeout to 5400" \
  || bad "swift timeout not applied: '$(tc_get "$S" FACTORY_ROLE_TIMEOUT)'"

# --- 3. HELDOUT_CMD is actually READ, not just declared --------------------
# The old bug: the variable existed and nothing consumed it. Prove consumption
# by making the command an observable side effect.
R="$(mkproj consumed)"; mkdir -p "$R/factory/tests/heldout"
cat > "$R/factory/toolchain.env" <<'EOF'
HELDOUT_DIR='somewhere/else/tests'
HELDOUT_CMD='touch .heldout_was_run'
VISIBLE_CMD='touch .visible_was_run'
EOF
mkdir -p "$R/somewhere/else/tests"
( cd "$R" && unset FACTORY_ROOT && . scripts/lib/status.sh \
    && run_visible_suite /dev/null; run_heldout_suite /dev/null ) >/dev/null 2>&1
[ -f "$R/.heldout_was_run" ] && ok "run_heldout_suite EXECUTES the declared HELDOUT_CMD" \
  || bad "HELDOUT_CMD was declared but never executed (the original defect)"
[ -f "$R/.visible_was_run" ] && ok "run_visible_suite EXECUTES the declared VISIBLE_CMD" \
  || bad "VISIBLE_CMD was declared but never executed"

# --- 4. the seal uses the DECLARED directory ------------------------------
( cd "$R" && unset FACTORY_ROOT && . scripts/lib/status.sh && printf 'SECRET\n' > somewhere/else/tests/leak.txt \
    && mkdir -p factory/tests/heldout && printf 'stale\n' > factory/tests/heldout/x.txt ) >/dev/null 2>&1
( cd "$R" && unset FACTORY_ROOT && . scripts/lib/status.sh && seal_tree "$R" ) >/dev/null 2>&1
[ ! -e "$R/somewhere/else/tests/leak.txt" ] \
  && ok "seal_tree removes the DECLARED held-out dir (somewhere/else/tests)" \
  || bad "seal_tree left the declared held-out files in place"
if ( cd "$R" && . scripts/lib/status.sh && tree_is_sealed "$R" ) 2>/dev/null; then
  bad "tree_is_sealed passed with a stale factory/tests/heldout present"
else
  ok "tree_is_sealed still refuses a leftover default-dir heldout/"
fi

# --- 5. a missing suite is 127, never a pass ------------------------------
M="$(mkproj missing)"
( cd "$M" && unset FACTORY_ROOT && . scripts/lib/status.sh && run_heldout_suite /dev/null ) >/dev/null 2>&1
rc=$?
[ "$rc" = "127" ] && ok "absent held-out suite returns 127 (missing evidence != green)" \
  || bad "absent held-out suite returned $rc, expected 127"

# --- 6. check refuses a toolchain that cannot run -------------------------
# Every OTHER value is valid here so the failure can only come from the missing
# tool. Assert on the message too: a bare non-zero exit could be anything.
B="$(mkproj broken)"; mkdir -p "$B/factory/tests/heldout" "$B/factory/tests/visible"
cat > "$B/factory/toolchain.env" <<'EOF'
HELDOUT_DIR='factory/tests/heldout'
VISIBLE_DIR='factory/tests/visible'
VISIBLE_CMD='definitely-not-a-real-tool test'
HELDOUT_CMD='true'
EOF
BOUT="$( cd "$B" && env -u FACTORY_ROOT bash scripts/toolchain.sh check 2>&1 )"; BRC=$?
[ "$BRC" -ne 0 ] && ok "check FAILS a VISIBLE_CMD whose tool is not on PATH (rc=$BRC)" \
  || bad "check passed a toolchain that cannot run"
case "$BOUT" in
  *"MISSING TOOL"*not-a-real-tool*) ok "the failure names the missing tool" ;;
  *) bad "check failed but did not say why: $(printf '%s' "$BOUT" | tr '\n' '|')" ;;
esac

# --- 7. check refuses a seal that would delete the visible suite ----------
N="$(mkproj nested)"; mkdir -p "$N/factory/tests/visible" "$N/factory/tests"
cat > "$N/factory/toolchain.env" <<'EOF'
HELDOUT_DIR='factory/tests'
VISIBLE_DIR='factory/tests/visible'
VISIBLE_CMD='true'
HELDOUT_CMD='true'
EOF
NOUT="$( cd "$N" && env -u FACTORY_ROOT bash scripts/toolchain.sh check 2>&1 )"; NRC=$?
[ "$NRC" -ne 0 ] && ok "check FAILS when VISIBLE_DIR sits inside HELDOUT_DIR (rc=$NRC)" \
  || bad "check passed a profile whose seal would delete the visible suite"
case "$NOUT" in
  *"is inside HELDOUT_DIR"*) ok "the failure explains that sealing would delete the visible suite" ;;
  *) bad "check failed but not for the nesting reason: $(printf '%s' "$NOUT" | tr '\n' '|')" ;;
esac

# --- 7b. check's standard depends on WHERE in the pipeline it runs ---------
# TOOLCHAIN runs before the exam board, and for a Python project the runner
# scripts are that station's OUTPUT. A pre-exam check that demanded them would
# stop every default-layout project before it reached the station that writes
# them; a post-exam check that forgave their absence would let a board that
# wrote nothing proceed. Both directions are asserted.
O="$(mkproj order)"
mkdir -p "$O/factory"
in_proj "$O" scripts/toolchain.sh resolve >/dev/null 2>&1
in_proj "$O" scripts/toolchain.sh check >/dev/null 2>&1; PRER=$?
[ "$PRER" = "0" ] \
  && ok "pre-exam check PASSES a Python project whose runner scripts do not exist yet" \
  || bad "pre-exam check blocked the default path (rc=$PRER) — the exam board never gets to run"
in_proj "$O" scripts/toolchain.sh check post-exam >/dev/null 2>&1; POSTR=$?
[ "$POSTR" != "0" ] \
  && ok "post-exam check FAILS when the promised runner scripts were never written" \
  || bad "post-exam check forgave a missing runner — an unverifiable project would proceed"
# and once the board has written them, post-exam passes
mkdir -p "$O/factory/tests/visible" "$O/factory/tests/heldout"
printf '#!/bin/sh\nexit 1\n' | tee "$O/factory/tests/run-visible.sh" "$O/factory/tests/run-heldout.sh" >/dev/null
chmod +x "$O"/factory/tests/run-*.sh
in_proj "$O" scripts/toolchain.sh check post-exam >/dev/null 2>&1; POST2=$?
[ "$POST2" = "0" ] \
  && ok "post-exam check passes once the runners exist" \
  || bad "post-exam check still fails with valid runners (rc=$POST2)"

# --- 8. resolve respects a profile the human already wrote ----------------
K="$(mkproj respect)"; mkdir -p "$K/custom/heldout" "$K/custom/visible"
printf "HELDOUT_DIR='custom/heldout'\nVISIBLE_CMD='true'\nHELDOUT_CMD='true'\n" \
  > "$K/factory/toolchain.env"
( cd "$K" && touch Package.swift && env -u FACTORY_ROOT bash scripts/toolchain.sh resolve >/dev/null 2>&1 )
[ "$(tc_get "$K" HELDOUT_DIR)" = "custom/heldout" ] \
  && ok "resolve does NOT overwrite a declaration the project already made" \
  || bad "resolve clobbered the project's HELDOUT_DIR -> '$(tc_get "$K" HELDOUT_DIR)'"

# --- 9. sparse_patterns tracks the declaration ----------------------------
SP="$( cd "$S" && unset FACTORY_ROOT && . scripts/lib/status.sh && sparse_patterns | tr '\n' ' ' )"
case "$SP" in
  *"!/Tests/HeldoutTests/"*) ok "sparse_patterns excludes the DECLARED dir" ;;
  *) bad "sparse_patterns still hard-codes the default: $SP" ;;
esac

# --- 10. the Python reader and the shell loader must agree ----------------
# Two parsers for one file is how the seal (Python) and the suite (shell) could
# disagree about HELDOUT_DIR while both reported success.
if command -v python3 >/dev/null 2>&1 && [ -d "$SRC/foreman" ]; then
  PYD="$( cd "$S" && env -u FACTORY_ROOT python3 -c "
import sys; sys.path.insert(0,'$SRC')
try:
    from foreman.contracts import heldout_dir
    print(heldout_dir(__import__('pathlib').Path('$S')))
except Exception as e:
    print('SKIP', e)
" 2>/dev/null )"
  case "$PYD" in
    SKIP*) printf '  \033[33m–\033[0m python reader skipped (%s)\n' "${PYD#SKIP }" ;;
    *)  [ "$PYD" = "$(tc_get "$S" HELDOUT_DIR)" ] \
          && ok "foreman's Python reader agrees with the shell loader ($PYD)" \
          || bad "readers disagree: python='$PYD' shell='$(tc_get "$S" HELDOUT_DIR)'" ;;
  esac
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
