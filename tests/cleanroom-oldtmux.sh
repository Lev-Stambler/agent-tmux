#!/usr/bin/env bash
# Runs INSIDE a container whose tmux is older than the plugin's 3.2 floor.
# display-popup is 3.2+, so without a version gate the status row installs while
# every key binding silently fails. The gate must refuse, and leave a reason.
set -u
mkdir -p "$HOME/.tmux/plugins"
cp -r "${AGENT_TMUX_SRC:-/srv/agent-tmux}" "$HOME/.tmux/plugins/agent-tmux"
printf "run '%s/.tmux/plugins/agent-tmux/agent-tmux.tmux'\n" "$HOME" > "$HOME/.tmux.conf"
tmux -L old -f "$HOME/.tmux.conf" new-session -d -s a 2>/dev/null
echo "tmux=$(tmux -V)"
echo "rows=$(tmux -L old show-options -gv status 2>&1)"
echo "bound=$(tmux -L old list-keys -T prefix p >/dev/null 2>&1 && echo yes || echo no)"
echo "err=$(tmux -L old show-option -gv @agent_tmux_error 2>&1)"
tmux -L old kill-server 2>/dev/null
