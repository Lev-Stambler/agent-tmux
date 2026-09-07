#!/usr/bin/env bash
# Tests for scripts/tmux-sessions — one-keystroke session jump + status-bar list.
#
# Uses a throwaway tmux server (-L sessionsjumptest) so it never touches the
# live session. A control-mode client (tmux -C, fed by a held-open fifo) stands
# in for an attached terminal so switch-client has a real target.
#
# Run:  bash tmux-sessions.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/tmux-sessions"
SOCK="sessionsjumptest"

PASS=0; FAIL=0
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }

tt(){ tmux -L "$SOCK" "$@"; }
TMUXVAL(){ tt display-message -p '#{socket_path},0,0'; }
run(){ TMUX="$(TMUXVAL)" bash "$SCRIPT" "$@"; }
cleanup(){
  exec 9>&- 2>/dev/null
  [ -n "${CPID:-}" ] && kill "$CPID" 2>/dev/null
  [ -n "${FIFO:-}" ] && rm -f "$FIFO"
  tt kill-server 2>/dev/null
}
trap cleanup EXIT
tt kill-server 2>/dev/null

# Created out of alphabetical order on purpose: numbering must sort by name.
tt new-session -d -s bravo -x 80 -y 24
tt new-session -d -s alpha
tt new-session -d -s charlie

# Control-mode client (no pty needed); fd 9 keeps its stdin open until cleanup.
FIFO="$(mktemp -u)"; mkfifo "$FIFO"
tmux -L "$SOCK" -C attach-session -t bravo <"$FIFO" >/dev/null 2>&1 &
CPID=$!
exec 9>"$FIFO"
for _ in $(seq 50); do [ -n "$(tt list-clients 2>/dev/null)" ] && break; sleep 0.1; done
CLIENT="$(tt list-clients -F '#{client_name}' | head -1)"
[ -n "$CLIENT" ] || { echo "FATAL: control client never attached"; exit 1; }
csess(){ tt list-clients -F '#{client_session}' | head -1; }
# strip style directives and collapse pill padding to single spaces
# forwards BOTH args: status <current> [width]
plain(){ run status "$1" ${2:+"$2"} | sed 's/#\[[^]]*\]//g; s/  */ /g; s/^ *//; s/ *$//'; }

echo "== 1. status: alphabetical numbering, creation order ignored =="
check "order+numbers" "+ 1:alpha 2:bravo 3:charlie" "$(plain bravo)"

echo "== 2. status: current session gets the accent pill, others the dim pill =="
OUT="$(run status bravo)"
case "$OUT" in *'bg=#cba6f7,bold] 2:bravo '*) ok "current (bravo) on accent pill";; *) bad "current pill wrong: '$OUT'";; esac
case "$OUT" in *'bold] 1:alpha '*) bad "non-current (alpha) bold";; *) ok "non-current not bold";; esac
case "$OUT" in *'bg=#313244] 1:alpha '*) ok "non-current on dim pill";; *) bad "dim pill wrong: '$OUT'";; esac
case "$OUT" in *'range=user|session_2'*) ok "entries carry clickable range markers";; *) bad "missing range=user|session_N: '$OUT'";; esac

echo "== 3. jump switches the client by alphabetical index =="
run jump 3 "$CLIENT"; check "jump 3 -> charlie" charlie "$(csess)"
run jump 1 "$CLIENT"; check "jump 1 -> alpha"   alpha   "$(csess)"

echo "== 4. jump out of range: silent no-op =="
OUT="$(run jump 99 "$CLIENT" 2>&1)"; RC=$?
check "exit 0" 0 "$RC"; check "silent" "" "$OUT"
check "session unchanged" alpha "$(csess)"

