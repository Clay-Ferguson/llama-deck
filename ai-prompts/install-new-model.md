# Objective: Add a new model to the menus

Instructions to a Coding Agent for adding another model option to this project.

> Fill in the model you want before handing this over:
> **MODEL:** `<name, e.g. Qwen3.6-35B-A3B>`  —  **REPO:** `<HuggingFace repo>`  —  **QUANT/FILE:** `<the .gguf filename>`
> **SOURCE:** `<"LM Studio" if I already downloaded it there, or "download-model.sh" if it still needs fetching>`

this project is the set of bash scripts that install and run a local LLM, which MkBrowser talks to for its AI features. there aren't many files here, so please read all of them first to get a full understanding of how things work — `README.md`, `download-model.sh`, `start-server.sh`, and anything relevant in `model-research/`.

the important thing to understand before you change anything: models are **not** switched by commenting and uncommenting variables anymore. both `download-model.sh` and `start-server.sh` present an interactive numbered menu and then branch on the answer in a `case` block.

**where the model comes from decides how much you touch.** I now get most models through LM Studio, which downloads into its own tree, so `start-server.sh` is the source of truth for what can be served and `download-model.sh` is the legacy path:

- **model downloaded through LM Studio** → add a branch to **`start-server.sh` only**. do not add anything to `download-model.sh`; it did not fetch this file and must not pretend it can.
- **model to be fetched by `./download-model.sh`** → add a branch to **both** scripts, at the same number in each.

so the two menus are *expected* to drift apart, and a gap in `download-model.sh`'s numbering is correct, not a bug to tidy up. never renumber existing entries to close one.

adding a model is otherwise purely additive, and nothing existing should be removed or commented out. for each script you are touching, add:

1. one new `echo` line in the menu listing, matching the existing column alignment and the `~X.X GB` size hint style. mark LM Studio-sourced entries with a `[LM Studio]` tag the way option 10 does.
2. one new numbered branch in the `case` block, placed in the same order as the menu

what each branch needs to set:

- **`download-model.sh`** — `MODEL_REPO`, `MODEL_FILE`, and `MODEL_SIZE_HINT`
- **`start-server.sh`** — **`MODEL_PATH`** (the *full* path, not a bare filename) and `CTX_SIZE`, plus optional `FA` (flash-attention on/off) and `BATCH` (prefill batch size, `-b`) if this model needs something other than the defaults declared just above the menu. only override those if there's a documented reason, and put the reason in a comment.

build `MODEL_PATH` from one of the two roots defined above the menu — `"$LLAMA_MODELS/<file>.gguf"` for anything `download-model.sh` fetches, `"$LMS_MODELS/<publisher>/<repo>/<file>.gguf"` for anything from LM Studio. a literal absolute path is fine too if the model lives somewhere else entirely.

**finding the path of an LM Studio model — do not guess it.** LM Studio picks the `<publisher>/<repo>` folder from its own catalog and it does *not* match the model key shown in the app: Qwen3.8-27B displays as `qwen/qwen3.8-27b` but sits under `lmstudio-community/Qwen3.8-27B-GGUF/`. `lms ls --json` reports that same normalized key rather than a file path, so it cannot answer this either. look on disk instead, and copy the real path:

```bash
find ~/.lmstudio/models -name '*.gguf' -printf '%T@ %p\n' | sort -rn | head -5
```

verify the file exists at the path you wrote before telling me it's ready.

follow the commenting style already in the existing branches: a short block explaining what the model is, why this particular quant was chosen, and any hardware-specific gotcha (the Arc 140V iGPU has a known k-quant crash, which is why the big MoE models here use `IQ4_XS` — check `model-research/` for anything similar affecting the new model).

if the new model should become the one I get by pressing Enter, also update the default in every script you touched — that's the `[6]` in the `read -rp "Model [6]: "` prompt and the `${MODEL_CHOICE:-6}` fallback in the `case` statement. otherwise leave the default alone. (an LM Studio-sourced model can only be the default in `start-server.sh`, since it has no `download-model.sh` entry.)

then update `README.md`:

- add a row to the model table in the **Switching Models** section (params, quant, file size, context, notes)
- update the menu listing quoted in that same section so it matches the real menu
- move the **Current default** marker if the default changed

finally, please let me know what I need to run to download and serve the new model, including which menu number to pick.
