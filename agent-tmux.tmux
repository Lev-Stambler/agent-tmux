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

# Row 0 (the theme's window tabs) additions. Palette defaults match
# scripts/tmux-sessions so the two rows look like one bar.
ACCENT="$(opt @agent_tmux_accent '#cba6f7')"
BTN_BG="$(opt @agent_tmux_button_bg '#313244')"
BTN_FG="$(opt @agent_tmux_button_fg '#cba6f7')"
WBTNS="$(opt @agent_tmux_window_buttons on)"          # on | off
NEW_LBL="$(opt @agent_tmux_new_window_label '+')"
LR_LBL="$(opt @agent_tmux_split_lr_label '│')"
# Four columns of rule, not one: a single ─ in a pill reads as a minus sign,
# which is not what the button does. A phone gets the short one back -- measured,
# at 55 columns the four-column rule pushes the current window's tab off row 0
# entirely, and a tab you cannot see is worth more than a prettier glyph.
TB_LBL="$(opt @agent_tmux_split_tb_label '────')"
TB_LBL_N="$(opt @agent_tmux_split_tb_label_narrow '─')"
BTN_NARROW="$(opt @agent_tmux_buttons_width 60)"      # below this: drop the gaps
BTN_GAP="$(opt @agent_tmux_buttons_gap 3)"            # columns between the group and the tabs
PILL_BG="$(opt @agent_tmux_pill_bg '#313244')"
PANE_HL="$(opt @agent_tmux_pane_highlight on)"        # on | off
PANE_LINES="$(opt @agent_tmux_pane_border_lines heavy)" # single|double|heavy|simple|number
WBORDER="$(opt @agent_tmux_window_border on)"         # on | off
WB_L="$(opt @agent_tmux_window_border_left '▏')"
WB_R="$(opt @agent_tmux_window_border_right '▕')"

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

# ------------------------------------------------------- row 0: the buttons --
# Row 0 stays the theme's row: we PREPEND one reference to it and leave every
# other byte alone, so catppuccin & friends keep drawing the tabs.
#
# The group is a plain format, not a #() job: it never changes, and row 0 is
# redrawn far more often than row 1 -- a fork per redraw for three static pills
# would be pure waste. Being a format is also what makes it per-client: the
# narrow branch is chosen from #{client_width}, which tmux evaluates for the
# client it is drawing for, so a phone and a laptop on the same session each get
# the group that fits.
#
# It has to be reached as #{E:...}: a bare #{@opt} is substituted verbatim,
# NOT re-expanded, so the #{?...} inside it would reach the screen as text.
btn(){ # <range> <label>
  printf '#[range=user|%s]#[fg=%s,bg=%s,bold] %s #[norange]#[default]' \
         "$1" "$BTN_FG" "$BTN_BG" "${2//#/##}"
}
# Whichever row the rail did NOT take is the theme's, and that is where the
# buttons belong: @agent_tmux_row 0 moves the rail up, so the tabs move down.
TABROW=0; [ "$ROW" = 0 ] && TABROW=1
f0="$(tmux show-options -gv "status-format[$TABROW]" 2>/dev/null)"
if [ "$WBTNS" != "off" ]; then
  # Narrow keeps all three buttons at full size and drops only the gaps between
  # them: on a phone the tap target is the thing you cannot afford to shrink.
  # The gap after the group is not decoration: without it the last pill sits
  # flush against the theme's first tab and the two read as one control.
  case "$BTN_GAP" in ''|*[!0-9]*) BTN_GAP=3 ;; esac
  gap="$(printf "%${BTN_GAP}s" '')"
  tmux set-option -g @agent_tmux_buttons_wide \
    "$(btn agent_newwin "$NEW_LBL") $(btn agent_split_lr "$LR_LBL") $(btn agent_split_tb "$TB_LBL")$gap"
  # Narrow drops the gaps BETWEEN the pills and keeps one column before the
  # tabs -- the tap targets stay full size, which is the part that matters on a
  # phone, and the row gets 3 columns back.
  tmux set-option -g @agent_tmux_buttons_narrow \
    "$(btn agent_newwin "$NEW_LBL")$(btn agent_split_lr "$LR_LBL")$(btn agent_split_tb "$TB_LBL_N") "
  # Both branches are bare option references on purpose: a #{?a,b,c} branch is
  # split on the first top-level comma, and every pill is full of them.
  #
  # The breakpoint is the SIGN OF A SUBTRACTION, not #{<:}, because tmux's
  # comparison operators are string comparisons: #{<:100,60} is TRUE ("1" sorts
  # before "6"), so a 100-column laptop would have been served the phone row.
  # #{e|-|:...} is real arithmetic, and a leading '-' means "narrower than".
  tmux set-option -g @agent_tmux_buttons \
    "#{?#{m:-*,#{e|-|:#{client_width},$BTN_NARROW}},#{E:@agent_tmux_buttons_narrow},#{E:@agent_tmux_buttons_wide}}"
  case "$f0" in
    *'#{E:@agent_tmux_buttons}'*) ;;   # already installed; TPM re-runs this file
    *) tmux set-option -g "status-format[$TABROW]" "#{E:@agent_tmux_buttons}$f0" ;;
  esac
