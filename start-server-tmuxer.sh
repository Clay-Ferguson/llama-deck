#!/usr/bin/env bash
#
# start-server_.sh — Start llama-server in a tmux session named "llama".
#
# All of the tmux handling lives in tmuxer.sh at the project root; this file
# only supplies the session name and the script to run. See tmuxer.sh for how
# detaching and reattaching behave.
#
set -uo pipefail

# This script, tmuxer.sh, and start-server.sh all live at the project root.
# Resolved from BASH_SOURCE rather than assumed from the cwd, since this may
# be launched from anywhere.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMUXER="$HERE/tmuxer.sh"

if [[ ! -x "$TMUXER" ]]; then
  # This script is a terminal's only process, so hold the window open or the
  # message vanishes along with it.
  printf '\nCannot find an executable tmuxer.sh at:  %s\nPress Enter to close…' "$TMUXER"
  read -r
  exit 1
fi

exec "$TMUXER" "llama" "$HERE/start-server.sh"
