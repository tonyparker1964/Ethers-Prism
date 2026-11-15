# Pointillism: the picture rebuilt from coloured dots.

canvas(background="#fbf8f2", seconds=5)

big   = brush("Dots big", kind="dots", size=22, spacing=10)
small = brush("Dots small", kind="dots", size=9, spacing=6)

paint([big, small], length=2, density=1.3, detail=0.7)
draw_on(seconds=4)