else
  # Turned off after having been on: take the reference back out rather than
  # leaving a dead one behind.
  case "$f0" in
    *'#{E:@agent_tmux_buttons}'*) tmux set-option -g "status-format[$TABROW]" "${f0//'#{E:@agent_tmux_buttons}'/}" ;;
  esac
  for o in @agent_tmux_buttons @agent_tmux_buttons_wide @agent_tmux_buttons_narrow; do
    tmux set-option -gu "$o" 2>/dev/null
  done
fi

# The current window's tab, in a border. Same trick: wrap whatever the theme
# put in window-status-current-format instead of replacing it. The two halves
# live in options so agent-status.sh can keep the border while it repaints a
# tab in an agent's colour -- otherwise the border would vanish from exactly
# the window you are working in.
wsc="$(tmux show-options -gv window-status-current-format 2>/dev/null)"
if [ "$WBORDER" != "off" ]; then
  tmux set-option -g @agent_tmux_wb_l "#[fg=$ACCENT,bg=default,nobold]${WB_L//#/##}"
  tmux set-option -g @agent_tmux_wb_r "#[fg=$ACCENT,bg=default,nobold]${WB_R//#/##}#[default]"
  case "$wsc" in
    *'@agent_tmux_wb_l'*) ;;
    *) tmux set-option -g window-status-current-format \
         "#{E:@agent_tmux_wb_l}$wsc#{E:@agent_tmux_wb_r}" ;;
  esac
else
  case "$wsc" in
    *'@agent_tmux_wb_l'*)
      wsc="${wsc/'#{E:@agent_tmux_wb_l}'/}"
      tmux set-option -g window-status-current-format "${wsc/'#{E:@agent_tmux_wb_r}'/}" ;;
  esac
  tmux set-option -gu @agent_tmux_wb_l 2>/dev/null
  tmux set-option -gu @agent_tmux_wb_r 2>/dev/null
fi

# The pane you are in. tmux only ever draws a border BETWEEN panes, so this is
# the one highlight that costs no columns: the active pane's frame takes the
# accent, every other border goes dim, and heavy lines make the difference
# readable at a glance across a wall of splits.
#
# Set globally, so agent-status.sh's per-window override (the agent's colour on
# the active border) still wins where it applies, and unsetting that override
# falls back to here rather than to the theme's default.
if [ "$PANE_HL" != "off" ]; then
  tmux set-option -g pane-active-border-style "fg=$ACCENT"
  tmux set-option -g pane-border-style "fg=$PILL_BG"
  case "$PANE_LINES" in
    single|double|heavy|simple|number) tmux set-option -g pane-border-lines "$PANE_LINES" ;;
  esac
  # Arrows on top of the colour: a monochrome phone terminal, or anyone who
  # cannot tell mauve from surface0, still gets to see which pane is live.
  tmux set-option -g pane-border-indicators both
fi

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

# Explode the window into one full-screen window per pane, and put it back.
# One key both ways, and it reads the state off the window you are ON, so it
# collapses the group from any of its tabs -- you press it where you are.
BURSTKEY="$(opt @agent_tmux_burst_key 'e')"    # prefix key; 'off' unbinds
[ "$BURSTKEY" = off ] || tmux bind-key "$BURSTKEY" run-shell -b "$SESSIONS burst-toggle '#{client_name}'"

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
#
# Row 0 now has our own ranges on it (agent_newwin, agent_split_lr,
# agent_split_tb). They are matched by prefix, so the tabs keep their stock
# behaviour and anything the theme emits is still none of our business.
tmux bind-key -n MouseDown1Status run-shell -C \
  "#{?#{!=:#{mouse_status_line},$ROW},#{?#{m:agent_*,#{mouse_status_range}},#{@agent_tmux_clickcmd},#{@agent_tmux_row0}},#{?#{==:#{mouse_status_range},menu},#{@agent_menu_cmd},#{@agent_tmux_clickcmd}}}"

# ------------------------------------------------------------ agent  colors --
if [ "$COLORS" != "off" ]; then
  tmux bind-key g run-shell "TMUX_PANE='#{pane_id}' $STATUS done </dev/null"
  tmux bind-key G run-shell "TMUX_PANE='#{pane_id}' $STATUS clear </dev/null"
fi

# Expose the resolved locations so users can reference them from their own conf
# (and so `notify = [...]` in ~/.codex/config.toml is easy to write).
tmux set-option -g @agent_tmux_dir "$DIR"
tmux set-option -g @agent_tmux_button_label "$BUTTON"
