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

# ------------------------------------------------- row 0: buttons + border --
# Clicks the three row-0 buttons for real. VHS has no mouse command, but a
# status-bar click is just an SGR escape sequence on the terminal's input, and
# VHS can type one: ESC [ < 0 ; <col> ; <row> M, then the same with m to release.
#
# The row to aim at cannot be assumed -- VHS sizes the terminal in PIXELS, so how
# many rows 190px of 15pt text comes to is ttyd's business. Ask tmux once, with a
# throwaway render, and then write the real tape.
probe_rows(){ # <width> <height> <fontsize> -> total rows in that terminal
  local w="$1" h="$2" fs="$3" f="$OUT/.rows"
  rm -f "$f"
  cat > "$OUT/.p.run.sh" <<CONF
#!/usr/bin/env bash
S=atxprobe
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f "$OUT/.demo.conf" new-session -d -s p -x 100 -y 16
( sleep 2; tmux -L \$S display-message -p '#{client_height}' > $f ) &
exec tmux -L \$S attach -t p
CONF
  cat > "$OUT/.p.tape" <<CONF
Output "$OUT/.probe.gif"
Set Shell "bash"
Set Width $w
Set Height $h
Set FontSize $fs
Set Padding 0
Set Margin 0
Sleep 300ms
Type "bash $OUT/.p.run.sh"
Enter
Sleep 4s
CONF
  vhs "$OUT/.p.tape" >/dev/null 2>&1
  tmux -L atxprobe kill-server 2>/dev/null || true
  # #{client_height} is the whole terminal, status rows included -- so this is
  # the row count, and the two status lines are the last two of it.
  cat "$f" 2>/dev/null || echo 12
}

W=900; H=230; FS=15
ROWS="$(probe_rows $W $H $FS)"
R0=$(( ROWS - 1 ))            # 1-based terminal row of status line 0
cat > "$OUT/.w.run.sh" <<CONF
#!/usr/bin/env bash
S=atxwin
B='bash --rcfile $OUT/.demo.rc -i'
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f "$OUT/.demo.conf" new-session -d -s api -n api -x 100 -y 16 "\$B"
tmux -L \$S new-window -a -t api:1 -n build "\$B"   # -t api alone means "index 1", which is taken
tmux -L \$S select-window -t api:1
exec tmux -L \$S attach -t api
CONF
chmod +x "$OUT/.w.run.sh"
click(){ # <column> [pause] — press and release button 1 on row 0
  printf 'Escape\nType "[<0;%s;%sM"\nEscape\nType "[<0;%s;%sm"\nSleep %s\n' \
         "$1" "$R0" "$1" "$R0" "${2:-2s}"
}
{ cat <<CONF
Output "$OUT/windows.gif"
Set Shell "bash"
Set Width $W
Set Height $H
Set FontSize $FS
Set Padding 0
Set Margin 0
Set Theme "Catppuccin Mocha"
Set Framerate 12
Set TypingSpeed 5ms
Sleep 300ms
Hide
Type "bash $OUT/.w.run.sh"
Enter
Sleep 3s
Show
Sleep 1500ms
CONF
  click 2 2500ms      # +  -> a third window, and the border moves to it
  click 6 2500ms      # │  -> split left/right
  click 10 3s         # ─  -> split top/bottom
} > "$OUT/.w.tape"
vhs "$OUT/.w.tape"
tmux -L atxwin kill-server 2>/dev/null || true
echo "wrote $OUT/windows.gif"

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
      "$OUT/.c.run.sh" "$OUT/.c.tape" "$OUT/.m.run.sh" "$OUT/.m.tape" \
      "$OUT/.w.run.sh" "$OUT/.w.tape" "$OUT/.p.run.sh" "$OUT/.p.tape" "$OUT/.probe.gif" "$OUT/.rows"