echo "== 5. click: user-range name jumps, other ranges are no-ops =="
run click session_2 "$CLIENT"; check "click session_2 -> bravo" bravo "$(csess)"
OUT="$(run click 'window|1' "$CLIENT" 2>&1)"; RC=$?
check "window range: exit 0" 0 "$RC"; check "window range: silent" "" "$OUT"
check "window range: session unchanged" bravo "$(csess)"
OUT="$(run click '' "$CLIENT" 2>&1)"; RC=$?
check "empty range: exit 0" 0 "$RC"; check "empty range: silent" "" "$OUT"
run click session_junk "$CLIENT"; check "non-numeric index: no-op" bravo "$(csess)"
run jump 1 "$CLIENT"

echo "== 6. numeric session name: sorts first, exact-match target =="
tt new-session -d -s 0
run jump 1 "$CLIENT"; check "jump 1 -> session '0'" 0 "$(csess)"
check "renumbered" "+ 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0)"

echo "== 7. unreachable server: silent, exit 0 =="
OUT="$(TMUX='/nonexistent/sock,0,0' bash "$SCRIPT" status x 2>&1)"; RC=$?
check "status exit 0" 0 "$RC"; check "status silent" "" "$OUT"
OUT="$(TMUX='/nonexistent/sock,0,0' bash "$SCRIPT" jump 1 2>&1)"; RC=$?
check "jump exit 0" 0 "$RC"; check "jump silent" "" "$OUT"

echo "== 8. picker button: clickable range, themable, disableable =="
OUT="$(run status alpha)"
case "$OUT" in *'range=user|picker'*) ok "button carries a clickable range";; *) bad "missing range=user|picker: '$OUT'";; esac
case "$OUT" in 'range=user|picker'*|'#[range=user|picker]'*) ok "button leads the row";; *) bad "button not first: '$OUT'";; esac
# `click picker` now opens the popup itself (the script passes -c, which
# run-shell cannot). A popup blocks until a human dismisses it, so assert the
# ROUTING decision instead of executing it -- `route` exists for exactly this.
check "picker routes to the picker" picker "$(run route picker)"
check "session_N routes to a jump"  "jump 2" "$(run route session_2)"
check "menu routes to the menu"     menu   "$(run route menu)"
check "a window range routes nowhere" none "$(run route 'window|1')"
check "an empty range routes nowhere" none "$(run route '')"
check "a junk index routes nowhere"   none "$(run route session_junk)"
tt set-option -g @agent_tmux_button_label 'NEW' >/dev/null
check "custom label" "NEW 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0)"
tt set-option -g @agent_tmux_button_label 'off' >/dev/null
check "label 'off' hides the button" "1:0 2:alpha 3:bravo 4:charlie" "$(plain 0)"
tt set-option -gu @agent_tmux_button_label >/dev/null

echo "== 9. palette is themable via @agent_tmux_* =="
tt set-option -g @agent_tmux_accent '#ff0000' >/dev/null
tt set-option -g @agent_tmux_pill_bg '#00ff00' >/dev/null
OUT="$(run status alpha)"
case "$OUT" in *'bg=#ff0000,bold] 2:alpha '*) ok "accent override applied";; *) bad "accent not overridden: '$OUT'";; esac
case "$OUT" in *'bg=#00ff00] 1:0 '*) ok "dim pill override applied";; *) bad "pill_bg not overridden: '$OUT'";; esac
tt set-option -gu @agent_tmux_accent >/dev/null
tt set-option -gu @agent_tmux_pill_bg >/dev/null
OUT="$(run status alpha)"
case "$OUT" in *'bg=#cba6f7,bold]'*) ok "unset restores the default palette";; *) bad "default not restored: '$OUT'";; esac

echo "== 11. a session name cannot inject style directives into the row =="
tt new-session -d -s '#[bg=red]evil' >/dev/null 2>&1
OUT="$(run status alpha)"
case "$OUT" in
  *'##[bg=red]evil'*) ok "'#' in a session name is escaped to '##'";;
  *)                  bad "unescaped name reached the row: '$OUT'";;
esac
# every session must still be present and numbered after the hostile one
N_SESS="$(tt list-sessions -F '#{session_name}' | wc -l)"
N_PILL="$(printf '%s' "$OUT" | grep -o 'range=user|session_' | wc -l)"
check "no pill swallowed by the hostile name" "$N_SESS" "$N_PILL"
tt kill-session -t '#[bg=red]evil' >/dev/null 2>&1

