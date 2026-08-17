#!/usr/bin/env bash
#
# start-server.sh — Launch llama-server with a local GGUF model
#
# Starts the llama.cpp HTTP server on localhost:8080 with an OpenAI-compatible
# API, which any client speaking that protocol can point at.
#
# Usage:
#   ./start-server.sh              # Start; menus ask for model, reasoning, sampling
#   ./start-server.sh --port 9090  # same, overriding a llama-server flag
#
# Every argument is passed straight through to llama-server, so anything in
# `llama-server --help` can be overridden on the command line.
#
# After the model menu you are asked two more questions: how much reasoning
# (thinking) the model should do, and which sampling mode to use (creative vs
# factual). Answer either up front to run unattended:
#   REASONING=off SAMPLING=factual ./start-server.sh
#   REASONING=low ./start-server.sh     # effort level, where the model has them
#
# Models may live in more than one place: those fetched by ./download-model.sh,
# and those downloaded through LM Studio. Every entry in the menu carries its own
# full path, so both work identically — see the Model Locations block below.
#
# Backend (CPU vs GPU) is chosen via the BACKEND env var (default "gpu"):
#   ./start-server.sh                    # run on the Intel Arc iGPU (Vulkan)
#   BACKEND=cpu ./start-server.sh        # run on the CPU cores instead
#   BACKEND=cpu REASONING=on ./start-server.sh   # CPU + reasoning on
# (The default GPU mode requires ./setup-with-vulkan.sh to have been run first;
#  ./setup.sh alone installs only the CPU build.)
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ── Reasoning Mode: the answer is collected below, not here ──────────────
# Reasoning is chosen from a menu shown AFTER the model menu, because what can be
# asked depends on which model was picked — see the Reasoning Mode block further
# down for the whole story.
#
# All that happens here is picking up an answer from the environment so the menu
# can be skipped, which is what makes the script usable non-interactively. This
# matches SAMPLING's pattern exactly:
#   REASONING=low ./start-server.sh
REASONING_CHOICE="${REASONING:-}"
# ─────────────────────────────────────────────────────────────────────────

# ── Model Locations ──────────────────────────────────────────────────────
# There is no single models directory anymore. Each entry in the menu below
# sets its own full MODEL_PATH, so a model can live in either tree — or
# anywhere else, by writing a literal absolute path in its branch.
#
# llama-server accepts any path for --model; unlike LM Studio it has no
# opinion about directory layout. That is what makes this work at all.
#
#   LLAMA_MODELS — where download-model.sh puts things (flat: one .gguf each)
#   LMS_MODELS   — LM Studio's tree, which nests as <publisher>/<repo>/<file>.gguf
#
# These two are conveniences, not a rule: they exist so that relocating a whole
# tree is a one-line edit rather than one per model. LM Studio's folder in
# particular is user-relocatable from its GUI (it is "downloadsFolder" in
# ~/.lmstudio/settings.json), so if you move it there, change it here too — or
# override without editing this file:  LMS_MODELS=/mnt/big/models ./start-server.sh
LLAMA_MODELS="${LLAMA_MODELS:-$HOME/.local/share/llama.cpp/models}"
LMS_MODELS="${LMS_MODELS:-$HOME/.lmstudio/models}"
# ─────────────────────────────────────────────────────────────────────────

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
# the output repeats long runs of the input.
#   SPEC=ngram-simple ./start-server.sh   # rewriting-oriented defaults
#   SPEC=ngram-mod ./start-server.sh      # constant-memory variant
#   SPEC=draft-mtp ./start-server.sh      # use a model's built-in MTP head
# Any other --spec-type value is passed through as-is.
#
# WHETHER THIS HELPS DEPENDS ON THE MODEL, NOT ON THE HARDWARE. An earlier
# note here said speculative decoding is simply harmful on this laptop. That
# is true for the A3B MoE models (options 6-8) and false in general, and the
# distinction is worth stating because it is what decides the setting:
#
#   MoE (options 6-8): only ~3B of 35B params are read per token. Verifying k
#     drafted tokens in one batch activates the *union* of those tokens'
#     experts, so the step reads MORE weight than k separate steps would. The
#     draft has to be nearly always right just to break even. It usually isn't.
#   Dense (options 9, 10): every param is read every token — ~17 GB against
#     ~136 GB/s of LPDDR5X, which is the ~5-8 tok/s ceiling those options warn
#     about. Verifying k drafted tokens reads that 17 GB exactly ONCE, so every
#     accepted token is a whole weight-read saved. Here it is the single
#     largest lever available.
#
# So this stays "off" as the global default (it is right for the default model
# and every MoE entry), and a per-model branch turns it on where the economics
# invert — see option 10.
#
# Unlike FA and BATCH, an explicit SPEC= in the environment WINS over a
# per-model branch. That is deliberate: it is what lets you A/B a branch's
# choice (`SPEC=off ./start-server.sh`) without editing this file.
# A branch may therefore assign SPEC unconditionally; the value from the
# environment is stashed here and reinstated after the menu.
SPEC_ENV="${SPEC:-}"
SPEC="${SPEC:-off}"
# NOTE: SPEC is translated into SPEC_ARGS *below the model menu*, not here, so
# that a per-model branch has a chance to set it first.

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
#           grows with N, so it only shows up on long prompts:
#             FA=off ./start-server.sh
#   BATCH — empty uses the llama.cpp default; "256" improves A3B prefill on Vulkan.
# Both are env-overridable; a per-model block below may still override either
# one for that specific model.
FA="${FA:-on}"
BATCH="${BATCH:-}"

