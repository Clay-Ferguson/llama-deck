# Objective: Add a new model to the menus

Instructions to a Coding Agent for adding another model option to this project.

> Fill in the model you want before handing this over:
> **MODEL:** `<name, e.g. Qwen3.6-35B-A3B>`  —  **REPO:** `<HuggingFace repo>`  —  **QUANT/FILE:** `<the .gguf filename>`

this project is the set of bash scripts that install and run a local LLM, which MkBrowser talks to for its AI features. there aren't many files here, so please read all of them first to get a full understanding of how things work — `README.md`, `download-model.sh`, `start-server.sh`, and anything relevant in `model-research/`.

the important thing to understand before you change anything: models are **not** switched by commenting and uncommenting variables anymore. both `download-model.sh` and `start-server.sh` present an interactive numbered menu and then branch on the answer in a `case` block. the two menus have to stay in sync — the same model must be the same number in both scripts, because I pick the same number in each.

so adding a model is purely additive, and nothing existing should be removed or commented out. for each of the two scripts, add:

1. one new `echo` line in the menu listing, matching the existing column alignment and the `~X.X GB` size hint style
2. one new numbered branch in the `case` block, placed in the same order as the menu

what each branch needs to set:

- **`download-model.sh`** — `MODEL_REPO`, `MODEL_FILE`, and `MODEL_SIZE_HINT`
- **`start-server.sh`** — `MODEL_FILE` and `CTX_SIZE`, plus optional `FA` (flash-attention on/off) and `BATCH` (prefill batch size, `-b`) if this model needs something other than the defaults declared just above the menu. only override those if there's a documented reason, and put the reason in a comment.

follow the commenting style already in the existing branches: a short block explaining what the model is, why this particular quant was chosen, and any hardware-specific gotcha (the Arc 140V iGPU has a known k-quant crash, which is why the big MoE models here use `IQ4_XS` — check `model-research/` for anything similar affecting the new model).

if the new model should become the one I get by pressing Enter, also update the default in **both** scripts — that's the `[6]` in the `read -rp "Model [6]: "` prompt and the `${MODEL_CHOICE:-6}` fallback in the `case` statement. otherwise leave the default alone.

then update `README.md`:

- add a row to the model table in the **Switching Models** section (params, quant, file size, context, notes)
- update the menu listing quoted in that same section so it matches the real menu
- move the **Current default** marker if the default changed

finally, please let me know what I need to run to download and serve the new model, including which menu number to pick.