echo "== 12. narrow mode: the rail collapses only when it genuinely does not fit =="
# sessions here: 0, alpha, bravo, charlie -> " + " + 4 pills, joined by spaces.
# Width is OPTIONAL: absent means "never collapse", which is why every assertion
# above still describes the full rail.
WIDE="$(plain 0)"
# The true rendered width must NOT use plain(), which squeezes the double spaces
# between pills (each pill's own trailing pad plus the join space) down to one.
# Strip only the style directives, and add status-format's leading space.
RAILW=$(( $(run status 0 | sed 's/#\[[^]]*\]//g' | wc -c) + 1 ))
check "no width given: full rail" "+ 1:0 2:alpha 3:bravo 4:charlie" "$WIDE"
check "width way over: full rail" "+ 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0 200)"
check "at exactly the rail width: still full" "+ 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0 $RAILW)"
check "one column short: collapses" "☰ 1:0" "$(plain 0 $((RAILW-1)))"
check "very narrow: collapses" "☰ 1:0" "$(plain 0 20)"
check "non-numeric width is ignored" "+ 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0 abc)"
OUT="$(run status 0 20)"
case "$OUT" in *'range=user|menu'*)   ok "narrow row has a menu range";;   *) bad "no menu range: '$OUT'";; esac
case "$OUT" in *'range=user|picker'*) bad "narrow row still has the picker";; *) ok "narrow row drops the picker";; esac
N_PILL="$(printf '%s' "$OUT" | grep -o 'range=user|session_' | wc -l)"
check "narrow shows exactly one session" 1 "$N_PILL"
# @agent_tmux_narrow_width forces a breakpoint instead of the fits/doesn't-fit test
tt set-option -g @agent_tmux_narrow_width 999 >/dev/null
check "forced breakpoint collapses a wide client" "☰ 1:0" "$(plain 0 200)"
tt set-option -g @agent_tmux_narrow_width 1 >/dev/null
check "forced breakpoint keeps a narrow client wide" "+ 1:0 2:alpha 3:bravo 4:charlie" "$(plain 0 10)"
tt set-option -gu @agent_tmux_narrow_width >/dev/null

echo "== 13. narrow mode: the attention badge =="
PANE_A="$(tt display-message -p -t alpha '#{pane_id}')"
PANE_B="$(tt display-message -p -t bravo '#{pane_id}')"
check "no agent state: no badge" "☰ 1:0" "$(plain 0 20)"
tt set-option -p -t "$PANE_A" @agent_state waiting >/dev/null
check "one waiting pane" "☰ ●1 1:0" "$(plain 0 20)"
tt set-option -p -t "$PANE_B" @agent_state waiting >/dev/null
check "two waiting panes" "☰ ●2 1:0" "$(plain 0 20)"
case "$(run status 0 20)" in *'bg=#f9e2af,bold] ●2'*) ok "waiting badge is yellow";; *) bad "wrong waiting colour";; esac
tt set-option -p -t "$PANE_B" @agent_state blocked >/dev/null
case "$(run status 0 20)" in *'bg=#f38ba8,bold] ●2'*) ok "blocked outranks waiting (red)";; *) bad "priority wrong";; esac
tt set-option -p -t "$PANE_A" @agent_state working >/dev/null
tt set-option -p -t "$PANE_B" @agent_state working >/dev/null
check "working alone raises no badge" "☰ 1:0" "$(plain 0 20)"
tt set-option -p -t "$PANE_A" -u @agent_state >/dev/null
tt set-option -p -t "$PANE_B" -u @agent_state >/dev/null

