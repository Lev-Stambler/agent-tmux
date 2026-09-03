#!/usr/bin/env bash
# Print which session pill (1|2|3|...) is the ACCENT (mauve) one on the bottom
# status row of a rendered frame — the sessions band drawn by bin/tmux-sessions.
# Position-based: mean x of mauve-background pixels -> terminal column -> pill
# index, assuming the test layout "<lead>1:aa  2:ab  3:zz " (6-char pills, 1-char
# gaps). $PILL_LEAD is how many columns precede pill 1: 1 for the bare row, 5 with
# the default " + " picker button in front of it. Tolerance is tight (25) so
# catppuccin lavender on the tabs row can never match. Prints none if no mauve.
#
#   Usage: [PILL_LEAD=n] sample-session-pill.sh <frame.png> [cols]
img="$1"; cols="${2:-136}"; lead="${PILL_LEAD:-1}"
[ -f "$img" ] || { echo none; exit 0; }
magick "$img" -gravity South -crop "100%x14+0+0" +repage -depth 8 txt:- 2>/dev/null | python3 -c '
import sys
cols = int(sys.argv[1]); lead = int(sys.argv[2]); M = (203, 166, 247); tol2 = 25 * 25
xs, w = [], 0
for line in sys.stdin:
    if line.startswith("#"):
        continue
    try:
        pos, rest = line.split(":", 1)
        x = int(pos.split(",")[0])
        r, g, b = (int(v) for v in rest.split("(", 1)[1].split(")", 1)[0].split(",")[:3])
    except Exception:
        continue
    w = max(w, x + 1)
    if (r - M[0]) ** 2 + (g - M[1]) ** 2 + (b - M[2]) ** 2 <= tol2:
        xs.append(x)
if not xs or w == 0:
    print("none"); sys.exit()
col = (sum(xs) / len(xs)) / (w / cols)          # mean x -> 0-based column
print(int((col - lead) // 7) + 1 if col >= lead else "none")  # 7 = pill(6) + gap(1)
' "$cols" "$lead"
