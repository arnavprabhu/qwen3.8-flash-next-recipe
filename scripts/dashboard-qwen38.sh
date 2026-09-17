#!/usr/bin/env bash
# Real-time Telemetry Dashboard for Qwen3.8-Flash-Next on Apple Silicon
# Usage: ./scripts/dashboard-qwen38.sh [--interval <seconds>] [--once]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration if present
if [[ -f "${BASE_DIR}/.env.qwen38" ]]; then
    # shellcheck disable=SC1091
    source "${BASE_DIR}/.env.qwen38"
fi

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-9999}"
PID_FILE="${PID_FILE:-${BASE_DIR}/logs/qwen38.pid}"

exec python3 - "${HOST}" "${PORT}" "${PID_FILE}" "$@" << 'EOF'
import sys
import os
import time
import json
import subprocess
import urllib.request
import urllib.error

host = sys.argv[1]
port = sys.argv[2]
pid_file = sys.argv[3]
args = sys.argv[4:]

interval = 1.0
once = False

i = 0
while i < len(args):
    if args[i] in ('-i', '--interval') and i + 1 < len(args):
        interval = float(args[i+1])
        i += 2
    elif args[i] in ('-1', '--once'):
        once = True
        i += 1
    else:
        i += 1

# ANSI escape codes
CLEAR = "\033[2J\033[H"
BOLD = "\033[1m"
DIM = "\033[2m"
RESET = "\033[0m"
GREEN = "\033[32m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
RED = "\033[31m"
MAGENTA = "\033[35m"
BLUE = "\033[34m"

def get_pid():
    if os.path.exists(pid_file):
        try:
            with open(pid_file) as f:
                return int(f.read().strip())
        except Exception:
            pass
    # Fallback to pgrep
    try:
        out = subprocess.check_output(["pgrep", "-f", "llama-server.*--port " + port]).decode().strip()
        lines = out.splitlines()
        if lines:
            return int(lines[0])
    except Exception:
        pass
    return None

def get_proc_stats(pid):
    if not pid:
        return None
    try:
        out = subprocess.check_output(["ps", "-o", "%cpu=,%mem=,rss=,etime=", "-p", str(pid)]).decode().strip()
        parts = out.split()
        if len(parts) >= 4:
            cpu_pct = float(parts[0])
            mem_pct = float(parts[1])
            rss_kb = int(parts[2])
            etime = parts[3]
            return {
                "cpu_pct": cpu_pct,
                "mem_pct": mem_pct,
                "rss_gb": rss_kb / (1024 * 1024),
                "etime": etime
            }
    except Exception:
        pass
    return None

