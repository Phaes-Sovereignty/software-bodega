#!/usr/bin/env bash
# local-model.sh — adapter shim for a local llama.cpp server.
#
# Presents an OpenAI-compatible llama-server as the same CLI shape every other
# role uses: prompt as a single argument, plain model text on stdout, non-zero
# exit on failure. That is all `run_role` needs, so a local model slots into the
# escalation ladder without any special-casing upstream.
#
#   bash scripts/lib/local-model.sh "<prompt>"
#
# Env:
#   LOCAL_MODEL_URL    default http://127.0.0.1:12435
#   LOCAL_MODEL_NAME   default local/qwopus3.6-27b
#   LOCAL_MODEL_TOKENS default 8192
#   LOCAL_MODEL_TIMEOUT default 900   (27B Q5 on Metal is ~1 tok/s of reasoning)
#
# Start the server with:
#   llama-server -m <model.gguf> --alias local/qwopus3.6-27b \
#     --host 127.0.0.1 --port 12435 --ctx-size 32768 --gpu-layers 999 \
#     --flash-attn on --jinja

set -uo pipefail

URL="${LOCAL_MODEL_URL:-http://127.0.0.1:12435}"
NAME="${LOCAL_MODEL_NAME:-local/qwopus3.6-27b}"
MAXTOK="${LOCAL_MODEL_TOKENS:-8192}"
TIMEOUT="${LOCAL_MODEL_TIMEOUT:-900}"

PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then
  echo "local-model.sh: no prompt given" >&2
  exit 2
fi

# Fail fast and loudly if the server is not up. A fallback that hangs for the
# full timeout is worse than one that is honestly absent: the preflight can
# report "unavailable" in a second and the night proceeds degraded.
if ! curl -s --max-time 5 "$URL/health" >/dev/null 2>&1; then
  echo "local-model.sh: no llama-server at $URL (start it, or unset the fallback role)" >&2
  exit 1
fi

REQ="$(TMPDIR="${TMPDIR:-/tmp}" mktemp)"
RES="$(TMPDIR="${TMPDIR:-/tmp}" mktemp)"
trap 'rm -f "$REQ" "$RES"' EXIT

# Build the request with python so the prompt is JSON-escaped correctly — the
# prompt contains newlines, quotes and whole skill files.
PROMPT="$PROMPT" NAME="$NAME" MAXTOK="$MAXTOK" python3 - "$REQ" <<'PY'
import json, os, sys
json.dump({
    "model": os.environ["NAME"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
    "temperature": 0,
    "max_tokens": int(os.environ["MAXTOK"]),
}, open(sys.argv[1], "w"))
PY

if ! curl -s --max-time "$TIMEOUT" "$URL/v1/chat/completions" \
      -H 'Content-Type: application/json' --data-binary "@$REQ" > "$RES" 2>/dev/null; then
  echo "local-model.sh: request failed or timed out after ${TIMEOUT}s" >&2
  exit 1
fi

python3 - "$RES" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except json.JSONDecodeError:
    print("local-model.sh: server returned non-JSON", file=sys.stderr); sys.exit(1)
if "error" in d:
    print(f"local-model.sh: {d['error']}", file=sys.stderr); sys.exit(1)
try:
    msg = d["choices"][0]["message"]
except (KeyError, IndexError):
    print("local-model.sh: no choices in response", file=sys.stderr); sys.exit(1)
# Reasoning models put chain-of-thought in reasoning_content. Print ONLY
# content: the factory's channel separation says a judge never sees a worker's
# reasoning, and the status-block parser wants the answer, not the deliberation.
sys.stdout.write(msg.get("content") or "")
PY
