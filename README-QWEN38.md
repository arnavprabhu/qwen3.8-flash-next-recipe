# Qwen3.8-Flash-Next Local Setup (Apple Silicon)

High-performance local deployment of **Qwen3.8-Flash-Next** on Apple Silicon using `llama.cpp`, Metal GPU acceleration, 200K binary context window (`204,800` tokens), and self-speculative n-gram decoding.

> [!IMPORTANT]
> **Hardware Requirement: 64 GB Unified Memory or Greater**
>
> This setup is designed specifically for Apple Silicon Macs equipped with **64 GB or more of Unified Memory** (e.g., M5 Pro, M4 Pro / Max, M3 Max, M2 Ultra, M1 Ultra):
>
> * **Model Resident Memory:** The AtomicChat IQ1_M / IQ4_XS (3.84bpw) mixed quantization requires **~45 GB** of resident memory for weights.
> * **200K Context KV Cache:** At a `204,800` token context window, the unified Metal KV cache allocates an additional **~6.4 GB**.
> * **Total Resident Footprint (RSS):** **~51.4 GB**, leaving ~12.6 GB of headroom for macOS, display framebuffers, and system processes.
> * **Smaller Memory Systems:** Running this configuration on Macs with **16 GB, 24 GB, 32 GB, or 36 GB** of Unified Memory will trigger immediate out-of-memory (OOM) kernel kills or severe swap thrashing. (If running on a smaller Mac, the context size and quantization would need drastic reduction).

---

## Architecture & Specifications

| Component | Specification |
|---|---|
| **Target Machine** | Apple Silicon Mac with 64 GB+ Unified Memory (M-series Pro / Max / Ultra) |
| **Model** | AtomicChat `Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64` |
| **Model Shards** | 28 GGUF shards (`00001-of-00028.gguf` to `00028-of-00028.gguf`, ~79 GB disk) |
| **Model ID / Alias** | `qwen3.8-flash-next` |
| **Total Parameters** | 176.94 Billion (125B MoE + 51.2B per-layer token embeddings) |
| **Quantization Profile** | Hybrid Mixed-Precision (Auto-Dequant 3.84 bpw average: Q5_1 / MXFP4 / IQ2_S / Q8_0 / IQ1_M) |
| **Architecture** | `qwen4exp` (125B MoE, ~6B active, Gated DeltaNet + QSA sparse attention + Hyper-Connections) |
| **Context Window** | **`204,800` tokens** (200K binary: $200 \times 1024$), architecture maximum `262,144` (256K) |
| **GPU Offload** | Apple Metal (`-ngl 99`, full layer offload) |
| **Attention** | Metal Flash Attention (`--flash-attn on`) |
| **Speculative Decoding** | Self-speculative n-gram matching (`--spec-type ngram-mod`) |
| **API Endpoint** | OpenAI-compatible at `http://127.0.0.1:9999/v1` |
| **Web UI** | Embedded SvelteKit interface at `http://127.0.0.1:9999/` |
| **Prometheus Metrics** | Real-time counters at `http://127.0.0.1:9999/metrics` |

---

## Step-by-Step Setup Guide (From Scratch)

Follow these steps to set up, build, and run the server on a fresh macOS environment with $\ge$ 64 GB RAM.

### Step 1: Install System Prerequisites

Open Terminal and ensure you have Xcode Command Line Tools and Homebrew installed:

```bash
# Install Xcode CLI tools (compiler, make, git)
xcode-select --install

# Install CMake and Python (via Homebrew)
brew install cmake git python@3.14

# (Recommended) Install macmon for Apple Silicon GPU & power telemetry
brew install macmon
```

### Step 2: Clone & Build `llama.cpp` with Apple Metal Support

Clone the official `llama.cpp` repository inside the project directory and compile it with Metal enabled:

```bash
# Clone this recipe repository and enter the directory
git clone https://github.com/arnavprabhu/qwen3.8-flash-next-recipe.git
cd qwen3.8-flash-next-recipe

# Clone llama.cpp inside the project directory
git clone https://github.com/ggerganov/llama.cpp.git

# Configure build with Metal GPU backend
cmake -B llama.cpp/build -S llama.cpp -DGGML_METAL=ON

# Build all binaries in Release mode using all available CPU cores
cmake --build llama.cpp/build --config Release -j$(sysctl -n hw.ncpu)
```

Verify that the server binary was created:
```bash
./llama.cpp/build/bin/llama-server --version
```

