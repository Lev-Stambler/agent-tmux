#!/usr/bin/env bash
# Robust LIVE integration test for tmux agent tab coloring (Codex + Claude).
#
# Exercises the REAL user path end to end — interactive tmux panes, the codex()
# shell wrapper (in-process TUI), real hooks (SessionStart/UserPromptSubmit, Claude
# Stop) and the codex notify(agent-turn-complete) program, agent-status.sh, and the
# per-pane window aggregate. Asserts the AUTHORITATIVE window-status-current-format
# color at each checkpoint (timing-robust: waits for the expected color, with a
# timeout). Covers: codex multi-turn cycling, codex two-pane aggregation, and a
# Claude+Codex cross-agent split window (the real "many agents on one tab" case).
#
# Launches REAL agent turns (low reasoning) so it is slow (~several minutes) and
# needs working auth. Runs on its own tmux server (-L codexlive) in a trusted cwd so
# there are no folder/hook trust prompts.
#
#   Usage: bash test-agents-live.sh
set -u
SOCK=codexlive
CFG="${AGENT_TMUX_LIVE_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")/vhs" && pwd)/out/demo.conf}"
CWD="$HOME/.config"           # trusted in ~/.codex/config.toml -> no folder prompt
# codex wrapper expands in interactive bash; add low reasoning + bypass for speed.
CODEX='codex -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox'

PASS=0; FAIL=0
ok(){  printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
tt(){ tmux -L "$SOCK" "$@"; }
cleanup(){ tt kill-server 2>/dev/null; }
trap cleanup EXIT

wcol(){ # color of window $1 (active pane uses *current* format)
  case "$(tt show-window-options -v -t "$1" window-status-current-format 2>/dev/null)" in
    *'#f38ba8'*) echo red ;; *'#f9e2af'*) echo yellow ;; *'#89b4fa'*) echo blue ;;
    *'#a6e3a1'*) echo green ;; '') echo none ;; *) echo other ;;
  esac
}
wait_col(){ # wait until window $1 == color $2, up to $3 s; echoes final color
  local win="$1" want="$2" to="${3:-45}" i c
  for i in $(seq 1 "$to"); do c="$(wcol "$win")"; [ "$c" = "$want" ] && { echo "$c"; return 0; }; sleep 1; done
  echo "$(wcol "$win")"; return 1
}
assert_reaches(){ # <desc> <win> <color> <timeout>
  local got; got="$(wait_col "$2" "$3" "$4")"
  [ "$got" = "$3" ] && ok "$1 (-> $3)" || bad "$1 (wanted $3, got $got after ${4}s)"
}
submit(){ # type a prompt into pane $1 and press Enter
  tt send-keys -t "$1" "$2"; sleep 0.6; tt send-keys -t "$1" Enter
}
launch_codex(){ # start codex in pane $1, approve any hook-trust prompt
  tt send-keys -t "$1" "$CODEX" Enter
  local i
  for i in $(seq 1 12); do
    sleep 1
    if tt capture-pane -p -t "$1" | grep -q "Trust all and continue"; then
      tt send-keys -t "$1" Down; sleep 0.5; tt send-keys -t "$1" Enter
    fi
    tt capture-pane -p -t "$1" | grep -qiE 'Ask Codex|/status|to change|gpt-' && break
  done
  sleep 2
}
launch_claude(){ # start claude in pane $1, accept any "trust this folder" prompt
  tt send-keys -t "$1" "claude --dangerously-skip-permissions" Enter
  local i
  for i in $(seq 1 15); do
    sleep 1
    if tt capture-pane -p -t "$1" | grep -qiE 'trust this folder|safety check'; then
      tt send-keys -t "$1" Enter   # default = "Yes, I trust this folder"
    fi
    tt capture-pane -p -t "$1" | grep -qiE 'shortcuts|for newline|/help' && break
  done
  sleep 2
}

echo "== agents live integration (real turns; this is slow) =="
cleanup
tt -f "$CFG" new-session -d -s s -c "$CWD" -x 160 -y 40
W1="$(tt display-message -p -t s '#{window_id}')"
P1="$(tt display-message -p -t s '#{pane_id}')"

echo "-- 1. single codex, multi-turn (blue<->yellow cycles, no stuck color) --"
launch_codex "$P1"
assert_reaches "fresh codex window starts uncolored" "$W1" none 2 || true   # best-effort
submit "$P1" "reply with just: hi"
assert_reaches "turn1 submit -> working(blue)"  "$W1" blue   12
assert_reaches "turn1 complete -> waiting(yellow)" "$W1" yellow 60
submit "$P1" "reply with just: bye"
assert_reaches "turn2 submit -> working(blue) again" "$W1" blue   12
assert_reaches "turn2 complete -> waiting(yellow)"   "$W1" yellow 60

echo "-- 2. two codex panes in one window: aggregate (one done while other works) --"
tt new-window -t s -c "$CWD"
W2="$(tt display-message -p -t s: '#{window_id}')"
PA="$(tt display-message -p -t s: '#{pane_id}')"
PB="$(tt split-window -h -t "$PA" -c "$CWD" -P -F '#{pane_id}')"
launch_codex "$PA"; launch_codex "$PB"
# give B a long task, A a short one, so A finishes first while B is still working
submit "$PB" "count slowly from 1 to 40, one number per line, with a short pause between each"
sleep 1
submit "$PA" "reply with just: hi"
assert_reaches "both submitted -> window working(blue)" "$W2" blue 12
# A finishes first (short) while B still counting -> A waiting + B working = YELLOW (waiting>working)
assert_reaches "A done while B still working -> window yellow" "$W2" yellow 60

echo "-- 3. cross-agent: Claude + Codex in ONE window (the real multi-agent case) --"
tt new-window -t s -c "$CWD"
W3="$(tt display-message -p -t s: '#{window_id}')"
PC="$(tt display-message -p -t s: '#{pane_id}')"
PX="$(tt split-window -h -t "$PC" -c "$CWD" -P -F '#{pane_id}')"
launch_claude "$PC"; launch_codex "$PX"
# codex gets a long task, claude a short one -> claude done first while codex works
submit "$PX" "count slowly from 1 to 40, one per line, pausing between each"
sleep 1
submit "$PC" "reply with just: hi"
assert_reaches "claude+codex both submitted -> window blue" "$W3" blue 14
assert_reaches "claude done while codex works -> window yellow" "$W3" yellow 70
# ack the claude split -> it leaves the aggregate; codex still working -> blue
tt select-pane -t "$PC"
TMUX="$(tt display -p '#{socket_path},0,0')" TMUX_PANE="$PC" \
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/agent-status.sh" done </dev/null
assert_reaches "ack claude split (prefix+g) while codex works -> window blue" "$W3" blue 8

echo
echo "----------------------------------------"
printf 'agents-live: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