echo "== 14. the menu's contents (a menu is an overlay; assert the argv) =="
tt set-option -p -t "$PANE_A" @agent_state blocked >/dev/null
mapfile -t M < <(run menu-args "$CLIENT" 0)
joined="$(printf '%s\n' "${M[@]}")"
case "$joined" in *'-needs you'*) ok "attention section present when a pane is blocked";; *) bad "no attention section";; esac
case "$joined" in *'-sessions'*)  ok "sessions section present";; *) bad "no sessions section";; esac
case "$joined" in *'new project…'*) ok "picker entry present";; *) bad "no picker entry";; esac
# Sessions are addressed by RAIL INDEX, never by name: a session called "it's"
# would otherwise produce switch-client -t '=it's', which resolves to "its".
for i in 1 2 3 4; do
  case "$joined" in *"jump $i "*) ok "session $i switches by index";; *) bad "session $i not addressed by index";; esac
done
case "$joined" in *"-t '="*) bad "a command still embeds a session name";; *) ok "no command embeds a session name";; esac
# every key is exactly one character: tmux cannot parse "10" and silently
# renders such an item with NO shortcut, making it unreachable by keyboard
BADKEY=0
for k in "${M[@]}"; do case "$k" in [0-9a-z]) ;; ?) ;; ??*) case "$k" in *' '*|*:*|-*) ;; *) BADKEY=1 ;; esac ;; esac; done
check "no multi-character shortcut keys" 0 "$BADKEY"
case "$joined" in *$'\nq\n'*) ok "attention rows use non-digit keys";; *) bad "attention key collides with a session digit";; esac
tt set-option -p -t "$PANE_A" -u @agent_state >/dev/null
case "$(run menu-args "$CLIENT" 0)" in *'-needs you'*) bad "attention section shown with nothing waiting";; *) ok "attention section hidden when nothing needs you";; esac

echo "== 15. the menu is safe against hostile session names =="
tt new-session -d -s '#[bg=red]evil' >/dev/null 2>&1
tt new-session -d -s "it's" >/dev/null 2>&1
J="$(run menu-args "$CLIENT" 0)"
case "$J" in *'##[bg=red]evil'*) ok "'#' escaped in menu item names";; *) bad "unescaped name in menu: $J";; esac
# Only the COMMAND lines matter -- a name containing an apostrophe is fine and
# expected; a command containing one would break tmux's quoting.
BADCMD="$(printf '%s\n' "$J" | grep -c "run-shell.*it's")"
check "no command contains an apostrophe name" 0 "$BADCMD"
# the staged command must be ONE line: it lives in a tmux option read back by
# `run-shell -C`, and both are line-oriented
CMD="$(run menu-cmd "" 0)"
check "menu-cmd is a single line" 1 "$(printf '%s' "$CMD" | wc -l | awk '{print $1+1}')"
case "$CMD" in 'display-menu -O'*' -- '*) ok "menu-cmd has the -- terminator";; *) bad "missing --: tmux parses '-needs you' as a flag";; esac
# It must also PARSE as a tmux command. Do not execute it here: display-menu is
# an interactive overlay and blocks until dismissed, which hangs the suite.
# `list-commands` after a failed parse is not a thing, so validate by round-
# tripping it through an option and asserting tmux stored it whole.
tt set-option -g @agent_menu_cmd "$CMD" >/dev/null
check "staged command survives a round trip" "$CMD" "$(tt show-option -gv @agent_menu_cmd)"
QUOTES="$(printf '%s' "$CMD" | tr -cd '"' | wc -c)"
check "quotes balance in the staged command" 0 "$(( QUOTES % 2 ))"
tt kill-session -t '#[bg=red]evil' >/dev/null 2>&1
tt kill-session -t "it's" >/dev/null 2>&1

