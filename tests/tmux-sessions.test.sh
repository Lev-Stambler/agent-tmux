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
plain(){ run status "$1" | sed 's/#\[[^]]*\]//g; s/  */ /g; s/^ *//; s/ *$//'; }

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
# the button is the binding's job, not the script's: click picker must no-op
BEFORE="$(csess)"
OUT="$(run click picker "$CLIENT" 2>&1)"; RC=$?
check "click picker: exit 0" 0 "$RC"
check "click picker: silent" "" "$OUT"
check "click picker: session unchanged" "$BEFORE" "$(csess)"
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

echo
echo "----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