def get_macmon_summary():
    try:
        proc = subprocess.Popen(["macmon", "pipe"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        line = proc.stdout.readline()
        proc.terminate()
        data = json.loads(line)
        gpu_power = data.get("gpu_power", 0.0)
        sys_power = data.get("sys_power", 0.0)
        gpu_usage = data.get("gpu_scaled_ratio", 0.0) * 100
        gpu_freq = data.get("gpu_freq_mhz", 0)
        cpu_temp = data.get("temp", {}).get("cpu_temp_avg", 0.0)
        gpu_temp = data.get("temp", {}).get("gpu_temp_avg", 0.0)
        return {
            "gpu_power": gpu_power,
            "sys_power": sys_power,
            "gpu_usage": gpu_usage,
            "gpu_freq": gpu_freq,
            "cpu_temp": cpu_temp,
            "gpu_temp": gpu_temp
        }
    except Exception:
        return None

def query_endpoint(path):
    url = f"http://{host}:{port}{path}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "qwen38-dashboard"})
        with urllib.request.urlopen(req, timeout=1.5) as r:
            return r.read()
    except Exception:
        return None

prev_decoded = {}
prev_time = time.time()

try:
    while True:
        current_time = time.time()
        dt = max(current_time - prev_time, 0.001)

        pid = get_pid()
        proc_stats = get_proc_stats(pid)
        hw_stats = get_macmon_summary()

        slots_raw = query_endpoint("/slots")
        slots = []
        if slots_raw:
            try:
                slots = json.loads(slots_raw.decode("utf-8"))
            except Exception:
                pass

        metrics_raw = query_endpoint("/metrics")
        metrics_dict = {}
        if metrics_raw:
            try:
                for line in metrics_raw.decode("utf-8").splitlines():
                    line = line.strip()
                    if line and not line.startswith("#"):
                        parts = line.split()
                        if len(parts) >= 2:
                            metrics_dict[parts[0]] = float(parts[1])
            except Exception:
                pass

        props_raw = query_endpoint("/props")
        model_alias = "qwen3.8-flash-next"
        build_info = "llama.cpp"
        if props_raw:
            try:
                props = json.loads(props_raw.decode("utf-8"))
                build_info = props.get("build_info", build_info)
            except Exception:
                pass

        # Render screen
        out = []
        if not once:
            out.append(CLEAR)

        # Header
        out.append(f"{BOLD}{CYAN}╔════════════════════════════════════════════════════════════════════════════════════╗{RESET}")
        out.append(f"{BOLD}{CYAN}║             QWEN3.8-FLASH-NEXT REAL-TIME TELEMETRY & METRICS DASHBOARD             ║{RESET}")
        out.append(f"{BOLD}{CYAN}╚════════════════════════════════════════════════════════════════════════════════════╝{RESET}")

        # Server info
        status_badge = f"{GREEN}● RUNNING{RESET}" if pid and slots_raw else f"{RED}● STOPPED{RESET}"
        out.append(f" {BOLD}Server Status:{RESET} {status_badge}  |  {BOLD}Endpoint:{RESET} http://{host}:{port}  |  {BOLD}Build:{RESET} {build_info}")

        if proc_stats:
            rss_str = f"{proc_stats['rss_gb']:.2f} GB"
            out.append(f" {BOLD}PID:{RESET} {pid}  |  {BOLD}Uptime:{RESET} {proc_stats['etime']}  |  {BOLD}Model RSS:{RESET} {YELLOW}{rss_str}{RESET} / 64 GB  |  {BOLD}CPU:{RESET} {proc_stats['cpu_pct']:.1f}%")
        else:
            out.append(f" {BOLD}PID:{RESET} {pid if pid else 'None'}  |  {BOLD}Model Memory:{RESET} N/A")

        if hw_stats:
            out.append(f" {BOLD}Apple Silicon:{RESET} GPU {YELLOW}{hw_stats['gpu_usage']:.1f}%{RESET} ({hw_stats['gpu_freq']} MHz) | "
                       f"GPU Power: {YELLOW}{hw_stats['gpu_power']:.1f}W{RESET} | "
                       f"Total SoC: {hw_stats['sys_power']:.1f}W | "
                       f"GPU Temp: {hw_stats['gpu_temp']:.0f}°C")

        out.append(f"{DIM}──────────────────────────────────────────────────────────────────────────────────────{RESET}")

        # Engine & Specs
        out.append(f" {BOLD}Architecture:{RESET} qwen4exp (125B MoE, ~6B active, DeltaNet + QSA)  |  {BOLD}Context:{RESET} {GREEN}204,800 tokens (200K){RESET}")
        out.append(f" {BOLD}Offload:{RESET} Metal (-ngl 99)  |  {BOLD}KV Cache:{RESET} Unified RAM  |  {BOLD}Speculative:{RESET} ngram-mod (self-spec)")

        out.append(f"{DIM}──────────────────────────────────────────────────────────────────────────────────────{RESET}")

        # Throughput & Speculative Metrics
        out.append(f"{BOLD} Throughput & Generation Telemetry:{RESET}")
        if metrics_dict:
            # Current bucket rates
            pred_tok_s = metrics_dict.get("llamacpp:predicted_tokens_seconds", 0.0)
            prompt_tok_s = metrics_dict.get("llamacpp:prompt_tokens_seconds", 0.0)
            
            # Cumulative totals
            total_pred = int(metrics_dict.get("llamacpp:tokens_predicted_total", 0))
            pred_sec = metrics_dict.get("llamacpp:tokens_predicted_seconds_total", 0.0)
            avg_pred_s = (total_pred / pred_sec) if pred_sec > 0 else pred_tok_s

            total_prompt = int(metrics_dict.get("llamacpp:prompt_tokens_total", 0))
            prompt_sec = metrics_dict.get("llamacpp:prompt_seconds_total", 0.0)
            avg_prompt_s = (total_prompt / prompt_sec) if prompt_sec > 0 else prompt_tok_s

            cached_prompt = int(metrics_dict.get("llamacpp:prompt_tokens_cached_total", 0))
            draft_accepted = metrics_dict.get("llamacpp:spec_decode_num_accepted_tokens_total", 0)
            draft_total = metrics_dict.get("llamacpp:spec_decode_num_draft_tokens_total", 0)
            draft_acc = (draft_accepted / draft_total * 100.0) if draft_total > 0 else 0.0

            out.append(f"  • Eval Speed:   {GREEN}{BOLD}{avg_pred_s:.2f} tok/s{RESET}  (Total Generated: {total_pred} tokens in {pred_sec:.1f}s)")
            out.append(f"  • Prompt Speed: {CYAN}{BOLD}{avg_prompt_s:.1f} tok/s{RESET}  (Total Prompt: {total_prompt} tokens, Cached: {cached_prompt})")
            if draft_total > 0:
                out.append(f"  • N-Gram Draft Acceptance: {MAGENTA}{BOLD}{draft_acc:.1f}%{RESET} ({int(draft_accepted)}/{int(draft_total)} drafts)")
            else:
                out.append(f"  • Speculative Decoding: {MAGENTA}{BOLD}ngram-mod (Active){RESET}")
        else:
            # Aggregate from slots
            active_slots = [s for s in slots if s.get("is_processing")]
            out.append(f"  • Active Generations: {len(active_slots)} / {len(slots)} slots")
            out.append(f"  • Metrics endpoint (`/metrics`): {DIM}Available with --metrics flag{RESET}")

        out.append(f"{DIM}──────────────────────────────────────────────────────────────────────────────────────{RESET}")

        # Slots Table
        out.append(f"{BOLD} Active Slots Table ({len(slots)} parallel slots):{RESET}")
        out.append(f"  {BOLD}{'Slot':<5} {'State':<12} {'Prompt':<10} {'Decoded':<10} {'Remaining':<10} {'Speed (tok/s)':<14} {'Context':<10}{RESET}")

        for s in slots:
            slot_id = s.get("id", 0)
            is_proc = s.get("is_processing", False)
            n_ctx = s.get("n_ctx", 204800)
            n_prompt = s.get("n_prompt_tokens", 0)
            
            # Decoded tokens
            next_tokens = s.get("next_token", [{}])
            n_decoded = next_tokens[0].get("n_decoded", 0) if next_tokens else 0
            n_remain = next_tokens[0].get("n_remain", 0) if next_tokens else 0

            # Delta tok/s per slot
            last_dec = prev_decoded.get(slot_id, n_decoded)
            speed = (n_decoded - last_dec) / dt if is_proc and n_decoded >= last_dec else 0.0
            prev_decoded[slot_id] = n_decoded

            state_str = f"{GREEN}BUSY{RESET}" if is_proc else f"{DIM}IDLE{RESET}"
            prompt_str = f"{n_prompt:,}" if n_prompt else "-"
            dec_str = f"{n_decoded:,}" if n_decoded else "-"
            rem_str = f"{n_remain:,}" if is_proc and n_remain >= 0 else "-"
            speed_str = f"{speed:.1f}" if is_proc else "-"
            ctx_pct = f"{(n_prompt + n_decoded) / n_ctx * 100:.2f}%" if (n_prompt or n_decoded) else "0.00%"

            out.append(f"  {slot_id:<5} {state_str:<21} {prompt_str:<10} {dec_str:<10} {rem_str:<10} {speed_str:<14} {ctx_pct:<10}")

        out.append(f"{DIM}──────────────────────────────────────────────────────────────────────────────────────{RESET}")
        out.append(f" {DIM}Web UI: http://127.0.0.1:{port}/  |  Press Ctrl+C to exit  |  Refresh: {interval}s{RESET}")

        print("\n".join(out), flush=True)

        if once:
            break

        prev_time = current_time
        time.sleep(interval)

except KeyboardInterrupt:
    print(f"\n{GREEN}Dashboard exited.{RESET}")
    sys.exit(0)
EOF