echo "== 16. the menu is capped so it cannot exceed the client and vanish =="
for n in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12; do tt new-session -d -s "$n" >/dev/null 2>&1; done
# Count actionable items (one run-shell each), not argv lines.
ITEMS="$(run menu-args "$CLIENT" 8 | grep -c 'run-shell')"
[ "$ITEMS" -le 8 ] && ok "cap honoured ($ITEMS actionable items for cap 8)" || bad "cap ignored: $ITEMS items"
UNCAPPED="$(run menu-args "$CLIENT" 0 | grep -c 'run-shell')"
[ "$UNCAPPED" -gt "$ITEMS" ] && ok "an uncapped menu really is longer ($UNCAPPED)" || bad "cap had no effect"
case "$(run menu-args "$CLIENT" 8)" in *'all sessions…'*) ok "overflow entry offered";; *) bad "sessions silently dropped";; esac
for n in s1 s2 s3 s4 s5 s6 s7 s8 s9 s10 s11 s12; do tt kill-session -t "$n" >/dev/null 2>&1; done

echo "== 17. row-0 buttons: routing =="
check "the + button routes to a new window"   newwin     "$(run route agent_newwin)"
check "the │ button routes to a left/right split" "split lr" "$(run route agent_split_lr)"
check "the ─ button routes to a top/bottom split" "split tb" "$(run route agent_split_tb)"
check "an unknown agent_ range routes nowhere" none "$(run route agent_bogus)"

echo "== 18. row-0 buttons: they act on the CLIENT's window, not tmux's idea of current =="
run jump 4 "$CLIENT"                       # charlie
check "client parked on charlie" charlie "$(csess)"
W0="$(tt list-windows -t charlie | wc -l)"
run click agent_newwin "$CLIENT"
check "the + button opened a window in the client's session" "$((W0+1))" "$(tt list-windows -t charlie | wc -l)"
# The new window must be the one the client is looking at — a window created
# somewhere behind you is indistinguishable from nothing happening.
NEWW="$(tt display-message -c "$CLIENT" -p '#{window_id}')"
check "and switched the client to it" "$NEWW" "$(tt list-windows -t charlie -F '#{window_id}' | tail -1)"

P0="$(tt list-panes -t "$NEWW" | wc -l)"
run click agent_split_lr "$CLIENT"
check "the │ button splits the pane" "$((P0+1))" "$(tt list-panes -t "$NEWW" | wc -l)"
# left/right vs top/bottom is the whole point of having two buttons: assert the
# geometry, not just that a pane appeared.
LR="$(tt list-panes -t "$NEWW" -F '#{pane_left}' | sort -u | wc -l)"
check "left/right: the panes sit side by side" 2 "$LR"
run click agent_split_tb "$CLIENT"
TB="$(tt list-panes -t "$NEWW" -F '#{pane_top}' | sort -u | wc -l)"
check "top/bottom: the panes stack" 2 "$TB"
tt kill-window -t "$NEWW" 2>/dev/null

echo "== 19. row-0 buttons in the menu, for phones with no mouse =="
J="$(run menu-args "$CLIENT" 0)"
case "$J" in *'new window'*)   ok "menu offers a new window";;   *) bad "no new-window entry: $J";; esac
case "$J" in *'split right'*)  ok "menu offers a left/right split";; *) bad "no split-right entry";; esac
case "$J" in *'split down'*)   ok "menu offers a top/bottom split";; *) bad "no split-down entry";; esac
case "$J" in *"newwin '#{client_name}'"*) ok "menu passes the client through";; *) bad "menu drops the client";; esac
case "$J" in *'explode panes'*) ok "menu offers the explode toggle";; *) bad "no explode entry";; esac
# The label is a format so one staged menu serves every client: it has to read
# "collapse panes" for a client standing on an exploded window and "explode
# panes" for one that is not.
LBL="$(printf '%s\n' "$J" | grep -F 'explode panes' | head -1)"
check "on an ordinary window it says explode" "explode panes" "$(tt display-message -c "$CLIENT" -p "$LBL")"
case "$J" in *"burst-toggle '#{client_name}'"*) ok "the explode entry is the toggle";; *) bad "explode entry wrong command";; esac
# 'e' now belongs to the tail, so it must not also be handed to an attention row
# -- a duplicate key makes one of the two unreachable from the keyboard.
tt set-option -p -t "$PANE_A" @agent_state blocked >/dev/null
tt set-option -p -t "$PANE_B" @agent_state waiting >/dev/null
DUPE="$(run menu-args "$CLIENT" 0 | awk 'NR%3==2 && $0 != ""' | sort | uniq -d | tr -d '\n')"
check "no two menu items share a key" "" "$DUPE"
tt set-option -p -t "$PANE_A" -u @agent_state >/dev/null
tt set-option -p -t "$PANE_B" -u @agent_state >/dev/null
# The staged one-line command must still parse after the new entries.
CMD="$(run menu-cmd "" 0)"
check "menu-cmd is still a single line" 1 "$(printf '%s' "$CMD" | wc -l | awk '{print $1+1}')"
QUOTES="$(printf '%s' "$CMD" | tr -cd '"' | wc -c)"
check "quotes still balance" 0 "$(( QUOTES % 2 ))"