# REASONING_EFFORTS — which named reasoning/thinking *levels* this model's own
# chat template understands, as a space-separated list. Empty (the default) means
# the model only knows thinking on vs. off, which is the case for every entry
# here except option 10. It is NOT env-overridable on purpose: it is a fact about
# the GGUF's embedded template, not a preference, and claiming a level a template
# does not implement would only get you a jinja exception at request time.
# See the Reasoning Mode block below the menu for how to read it out of a model.
REASONING_EFFORTS=""

# MODEL_ARGS — extra llama-server flags applied to every model, plus any a single
# model requires in order to work correctly at all (as opposed to FA/BATCH, which
# are tuning). A per-model block below may append to it.
# These are appended before the caller's own CLI arguments, so anything you pass
# on the command line still wins.
#
# --jinja makes llama.cpp use each GGUF's own embedded chat template rather than a
# built-in approximation of it. That is what drives tool/function calling and
# reasoning-block parsing, and every model in the menu below ships a real template
# (7K-17K chars, all of them containing tool-calling logic).
#
# IMPORTANT: on the pinned build (b10355) jinja is ALREADY llama.cpp's default —
# `--jinja, --no-jinja ... (default: enabled)`. So this flag changes nothing today;
# it is passed explicitly to *pin* the behavior, for the same reason LLAMA_TAG is
# pinned: a default that flipped on once can flip back on some unrelated Tuesday.
# It costs nothing and it makes the intent visible in the startup banner.
#
# To test a model against llama.cpp's built-in template instead, pass the negation
# on the command line (it wins, being appended later):
#   ./start-server.sh --no-jinja
MODEL_ARGS=(--jinja)

echo "=== Select a Model ==="
echo ""
echo "  1) Gemma 4 E2B                              2.3B effective params (~3.1 GB)"
echo "  2) Gemma 4 E4B                              4.5B effective params (~5.0 GB)"
echo "  3) Gemma 4 12B                              12B params, dense (~7.1 GB)"
echo "  4) Gemma 4 12B QAT                          12B params, dense (~6.7 GB)"
echo "  5) Gemma 4 26B-A4B                          3.8B active params, MoE (~13.4 GB)"
echo "  6) Qwen3.6-35B-A3B                          3B active params, MoE (~17.7 GB)"
echo "  7) Qwen3.6-35B-A3B Unc.                     3B active params, MoE (~19.0 GB)"
echo "  8) Qwen3.6-35B Genesis Unc.                 3B active params, MoE (~17.4 GB)"
echo "  9) Muse Glimmer 30B (WARNING: Slow ~3tps)   29.6B params, dense (~16.8 GB)"
echo " 10) Qwen3.8-27B  [LM Studio]                 27B params, dense (~16.8 GB)"
echo " 11) Gemma 4 E2B  [LM Studio]                 2.3B effective params (~3.4 GB)"
echo ""
read -rp "Model [6]: " MODEL_CHOICE
echo ""

