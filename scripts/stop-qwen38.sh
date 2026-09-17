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
[[ "$PID_FILE" != /* ]] && PID_FILE="$BASE_DIR/$PID_FILE"

TARGET_PID=""

# 1. Try to find PID from PID file
if [ -f "$PID_FILE" ]; then
    CANDIDATE_PID="$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$CANDIDATE_PID" ] && kill -0 "$CANDIDATE_PID" 2>/dev/null; then
        PROC_ARGS="$(ps -p "$CANDIDATE_PID" -o args= 2>/dev/null || echo "")"
        # Verify that this PID belongs to llama-server
        if [[ "$PROC_ARGS" == *"llama-server"* ]]; then
            TARGET_PID="$CANDIDATE_PID"
        else
            echo "Warning: PID $CANDIDATE_PID in $PID_FILE is not a llama-server process (found: $PROC_ARGS)."
            rm -f "$PID_FILE"
        fi
    else
        echo "Removing stale PID file: $PID_FILE"
        rm -f "$PID_FILE"
    fi
fi

# 2. If no valid PID from file, check if port 9999 is owned by llama-server
if [ -z "$TARGET_PID" ]; then
    PORT_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
    if [ -n "$PORT_PID" ]; then
        PROC_ARGS="$(ps -p "$PORT_PID" -o args= 2>/dev/null || echo "")"
        if [[ "$PROC_ARGS" == *"llama-server"* ]]; then
            echo "Discovered running Qwen llama-server on port $PORT (PID: $PORT_PID)."
            TARGET_PID="$PORT_PID"
        fi
    fi
fi

if [ -z "$TARGET_PID" ]; then
    echo "Qwen3.8 server is not currently running."
    rm -f "$PID_FILE"
    exit 0
fi

echo "Stopping Qwen3.8 server (PID: $TARGET_PID)..."
kill -TERM "$TARGET_PID" 2>/dev/null || true

# Wait gracefully up to 15 seconds
STOPPED=false
for ((i=1; i<=15; i++)); do
    if ! kill -0 "$TARGET_PID" 2>/dev/null; then
        STOPPED=true
        break
    fi
    sleep 1
done

if [ "$STOPPED" = false ]; then
    echo "Process did not stop gracefully within 15 seconds. Sending SIGKILL..."
    kill -KILL "$TARGET_PID" 2>/dev/null || true
    sleep 1
fi

rm -f "$PID_FILE"
echo "Qwen3.8 server (PID: $TARGET_PID) stopped successfully."