echo "== 20. burst: every pane of the window becomes its own full-screen window =="
run jump 4 "$CLIENT"                       # charlie
W="$(tt display-message -c "$CLIENT" -p '#{window_id}')"
tt rename-window -t "$W" burstme
P1="$(tt display-message -t "$W" -p '#{pane_id}')"
P2="$(tt split-window -t "$W" -h -P -F '#{pane_id}')"
P3="$(tt split-window -t "$P2" -v -P -F '#{pane_id}')"
LAYOUT="$(tt display-message -t "$W" -p '#{window_layout}')"
ORDER="$(tt list-panes -t "$W" -F '#{pane_id}' | tr '\n' ' ')"
tt select-pane -t "$P2"                    # the pane the user is looking at
W0="$(tt list-windows -t charlie | wc -l)"
run burst "$CLIENT"
check "each pane got a window" "$((W0+2))" "$(tt list-windows -t charlie | wc -l)"
check "the base window keeps exactly one pane" 1 "$(tt list-panes -t "$W" | wc -l)"
check "the base keeps its name"       burstme    "$(tt display-message -t "$W" -p '#{window_name}')"
check "satellites take the name + index" "burstme·2" "$(tt display-message -t "$P2" -p '#{window_name}')"
check "numbered in pane order"           "burstme·3" "$(tt display-message -t "$P3" -p '#{window_name}')"
# Named tabs only stay named if automatic-rename is off: the running command
# would otherwise rename the tab out from under the group.
check "automatic-rename is off on a satellite" off "$(tt show-window-options -v -t "$P2" automatic-rename)"
check "satellites point back at the base" "$W" "$(tt show-window-options -v -t "$P2" @agent_burst_of)"
check "the base records the layout"  "$LAYOUT" "$(tt show-window-options -v -t "$W" @agent_burst_layout)"
# Ids, never indices: renumber-windows shifts indices whenever a window closes.
case "$(tt show-window-options -v -t "$W" @agent_burst_panes)" in
  *"$P2"*"$P3"*) ok "the base records the pane order";; *) bad "pane order not recorded";; esac
check "the client follows the pane it was on" "$P2" "$(tt display-message -c "$CLIENT" -p '#{pane_id}')"
# rename-window expands its argument as a format and break-pane -n does not --
# opposite behaviours, both measured. A '#' in the name is where that bites: the
# base must not be renamed to itself, and the satellite name must not be escaped.
run burst-toggle "$CLIENT"
tt rename-window -t "$W" '##S-hash'        # tmux expands this to the literal #S-hash
check "a hostile name is set up" '#S-hash' "$(tt display-message -t "$W" -p '#{window_name}')"
run burst "$CLIENT"
check "the base keeps a '#' name verbatim"      '#S-hash'   "$(tt display-message -t "$W" -p '#{window_name}')"
check "and the satellite inherits it verbatim"  '#S-hash·2' "$(tt display-message -t "$P2" -p '#{window_name}')"
run burst-toggle "$CLIENT"
tt rename-window -t "$W" burstme
run burst "$CLIENT"

