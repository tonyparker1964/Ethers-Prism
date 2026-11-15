# Brushes and colours: every brush kind, one stroke each, drawing itself.
# Run with ⌘↩ (still) or ⇧⌘↩ (video). Change a colour or size and run again.

canvas(1920, 1080, background="#f3ede1", seconds=5)

kinds = ["ink", "pen", "marker", "pencil", "charcoal", "chalk", "bristle",
         "oil", "dry", "wash", "watercolor", "airbrush", "dots", "squares"]
colours = ["#1b2a4a", "#2e6f8e", "#3fa37a", "#e8b53a", "#d9643a", "#9b3d6b"]

for i, kind in enumerate(kinds):
    col = gradient(colours, i / (len(kinds) - 1))
    b = brush(kind.title(), kind=kind, color=col, size=34 if kind in ("wash", "watercolor", "airbrush") else 18,
              jitter=1.5, spacing=6)
    x0, y = 160 + (i % 2) * 820, 110 + (i // 2) * 130
    # a gentle S-curve across the canvas
    pts = [(x0 + t * 700, y + math.sin(t * math.pi * 2) * 28) for t in np.linspace(0, 1, 40)]
    stroke(b, pts)

draw_on(order="together")
