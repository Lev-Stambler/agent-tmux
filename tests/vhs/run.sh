#!/usr/bin/env bash
# VHS end-to-end tests for the tmux agent-status colorizer.
#
# Each scenario renders a REAL tmux session (your catppuccin config) driven through
# agent states, records it to a GIF, extracts frames with ffmpeg, and samples the
# window-tab color of each frame (sample-status-color.sh). It asserts the expected
# color sequence appears, in order. GIFs are kept in out/ for eyeballing.
#
# Deterministic scenarios drive the REAL agent-status.sh directly (the exact
# entrypoint the Claude/Codex hooks call) via set-state.sh — fast and repeatable.
# Real scenarios launch actual claude/codex so the hooks/notify fire end to end.
#
#   Usage: run.sh [scenario|all|deterministic|real]    (default: deterministic)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"; mkdir -p "$OUT"
SS="$HERE/set-state.sh"
SAMP="$HERE/sample-status-color.sh"
ROOT="$(cd "$HERE/../.." && pwd)"
# Build a config for one scenario: demo.conf with the plugin path filled in and
# any per-scenario options spliced in at the marker — which sits BEFORE the
# `run` line on purpose, since options like the palette are read at load time.
mkconf(){ # <name> [extra conf lines] -> path
  local out="$OUT/$1.conf" extra="${2:-}"
  : > "$out"
  while IFS= read -r line; do
    case "$line" in
      *'#{@agent_tmux_extra}'*) [ -n "$extra" ] && printf '%s\n' "$extra" >> "$out" ;;
      *) printf '%s\n' "${line//'#{@agent_tmux_selfdir}'/$ROOT}" >> "$out" ;;
    esac
  done < "$HERE/demo.conf"
  printf '%s' "$out"
}
# Self-contained by default; override to render against your own config.
CFG="${AGENT_TMUX_VHS_CONF:-$(mkconf demo)}"
# Columns before session pill 1 on row 1: 1 leading space + the " + " picker
# button (3) + 1 gap. sample-session-pill.sh maps x-position to pill index.
export PILL_LEAD="${PILL_LEAD:-5}"

command -v vhs    >/dev/null || { echo "FATAL: vhs not found";              exit 2; }
command -v ffmpeg >/dev/null || { echo "FATAL: ffmpeg not found";           exit 2; }
command -v magick >/dev/null || command -v convert >/dev/null \
  || { echo "FATAL: ImageMagick missing (need 'magick' or 'convert')"; exit 2; }

PASS=0; FAIL=0
grn(){ printf '\033[32m%s\033[0m' "$1"; }; rdn(){ printf '\033[31m%s\033[0m' "$1"; }

observed_seq(){ # <gif> -> adjacent-deduped sample list, none/other dropped
  local gif="$1" tmp; tmp="$(mktemp -d)"
  ffmpeg -y -i "$gif" -vf fps=3 "$tmp/f_%04d.png" >/dev/null 2>&1
  local prev="" out="" c
  for f in "$tmp"/f_*.png; do
    c="$(bash "${SAMPLER:-$SAMP}" "$f")"
    { [ "$c" = none ] || [ "$c" = other ] || [ "$c" = "$prev" ]; } && continue
    out="$out $c"; prev="$c"
  done
  rm -rf "$tmp"; echo "${out# }"
}
is_subseq(){ # <expected csv> <observed list> : expected is in-order subsequence?
  # Each expected token is matched as a GLOB, so a scenario can assert the shape
  # of a sample ("b1c[0-9]*" = buttons merged and SOME border present) where the
  # exact position is the theme's business, not ours.
  local exp=(${1//,/ }) obs=($2) i=0 o
  for o in "${obs[@]}"; do
    [ "$i" -lt "${#exp[@]}" ] && case "$o" in ${exp[$i]}) i=$((i+1)) ;; esac
  done
  [ "$i" -eq "${#exp[@]}" ]
}
saw(){ # <token glob> <observed list> : did this sample ever appear?
  local o; for o in $2; do case "$o" in $1) return 0 ;; esac; done; return 1
}