case "${MODEL_CHOICE:-6}" in
  1)
    # Gemma 4 E2B: 2.3B effective params (~3.1 GB)
    MODEL_PATH="$LLAMA_MODELS/gemma-4-E2B-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  2)
    # Gemma 4 E4B: 4.5B effective params (~5.0 GB)
    MODEL_PATH="$LLAMA_MODELS/gemma-4-E4B-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  3)
    # Gemma 4 12B (dense): 12B params (~7.1 GB)
    MODEL_PATH="$LLAMA_MODELS/gemma-4-12b-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  4)
    # Gemma 4 12B QAT (dense, Quantization-Aware Training): 12B params (~6.7 GB)
    # Lower memory footprint (~7 GB total) and potentially faster than the
    # standard Q4_K_M 12B build, with accuracy close to the original BF16.
    # In other words, this QAT model is "smarter" (better answers/inference) than
    # the non-QAT model above, but runs in about the same memory.
    MODEL_PATH="$LLAMA_MODELS/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf"
    CTX_SIZE="16384"
    ;;
  5)
    # Gemma 4 26B-A4B (MoE): 3.8B active params (~13.4 GB)
    # Mixture-of-Experts: all 25.2B params live in memory but only ~3.8B activate
    # per token, so generation stays fast while quality is higher than the 12B.
    # Context kept at 8192 to leave memory headroom alongside the larger weights,
    # although there is reason to believe 16384 will alwo work on my hardware.
    MODEL_PATH="$LLAMA_MODELS/gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"
    CTX_SIZE="8192"
    ;;
  6)
    # Qwen3.6-35B-A3B (MoE): ~3B active params (~17.7 GB)
    # Mixture-of-Experts: all 35B params live in memory but only ~3B activate per
    # token, so generation stays fast on bandwidth-limited unified memory while
    # quality rivals a flagship coder. IQ4_XS avoids the known k-quant crash on the
    # Arc 140V iGPU, and a small prefill batch is the recommended Arc workaround
    # (see model-research/Qwen).
    MODEL_PATH="$LLAMA_MODELS/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf"
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
    # this fine-tune's chat template. That is now handled globally by MODEL_ARGS
    # above (and is llama.cpp's own default on b10355), so nothing to do here.
    MODEL_PATH="$LLAMA_MODELS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-IQ4_XS.gguf"
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
    # option 7. It is an agent / tool-calling fine-tune shipping its own
    # chat_template.jinja, and without --jinja llama.cpp substitutes a built-in
    # approximation of the template, breaking function calls and reasoning-block
    # parsing. This branch used to set MODEL_ARGS itself; --jinja is now applied
    # globally in MODEL_ARGS above, so the per-model assignment was redundant and
    # has been removed. Do not pass --no-jinja when running this model.
    #
    # CTX_SIZE is a knowing compromise. The model card asks for 128K+ context to
    # keep its thinking mode intact, but 128K of KV cache is far past what is
    # left of 32 GB once ~17.4 GB of weights are resident. 16384 matches the
    # other A3B entries and is what actually runs; long-form reasoning pays for
    # it. Quantizing the KV cache (--cache-type-k/v q8_0, which -fa on already
    # makes available) is the lever that could buy more here, at the cost of a
    # dequant step on every token.
    #
    # See download-model.sh option 8 for why this quant was chosen, including the
    # caveat that APEX's GGML tensor types are undocumented — so unlike options 6
    # and 7 this file is NOT confirmed to dodge the Arc 140V k-quant crash.
    MODEL_PATH="$LLAMA_MODELS/Hermes3.6-35B-A3B-Uncensored-Genesis-V7-APEX-Compact.gguf"
    CTX_SIZE="16384"
    BATCH="256"
    ;;
  9)
    # Muse Glimmer 30B (dense): 29.6B params, 52 layers, 131K+ native context
    # (~16.8 GB). CTX_SIZE matches the other large models here — the weights
    # are close in size to option 6's ~17.7 GB, so the same 16384 leaves
    # comparable headroom in 32 GB. No documented reason to override FA or
    # BATCH for this model, so both fall through to the defaults above (FA on,
    # BATCH unset) — the -b 256 tweak used by the three Qwen3.6-35B-A3B
    # branches is specifically an A3B/MoE-on-Vulkan prefill workaround
    # (model-research/Qwen), not something known to apply to this dense model.
    #
    # CAUTION #1 — no IQ-quant exists for this model; this repo ships K-quants
    # only, and the Arc 140V iGPU has a known k-quant crash (see
    # model-research/Qwen). Options 6 and 7 dodge that bug via IQ4_XS; this
    # model has no such fallback quant within its own repo. Treat the first
    # launch as the test.
    #
    # CAUTION #2 — this is a dense model, not MoE, so it reads all ~29.6B
    # params every token. model-research/Qwen's bandwidth math predicts dense
    # models this large land around 5-8 tok/s on this hardware (it measured a
    # dense 27B Qwen there, under the 10 TPS floor targeted in that doc) — so
    # expect noticeably slower generation than every MoE model above.
    #
    # See download-model.sh option 9 for why kquant-17gb (not kquant-dynamic)
    # was the file chosen, and for the optional mmproj/dflash companion files
    # that were deliberately not downloaded.
    #
    # NOTE: --jinja is required for this model — it ships a bespoke agentic
    # template using <atem:function_calls> tags. Applied globally in MODEL_ARGS
    # above, so the per-model assignment that was here has been removed.
    MODEL_PATH="$LLAMA_MODELS/muse-glimmer-30B-kquant-17gb.gguf"
    CTX_SIZE="16384"
    ;;
  10)
    # Qwen3.8-27B — the first entry served out of LM STUDIO's tree rather than
    # llama-deck's own. Nothing about llama.cpp changes for this: llama-server
    # takes any path for --model, so a model downloaded by LM Studio runs here
    # exactly like one fetched by download-model.sh. There is deliberately NO
    # matching entry in download-model.sh — see ai-prompts/install-new-model.md
    # for why the two menus are no longer expected to line up.
    #
    # PATH NOTE: LM Studio picks the <publisher>/<repo> folder from its own
    # catalog, and it does NOT match the model key the app displays — this model
    # shows as "qwen/qwen3.8-27b" in the UI but sits under lmstudio-community/.
    # `lms ls --json` reports that same normalized key rather than a file path,
    # so it cannot be used to find the file. After downloading anything in
    # LM Studio, look up where it actually landed before adding it here:
    #   find "$LMS_MODELS" -name '*.gguf' -printf '%T@ %p\n' | sort -rn | head -5
    #
    # K-QUANT, BUT CONFIRMED WORKING (2026-08-14). This is a Q4_K_M with no
    # IQ-quant fallback in the repo, so it carried the same Arc 140V k-quant
    # crash risk that options 6 and 7 dodge by choosing IQ4_XS, and that option 9
    # is still unverified against (see model-research/Qwen). It was run on the
    # Vulkan backend and did not crash — so this is now a data point that the
    # k-quant bug does not hit every k-quant on this hardware. Option 9's warning
    # stands on its own; it has not been retested.
    #
    # ARCHITECTURE — read from the GGUF header, not guessed from the name:
    # general.architecture is "qwen35", a HYBRID of attention and Mamba-style
    # SSM layers. Of its 65 blocks, only 16 are attention (indices 3, 7, 11 ...
    # 63 — qwen35.full_attention_interval=4); 48 are SSM, and block 64 is an MTP
    # head (see SPEC below). There are no expert tensors, so the FFNs are dense
    # and the ~5-8 tok/s bandwidth ceiling option 9 warns about does apply.
    # BATCH is left at the default on purpose: the -b 256 tweak used by the A3B
    # entries is an MoE-on-Vulkan prefill workaround, not something known to
    # apply here.
    #
    # Two things follow from the hybrid layout that are easy to get wrong:
    #   - KV cache is CHEAP. Only 16 layers hold one, at 4 kv-heads x (256+256)
    #     x 2 bytes = 64 KiB/token, so CTX_SIZE 16384 costs ~1 GiB rather than
    #     the ~4 GiB a conventional dense 27B would. There is room to raise it.
    #   - The 48 SSM layers carry a recurrent state instead, ~150 MB per slot,
    #     and that cost is fixed regardless of CTX_SIZE.
    #
    # SPEC — this model ships its own MTP (multi-token prediction) head:
    # qwen35.nextn_predict_layers=1, with the blk.64.nextn.* tensors already
    # inside the 16.81 GB below. So draft-mtp needs no draft model and no extra
    # download; it drafts with a head that is loaded either way. Being dense, it
    # is exactly the case where speculation pays (see the Speculative Decoding
    # block above for why that is the opposite of options 6-8). ggml-org's own
    # published launch commands for this model use --spec-type draft-mtp on
    # every hardware tier, from an RTX 5090 down to a DGX Spark, because the win
    # is about memory bandwidth rather than GPU size — and this laptop is more
    # bandwidth-starved than either.
    #
    # UNVERIFIED, so treat the first run as the test: a rejected draft has to
    # rewind the recurrent state of those 48 SSM layers, which is the one place
    # a hybrid model could misbehave where a plain transformer would not. If it
    # errors or the output degrades, `SPEC=off ./start-server.sh` overrides this
    # line without editing the file. Confirm the gain with ./status.sh either
    # way — the model is not obliged to draft well just because it can draft.
    SPEC="draft-mtp"
    #
    # REASONING — this is the ONE model in the menu with graduated thinking
    # levels rather than a thinking on/off switch, which is why the reasoning
    # menu below has more entries when this option is chosen. Its template reads
    # a `reasoning_effort` variable and validates it itself:
    #
    #   {%- set resolved_reasoning_effort = reasoning_effort|default('xhigh') %}
    #   {%- if resolved_reasoning_effort not in ('xhigh', 'medium', 'low') %}
    #       {{- raise_exception('Unexpected reasoning effort ...') }}
    #
    # So the levels are literally 'low', 'medium', 'xhigh' — there is NO 'high',
    # and 'xhigh' is the default when thinking is on and nothing is passed. The
    # mechanism is plain prompting: low and xhigh each prepend a sentence of
    # instruction to the system message ("Keep your thinking brief and focused"
    # / "think carefully through the task, validate key assumptions..."), while
    # medium deliberately injects NOTHING and is the un-nudged baseline. Nothing
    # here caps the thinking length by force; see --reasoning-budget below for
    # the lever that does.
    REASONING_EFFORTS="low medium xhigh"
    #
    # SIZE — the weights are 16.81 GB. Note that LM Studio's own UI and
    # `lms ls` report ~17.7 GB for this model: that figure is the whole repo
    # folder, weights plus the 0.93 GB mmproj below. Only the weights are loaded
    # here, so budget 16.8 GB, not 17.7 GB.
    #
    # Vision: LM Studio also downloaded mmproj-Qwen3.8-27B-BF16.gguf alongside
    # this file. Loading it would need --mmproj; as everywhere else in this
    # script, we serve text-only weights.
    MODEL_PATH="$LMS_MODELS/lmstudio-community/Qwen3.8-27B-GGUF/Qwen3.8-27B-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  11)
    # Gemma 4 E2B, LM Studio's copy: 2.3B effective params (~3.4 GB)
    #
    # THIS IS THE SAME MODEL AS OPTION 1, from a different packager — it is not a
    # mistake in the menu, and the two are not interchangeable byte-for-byte:
    #   option  1  3.11 GB  unsloth/gemma-4-E2B-it-GGUF        (llama-deck tree)
    #   option 11  3.43 GB  lmstudio-community/gemma-4-E2B-it-GGUF (LM Studio tree)
    # Both are labelled Q4_K_M, but they are separate conversions of the same
    # weights and differ by ~320 MB, so they will not generate identical output.
    # Having both is what lets you compare packagers on identical hardware; if you
    # ever want the ~3.4 GB back, this is the safest model on the menu to delete
    # (from LM Studio's My Models tab), since option 1 covers the same ground.
    #
    # CTX_SIZE matches option 1 — same architecture, same memory profile, and the
    # model's own trained context is 131072, so 16384 is a budget choice rather
    # than a model limit. FA and BATCH fall through to the defaults for the same
    # reason they do in option 1: nothing about this model calls for either.
    #
    # Vision: LM Studio also pulled mmproj-gemma-4-E2B-it-BF16.gguf (0.99 GB)
    # into this folder. It would need --mmproj to be used; as everywhere else in
    # this script, only the text weights are served.
    MODEL_PATH="$LMS_MODELS/lmstudio-community/gemma-4-E2B-it-GGUF/gemma-4-E2B-it-Q4_K_M.gguf"
    CTX_SIZE="16384"
    ;;
  *)
    echo "ERROR: Invalid selection '$MODEL_CHOICE'."
    exit 1
    ;;
