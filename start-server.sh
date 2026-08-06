#!/usr/bin/env bash
#
# start-server.sh — Launch llama-server with a local GGUF model
#
# Starts the llama.cpp HTTP server on localhost:8080 with an
# OpenAI-compatible API. MkBrowser connects to this endpoint
# when using a LLAMACPP provider model.
#
# Usage:
#   ./start-server.sh              # Start with defaults (reasoning off)
#   ./start-server.sh on           # Start with reasoning on
#   ./start-server.sh off          # Start with reasoning off
#   ./start-server.sh on --port 9090  # reasoning on + override port
#
# Backend (CPU vs GPU) is chosen via the BACKEND env var (default "gpu"):
#   ./start-server.sh                    # run on the Intel Arc iGPU (Vulkan)
#   BACKEND=cpu ./start-server.sh        # run on the CPU cores instead
#   BACKEND=cpu ./start-server.sh on     # CPU + reasoning on
# (The default GPU mode requires ./setup-with-vulkan.sh to have been run first;
#  ./setup.sh alone installs only the CPU build.)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── Reasoning Mode ───────────────────────────────────────────────────────
# Optional first argument: "on" or "off" (controls --reasoning). Defaults
# to "off". MkBrowser passes "on" when Agentic Mode is enabled.
REASONING="off"
if [[ "${1:-}" == "on" || "${1:-}" == "off" ]]; then
  REASONING="$1"
  shift
fi
# ─────────────────────────────────────────────────────────────────────────

MODELS_DIR="$HOME/.local/share/llama.cpp/models"

# ── Backend Selection: CPU vs GPU (Vulkan / Intel Arc) ───────────────────
# Choose which llama.cpp build to launch:
#   "cpu" → the CPU-only build installed by ./setup.sh
#   "gpu" → the Vulkan build installed by ./setup-with-vulkan.sh, which offloads
#           the model to the Intel Arc iGPU (adds --n-gpu-layers). This is the
#           default, so ./setup-with-vulkan.sh must have been run.
# The two builds live in separate directories with separate binaries, so the
# CPU setup is never disturbed. Change the default by editing BACKEND below, or
# override per-run without editing this file:  BACKEND=cpu ./start-server.sh
BACKEND="${BACKEND:-gpu}"

# Layers to offload to the GPU in "gpu" mode. 99 = offload all layers.
NGL="${NGL:-99}"

# ── Speculative Decoding (optional) ──────────────────────────────────────
# SPEC selects a llama.cpp speculative-decoding type (--spec-type). Default
# "off" changes nothing. The ngram-* types are self-speculative (no draft
# model, no extra download) and mainly help rewrite/edit-style tasks where
# the output repeats long runs of the input. See README § Speculative
# Decoding for what applies (and doesn't) on this hardware.
#   SPEC=ngram-simple ./start-server.sh   # rewriting-oriented defaults
#   SPEC=ngram-mod ./start-server.sh      # constant-memory variant
# Any other --spec-type value is passed through as-is.
# NOTE: For the hardware mentioned in README (Dell XPS Laptop) 
#       speculative decoding is actually harmful to performance
#       so leaving it off is the correct and the default option here
#       for that particular hardware.
SPEC="${SPEC:-off}"

SPEC_ARGS=()
case "$SPEC" in
  off) ;;
  ngram-simple)
    SPEC_ARGS=(--spec-type ngram-simple --spec-draft-n-max 64)
    ;;
  ngram-mod)
    SPEC_ARGS=(--spec-type ngram-mod
               --spec-ngram-mod-n-match 24
               --spec-ngram-mod-n-min 48
               --spec-ngram-mod-n-max 64)
    ;;
  *)
    SPEC_ARGS=(--spec-type "$SPEC")
    ;;
esac

case "$BACKEND" in
  cpu)
    LIB_DIR="$HOME/.local/lib/llama.cpp"
    SERVER_BIN="$LIB_DIR/llama-server"
    GPU_ARGS=()
    ;;
  gpu)
    LIB_DIR="$HOME/.local/lib/llama.cpp-vulkan"
    SERVER_BIN="$LIB_DIR/llama-server"
    GPU_ARGS=(--n-gpu-layers "$NGL")
    ;;
  *)
    echo "ERROR: Unknown BACKEND='$BACKEND' (expected 'cpu' or 'gpu')."
    exit 1
    ;;
esac
# ─────────────────────────────────────────────────────────────────────────