render(){ # <name> <tape> <socket> <timeout-s>: 1 (reported) if no GIF came out
  rm -f "$OUT/$1.gif"
  timeout "$4" vhs "$2" >"$OUT/$1.log" 2>&1
  tmux -L "$3" kill-server 2>/dev/null
  # -s, not -f: an ffmpeg failure inside vhs leaves a 0-byte GIF behind, and
  # sampling that reads as "the plugin drew nothing".
  [ -s "$OUT/$1.gif" ] && return 0
  echo "  $(rdn FAIL) no GIF — see $OUT/$1.log"; FAIL=$((FAIL+1)); return 1
}

run_scenario(){ # <name> <expected csv> <tape> <socket> <timeout-s> [sampler] [forbidden glob]
  local name="$1" exp="$2" tape="$3" sock="$4" to="$5" forbid="${7:-}"
  SAMPLER="${6:-$SAMP}"
  printf '== %-12s ==  expect: %s\n' "$name" "$exp"
  render "$name" "$tape" "$sock" "$to" || return
  local obs; obs="$(observed_seq "$OUT/$name.gif")"
  printf '  observed: %s\n' "${obs:-<none>}"
  if [ -n "$forbid" ] && saw "$forbid" "$obs"; then
    echo "  $(rdn FAIL)  saw [$forbid], which must never happen"; FAIL=$((FAIL+1))
  elif is_subseq "$exp" "$obs"; then echo "  $(grn PASS)  $OUT/$name.gif"; PASS=$((PASS+1))
  else echo "  $(rdn FAIL)  [$exp] not a subsequence of observed"; FAIL=$((FAIL+1)); fi
}

tape_header(){ cat <<EOF
Output "$1"
Set Shell "bash"
Set Width ${2:-1100}
Set Height 360
Set FontSize 16
Set Padding 0
Set Margin 0
Set Theme "Catppuccin Mocha"
Set Framerate 10
Set TypingSpeed 10ms
Sleep 600ms
EOF
}

# Write a deterministic scenario: a setup script (tmux + bg driver + attach) and a
# tiny tape that just runs it. $1 name $2 sock $3 split? $4 driver-body $5 watch-s
det(){
  local name="$1" sock="$2" split="$3" driver="$4" watch="$5"
  local sh="$OUT/$name.run.sh" tape="$OUT/$name.tape"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $CFG new-session -d -s s -x 136 -y 22
$split
A=\$(tmux -L \$S list-panes -t s -F '#{pane_id}' | sed -n 1p)
B=\$(tmux -L \$S list-panes -t s -F '#{pane_id}' | sed -n 2p)
( $driver ) &
exec tmux -L \$S attach -t s
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif"; printf 'Type "bash %s"\nEnter\nSleep %ss\n' "$sh" "$watch"; } >"$tape"
  echo "$tape"
}

# Real scenario: setup script (session + attach), tape types the real agent command.
# $6 (optional) = working dir; default scratch. Use a TRUSTED dir for claude so it
# doesn't block on a "trust this folder?" prompt.
real(){
  local name="$1" sock="$2" cmd="$3" prompt="$4" watch="$5" dir="${6:-}" presteps="${7:-}"
  local sh="$OUT/$name.run.sh" tape="$OUT/$name.tape"
  [ -n "$dir" ] || dir="$(mktemp -d /tmp/vhsr.XXXX)"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $CFG new-session -d -s s -c $dir -x 136 -y 26
exec tmux -L \$S attach -t s
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif"
    printf 'Type "bash %s"\nEnter\nSleep 1s\n' "$sh"
    printf 'Type "%s"\nEnter\nSleep 9s\n' "$cmd"
    printf '%s' "$presteps"   # e.g. accept a "trust this folder?" prompt
    printf 'Type "%s"\nSleep 500ms\nEnter\nSleep %ss\n' "$prompt" "$watch"
  } >"$tape"
  echo "$tape"
}