esac
# ─────────────────────────────────────────────────────────────────────────

# ── Reasoning Mode ───────────────────────────────────────────────────────
# Asked AFTER the model menu because the available answers depend on the model:
# most entries here can only turn thinking on or off, while option 10 has three
# named effort levels. The menu below shows the levels only when the selected
# model actually implements them (REASONING_EFFORTS, set in its branch above).
#
# TWO SEPARATE MECHANISMS, and it is worth being precise about which is which,
# because only the first is a llama.cpp feature at all:
#
#   ON / OFF is llama-server's own --reasoning [on|off|auto] flag. It sets the
#     `enable_thinking` variable that essentially every thinking model's chat
#     template reads. "off" does not merely ask the model not to think — the
#     template emits a CLOSED, EMPTY thought block ("<think>\n\n</think>") as
#     part of the assistant prefix, so the model resumes after a thought it
#     never had and cannot open a new one. That is why it is the fastest
#     setting: zero thinking tokens, not fewer.
#
#   LOW / MEDIUM / HIGH is NOT a llama.cpp feature. There is no --reasoning-level
#     flag; llama-server's --reasoning takes only on/off/auto. The levels live
#     inside the model's own chat template, which reads a `reasoning_effort`
#     variable, and we reach it through the generic --chat-template-kwargs
#     escape hatch. Their effect is therefore prompting, not decoding: the
#     template prepends a sentence of instruction to the system message. So a
#     level is a request the model can ignore, unlike off, which it cannot.
#
# WHICH MODELS HAVE LEVELS. Only option 10 (Qwen3.8-27B), whose levels are
# 'low', 'medium', 'xhigh' — note there is no 'high', and that its `medium`
# injects no instruction at all, being the un-nudged baseline. Every other model
# in this menu ships a template with `enable_thinking` and nothing else (Muse
# Glimmer, option 9, has neither). Don't take that on faith when adding a model —
# read it out of the GGUF, since this is a property of the file, not of the
# model family. The template is metadata, so a quick way to see it rendered is
# to make the *small* model wear the big one's template and ask the server what
# it would send:
#   llama-server -m <small>.gguf --jinja --chat-template-file <extracted>.jinja \
#     --chat-template-kwargs '{"reasoning_effort":"low"}' --port 8099 &
#   curl -s localhost:8099/apply-template -H 'Content-Type: application/json' \
#     -d '{"messages":[{"role":"user","content":"hi"}]}'
# Passing a key a template does not read is harmless — it is simply unused — so
# the risk of a wrong guess is a setting that silently does nothing, which is
# exactly why REASONING_EFFORTS is declared per model rather than assumed.
#
# Answers are the same names in the menu, the environment, and the banner, so
# nothing has to be translated between them:
#   REASONING=off ./start-server.sh
#   REASONING=low ./start-server.sh     # or 3, the menu number
# Numbering is deliberately stable across models — 3 is always "low", even for a
# model that has no levels — so a saved command line keeps its meaning when you
# switch models. Ask a model for a level it does not implement and you get a
# note and plain "on" rather than a failure.
if [[ -z "$REASONING_CHOICE" ]]; then
  echo "=== Select a Reasoning Mode ==="
  echo ""
  echo "  1) No reasoning   thinking suppressed entirely — fastest, fewest tokens"
  echo "  2) Reasoning on   the model's own default thinking depth"
  if [[ -n "$REASONING_EFFORTS" ]]; then
    echo "  3) Low            think briefly, move straight to the conclusion"
    echo "  4) Medium         think, with no instruction either way (baseline)"
    echo "  5) High           think carefully: check assumptions, weigh alternatives"
    echo ""
    echo "     3-5 set this model's reasoning_effort. 5 is its 'xhigh', which is"
    echo "     also what 2 gives you, that being the template's own default."
  else
    echo ""
    echo "     This model's chat template knows thinking on/off only; it has no"
    echo "     effort levels. (Option 10 is the one that does.)"
  fi
  echo ""
  read -rp "Reasoning [1]: " REASONING_INPUT
  echo ""
  REASONING_CHOICE="${REASONING_INPUT:-1}"
