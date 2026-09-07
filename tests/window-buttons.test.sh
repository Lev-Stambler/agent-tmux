#!/usr/bin/env bash
# Tests for row 0 — the window buttons (+ new window, │ / ─ splits) and the
# border drawn around the current window's tab.
#
# Loads the REAL plugin entrypoint (agent-tmux.tmux) against a throwaway server
# (-L winbtntest) with a control-mode client attached, because everything here
# is per-client: the button group branches on #{client_width}, and a control
# client's width can be driven with `refresh-client -C` — which is how the
# phone-width case gets tested without a phone.
#
# Run:  bash window-buttons.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SOCK="winbtntest"
SOCK2="winbtntest2"   # sections that need a pristine server (nothing loaded yet)
SOCK3="winbtntest3"

PASS=0; FAIL=0
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }
has(){    case "$3" in *"$2"*) ok "$1";; *) bad "$1 (no '$2' in: $3)";; esac; }
hasnt(){  case "$3" in *"$2"*) bad "$1 (unexpected '$2' in: $3)";; *) ok "$1";; esac; }

tt(){ tmux -L "$SOCK" "$@"; }
# Load the plugin the way tmux.conf does: `run` gives it no client, only $TMUX.
load_on(){ TMUX="$(tmux -L "$1" display-message -p '#{socket_path},0,0')" \
             bash "$ROOT/agent-tmux.tmux" >/dev/null 2>&1; }
load(){ load_on "$SOCK"; }
occurrences(){ printf '%s' "$2" | grep -o -F "$1" | wc -l | tr -d ' '; }
# What the client actually gets drawn: the option value expanded as a format.
# Not `display-message -c`: tmux 3.2 rejects that flag, so on the version floor
# this returned empty and every rendered-format assertion compared "" with "".
expand(){ tt list-clients -F "#{client_name}	$1" 2>/dev/null | awk -F'\t' -v c="$CLIENT" '$1==c {print $2; exit}'; }

