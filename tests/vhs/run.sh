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
# Self-contained by default; override to render against your own config.
CFG="${AGENT_TMUX_VHS_CONF:-$OUT/demo.conf}"
sed "s|#{@agent_tmux_selfdir}|$ROOT|g" "$HERE/demo.conf" > "$OUT/demo.conf"
# Columns before session pill 1 on row 1: 1 leading space + the " + " picker
# button (3) + 1 gap. sample-session-pill.sh maps x-position to pill index.
export PILL_LEAD="${PILL_LEAD:-5}"

command -v vhs    >/dev/null || { echo "FATAL: vhs not found";              exit 2; }
command -v ffmpeg >/dev/null || { echo "FATAL: ffmpeg not found";           exit 2; }
command -v magick >/dev/null || { echo "FATAL: ImageMagick(magick) missing"; exit 2; }

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
  local exp=(${1//,/ }) obs=($2) i=0 o
  for o in "${obs[@]}"; do [ "$i" -lt "${#exp[@]}" ] && [ "$o" = "${exp[$i]}" ] && i=$((i+1)); done
  [ "$i" -eq "${#exp[@]}" ]
}

run_scenario(){ # <name> <expected csv> <tape> <socket> <timeout-s> [sampler]
  local name="$1" exp="$2" tape="$3" sock="$4" to="$5"
  SAMPLER="${6:-$SAMP}"
  printf '== %-12s ==  expect: %s\n' "$name" "$exp"
  rm -f "$OUT/$name.gif"
  timeout "$to" vhs "$tape" >"$OUT/$name.log" 2>&1
  tmux -L "$sock" kill-server 2>/dev/null
  if [ ! -f "$OUT/$name.gif" ]; then
    echo "  $(rdn FAIL) no GIF — see $OUT/$name.log"; FAIL=$((FAIL+1)); return
  fi
  local obs; obs="$(observed_seq "$OUT/$name.gif")"
  printf '  observed: %s\n' "${obs:-<none>}"
  if is_subseq "$exp" "$obs"; then echo "  $(grn PASS)  $OUT/$name.gif"; PASS=$((PASS+1))
  else echo "  $(rdn FAIL)  [$exp] not a subsequence of observed"; FAIL=$((FAIL+1)); fi
}

tape_header(){ cat <<EOF
Output "$1"
Set Shell "bash"
Set Width 1100
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

do_det(){
  run_scenario single     "blue,yellow,red,green" "$(scn_single)"     sgl 180
  run_scenario aggregate  "blue,yellow,red,blue"  "$(scn_aggregate)"  agg 180
  run_scenario manual-ack "blue,green"            "$(scn_manualack)"  ack 150
  run_scenario sessions   "2,1,3"                 "$(scn_sessions)"   ses 180 "$HERE/sample-session-pill.sh"
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
  real-claude) do_real_one=1; run_scenario real-claude "blue,yellow" "$(real real-claude rc 'claude --dangerously-skip-permissions' 'say hi in one word' 22)" rc 260 ;;
  real-codex)  run_scenario real-codex "blue,yellow" "$(real real-codex rx 'codex -c model_reasoning_effort=low --dangerously-bypass-approvals-and-sandbox' 'say hi in one word' 22)" rx 260 ;;
  *) echo "unknown scenario: $1"; exit 2 ;;
esac

echo "----------------------------------------"
printf 'VHS: %d passed, %d failed   (GIFs in %s)\n' "$PASS" "$FAIL" "$OUT"
[ "$FAIL" -eq 0 ]