fi

REASONING_EFFORT=""
case "$REASONING_CHOICE" in
  1 | off | none)    REASONING="off" ;;
  2 | on)            REASONING="on" ;;
  3 | low)           REASONING="on"; REASONING_EFFORT="low" ;;
  4 | medium | med)  REASONING="on"; REASONING_EFFORT="medium" ;;
  5 | high | xhigh)  REASONING="on"; REASONING_EFFORT="xhigh" ;;
  *)
    echo "ERROR: Invalid reasoning mode '$REASONING_CHOICE'"
    echo "       (expected 1/off, 2/on, 3/low, 4/medium, or 5/high)."
    exit 1
    ;;
esac

REASONING_ARGS=()
if [[ -n "$REASONING_EFFORT" ]]; then
  if [[ " $REASONING_EFFORTS " == *" $REASONING_EFFORT "* ]]; then
    REASONING_ARGS=(--chat-template-kwargs "{\"reasoning_effort\":\"$REASONING_EFFORT\"}")
  else
    echo "NOTE: this model's template has no '$REASONING_EFFORT' reasoning level"
    echo "      (${REASONING_EFFORTS:-it supports on/off only}), so reasoning is"
    echo "      simply on, at whatever depth the model does by default."
    echo ""
    REASONING_EFFORT=""
  fi
