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

echo
echo "----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
