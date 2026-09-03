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
rm -f "$OUT/.demo.conf" "$OUT/.demo.run.sh" "$OUT/.demo.tape" "$OUT/.demo.rc"
echo "wrote $OUT/sessions.gif"
