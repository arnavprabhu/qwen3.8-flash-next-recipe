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
PID_FILE="${PID_FILE:-$BASE_DIR/logs/qwen38.pid}"
LOG_FILE="${LOG_FILE:-$BASE_DIR/logs/qwen38.log}"
[[ "$PID_FILE" != /* ]] && PID_FILE="$BASE_DIR/$PID_FILE"
[[ "$LOG_FILE" != /* ]] && LOG_FILE="$BASE_DIR/$LOG_FILE"

API_URL="http://$HOST:$PORT/v1"
MODELS_URL="$API_URL/models"

CURRENT_PID=""
if [ -f "$PID_FILE" ]; then
    CANDIDATE_PID="$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$CANDIDATE_PID" ] && kill -0 "$CANDIDATE_PID" 2>/dev/null; then
        CURRENT_PID="$CANDIDATE_PID"
    fi
fi

if [ -z "$CURRENT_PID" ]; then
    PORT_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
    if [ -n "$PORT_PID" ]; then
        PROC_ARGS="$(ps -p "$PORT_PID" -o args= 2>/dev/null || echo "")"
        if [[ "$PROC_ARGS" == *"llama-server"* ]]; then
            CURRENT_PID="$PORT_PID"
        fi
    fi
fi

echo "=============================================================="
echo " Qwen3.8 Server Status"
echo "=============================================================="

if [ -z "$CURRENT_PID" ]; then
    echo " Status:       STOPPED (No active process found)"
    echo " Port:         $PORT (not listening)"
    echo " API URL:      $API_URL"
    echo " PID File:     $PID_FILE (not active)"
    if [ -f "$LOG_FILE" ]; then
        echo " Logs:         $LOG_FILE"
    fi
    echo "=============================================================="
    exit 1
fi

echo " Status:       RUNNING"
echo " PID:          $CURRENT_PID"
echo " Port:         $PORT"
echo " API Base URL: $API_URL"
echo " Logs:         $LOG_FILE"

# Test /v1/models endpoint
echo ""
echo "Testing $MODELS_URL..."
HTTP_RESPONSE="$(curl -s -m 5 "$MODELS_URL" || true)"

if [ -n "$HTTP_RESPONSE" ] && [[ "$HTTP_RESPONSE" == *"\"data\""* ]]; then
    echo "API Endpoint:  HEALTHY (200 OK)"
    echo ""
    echo "Model Details (from $MODELS_URL):"
    printf '%s' "$HTTP_RESPONSE" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for m in data.get("data", []):
        meta = m.get("meta", {})
        mid = m.get("id", "N/A")
        n_ctx = meta.get("n_ctx", "N/A")
        n_ctx_train = meta.get("n_ctx_train", "N/A")
        ftype = meta.get("ftype", "N/A")
        n_params = meta.get("n_params", "N/A")
        print(f"  - Model ID:       {mid}")
        print(f"  - Context Size:   {n_ctx}")
        print(f"  - Max Train Ctx:  {n_ctx_train}")
        print(f"  - Quantization:   {ftype}")
        print(f"  - Parameters:     {n_params}")
except Exception as e:
    print("  Failed to parse JSON response:", e)
' || echo "$HTTP_RESPONSE"
    echo "=============================================================="
    exit 0
else
    echo "API Endpoint:  UNRESPONSIVE or returned unexpected output"
    echo "Raw response:  $HTTP_RESPONSE"
    echo "=============================================================="
    exit 1
fi
