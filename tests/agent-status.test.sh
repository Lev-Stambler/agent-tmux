#!/usr/bin/env bash
# Tests for agent-status.sh — the per-pane / window-aggregate tmux colorizer.
#
# Uses a throwaway tmux server (-L agentstatustest) so it never touches the live
# session. Verifies: single-pane colors, multi-pane aggregation (highest concern
# wins; clearing one split doesn't wipe the tab), the env matrix (no-tmux /
# unreachable), the background-task downgrade, and the Codex cwd-fallback.
#
# Run:  bash agent-status.test.sh   (exit 0 = all pass)
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/agent-status.sh"
SOCK="agentstatustest"

RED='#f38ba8'; YELLOW='#f9e2af'; BLUE='#89b4fa'; GREEN='#a6e3a1'

PASS=0; FAIL=0
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }

tt(){ tmux -L "$SOCK" "$@"; }
TMUXVAL(){ tt display-message -p '#{socket_path},0,0'; }
cleanup(){ tt kill-server 2>/dev/null; }
trap cleanup EXIT
cleanup

tt new-session -d -s s -x 220 -y 50
WIN="$(tt display-message -p -t s '#{window_id}')"
A="$(tt display-message -p -t s '#{pane_id}')"
B="$(tt split-window -t s -h -P -F '#{pane_id}')"

# Run the script as if a hook fired in <pane>, on the test server.
run(){ # run <pane> <state> [json]
  printf '%s' "${3:-}" | TMUX="$(TMUXVAL)" TMUX_PANE="$1" bash "$SCRIPT" "$2"
}
wfmt(){ tt show-window-options -v -t "$WIN" window-status-format 2>/dev/null; }
wcolor(){ case "$(wfmt)" in
  *"$RED"*)    echo red ;;
  *"$YELLOW"*) echo yellow ;;
  *"$BLUE"*)   echo blue ;;
  *"$GREEN"*)  echo green ;;
  '')          echo none ;;
  *)           echo other ;;
esac; }
reset(){ run "$A" clear; run "$B" clear; }

echo "== 1. single pane (B stays clear) =="
reset
run "$A" working; check "working -> blue"   blue   "$(wcolor)"
run "$A" waiting; check "waiting -> yellow"  yellow "$(wcolor)"
run "$A" blocked; check "blocked -> red"     red    "$(wcolor)"
run "$A" done;    check "done -> green"      green  "$(wcolor)"
run "$A" clear;   check "clear -> none"      none   "$(wcolor)"
run "$A" waiting
case "$(wfmt)" in *'#I'*) ok "pill keeps window number (#I)";; *) bad "pill missing #I";; esac

echo "== 2. aggregation priority: blocked > waiting > working > acked =="
reset; run "$A" working; run "$B" working
check "working + working -> blue"   blue   "$(wcolor)"
run "$B" waiting
check "working + waiting -> yellow"  yellow "$(wcolor)"
run "$A" blocked
check "blocked + waiting -> red (blocked wins)" red "$(wcolor)"
reset; run "$A" waiting; run "$B" done
check "waiting + acked -> yellow"    yellow "$(wcolor)"
reset; run "$A" done; run "$B" working
check "acked + working -> blue"      blue   "$(wcolor)"
reset; run "$A" done; run "$B" done
check "acked + acked -> green"       green  "$(wcolor)"

echo "== 3. clearing one split does NOT wipe the tab =="
reset; run "$A" waiting; run "$B" working
check "waiting + working -> yellow"  yellow "$(wcolor)"
run "$A" clear
check "clear A -> still blue (B working)" blue "$(wcolor)"
run "$B" clear
check "clear B -> none (both clear)"      none "$(wcolor)"

echo "== 4. re-assert working clears prior needs-you =="
reset; run "$A" waiting; run "$B" working
check "A waiting -> yellow" yellow "$(wcolor)"
run "$A" working
check "A back to working -> blue" blue "$(wcolor)"

