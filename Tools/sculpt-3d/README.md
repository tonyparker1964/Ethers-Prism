# Sculpt 3D tools

The 3D-look engine behind True Trace's 3D tab, outside Blender, for tuning.

- `core.py` (numpy only): finds the subject (transparency, or everything unlike the border colour; full-frame pictures become a relief), then inflates it into a rounded height field with the picture's light as surface detail.
- `build.py`: the Blender half: a closed model (front, back and side wall) with the picture painted on, the look's material, studio lights, a turntable; renders a still and an MP4, saves a .blend and a .glb.
- `preview.py`: a quick shaded preview of the shape: `python3 preview.py picture.png out.png`

After editing, run `python3 scripts/sync-true-trace.py` (it builds both engines into the app).
Recipes for each 3D look live in `Sources/EthersPrismCore/Adapters/Sculpt3D.swift`.
