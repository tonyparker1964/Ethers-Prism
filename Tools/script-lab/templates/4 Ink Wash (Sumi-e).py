# Sumi-e: the picture in grey ink washes with black brush lines, on rice paper.

canvas(background="#f1ece0", seconds=6)

pic = load_picture()
grey = pic @ np.array([0.3, 0.59, 0.11])          # the picture in greys
greys = np.stack([grey, grey, grey], axis=-1) * 0.85 + 0.12

wash  = brush("Sumi wash", kind="wash", size=90)
mid   = brush("Sumi mid", kind="wash", size=36, opacity=0.5)
brushpen = brush("Brush pen", kind="ink", color="#111111", size=5, taper=0.45, jitter=0.8)

# paint() takes a picture path; for an array, plan the strokes directly:
scale = S.width / greys.shape[1]
plan = plan_paint(greys, [90 / scale, 36 / scale], length=12, detail=0.4)
for i, b in enumerate([wash, mid]):
    layer(f"Wash {i + 1}")
    strokes([dict(brush=b, points=s["points"] * scale, size=s["size"] * scale, color=s["color"])
             for s in plan if s["layer"] == i])

ink(brushpen, threshold=0.3, detail=0.4)
boil(0.6)
draw_on(seconds=5)
