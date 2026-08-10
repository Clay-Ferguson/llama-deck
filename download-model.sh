#!/usr/bin/env bash
#
# download-model.sh — Download a GGUF model for llama.cpp
#
# Downloads a quantized GGUF model from HuggingFace into
# ~/.local/share/llama.cpp/models/
#
set -euo pipefail

MODELS_DIR="$HOME/.local/share/llama.cpp/models"
mkdir -p "$MODELS_DIR"

# ── Model Selection ──────────────────────────────────────────────────────
# Pick ONE model from the menu below.
# All model files can coexist on disk — download each variant once.

echo "=== Select a Model to Download ==="
echo ""
echo "  1) Gemma 4 E2B              2.3B effective params (~3.1 GB)"
echo "  2) Gemma 4 E4B              4.5B effective params (~5.0 GB)"
echo "  3) Gemma 4 12B              12B params, dense (~7.1 GB)"
echo "  4) Gemma 4 12B QAT          12B params, dense (~6.7 GB)"
echo "  5) Gemma 4 26B-A4B          3.8B active params, MoE (~13.4 GB)"
echo "  6) Qwen3.6-35B-A3B          ~3B active params, MoE (~17.7 GB)"
echo "  7) Qwen3.6-35B-A3B Unc.     ~3B active params, MoE (~19.0 GB)"
echo "  8) Qwen3.6-35B Genesis Unc. ~3B active params, MoE (~17.4 GB)"
echo "  9) Muse Glimmer 30B         29.6B params, dense (~16.8 GB)"
echo ""
read -rp "Model [6]: " MODEL_CHOICE
echo ""

