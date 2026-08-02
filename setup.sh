#!/usr/bin/env bash
#
# setup.sh — Download and install prebuilt llama.cpp binaries
#
# Downloads a specific, pinned llama.cpp release for Ubuntu x64 from GitHub,
# extracts everything into ~/.local/lib/llama.cpp/, and creates symlinks
# in ~/.local/bin/ for the main executables. Keeping binaries and shared
# libraries in the same directory is required because llama-server loads
# its CPU backends (libggml-cpu-*.so) via dlopen() from the executable's
# own directory.
#
set -euo pipefail

# ── Pinned llama.cpp version ─────────────────────────────────────────────
# This is a fixed release tag, not "whatever is newest". Re-running this
# script — today, or on a brand-new machine a year from now — reinstalls this
# exact build. That reproducibility is the whole point: this project depends on
# version-sensitive behavior (the Arc iGPU quant workaround described in
# README.md), so drifting onto an untested llama.cpp release by accident is a
# real risk.
#
# TO UPGRADE — this is a deliberate, manual act:
#   1. Find the newest tag:   ./check-current-versions.sh --latest
#      (or browse https://github.com/ggml-org/llama.cpp/releases — tags look
#      like "b10229")
#   2. Try it without editing this file:   LLAMA_TAG=b10310 ./setup.sh
#   3. Test it:  ./start-server.sh && ./status.sh    and  ./benchmark.sh
#   4. If it works, edit the line below to that tag to make it permanent.
#
# IF AN UPGRADE GOES BADLY: set the line below back to the previous tag and
# re-run this script. It re-downloads that release from GitHub and overwrites
# the install, putting you back exactly where you were.
LLAMA_TAG="${LLAMA_TAG:-b10229}"
# ─────────────────────────────────────────────────────────────────────────

BIN_DIR="$HOME/.local/bin"
LIB_DIR="$HOME/.local/lib/llama.cpp"
MODELS_DIR="$HOME/.local/share/llama.cpp/models"
TEMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "=== llama.cpp Setup (pinned version: $LLAMA_TAG) ==="
echo ""

# Ensure install directories exist
mkdir -p "$BIN_DIR"
mkdir -p "$LIB_DIR"
mkdir -p "$MODELS_DIR"

# Check if llama-server is already installed
if command -v llama-server &>/dev/null; then
  echo "llama-server is already installed:"
  llama-server --version 2>&1 || true
  echo ""
  read -rp "Re-install / update? (y/N) " answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    echo "Skipping install."
    exit 0
  fi
fi

# Detect architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
  echo "ERROR: This script supports x86_64 only (detected: $ARCH)."
  echo "Visit https://github.com/ggml-org/llama.cpp/releases for other architectures."
  exit 1
fi

echo "Fetching llama.cpp release $LLAMA_TAG from GitHub..."
if ! RELEASE_JSON=$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/$LLAMA_TAG"); then
  echo "ERROR: no llama.cpp release found for tag '$LLAMA_TAG'."
  echo "Check the pinned LLAMA_TAG near the top of this script."
  echo "Available releases: https://github.com/ggml-org/llama.cpp/releases"
  exit 1
fi

# Find the Ubuntu x64 binary asset (tar.gz archive)
# Pattern: llama-b{N}-bin-ubuntu-x64.tar.gz (plain CPU build, no vulkan/rocm/openvino)
ASSET_URL=$(echo "$RELEASE_JSON" \
  | grep -oP '"browser_download_url":\s*"\K[^"]+' \
  | grep -P 'ubuntu-x64\.tar\.gz$' \
  | head -1)

if [[ -z "$ASSET_URL" ]]; then
  echo "ERROR: Could not find a suitable binary download for Ubuntu x64."
  echo "Check releases manually: https://github.com/ggml-org/llama.cpp/releases"
  exit 1
fi

FILENAME=$(basename "$ASSET_URL")
echo "Downloading $FILENAME..."
curl -fSL -o "$TEMP_DIR/$FILENAME" "$ASSET_URL"

echo "Extracting..."
mkdir -p "$TEMP_DIR/extracted"
tar -xzf "$TEMP_DIR/$FILENAME" -C "$TEMP_DIR/extracted"

# Find the directory containing the extracted files
EXTRACT_DIR=$(find "$TEMP_DIR/extracted" -name "llama-server" -type f -printf '%h\n' | head -1)
if [[ -z "$EXTRACT_DIR" ]]; then
  echo "ERROR: llama-server binary not found in the downloaded archive."
  echo "Contents of archive:"
  find "$TEMP_DIR/extracted" -type f | head -20
  exit 1
fi

# Install everything (binaries + libraries) into LIB_DIR so that
# llama-server can find its dynamically-loaded backends via dlopen().
echo "Installing to $LIB_DIR ..."
find "$EXTRACT_DIR" \( -name '*.so*' -o -name 'llama-*' -o -name 'rpc-server' \) \
  \( -type f -o -type l \) -exec cp -a {} "$LIB_DIR/" \;
chmod +x "$LIB_DIR"/llama-* 2>/dev/null || true

# Create symlinks in BIN_DIR for convenient PATH access
ln -sf "$LIB_DIR/llama-server" "$BIN_DIR/llama-server"
if [[ -f "$LIB_DIR/llama-cli" ]]; then
  ln -sf "$LIB_DIR/llama-cli" "$BIN_DIR/llama-cli"
fi

echo ""
echo "=== Installation Complete ==="
echo "  Version      → $LLAMA_TAG"
echo "  Install dir  → $LIB_DIR/"
echo "  llama-server → $BIN_DIR/llama-server (symlink)"

# Verify it works
if command -v llama-server &>/dev/null; then
  echo ""
  llama-server --version 2>&1 || true
else
  echo ""
  echo "NOTE: $BIN_DIR is not on your PATH."
  echo "Add this to your ~/.bashrc:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo "Models directory: $MODELS_DIR"
echo ""
echo "Next step: run ./download-model.sh to download the Gemma 4 model."