echo "== 21. the toggle collapses the group back, from a satellite =="
run burst-toggle "$CLIENT"                 # client is on P2's satellite, not the base
check "one window again"        "$W0" "$(tt list-windows -t charlie | wc -l)"
check "every pane is back"      3     "$(tt list-panes -t "$W" | wc -l)"
check "in their original order" "$ORDER" "$(tt list-panes -t "$W" -F '#{pane_id}' | tr '\n' ' ')"
# The whole point. select-layout assigns panes positionally, so this only holds
# if the join order was rebuilt correctly first.
check "and the layout is restored byte for byte" "$LAYOUT" "$(tt display-message -t "$W" -p '#{window_layout}')"
check "the pane you were in is selected" "$P2" "$(tt display-message -c "$CLIENT" -p '#{pane_id}')"
check "the burst state is cleared" "" "$(tt show-window-options -v -t "$W" @agent_burst_layout 2>/dev/null)"
check "no satellite marks left behind" 0 "$(tt list-windows -a -F '#{@agent_burst_of}' | grep -c .)"

echo "== 22. burst: a window with nothing to explode, and a zoomed one =="
SOLO="$(tt new-window -t charlie -P -F '#{window_id}')"
tt select-window -t "$SOLO"
WN="$(tt list-windows -t charlie | wc -l)"
run burst "$CLIENT"
check "a single-pane window is a no-op" "$WN" "$(tt list-windows -t charlie | wc -l)"
check "and records no state" "" "$(tt show-window-options -v -t "$SOLO" @agent_burst_layout 2>/dev/null)"
# A toggle that silently does nothing is indistinguishable from a key that is
# not bound at all.
case "$(tt show-messages -t "$CLIENT" 2>/dev/null)" in
  *'nothing to explode'*) ok "and says why";; *) bad "a silent no-op gives no feedback";; esac
tt kill-window -t "$SOLO"
# Zoom: #{window_layout} ignores it, so the round trip must still be exact.
tt select-window -t "$W"; tt select-pane -t "$P1"; tt resize-pane -Z -t "$P1"
run burst "$CLIENT"
check "a zoomed window unzooms and explodes" "$((W0+2))" "$(tt list-windows -t charlie | wc -l)"
run burst-toggle "$CLIENT"
check "and still round-trips exactly" "$LAYOUT" "$(tt display-message -t "$W" -p '#{window_layout}')"
# Zoom is not in the layout string, so it has to be carried separately -- losing
# it silently is the one outcome to avoid.
check "and comes back zoomed"  1    "$(tt display-message -t "$W" -p '#{window_zoomed_flag}')"
check "on the pane that was zoomed" "$P1" "$(tt display-message -t "$W" -p '#{pane_id}')"
tt resize-pane -Z -t "$P1"

echo "== 23. burst: the group survives being messed with while it is open =="
run burst "$CLIENT"
tt kill-window -t "$P3"                    # a satellite closed while exploded
run burst-toggle "$CLIENT"
check "a closed satellite loses only its own pane" 2 "$(tt list-panes -t "$W" | wc -l)"
check "the survivors still come home" "$P1 $P2 " "$(tt list-panes -t "$W" -F '#{pane_id}' | tr '\n' ' ')"
check "state cleared after a partial collapse" "" "$(tt show-window-options -v -t "$W" @agent_burst_layout 2>/dev/null)"
# A satellite split further has more panes than the saved layout has cells, and
# tmux refuses such a layout outright ("have N panes but need M") -- so this has
# to fall back rather than error.
run burst "$CLIENT"
SAT="$(tt display-message -t "$P2" -p '#{window_id}')"
tt split-window -t "$P2" -v >/dev/null 2>&1
OUT="$(run burst-toggle "$CLIENT" 2>&1)"; RC=$?
check "collapsing a split satellite exits 0" 0 "$RC"
check "it is silent"                        "" "$OUT"
check "and brings every pane home"          3  "$(tt list-panes -t "$W" | wc -l)"