scn_single(){    det single    sgl "" \
  "sleep 1.5; $SS \$S \$A working; sleep 2; $SS \$S \$A waiting; sleep 2; $SS \$S \$A blocked; sleep 2; $SS \$S \$A done; sleep 2" 11; }
scn_aggregate(){ det aggregate agg "tmux -L \$S split-window -h -t s" \
  "sleep 1.5; $SS \$S \$A working; $SS \$S \$B working; sleep 2.5; $SS \$S \$B waiting; sleep 2.5; $SS \$S \$A blocked; sleep 2.5; $SS \$S \$A working; $SS \$S \$B working; sleep 2.5" 12; }
scn_manualack(){ det manual-ack ack "" \
  "sleep 1.5; $SS \$S \$A working; sleep 2.5; $SS \$S \$A done; sleep 2.5" 8; }

# Sessions band (bottom status row): three sessions as numbered pills; the
# accent pill must track switch-client — 2 (attached) -> 1 -> 3. Uniform 2-char
# names keep the pill geometry sample-session-pill.sh assumes.
scn_sessions(){
  local name=sessions sock=ses
  local sh="$OUT/$name.run.sh" tape="$OUT/$name.tape"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $CFG new-session -d -s ab -x 136 -y 22
tmux -L \$S new-session -d -s aa
tmux -L \$S new-session -d -s zz
(
  sleep 2.5
  C=\$(tmux -L \$S list-clients -F '#{client_name}' | head -1)
  tmux -L \$S switch-client -c "\$C" -t aa; sleep 3
  tmux -L \$S switch-client -c "\$C" -t zz; sleep 3
) &
exec tmux -L \$S attach -t ab
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif"; printf 'Type "bash %s"\nEnter\nSleep 10s\n' "$sh"; } >"$tape"
  echo "$tape"
}

# Row 0: the window buttons, and the border that has to follow the selected
# window. Both colours are overridden to something the theme never uses, because
# catppuccin already paints the current tab mauve — our own default accent — and
# a sampler that cannot tell the two apart would pass with the border missing.
ROW0_CONF='set -g @agent_tmux_accent "#ff00ff"
set -g @agent_tmux_button_bg "#0000ff"
set -g @agent_tmux_button_label off'

# On a laptop: three separate pills (b3), and the border walking right along the
# tabs as windows 1 -> 2 -> 3 are selected. Position is in sixteenths of the
# screen, and the expectation is RANGES, not exact buckets: which frame ffmpeg
# lands on inside a three-second hold moves a sample by one. The ranges do not
# overlap, so the claim they encode is still "the border tracks the selection".
ROW0_WIDE="${ROW0_WIDE:-b3c[34],b3c[56],b3c[78]}"
# On a phone the tab list is a scrolling window of ONE tab -- tmux keeps the
# current window visible and marks the rest with < and > -- so the border does
# not travel anywhere. What has to hold is that the buttons are still there, in
# their merged form, and that the tab you are on is still bordered. Position is
# the theme's business, so it is matched as a glob.
ROW0_MOBILE="${ROW0_MOBILE:-b1c[0-9]*}"

# $1 name $2 sock $3 tape width px $4 columns. Three windows, and the client is
# walked along them so the border has to move.
scn_row0(){
  local name="$1" sock="$2" wpx="$3" cols="$4"
  local cfg sh tape
  cfg="$(mkconf "$name" "$ROW0_CONF")"
  sh="$OUT/$name.run.sh"; tape="$OUT/$name.tape"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $cfg new-session -d -s s -x $cols -y 22
tmux -L \$S new-window -t s; tmux -L \$S new-window -t s
tmux -L \$S select-window -t s:1
(
  sleep 3
  tmux -L \$S select-window -t s:2; sleep 3
  tmux -L \$S select-window -t s:3; sleep 3
) &
exec tmux -L \$S attach -t s
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif" "$wpx"
    printf 'Type "bash %s"\nEnter\nSleep 11s\nScreenshot "%s"\n' "$sh" "$OUT/$name.png"
  } >"$tape"
  echo "$tape"
}