# ── Model Selection ──────────────────────────────────────────────────────
# Pick ONE model from the menu below.
#
# Defaults below apply to any block that does not set them. Per-model blocks may
# override FA (flash-attention on/off) and BATCH (prefill batch size, -b):
#   FA    — flash-attention on/off; stable on the Arc 140V iGPU for both the
#           Gemma and Qwen builds. It is an EXACT algorithm, not an
#           approximation: it tiles attention and uses an online softmax to
#           avoid materializing the N×N score matrix, giving the same result as
#           the naive path up to floating-point rounding. So it costs no model
#           quality, and it is the prerequisite for KV-cache quantization
#           (--cache-type-k/v). Its benefit is invisible at short context and
#           grows with N, so only a long prompt can measure it:
#             FA=off ./start-server.sh   # then ./benchmark.sh -f README.md -n 100
#   BATCH — empty uses the llama.cpp default; "256" improves A3B prefill on Vulkan.
# Both are env-overridable for benchmark sweeps; a per-model block below may
# still override either one for that specific model.
FA="${FA:-on}"
BATCH="${BATCH:-}"

# MODEL_ARGS — extra llama-server flags that one specific model requires in order
# to work correctly at all (as opposed to FA/BATCH, which are tuning). Empty for
# every model that needs nothing special; a per-model block below may set it.
# These are appended before the caller's own CLI arguments, so anything you pass
# on the command line still wins.
MODEL_ARGS=()

echo "=== Select a Model ==="
echo ""
echo "  1) Gemma 4 E2B              2.3B effective params (~3.1 GB)"
echo "  2) Gemma 4 E4B              4.5B effective params (~5.0 GB)"
echo "  3) Gemma 4 12B              12B params, dense (~7.1 GB)"
echo "  4) Gemma 4 12B QAT          12B params, dense (~6.7 GB)"
echo "  5) Gemma 4 26B-A4B          3.8B active params, MoE (~13.4 GB)"
echo "  6) Qwen3.6-35B-A3B          ~3B active params, MoE (~17.7 GB)"
echo "  7) Qwen3.6-35B-A3B Unc.     ~3B active params, MoE (~19.0 GB)"
echo "  8) Qwen3.6-35B Genesis Unc. ~3B active params, MoE (~17.4 GB)"
echo ""
read -rp "Model [6]: " MODEL_CHOICE
echo ""

case "${MODEL_CHOICE:-6}" in
  1)
    # Gemma 4 E2B: 2.3B effective params (~3.1 GB)
    MODEL_FILE="gemma-4-E2B-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  2)
    # Gemma 4 E4B: 4.5B effective params (~5.0 GB)
    MODEL_FILE="gemma-4-E4B-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  3)
    # Gemma 4 12B (dense): 12B params (~7.1 GB)
    MODEL_FILE="gemma-4-12b-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  4)
    # Gemma 4 12B QAT (dense, Quantization-Aware Training): 12B params (~6.7 GB)
    # Lower memory footprint (~7 GB total) and potentially faster than the
    # standard Q4_K_M 12B build, with accuracy close to the original BF16.
    # In other words, this QAT model is "smarter" (better answers/inference) than
    # the non-QAT model above, but runs in about the same memory.
    MODEL_FILE="gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"
    CTX_SIZE="16384"
    ;;
  5)
    # Gemma 4 26B-A4B (MoE): 3.8B active params (~13.4 GB)
    # Mixture-of-Experts: all 25.2B params live in memory but only ~3.8B activate
    # per token, so generation stays fast while quality is higher than the 12B.
    # Context kept at 8192 to leave memory headroom alongside the larger weights,
    # although there is reason to believe 16384 will alwo work on my hardware.
    MODEL_FILE="gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"
    CTX_SIZE="8192"
    ;;
  6)
    # Qwen3.6-35B-A3B (MoE): ~3B active params (~17.7 GB)
    # Mixture-of-Experts: all 35B params live in memory but only ~3B activate per
    # token, so generation stays fast on bandwidth-limited unified memory while
    # quality rivals a flagship coder. IQ4_XS avoids the known k-quant crash on the
    # Arc 140V iGPU, and a small prefill batch is the recommended Arc workaround
    # (see model-research/Qwen).
    MODEL_FILE="Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
    CTX_SIZE="16384"
    BATCH="256"
    ;;
  7)
    # Qwen3.6-35B-A3B Uncensored (HauhauCS "Aggressive"): ~3B active params (~19.0 GB)
    # Same Qwen3.6-35B-A3B MoE as option 6, fine-tuned to remove refusals; the
    # architecture is identical, so every tuning decision below carries over:
    # IQ4_XS to avoid the Arc 140V k-quant crash, and -b 256 as the recommended
    # Arc prefill workaround for A3B models (see model-research/Qwen).
    # Context stays at 16384 for the same reason as option 6 — the weights are
    # ~1.3 GB larger here, so there is if anything slightly less headroom in 32 GB.
    # NOTE: the model card recommends running with --jinja so llama.cpp picks up
    # this fine-tune's chat template. This script does not pass it by default;
    # append it at launch if you need it:  ./start-server.sh --jinja
    MODEL_FILE="Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf"
    CTX_SIZE="16384"
    BATCH="256"
    ;;
  8)
    # Qwen3.6-35B-A3B Uncensored "Genesis-Hermes V7" (~17.4 GB)
    # Option 7's uncensored weights plus Hermes function-calling data and the
    # author's "Genesis" tensor-repair pass. The Qwen35MoE architecture is
    # identical to options 6 and 7, so their tuning carries over unchanged:
    # -b 256, the recommended Arc prefill workaround for A3B models on Vulkan
    # (see model-research/Qwen).
    #
    # --jinja is REQUIRED for this model, not merely suggested as it is for
    # option 7 — which is why this is the first branch to set MODEL_ARGS. It is
    # an agent / tool-calling fine-tune shipping its own chat_template.jinja, and
    # without --jinja llama.cpp substitutes a built-in approximation of the
    # template, breaking function calls and reasoning-block parsing (the same
    # point PERFORMANCE_TUNING.md raises about --jinja generally).
    #
    # CTX_SIZE is a knowing compromise. The model card asks for 128K+ context to
    # keep its thinking mode intact, but 128K of KV cache is far past what is
    # left of 32 GB once ~17.4 GB of weights are resident. 16384 matches the
    # other A3B entries and is what actually runs; long-form reasoning pays for
    # it. Quantizing the KV cache is the lever that could buy more here — see
    # PERFORMANCE_TUNING.md item 2.
    #
    # See download-model.sh option 8 for why this quant was chosen, including the
    # caveat that APEX's GGML tensor types are undocumented — so unlike options 6
    # and 7 this file is NOT confirmed to dodge the Arc 140V k-quant crash.
    MODEL_FILE="Hermes3.6-35B-A3B-Uncensored-Genesis-V7-APEX-Compact.gguf"
    CTX_SIZE="16384"
    BATCH="256"
    MODEL_ARGS=(--jinja)
    ;;
  *)
    echo "ERROR: Invalid selection '$MODEL_CHOICE'."
    exit 1
    ;;