### Step 3: Download Model Weights (AtomicChat 28 Shards)

The model is hosted on Hugging Face as 28 split GGUF files totaling ~79 GB. Download them into `models/`:

```bash
# Create and activate a temporary Python environment for downloading
python3 -m venv .venv
source .venv/bin/activate
pip install huggingface_hub

# Download all 28 shards into models/
huggingface-cli download AtomicChat/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64 \
  --local-dir models/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64

deactivate
```

Verify that shard 1 exists:
```bash
ls -lh models/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64/Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64-00001-of-00028.gguf
```

### Step 4: Configure Environment Settings

Configuration defaults are maintained in [`.env.qwen38`](.env.qwen38) (template: [`.env.qwen38.example`](.env.qwen38.example)). If starting fresh:

```bash
cp .env.qwen38.example .env.qwen38
```

Key tuned parameters in `.env.qwen38`:
* `PORT="9999"`: Dedicated port for this server.
* `CTX_SIZE="204800"`: 200K binary context ($200 \times 1024$ tokens).
* `N_GPU_LAYERS="99"`: Full offload to Apple Silicon Metal GPU.
* `FIT="off"`: Prevents `llama.cpp` from silently downscaling context.
* `LOAD_MODE="mmap"`: Fast zero-copy memory mapping.
* `EXTRA_ARGS="--spec-type ngram-mod --metrics"`: Self-speculative decoding and Prometheus metrics.

### Step 5: Start the Server

Launch the daemonized background server:

```bash
./scripts/start-qwen38.sh
```

* Automatically checks for port conflicts.
* Pre-creates log files under `logs/qwen38.log`.
* Launches `llama-server` in the background and tracks PID in `logs/qwen38.pid`.
* Polls `http://127.0.0.1:9999/v1/models` until the server reports ready.

### Step 6: Verify Health & Status

Check the health and runtime details:

```bash
./scripts/status-qwen38.sh
```

Expected output:
```text
==============================================================
 Qwen3.8 Server Status
==============================================================
 Status:       RUNNING
 PID:          52753
 Port:         9999
 API Base URL: http://127.0.0.1:9999/v1
 Logs:         <project-root>/logs/qwen38.log

Testing http://127.0.0.1:9999/v1/models...
API Endpoint:  HEALTHY (200 OK)

Model Details (from http://127.0.0.1:9999/v1/models):
  - Model ID:       qwen3.8-flash-next
  - Context Size:   204800
  - Max Train Ctx:  262144
  - Quantization:   IQ1_M - 1.75 bpw
  - Parameters:     176943899520
==============================================================
```

### Step 7: Run a Test Chat Completion

Execute an end-to-end inference test:

```bash
./scripts/test-qwen38.sh
```

* Sends a query to `/v1/chat/completions`.
* Displays separate reasoning tokens (`<think>`) and answer content.
* Reports prompt processing speed (tok/s) and generation speed (tok/s).

### Step 8: Monitor Telemetry in Real-Time

Run the interactive TUI monitor:

```bash
./scripts/dashboard-qwen38.sh
```

Or open the Web UI in your browser at:
```text
http://127.0.0.1:9999/
```

### Step 9: Stop the Server

When finished, shut down cleanly:

```bash
./scripts/stop-qwen38.sh
```

* Sends `SIGTERM` to the server PID.
* Verifies port `9999` is released.
* Frees the ~51.4 GB unified RAM immediately.

---

## Management Scripts Overview

All scripts are located in `scripts/`:

| Script | Command | Purpose |
|---|---|---|
| **Start** | `./scripts/start-qwen38.sh` | Launches background server with Metal offload & polls for readiness |
| **Stop** | `./scripts/stop-qwen38.sh` | Safely terminates daemon and frees all unified memory |
| **Status** | `./scripts/status-qwen38.sh` | Queries `/v1/models` and prints runtime status |
| **Test** | `./scripts/test-qwen38.sh` | Benchmark chat completion with reasoning and tok/s metrics |
| **Dashboard** | `./scripts/dashboard-qwen38.sh` | Real-time terminal monitor for tok/s, slots, RAM, and GPU power |

---

## Telemetry & Live Dashboards

### 1. Interactive Terminal Dashboard (TUI)
```bash
# Live auto-refreshing monitor (1s refresh, Ctrl+C to exit)
./scripts/dashboard-qwen38.sh

# Single snapshot inspection
./scripts/dashboard-qwen38.sh --once
```

