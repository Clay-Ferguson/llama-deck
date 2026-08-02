# Llama Deck (llama.cpp-based Local LLM Backend)

Run local LLM models using [llama.cpp](https://github.com/ggml-org/llama.cpp). llama.cpp provides an OpenAI-compatible HTTP API, which
MkBrowser connects to via the `LLAMACPP` provider. The scripts in this project can be used to run any `LLAMA.CPP` model locally on your own hardware 
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

Then in MkBrowser **Settings → AI**:
- Select the **llama.cpp** model
- Verify the **llama.cpp Base URL** is `http://localhost:8080/v1`

## Web UI (Browser Chat)

You don't need MkBrowser — or any extra app — just to confirm the model is up.
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

If you change the port, update MkBrowser to match in **Settings → AI** by
setting the **llama.cpp Base URL** to `http://localhost:9090/v1`.

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
| `download-model.sh` | Download a quantized GGUF model to `~/.local/share/llama.cpp/models/` |
| `start-server.sh` | Launch the server on `localhost:8080`; selects CPU or GPU via the `BACKEND` env var (default: `gpu`) |
| `status.sh` | Report whether the server is up, what it's serving, and run a test inference (see [Verifying the Server](#verifying-the-server)) |
| `stop-server.sh` | Stop the running server |
| `server-lib.sh` | Shared helper *sourced* by the scripts above (not run directly) — locates and verifies the server process |
| `benchmark.sh` | Measure tokens-per-second: restarts the server, runs one timed inference, prints the metrics, shuts down (see [Speculative Decoding](#speculative-decoding)) |

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
healthy server, you can just use it (point MkBrowser at
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
| **Gemma 4 26B-A4B** | 3.8B active / 25.2B total (MoE) | UD-IQ4_XS | ~13.4 GB | 8192 | High quality; MoE keeps generation fast despite the large size |
| **Gemma 4 12B QAT** | 12B (dense) | UD-Q4_K_XL | ~6.7 GB | 16384 | Quantization-Aware Training; lower memory (~7 GB total), potentially faster, accuracy close to BF16 |
| **Gemma 4 12B** | 12B (dense) | Q4_K_M | ~7.1 GB | 16384 | Strong quality |
| **Gemma 4 E4B** | 4.5B effective (8B total) | Q4_K_M | ~5.0 GB | 16384 | Good balance |
| **Gemma 4 E2B** | 2.3B effective (5.1B total) | Q4_K_M | ~3.1 GB | 16384 | Lightest, fastest |

You don't edit anything to switch between them. Both `./download-model.sh` and
`./start-server.sh` open with the same menu, using the same numbering in each —
so a given model is choice **6** in both places:

```
=== Select a Model ===

  1) Gemma 4 E2B          2.3B effective params (~3.1 GB)
  2) Gemma 4 E4B          4.5B effective params (~5.0 GB)
  3) Gemma 4 12B          12B params, dense (~7.1 GB)
  4) Gemma 4 12B QAT      12B params, dense (~6.7 GB)
  5) Gemma 4 26B-A4B      3.8B active params, MoE (~13.4 GB)
  6) Qwen3.6-35B-A3B      ~3B active params, MoE (~17.7 GB)

Model [6]:
```

Press Enter to take the default (**6**, Qwen3.6-35B-A3B); anything outside 1-6
exits with an error rather than starting. So switching models is just:

```bash
./download-model.sh   # choose 5 → fetches Gemma 4 26B-A4B
./start-server.sh     # choose 5 → serves it
```

All model files can coexist on disk (they have different filenames), so you only
need `./download-model.sh` once per variant. From then on, switching is nothing
more than restarting `./start-server.sh` and picking a different number.

Because both scripts prompt, they need a real terminal — they can't be driven
from cron or a pipe as-is.

Per-model *settings* are not in the menu itself but in the `case` block just
below it in `start-server.sh`. Each branch sets `CTX_SIZE`, and may override `FA`
(flash-attention on/off) and `BATCH` (prefill batch size, `-b`); branches that
omit those fall back to the defaults declared just above the menu (`FA="on"`,
`BATCH=""`). At the moment Qwen3.6-35B-A3B is the only branch overriding
anything — it sets `BATCH="256"` — and every model runs with flash-attention on.

Adding a new model means editing the menu and `case` block in **both** scripts,
keeping the numbering aligned between them (see `ai-prompts/`).

> **Note:** Qwen3.6-35B-A3B uses `IQ4_XS` because the Arc 140V iGPU has a known
> crash with k-quants. Context is kept at 16384 to fit comfortably in 32 GB RAM alongside the ~17.7 GB
> weights, the OS, and KV-cache overhead.

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
LLAMA_TAG="${LLAMA_TAG:-b10229}"
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
   pinned in setup-with-vulkan.sh: b10229
   installed:   b10229  ✓ matches the pin
   size:        181M
```

This is read-only — it installs and changes nothing. It's the quickest way to
catch the case where you trialled a version with a one-off `LLAMA_TAG=` override
and forgot to update the pin afterwards, leaving disk and script disagreeing.

### Upgrading

1. **Find the newest tag** — `./check-current-versions.sh --latest`, or browse
   <https://github.com/ggml-org/llama.cpp/releases>. Tags look like `b10229`.
2. **Try it without committing.** Override the pin for a single run:
   ```bash
   LLAMA_TAG=b10310 ./setup-with-vulkan.sh
   ```
3. **Test it before trusting it:**
   ```bash
   ./start-server.sh     # does it load without crashing?
   ./status.sh           # healthy, serving the right model?
   ./benchmark.sh        # did tokens/sec regress?
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
~/.local/lib/llama.cpp*             ← llama.cpp program binaries only
```

The setup scripts never write to `~/.local/share/`, so reinstalling llama.cpp at
any version — as many times as you like — never costs you a model download.

## Backing Up Models
Normally on Linux your models will be stored under folder `~/.local/share/llama.cpp/models/` 
so if you want to backup all your models this is the folder to backup.

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
- `--n-gpu-layers N` — Offload layers to GPU (Vulkan/CUDA/ROCm builds; see [Vulkan Driver](#vulkan-driver))

See `llama-server --help` for all options.