fi

# ── Reasoning Budget (optional, and model-agnostic) ──────────────────────
# The hard cap the effort levels above are not: --reasoning-budget N ends the
# thought after N tokens by injecting the closing tag, whatever the model wanted
# to do. Unlike reasoning_effort this needs no cooperation from the template, so
# it is the nearest thing to a "shorter thinking" control on the models that
# have no levels — at the cost of being a guillotine rather than an instruction,
# so a thought can be cut mid-sentence. Off by default (-1, unrestricted):
#   REASONING_BUDGET=512 ./start-server.sh
# Only meaningful with reasoning on; with mode 1 there is no thought to bound.
REASONING_BUDGET="${REASONING_BUDGET:-}"
if [[ -n "$REASONING_BUDGET" ]]; then
  if [[ "$REASONING" == "on" ]]; then
    REASONING_ARGS+=(--reasoning-budget "$REASONING_BUDGET")
  else
    echo "NOTE: REASONING_BUDGET=$REASONING_BUDGET ignored — reasoning is off."
    echo ""
    REASONING_BUDGET=""
  fi
fi

# What the startup banner prints: the mode, plus the level when there is one.
if [[ -n "$REASONING_EFFORT" ]]; then
  REASONING_LABEL="on (effort: $REASONING_EFFORT)"
else
  REASONING_LABEL="$REASONING"
fi
[[ -n "$REASONING_BUDGET" ]] && REASONING_LABEL+=", budget $REASONING_BUDGET"

# As with sampling, all of this sets SERVER DEFAULTS. A client that sends its own
# "chat_template_kwargs" in the request body still wins for that request.
# ─────────────────────────────────────────────────────────────────────────

