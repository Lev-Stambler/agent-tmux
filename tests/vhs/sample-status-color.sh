#!/usr/bin/env bash
# Print the dominant agent-status accent color (red|yellow|blue|green|none) of the
# tmux WINDOW TABS in a rendered frame.
#
# We sample the bottom-LEFT strip only — the window tabs live at the left of the
# status line; cropping left avoids catppuccin's right-side modules (green session,
# sapphire clock, rosewater dir) which would otherwise be false positives.
# Matching is tolerant: GIF/host palette quantization shifts colors by a few units,
# and ffmpeg frames are RGBA, so we match the first 3 channels within a distance.
#
#   Usage: sample-status-color.sh <frame.png> [crop_geometry]
img="$1"; crop="${2:-48%x9%+0+0}"
[ -f "$img" ] || { echo none; exit 0; }
magick "$img" -gravity SouthWest -crop "$crop" +repage -depth 8 \
  -format '%c' histogram:info:- 2>/dev/null | python3 -c '
import sys, re
acc  = {"red":(243,139,168), "yellow":(249,226,175), "blue":(137,180,250), "green":(166,227,161)}
# filled pills (red/yellow/green) paint hundreds of px; the "working" blue pill is a
# dark pill with blue TEXT only, so it needs a much lower count threshold and a wider
# color tolerance (anti-aliased text edges) — but not so wide it catches lavender.
mins = {"red":120, "yellow":120, "green":120, "blue":18}
tol  = {"red":30,  "yellow":30,  "green":30,  "blue":42}
tot  = {k:0 for k in acc}
for line in sys.stdin:
    m = re.search(r"(\d+):\s*\((\d+),(\d+),(\d+)", line)   # first 3 channels (RGB or RGBA)
    if not m: continue
    cnt = int(m.group(1)); r,g,b = int(m.group(2)), int(m.group(3)), int(m.group(4))
    for k,(R,G,B) in acc.items():
        if (r-R)**2 + (g-G)**2 + (b-B)**2 <= tol[k]*tol[k]:
            tot[k] += cnt
best, bc = "none", 0
for k in acc:
    if tot[k] >= mins[k] and tot[k] > bc:
        best, bc = k, tot[k]
print(best)
'