# Clicking, for real. VHS has no mouse command, but a status-bar click is just
# an SGR escape sequence arriving on the terminal's input -- which VHS CAN type.
# The bar goes to the top for this one so the row to aim at is row 1 whatever
# ttyd's font metrics make of the window size; the three buttons are then the
# leftmost columns of row 0 (" + " " │ " " ─ " => columns 2, 6 and 10).
#
# The assertion is tmux's own state, not pixels: this scenario exists to prove
# that a real click reaches the routing at all -- emitting a #[range=user|...]
# and having tmux REPORT it are different things (and below tmux 3.4, the second
# one does not happen).
click_at(){ printf 'Escape\nType "[<0;%s;1M"\nEscape\nType "[<0;%s;1m"\nSleep 2s\n' "$1" "$1"; }
scn_click(){ # <state file>
  local name=row0-click sock=r0c cfg sh tape
  cfg="$(mkconf "$name" "$ROW0_CONF"$'\nset -g status-position top')"
  sh="$OUT/$name.run.sh"; tape="$OUT/$name.tape"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $cfg new-session -d -s s -x 136 -y 22
(
  # Dumped from inside the session while the tape is still recording -- the
  # server is killed the moment vhs exits.
  sleep 11
  tmux -L \$S list-windows -t s -F 'W #{window_index}' > $1
  tmux -L \$S list-panes -a -F 'P #{window_index} #{pane_left} #{pane_top}' >> $1
) &
exec tmux -L \$S attach -t s
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif"
    printf 'Set TypingSpeed 5ms\nType "bash %s"\nEnter\nSleep 5s\n' "$sh"
    click_at 2; click_at 6; click_at 10
    printf 'Screenshot "%s"\nSleep 5s\n' "$OUT/$name.png"
  } >"$tape"
  echo "$tape"
}
run_click(){
  local state="$OUT/row0-click.state" name=row0-click
  printf '== %-12s ==  expect: + opens a window, │ and ─ split it\n' "$name"
  rm -f "$state"
  render "$name" "$(scn_click "$state")" r0c 240 || return
  if [ ! -s "$state" ]; then
    echo "  $(rdn FAIL)  the session never reported its state — see $OUT/$name.log"
    FAIL=$((FAIL+1)); return
  fi
  local wins panes lefts tops
  wins="$(grep -c '^W ' "$state")"
  panes="$(grep -c '^P 2 ' "$state")"
  lefts="$(awk '$1=="P" && $2==2 {print $3}' "$state" | sort -u | wc -l)"
  tops="$(awk '$1=="P" && $2==2 {print $4}' "$state" | sort -u | wc -l)"
  # ...and the pane you land in has to be visible among them. The screenshot is
  # taken after the last split, so the accent-coloured frame is either drawn in
  # the content area or it is not.
  local hl; hl="$(bash "$HERE/sample-pane-border.sh" "$OUT/$name.png")"
  printf '  observed: %s windows, %s panes in window 2 (%s columns, %s rows), active pane %s\n' \
    "$wins" "$panes" "$lefts" "$tops" "$hl"
  if [ "$wins" = 2 ] && [ "$panes" = 3 ] && [ "$lefts" = 2 ] && [ "$tops" = 2 ] \
     && case "$hl" in hl[0-9]*) [ "${hl#hl}" -ge 100 ] ;; *) false ;; esac; then
    echo "  $(grn PASS)  $OUT/$name.gif"; PASS=$((PASS+1))
  else
    echo "  $(rdn FAIL)  want 2 windows, 3 panes split both ways, active pane outlined"
    FAIL=$((FAIL+1))
  fi
}