```text
╔════════════════════════════════════════════════════════════════════════════════════╗
║             QWEN3.8-FLASH-NEXT REAL-TIME TELEMETRY & METRICS DASHBOARD             ║
╚════════════════════════════════════════════════════════════════════════════════════╝
 Server Status: ● RUNNING  |  Endpoint: http://127.0.0.1:9999  |  Build: b11028-972d2313b
 PID: 52753  |  Uptime: 01:20  |  Model RSS: 51.40 GB / 64 GB  |  CPU: 1.5%
 Apple Silicon: GPU 1.8% (338 MHz) | GPU Power: 0.1W | Total SoC: 20.0W | GPU Temp: 48°C
──────────────────────────────────────────────────────────────────────────────────────
 Architecture: qwen4exp (125B MoE, ~6B active, DeltaNet + QSA)  |  Context: 204,800 tokens (200K)
 Offload: Metal (-ngl 99)  |  KV Cache: Unified RAM  |  Speculative: ngram-mod (self-spec)
──────────────────────────────────────────────────────────────────────────────────────
 Throughput & Generation Telemetry:
  • Eval Speed:   15.95 tok/s  (Total Generated: 213 tokens in 13.4s)
  • Prompt Speed: 457.5 tok/s  (Total Prompt: 12287 tokens, Cached: 0)
  • Speculative Decoding: ngram-mod (Active)
──────────────────────────────────────────────────────────────────────────────────────
 Active Slots Table (4 parallel slots):
  Slot  State        Prompt     Decoded    Remaining  Speed (tok/s)  Context   
  0     IDLE          -          -          -          -              0.00%     
  1     IDLE          -          -          -          -              0.00%     
  2     IDLE          282        -          -          -              0.14%     
  3     IDLE          12,217     -          -          -              5.97%     
──────────────────────────────────────────────────────────────────────────────────────
 Web UI: http://127.0.0.1:9999/  |  Press Ctrl+C to exit  |  Refresh: 1.0s
```

### 2. Built-in Web UI
Open in your browser:
```text
http://127.0.0.1:9999/
```
* Built directly into `llama-server`.
* Interactive chat with full reasoning trace toggling.
* Live tokens/sec meter and slot status view.

### 3. Prometheus Metrics Endpoint
```text
http://127.0.0.1:9999/metrics
```
Exposes standard Prometheus metrics:
* `llamacpp:predicted_tokens_seconds`
* `llamacpp:prompt_tokens_seconds`
* `llamacpp:tokens_predicted_total`
* `llamacpp:spec_decode_num_draft_tokens_total`
* `llamacpp:spec_decode_num_accepted_tokens_total`

### 4. Hardware Telemetry (`macmon`)
Run in a separate terminal:
```bash
macmon
```
Displays Apple Silicon GPU wattage, memory bandwidth (GB/s), core frequencies, and temperatures.

---

## Hybrid Mixed-Precision Quantization (Auto-Dequant 3.84 bpw)

This model is **not a pure 1-bit quantization**. It utilizes AtomicChat's **Auto-Dequant (AD)** mixed-precision strategy, which calibrates different layer types using an importance matrix (`imatrix`) to achieve an average precision of **3.84 bits per weight (bpw)** across 176.94 billion parameters:

### Exact Parameter Breakdown Across All 28 Shards

| Quantization Type | Nominal Precision | Parameters (Elements) | Share | Layers Used For |
|---|---|---|---|---|
| **`Q5_1`** | **5.5 bpw** | **51.20 Billion** | 28.9% | Per-layer token embeddings (`per_layer_token_embd`) |
| **`MXFP4`** | **4.25 bpw** | **40.27 Billion** | 22.8% | MoE expert down-projections (`ffn_down_exps`) |
| **`IQ2_S`** | **2.5 bpw** | **20.13 Billion** | 11.4% | MoE expert gate/up projections (`ffn_gate_exps`, `ffn_up_exps`) |
| **`Q8_0`** | **8.5 bpw** | **4.86 Billion** | 2.7% | Output projections, normalization, and attention routing |
| **`IQ1_M`** | **1.75 bpw** | **60.40 Billion** | 34.1% | Large-capacity MoE expert feed-forward weights |
| **`F32` / `BF16`** | **32 / 16 bit** | **0.09 Billion** | <0.1% | Layer norms, biases, hyper-connection scalars |
| **Total** | **~3.84 bpw (avg)** | **176.94 Billion** | **100%** | **~79 GB on disk / ~45 GB resident RAM** |

### Why `/v1/models` and `llama.cpp` report `IQ1_M - 1.75 bpw`

