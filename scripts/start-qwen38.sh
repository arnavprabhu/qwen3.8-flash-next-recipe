#!/usr/bin/env bash
set -euo pipefail

# Determine script and base directory (handling paths with spaces)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source configuration file if present
ENV_FILE="$BASE_DIR/.env.qwen38"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

# Fallback defaults
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-9999}"
MODEL_PATH="${MODEL_PATH:-models/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64-00001-of-00028.gguf}"
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-llama.cpp/build/bin/llama-server}"
CTX_SIZE="${CTX_SIZE:-204800}"
N_GPU_LAYERS="${N_GPU_LAYERS:-99}"
LOAD_MODE="${LOAD_MODE:-mmap}"
FIT="${FIT:-off}"
FLASH_ATTN="${FLASH_ATTN:-on}"
JINJA="${JINJA:-true}"
TEMPERATURE="${TEMPERATURE:-1.0}"
TOP_P="${TOP_P:-0.95}"
TOP_K="${TOP_K:-20}"
MIN_P="${MIN_P:-0}"
MODEL_ALIAS="${MODEL_ALIAS:-qwen3.8-flash-next}"
LOG_DIR="${LOG_DIR:-logs}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/qwen38.log}"
PID_FILE="${PID_FILE:-$LOG_DIR/qwen38.pid}"
EXTRA_ARGS="${EXTRA_ARGS:-}"

# Resolve relative paths relative to BASE_DIR
[[ "$MODEL_PATH" != /* ]] && MODEL_PATH="$BASE_DIR/$MODEL_PATH"
[[ "$LLAMA_SERVER_BIN" != /* ]] && LLAMA_SERVER_BIN="$BASE_DIR/$LLAMA_SERVER_BIN"
[[ "$LOG_DIR" != /* ]] && LOG_DIR="$BASE_DIR/$LOG_DIR"
[[ "$LOG_FILE" != /* ]] && LOG_FILE="$BASE_DIR/$LOG_FILE"
[[ "$PID_FILE" != /* ]] && PID_FILE="$BASE_DIR/$PID_FILE"

# 1. Automatically create logs directory
mkdir -p "$LOG_DIR"
mkdir -p "$(dirname "$PID_FILE")"
mkdir -p "$(dirname "$LOG_FILE")"

# 2. Check if already running via PID file
if [ -f "$PID_FILE" ]; then
    EXISTING_PID="$(cat "$PID_FILE" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        echo "Qwen3.8 server is already running with PID: $EXISTING_PID"
        echo "API URL: http://$HOST:$PORT/v1"
        exit 0
    else
        # Stale PID file
        rm -f "$PID_FILE"
    fi
fi

# 3. Detect if port 9999 is already occupied
OCCUPIED_PID="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
if [ -n "$OCCUPIED_PID" ]; then
    OCCUPIED_CMD="$(ps -p "$OCCUPIED_PID" -o comm= 2>/dev/null || echo "unknown")"
    echo "ERROR: Port $PORT is already occupied by PID $OCCUPIED_PID ($OCCUPIED_CMD)." >&2
    echo "Please stop the existing service or choose another port." >&2
    exit 1
fi

# 4. Validate llama-server binary exists and is executable
if [ ! -f "$LLAMA_SERVER_BIN" ]; then
    echo "ERROR: llama-server binary not found at:" >&2
    echo "  $LLAMA_SERVER_BIN" >&2
    exit 1
fi
if [ ! -x "$LLAMA_SERVER_BIN" ]; then
    echo "ERROR: llama-server binary is not executable:" >&2
    echo "  $LLAMA_SERVER_BIN" >&2
    exit 1
fi

# 5. Validate model exists
if [ ! -f "$MODEL_PATH" ]; then
    echo "ERROR: Model file not found at:" >&2
    echo "  $MODEL_PATH" >&2
    exit 1
fi

# 6. Build command arguments
SERVER_ARGS=(
    --host "$HOST"
    --port "$PORT"
    -m "$MODEL_PATH"
    --load-mode "$LOAD_MODE"
    --fit "$FIT"
    -ngl "$N_GPU_LAYERS"
    --flash-attn "$FLASH_ATTN"
    -c "$CTX_SIZE"
    --temp "$TEMPERATURE"
    --top-p "$TOP_P"
    --top-k "$TOP_K"
    --min-p "$MIN_P"
    --alias "$MODEL_ALIAS"
)

if [ "$JINJA" = "true" ] || [ "$JINJA" = "on" ] || [ "$JINJA" = "1" ]; then
    SERVER_ARGS+=(--jinja)
fi

if [ -n "$EXTRA_ARGS" ]; then
    # shellcheck disable=SC2206
    SERVER_ARGS+=($EXTRA_ARGS)
fi

# 7. Start server in background
echo "Starting Qwen3.8 server on port $PORT..."
nohup "$LLAMA_SERVER_BIN" "${SERVER_ARGS[@]}" >> "$LOG_FILE" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" > "$PID_FILE"

# 8. Wait for readiness
echo "Waiting for API readiness at http://$HOST:$PORT/v1/models..."
MAX_WAIT_SECONDS=60
READY=false
for ((i=1; i<=MAX_WAIT_SECONDS; i++)); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: llama-server process $SERVER_PID terminated unexpectedly." >&2
        echo "Last 25 lines of log ($LOG_FILE):" >&2
        tail -n 25 "$LOG_FILE" >&2
        rm -f "$PID_FILE"
        exit 1
    fi

    if curl -s -f "http://$HOST:$PORT/v1/models" >/dev/null 2>&1; then
        READY=true
        break
    fi
    sleep 1
done

if [ "$READY" = false ]; then
    echo "ERROR: Server did not become ready within $MAX_WAIT_SECONDS seconds." >&2
    echo "Last 25 lines of log ($LOG_FILE):" >&2
    tail -n 25 "$LOG_FILE" >&2
    exit 1
fi

# 9. Report success
echo ""
echo "=============================================================="
echo " Qwen3.8-Flash-Next Server Started Successfully"
echo "=============================================================="
echo " PID:          $SERVER_PID"
echo " Model:        $MODEL_PATH"
echo " Context Size: $CTX_SIZE"
echo " Port:         $PORT"
echo " Logs:         $LOG_FILE"
echo " API Base URL: http://$HOST:$PORT/v1"
echo " Health:       http://$HOST:$PORT/health"
echo " Models URL:   http://$HOST:$PORT/v1/models"
echo "=============================================================="