echo "== 23b. burst: more panes than a window can re-split still all come home =="
# Each join splits the pane placed before it, so the room halves every time:
# 22 rows -> 11 -> 5 -> 2 -> fail. Measured: twelve panes out, nine home and
# three windows orphaned with their marks already cleared -- no way back.
DEEP="$(tt new-window -t charlie -P -F '#{window_id}' -n deep)"
for _ in $(seq 11); do tt split-window -t "$DEEP" >/dev/null 2>&1; tt select-layout -t "$DEEP" tiled >/dev/null 2>&1; done
DN="$(tt list-panes -t "$DEEP" | wc -l)"
tt select-window -t "$DEEP"
run burst "$CLIENT"
run burst-toggle "$CLIENT"
check "every pane comes home from a deep burst" "$DN" "$(tt list-panes -t "$DEEP" 2>/dev/null | wc -l)"
check "and no window is orphaned" 0 "$(tt list-windows -a -F '#{@agent_burst_of}' | grep -c .)"
tt kill-window -t "$DEEP" 2>/dev/null

echo "== 23c. burst: a window already in a group is left alone =="
tt select-window -t "$W"
run burst "$CLIENT"
SAT2="$(tt display-message -t "$P2" -p '#{window_id}')"
tt select-window -t "$SAT2"
BEFORE_OF="$(tt show-window-options -v -t "$SAT2" @agent_burst_of)"
run burst "$CLIENT"                        # burst, not the toggle: must refuse
check "a satellite does not secede into its own group" "$BEFORE_OF" \
      "$(tt show-window-options -v -t "$SAT2" @agent_burst_of)"
run burst-toggle "$CLIENT"
check "the group still collapses afterwards" 3 "$(tt list-panes -t "$W" | wc -l)"

echo "== 24. burst: the agent colours follow the panes onto their new tabs =="
# The whole reason this feature earns its place: a window of four agents shows
# ONE aggregated colour, and exploding gives each agent its own coloured tab.
# The colour is a window option and the state a pane option, so neither end is
# right until the aggregate is recomputed per window.
P4="$(tt split-window -t "$W" -h -P -F '#{pane_id}')"
TMUX="$(TMUXVAL)" TMUX_PANE="$P4" bash "$HERE/../scripts/agent-status.sh" blocked </dev/null
case "$(tt show-window-options -v -t "$W" window-status-format 2>/dev/null)" in
  *'#f38ba8'*) ok "the combined window reads red";; *) bad "no red before the burst";; esac
run burst "$CLIENT"
BW="$(tt display-message -t "$P4" -p '#{window_id}')"
case "$(tt show-window-options -v -t "$BW" window-status-format 2>/dev/null)" in
  *'#f38ba8'*) ok "the blocked pane's own tab is red";; *) bad "the exploded tab lost its colour";; esac
check "and the tab it left is no longer red" "" "$(tt show-window-options -v -t "$W" window-status-format 2>/dev/null)"
run burst-toggle "$CLIENT"
case "$(tt show-window-options -v -t "$W" window-status-format 2>/dev/null)" in
  *'#f38ba8'*) ok "collapsing puts the colour back on the one window";; *) bad "colour lost on collapse";; esac
TMUX="$(TMUXVAL)" TMUX_PANE="$P4" bash "$HERE/../scripts/agent-status.sh" clear </dev/null
tt kill-pane -t "$P4" 2>/dev/null

echo "== 25. burst: closing the base window does not strand the rest =="
# Every member carries the record, so any survivor can take the panes home.
run burst "$CLIENT"
tt kill-window -t "$W"                     # the base tab, closed while exploded
run burst-toggle "$CLIENT"                 # fired from a satellite
SURV="$(tt display-message -c "$CLIENT" -p '#{window_id}')"
check "a survivor is promoted and takes the panes" 2 "$(tt list-panes -t "$SURV" | wc -l)"
check "nothing is left marked" 0 "$(tt list-windows -a -F '#{@agent_burst_of}' | grep -c .)"
tt kill-window -t "$SURV" 2>/dev/null

echo
echo "----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