In the GGUF specification, the file header contains a single integer field called `general.file_type`. For this model, `general.file_type = 31`, which maps to `LLAMA_FTYPE_MOSTLY_IQ1_M` in `llama.cpp`. Because GGUF does not have a single standard enum for custom mixed-precision profiles, `llama.cpp` labels the file by its base quantization tier (`IQ1_M`), even though higher-precision quants (Q5_1, MXFP4, IQ2_S, Q8_0) compose over 65% of the model's weights.

### Quality & Memory Trade-offs

* **Avoids 1-Bit Perplexity Collapse:** Pure 1-bit models suffer severe perplexity degradation on attention matrices and embeddings. Preserving embeddings at 5-bit (`Q5_1`) and attention/output heads at 8-bit (`Q8_0`) maintains high semantic coherence and reasoning quality.
* **Fits 64 GB Unified Memory:** A full FP16 model (176B) would require >350 GB VRAM. A 4-bit model requires ~90 GB VRAM. The 3.84 bpw hybrid profile fits the model into **~45 GB** of resident RAM, leaving room for a **200K token KV cache (~6.4 GB)** inside a 64 GB Apple Silicon system.

---

## Speculative Decoding Architecture

* **Active Setting:** `--spec-type ngram-mod`
* **Mechanism:** Self-speculative n-gram decoding generates speculative token proposals by matching recurring sub-sequences directly from prompt and output tokens.
* **Overhead:** **0 MB additional VRAM**, no secondary draft model required.
* **Why not MTP or DFlash?**
  * **MTP (Multi-Token Prediction):** The conversion script (`conversion/qwen4exp.py`) explicitly excluded MTP layers during quantization (`supports_mtp_export = False`), and `llama.cpp` does not have an MTP computation graph for `qwen4exp`.
  * **DFlash:** DFlash checkpoints currently only exist as unquantized PyTorch checkpoints for NVIDIA vLLM, not GGUF or Metal.
  * Self-speculative n-gram decoding is the optimal zero-overhead speedup for `qwen4exp` on Apple Silicon.

---

## OpenAI-Compatible API Usage

Base URL: `http://127.0.0.1:9999/v1`

### 1. cURL Example

```bash
curl -s http://127.0.0.1:9999/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.8-flash-next",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain how Apple Silicon unified memory accelerates local LLMs in two sentences."}
    ],
    "temperature": 1.0,
    "top_p": 0.95,
    "max_tokens": 512
  }' | jq .
```

### 2. Python SDK Example

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:9999/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="qwen3.8-flash-next",
    messages=[
        {"role": "system", "content": "You are a concise expert engineer."},
        {"role": "user", "content": "What are the advantages of DeltaNet linear attention?"}
    ],
    temperature=1.0,
    top_p=0.95,
    max_tokens=512,
    stream=True
)

for chunk in response:
    content = chunk.choices[0].delta.content or ""
    print(content, end="", flush=True)
print()
```

### 3. Open WebUI (Docker)

```bash
docker run -d -p 3000:8080 \
  -e OPENAI_API_BASE_URL=http://host.docker.internal:9999/v1 \
  -e OPENAI_API_KEY=not-needed \
  -v open-webui:/app/backend/data \
  --name open-webui \
  ghcr.io/open-webui/open-webui:main
```
Open `http://localhost:3000` to chat.

---

## Directory Structure

```text
qwen3.8-flash-next-recipe/
├── .env.qwen38                   # Active server configuration
├── .env.qwen38.example           # Configuration template
├── .gitignore                    # Excludes models/, llama.cpp/, logs/
├── README-QWEN38.md              # Complete guide & documentation
├── README.md                     # Symlink to README-QWEN38.md
├── scripts/
│   ├── start-qwen38.sh           # Background launcher & readiness waiter
│   ├── stop-qwen38.sh            # Safe shutdown script
│   ├── status-qwen38.sh          # Model health & info reporter
│   ├── test-qwen38.sh            # Benchmark chat completion test
│   └── dashboard-qwen38.sh       # Live terminal TUI & telemetry dashboard
├── logs/
│   ├── qwen38.log                # llama-server stdout & stderr log
│   └── qwen38.pid                # Server PID tracker
├── models/
│   └── Qwen3.8-Flash-Next-AD-3.84bpw-IQ4_XS-M64/  # 28 GGUF shards (~79 GB)
└── llama.cpp/                    # Cloned & compiled llama.cpp engine
```
