#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source configuration file if present
ENV_FILE="$BASE_DIR/.env.qwen38"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-9999}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen3.8-flash-next}"
TEMPERATURE="${TEMPERATURE:-1.0}"
TOP_P="${TOP_P:-0.95}"

PROMPT="${1:-In one concise sentence, explain how Apple Silicon unified memory accelerates local LLM inference.}"
CHAT_URL="http://$HOST:$PORT/v1/chat/completions"

echo "=============================================================="
echo " Testing Qwen3.8 Chat Completions API"
echo " Endpoint: $CHAT_URL"
echo " Model:    $MODEL_ALIAS"
echo " Prompt:   \"$PROMPT\""
echo "=============================================================="

# Build request payload
JSON_PAYLOAD="$(python3 -c "
import json, sys
payload = {
    'model': sys.argv[1],
    'messages': [{'role': 'user', 'content': sys.argv[2]}],
    'temperature': float(sys.argv[3]),
    'top_p': float(sys.argv[4]),
    'max_tokens': 512
}
print(json.dumps(payload))
" "$MODEL_ALIAS" "$PROMPT" "$TEMPERATURE" "$TOP_P")"

START_TIME=$(python3 -c "import time; print(time.time())")
RESPONSE="$(curl -s -X POST "$CHAT_URL" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" || true)"
END_TIME=$(python3 -c "import time; print(time.time())")

if [ -z "$RESPONSE" ]; then
    echo "ERROR: Received empty response from server at $CHAT_URL" >&2
    exit 1
fi

printf '%s' "$RESPONSE" | python3 -c '
import json, sys

start_time = float(sys.argv[1])
end_time = float(sys.argv[2])

try:
    data = json.load(sys.stdin)
except Exception as e:
    print("ERROR: Failed to parse JSON response:", e)
    sys.exit(1)

if "error" in data:
    print("API Error:", data["error"])
    sys.exit(1)

choices = data.get("choices", [])
if not choices:
    print("No choices returned in response:", data)
    sys.exit(1)

msg = choices[0].get("message", {})
content = msg.get("content", "").strip()
reasoning = msg.get("reasoning_content", "").strip()

print("\n--- Model Response ---")
if reasoning:
    print("[Reasoning]:")
    print(reasoning)
    print("")
print("[Assistant]:")
print(content if content else "(empty response)")

usage = data.get("usage", {})
timings = data.get("timings", {})

print("\n--- Performance Metrics ---")
prompt_tokens = usage.get("prompt_tokens", timings.get("prompt_n", "N/A"))
completion_tokens = usage.get("completion_tokens", timings.get("predicted_n", "N/A"))
total_tokens = usage.get("total_tokens", "N/A")

print(f"Prompt Tokens:     {prompt_tokens}")
if "prompt_per_second" in timings:
    print(f"Prompt Speed:      {timings["prompt_per_second"]:.2f} tok/s ({timings.get("prompt_ms", 0):.1f} ms)")

print(f"Completion Tokens: {completion_tokens}")
if "predicted_per_second" in timings:
    print(f"Generation Speed:  {timings["predicted_per_second"]:.2f} tok/s ({timings.get("predicted_ms", 0):.1f} ms)")

total_wall_s = end_time - start_time
print(f"Total Wall Time:   {total_wall_s:.2f} s")
print("==============================================================")
' "$START_TIME" "$END_TIME"