case "${MODEL_CHOICE:-6}" in
  1)
    # Gemma 4 E2B: 2.3B effective params (5.1B total with embeddings)
    MODEL_REPO="unsloth/gemma-4-E2B-it-GGUF"
    MODEL_FILE="gemma-4-E2B-it-Q4_K_M.gguf"
    MODEL_SIZE_HINT="~3.1 GB"
    ;;
  2)
    # Gemma 4 E4B: 4.5B effective params (8B total with embeddings)
    MODEL_REPO="unsloth/gemma-4-E4B-it-GGUF"
    MODEL_FILE="gemma-4-E4B-it-Q4_K_M.gguf"
    MODEL_SIZE_HINT="~5.0 GB"
    ;;
  3)
    # Gemma 4 12B (dense): 12B params
    MODEL_REPO="unsloth/gemma-4-12b-it-GGUF"
    MODEL_FILE="gemma-4-12b-it-Q4_K_M.gguf"
    MODEL_SIZE_HINT="~7.1 GB"
    ;;
  4)
    # Gemma 4 12B QAT (dense, Quantization-Aware Training): 12B params
    # Lower memory footprint (~7 GB total) and potentially faster than the
    # standard Q4_K_M 12B build, with accuracy close to the original BF16.
    MODEL_REPO="unsloth/gemma-4-12b-it-qat-GGUF"
    MODEL_FILE="gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"
    MODEL_SIZE_HINT="~6.7 GB"
    ;;
  5)
    # Gemma 4 26B-A4B (MoE): 3.8B active params (25.2B total)
    # A Mixture-of-Experts model: holds all 25.2B params in memory (~13.4 GB) but
    # only activates ~3.8B per token, so generation stays fast while quality is
    # high. A strong fit for unified-memory machines with plenty of RAM.
    MODEL_REPO="unsloth/gemma-4-26B-A4B-it-GGUF"
    MODEL_FILE="gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"
    MODEL_SIZE_HINT="~13.4 GB"
    ;;
  6)
    # Qwen3.6-35B-A3B (MoE): ~3B active params (35B total)
    # A Mixture-of-Experts model: all 35B params live in memory (~17.7 GB) but only
    # ~3B activate per token, so generation stays fast on bandwidth-limited unified
    # memory while quality rivals a flagship coder. IQ4_XS is preferred on the Arc
    # 140V iGPU to avoid the known k-quant crash (see model-research/Qwen).
    # IMPORTANT: This model scores *much* better on benchmarks than any of the above models.
    MODEL_REPO="unsloth/Qwen3.6-35B-A3B-GGUF"
    MODEL_FILE="Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
    MODEL_SIZE_HINT="~17.7 GB"
    ;;
  7)
    # Qwen3.6-35B-A3B Uncensored (HauhauCS "Aggressive"): ~3B active params (35B total)
    # A community fine-tune of the same Qwen3.6-35B-A3B MoE as option 6, with the
    # refusal behavior stripped out — the model card reports 0 refusals across its
    # 465-prompt test set. Architecture is unchanged (40 layers, 256 experts / 8
    # routed per token, 262K native context), so it runs with the same speed and
    # memory profile as option 6; only the alignment differs.
    # IQ4_XS again, for the same reason: it dodges the known k-quant crash on the
    # Arc 140V iGPU (see model-research/Qwen). This repo also publishes custom
    # "K_P" quants, but those are k-quants and so are exactly what to avoid here.
    # Slightly larger than option 6 (~19 GB vs ~17.7 GB) because this is a plain
    # IQ4_XS rather than an Unsloth "UD" dynamic quant.
    MODEL_REPO="HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive"
    MODEL_FILE="Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf"
    MODEL_SIZE_HINT="~19.0 GB"
    ;;
  8)
    # Qwen3.6-35B-A3B Uncensored "Genesis-Hermes V7" (LuffyTheFox): ~3B active (35B total)
    # A second-order fine-tune: it starts from option 7's HauhauCS "Aggressive"
    # uncensored weights, adds NousResearch hermes-function-calling-v1 data
    # (~2k blocks) for tool/agent use, then applies the author's "Genesis" pass —
    # a post-training tensor repair performed directly on the GGUF (rescaling
    # saturated weights, mean drift, and zero blocks) rather than a retrain.
    # The architecture is untouched from options 6 and 7: Qwen35MoE, 40 layers,
    # 256 experts (8 routed + 1 shared per token), 262K native context.
    #
    # WHICH FILE: the repo publishes five GGUFs, and on a 32 GB machine only two
    # are even candidates —
    #   APEX-Compact      17.4 GB  ← this one
    #   MTP-APEX-Compact  18.3 GB
    #   APEX              25.7 GB  leaves too little for the OS + KV cache
    #   MTP-APEX          26.6 GB  same problem
    #   Q8_K_P            43.6 GB  does not fit at all, and is a k-quant besides
    # The MTP builds carry an extra ~0.9 GB multi-token-prediction head, which
    # only pays off under speculative decoding — and that is measured as actively
    # *harmful* on this hardware (see SPEC in start-server.sh and
    # PERFORMANCE_TUNING.md), so the extra memory would buy nothing here. Hence
    # plain APEX-Compact, which is also the quant the model card recommends.
    #
    # CAUTION — NOT verified against the Arc 140V k-quant crash. Unlike options 6
    # and 7 there is no "IQ4_XS" in the filename to go on: the model card states
    # only that the quant is imatrix-based and never publishes APEX's per-tensor
    # GGML types. 17.4 GB across 34.7B params works out to ~4.0 bpw, a shade
    # below IQ4_XS (4.25 bpw), but that alone does not prove it is an IQ rather
    # than a K quant. Treat the first run as the experiment: if it crashes on the
    # Arc iGPU the way k-quants do (see model-research/Qwen), fall back to 6 or 7.
    #
    # Vision: this model is multimodal, but that requires the separate
    # mmproj-Hermes3.6-35B-A3B-Uncensored-Genesis-F16.gguf (899 MB) from the same
    # repo, loaded via --mmproj. Not fetched here — as with the multimodal Gemma
    # entries above, this script downloads text-only weights.
    MODEL_REPO="LuffyTheFox/Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V7-GGUF"
    MODEL_FILE="Hermes3.6-35B-A3B-Uncensored-Genesis-V7-APEX-Compact.gguf"
    MODEL_SIZE_HINT="~17.4 GB"
    ;;
  9)
    # Muse Glimmer 30B (dense): 29.6B params, 52 layers, GQA 32Q/2KV heads,
    # 131K+ native context. Unlike every MoE model above, this is a plain dense
    # transformer, so all ~29.6B params are read from memory on every token.
    #
    # WHICH FILE: the repo publishes two K-quant builds —
    #   kquant-17gb      16.8 GB  ← this one, sized by the model card for
    #                              24 GB-class hardware
    #   kquant-dynamic    19.7 GB  targets higher-VRAM platforms; more weight
    #                              for less headroom here, no upside on this box
    # Two more files in the repo are NOT fetched here, per instructions: the
    # ~1.4 GB mmproj-kquant.gguf (vision) and the ~1.63 GB dflash-kquant.gguf
    # (a speculative-decoding draft model — and see the SPEC block in
    # start-server.sh for why speculative decoding measures as harmful on this
    # hardware anyway).
    #
    # CAUTION #1 — no IQ-quant exists for this model. This repo ships K-quants
    # only. Options 6 and 7 above deliberately chose IQ4_XS specifically to
    # dodge the Arc 140V iGPU's known k-quant crash (see model-research/Qwen);
    # this model offers no such alternative to fall back to within this repo.
    # Treat the first launch as the test — if it crashes, there is no other
    # quant here to try instead.
    #
    # CAUTION #2 — dense, not MoE, so expect lower speed. Every model above
    # this one was chosen to be Mixture-of-Experts specifically because dense
    # models this large fail the bandwidth math worked out in
    # model-research/Qwen: that doc measured a dense 27B Qwen at an estimated
    # ~5-8 tok/s, under the 10 TPS floor targeted there. This 29.6B dense model
    # is in the same boat — added for completeness / quality-over-speed use,
    # not because it is expected to be fast.
    MODEL_REPO="meta-models/Muse-Glimmer-30B-GGUF"
    MODEL_FILE="muse-glimmer-30B-kquant-17gb.gguf"
    MODEL_SIZE_HINT="~16.8 GB"
    ;;
  *)
    echo "ERROR: Invalid selection '$MODEL_CHOICE'."
    exit 1
    ;;
