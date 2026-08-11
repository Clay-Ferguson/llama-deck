# Troubleshooting

Problems that don't fit neatly into `README.md`'s own Troubleshooting section —
usually because they're about the *process* of adding or updating a model
rather than about running the scripts day to day.

## ERROR: unknown model architecture

RESOLUTION: This was ultimately fixed by upgrading to version 'b10355' on 8/10/26

### TL;DR
the description below of this type of error, when it was first encountered 
essentially boils down to "You probably need to upgrade to latest LLAMA.CPP",
because essentially what had happened is that i tried to run a Meta (as in Facebook)
model that uses the `muse-glimmer` architecture before LLAMA.CPP had been updated
to handle that architecture, and so this error is what happens in that case.


### What it looks like

`./start-server.sh` prints its startup banner, then fails immediately with
something like:

```
E llama_model_load: error loading model: unknown model architecture: 'some-arch-name'
E llama_model_load_from_file_impl: failed to load model
E cmn  common_init_: failed to load model '/home/.../models/some-model.gguf'
E srv    load_model: failed to load model, '/home/.../models/some-model.gguf'
E srv  llama_server: exiting due to model loading error
```

The key line is `unknown model architecture: '<name>'`. This is **not** the
Arc 140V k-quant crash (see `model-research/Qwen` and the cautions in
`download-model.sh`/`start-server.sh`) — that one gets much further before
failing, usually with a GPU/Vulkan assertion or a crash during inference, not
an immediate, clean rejection during model load. This error happens before
llama.cpp even looks at the quant type.

### Why it happens

Every GGUF file embeds a `general.architecture` metadata field (e.g. `llama`,
`gemma3`, `qwen3moe`) that tells llama.cpp which internal model code to use to
build the compute graph. llama.cpp's supported architectures are a **fixed,
compiled-in list** — see `LLM_ARCH_NAMES` in
[`src/llama-arch.cpp`](https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp)
upstream. If a model's architecture isn't in that list *in the specific build
you have installed*, loading fails outright — the file itself is fine, your
download isn't corrupt, and there's nothing to fix in `download-model.sh` or
`start-server.sh`.

This project pins a specific llama.cpp release (`LLAMA_TAG` near the top of
`setup.sh` / `setup-with-vulkan.sh` — see README § "Pinned llama.cpp Version")
precisely so upgrades are deliberate rather than accidental. The downside is
that a **brand-new model architecture released after your pinned build** will
always hit this error, no matter how correct the rest of the setup is. New
architecture support has to be merged into llama.cpp upstream, and then
shipped in a tagged release, before your pin can pick it up.

### How to confirm and fix it

1. **Confirm the pinned build predates the architecture.** Note the exact
   architecture name from the error (e.g. `muse-glimmer`), then check whether
   it exists in llama.cpp's current `master`:
   ```
   https://github.com/ggml-org/llama.cpp/blob/master/src/llama-arch.cpp
   ```
   Search that file (or ask an agent to) for the architecture name. If it's
   there, support exists upstream — you just need a new enough build. If it's
   genuinely absent from `master` too, the model isn't supported by llama.cpp
   yet at all, and no amount of upgrading will fix it until someone adds it.

2. **Find when support was added**, so you know how new a build you need. Search
   GitHub issues/PRs for the architecture name, e.g.:
   ```
   https://github.com/ggml-org/llama.cpp/issues?q=<architecture-name>
   ```
   Look for a merged PR titled something like "model: `<Name>` support" and
   note its merge date/commit.

3. **Check what's actually installed vs. pinned vs. newest available:**
   ```bash
   ./check-current-versions.sh            # installed vs. pinned
   ./check-current-versions.sh --latest   # also asks GitHub for the newest tag
   ```

4. **Check whether even the newest published release is new enough.** llama.cpp
   cuts releases frequently (often several a day), but a same-day merge can
   still be a handful of commits ahead of the latest tag. To check without
   downloading anything, compare the merge commit against a release tag:
   ```bash
   curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/compare/<tag>...<merge-commit-sha>"
   ```
   Look at `"ahead_by"` / `"behind_by"` in the JSON: if `ahead_by` is 0, the
   tag already includes the merge; if it's greater than 0, the tag is that
   many commits short and doesn't have it yet.

