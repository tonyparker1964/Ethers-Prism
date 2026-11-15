# Repaints the chosen picture with brush strokes: a broad wash, bristle strokes, dry-brush detail,
# then ink on top. Choose a picture from the Library in the toolbar first.

canvas(background="#f4efe4", seconds=6)      # takes the picture's shape

wash    = brush("Wash", kind="watercolor", size=70)
bristle = brush("Bristle", kind="bristle", size=26)
detail  = brush("Detail", kind="dry", size=10)
pen     = brush("Ink", kind="ink", color="#161616", size=3)

paint([wash, bristle, detail], length=10, detail=0.6)
ink(pen, threshold=0.32)

draw_on(seconds=5)      # washes first, then bristle, detail, ink