esac
# ─────────────────────────────────────────────────────────────────────────

# ── Server Configuration ─────────────────────────────────────────────────
HOST="127.0.0.1"
PORT="8080"
# ─────────────────────────────────────────────────────────────────────────

MODEL_PATH="$MODELS_DIR/$MODEL_FILE"

# Allow CLI overrides (e.g., --port 9090)
EXTRA_ARGS=("$@")

# A --port override in EXTRA_ARGS wins over the PORT set above; track the
# effective port so the bind check and the banner report where we'll really be.
for ((i = 0; i < ${#EXTRA_ARGS[@]}; i++)); do
  if [[ "${EXTRA_ARGS[i]}" == "--port" && -n "${EXTRA_ARGS[i + 1]:-}" ]]; then
    PORT="${EXTRA_ARGS[i + 1]}"
  fi
done

# Verify prerequisites
if [[ ! -x "$SERVER_BIN" ]]; then
  if [[ "$BACKEND" == "gpu" ]]; then
    echo "ERROR: Vulkan build not found at $SERVER_BIN."
    echo "Run ./setup-with-vulkan.sh first."
  else
    echo "ERROR: llama-server not found at $SERVER_BIN."
    echo "Run ./setup.sh first."
  fi
  exit 1
fi

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "ERROR: Model not found at $MODEL_PATH"
  echo "Run ./download-model.sh first."
  exit 1
fi

# ── Port Pre-flight Check ────────────────────────────────────────────────
# llama-server only discovers a taken port *after* it has loaded the model and
# printed a startup banner, so a duplicate launch looks like a mysterious crash
# ("couldn't bind HTTP server socket") rather than "it's already running".
# Catch it here instead, before we print anything that looks like success — and
# crucially before the PID file is written, so a rejected launch cannot clobber
# the PID of the server that is already running.
#
# Unlike status.sh / stop-server.sh, this check is a convenience rather than a
# safety guard: if `ss` is unavailable (non-Linux), skip it and let llama.cpp
# report the bind failure itself rather than refusing to start at all.
# shellcheck source=server-lib.sh
source "$SCRIPT_DIR/server-lib.sh"

if command -v ss >/dev/null 2>&1 && llama_port_listening "$HOST" "$PORT"; then
  echo "ERROR: ${HOST}:${PORT} is already in use — not starting a second server."
  echo ""

  if curl -sf -m 5 "http://${HOST}:${PORT}/health" >/dev/null 2>&1; then
    echo "  A healthy llama-server is already listening there. To use it, set the"
    echo "  llama.cpp Base URL in MkBrowser Settings to:"
    echo "    http://localhost:${PORT}/v1"
    echo ""
    echo "  ./status.sh      # model, slots, and a test inference"
    echo "  ./stop-server.sh # stop it, then re-run this script to restart"
  else
    echo "  Something is listening on that port but it is not answering /health,"
    echo "  so it may be a different program or a wedged server:"
    ss -tlnp 2>/dev/null | grep -E "[[:space:]]${HOST}:${PORT}[[:space:]]" | sed 's/^/    /'
    echo ""
    echo "  Stop it (./stop-server.sh if it is llama-server), or start this one on"
    echo "  another port:  ./start-server.sh --port 8081"
  fi
  exit 1
fi
# ─────────────────────────────────────────────────────────────────────────

# Ensure shared libraries are findable
export LD_LIBRARY_PATH="$LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ── Thread Tuning ────────────────────────────────────────────────────────
# For the Intel Core Ultra 9 288V (Lunar Lake): 8 cores, no hyperthreading =
# 4 fast P-cores + 4 low-power E-cores.
#   --threads 4        Token generation is memory-bandwidth-bound, and the 4
#                      P-cores nearly saturate the LPDDR5X bandwidth on their
#                      own. Including the slower E-cores tends to gate each
#                      token (every token waits on the slowest thread) and
#                      hurts laptop responsiveness, so we pin generation to 4.
#   --threads-batch 8  Prompt ingestion (prefill) is compute-bound rather than
#                      bandwidth-bound, so it benefits from all 8 cores.
#
# Both are overridable from the environment so they can be swept against
# ./benchmark.sh without editing this file:
#   THREADS=1 ./start-server.sh
#   THREADS=2 THREADS_BATCH=8 ./start-server.sh
#
# WHY FEWER THREADS MAY BE FASTER IN GPU MODE: the defaults above are reasoned
# entirely as *CPU inference* tuning, and they are right for BACKEND=cpu. But
# with BACKEND=gpu and -ngl 99 the whole model lives on the Arc iGPU, and those
# CPU threads spend most of their time spin-waiting on GPU completion. On this
# machine that is not free:
#   - The CPU cores and the iGPU share one package power budget, so cores
#     busy-waiting burn watts that would otherwise clock the GPU higher.
#   - They share the same LPDDR5X bus, so spinning threads add memory traffic
#     alongside the GPU that is already trying to saturate it.
# So in GPU mode, fewer generation threads is often *faster*. Worth measuring.
THREADS="${THREADS:-4}"
THREADS_BATCH="${THREADS_BATCH:-8}"
# ─────────────────────────────────────────────────────────────────────────

echo "=== Starting llama.cpp Server ==="
echo ""
if [[ "$BACKEND" == "gpu" ]]; then
  echo "  Backend:      gpu (Vulkan / Intel Arc, --n-gpu-layers $NGL)"
else
  echo "  Backend:      cpu"
fi
echo "  Model:        $MODEL_FILE"
echo "  Context size: $CTX_SIZE"
echo "  Flash-attn:   $FA"
echo "  Prefill batch: ${BATCH:-default}"
echo "  Threads:      $THREADS gen / $THREADS_BATCH batch"
echo "  Spec decoding: $SPEC"
echo "  Model flags:  ${MODEL_ARGS[*]:-none}"
echo "  Endpoint:     http://${HOST}:${PORT}"
echo "  API (OpenAI): http://${HOST}:${PORT}/v1"
echo ""
echo "  In MkBrowser Settings, set the llama.cpp Base URL to:"
echo "  http://localhost:${PORT}/v1"
echo ""
echo "Press Ctrl+C to stop the server."
echo ""

# Write PID file so stop-server.sh (and MkBrowser) can find us.
# exec replaces this shell, so $$ will be the llama-server PID.
#
# This is a hint, not the source of truth: stop-server.sh prefers the listening
# socket's owning PID and only falls back to this file. See server-lib.sh.
echo $$ > "$LLAMA_PID_FILE"

# Optional prefill batch size (-b); empty BATCH leaves the llama.cpp default.
BATCH_ARGS=()
[[ -n "$BATCH" ]] && BATCH_ARGS=(-b "$BATCH")

exec "$SERVER_BIN" \
  --model "$MODEL_PATH" \
  --host "$HOST" \
  --port "$PORT" \
  --sleep-idle-seconds 300 \
  --ctx-size "$CTX_SIZE" \
  -fa "$FA" \
  "${BATCH_ARGS[@]}" \
  --threads "$THREADS" \
  --threads-batch "$THREADS_BATCH" \
  "${GPU_ARGS[@]}" \
  "${SPEC_ARGS[@]}" \
  --reasoning "$REASONING" \
  "${MODEL_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"
