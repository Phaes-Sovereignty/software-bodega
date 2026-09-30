# scripts/lib/python.sh — find an interpreter that can actually run the foreman.
# Source this; do not execute it.
#
# Why this exists: `python3 -m foreman launch` is the ONLY sealed night path, and
# foreman/router.py imports yaml. On a machine whose default python3 has no
# PyYAML the documented command dies at import, the conductor falls back to
# `nightshift.sh`, and the night runs with the builder sitting next to its own
# exam. selftest.sh reported that machine as green because the foreman checks
# SKIP when the import fails — a skip is not a pass, but nothing told the human
# which interpreter would fix it.
#
# BODEGA_PYTHON is the answer to "which python do I run the foreman with",
# resolved once, in this order:
#   1. $BODEGA_PYTHON / $PYTHON if given and it can import yaml
#   2. python3, then every interpreter on PATH named python3.*, then the usual
#      Homebrew / framework / conda locations
# First one that imports yaml wins. If none does, prints nothing and returns 1 —
# callers must then say so out loud rather than assuming python3 works.

: "${BODEGA_PYTHON:=}"

bodega_python_candidates() {
  [ -n "$BODEGA_PYTHON" ] && { printf '%s\n' "$BODEGA_PYTHON"; return; }
  [ -n "${PYTHON:-}" ] && printf '%s\n' "$PYTHON"
  command -v python3 >/dev/null 2>&1 && command -v python3
  # versioned interpreters on PATH first (they are usually the one with packages)
  local p
  for p in "$(command -v python3.13 2>/dev/null)" "$(command -v python3.12 2>/dev/null)" \
           "$(command -v python3.11 2>/dev/null)"; do
    [ -n "$p" ] && printf '%s\n' "$p"
  done
  for p in /usr/local/bin/python3.11 /usr/local/bin/python3.12 /usr/local/bin/python3.13 \
           /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3 \
           /usr/bin/python3 "$HOME/miniconda3/bin/python" "$HOME/anaconda3/bin/python"; do
    [ -x "$p" ] && printf '%s\n' "$p"
  done
}

# bodega_python_has_yaml <interpreter>
bodega_python_has_yaml() {
  local p="${1:-}"
  [ -n "$p" ] && command -v "$p" >/dev/null 2>&1 || return 1
  "$p" -c 'import yaml' >/dev/null 2>&1
}

# bodega_python : echo the best interpreter for foreman work, or nothing + rc 1.
bodega_python() {
  local p
  for p in $(bodega_python_candidates); do
    if bodega_python_has_yaml "$p"; then printf '%s' "$p"; return 0; fi
  done
  return 1
}

# bodega_python_foreman : echo the command prefix that runs the foreman module.
# Falls back to the bare `python3` so callers still get their ModuleNotFoundError
# text (which names the missing package) instead of silence.
bodega_python_foreman() {
  local p
  p="$(bodega_python)" || { printf 'python3'; return 1; }
  printf '%s' "$p"
}
