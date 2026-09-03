#!/usr/bin/env bash
# Drive a pane's agent state through the REAL agent-status.sh (same entrypoint the
# Claude/Codex hooks use). Usage: set-state.sh <tmux -L socket> <pane_id> <state>
#
# Setting $TMUX is the point: agent-status.sh resolves the pane through it, so
# without it the call lands on the user's DEFAULT tmux server instead of the
# throwaway one -- silently colouring the wrong machine's tabs.
sock="$1"; pane="$2"; state="$3"
AS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/agent-status.sh"
TMUX="$(tmux -L "$sock" display -p '#{socket_path},0,0' 2>/dev/null)" \
TMUX_PANE="$pane" bash "$AS" "$state" </dev/null
