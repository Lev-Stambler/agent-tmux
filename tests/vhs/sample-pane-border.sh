#!/usr/bin/env bash
# Print how the pane borders are drawn in the CONTENT area of a frame (that is,
# above both status rows):
#
#   hl<N>       N pixels of accent-coloured border — the active pane's frame
#   noborder    panes are split but nothing is drawn in the accent colour
#   none        unreadable frame
#
# Same self-calibration as sample-row0.sh: the button pills are the only pure
# blue in the frame, so their pixels locate the status bar -- and one text row
# either side of them is the OTHER status row, whichever way up the bar is
# (the click scenario puts it at the top). Everything outside that is pane
# content, and the border there is the only magenta hue.
# (run.sh's $ROW0_CONF sets both colours.)
#
#   Usage: sample-pane-border.sh <frame.png>
IM="$(command -v magick || command -v convert)"   # ImageMagick 7 or 6
img="$1"
{ [ -f "$img" ] && [ -n "$IM" ]; } || { echo none; exit 0; }
"$IM" "$img" -depth 8 txt:- 2>/dev/null | python3 -c '
import sys
ys = []; mag = []
for line in sys.stdin:
    if line.startswith("#"):
        continue
    try:
        pos, rest = line.split(":", 1)
        x, y = (int(v) for v in pos.split(",")[:2])
        r, g, b = (int(v) for v in rest.split("(", 1)[1].split(")", 1)[0].split(",")[:3])
    except Exception:
        continue
    if r < 60 and g < 60 and b > 190:                   # a button pill: the status bar
        ys.append(y)
    elif r > 110 and b > 110 and g < 95 and abs(r - b) <= 70:
        mag.append(y)
if not ys:
    print("none"); sys.exit()
lo, hi = min(ys), max(ys)
row = hi - lo + 1                                       # the button row
# Two rows of slack either way, not one: the second status row is not
# necessarily the same pixel height as the first (measured 20px against 18px),
# and the rail accent pill hanging into that extra 2px reads as a pane border.
n = sum(1 for y in mag if y < lo - 2 * row or y > hi + 2 * row)
print("hl%d" % n if n else "noborder")
'