cleanup(){
  exec 9>&- 2>/dev/null
  [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
  [ -n "${FIFO:-}" ] && rm -f "$FIFO"
  for s in "$SOCK" "$SOCK2" "$SOCK3"; do tmux -L "$s" kill-server 2>/dev/null; done
}
trap cleanup EXIT
tt kill-server 2>/dev/null

# -f /dev/null: no theme, no user config. Composition with a real theme is what
# the VHS scenarios cover; here the point is that we compose with tmux's stock
# status-format and window-status-current-format.
tt -f /dev/null new-session -d -s alpha -x 100 -y 24
FIFO="$(mktemp -u)"; mkfifo "$FIFO"
tmux -L "$SOCK" -C attach-session -t alpha <"$FIFO" >/dev/null 2>&1 &
CPID=$!
exec 9>"$FIFO"
for _ in $(seq 50); do [ -n "$(tt list-clients 2>/dev/null)" ] && break; sleep 0.1; done
CLIENT="$(tt list-clients -F '#{client_name}' | head -1)"
[ -n "$CLIENT" ] || { echo "FATAL: control client never attached"; exit 1; }
STOCK_CUR="$(tt show-options -gv window-status-current-format)"
STOCK_PANE="$(tt show-options -gv pane-border-style)"
STOCK_FMT="$(tt show-options -gv window-status-format)"
tt refresh-client -C 100x24 -t "$CLIENT" 2>/dev/null
load

echo "== 1. row 0 carries the button group, row 1 is still the rail =="
F0="$(tt show-options -gv 'status-format[0]')"
F1="$(tt show-options -gv 'status-format[1]')"
has "row 0 references the buttons" '#{E:@agent_tmux_buttons}' "$F0"
has "row 0 keeps the theme's window list" '#{W:' "$F0"
has "row 1 is still the session rail" 'tmux-sessions status' "$F1"
hasnt "row 1 does not get the buttons" '@agent_tmux_buttons' "$F1"

echo "== 2. reload is idempotent (prefix+I / prefix+R re-run this file) =="
load; load; load
F0="$(tt show-options -gv 'status-format[0]')"
check "buttons referenced exactly once" 1 "$(occurrences '#{E:@agent_tmux_buttons}' "$F0")"
check "border wraps the tab exactly once" 1 \
  "$(occurrences '#{E:@agent_tmux_wb_l}' "$(tt show-options -gv window-status-current-format)")"

echo "== 3. the group renders three clickable buttons =="
B="$(expand '#{E:@agent_tmux_buttons}')"
has "new-window button is clickable" 'range=user|agent_newwin' "$B"
has "left/right split is clickable"  'range=user|agent_split_lr' "$B"
has "top/bottom split is clickable"  'range=user|agent_split_tb' "$B"
has "the + glyph is drawn" '+' "$B"
has "the │ glyph is drawn" '│' "$B"
has "the ─ glyph is drawn" '────' "$B"
# Every range must be closed, or the rest of row 0 (the window tabs) inherits it
# and clicking a tab would create a window.
check "every range is closed" 3 "$(occurrences '#[norange]' "$B")"

echo "== 4. mobile: a phone-width client still gets all three buttons =="
tt refresh-client -C 45x20 -t "$CLIENT" 2>/dev/null
sleep 0.3
N="$(expand '#{E:@agent_tmux_buttons}')"
check "narrow client is really narrow" 45 "$(expand '#{client_width}')"
has "narrow keeps new-window" 'range=user|agent_newwin' "$N"
has "narrow keeps left/right split" 'range=user|agent_split_lr' "$N"
has "narrow keeps top/bottom split" 'range=user|agent_split_tb' "$N"
# Tap targets stay 3 columns wide (a 1-column button is unhittable with a thumb);
# what narrow drops is the gap BETWEEN them.
strip(){ printf '%s' "$1" | sed 's/#\[[^]]*\]//g'; }
# Each pill is " X " (its own padding is the pill background); wide adds one
# more column of band between them, narrow does not. Both end with a gap before
# the theme's first tab: 3 columns wide, 1 narrow.
check "narrow group is compact" " +  │  ─  " "$(strip "$N")"
has "narrow keeps the ─ button clickable" 'range=user|agent_split_tb' "$N"
tt refresh-client -C 100x24 -t "$CLIENT" 2>/dev/null
sleep 0.3
check "wide group is spaced" " +   │   ────    " "$(strip "$(expand '#{E:@agent_tmux_buttons}')")"
# The gap is what stops the last pill reading as part of the first window tab.
tt set-option -g @agent_tmux_buttons_gap 6 >/dev/null; load
check "the gap is themable" " +   │   ────       " "$(strip "$(expand '#{E:@agent_tmux_buttons}')")"
tt set-option -gu @agent_tmux_buttons_gap >/dev/null; load

echo "== 5. the current window's tab gets a border, other tabs do not =="
CUR="$(tt show-options -gv window-status-current-format)"
FMT="$(tt show-options -gv window-status-format)"
has "current tab is wrapped on the left"  '#{E:@agent_tmux_wb_l}' "$CUR"
has "current tab is wrapped on the right" '#{E:@agent_tmux_wb_r}' "$CUR"
has "the theme's own format survives" "$STOCK_CUR" "$CUR"
check "inactive tabs are untouched" "$STOCK_FMT" "$FMT"
has "the border is drawn in the accent colour" '#cba6f7' "$(expand '#{E:@agent_tmux_wb_l}')"

echo "== 5b. the pane you are in is highlighted =="
check "active pane border takes the accent" 'fg=#cba6f7' "$(tt show-options -gv pane-active-border-style)"
check "the other borders go dim"            'fg=#313244' "$(tt show-options -gv pane-border-style)"
check "borders are drawn heavy"             heavy        "$(tt show-options -gv pane-border-lines)"
# pane-border-indicators is 3.3+; on the 3.2 floor the accent colour carries
# the highlight by itself and the option must not be set (nor error).
if tt show-options -gv pane-border-indicators >/dev/null 2>&1; then
  check "and carry the arrow indicators" both "$(tt show-options -gv pane-border-indicators)"
else
  ok "no arrow indicators on this tmux (3.2 has no such option)"
fi

echo "== 5c. the explode/collapse key is bound =="
has "prefix+e runs the toggle" 'burst-toggle' "$(tt list-keys -T prefix e 2>/dev/null)"

echo "== 6. clicks on row 0 route: buttons to us, tabs to tmux =="
K="$(tt list-keys -T root MouseDown1Status)"
has "row-0 button ranges are routed" '#{m:agent_' "$K"
check "window tabs still select-window" 'select-window -t =' "$(tt show-options -gv @agent_tmux_row0)"

echo "== 7. both features are opt-out =="
t2(){ tmux -L "$SOCK2" "$@"; }
t2 kill-server 2>/dev/null
t2 -f /dev/null new-session -d -s alpha -x 100 -y 24
t2 set-option -g @agent_tmux_window_buttons off
t2 set-option -g @agent_tmux_window_border off
t2 set-option -g @agent_tmux_pane_highlight off
t2 set-option -g @agent_tmux_burst_key off
load_on "$SOCK2"
hasnt "buttons off: row 0 untouched" '@agent_tmux_buttons' "$(t2 show-options -gv 'status-format[0]')"
check "border off: the tab format is untouched" "$STOCK_CUR" "$(t2 show-options -gv window-status-current-format)"
check "row 1 still installs with both off" 2 "$(t2 show-options -gv status)"
check "pane highlight off: tmux's border style is untouched" "$STOCK_PANE" "$(t2 show-options -gv pane-border-style)"
check "burst key off: nothing is bound" 1 "$(t2 list-keys -T prefix e >/dev/null 2>&1 && echo 0 || echo 1)"

echo "== 8. labels and colours are themable =="
t3(){ tmux -L "$SOCK3" "$@"; }
t3 kill-server 2>/dev/null
t3 -f /dev/null new-session -d -s alpha -x 100 -y 24
t3 set-option -g @agent_tmux_new_window_label 'NEW'
t3 set-option -g @agent_tmux_split_lr_label 'LR'
t3 set-option -g @agent_tmux_split_tb_label 'TB'
t3 set-option -g @agent_tmux_accent '#ff0000'
load_on "$SOCK3"
B="$(t3 display-message -p '#{E:@agent_tmux_buttons}')"
has "custom new-window label" 'NEW' "$B"
has "custom split labels" 'LR' "$B"
has "border follows the accent option" '#ff0000' "$(t3 display-message -p '#{E:@agent_tmux_wb_l}')"

echo
echo "----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
