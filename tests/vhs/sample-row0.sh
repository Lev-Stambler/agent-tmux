#!/usr/bin/env bash
# Print what row 0 — the theme's window tabs, plus the buttons agent-tmux adds —
# looks like in a rendered frame:
#
#   b<N>c<M>   N = button pills found (3 spaced on a laptop, 1 merged block on a
#              phone), M = where the border around the CURRENT window's tab sits,
#              in sixteenths of the screen
#   b<N>c-     the buttons are there but the current tab has no border
#   nobtn      row 0 has no button group at all
#   none       nothing recognisable yet (a frame from before tmux drew)
#
# Everything here is measured from the frame, never assumed: the tab geometry
# belongs to the THEME, and the terminal's real column width is whatever VHS's
# font metrics make it (a tape asking for 136 columns renders about 110). The
# button pills are the only pure blue (#0000ff) in the frame, so their pixels
# give both the pill layout and the y band of row 0; the border is the only
# magenta hue, and is looked for only inside that band — which is what keeps
# row 1's accent pill out of the answer. The scenario sets both colours
# (see run.sh $ROW0_CONF).
#
#   Usage: sample-row0.sh <frame.png>
IM="$(command -v magick || command -v convert)"   # ImageMagick 7 or 6
img="$1"
{ [ -f "$img" ] && [ -n "$IM" ]; } || { echo none; exit 0; }
# The bottom 12% is both status rows (they are 2 of 24 lines). ImageMagick reads
# a geometry with any % as all-percent, so this is 12% of the height, not 12px --
# and cropping first is what keeps the pixel dump, and so the suite, fast.
"$IM" "$img" -gravity South -crop "100%x12%+0+0" +repage -depth 8 txt:- 2>/dev/null | python3 -c '
import sys
blue, mag, w = set(), [], 0
for line in sys.stdin:
    if line.startswith("#"):
        continue
    try:
        pos, rest = line.split(":", 1)
        x, y = (int(v) for v in pos.split(",")[:2])
        r, g, b = (int(v) for v in rest.split("(", 1)[1].split(")", 1)[0].split(",")[:3])
    except Exception:
        continue
    w = max(w, x + 1)
    if r < 60 and g < 60 and b > 190:                   # button pill background
        blue.add((x, y))
    # The border is a one-eighth block: a hairline of TEXT, so antialiasing and
    # the GIF palette leave it near 65% of full magenta and it never reaches the
    # pure colour. Match the HUE (r ~= b, little green) rather than the value --
    # catppuccin mauve, lavender and pink all carry far too much green to pass.
    elif r > 110 and b > 110 and g < 95 and abs(r - b) <= 70:
        mag.append((x, y))
if w == 0:
    print("none"); sys.exit()
if not blue:
    print("nobtn"); sys.exit()
# Row 0 is wherever the buttons are; row 1 is a different band, so the rail
# accent pill down there cannot be mistaken for the tab border.
y0, y1 = min(y for _, y in blue), max(y for _, y in blue)
# Pills, not pixels: a full-height glyph (the │ button) cuts its own pill in two,
# so runs closer than 4px are one pill. What is left is 3 pills with a column of
# band between them (wide) or a single merged block (narrow) -- which is exactly
# the difference the phone layout is supposed to make.
xs = sorted({x for x, _ in blue})
runs = 1
for a, b in zip(xs, xs[1:]):
    if b - a > 4:
        runs += 1
bx = [x for x, y in mag if y0 <= y <= y1]
if not bx:
    print("b%dc-" % runs); sys.exit()
print("b%dc%d" % (runs, int(sum(bx) / len(bx) / w * 16)))
'