# Explode and collapse, driven by the real key binding through a real client.
# The assertion is tmux's own state plus the pixels: with the panes burst out
# there is no pane divider on screen, and collapsing brings it back -- which is
# what sample-pane-border.sh already measures for the row-0 scenarios.
scn_burst(){ # <state file>
  local name=burst sock=brs cfg sh tape
  # catppuccin's own window module renders the host, not #{window_name}, so
  # without these the recorded GIF cannot show the half of this feature that is
  # the tab names -- stack, stack·2, stack·3.
  cfg="$(mkconf "$name" "$ROW0_CONF"$'\nset -g @catppuccin_window_text " #W"\nset -g @catppuccin_window_current_text " #W"')"
  sh="$OUT/$name.run.sh"; tape="$OUT/$name.tape"
  cat >"$sh" <<EOF
#!/usr/bin/env bash
S=$sock
tmux -L \$S kill-server 2>/dev/null
tmux -L \$S -f $cfg new-session -d -s s -n stack -x 136 -y 22
tmux -L \$S split-window -h -t s
tmux -L \$S split-window -v -t s
(
  # The layout has to be captured with the CLIENT attached: a session resizes to
  # its client on attach, and the layout string encodes the window size -- taken
  # before that, it would differ for a reason that has nothing to do with burst.
  sleep 2
  tmux -L \$S display-message -p -t s '#{window_layout}' > $1.layout
  sleep 10
  tmux -L \$S list-windows -t s -F 'W #{window_index} #{window_name} #{window_panes}' > $1
  tmux -L \$S display-message -p -t s:1 'L #{window_layout}' >> $1
) &
exec tmux -L \$S attach -t s
EOF
  chmod +x "$sh"
  { tape_header "$OUT/$name.gif"
    printf 'Set TypingSpeed 5ms\nType "bash %s"\nEnter\nSleep 3s\n' "$sh"
    printf 'Screenshot "%s.before.png"\n' "$OUT/$name"
    printf 'Ctrl+b\nSleep 300ms\nType "e"\nSleep 3s\n'          # explode
    printf 'Screenshot "%s.exploded.png"\n' "$OUT/$name"
    printf 'Ctrl+b\nSleep 300ms\nType "e"\nSleep 3s\n'          # collapse
    printf 'Screenshot "%s.after.png"\nSleep 6s\n' "$OUT/$name"
  } >"$tape"
  echo "$tape"
}
run_burst(){
  local state="$OUT/burst.state" name=burst
  printf '== %-12s ==  expect: prefix+e explodes 3 panes into 3 tabs, and puts them back\n' "$name"
  rm -f "$state" "$state.layout"
  render "$name" "$(scn_burst "$state")" brs 240 || return
  if [ ! -s "$state" ]; then
    echo "  $(rdn FAIL)  the session never reported its state — see $OUT/$name.log"
    FAIL=$((FAIL+1)); return
  fi
  local wins panes layout before div_before div_burst div_after
  wins="$(grep -c '^W ' "$state")"
  panes="$(awk '$1=="W" {print $NF}' "$state" | paste -sd, -)"
  layout="$(sed -n 's/^L //p' "$state")"
  before="$(cat "$state.layout" 2>/dev/null)"
  div_before="$(bash "$HERE/sample-pane-border.sh" "$OUT/$name.before.png")"
  div_burst="$(bash "$HERE/sample-pane-border.sh" "$OUT/$name.exploded.png")"
  div_after="$(bash "$HERE/sample-pane-border.sh" "$OUT/$name.after.png")"
  printf '  observed: %s window(s), panes=%s; borders %s -> %s -> %s\n' \
    "$wins" "$panes" "$div_before" "$div_burst" "$div_after"
  # Back to one window of three panes, the layout byte-identical to the one the
  # session reported before the key was ever pressed, and the divider gone from
  # the screen while exploded.
  # div_before is asserted too, not just printed: without it a window that never
  # got its splits would still satisfy "no divider while exploded".
  if [ "$wins" = 1 ] && [ "$panes" = 3 ] && [ "$layout" = "$before" ] \
     && [ "$div_before" != noborder ] && [ "$div_burst" = noborder ] \
     && [ "$div_after" != noborder ]; then
    echo "  $(grn PASS)  $OUT/$name.gif"; PASS=$((PASS+1))
  else
    echo "  $(rdn FAIL)  want 1 window of 3 panes, layout restored, divider back"
    FAIL=$((FAIL+1))
  fi
}

