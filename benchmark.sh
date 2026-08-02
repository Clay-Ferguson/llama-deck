#!/usr/bin/env bash
#
# benchmark.sh — Measure llama-server tokens-per-second from the command line
#
# Runs one small warmup inference plus one measured inference against an
# already-running llama-server, then prints the performance metrics.
#
# This script does NOT start or stop the server — start it yourself first with
# ./start-server.sh (which prompts for a model) and leave it running. Whatever
# model, backend, and speculative-decoding settings that server was launched
# with are what gets benchmarked here.
#
# Usage:
#   ./start-server.sh                        # in another terminal, pick a model
#
#   ./benchmark.sh                           # default prompt, 300 tokens
#   ./benchmark.sh -n 500                    # generate 500 tokens instead
#   ./benchmark.sh -p "Explain quicksort."   # custom prompt
#   ./benchmark.sh -f mydoc.md               # read the prompt from a file
#   PORT=9090 ./benchmark.sh                 # server on a non-default port
#
# The metrics come from llama-server itself (the `timings` object in the
# /completion response), so they are exact, not wall-clock estimates:
#   - prefill tok/s   — prompt-processing speed
#   - generation tok/s — the TPS number you usually care about
#   - draft acceptance — only shown when the server has speculative decoding on
#
set -euo pipefail

PORT="${PORT:-8080}"
BASE="http://127.0.0.1:${PORT}"

# ── Options ──────────────────────────────────────────────────────────────
N_PREDICT=300
PROMPT="Explain how binary search trees work, covering insertion, search, deletion, and balancing. Be thorough."

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) N_PREDICT="$2"; shift 2 ;;
    -p) PROMPT="$2"; shift 2 ;;
    -f) PROMPT="$(cat "$2")"; shift 2 ;;
    *)  echo "Unknown option: $1"; echo "Usage: ./benchmark.sh [-n tokens] [-p prompt] [-f prompt-file]"; exit 1 ;;
  esac
done

# ── Is anything listening? ───────────────────────────────────────────────
# Deliberately not `curl -f` / not matching '"ok"': a server that has unloaded
# the model after --sleep-idle-seconds answers /health with 503 but will wake up
# on the first request, so it is perfectly benchmarkable. All we want to catch
# here is "no server at all", which shows up as a connection failure.
if ! curl -sS -m 5 "$BASE/health" >/dev/null 2>&1; then
  echo "ERROR: nothing is answering at $BASE"
  echo "       Start a server first:  ./start-server.sh"
  exit 1
fi

# ── Warmup + measured run (python3 for robust JSON handling) ─────────────
echo "Benchmarking the server at $BASE"
echo "Running warmup inference (16 tokens)..."
echo "Running measured inference ($N_PREDICT tokens)..."
python3 - "$BASE" "$N_PREDICT" "$PROMPT" <<'PYEOF'
import json, sys, urllib.request

base, n_predict, prompt = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def post(path, payload, timeout=900):
    req = urllib.request.Request(base + path, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def completion(text, n):
    # Route through the model's chat template so instruct models behave.
    tmpl = post("/apply-template",
                {"messages": [{"role": "user", "content": text}]})["prompt"]
    return post("/completion", {"prompt": tmpl, "n_predict": n,
                                "temperature": 0, "cache_prompt": False})

completion("Say hello.", 16)          # warmup: shader compile, weight touch
resp = completion(prompt, n_predict)  # measured run

t = resp["timings"]
print()
print("=== Benchmark Results ===")
print(f"  Prompt tokens:    {t.get('prompt_n')}  "
      f"({(t.get('prompt_per_second') or 0):.1f} tok/s prefill)")
print(f"  Generated tokens: {t.get('predicted_n')}  "
      f"({(t.get('predicted_per_second') or 0):.1f} tok/s generation)")
draft = t.get("draft_n") or 0
if draft:
    acc = t.get("draft_n_accepted") or 0
    print(f"  Draft tokens:     {draft}  "
          f"({acc} accepted, {100 * acc / draft:.1f}%)")
print()
print("--- First lines of model output ---")
print("\n".join(resp.get("content", "").strip().splitlines()[:6]))
PYEOF

echo ""
echo "Done."
