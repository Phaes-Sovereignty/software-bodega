#!/usr/bin/env bash
# foreman.sh — the ONE way to run the foreman, because it needs an interpreter
# that can import yaml and the machine's default python3 frequently cannot.
#
#   bash scripts/foreman.sh status
#   bash scripts/foreman.sh launch --max-iters 25
#   bash scripts/foreman.sh --root /path/to/project launch
#
# `python3 -m foreman` is what the docs used to say. On a host where python3 has
# no PyYAML that dies at import; the conductor then falls back to nightshift.sh,
# which runs the whole night UNSEALED with the builder next to its own exam. A
# missing package silently cost the single most important mechanism in the
# design, so the entry point resolves the interpreter itself and refuses loudly
# when none can do the job.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck source=lib/python.sh
. "$HERE/lib/python.sh"

PY="$(bodega_python)"
if [ -z "$PY" ]; then
  cat >&2 <<'MSG'
foreman: no Python interpreter here can import PyYAML.

The foreman is the sealed night launcher (`foreman.sh launch`): it builds a
sparse-checkout worktree in which the held-out suite does not exist. Without it
you have two options, and neither is "run nightshift.sh in the main checkout":

  1. install the dependency into any interpreter on PATH:
       <python> -m pip install pyyaml
     then re-run: bash scripts/foreman.sh status
  2. seal the tree yourself and run the loop inside it:
       . scripts/lib/status.sh
       tmp="$(mktemp -d)/wt"
       create_sealed_tree "$PWD" "$tmp" "night/manual" HEAD || exit 1
       ( cd "$tmp" && FACTORY_ROOT="$PWD" BODEGA_SEALED=1 bash scripts/nightshift.sh )

Option 2 is exactly what the foreman does; do not skip the sealing.
MSG
  exit 1
fi

# `-m foreman` needs the package importable, which is not the case when invoked
# from a different directory. PYTHONPATH makes the entry point location-independent.
cd "$ROOT" || exit 1
export PYTHONPATH="$ROOT${PYTHONPATH:+:$PYTHONPATH}"
exec "$PY" -m foreman "$@"
