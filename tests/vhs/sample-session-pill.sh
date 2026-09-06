#!/usr/bin/env bash
# Print which session pill (1|2|3|...) is the ACCENT (mauve) one on the bottom
# status row of a rendered frame — the sessions band drawn by bin/tmux-sessions.
# Position-based: the accent pill's own x-run -> terminal column -> pill index,
# assuming the test layout "<lead>1:aa  2:ab  3:zz " (6-char pills, 1-char gaps).
# $PILL_LEAD is how many columns precede pill 1: 1 for the bare row, 5 with the
# default " + " picker button in front of it. Tolerance is tight (25) so
# catppuccin lavender on the tabs row can never match. Prints none if no mauve.
#
# The column width is measured from the pill (it is exactly 6 columns wide), not
# taken from the tape: VHS sizes the terminal from PIXELS, so a tape asking for
# 136 columns renders about 107 of them, and assuming the nominal number put the
# rightmost pill a whole index out.
#
#   Usage: [PILL_LEAD=n] sample-session-pill.sh <frame.png>
IM="$(command -v magick || command -v convert)"   # ImageMagick 7 or 6
img="$1"; lead="${PILL_LEAD:-1}"
{ [ -f "$img" ] && [ -n "$IM" ]; } || { echo none; exit 0; }
# 5% is the BOTTOM row alone (the two status rows are 2 of 18 lines here, so a
# row is ~5.5%). It used to be 14%, which reached up into row 0 and pooled the
# theme's mauve current-tab pill into the mean -- harmless until anything moved
# the tabs sideways, at which point this sampler reported the wrong pill.
"$IM" "$img" -gravity South -crop "100%x5%+0+0" +repage -depth 8 txt:- 2>/dev/null | python3 -c '
import sys
lead = int(sys.argv[1]); M = (203, 166, 247); tol2 = 25 * 25
xs = set()
for line in sys.stdin:
    if line.startswith("#"):
        continue
    try:
        pos, rest = line.split(":", 1)
        x = int(pos.split(",")[0])
        r, g, b = (int(v) for v in rest.split("(", 1)[1].split(")", 1)[0].split(",")[:3])
    except Exception:
        continue
    if (r - M[0]) ** 2 + (g - M[1]) ** 2 + (b - M[2]) ** 2 <= tol2:
        xs.add(x)
if not xs:
    print("none"); sys.exit()
# The widest contiguous run of accent pixels IS the pill: 6 columns of " N:xx ".
xs = sorted(xs); runs = []; a = p = xs[0]
for x in xs[1:]:
    if x > p + 1:
        runs.append((a, p)); a = x
    p = x
runs.append((a, p))
a, b = max(runs, key=lambda r: r[1] - r[0])
colw = (b - a + 1) / 6.0
col = a / colw                                   # pill start, in columns
print(int(round((col - lead) / 7)) + 1 if col >= lead - 1 else "none")  # 7 = pill(6) + gap(1)
' "$lead"
