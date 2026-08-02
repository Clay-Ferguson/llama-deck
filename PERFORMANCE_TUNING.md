# PERFORMANCE TUNING (NOT YET DONE) todo-0

The following is a response from Claude Code on 8/2/26, after I was asking about potential optimization parameters that I haven't yet taken advantage of which could potentially result in improved LLM performance, and I haven't looked into any of this yet.


## NGL — `--n-gpu-layers`

How many transformer layers get offloaded to the GPU. `start-server.sh:47` sets `NGL=99`, which is the idiomatic "more layers than any model has," i.e. offload everything including the output layer. Any leftover layers run on CPU.

On a discrete GPU this is the main tuning dial: you lower it until the model fits in VRAM. On your Arc 140V it's much less interesting, because the iGPU has no dedicated VRAM — it carves out of the same LPDDR5X the CPU uses. Moving a layer from GPU to CPU doesn't free memory, it just changes which processor reads the same bytes over the same memory bus. So 99 is essentially always right for you, and partial offload is a knob you'd only touch to diagnose a specific layer misbehaving on Vulkan. Fine as-is.

## SPEC — speculative decoding, `--spec-type`

Generation is normally strictly sequential: one forward pass per token. Speculative decoding breaks that by having something cheap *guess* the next several tokens, then running the real model once over the whole guessed run to check them in parallel. Accepted guesses are free; rejected ones cost a discarded pass. Classically the guesser is a small draft model, but the `ngram-*` types in `start-server.sh:65-79` are self-speculative — they guess by pattern-matching text already in the context, so there's no second model and no extra download. That's why they help most on rewrite/edit tasks, where the output replays long stretches of the input verbatim.

The reason it backfires on your hardware, as the comment at `start-server.sh:58` says: the trick converts *memory bandwidth* savings into *extra compute*. That's a great trade on a discrete GPU with idle compute and fast VRAM. Lunar Lake's iGPU is the opposite — it's bandwidth-starved and compute-modest, so verifying a batch of speculated tokens costs nearly what generating them normally would, and every rejection is pure loss. `off` is correct.

That's also what the `draft acceptance` block in `benchmark.sh` prints — it stays dormant unless the running server has spec enabled, so it still works if you ever flip it on to re-measure.

## What might actually be missing

Ranked for your setup. **Check names against `llama-server --help` on your pinned build** — llama.cpp renames flags fairly often and I can't run it from here:

1. **`--jinja`** — the likeliest real gap. It makes the server use the GGUF's embedded Jinja chat template instead of a built-in approximation, which is what enables proper tool/function calling and reasoning-block parsing on Qwen3 and Gemma. If MkBrowser ever does tool use, this is close to mandatory.

2. **KV cache quantization — `--cache-type-k` / `--cache-type-v`** (e.g. `q8_0`). Your KV cache at 16K context is competing with the model for the same unified memory; q8_0 roughly halves it at negligible quality cost. This is what would let Gemma 26B-A4B go from the 8192 you settled on at `start-server.sh:154` up to 16384. V-cache quantization generally requires flash-attention, which is now on for every model here, so this applies across the board.

3. **`-ub` / `--ubatch-size`** — you set `-b 256` for Qwen at `start-server.sh:165`, but `-b` is the *logical* batch while `-ub` is the *physical* micro-batch actually handed to the backend. They're separate knobs with separate defaults, and on Vulkan `-ub` is usually the one that moves prefill throughput. Worth a benchmark sweep now that you have a clean way to measure.

4. **Context-overflow behavior** — recent llama.cpp changed whether context shift is on by default. Worth confirming what your pinned build does when a chat exceeds `--ctx-size`: silently drop the oldest tokens, or error out. It's a behavior you want chosen deliberately, not inherited.

5. **`--alias`** — cosmetic. Sets the model name reported by `/v1/models`, so MkBrowser shows "gemma-4-12b-qat" instead of a filesystem path.

6. **`--mmproj`** — only if you care that Gemma 4 is natively multimodal. Vision needs the separate projector file loaded alongside the GGUF; without it the model is text-only.

Items 2 and 3 are the two most likely to show up as real tok/s or context gains. 