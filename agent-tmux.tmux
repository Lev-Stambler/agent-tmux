#!/usr/bin/env bash
# agent-tmux — TPM entrypoint.
#
# Installs status row 1 (numbered session pills + picker button), the pickers,
# and the agent state colors. Everything is driven by @agent_tmux_* options read
# once here, at load time.
set -u

DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

# Version gate. display-popup is tmux 3.2+, and a plugin loaded via `run` has its
# stderr swallowed — so on an older tmux the status row installs fine while every
# single key binding silently fails, leaving a half-working plugin and no clue
# why. Verified on Ubuntu 20.04 (tmux 3.0a). Refuse loudly instead.
ver="$(tmux -V | sed 's/^tmux //; s/^next-//; s/[^0-9.].*$//')"
v_maj="${ver%%.*}"; v_min="${ver#*.}"; v_min="${v_min%%.*}"
case "$v_maj" in ''|*[!0-9]*) v_maj=0 ;; esac
case "$v_min" in ''|*[!0-9]*) v_min=0 ;; esac
if [ "$v_maj" -lt 3 ] || { [ "$v_maj" -eq 3 ] && [ "$v_min" -lt 2 ]; }; then
  msg="agent-tmux: needs tmux 3.2 or newer (found ${ver:-unknown}); not loaded"
  # Two channels on purpose. display-message only lands if a client is attached,
  # which is false while tmux.conf is first parsed but TRUE on prefix+I (the TPM
  # install) and prefix+R — the moments a user is actually looking. The option is
  # the durable record for anyone asking "why is nothing happening".
  tmux set-option -g @agent_tmux_error "$msg" 2>/dev/null
  tmux display-message -d 4000 "$msg" 2>/dev/null
  exit 0
fi

opt(){ local v; v="$(tmux show-option -gqv "$1" 2>/dev/null)"; [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$2"; }

ROW="$(opt @agent_tmux_row 1)"
BAND="$(opt @agent_tmux_band '#181825')"
# Empty by default: we deliberately do NOT write status-interval. tmux-sensible
# only lowers it (15 -> 5) while it is still exactly 15, so writing it here makes
# the result depend on plugin load order for no benefit — the row is redrawn by
# hooks, not by polling. Set the option explicitly to override.
INTERVAL="$(opt @agent_tmux_status_interval '')"
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
[ -n "$INTERVAL" ] && tmux set-option -g status-interval "$INTERVAL"

# The pills only change when the session list or the attached session changes,
# so redraw on those events instead of polling once a second forever.
#
# Two things this has to get right:
#  * Idempotency. set-hook -a APPENDS, and TPM re-runs this file on prefix+I
#    while tmux-sensible binds prefix+R to re-source the config. Without the
#    guard the array grows a duplicate every reload, forking N times per event.
#  * No client. session-created fires while a session is being built, before any
#    client is attached, and a bare `refresh-client -S` there prints
#    "no current client" into the pane. Redirecting inside run-shell swallows it.
refresh_cmd='run-shell -b "tmux refresh-client -S 2>/dev/null || true"'
for h in session-created session-closed session-renamed client-session-changed client-attached; do
  tmux show-hooks -g 2>/dev/null | grep -q "^$h\(\[[0-9]*\]\)\? .*refresh-client -S" && continue
  tmux set-hook -ga "$h" "$refresh_cmd" 2>/dev/null
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
