# Llama Deck (llama.cpp-based Local LLM Backend)

Run local LLM models using [llama.cpp](https://github.com/ggml-org/llama.cpp). llama.cpp provides an OpenAI-compatible HTTP API, so any
client that speaks that protocol can point at it. The scripts in this project can be used to run any `LLAMA.CPP` model locally on your own hardware 
the actual models that are listed (inactive ones commented out) are the ones selected because they run on the machine the developer of this project
uses which is a **Dell XPS laptop with an Intel Core Ultra 9 288V (Lunar Lake) running Ubuntu Linux**, which pairs 8 CPU cores with an **Intel Arc 140V integrated GPU** and 
**32 GB of on-package "unified" LPDDR5X memory**. So as long as you have a hardware equal to or better than this you can easily run all
the models listed in this project. Also the Vulkan script in this project is specific to my hardware Intel Chipset, and so it may not be applicable
to your specific hardware.

## Quick Start

```bash
# 1. Install llama.cpp (downloads prebuilt binaries, at a pinned version)
./setup.sh                # CPU build
./setup-with-vulkan.sh    # GPU build — required, since GPU is the default backend

# 2. Download the model (see model selection in script; default: Qwen3.6-35B-A3B)
./download-model.sh

# 3. Start the server
./start-server.sh

# 4. In another terminal: confirm it's up and inference works
#    (a large model takes ~2 min to load; until then this reports LOADING)
./status.sh
```

`start-server.sh` defaults to the **GPU (Vulkan)** backend, so step 1 needs
`./setup-with-vulkan.sh` — with only `./setup.sh` installed it will stop with
"Vulkan build not found." To run on the CPU build instead, set the backend
explicitly: `BACKEND=cpu ./start-server.sh` (see [Vulkan Driver](#vulkan-driver)).

The server is then up at **http://localhost:8080**, with the OpenAI-compatible
API at **http://localhost:8080/v1** — that `/v1` is the base URL to give any API
client. To just chat with the model, open the first URL in a browser (see below).

## Web UI (Browser Chat)

You don't need any extra app to confirm the model is up.
`llama-server` ships with a **built-in chat web app**, served from the same
host and port as the API. Once `./start-server.sh` is running, open:

```
http://localhost:8080
```

in any browser and you get a full chat interface with conversation history and
adjustable sampling settings (temperature, top-p, etc.). Nothing else to
install — it's part of the `llama-server` binary itself, so it's the quickest
way to prove the model is installed and answering (a friendlier alternative to
the `curl` checks in [Verifying the Server](#verifying-the-server)).

### Using a different port

The Web UI is served on the **same port as the API** (default **8080**), so
changing the port moves both. If something else on your machine is already using
8080, start the server on another port:

```bash
./start-server.sh --port 9090
```

Then open **http://localhost:9090** for the UI. (This is just the `--port N`
override described under [Customization](#server-parameters).)

If you change the port, update any API client to match — its base URL becomes
`http://localhost:9090/v1`.

## Prerequisites

- **Linux x86_64** (Ubuntu or similar)
- **32 GB RAM** recommended (model sizes range from ~3.1 GB to ~24 GB)
- `curl`, `unzip`, `bc` (standard on most Ubuntu installs)
- `ss` (from `iproute2`) and `jq` — used by `status.sh` / `stop-server.sh` to
  identify the running server. Both are standard on Ubuntu. These two scripts are
  **Linux-only** by design and will say so plainly on other platforms, rather
  than guessing (see [How the scripts find the server](#how-the-scripts-find-the-server)).

## Files

| Script | Purpose |
|--------|---------|
| `setup.sh` | Download and install the **CPU-only** llama.cpp binaries to `~/.local/bin/`, at a [pinned version](#pinned-llamacpp-version) |
| `setup-with-vulkan.sh` | Download and install a **Vulkan (GPU)** llama.cpp build side-by-side (see [Vulkan Driver](#vulkan-driver)) |
| `check-current-versions.sh` | Report which llama.cpp version each build is actually running, and whether it matches the pin (see [Pinned llama.cpp Version](#pinned-llamacpp-version)) |
| `download-model.sh` | Download a quantized GGUF model to `~/.local/share/llama.cpp/models/`. Legacy path — models obtained through LM Studio don't go through this (see [Models from LM Studio](#models-from-lm-studio)) |
| `start-server.sh` | Launch the server on `localhost:8080`; selects CPU or GPU via the `BACKEND` env var (default: `gpu`) |
| `status.sh` | Report whether the server is up, what it's serving, and run a test inference (see [Verifying the Server](#verifying-the-server)) |
| `stop-server.sh` | Stop the running server |
| `server-lib.sh` | Shared helper *sourced* by the scripts above (not run directly) — locates and verifies the server process |

## Verifying the Server

The quickest check is **`./status.sh`**, which answers "is it up, what is it
serving, and does inference actually work?" in one shot — port and PID, health,
the loaded model, slot usage, and a real test inference with token rates:

```bash
./status.sh              # full report + test inference
./status.sh --no-test    # just the report; generates no tokens
./status.sh --port 9090  # check a server on a non-default port
```

```
=== llama.cpp Server Status ===

  UP — healthy and accepting requests

  Endpoint:        http://127.0.0.1:8080
  ...
  Model:           Qwen3.6-35B-A3B-UD-IQ4_XS.gguf
  Quant:           IQ4_XS - 4.25 bpw
  Context:         16384 tokens (trained: 262144)
  Slots:           4 total, 0 busy, 4 idle

=== Test Inference ===
  Prompt eval:     26 tokens @ 22.2 tok/s
  Generation:      37 tokens @ 10.4 tok/s
```

Its exit codes are scriptable: **0** up, **1** down, **2** something is on the
port but it isn't a healthy llama-server, **3** still loading.

> **A cold start is not instant.** Loading a large MoE model off disk takes a
> couple of minutes (~2m10s for Qwen3.6-35B on this laptop). During that window
> the server is *already listening* but answers every request with **HTTP 503
> "Loading model"** — this is normal, and `status.sh` reports it as `LOADING`
> rather than an error. Don't kill and restart a server that is merely loading;
> you'll just start the wait over. To block until it's ready:
>
> ```bash
> until curl -sf http://localhost:8080/health >/dev/null; do sleep 2; done; echo READY
> ```

To poke at the API directly instead:

```bash
# List available models
curl http://localhost:8080/v1/models

# Send a test chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Stopping the Server

```bash
./stop-server.sh              # stop the server on the default port
./stop-server.sh --port 9090  # stop the server on a specific port, and nothing else
```

`stop-server.sh` sends `SIGTERM`, waits up to 10s for a graceful exit, then
escalates to `SIGKILL`. Two behaviors are worth knowing:

- **With an explicit `--port`, it only ever touches a server on that port.** It
  will not "helpfully" fall back to some other llama-server it happens to find.
- **If the port is held by a process that isn't llama-server, it leaves it
  alone** and reports what's there (exit code 2). Stopping unrelated programs is
  not its job.

### How the scripts find the server

`start-server.sh` writes a PID file (`~/.local/share/llama.cpp/llama-server.pid`),
but that file is treated as a **hint, not the source of truth**. A PID file
records a claim made at launch, and the claim can rot: the process may be
`SIGKILL`ed, crash, or be started outside the script. The real danger is that
PIDs get **recycled** — a stale file can end up naming a completely unrelated
process, and blindly signalling it would kill the wrong thing, silently.

So `status.sh` and `stop-server.sh` instead ask the kernel *who currently holds
the listening port* (via `ss`), fall back to the PID file only if that fails, and
in **either** case verify the process really is llama-server (via
`/proc/<pid>/comm`) before sending any signal. That verification is what makes
the operation safe against PID reuse. This is also why these two scripts are
Linux-only: `ss` and `/proc` don't exist on macOS or the BSDs, and the scripts
refuse to run rather than degrade into trusting a PID file. (On macOS the
equivalent lookup is `lsof -nP -iTCP:8080 -sTCP:LISTEN`.)

## Troubleshooting

### "couldn't bind HTTP server socket" on startup

```
E srv start: couldn't bind HTTP server socket, hostname: 127.0.0.1, port: 8080
E srv llama_server: exiting due to HTTP server error
```

This almost always means **the server is already running** — something else is
holding port 8080, so the new instance can't bind it and exits. It is not a
crash, and nothing is wrong with your model or install.

`start-server.sh` now checks the port *before* it starts, so you'll get a clear
message instead of this error. Run `./status.sh` to see what's there. If it's a
healthy server, you can just use it (point your client at
`http://localhost:8080/v1`); otherwise `./stop-server.sh` and start again, or run
the new one on another port with `./start-server.sh --port 9090`.

> Note the misleading detail that makes this error confusing: `start-server.sh`
> prints its whole "=== Starting llama.cpp Server ===" banner *before*
> llama-server ever attempts the bind. Seeing the banner does **not** mean the
> server started.

## Switching Models

Several model variants are supported:

| Variant | Params | Quant | File Size | Context | Notes |
|---------|--------|-------|-----------|---------|-------|
| **Qwen3.6-35B-A3B** | ~3B active / 35B total (MoE) | UD-IQ4_XS | ~17.7 GB | 16384 | Near-flagship coder; MoE keeps generation fast on unified memory. Uses `-b 256` on the Arc 140V iGPU. **Current default** |
| **Qwen3.6-35B-A3B Uncensored** | ~3B active / 35B total (MoE) | IQ4_XS | ~19.0 GB | 16384 | [HauhauCS "Aggressive"](https://huggingface.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive) fine-tune of the row above with refusals removed; same architecture, same `-b 256`. Model card suggests `--jinja` for its chat template |
| **Qwen3.6-35B Genesis-Hermes V7** | ~3B active / 35B total (MoE) | APEX-Compact (~4.0 bpw, imatrix) | ~17.4 GB | 16384 | [LuffyTheFox](https://huggingface.co/LuffyTheFox/Qwen3.6-35B-A3B-Uncensored-Genesis-Hermes-V7-GGUF) tool-calling fine-tune of the row above, plus a "Genesis" tensor-repair pass; same architecture, same `-b 256`. **Requires `--jinja`** — passed automatically. Quant types undocumented, so **not** confirmed k-quant-safe on the Arc 140V |
| **Gemma 4 26B-A4B** | 3.8B active / 25.2B total (MoE) | UD-IQ4_XS | ~13.4 GB | 8192 | High quality; MoE keeps generation fast despite the large size |
| **Gemma 4 12B QAT** | 12B (dense) | UD-Q4_K_XL | ~6.7 GB | 16384 | Quantization-Aware Training; lower memory (~7 GB total), potentially faster, accuracy close to BF16 |
| **Gemma 4 12B** | 12B (dense) | Q4_K_M | ~7.1 GB | 16384 | Strong quality |
| **Gemma 4 E4B** | 4.5B effective (8B total) | Q4_K_M | ~5.0 GB | 16384 | Good balance |
| **Gemma 4 E2B** | 2.3B effective (5.1B total) | Q4_K_M | ~3.1 GB | 16384 | Lightest, fastest |
| **Muse Glimmer 30B** | 29.6B (dense) | K-quant (kquant-17gb) | ~16.8 GB | 16384 | Dense, not MoE — expect ~5-8 tok/s per the project's bandwidth math, well under the MoE models above. Repo ships **only K-quants**, no IQ-quant fallback, so it is **unverified against the Arc 140V k-quant crash** |
| **Qwen3.8-27B** | 27B, dense FFN (hybrid SSM/attention) | Q4_K_M | ~16.8 GB | 16384 | **Served from LM Studio's folder**, not downloaded by this project. A K-quant with no IQ fallback, so it carried the Arc 140V k-quant crash risk — but it **runs fine on Vulkan** (confirmed 2026-08-14), useful evidence that the bug doesn't hit every K-quant. Architecture `qwen35`: of 65 blocks only 16 are attention, 48 are Mamba-style SSM, and block 64 is an MTP head — so it runs [speculative decoding](#speculative-decoding) for free, but the dense FFNs still put it at ~5-8 tok/s rather than MoE speed. KV cache is unusually cheap (~64 KiB/token, so 16384 ctx ≈ 1 GiB) since only 16 layers hold one. LM Studio reports ~17.7 GB because that figure includes the 0.93 GB mmproj; only the 16.8 GB of weights get loaded |
| **Gemma 4 E2B** *(LM Studio copy)* | 2.3B effective (5.1B total) | Q4_K_M | ~3.4 GB | 16384 | **Same model as the Gemma 4 E2B row above**, packaged by `lmstudio-community` instead of `unsloth` — a separate conversion, ~320 MB larger, so output won't match byte-for-byte. Kept alongside option 1 for packager comparison; the most redundant model on the menu if you need disk back |
| **Qwen3.8-27B** *(unsloth Dynamic v3.0)* | 27B, dense FFN (hybrid SSM/attention) | UD-Q4_K_XL | ~17.6 GB | 16384 | **Fetched by `./download-model.sh`** (option 12 in both scripts), unlike the row above — this is [unsloth's own repo](https://huggingface.co/unsloth/Qwen3.8-27B-GGUF), quantized with their newer "Dynamic v3.0" method. Same `qwen35` hybrid architecture as the LM Studio row above. Added because the LM Studio download of that same base model produced endless `?????` output — a classic tokenizer/detokenizer mismatch, most likely LM Studio's bundled runtime predating this quant tooling — so this repo is fetched and served independently through this project's own pinned llama.cpp build instead. Unlike the LM Studio copy, this repo ships its MTP head as a **separate** file that isn't fetched here, so `SPEC` stays `off` rather than `draft-mtp` |
| **Qwen3.8-2B-Distill** | 2B (dense, Qwen3.5 hybrid attention/Gated-DeltaNet) | Q8_0 | ~2.1 GB | 16384 | [empero-ai](https://huggingface.co/empero-ai/Qwen3.8-2B-Distill-GGUF) distillation of the Qwen3.8 teacher line down to a 2B student, on the newer Qwen3.5 architecture (full-attention layers interleaved with Gated DeltaNet layers). Reasoning model — every response opens with a `<think>` block. Tiny enough that the 24 GB budget is a non-issue; `Q8_0` was picked over the repo's `Q4_K_M`/`Q5_K_M`/`Q6_K` specifically to dodge the Arc 140V K-quant crash, since this repo has no IQ-quant to fall back on. **Caution:** the model card requires "a recent llama.cpp build with Qwen3.5 / Gated DeltaNet support" and warns older builds won't load it at all — untested against this project's pinned `LLAMA_TAG`; try a newer pin if it fails to load (see [Pinned llama.cpp Version](#pinned-llamacpp-version)) |

You don't edit anything to switch between them. `./start-server.sh` opens with a
numbered menu and serves whichever you pick:

```
=== Select a Model ===

  1) Gemma 4 E2B          2.3B effective params (~3.1 GB)
  2) Gemma 4 E4B          4.5B effective params (~5.0 GB)
  3) Gemma 4 12B          12B params, dense (~7.1 GB)
  4) Gemma 4 12B QAT      12B params, dense (~6.7 GB)
  5) Gemma 4 26B-A4B      3.8B active params, MoE (~13.4 GB)
  6) Qwen3.6-35B-A3B      ~3B active params, MoE (~17.7 GB)
  7) Qwen3.6-35B-A3B Unc. ~3B active params, MoE (~19.0 GB)
  8) Qwen3.6-35B Genesis  ~3B active params, MoE (~17.4 GB)
  9) Muse Glimmer 30B     29.6B params, dense (~16.8 GB)
 10) Qwen3.8-27B  [LM Studio]  27B params, dense (~16.8 GB)
 11) Gemma 4 E2B  [LM Studio]  2.3B effective params (~3.4 GB)
 12) Qwen3.8-27B (Unsloth)     27B params, dense (~17.6 GB)
 13) Qwen3.8-2B-Distill        2B params, dense (~2.1 GB)

Model [6]:
```

Press Enter to take the default (**6**, Qwen3.6-35B-A3B); anything outside the
listed range exits with an error rather than starting.

Two more menus follow it — [reasoning](#reasoning) and sampling — because both
are per-run decisions about the same weights rather than properties of the model.
Set `REASONING=` / `SAMPLING=` to answer either up front and skip its prompt.

For models this project downloads itself, `./download-model.sh` uses the *same*
numbering, so a given model is the same choice in both places:

```bash
./download-model.sh   # choose 5 → fetches Gemma 4 26B-A4B
./start-server.sh     # choose 5 → serves it
```

You only need `./download-model.sh` once per variant. From then on, switching is
nothing more than restarting `./start-server.sh` and picking a different number.

The one exception is entries marked **`[LM Studio]`**, which have no
`download-model.sh` counterpart because LM Studio downloaded them — so the two
menus are expected to diverge. See below.

## Models from LM Studio

Models don't all have to live in one folder. Each entry in `start-server.sh`'s
menu carries its **own full path**, so it can serve a GGUF from anywhere:

| Source | Where it lands |
|--------|----------------|
| `./download-model.sh` | `~/.local/share/llama.cpp/models/` — flat, one `.gguf` per model |
| LM Studio | `~/.lmstudio/models/<publisher>/<repo>/<file>.gguf` |

This works because `llama-server --model` accepts any path — llama.cpp, unlike
LM Studio, has no opinion about directory layout. So there is nothing to copy,
symlink, or migrate: one download serves both apps, wherever it happens to sit.

The two roots are named at the top of `start-server.sh` and are overridable:

```bash
LMS_MODELS=/mnt/big/models ./start-server.sh
```

**Adding an LM Studio model — look up its path, don't guess it.** LM Studio picks
the `<publisher>/<repo>` folder from its own catalog, and it does *not* match the
model key shown in the app: Qwen3.8-27B displays as `qwen/qwen3.8-27b` but lives
under `lmstudio-community/Qwen3.8-27B-GGUF/`. `lms ls --json` reports that same
normalized key rather than a file path, so it can't answer this either. Look on
disk:

```bash
find ~/.lmstudio/models -name '*.gguf' -printf '%T@ %p\n' | sort -rn | head -5
```

Then add a branch to `start-server.sh` setting `MODEL_PATH` to that path.
`ai-prompts/install-new-model.md` has the full recipe.

> **Watch your RAM if you use both apps.** LM Studio keeps a model resident for
> an hour after last use by default, and its server is on port 1234 while this
> one is on 8080 — so nothing collides and nothing warns you. Loading a ~17 GB
> model here while LM Studio still holds one is ~35 GB on a 32 GB machine. See
> [troubleshooting.md](troubleshooting.md).

Because both scripts prompt, they need a real terminal — they can't be driven
from cron or a pipe as-is.

Per-model *settings* are not in the menu itself but in the `case` block just
below it in `start-server.sh`. Each branch sets `CTX_SIZE`, and may override `FA`
(flash-attention on/off), `BATCH` (prefill batch size, `-b`) and `SPEC`
(speculative decoding, `--spec-type`) and `REASONING_EFFORTS` (which named
thinking levels its template implements); branches that omit those fall back to
the defaults declared above the menu (`FA="on"`, `BATCH=""`, `SPEC="off"`,
`REASONING_EFFORTS=""`). Three branches override something today:

| Model | Override | Why |
|-------|----------|-----|
| Qwen3.6-35B-A3B (choices 6, 7, 8) | `BATCH="256"` | Arc 140V prefill workaround for A3B MoE on Vulkan |
| Qwen3.8-27B (choice 10) | `SPEC="draft-mtp"` | Dense model with a built-in MTP head — see [Speculative Decoding](#speculative-decoding) |
| Qwen3.8-27B (choice 10) | `REASONING_EFFORTS="low medium xhigh"` | The only models here whose template has graduated thinking levels — see [Reasoning](#reasoning) |
| Qwen3.8-27B, unsloth (choice 12) | `REASONING_EFFORTS="low medium xhigh"` | Same template/levels as choice 10 — see [Reasoning](#reasoning). `SPEC` stays `off`: this repo ships its MTP head as a separate file that isn't fetched, so there is no draft head to use |

Every model runs with flash-attention on.

`FA` and `BATCH` follow the rule that a per-model branch beats an environment
variable. **`SPEC` is the deliberate exception** — an explicit `SPEC=` in the
environment beats the branch, so that `SPEC=off ./start-server.sh` can A/B a
branch's choice without editing the file. `REASONING_EFFORTS` is outside that
rule entirely — it has no environment override, because it states a fact about
the GGUF's template rather than a preference. What you *choose* from it is
`REASONING=`, which does read the environment.

`MODEL_ARGS` is a separate array of extra `llama-server` flags needed to make a
model work *correctly at all*, as distinct from the tuning knobs above. It is
declared just above the menu and currently holds **`--jinja`**, applied to every
model; a branch may append to it for a flag only one model needs (none do today).
These flags are appended before your own command-line arguments, so anything you
pass to `./start-server.sh` still overrides them, and the startup banner prints
them on a `Model flags:` line so you can see what was applied.

`--jinja` makes llama.cpp use each GGUF's own embedded chat template instead of a
built-in approximation, which is what drives tool/function calling and
reasoning-block parsing. Every model in the menu ships a real template (7K–17K
characters, all containing tool-calling logic). **Note that jinja is already
llama.cpp's default on the pinned build** — `--jinja, --no-jinja ... (default:
enabled)` — so passing it changes nothing today; it is explicit in order to *pin*
the behavior, for the same reason [`LLAMA_TAG` is pinned](#pinned-llamacpp-version).
To test a model against llama.cpp's built-in template instead, run
`./start-server.sh --no-jinja`.

Adding a new model means editing the menu and `case` block in **both** scripts,
keeping the numbering aligned between them (see `ai-prompts/`).

> **Note:** Choices **6** and **7** use `IQ4_XS` because the Arc 140V iGPU has a
> known crash with k-quants — which is also why the uncensored repo's own custom
> `K_P` quants are not used here, despite being the quants that repo promotes.
> Context is kept at 16384 to fit comfortably in 32 GB RAM alongside the
> ~17.4–19 GB weights, the OS, and KV-cache overhead.
>
> **Choice 8 is the exception, and is unproven on this hardware.** Its repo
> publishes custom "APEX" quants and documents only that they are imatrix-based —
> the per-tensor GGML types are never stated, so there is no way to confirm from
> the model card that it avoids k-quants. The file works out to ~4.0 bpw, just
> under IQ4_XS's 4.25, which is suggestive but not proof. Treat the first launch
> as the test: if it crashes on the Arc iGPU the way k-quants do, fall back to 6
> or 7. Of that repo's five GGUFs, `APEX-Compact` is the one used here because
> the two full `APEX` builds (25.7 / 26.6 GB) leave too little of the 32 GB for
> the OS and KV cache, `Q8_K_P` (43.6 GB) does not fit at all, and the `MTP`
> builds spend ~0.9 GB on a multi-token-prediction head that only pays off under
> speculative decoding — which does not pay on an A3B MoE, whatever the hardware
> (see [Speculative Decoding](#speculative-decoding)). So the extra memory would
> buy nothing here.
>
> **Choice 9 (Muse Glimmer 30B) carries two caveats of its own.** It is a dense
> model, not MoE, so it reads all ~29.6B params every token; the bandwidth math
> in `model-research/Qwen` predicts dense models this large land around 5-8
> tok/s on this hardware, well under the MoE models above. Its repo also ships
> **only K-quants** — there is no IQ-quant to fall back to the way choices 6 and
> 7 use IQ4_XS to dodge the Arc 140V k-quant crash, so this one is genuinely
> unverified against that bug and has no in-repo fallback if it hits it.
>
> **Choice 13 (Qwen3.8-2B-Distill) is untested against a different problem: the
> architecture itself, not a quant.** It's on the newer Qwen3.5 architecture — a
> hybrid of full-attention and Gated DeltaNet layers — and its model card states
> plainly that a recent llama.cpp build with Qwen3.5 / Gated DeltaNet support is
> required, with older builds failing to load it outright. Whether this
> project's pinned `LLAMA_TAG` (see [Pinned llama.cpp Version](#pinned-llamacpp-version))
> is new enough was not confirmed when this entry was added. If the server
> errors on load instead of merely running slowly, that's the first thing to
> suspect — try a newer `LLAMA_TAG` before assuming the download is bad.

## Vulkan Driver

This project ships **two** llama.cpp builds and runs the **GPU** one by default.
`setup.sh` installs the plain CPU build, which works everywhere but leaves any
GPU in the machine idle. `setup-with-vulkan.sh` installs a second,
**GPU-accelerated** build that offloads the model to your graphics hardware via
[Vulkan](https://www.vulkan.org/) — and since `start-server.sh` defaults to
`BACKEND=gpu`, that second install is the one it expects to find. The CPU build
remains the universal fallback, one environment variable away.

**What is Vulkan, and why use it here?** Vulkan is a cross-vendor, open standard
for talking to GPUs — both for graphics and for general compute. For local LLMs
it serves the same role that CUDA does for NVIDIA cards or ROCm does for AMD
cards: it lets llama.cpp run the model's math on the GPU instead of the CPU. The
big advantage of Vulkan is that it is *vendor-neutral*. CUDA only works on
NVIDIA hardware and ROCm only on certain AMD cards, and both can be painful to
install. Vulkan, by contrast, runs on Intel integrated graphics, AMD GPUs, and
NVIDIA GPUs alike, using the driver that ships with the OS. That makes it the
most practical way to get GPU acceleration on the kind of hardware that doesn't
have a discrete NVIDIA card.

**The two setups, side by side.** The scripts are deliberately independent and
non-destructive. `setup.sh` installs the CPU build into
`~/.local/lib/llama.cpp/`; `setup-with-vulkan.sh` installs the Vulkan build into
a *separate* directory, `~/.local/lib/llama.cpp-vulkan/`, under a separate
binary name. Because nothing overlaps, installing or removing the Vulkan build
never disturbs the working CPU build — to remove GPU support you can simply
delete the `-vulkan` directory (and set `BACKEND` in `start-server.sh` back to
`cpu`, since `gpu` is what it defaults to). You choose which one runs at launch
time with an environment variable:

```bash
./start-server.sh               # Vulkan build, offloads all layers to the GPU (default)
BACKEND=cpu ./start-server.sh   # CPU build (the universal fallback)
```

In `gpu` mode the server adds `--n-gpu-layers 99`, which offloads the entire
model onto the GPU. The Vulkan installer also runs a self-check at the end that
asks llama.cpp to enumerate GPU devices, so you'll know immediately whether your
hardware is usable before you try to serve a real model.

**This setup was tuned for one specific machine.** It was developed and tested
on a **Dell XPS laptop with an Intel Core Ultra 9 288V (Lunar Lake)**, which
pairs 8 CPU cores with an **Intel Arc 140V integrated GPU** and **32 GB of
on-package "unified" LPDDR5X memory**. "Unified" means the CPU and the GPU share
the same physical memory pool rather than the GPU having its own dedicated VRAM.
That architecture is what makes GPU offload attractive here: a discrete entry-
level GPU might only have 4–8 GB of VRAM and couldn't hold a ~6.7 GB model at
all, but because the Arc iGPU can address the shared 32 GB pool, it can host the
full model with room to spare. If you're on a similar unified-memory machine
(many recent Intel and AMD laptops, for example), this same approach should
apply with little or no change.

**What to realistically expect.** On a unified-memory system the GPU and CPU
draw from the *same* memory at the *same* bandwidth, so GPU offload does not
necessarily make token *generation* dramatically faster — that phase is limited
by memory bandwidth, not raw compute. Where the GPU clearly wins is **prompt
processing** (digesting a long prompt or document before the first token), which
is compute-bound, and in **freeing up the CPU** so the rest of the laptop stays
responsive while the model is working. On machines with a genuinely more capable
GPU than this little iGPU, the generation speedup can be much larger. In other
words, Vulkan offload is worth it even on modest "unified memory" / low-end-GPU
hardware, but the benefit shows up more in latency and system responsiveness
than in a giant tokens-per-second jump.

**Requirements and caveats.** This is **Linux-only** (developed on Ubuntu) — the
scripts download prebuilt Ubuntu x86_64 binaries and rely on the system's
Mesa-provided Vulkan driver, so they do not apply to macOS or Windows. The
Vulkan path needs a reasonably **recent Mesa driver**: on brand-new GPUs (this
laptop included) the early drivers were too immature and GPU detection failed;
a later Mesa release fixed it. If `setup-with-vulkan.sh` reports that no GPU
device was found, updating your graphics/Mesa packages is the first thing to
try. The installer checks for the Vulkan loader (`libvulkan.so.1`) and an
appropriate driver up front and tells you what to install if anything is
missing. If GPU mode ever misbehaves, the CPU build is always one command away.

## Pinned llama.cpp Version

The setup scripts install **one specific llama.cpp release**, not whichever one
happens to be newest. The version lives in a single line near the top of each
script:

```bash
LLAMA_TAG="${LLAMA_TAG:-b10344}"
```

llama.cpp ships new releases constantly — often several a day. Without a pin,
re-running `./setup.sh` on some unrelated Tuesday would silently move you onto a
build you had never tested. That's a poor trade here specifically, because this
project depends on version-sensitive behavior: on the Arc 140V iGPU the model
has to be an `IQ4_XS` quant to dodge a known k-quant crash (see
[Switching Models](#switching-models) and `model-research/`). That is a
workaround for an upstream bug, so an upstream change can move it in either
direction.

The pin also means **setting up a new machine reproduces the exact build you are
running today**, rather than whatever is current whenever you get around to it.

The CPU and Vulkan builds are pinned independently, since they are separate
installs — though keeping the two tags in step is usually what you want.

### Seeing what you actually have

```bash
./check-current-versions.sh            # installed versions vs. the pinned ones
./check-current-versions.sh --latest   # also ask GitHub what the newest release is
```

```
── Vulkan build
   install dir: /home/you/.local/lib/llama.cpp-vulkan
   pinned in setup-with-vulkan.sh: b10344
   installed:   b10344  ✓ matches the pin
   size:        181M
```

This is read-only — it installs and changes nothing. It's the quickest way to
catch the case where you trialled a version with a one-off `LLAMA_TAG=` override
and forgot to update the pin afterwards, leaving disk and script disagreeing.

### Upgrading

1. **Find the newest tag** — `./check-current-versions.sh --latest`, or browse
   <https://github.com/ggml-org/llama.cpp/releases>. Tags look like `b10344`.
2. **Try it without committing.** Override the pin for a single run:
   ```bash
   LLAMA_TAG=b10350 ./setup-with-vulkan.sh
   ```
3. **Test it before trusting it:**
   ```bash
   ./start-server.sh     # does it load without crashing?
   ./status.sh           # healthy, serving the right model?
   ```
   `setup-with-vulkan.sh` also re-runs its GPU-detection check on every install,
   so you'll see immediately if a new release stopped recognizing your GPU.
4. **Happy?** Edit `LLAMA_TAG` in the script to the new tag to make it permanent.

### If an upgrade goes badly

Set `LLAMA_TAG` back to the previous tag and re-run the setup script. It
re-downloads that release and overwrites the install, putting you back exactly
where you were.

This does mean a rollback re-downloads (~100–200 MB) rather than restoring
something kept on disk. That's a deliberate trade: keeping every old build
around would complicate the install scripts considerably to save one short
download on a rare event. **Write the tag you are on somewhere before you
upgrade** — or just check `git log` on this repo, since the pin is committed
here — so you know what to set it back to.

Nothing about upgrading or rolling back touches your **models**. Program
binaries and model files live in separate trees:

```
~/.local/share/llama.cpp/models/    ← your .gguf files (many GB each)
~/.lmstudio/models/                 ← .gguf files downloaded by LM Studio
~/.local/lib/llama.cpp*             ← llama.cpp program binaries only
```

The setup scripts never write to `~/.local/share/` or to LM Studio's folder, so
reinstalling llama.cpp at any version — as many times as you like — never costs
you a model download.

## Backing Up Models
On Linux your GGUF files live in **two** folders, depending on what downloaded
them — back up both:

```
~/.local/share/llama.cpp/models/    ← fetched by ./download-model.sh
~/.lmstudio/models/                 ← downloaded through LM Studio
```

If you've relocated LM Studio's folder from its settings, check where it actually
points before trusting the second path:

```bash
jq -r .downloadsFolder ~/.lmstudio/settings.json
```

## Customization

### Server parameters

`start-server.sh` passes CLI flags directly to `llama-server`. You can override
settings on the command line:

```bash
./start-server.sh --port 9090 --ctx-size 8192 --threads 8
```

Common flags:
- `--port N` — HTTP port (default: 8080)
- `--ctx-size N` — Context window size in tokens (default: varies by model)
- `--threads N` — CPU threads (default: auto-detect)
- `--parallel N` — Request slots (default: 1; see [Request Slots](#request-slots))
- `--n-gpu-layers N` — Offload layers to GPU (Vulkan/CUDA/ROCm builds; see [Vulkan Driver](#vulkan-driver))

See `llama-server --help` for all options.

### Environment overrides

Everything tunable has an environment variable, so the common adjustments need
no edit to `start-server.sh`:

| Variable | Default | What it does |
|----------|---------|--------------|
| `BACKEND` | `gpu` | `cpu` or `gpu` — which build to launch ([Vulkan Driver](#vulkan-driver)) |
| `NGL` | `99` | Layers offloaded to the GPU (99 = all) |
| `THREADS` | `1` | Generation threads |
| `THREADS_BATCH` | `8` | Prefill threads |
| `FA` | `on` | Flash attention |
| `BATCH` | *(model)* | Prefill batch size (`-b`) |
| `SPEC` | `off` | Speculative decoding type ([below](#speculative-decoding)) |
| `REASONING` | *(menu)* | Skip the reasoning menu: `off`, `on`, `low`, `medium`, `high` ([below](#reasoning)) |
| `REASONING_BUDGET` | *(none)* | Hard token cap on thinking ([below](#reasoning)) |
| `SAMPLING` | *(menu)* | Skip the sampling menu: `creative`, `factual`, `strict` |
| `PARALLEL` | `1` | Request slots ([below](#request-slots)) |
| `LLAMA_MODELS` | `~/.local/share/llama.cpp/models` | Where `download-model.sh` puts models |
| `LMS_MODELS` | `~/.lmstudio/models` | LM Studio's model tree |

### Reasoning

After the model menu, `start-server.sh` asks how much thinking the model should
do. What it offers depends on the model you just picked:

```
=== Select a Reasoning Mode ===

  1) No reasoning   thinking suppressed entirely — fastest, fewest tokens
  2) Reasoning on   the model's own default thinking depth
  3) Low            think briefly, move straight to the conclusion
  4) Medium         think, with no instruction either way (baseline)
  5) High           think carefully: check assumptions, weigh alternatives
```

Entries **3-5 appear only for models that actually implement effort levels** —
today that is **Qwen3.8-27B, choices 10 and 12** (the LM Studio copy and the
unsloth one — same base model and template, so the same levels). Every other
model in the menu shows just 1 and 2, with a line saying so. The numbering is
stable either way, so
`REASONING=low` keeps its meaning when you switch models; ask a model for a level
it doesn't have and you get a note plus plain "on", not a failure.

**On/off and the levels are different mechanisms**, which is why one is
guaranteed and the other is a request:

| | Flag | What it really does |
|---|---|---|
| **Off** | `--reasoning off` | llama.cpp's own flag. Sets `enable_thinking` false, and the template emits a **closed, empty** `<think></think>` in the assistant prefix — so the model resumes after a thought it never had and can't open a new one. Zero thinking tokens, not fewer |
| **On** | `--reasoning on` | Thinking at whatever depth the model does by default |
| **Low / Medium / High** | `--chat-template-kwargs '{"reasoning_effort":"..."}'` | **Not a llama.cpp feature** — there is no reasoning-level flag; `--reasoning` takes only `on`/`off`/`auto`. The levels live in the *model's own chat template*, reached through the generic kwargs escape hatch. The template prepends a sentence of instruction to the system message, so the effect is prompting, and the model may ignore it |

Qwen3.8-27B's levels (choices 10 and 12) are literally `low`, `medium`, `xhigh` — **there is no
`high`** (the menu's "High" sends `xhigh`), and `xhigh` is also what "On" gives
you, being the template's default. Its `medium` deliberately injects *no*
instruction and is the un-nudged baseline.

`REASONING_BUDGET=N` is the blunt instrument the levels are not: it ends the
thought after N tokens by force, needs no cooperation from the template, and so
is the nearest thing to a "think less" control on models with no levels — at the
cost of possibly cutting a thought mid-sentence.

```bash
REASONING=low ./start-server.sh          # Qwen3.8-27B: brief thinking
REASONING=off ./start-server.sh          # any model: no thinking at all
REASONING_BUDGET=512 ./start-server.sh   # any model: hard cap on the thought
```

**Adding a model?** Whether it has levels is a property of that *GGUF's embedded
template*, not of the model family, so read it rather than assuming — then set
`REASONING_EFFORTS` in its branch (space-separated, empty for on/off only). The
quickest check is to make a small model wear the new one's template and ask the
server what it would send:

```bash
llama-server -m small.gguf --jinja --chat-template-file extracted.jinja \
  --chat-template-kwargs '{"reasoning_effort":"low"}' --port 8099 &
curl -s localhost:8099/apply-template -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
```

A kwarg a template doesn't read is simply unused, so a wrong guess costs you a
setting that silently does nothing — which is why the list is declared per model.

Everything here sets *server defaults*. A client that sends its own
`chat_template_kwargs` in the request body still wins for that request.

### Request Slots

A slot is one lane for an in-flight request. Left unset, llama.cpp picks for you
and announces it at startup — `n_parallel is set to auto, using n_parallel = 4
and kv_unified = true`. This project pins it to **1**, because the server backs a
single-user chat UI.

It is tempting to read "4 slots" as "4 KV caches" and assume dropping to 1
reclaims three of them. It does not: `kv_unified` (which auto mode enables) means
every sequence shares **one** pool of `--ctx-size` tokens, so on the transformer
models the extra slots cost almost nothing, and each slot still sees the full
context rather than a quarter of it.

The saving is specific to **hybrid SSM models like choice 10**, whose recurrent
state is *not* part of that shared pool. Those allocate a full state per
sequence, sized by the model rather than by the context length — roughly 150 MB
per slot for choice 10's 48 SSM layers. Auto's 4 slots therefore reserve ~600 MB
to serve one chat that can only ever use ~150 MB; pinning to 1 hands ~450 MB
back.

The trade is that concurrent requests queue instead of running side by side. For
one person typing in a chat box that is the right call — and arguably faster,
since two generations would only compete for the same LPDDR5X bandwidth. If you
drive this from something that fans requests out, raise it:

```bash
PARALLEL=4 ./start-server.sh
```

### Speculative Decoding

`SPEC` selects a `--spec-type`. Whether it helps **depends on the model, not on
the hardware** — an earlier version of these docs claimed speculation was simply
harmful on this laptop, which is true of the MoE entries and false in general.
The distinction is what decides the setting:

- **MoE (choices 6-8)** — only ~3B of 35B params are read per token. Verifying
  *k* drafted tokens in one batch activates the *union* of those tokens' experts,
  so the step reads **more** weight than *k* separate steps would. The draft has
  to be nearly always right just to break even, and it usually isn't. Leave it
  off. (This is also why choice 8's `MTP` builds are not worth their extra
  ~0.9 GB.)
- **Dense (choices 9, 10)** — every param is read every token: ~17 GB against the
  ~136 GB/s of LPDDR5X that sets the ~5-8 tok/s ceiling these entries warn about.
  Verifying *k* drafted tokens reads that 17 GB exactly **once**, so every
  accepted token is a whole weight-read saved. Here it is the largest single
  lever available.

Choice 10 is set up for this in the script: the model ships its own MTP
(multi-token prediction) head — `qwen35.nextn_predict_layers = 1`, with the
`blk.64.nextn.*` tensors already inside the 16.8 GB of weights — so
`SPEC="draft-mtp"` needs no draft model and no extra download. It drafts with a
head that is loaded either way.

Choice 12 is the same architecture and just as "dense" by this argument, but
its `SPEC` is left `off`: that repo (unsloth) ships the MTP head as a separate
`MTP/mtp-*.gguf` file rather than embedding it in the main quant, and that file
isn't fetched by `download-model.sh` option 12. Fetching it separately and
passing `--mtp-path` (or equivalent) would be the way to enable it there —
not done here, per the same "basic model only" scope as skipping vision.

Two things to keep in mind:

- **It is unverified, so treat the first run as the test.** A rejected draft has
  to rewind the recurrent state of choice 10's 48 SSM layers, which is the one
  place a hybrid model could misbehave where a plain transformer would not.
  Confirm the gain with `./status.sh` — a model is not obliged to draft *well*
  just because it can draft.
- **An explicit `SPEC=` in the environment beats the per-model branch**, unlike
  `FA` and `BATCH`. That exists precisely so you can A/B it:

```bash
SPEC=off ./start-server.sh    # override choice 10's draft-mtp
```

The `ngram-*` types are a different mechanism: self-speculative, no draft model,
and they mainly help rewrite/edit-style tasks where the output repeats long runs
of the input. Any other `--spec-type` value is passed through as-is.
