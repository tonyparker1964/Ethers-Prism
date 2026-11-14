# True Trace tools

The True Trace engine, outside Blender, for tuning looks.

- `core.py`: the trace itself (numpy only): colour quantising, cel shading, shapes, ink lines.
- `build.py`: the Blender half: turns the trace into Grease Pencil strokes, animates them drawing on, renders a still and an MP4 and saves a .blend.
- `render.py`: draws a trace with Pillow so you can judge a look without Blender:
  `python3 render.py photo.png out.png "{'colors': 16, 'cel_levels': 5, 'ink': 1}"`

After changing `core.py` or `build.py`, run `python3 scripts/sync-true-trace.py` to rebuild the script inside the app.
The recipes for each look live in `Sources/EthersPrismCore/Adapters/TrueTrace.swift`.