# ── Sampling Mode ────────────────────────────────────────────────────────
# Asked AFTER the model menu because it is a per-run decision about the same
# weights, not a property of the model: the identical GGUF answers differently
# depending on how the next token is drawn from its probability distribution.
#
#   creative → --temperature 0.8 --min-p 0.05 --top-p 0.95 --top-k 0
#     Temperature 0.8 flattens the distribution so lower-ranked tokens keep a
#     real chance of being picked, which is what produces varied prose instead
#     of the same sentence every time. top-k 0 DISABLES the top-k cutoff
#     (llama.cpp's default is 40) so the candidate pool is bounded by
#     probability mass (top-p/min-p) rather than by a fixed rank — the long
#     tail stays reachable where it is genuinely plausible.
#
#   factual → --temperature 0.2 --min-p 0.05 --top-p 0.95 --top-k 0
#     THE SAME SAMPLER STACK AS creative, WITH ONE KNOB MOVED: temperature.
#     That is the point — 0.2 sharpens the distribution toward the argmax, so
#     the model mostly says the most likely thing, while everything else stays
#     mass-bounded rather than rank-bounded. Low-entropy but NOT greedy, which
#     is what separates it from strict below: a little probability left on the
#     alternatives is what lets a model take a different route through a
#     problem instead of committing to a bad first step it can never leave.
#     Use it for code, tool calls, extraction, multi-step reasoning, long
#     technical explanations, and factual QA.
#
#     min-p 0.05 appears in both of the above — it drops any token below 5% of
#     the top token's probability, the cheapest guard against a rare nonsense
#     token, and it costs nothing once temperature is already low.
#
#   strict → --temperature 0.0 --seed 42 --repeat-penalty 1.05
#     Absolute determinism. Temperature 0.0 is not "very low randomness", it is
#     NO randomness: llama.cpp takes the argmax, so the truncation samplers
#     (top-p/top-k/min-p) become irrelevant — whatever they leave in the pool,
#     the single highest-probability token was always going to win. That is why
#     none of them are passed here; passing them would only imply they matter.
#     For code generation, JSON/YAML extraction, classification, and math, this
#     is the mode where the same prompt gives the same answer twice.
#
#     --seed 42 is belt-and-braces rather than load-bearing, and it is worth
#     knowing which: at temperature 0.0 the RNG is never consulted, so the seed
#     changes nothing. It matters the moment something reintroduces randomness
#     — an API client that sends its own "temperature" in the request body (see
#     SERVER DEFAULTS below), or you editing this line. Pinning it means the run
#     stays reproducible in that case instead of silently becoming a lottery.
#     The value 42 is arbitrary; any fixed number does the same job.
#
#     --repeat-penalty 1.05 exists because greedy decoding is the case that
#     degenerates into loops: with no randomness to break a tie, a model that
#     starts repeating a phrase has nothing to stop it repeating that phrase
#     forever. The penalty divides the logit of any token seen in the last
#     --repeat-last-n tokens (default 64), making an exact rerun slightly less
#     attractive. 1.05 is deliberately mild — llama.cpp's default is 1.0, i.e.
#     off, and this is the one setting here that can actively HURT structured
#     output, since JSON and code legitimately repeat braces, indentation, and
#     field names. If a model starts mangling long JSON in this mode, that is
#     the first knob to suspect: SAMPLING=factual is the same job without it.
#
# WHY THREE MODES AND NOT FOUR. A fourth "low-entropy reasoning" entry
# (--temperature 0.2 --min-p 0.05 --top-p 0.95) was drafted and dropped: 0.95
# is already llama.cpp's default top-p, so it would have sent llama-server a
# configuration indistinguishable from factual's. Two menu items that produce
# one behavior is a menu that lies. Its actual intent — low entropy without
# greedy decoding's repetition traps — is what factual now is, and the lever
# that makes that real is --top-k 0 (lifting the fixed rank-40 cutoff so
# top-p/min-p alone bound the pool), which factual carries.
#
# NOTE ON FLAG SPELLING: this build takes --temp/--temperature, but the sampler
# flags are hyphenated (--min-p, --top-p, --top-k, --repeat-penalty). The
# underscore spellings seen in some model cards (--min_p, --top_p) are rejected
# by llama-server here.
#
# These are SERVER DEFAULTS, not a ceiling: llama.cpp applies them only when a
# request does not carry its own sampling fields. An API client that sends
# "temperature" in the JSON body still wins for that request.
#
# Skip the prompt entirely from the environment (also what makes this script
# usable non-interactively). Menu numbers and names are both accepted:
#   SAMPLING=factual ./start-server.sh
#   SAMPLING=3 ./start-server.sh          # same as SAMPLING=strict
# (SAMPLING=reasoning is accepted as an alias for factual — see WHY THREE MODES
# above — so a caller written against the dropped fourth entry still runs.)
SAMPLING="${SAMPLING:-}"
if [[ -z "$SAMPLING" ]]; then
  echo "=== Select a Sampling Mode ==="
  echo ""
  echo "  1) Creative   temp 0.8  — varied prose, brainstorming, writing"
  echo "  2) Factual    temp 0.2  — low-entropy but not greedy: code, tool"
  echo "                            calls, extraction, multi-step reasoning,"
  echo "                            long technical explanations, factual QA"
  echo "  3) Strict     temp 0.0  — deterministic, same prompt same answer:"
  echo "                            code gen, JSON/YAML extraction,"
  echo "                            classification, precise math"
  echo ""
  read -rp "Mode [1]: " SAMPLING_CHOICE
  echo ""
  SAMPLING="${SAMPLING_CHOICE:-1}"
fi

case "$SAMPLING" in
  1 | creative)
    SAMPLING="creative"
    SAMPLING_ARGS=(--temperature 0.8 --min-p 0.05 --top-p 0.95 --top-k 0)
    ;;
  2 | factual | reasoning)
    SAMPLING="factual"
    SAMPLING_ARGS=(--temperature 0.2 --min-p 0.05 --top-p 0.95 --top-k 0)
    ;;
  3 | strict)
    SAMPLING="strict"
    SAMPLING_ARGS=(--temperature 0.0 --seed 42 --repeat-penalty 1.05)
    ;;
  *)
    echo "ERROR: Invalid sampling mode '$SAMPLING'"
    echo "       (expected 1/creative, 2/factual, or 3/strict)."
    exit 1
    ;;
esac
# ─────────────────────────────────────────────────────────────────────────

