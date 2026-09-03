#!/usr/bin/env bash
# Runs INSIDE a fresh container as a fresh user with an empty $HOME.
# Simulates exactly what a stranger does after reading the README.
set -u
P=0; F=0
ok(){ printf '  \033[32mPASS\033[0m %s\n' "$1"; P=$((P+1)); }
bad(){ printf '  \033[31mFAIL\033[0m %s\n' "$1"; F=$((F+1)); }
chk(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2' got '$3')"; fi; }

echo "== environment =="
echo "  distro : $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "  tmux   : $(tmux -V)"
echo "  home   : $HOME  (empty: $([ -z "$(ls -A "$HOME" 2>/dev/null)" ] && echo yes || echo no))"
echo "  fzf    : $(command -v fzf >/dev/null && echo yes || echo NO)"
echo "  jq     : $(command -v jq >/dev/null && echo yes || echo 'no (optional)')"

echo "== 1. README install path: TPM + one @plugin line =="
git clone -q --depth 1 https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm" 2>/dev/null \
  && ok "TPM cloned from GitHub" || bad "TPM clone failed"
# the repo is still private, so stand in for the network fetch by placing it
# exactly where TPM would clone it
cp -r "${AGENT_TMUX_SRC:-/srv/agent-tmux}" "$HOME/.tmux/plugins/agent-tmux"
rm -rf "$HOME/.tmux/plugins/agent-tmux/.git"
cat > "$HOME/.tmux.conf" <<CONF
set -g @plugin 'Lev-Stambler/agent-tmux'
set -g @agent_tmux_paths "\$HOME/code"
run '$HOME/.tmux/plugins/tpm/tpm'
CONF
mkdir -p "$HOME/code/api" "$HOME/code/web"

S=probe; tmux -L $S kill-server 2>/dev/null
ERR="$(tmux -L $S -f "$HOME/.tmux.conf" new-session -d -s api -x 120 -y 30 2>&1)"
chk "config loads with no errors" "" "$ERR"
tmux -L $S new-session -d -s web

echo "== 2. the two rows actually exist =="
chk "status is 2 rows" 2 "$(tmux -L $S show-options -gv status)"
FMT="$(tmux -L $S show-options -gv 'status-format[1]')"
case "$FMT" in *tmux-sessions*) ok "row 1 is owned by the plugin";; *) bad "row 1 not set: '$FMT'";; esac

echo "== 3. row 1 renders (no theme installed at all) =="
ROW="$(TMUX="$(tmux -L $S display-message -p '#{socket_path},0,0')" \
       bash "$HOME/.tmux/plugins/agent-tmux/scripts/tmux-sessions" status api)"
PLAIN="$(printf '%s' "$ROW" | sed 's/#\[[^]]*\]//g; s/  */ /g; s/^ *//; s/ *$//')"
chk "pills + picker button" "+ 1:api 2:web" "$PLAIN"
case "$ROW" in *'range=user|picker'*) ok "picker button is clickable";; *) bad "no picker range";; esac
case "$ROW" in *'range=user|session_2'*) ok "pills are clickable";; *) bad "no session range";; esac

echo "== 4. bindings a stranger gets for free =="
for k in p o g G 1 3 9; do
  tmux -L $S list-keys -T prefix "$k" >/dev/null 2>&1 && ok "prefix+$k bound" || bad "prefix+$k MISSING"
done
tmux -L $S list-keys -T root MouseDown1Status >/dev/null 2>&1 && ok "status click routing bound" || bad "mouse routing MISSING"
chk "chord keys off by default" 1 "$(tmux -L $S list-keys -T root C-M-3 >/dev/null 2>&1 && echo 0 || echo 1)"

echo "== 5. we did not trample tmux defaults =="
chk "status-interval untouched" 15 "$(tmux -L $S show-options -gv status-interval)"
# tmux's own default is "[#{session_name}] " — the point is that we leave it alone
chk "status-left is still tmux's default" "[#{session_name}] " "$(tmux -L $S show-options -gv status-left)"

echo "== 6. reload is idempotent (prefix+I / prefix+R) =="
for i in 1 2 3; do TMUX="$(tmux -L $S display-message -p '#{socket_path},0,0')" \
  bash "$HOME/.tmux/plugins/agent-tmux/agent-tmux.tmux" >/dev/null 2>&1; done
chk "hooks not stacked" 5 "$(tmux -L $S show-hooks -g | grep -c 'refresh-client -S')"

echo "== 7. the rail follows session lifecycle =="
tmux -L $S new-session -d -s zzz
sleep 1.5
ROW2="$(TMUX="$(tmux -L $S display-message -p '#{socket_path},0,0')" \
        bash "$HOME/.tmux/plugins/agent-tmux/scripts/tmux-sessions" status api | sed 's/#\[[^]]*\]//g; s/  */ /g; s/^ *//; s/ *$//')"
chk "new session on the rail" "+ 1:api 2:web 3:zzz" "$ROW2"

echo "== 8. agent tab colors with no theme present =="
PANE="$(tmux -L $S display-message -p -t api '#{pane_id}')"
export TMUX="$(tmux -L $S display-message -p '#{socket_path},0,0')"
TMUX_PANE="$PANE" bash "$HOME/.tmux/plugins/agent-tmux/scripts/agent-status.sh" blocked </dev/null
case "$(tmux -L $S show-window-options -v -t api window-status-format 2>/dev/null)" in
  *'#f38ba8'*) ok "blocked -> red";; *) bad "no red: $(tmux -L $S show-window-options -v -t api window-status-format)";; esac
TMUX_PANE="$PANE" bash "$HOME/.tmux/plugins/agent-tmux/scripts/agent-status.sh" clear </dev/null
chk "clear removes the override" "" "$(tmux -L $S show-window-options -v -t api window-status-format 2>/dev/null)"
tmux -L $S kill-server 2>/dev/null

echo "== 9. no fzf: rail must still work, picker must fail loudly not silently =="
if command -v fzf >/dev/null; then
  ok "fzf present (skipping degraded-mode check)"
else
  OUT="$(bash "$HOME/.tmux/plugins/agent-tmux/scripts/tmux-sessionizer" 2>&1)"; RC=$?
  chk "picker exits non-zero without fzf" 1 "$RC"
  case "$OUT" in *fzf*) ok "picker names the missing dependency";; *) bad "unhelpful error: '$OUT'";; esac
fi

echo "== 10. the shipped test suites run on a clean box =="
cd "$HOME/.tmux/plugins/agent-tmux"
bash tests/tmux-sessions.test.sh >/tmp/t1.log 2>&1 && ok "rail suite green" || { bad "rail suite red"; tail -12 /tmp/t1.log; }
bash tests/agent-status.test.sh  >/tmp/t2.log 2>&1 && ok "state suite green" || { bad "state suite red"; tail -12 /tmp/t2.log; }

echo
echo "--------------------------------------"
printf 'CLEAN ROOM: %d passed, %d failed\n' "$P" "$F"
[ "$F" -eq 0 ]