do_det(){
  run_scenario single     "blue,yellow,red,green" "$(scn_single)"     sgl 180
  run_scenario aggregate  "blue,yellow,red,blue"  "$(scn_aggregate)"  agg 180
  run_scenario manual-ack "blue,green"            "$(scn_manualack)"  ack 150
  run_scenario sessions   "2,1,3"                 "$(scn_sessions)"   ses 180 "$HERE/sample-session-pill.sh"
  do_row0
}
# A laptop and a phone. The phone case is the one that matters: row 0 is far too
# narrow for the tabs there, so the buttons have to survive at the left edge.
do_row0(){
  # "b?c-" is the buttons rendering with the current tab NOT bordered: the exact
  # regression this pair exists to catch, and a subsequence check alone cannot
  # express "never".
  run_scenario row0-buttons "$ROW0_WIDE"   "$(scn_row0 row0-buttons r0w 1100 136)" r0w 180 "$HERE/sample-row0.sh" 'b?c-'
  run_scenario row0-mobile  "$ROW0_MOBILE" "$(scn_row0 row0-mobile  r0m  550  55)"  r0m 180 "$HERE/sample-row0.sh" 'b?c-'
  run_click
  run_burst
}
# Real-agent end-to-end. NOTE: claude does not enter its TUI under vhs/ttyd (it
# prints the trust prompt and returns to the shell), so the real-claude scenario is
# opt-in only (run.sh real-claude) and not part of the gate. Claude's coloring uses
# the same agent-status.sh path the deterministic `single` scenario verifies, and was
# confirmed live. Codex DOES run its TUI under VHS, so real-codex is the real gate.
do_real(){
  run_scenario real-codex  "blue,yellow" \
    "$(real real-codex  rx 'codex -c features.tui_app_server=false -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox' 'say hi in one word' 22)" rx 260
}

case "${1:-deterministic}" in
  deterministic|det) do_det ;;
  real)              do_real ;;
  all)               do_det; do_real ;;
  single)      run_scenario single     "blue,yellow,red,green" "$(scn_single)"    sgl 180 ;;
  aggregate)   run_scenario aggregate  "blue,yellow,red,blue"  "$(scn_aggregate)" agg 180 ;;
  manual-ack)  run_scenario manual-ack "blue,green"            "$(scn_manualack)" ack 150 ;;
  sessions)    run_scenario sessions   "2,1,3"                 "$(scn_sessions)"  ses 180 "$HERE/sample-session-pill.sh" ;;
  row0)        do_row0 ;;
  row0-buttons) run_scenario row0-buttons "$ROW0_WIDE"   "$(scn_row0 row0-buttons r0w 1100 136)" r0w 180 "$HERE/sample-row0.sh" 'b?c-' ;;
  row0-mobile)  run_scenario row0-mobile  "$ROW0_MOBILE" "$(scn_row0 row0-mobile  r0m  550  55)"  r0m 180 "$HERE/sample-row0.sh" 'b?c-' ;;
  row0-click)   run_click ;;
  burst)        run_burst ;;
  real-claude) do_real_one=1; run_scenario real-claude "blue,yellow" "$(real real-claude rc 'claude --dangerously-skip-permissions' 'say hi in one word' 22)" rc 260 ;;
  real-codex)  run_scenario real-codex "blue,yellow" "$(real real-codex rx 'codex -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox' 'say hi in one word' 22)" rx 260 ;;
  *) echo "unknown scenario: $1"; exit 2 ;;
esac

echo "----------------------------------------"
printf 'VHS: %d passed, %d failed   (GIFs in %s)\n' "$PASS" "$FAIL" "$OUT"
[ "$FAIL" -eq 0 ]
