#!/usr/bin/env bash
# Drive a pane's agent state through the REAL agent-status.sh (same entrypoint the
# Claude/Codex hooks use). Usage: set-state.sh <tmux -L socket> <pane_id> <state>
sock="$1"; pane="$2"; state="$3"
TMUX="$(tmux -L "$sock" display -p '#{socket_path},0,0' 2>/dev/null)" \
TMUX_PANE="$pane" bash "$HOME/.config/tmux/agent-status.sh" "$state" </dev/null