echo "== 5. env matrix =="
OUT="$(env -u TMUX -u TMUX_PANE bash "$SCRIPT" waiting </dev/null 2>&1)"; RC=$?
check "no-tmux exits 0" 0 "$RC"; check "no-tmux silent" "" "$OUT"
OUT="$(TMUX='/nonexistent/sock,0,0' TMUX_PANE='%999' bash "$SCRIPT" waiting </dev/null 2>&1)"; RC=$?
check "unreachable exits 0" 0 "$RC"; check "unreachable silent" "" "$OUT"

echo "== 6. background-task downgrade (waiting w/ running bg -> working) =="
reset
BG_RUN='{"hook_event_name":"Stop","background_tasks":[{"id":"x","status":"running"}]}'
run "$A" waiting "$BG_RUN"
check "lone pane waiting+bg -> blue (not yellow)" blue "$(wcolor)"
reset
run "$A" waiting '{"background_tasks":[]}'
check "lone pane waiting+no-bg -> yellow" yellow "$(wcolor)"

echo "== 7. Codex cwd-fallback (no \$TMUX_PANE; resolve pane by payload cwd) =="
CWD="$(mktemp -d)"; BIN="$(mktemp -d)"; cp "$(command -v sleep)" "$BIN/codex"
# own window so its aggregate is independent of panes A/B
CXP="$(tt new-window -t s -n cdx -c "$CWD" -P -F '#{pane_id}')"
CXWIN="$(tt display-message -p -t "$CXP" '#{window_id}')"
tt send-keys -t "$CXP" "exec '$BIN/codex' 300" Enter; sleep 1
printf '%s' "{\"cwd\":\"$CWD\"}" | env -u TMUX_PANE TMUX="$(TMUXVAL)" bash "$SCRIPT" working
cxc="$(tt show-window-options -v -t "$CXWIN" window-status-format 2>/dev/null)"
case "$cxc" in *"$BLUE"*) ok "codex pane found via cwd -> blue";; *) bad "codex cwd-fallback (got '$cxc')";; esac
tt kill-pane -t "$CXP" 2>/dev/null; rm -rf "$CWD" "$BIN"

echo "== 8. every hook call stamps @agent_last (recency for agent-review) =="
reset
t0="$(date +%s)"
run "$A" working
st="$(tt display -p -t "$A" '#{@agent_last}')"
if [ -n "$st" ] && [ "$st" -ge "$t0" ] 2>/dev/null; then ok "working stamps @agent_last ($st)"
else bad "working did not stamp @agent_last (got '$st')"; fi
sleep 1.1
run "$A" clear
st2="$(tt display -p -t "$A" '#{@agent_last}')"
if [ -n "$st2" ] && [ "$st2" -gt "$st" ] 2>/dev/null; then ok "clear re-stamps (interaction time moves forward)"
else bad "clear did not re-stamp (was '$st', got '$st2')"; fi

echo "== 9. composes with a theme: clear restores the GLOBAL window-status-format =="
# catppuccin (and every other theme) sets window-status-format globally; we only
# ever set it per-window, so clearing must expose the theme's value again rather
# than a hardcoded default. This is what makes load order not matter.
THEME='#[fg=#cba6f7,bg=default] #I:#W #[default]'
tt set-option -g window-status-format "$THEME"
reset
check "theme visible before any state" "$THEME" "$(tt show-options -gv window-status-format)"
run "$A" blocked
check "window override wins while active" red "$(wcolor)"
check "global untouched by the override" "$THEME" "$(tt show-options -gv window-status-format)"
run "$A" clear
check "clear restores the theme verbatim" "$THEME" "$(tt display-message -p -t s '#{window-status-format}')"
tt set-option -gu window-status-format

echo "== 10. palette is themable via @agent_tmux_* =="
reset
tt set-option -g @agent_tmux_state_blocked '#ff0000'
run "$A" blocked
case "$(wfmt)" in *'#ff0000'*) ok "blocked color override applied";; *) bad "override ignored: $(wfmt)";; esac
tt set-option -gu @agent_tmux_state_blocked
run "$A" clear; run "$A" blocked
check "unset restores the default red" red "$(wcolor)"
reset

echo
echo "----------------------------------------"
printf 'Total: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
