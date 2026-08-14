#!/usr/bin/env bash
#
# check-current-versions.sh — Report which llama.cpp builds you have installed
#
# READ-ONLY. This script changes nothing: it creates no directories, moves no
# files, deletes nothing, and downloads nothing (except with --latest, which
# only queries the GitHub API and reports the answer).
#
# Two uses:
#
#   ./check-current-versions.sh
#       Show the version of each installed build (CPU and Vulkan) and compare
#       it against the LLAMA_TAG pinned in setup.sh / setup-with-vulkan.sh, so
#       you can see at a glance whether what is on disk matches what the
#       scripts say should be there. They can drift apart if you tried a
#       version with a one-off LLAMA_TAG=... override and never edited the pin.
#
#   ./check-current-versions.sh --latest
#       Additionally ask GitHub what the newest llama.cpp release is. Use this
#       when deciding whether to upgrade. It installs nothing.
#
# See README.md § "Pinned llama.cpp Version" for the upgrade procedure.
#
set -uo pipefail   # deliberately no -e: keep going and report everything

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHOW_LATEST=0

case "${1:-}" in
  --latest) SHOW_LATEST=1 ;;
  "") ;;
  *)
    echo "Usage: ./check-current-versions.sh [--latest]"
    echo "  (no args)  report installed versions and the pinned versions"
    echo "  --latest   also ask GitHub what the newest release is"
    exit 1
    ;;
esac

# Read the pinned LLAMA_TAG out of a setup script without executing it.
pinned_tag() {
  grep -oP '^LLAMA_TAG="\$\{LLAMA_TAG:-\K[^}]+' "$SCRIPT_DIR/$1" 2>/dev/null
}

# Ask an installed llama-server what build it is. Prints e.g. "b10229".
installed_tag() {
  local dir="$1" n
  [[ -x "$dir/llama-server" ]] || return 1
  n=$(LD_LIBRARY_PATH="$dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      "$dir/llama-server" --version 2>&1 \
      | grep -oP 'version:\s*\K[0-9]+' | head -1)
  [[ -n "$n" ]] && echo "b$n"
}

report() {  # label, install dir, setup script
  local label="$1" dir="$2" script="$3"
  local pin have

  pin="$(pinned_tag "$script")"
  echo "── $label"
  echo "   install dir: $dir"
  echo "   pinned in $script: ${pin:-<could not read>}"

  if [[ ! -d "$dir" ]]; then
    echo "   installed:   NOT INSTALLED — run ./$script"
    echo ""
    return
  fi

  have="$(installed_tag "$dir")"
  if [[ -z "$have" ]]; then
    echo "   installed:   present, but llama-server would not report a version"
    echo "                (missing/broken binary — reinstall with ./$script)"
  elif [[ "$have" == "$pin" ]]; then
    echo "   installed:   $have  ✓ matches the pin"
  else
    echo "   installed:   $have  ✗ DOES NOT MATCH the pin ($pin)"
    echo "                Either edit LLAMA_TAG in $script to \"$have\" to keep"
    echo "                what you are running, or run ./$script to install $pin."
  fi
  echo "   size:        $(du -sh "$dir" 2>/dev/null | cut -f1)"
  echo ""
}

echo "=== llama.cpp installed versions ==="
echo ""

report "CPU build"    "$HOME/.local/lib/llama.cpp"        "setup.sh"
report "Vulkan build" "$HOME/.local/lib/llama.cpp-vulkan" "setup-with-vulkan.sh"

if [[ "$SHOW_LATEST" == "1" ]]; then
  echo "── Newest release on GitHub"
  LATEST=$(curl -fsSL --max-time 20 \
    "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest" 2>/dev/null \
    | grep -oP '"tag_name":\s*"\K[^"]+')
  if [[ -n "$LATEST" ]]; then
    echo "   $LATEST"
    echo ""
    echo "   To try it without editing anything:"
    echo "     LLAMA_TAG=$LATEST ./setup-with-vulkan.sh"
    echo "   If it works out, set LLAMA_TAG=\"$LATEST\" in the setup scripts."
    echo "   If it doesn't, set LLAMA_TAG back to the old tag and re-run."
  else
    echo "   (could not reach the GitHub API)"
    echo "   Browse manually: https://github.com/ggml-org/llama.cpp/releases"
  fi
  echo ""
fi

echo "Models (never touched by the setup scripts):"
echo ""

# Two trees, because start-server.sh can serve a model from either: the flat
# folder download-model.sh writes to, and LM Studio's nested one. See the
# Model Locations block in start-server.sh.
LLAMA_MODELS="${LLAMA_MODELS:-$HOME/.local/share/llama.cpp/models}"
LMS_MODELS="${LMS_MODELS:-$HOME/.lmstudio/models}"

echo "  llama-deck (./download-model.sh):"
if [[ -d "$LLAMA_MODELS" ]]; then
  echo "    $LLAMA_MODELS — $(du -sh "$LLAMA_MODELS" 2>/dev/null | cut -f1)"
  find "$LLAMA_MODELS" -maxdepth 1 -name '*.gguf' -printf '      %f\n' 2>/dev/null | sort
else
  echo "    $LLAMA_MODELS does not exist — run ./download-model.sh"
fi
echo ""

echo "  LM Studio:"
if [[ -d "$LMS_MODELS" ]]; then
  echo "    $LMS_MODELS — $(du -sh "$LMS_MODELS" 2>/dev/null | cut -f1)"
  # Printed as <publisher>/<repo>/<file> — that relative path is exactly what a
  # start-server.sh branch needs after "$LMS_MODELS/".
  find "$LMS_MODELS" -name '*.gguf' 2>/dev/null \
    | sed "s|^$LMS_MODELS/|      |" | sort
else
  echo "    $LMS_MODELS does not exist — LM Studio is not installed, or its"
  echo "    models folder was moved (check: jq -r .downloadsFolder ~/.lmstudio/settings.json)"
fi
