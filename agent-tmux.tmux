#!/usr/bin/env bash
# agent-tmux — TPM entrypoint.
#
# Installs status row 1 (numbered session pills + picker button), the pickers,
# and the agent state colors. Everything is driven by @agent_tmux_* options read
# once here, at load time.
set -u

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

opt(){ local v; v="$(tmux show-option -gqv "$1" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

ROW="$(opt @agent_tmux_row 1)"
BAND="$(opt @agent_tmux_band '#181825')"
INTERVAL="$(opt @agent_tmux_status_interval 15)"
PATHS="$(opt @agent_tmux_paths "$HOME/code")"
PICKER="$(opt @agent_tmux_picker "$DIR/scripts/tmux-sessionizer")"
JUMP="$(opt @agent_tmux_jump_keys prefix)"     # prefix | chord | both | off
COLORS="$(opt @agent_tmux_colors on)"          # on | off
BUTTON="$(opt @agent_tmux_button_label '+')"

SESSIONS="$DIR/scripts/tmux-sessions"
STATUS="$DIR/scripts/agent-status.sh"

# ---------------------------------------------------------------- status row --
# Row 0 is left completely alone: whatever theme the user runs owns it. We only
# add a row and paint row $ROW. catppuccin & friends never write status-format,
# so this composes regardless of plugin load order.
tmux set-option -g status 2
tmux set-option -g status-format[$ROW] \
  "#[fill=$BAND]#[bg=$BAND,align=left] #($SESSIONS status '#S')"
tmux set-option -g status-interval "$INTERVAL"

# The pills only change when the session list or the attached session changes,
# so redraw on those events instead of polling once a second forever.
for h in session-created session-closed session-renamed client-session-changed client-attached; do
  tmux set-hook -ga "$h" 'refresh-client -S' 2>/dev/null
done

# ------------------------------------------------------------------ pickers --
tmux set-environment -g MUX_PATHS "$PATHS"

tmux bind-key p display-popup -E "$PICKER"

tmux bind-key o display-popup -E "tmux list-sessions -F '#{session_name}' | \
  fzf --reverse --border --border-label=' sessions ' \
    --preview 'tmux capture-pane -pt {}' \
    --bind 'ctrl-d:execute(tmux kill-session -t {})+reload(tmux list-sessions -F \"#{session_name}\")' | \
  xargs -I{} tmux switch-client -t '{}'"

# -------------------------------------------------------------- jump / click --
# prefix+1..9 works on every terminal with no extra setup. The Ctrl+Alt+N chord
# is faster but needs the terminal to emit CSI-u (see README) — opt in with
# @agent_tmux_jump_keys 'chord' or 'both'.
case "$JUMP" in
  prefix|both)
    for n in 1 2 3 4 5 6 7 8 9; do
      tmux bind-key "$n" run-shell "$SESSIONS jump $n '#{client_name}'"
    done ;;
esac
case "$JUMP" in
  chord|both)
    for n in 1 2 3 4 5 6 7 8 9; do
      tmux bind-key -n "C-M-$n" run-shell "$SESSIONS jump $n '#{client_name}'"
    done ;;
esac

# Click routing for the status bar:
#   session_N -> switch to that session
#   picker    -> open the project picker (display-popup needs the client context
#                that a key binding has and run-shell does not)
#   anything else (i.e. row 0's window tabs) -> stock select-window
tmux bind-key -n MouseDown1Status if-shell -F '#{m:session_*,#{mouse_status_range}}' \
  "run-shell \"$SESSIONS click '#{mouse_status_range}' '#{client_name}'\"" \
  "if-shell -F '#{==:#{mouse_status_range},picker}' \
     'display-popup -E \"$PICKER\"' \
     'select-window -t ='"

# ------------------------------------------------------------ agent  colors --
if [ "$COLORS" != "off" ]; then
  tmux bind-key g run-shell "TMUX_PANE='#{pane_id}' $STATUS done </dev/null"
  tmux bind-key G run-shell "TMUX_PANE='#{pane_id}' $STATUS clear </dev/null"
fi

# Expose the resolved locations so users can reference them from their own conf
# (and so `notify = [...]` in ~/.codex/config.toml is easy to write).
tmux set-option -g @agent_tmux_dir "$DIR"
tmux set-option -g @agent_tmux_button_label "$BUTTON"
