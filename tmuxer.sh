#!/usr/bin/env bash
#
# tmuxer.sh — Run a long-lived script inside a tmux session, so the window it
# prints to can be closed without taking the process down with it.
#
# Usage: tmuxer.sh SESSION SCRIPT_TO_RUN
#
#   SESSION         name of the tmux session to create or reattach to
#   SCRIPT_TO_RUN   absolute path of the script the session should run
#
# A script that ends in `exec` makes its process the terminal's only process:
# closing that window SIGHUPs it. tmux breaks that coupling — the session owns
# the process, and windows merely attach to the session.
#
#   Run this the first time → the process starts; you watch it come up.
#   Ctrl+B then D           → detaches. The window closes, the process keeps running.
#   Run it again later      → reattaches to the same live output and scrollback.
#
# Closing the window with the mouse is just as safe as detaching: that kills
# the tmux client, not the session.
#
set -uo pipefail

# Hold the window open on the error paths — this script runs as a terminal's
# only process, so without this its output would vanish with the window.
hold() { printf '\n%s' "$1"; read -r; }

if [[ $# -ne 2 ]]; then
  hold "Usage: $(basename "$0") SESSION SCRIPT_TO_RUN
Press Enter to close…"
  exit 1
fi

SESSION="$1"
SCRIPT_TO_RUN="$2"

if ! command -v tmux >/dev/null 2>&1; then
  hold "tmux is not installed.  Install it with:  sudo apt install tmux
Press Enter to close…"
  exit 1
fi

if [[ ! -x "$SCRIPT_TO_RUN" ]]; then
  hold "Not an executable script:  $SCRIPT_TO_RUN
Press Enter to close…"
  exit 1
fi

# A session whose process has already exited (crashed, or stopped deliberately)
# is debris. Attaching to it would show a dead pane and never start anything,
# so clear it and fall through to a fresh launch.
# remain-on-exit — set below — is what makes the dead pane detectable here
# instead of the session silently disappearing along with the error output.
if tmux has-session -t "$SESSION" 2>/dev/null; then
  if [[ "$(tmux list-panes -t "$SESSION" -F '#{pane_dead}' 2>/dev/null | sort -u)" == "1" ]]; then
    tmux kill-session -t "$SESSION" 2>/dev/null
  fi
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  # remain-on-exit keeps the pane, and its output, after the process exits, so a
  # failure to start stays readable instead of taking the session down with it.
  #
  # It must be set in this same tmux invocation, not a following one: the most
  # likely real failure (a port already in use, say) exits in milliseconds, and
  # a second `tmux` process cannot win that race — the session is already gone,
  # taking the error message with it. Chained with \; the tmux server applies
  # both back-to-back, before it reaps the child.
  tmux new-session -d -s "$SESSION" "$(printf '%q' "$SCRIPT_TO_RUN")" \
    \; set-option -t "$SESSION" remain-on-exit on \
    \; set-option -t "$SESSION" status-right " Ctrl+B D = detach (process keeps running) "
fi

if ! tmux attach-session -t "$SESSION" 2>/dev/null; then
  # Two very different failures, and saying the wrong one sends you hunting a
  # problem that isn't there: the session may be gone (the process died before
  # it could be attached to), or alive and merely unattachable from here.
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    hold "The tmux session exists, but this window could not attach to it.
See it from any terminal with:  tmux attach -t $SESSION
Press Enter to close…"
  else
    hold "The process exited immediately, before its output could be captured.
Run $SCRIPT_TO_RUN directly to see why.
Press Enter to close…"
  fi
  exit 1
fi
