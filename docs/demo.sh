#!/usr/bin/env bash
# Renders the README GIFs. Separate from tests/vhs/ on purpose: the test
# scenarios lock pill geometry (2-char session names, fixed lead) so the
# pixel sampler stays valid, while these just need to look like real use.
#   Usage: docs/demo.sh          (needs vhs + ttyd)
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE"

cat > "$OUT/.demo.conf" <<CONF
set -g default-terminal "tmux-256color"
set-option -sa terminal-overrides ",*:RGB"
set -g mouse on
set -g base-index 1
set -g automatic-rename off
set -g @catppuccin_flavor "mocha"
set -g @catppuccin_window_status_style "rounded"
set -g @catppuccin_window_text " #W"
set -g @catppuccin_window_current_text " #W"
run '\$HOME/.config/tmux/plugins/tmux/catppuccin.tmux'
run '$ROOT/agent-tmux.tmux'
# after the theme, which sets its own
set -g status-left ""
set -g status-right ""
CONF

printf 'PS1="$ "\n' > "$OUT/.demo.rc"

cat > "$OUT/.demo.run.sh" <<CONF
#!/usr/bin/env bash
S=atxdemo
tmux -L \$S kill-server 2>/dev/null
B='bash --rcfile "$OUT/.demo.rc" -i'
tmux -L \$S -f "$OUT/.demo.conf" new-session -d -s api -n app -x 100 -y 16 "\$B"
tmux -L \$S new-session -d -s infra -n app "\$B"
tmux -L \$S new-session -d -s web   -n app "\$B"
for s_ in api infra web; do tmux -L \$S rename-window -t "\$s_":1 app; done
(
  sleep 3
  C=\$(tmux -L \$S list-clients -F '#{client_name}' | head -1)
  tmux -L \$S switch-client -c "\$C" -t web;   sleep 2.5
  tmux -L \$S switch-client -c "\$C" -t infra; sleep 2.5
  tmux -L \$S switch-client -c "\$C" -t api;   sleep 2
) &
exec tmux -L \$S attach -t api
CONF
chmod +x "$OUT/.demo.run.sh"

cat > "$OUT/.demo.tape" <<CONF
Output "$OUT/sessions.gif"
Set Shell "bash"
Set Width 900
Set Height 190
Set FontSize 15
Set Padding 0
Set Margin 0
Set Theme "Catppuccin Mocha"
Set Framerate 12
Sleep 300ms
Hide
Type "bash $OUT/.demo.run.sh"
Enter
Sleep 2s
Show
Sleep 11s
CONF

vhs "$OUT/.demo.tape"
tmux -L atxdemo kill-server 2>/dev/null || true
echo "wrote $OUT/sessions.gif"

# ---------------------------------------------------------------- tab colours --
# Drives the REAL agent-status.sh (the entrypoint the Claude/Codex hooks call)
# through a turn, so the GIF shows the actual production path rather than a mock.
colour_gif(){ # <name> <panes> <script-body> <seconds>
  local name="$1" panes="$2" body="$3" secs="$4"
  cat > "$OUT/.c.run.sh" <<CONF
#!/usr/bin/env bash
S=atxcolour
SS="$ROOT/tests/vhs/set-state.sh"
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f "$OUT/.demo.conf" new-session -d -s api -n api -x 100 -y 14 "bash --rcfile $OUT/.demo.rc -i"
tmux -L \$S rename-window -t api:1 api
A=\$(tmux -L \$S display-message -p -t api '#{pane_id}')
$panes
( $body ) &
exec tmux -L \$S attach -t api
CONF
  chmod +x "$OUT/.c.run.sh"
  cat > "$OUT/.c.tape" <<CONF
Output "$OUT/$name.gif"
Set Shell "bash"
Set Width 900
Set Height 170
Set FontSize 15
Set Padding 0
Set Margin 0
Set Theme "Catppuccin Mocha"
Set Framerate 12
Sleep 300ms
Hide
Type "bash $OUT/.c.run.sh"
Enter
Sleep 2s
Show
Sleep ${secs}s
CONF
  vhs "$OUT/.c.tape"
  tmux -L atxcolour kill-server 2>/dev/null || true
  echo "wrote $OUT/$name.gif"
}

colour_gif single "" \
  'sleep 1.5
   bash $SS $S $A working </dev/null; sleep 2.5
   bash $SS $S $A waiting </dev/null; sleep 2.5
   bash $SS $S $A blocked </dev/null; sleep 2.5
   bash $SS $S $A done    </dev/null; sleep 2.5' 13

colour_gif aggregate \
  'B=$(tmux -L $S split-window -h -t api -P -F "#{pane_id}" "bash --rcfile '"$OUT"'/.demo.rc -i")' \
  'sleep 1.5
   bash $SS $S $A working </dev/null
   bash $SS $S $B working </dev/null; sleep 2.5
   bash $SS $S $B waiting </dev/null; sleep 2.5
   bash $SS $S $A blocked </dev/null; sleep 3
   bash $SS $S $A working </dev/null
   bash $SS $S $B working </dev/null; sleep 2.5' 14

# ------------------------------------------------------------------ mobile --
# A phone-width terminal: the rail collapses to the hamburger, and prefix+m
# opens the menu. Rendered NARROW on purpose -- the wide 900px GIFs scale down
# to ~6px text on a phone, which is the thing this whole change is about.
cat > "$OUT/.m.run.sh" <<CONF
#!/usr/bin/env bash
S=atxmobile
tmux -L \$S kill-server 2>/dev/null
B='bash --rcfile $OUT/.demo.rc -i'
tmux -L \$S -f "$OUT/.demo.conf" new-session -d -s api -n app -x 44 -y 22 "\$B"
for s_ in infra web payments search; do tmux -L \$S new-session -d -s \$s_ -n app "\$B"; done
for s_ in api infra web payments search; do tmux -L \$S rename-window -t \$s_:1 app; done
tmux -L \$S set-option -p -t search @agent_state blocked
tmux -L \$S set-option -p -t web    @agent_state waiting
exec tmux -L \$S attach -t api
CONF
chmod +x "$OUT/.m.run.sh"
cat > "$OUT/.m.tape" <<CONF
Output "$OUT/mobile.gif"
Set Shell "bash"
Set Width 430
Set Height 440
Set FontSize 16
Set Padding 0
Set Margin 0
Set Theme "Catppuccin Mocha"
Set Framerate 10
Sleep 300ms
Hide
Type "bash $OUT/.m.run.sh"
Enter
Sleep 3s
Show
Sleep 2500ms
Ctrl+b
Sleep 400ms
Type "m"
Sleep 5s
CONF
vhs "$OUT/.m.tape"
tmux -L atxmobile kill-server 2>/dev/null || true
echo "wrote $OUT/mobile.gif"

[ -n "${KEEP:-}" ] || rm -f "$OUT/.demo.conf" "$OUT/.demo.run.sh" "$OUT/.demo.tape" "$OUT/.demo.rc" \
      "$OUT/.c.run.sh" "$OUT/.c.tape" "$OUT/.m.run.sh" "$OUT/.m.tape"
