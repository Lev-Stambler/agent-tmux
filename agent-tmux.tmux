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

# Clicking the status bar needs `range=user|X` and #{mouse_status_range}, which
# landed in tmux 3.4 -- NOT 3.2. Confirmed by inspecting the shipped binaries:
# the symbol is absent from Ubuntu 22.04's 3.2a and Debian 12's 3.3a and present
# in 3.4. Below 3.4 the rail and the colours render fine and every key binding
# works; only the mouse is dead, so warn rather than refuse.
CLICKABLE=1
if [ "$v_maj" -eq 3 ] && [ "$v_min" -lt 4 ]; then
  CLICKABLE=0
  tmux set-option -g @agent_tmux_warning \
    "agent-tmux: tmux $ver cannot report status-bar clicks (needs 3.4); the rail renders but is not clickable - use prefix+1..9 and the menu key" 2>/dev/null
fi

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
# '#{client_width}' is expanded PER CLIENT before the job runs, and tmux caches
# job output by command string -- so a laptop and a phone attached to the same
# session at the same time get different rows. Verified: two real clients at 140
# and 59 columns each ran the job with their own width, and a resize re-ran it
# with no client-resized hook needed.
tmux set-option -g status-format[$ROW] \
  "#[fill=$BAND]#[bg=$BAND,align=left] #($SESSIONS status '#S' '#{client_width}')"
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
# `refresh-client -S` with no -t refreshes ONE client, so with a phone and a
# laptop attached the other one keeps a stale rail until the status interval.
# The `refresh` subcommand walks every attached client instead.
refresh_cmd="run-shell -b \"$SESSIONS refresh\""
for h in session-created session-closed session-renamed client-session-changed client-attached; do
  # migrate off the v1 single-client hook if it is still installed
  tmux show-hooks -g 2>/dev/null | grep -q "^$h\(\[[0-9]*\]\)\? .*refresh-client -S 2" \
    && tmux set-hook -gu "$h" 2>/dev/null
  tmux show-hooks -g 2>/dev/null | grep -q "^$h\(\[[0-9]*\]\)\? .*tmux-sessions refresh" && continue
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

# The hamburger menu, reachable without a mouse: plenty of mobile SSH clients
# never send mouse events, and it is the only way to reach another session once
# the rail has collapsed.
MENUKEY="$(opt @agent_tmux_menu_key 'm')"
[ "$MENUKEY" = off ] || tmux bind-key "$MENUKEY" run-shell -b "$SESSIONS menu '#{client_name}'"

# Seed the staged menu so the very first tap works, before any status redraw.
tmux set-option -g @agent_menu_cmd "$("$SESSIONS" menu-cmd "" 0 2>/dev/null)" 2>/dev/null

# Click routing for the status bar:
#   session_N -> switch to that session
#   picker    -> open the project picker (display-popup needs the client context
#                that a key binding has and run-shell does not)
#   anything else (i.e. row 0's window tabs) -> stock select-window
# Routing branches on WHICH ROW was clicked before it looks at range names. That
# makes row 0's window tabs untouchable by construction, rather than relying on
# nothing else ever emitting a session_* range.
#
# Everything past that lives in `tmux-sessions click`, not in nested if-shell:
# the script takes the client explicitly and passes it to display-popup/-menu
# with -c, so it has the client context that run-shell alone does not. That
# keeps the routing in testable bash instead of four levels of tmux quoting.
# The `menu` branch MUST be `run-shell -C`, not a plain run-shell. display-menu
# sets MENU_NOMOUSE when the invoking command has no mouse event, and such a menu
# ignores every press and closes on every release -- a tap opens literally
# nothing. `run-shell -C` runs a tmux command on the SAME queue item, keeping the
# mouse event; -O then stops the release half of the opening tap dismissing it.
# Verified both ways with injected SGR mouse sequences.
# Routing, and why it looks like this.
#
# `if-shell` runs its chosen branch as a NEW command-queue item, which does not
# carry the mouse event. display-menu sets MENU_NOMOUSE when the invoking command
# has no mouse event, and such a menu ignores every press and closes on every
# release -- so a menu opened behind an if-shell literally cannot be tapped.
# Measured: bound directly, a tap opens the menu and it stays; behind one
# if-shell, the identical command opens nothing.
#
# So there is exactly ONE command here, `run-shell -C`, which runs a tmux command
# on the SAME queue item and keeps the mouse event. The branching is done in the
# FORMAT instead, and every branch is a bare option reference -- never an inline
# command -- because a #{?a,b,c} branch cannot contain a comma, and the menu
# command line is full of them.
tmux set-option -g @agent_tmux_row0 'select-window -t ='
tmux set-option -g @agent_tmux_clickcmd \
  "run-shell -b \"$SESSIONS click #{mouse_status_range} #{client_name}\""
tmux bind-key -n MouseDown1Status run-shell -C \
  "#{?#{!=:#{mouse_status_line},$ROW},#{@agent_tmux_row0},#{?#{==:#{mouse_status_range},menu},#{@agent_menu_cmd},#{@agent_tmux_clickcmd}}}"

# ------------------------------------------------------------ agent  colors --
if [ "$COLORS" != "off" ]; then
  tmux bind-key g run-shell "TMUX_PANE='#{pane_id}' $STATUS done </dev/null"
  tmux bind-key G run-shell "TMUX_PANE='#{pane_id}' $STATUS clear </dev/null"
fi

# Expose the resolved locations so users can reference them from their own conf
# (and so `notify = [...]` in ~/.codex/config.toml is easy to write).
tmux set-option -g @agent_tmux_dir "$DIR"
tmux set-option -g @agent_tmux_button_label "$BUTTON"