5. **If a qualifying release exists, try it without committing to it** (per
   README § "Upgrading"):
   ```bash
   LLAMA_TAG=b10XXX ./setup-with-vulkan.sh   # or ./setup.sh for the CPU build
   ./start-server.sh                          # pick the new model's menu number
   ```
   If it loads and runs cleanly, make it permanent by editing `LLAMA_TAG` in
   `setup.sh` / `setup-with-vulkan.sh` to that tag.

6. **If no qualifying release exists yet**, your options are: wait (check back
   with `./check-current-versions.sh --latest` periodically — new releases
   land often), or build llama.cpp from source at a commit at/after the merge
   if you need it immediately (out of scope for this project's scripts, which
   only install prebuilt release binaries).

### Worked example: Muse Glimmer 30B (2026-08-10)

This happened for real when option **9 (Muse Glimmer 30B)** was added to this
project. Timeline:

- The pinned build was `b10229`, from well before this model existed.
- Its GGUF declares `general.architecture = "muse-glimmer"`.
- `./start-server.sh` (option 9) failed immediately with
  `unknown model architecture: 'muse-glimmer'`.
- Checking upstream: support had just been merged into llama.cpp `master` that
  same day, via [PR #26841](https://github.com/ggml-org/llama.cpp/pull/26841)
  ("model: Muse Glimmer Support"), merged 2026-08-10.
- Checking the newest available release at the time (`b10344`, published
  2026-08-10T16:24Z — the same day) showed it was still **5 commits behind**
  the merge commit, via the `compare` API call from step 4 above. So even
  upgrading to the latest release that existed at that moment would not have
  fixed it yet.
- Resolution: wait for a release tag that includes the merge, then
  `LLAMA_TAG=<that tag> ./setup-with-vulkan.sh`, test, and only then update the
  pin permanently.

**Note on release-tag timestamps.** `b10344` was *published* at 16:24Z, hours
after the Muse Glimmer PR merged at 11:07Z, and still did not contain it. Do
not reason from publication times — llama.cpp rebases on merge, so a release
cut later in the day can sit at an earlier commit than a PR that "merged"
earlier by wall clock. The `compare` API in step 4 is the only reliable check.

### Follow-up: the upgrade to b10344 (2026-08-10, later the same day)

The pin was moved to the newest release anyway — upgrading was worth doing on
its own merits, independent of Muse Glimmer. What that settled:

- Both builds were actually running `b9946` on disk, *older* than the `b10229`
  they claimed to be pinned at — the pin had been edited at some point without
  re-running the setup scripts. `./check-current-versions.sh` exists precisely
  to catch this, and did.
- `LLAMA_TAG` is now `b10344` in both `setup.sh` and `setup-with-vulkan.sh`,
  and both are installed and verified: Vulkan still detects the Arc iGPU, and
  option 6 (Qwen3.6-35B-A3B) benchmarks at **10.1 tok/s** generation against
  the ~10.4 tok/s recorded in README — no regression.
- Option 9 still fails with `unknown model architecture: 'muse-glimmer'`, as
  the commit math above predicted. Nothing is wrong with the model file or the
  scripts; `b10344` simply predates the merge. Re-check with
  `./check-current-versions.sh --latest` and upgrade again once a tag at or
  past the merge commit (roughly `b10349`+) is published.
- Noted in passing: `b10344` warns that llama.cpp's **default server port will
  change from 8080 to 9931** in a future release. This project sets `PORT`
  explicitly in `start-server.sh`, so nothing breaks — but a future upgrade
  will need `status.sh` and the MkBrowser base URL checked if that default is
  ever relied on.

This is also a useful moment to re-check the **other** open caution on option
9: it has no IQ-quant, so it's unverified against the separate Arc 140V
k-quant crash issue (see `model-research/Qwen`) — that risk is still live even
once the architecture itself loads.