esac
# ─────────────────────────────────────────────────────────────────────────

MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/main/${MODEL_FILE}"

DEST="$MODELS_DIR/$MODEL_FILE"

echo "=== Model Download ==="
echo ""
echo "  Repository: $MODEL_REPO"
echo "  File:       $MODEL_FILE"
echo "  Destination: $DEST"
echo ""

if [[ -f "$DEST" ]]; then
  FILE_SIZE=$(stat -c%s "$DEST" 2>/dev/null || stat -f%z "$DEST" 2>/dev/null)
  FILE_SIZE_GB=$(echo "scale=1; $FILE_SIZE / 1073741824" | bc 2>/dev/null || echo "?")
  echo "Model file already exists (${FILE_SIZE_GB} GB)."
  read -rp "Re-download? (y/N) " answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "Skipping download."
    exit 0
  fi
fi

echo "Downloading (${MODEL_SIZE_HINT}, this may take a while)..."
echo ""

# Use curl with resume support in case of interruption
curl -fSL --progress-bar -C - -o "$DEST" "$MODEL_URL"

echo ""
FILE_SIZE=$(stat -c%s "$DEST" 2>/dev/null || stat -f%z "$DEST" 2>/dev/null)
FILE_SIZE_GB=$(echo "scale=1; $FILE_SIZE / 1073741824" | bc 2>/dev/null || echo "?")
echo "=== Download Complete ==="
echo "  File: $DEST"
echo "  Size: ${FILE_SIZE_GB} GB"
echo ""
echo "Next step: run ./start-server.sh to start the llama.cpp server."
