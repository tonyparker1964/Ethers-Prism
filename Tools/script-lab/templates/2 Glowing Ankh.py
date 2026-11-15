# A glowing golden Ankh that draws itself, then glows.

canvas(1080, 1920, background="#0b0d14", seconds=4)

gold = brush("Gold", kind="ink", color="#f2c14e", size=22, taper=0.15)
glow_line = brush("Gold glow", kind="airbrush", color="#ffb347", size=70, opacity=0.18)

cx, top = 540, 520
layer("Glow")
ellipse(glow_line, (cx, top + 210), 150, 210)
line(glow_line, (cx - 260, top + 470), (cx + 260, top + 470))
line(glow_line, (cx, top + 470), (cx, top + 1050))

layer("Ink")
# the loop as an open stroke that ends where it began (no straight closing line while drawing)
t = np.linspace(-math.pi / 2, 3 * math.pi / 2, 90)
stroke(gold, np.c_[cx + 150 * np.cos(t), top + 210 + 210 * np.sin(t)])
line(gold, (cx - 260, top + 470), (cx + 260, top + 470))
line(gold, (cx, top + 470), (cx, top + 1050))

glow(color="#ffcc66", radius=60)
draw_on(seconds=3)