# ── Speculative Decoding, resolved ───────────────────────────────────────
# Deliberately down here rather than beside the SPEC docs above: the menu had
# to run first so a per-model branch could set SPEC. An explicit SPEC= in the
# environment is reinstated now, so it beats whatever the branch chose.
[[ -n "$SPEC_ENV" ]] && SPEC="$SPEC_ENV"

SPEC_ARGS=()
case "$SPEC" in
  off) ;;
  ngram-simple)
    SPEC_ARGS=(--spec-type ngram-simple --spec-draft-n-min 2 --spec-draft-n-max 12)
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
# ─────────────────────────────────────────────────────────────────────────

# ── Server Configuration ─────────────────────────────────────────────────
HOST="127.0.0.1"
PORT="8080"
# ─────────────────────────────────────────────────────────────────────────

# ── Request Slots (--parallel) ───────────────────────────────────────────
# A "slot" is one lane for an in-flight request. Left unset, llama.cpp picks
# for you, and it says so at startup:
#   "n_parallel is set to auto, using n_parallel = 4 and kv_unified = true"
# We pin it to 1 instead, because this server backs a single-user chat UI —
# one person, one conversation at a time.
#
# WHAT THIS DOES NOT SAVE. It is tempting to assume 4 slots means 4 KV caches
# and that dropping to 1 reclaims three of them. It does not: `kv_unified =
# true` (which auto mode turns on) means all sequences share ONE pool of
# --ctx-size tokens, so on the transformer models the extra slots cost nearly
# nothing, and n_ctx_slot stays the full 16384 rather than being divided.
# Setting --parallel 1 there is tidiness, not a memory win.
#
# WHAT IT DOES SAVE, and why it is worth pinning at all: recurrent state is
# NOT part of that shared token pool. Hybrid SSM models allocate a full state
# per sequence, sized by the model rather than by the context length, so it
# scales with the slot count and nothing reclaims it. Option 10 is the case in
# hand — 48 SSM layers at roughly 3.1 MB of state each is ~150 MB per slot, so
# auto's 4 slots reserve ~600 MB to serve one chat that can only ever use
# ~150 MB. Pinning to 1 hands ~450 MB back.
#
# THE TRADE: concurrent requests now queue instead of running side by side. For
# one human typing in a chat box that is the right call — and arguably faster,
# since two generations on this laptop would only fight each other for the same
# LPDDR5X bandwidth. If you ever drive this from something that fans out
# requests (a batch script, several browser tabs), raise it:
#   PARALLEL=4 ./start-server.sh
#
# Note that passing this explicitly also flips kv_unified off, since that
# defaulted on only *because* the slot count was auto. At one slot there is one
# sequence, so unified vs. not is a distinction without a difference.
PARALLEL="${PARALLEL:-1}"
# ─────────────────────────────────────────────────────────────────────────

# Each branch above set a full MODEL_PATH; derive the bare filename from it so
# the startup banner stays readable rather than printing a long path twice.
MODEL_FILE="$(basename "$MODEL_PATH")"

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
  echo ""
  if [[ "$MODEL_PATH" == "$LMS_MODELS"/* ]]; then
    echo "  This model comes from LM Studio. It was most likely deleted from"
    echo "  LM Studio's My Models tab, or the models folder was moved (LM Studio"
    echo "  Settings → models directory). See what is actually there:"
    echo "    find \"$LMS_MODELS\" -name '*.gguf'"
    echo ""
    echo "  If you moved the folder, update LMS_MODELS at the top of this script."
  else
    echo "  Run ./download-model.sh first, and pick the matching model."
  fi
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
    echo "  A healthy llama-server is already listening there. To use it, point"
    echo "  your client at:"
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
# Both are overridable from the environment, without editing this file:
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
THREADS="${THREADS:-1}"
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
echo "  Model path:   $MODEL_PATH"
echo "  Reasoning:    $REASONING_LABEL"
echo "  Context size: $CTX_SIZE"
echo "  Flash-attn:   $FA"
echo "  Prefill batch: ${BATCH:-default}"
echo "  Threads:      $THREADS gen / $THREADS_BATCH batch"
echo "  Slots:        $PARALLEL"
echo "  Spec decoding: $SPEC"
echo "  Sampling:     $SAMPLING (${SAMPLING_ARGS[*]})"
echo "  Model flags:  ${MODEL_ARGS[*]:-none}"
echo "  Endpoint:     http://${HOST}:${PORT}  (built-in chat UI)"
echo "  API (OpenAI): http://${HOST}:${PORT}/v1  (base URL for API clients)"
echo ""
echo "Press Ctrl+C to stop the server."
echo ""

# Write PID file so stop-server.sh can find us.
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
  --parallel "$PARALLEL" \
  "${GPU_ARGS[@]}" \
  "${SPEC_ARGS[@]}" \
  "${SAMPLING_ARGS[@]}" \
  --reasoning "$REASONING" \
  "${REASONING_ARGS[@]}" \
  "${MODEL_ARGS[@]}" \
  "${EXTRA_ARGS[@]}"
