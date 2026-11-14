# Blender cheat sheet for Ethers Prism

A working reference for the Blender side of Ethers Prism: Grease Pencil, Line Art, rendering, the command line and the Python API. It is written for **Blender 5.2 LTS** (the version on Ether's Mac mini) and checked against the official manual and API docs. Prism's agents can read it offline, and you can add it to a Claude project as knowledge so Claude's Blender scripts follow it.

Full manual: https://docs.blender.org/manual/en/latest/ · Python API: https://docs.blender.org/api/current/

---

## 1. How Prism runs Blender

Prism never opens Blender's window. It starts Blender in the background, runs a script and collects the render:

```bash
blender -b --factory-startup --python runner.py -- '<json args>'
```

| Flag | What it does |
|---|---|
| `-b`, `--background` | Run without the UI. Audio is off in background mode unless you add `-setaudio Default`. |
| `--factory-startup` | Ignore your saved startup file and add-on preferences, so every run starts the same way. |
| `-P`, `--python <file>` | Run a Python script. |
| `--python-expr "<code>"` | Run one line of Python. |
| `--python-exit-code <n>` | Exit with this code if a script raises an error (useful for checking failures). |
| `--` | Everything after it goes to your script, not to Blender. Read it with `sys.argv[sys.argv.index('--') + 1:]`. |
| `-o`, `--render-output <path>` | Output path. `#` marks the frame number: `frame_####` → `frame_0001.png`. `//` means "next to the .blend file". |
| `-F`, `--render-format <fmt>` | `PNG`, `JPEG`, `TIFF`, `OPEN_EXR`, `OPEN_EXR_MULTILAYER`, `FFMPEG`, `WEBP` and others. |
| `-E`, `--engine <engine>` | Render engine. `blender -E help` lists them. |
| `-s` / `-e` | Start / end frame. |
| `-f <n>` | Render one frame (`-f -2` = second-to-last; `1,5,9` = a list). |
| `-a`, `--render-anim` | Render the whole frame range. |
| `-t <n>` | Threads (0 = all cores). |
| `-- --cycles-device METAL` | Cycles only: render on the Mac's GPU. Goes after `--`. |

**Order matters.** Blender runs arguments left to right, so the .blend file comes first, then settings, and `-f` or `-a` comes **last**:

```bash
blender -b scene.blend -o //render/frame_#### -F PNG -a        # right
blender -b scene.blend -a -o //render/frame_####               # wrong: renders before the path is set
```

Flags are case-sensitive: `-F` (format) is not `-f` (frame).

On the Mac the binary is `/Applications/Blender.app/Contents/MacOS/Blender` (Prism looks it up in `BlenderStageAdapter.blenderPath`).

---

## 2. Python essentials

| Module | Use |
|---|---|
| `bpy.data` | All data blocks: objects, meshes, materials, grease_pencils, cameras, lights, images, node_groups. **Prefer it in background scripts.** |
| `bpy.context` | The current scene, active object and selection. In background mode there is no window, so many context values are missing. |
| `bpy.ops` | Operators, the same as menu items and tools. Many need a 3D viewport context and **fail in background mode**. Avoid them unless you know they work headless. |
| `bpy.types` | Class definitions (what the API docs describe). |
| `mathutils` | `Vector`, `Matrix`, `Euler`, `Quaternion`, `Color`. |

Basic patterns:

```python
import bpy, math
from mathutils import Vector

scene = bpy.context.scene

# Clear the scene (data API, works headless)
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)

# Make an object from data and link it into the scene
cam_data = bpy.data.cameras.new("Camera")
cam = bpy.data.objects.new("Camera", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

# Keyframe any property
cam.location = (0, -10, 2)
cam.keyframe_insert(data_path="location", frame=1)
cam.location = (0, -6, 2)
cam.keyframe_insert(data_path="location", frame=96)

# Aim at something with a constraint
target = bpy.data.objects.new("Target", None)
scene.collection.objects.link(target)
track = cam.constraints.new('TRACK_TO')
track.target = target
track.track_axis = 'TRACK_NEGATIVE_Z'
track.up_axis = 'UP_Y'
```

Tips:
- Hover over any field in Blender with **Python Tooltips** on (Preferences → Interface) to see its Python path. Right-click → **Copy Data Path** copies it.
- Wrap risky calls in `try/except`, because property names sometimes change between versions.
- Use `getattr(obj, "name", default)` to check whether a property exists before using it.

---

## 3. Grease Pencil: the ideas

Grease Pencil is Blender's **2D drawing and animation** system, living inside 3D space. A Grease Pencil object holds strokes, not a mesh.

**Structure** (from the outside in):
- **Object** → its **Grease Pencil data** holds a **layer tree**: layers, optionally inside **layer groups**.
- **Layer** → has **frames** (keyframes). Each layer is one channel in the Dope Sheet (Grease Pencil mode).
- **Frame** → points to a **drawing**. Several frames can share one drawing (instanced).
- **Drawing** → holds **strokes** (curves).
- **Stroke** → a run of **points** joined by straight edit lines. Each stroke uses **one material**.
- **Point** → position, radius (thickness), opacity, vertex color, UV rotation, weights.

**Layers:** every stroke belongs to exactly one layer; new strokes go to the active layer. A layer has a blend mode, opacity, tint color and factor, a stroke-thickness override, its own transform, a parent object or bone (cut-out animation), masks (one layer can mask another), a pass index for modifiers, and **Lights** (whether scene lights affect it). Turn **Lights off** for clean, bright line art.

**Materials:** each stroke uses one Grease Pencil material, which has separate **Stroke** and **Fill** parts.
- Stroke: **Line**, **Dots** or **Squares**; style **Solid** or **Texture**; base color; **Holdout** (acts as a mask).
- Fill: only fills **closed** strokes; style **Solid**, **Gradient** (linear/radial) or **Texture**; base and secondary colors; holdout.
- Changing a material changes every stroke that uses it. Vertex color (Vertex Paint mode, or the Draw and Tint tool) can override the material color per point.

**Modes:** Object, Edit, Sculpt, **Draw**, Weight Paint, Vertex Paint.

**Add menu primitives** (Add → Grease Pencil): Blank, Stroke, Monkey, **Scene Line Art**, **Collection Line Art**, **Object Line Art**. The Line Art ones create an empty Grease Pencil object with a Line Art modifier already set up.

**Templates:** File → New → **2D Animation** opens a ready setup: a Grease Pencil object, camera view, onion skinning and Auto Keyframe on.

---

## 4. Grease Pencil: drawing and animating in the UI

| Action | How |
|---|---|
| Material slots | `U` (Draw mode) |
| Interpolate one in-between | `Ctrl-E` (Draw/Edit mode) or the Interpolate tool |
| Interpolate a sequence | `Shift-Ctrl-E`: a breakdown on every frame between two keys. Options: Step, Layer (Active/All), Only Selected, Exclude Breakdowns, Flip Mode, Smooth, Iterations |
| Insert keyframe | `I` over the Dope Sheet. Copies the active frame when Additive Drawing is on, or makes a blank one |
| Line tool | Drag from start to end. Wheel or `+`/`-` changes the point count; `F` thickness, `Shift-F` opacity; `Shift` snaps to 0/45/90°; `Alt` draws from the center |
| Fill tool | Click inside a closed shape. `Alt`+drag draws a temporary fill guide over gaps. In 5.3 you can drag across several regions to fill them at once. Solvers: **Delaunay** (geometry) or **Pixel** (flood fill) |
| Show all layers | `Alt-H` (Edit mode) |
| Separate | `P`: by Selection, Material or Layer |
| Merge layer down | `Shift-Ctrl-M` |
| Outline | Edit mode → Grease Pencil → Outline: turns strokes into filled outline shapes |
| Onion skinning | Overlays switch plus a per-layer toggle. Mode: Keyframes / Frames / Selected; Before/After counts; custom colors; Fade; Show Start Frame (for loops) |
| Retime | Dope Sheet → Grease Pencil mode. Breakdowns show as small light-blue keys |

Interpolation works best when the two keys have strokes with the **same number of points** (for example, a duplicated stroke that was moved).

---

## 5. Grease Pencil in Python (Blender 5.x API)

Blender 4.3 introduced the new Grease Pencil data model; 5.x uses it everywhere. Old `GPencilStroke` / `bpy.ops.gpencil.*` code is for annotations and older versions, so don't use it for Grease Pencil objects.

```python
import bpy

scene = bpy.context.scene

# The data collection: 'grease_pencils_v3' existed in 4.3-4.5; 5.x uses 'grease_pencils'.
gp_blocks = getattr(bpy.data, "grease_pencils_v3", None) or bpy.data.grease_pencils

gp = gp_blocks.new("Ink")
ob = bpy.data.objects.new("Ink", gp)
scene.collection.objects.link(ob)

# Material: a normal material turned into a Grease Pencil one
mat = bpy.data.materials.new("Ink Line")
bpy.data.materials.create_gpencil_data(mat)
mat.grease_pencil.color = (1.0, 1.0, 1.0, 1.0)      # stroke color
mat.grease_pencil.show_stroke = True
mat.grease_pencil.show_fill = False                 # set True + fill_color for fills
gp.materials.append(mat)

# Layer → frame → drawing
layer = gp.layers.new("Lines")
try:
    layer.use_lights = False      # bright, unlit lines (Prism always does this)
except Exception:
    pass
frame = layer.frames.new(1)       # keyframe on frame 1
drawing = frame.drawing

# One stroke with 4 points
drawing.add_strokes([4])
pts = [(-1, 0, 0), (0, 0, 1), (1, 0, 0), (2, 0, 1)]
flat = [c for p in pts for c in p]
drawing.attributes["position"].data.foreach_set("vector", flat)
drawing.attributes["radius"].data.foreach_set("value", [0.02] * 4)
drawing.attributes["opacity"].data.foreach_set("value", [1.0] * 4)
```

The fast path is **attributes** with `foreach_set`. Main attributes:

| Attribute | Domain | Holds |
|---|---|---|
| `position` | point | location (vector) |
| `radius` | point | thickness (world units, half the width) |
| `opacity` | point | 0–1 |
| `vertex_color` | point | RGBA color over the material |
| `material_index` | curve (stroke) | which material slot the stroke uses |
| `cyclic` | curve | closed stroke (needed for fills) |

If an attribute such as `vertex_color`, `material_index` or `cyclic` doesn't exist yet, create it first, for example `drawing.attributes.new("cyclic", 'BOOLEAN', 'CURVE')`.

Other useful calls:
- `drawing.add_strokes(sizes)`, `drawing.remove_strokes(indices)`, `drawing.resize_strokes(sizes, indices)`
- `drawing.strokes[i]`: an easy per-stroke API. It is slow, so use attributes for anything big. After the point count changes, fetch the stroke again.
- `layer.frames.new(n)`, `.copy(from, to, instance_drawing=False)`, `.move(from, to)`, `.remove(n)`
- `layer.get_frame_at(n)`, `layer.current_frame()`
- `layer.blend_mode` (`'REGULAR'`, `'HARDLIGHT'`, `'ADD'`, `'SUBTRACT'`, `'MULTIPLY'`, `'DIVIDE'`), `layer.opacity`, `layer.parent`, `layer.pass_index`
- `gp.stroke_depth_order`: `'2D'` (layer order) or `'3D'` (real depth)

**Held drawings (animating on 2s or 3s):** make a new frame only every 2nd or 3rd frame. Each drawing then stays on screen until the next key.

**Boil (hand-drawn wobble):** redraw the same lines on each key with small random offsets, or add a Noise modifier with Randomize → Steps.

---

## 6. Grease Pencil modifiers

Add with `ob.modifiers.new(name, type)`. They act on strokes non-destructively, and you can limit most of them to a layer, material or pass index (Influence panel).

| Group | Modifier | Type string | Good for |
|---|---|---|---|
| Generate | Array | `GREASE_PENCIL_ARRAY` | Repeats |
| | **Build** | `GREASE_PENCIL_BUILD` | Lines drawing themselves on: Grow / Shrink / Vanish; Sequential, Concurrent or Additive; timing by drawing speed, frame count or a factor |
| | Dot Dash | `GREASE_PENCIL_DASH` | Dashed lines |
| | Envelope | `GREASE_PENCIL_ENVELOPE` | Hatched or sketchy outer shell |
| | Length | `GREASE_PENCIL_LENGTH` | Extend or shorten strokes, overshoot |
| | **Line Art** | `GREASE_PENCIL_LINEART` | Lines from 3D geometry (section 7) |
| | Mirror | `GREASE_PENCIL_MIRROR` | Symmetry |
| | Multiple Strokes | `GREASE_PENCIL_MULTIPLY` | Doubled, sketchy lines |
| | Outline | `GREASE_PENCIL_OUTLINE` | Strokes into outlined shapes |
| | Simplify | `GREASE_PENCIL_SIMPLIFY` | Fewer points |
| | Subdivide | `GREASE_PENCIL_SUBDIV` | Smoother curves |
| Deform | Armature, Hook, Lattice | `GREASE_PENCIL_ARMATURE` / `_HOOK` / `_LATTICE` | Rigging and cut-out animation |
| | **Noise** | `GREASE_PENCIL_NOISE` | Wobble in position, opacity, thickness and UV; Randomize per step for boil |
| | Offset | `GREASE_PENCIL_OFFSET` | Move, rotate, scale per layer or stroke |
| | Shrinkwrap | `GREASE_PENCIL_SHRINKWRAP` | Stick lines to a surface |
| | Smooth | `GREASE_PENCIL_SMOOTH` | Clean up jitter |
| | **Thickness** | `GREASE_PENCIL_THICKNESS` | Line weight, tapering |
| Color | Hue/Saturation | `GREASE_PENCIL_COLOR` | Color shift |
| | Opacity | `GREASE_PENCIL_OPACITY` | Fade |
| | **Tint** | `GREASE_PENCIL_TINT` | Ink color, gradients |
| Edit | Texture Mapping | `GREASE_PENCIL_TEXTURE` | Stroke texture placement |
| | **Time Offset** | `GREASE_PENCIL_TIME` | Loops (Regular, Reverse, Ping Pong, Chain), fixed frame (mouth shapes), desynced copies |
| | Vertex Weight Angle / Proximity | `GREASE_PENCIL_WEIGHT_ANGLE` / `_PROXIMITY` | Weight-driven effects |

Example: a hand-drawn reveal with boil.

```python
build = ob.modifiers.new("Draw On", 'GREASE_PENCIL_BUILD')
noise = ob.modifiers.new("Boil", 'GREASE_PENCIL_NOISE')
noise.factor = 0.3                 # position strength
noise.use_random = True
noise.step = 2                     # new noise every 2 frames
```

---

## 7. Line Art (3D → drawn lines)

The Line Art modifier draws lines from 3D geometry as Grease Pencil strokes. **The scene needs an active camera**: lines are only made where the camera can see.

Main settings (Python name in brackets):
- **Source Type** (`source_type`): `'SCENE'`, `'COLLECTION'` (the default) or `'OBJECT'`, plus `source_collection` / `source_object`. Object sources can be Mesh, Text, Curve, Surface or Curves.
- **Layer / Material** (`target_layer`, `target_material`): where the strokes go. You must set both.
- **Line Radius** (`radius`, default 0.0025) and **Opacity** (`opacity`).
- **Fill Strokes** (`fill_strokes`): filled shapes instead of outlines.
- **Edge types:** Contour (`use_contour`) with Silhouette / Individual Silhouette (`silhouette_filtering`), Crease (`use_crease`, `crease_threshold`), Intersections (`use_intersection`), Material Borders (`use_material`), Edge Marks (`use_edge_mark`), Loose (`use_loose`), Light Contour (`use_light_contour`, `light_contour_object`), Cast Shadow (`use_shadow`).
- **Illumination filtering** (`shadow_region_filtering`): `'NONE'`, `'ILLUMINATED'`, `'SHADED'`, `'ILLUMINATED_ENCLOSED'`. Use it for lit/shadow line styles.
- **Occlusion:** Level (`level_start`/`level_end`, 0 = visible lines only); Range (`use_multiple_levels`) to also draw hidden lines.
- **Chaining:** Image Threshold (`chaining_image_threshold`), Smooth Tolerance (`smooth_tolerance`), Angle Splitting (`split_angle`), Preserve Details (`use_detail_preserve`), Geometry Space.
- **Composition:** Overscan (`overscan`, default 0.1) stops lines ending at the frame edge; Image Boundary Trimming; Depth Offset.
- **Custom Camera** (`use_custom_camera`, `source_camera`): bake several angles.
- **Use Cache** (`use_cache`): later Line Art modifiers reuse the first one's calculation, which is much faster with several styles.
- **Bake:** Bake Line Art / Bake All write the strokes into frames and switch the modifier off. Clear Baked removes them. **Clearing also deletes anything hand-drawn in that frame range.** Bake when you want to hand-edit the lines.

```python
lineart_gp = gp_blocks.new("Line Art")
la_ob = bpy.data.objects.new("Line Art", lineart_gp)
scene.collection.objects.link(la_ob)
lineart_gp.materials.append(mat)
la_layer = lineart_gp.layers.new("Lines")
la_layer.frames.new(scene.frame_start)

la = la_ob.modifiers.new("Line Art", 'GREASE_PENCIL_LINEART')
la.source_type = 'SCENE'
la.target_layer = "Lines"
la.target_material = mat
la.radius = 0.003
la.use_contour = True
la.use_crease = True
la.use_intersection = True
```

Tip: mark meshes with **Freestyle edge marks** (Edge mode → Mark Freestyle Edge) to force lines exactly where you want them.

---

## 8. Visual effects (Grease Pencil only)

Add with `ob.shader_effects.new(name, type)`. They are screen-space and render in EEVEE.

| Effect | Type | Notes |
|---|---|---|
| Blur | `FX_BLUR` | Soft or depth-of-field look |
| Colorize | `FX_COLORIZE` | Grayscale, sepia, duotone, transparent, custom |
| Flip | `FX_FLIP` | Mirror horizontally or vertically |
| **Glow** | `FX_GLOW` | Mode Luminance or Color, threshold, glow color, blend mode, opacity, size X/Y, rotation, samples, Glow Under |
| Pixelate | `FX_PIXEL` | Retro pixel look |
| **Rim** | `FX_RIM` | Fake rim light: rim color, mask color, offset, blur |
| **Shadow** | `FX_SHADOW` | Drop shadow: color, offset, scale, rotation, blur, optional wave |
| Swirl | `FX_SWIRL` | Twist distortion |
| Wave Distortion | `FX_WAVE` | Wavy lines |

For a glow across the **whole picture** (bloom), use the compositor instead (section 10).

---

## 9. Rendering

**Engines** (`scene.render.engine`):
- `'BLENDER_EEVEE'`: fast real-time engine, best for Grease Pencil, stylized and motion work. (4.2–4.5 called it `'BLENDER_EEVEE_NEXT'`. Prism tries that first and falls back to `'BLENDER_EEVEE'`.)
- `'CYCLES'`: path tracing, slower but physically accurate. On the Mac set the device to Metal: `bpy.context.preferences.addons['cycles'].preferences.compute_device_type = 'METAL'` and `scene.cycles.device = 'GPU'`.
- `'BLENDER_WORKBENCH'`: viewport-style flat or solid shading, very fast. Good for previews and clay renders.

**Basic settings:**

```python
rd = scene.render
rd.resolution_x, rd.resolution_y = 1920, 1080
rd.resolution_percentage = 100
rd.fps = 24
scene.frame_start, scene.frame_end = 1, 120
rd.film_transparent = True          # transparent background (PNG/EXR, ProRes 4444)
rd.filepath = "/tmp/prism/frame_####"
```

**Still image:**

```python
im = rd.image_settings
im.media_type = 'IMAGE'             # Blender 5.x; wrap in try for 4.x
im.file_format = 'PNG'
im.color_mode = 'RGBA'
```

**Video** (5.x has a separate **Media Type: Video**):

```python
im = rd.image_settings
try:
    im.media_type = 'VIDEO'
except Exception:
    pass
im.file_format = 'FFMPEG'
ff = rd.ffmpeg
ff.format = 'MPEG4'                 # MPEG4, MKV, WEBM, QUICKTIME, AVI, OGG …
ff.codec = 'H264'                   # H264, H265, AV1, WEBM (VP9), PRORES, FFV1, PNG, QTRLE …
ff.constant_rate_factor = 'HIGH'    # LOSSLESS, PERC_LOSSLESS, HIGH, MEDIUM, LOW, VERYLOW, LOWEST
ff.ffmpeg_preset = 'GOOD'           # BEST (smallest, slowest), GOOD, REALTIME (fastest)
ff.audio_codec = 'AAC'              # or 'NONE'
```

- CRF ranges: 0–51 for H.264, H.265 and AV1 (0 = lossless). Color depth: 10-bit for H.264/H.265/AV1, 12-bit for H.265/AV1.
- **ProRes** (`codec = 'PRORES'`, `ffmpeg.ffprores_profile`): 422 Proxy, LT, 422, HQ, **4444** (keeps alpha), 4444 XQ. Use 4444 in a QuickTime container for transparent video going into Ether Cut or Final Cut.
- For alpha you can also use `FFV1` in MKV, or `PNG` / `QTRLE` in QuickTime.
- The manual's advice: for long or important renders, **render a PNG or EXR image sequence first**. If a render crashes you keep the finished frames, then join them into a video in the Video Sequencer or with ffmpeg.

**Color management:** `scene.view_settings.view_transform` → `'AgX'` (default, filmic) or `'Standard'` (exact colors: use it for logos, flat graphics and Grease Pencil ink colors that must match).

---

## 10. Compositor (bloom, glare, grading)

Blender 5.x keeps the compositor in a node group assigned to the scene:

```python
tree = bpy.data.node_groups.new("Prism Comp", 'CompositorNodeTree')
scene.compositing_node_group = tree
# Add Render Layers → Glare → Group Output (or Composite) nodes, then link them
glare = tree.nodes.new('CompositorNodeGlare')
glare.inputs['Type'].default_value = 'Bloom'   # 5.x exposes glare settings as inputs
```

Useful nodes: Glare (Bloom, Fog Glow, Streaks, Ghosts), Blur, Bokeh Blur, Defocus, Color Balance, Hue/Saturation, Curves, Alpha Over, Mix, Denoise, Lens Distortion.

---

## 11. Cameras, lights and moves

- **Camera:** `cam_data.lens` (mm), `cam_data.type` (`'PERSP'`, `'ORTHO'` for flat 2D, `'PANO'`), `cam_data.ortho_scale`, depth of field via `cam_data.dof.use_dof`, `focus_object`, `aperture_fstop`.
- **2D work:** an orthographic camera looking down −Y (front view) keeps Grease Pencil flat and undistorted.
- **Lights:** `bpy.data.lights.new(name, 'POINT' | 'SUN' | 'SPOT' | 'AREA')`, `.energy` (W), `.color`. Three-point setup: key, fill, rim.
- **Eased moves:** keyframes default to Bézier easing. For linear motion, set each keyframe point's `interpolation = 'LINEAR'` on the object's action F-curves.
- **Camera push:** keyframe `location` or `lens` from start to end; add a slight Noise F-curve modifier for a handheld feel.

---

## 12. Recipes for the Prism and Image Studio plan

**A. Logo draws itself on (Line Logo field, already in Prism)**
Trace the image into strokes → Build modifier (Grow, Sequential) → Noise with Randomize Steps for boil → frames held on 2s or 3s → layer `use_lights = False` → compositor Bloom for glow → H.264 MP4.

**B. Sketch to image**
1. Draw a rough layout in Grease Pencil (or bake Line Art from a 3D blockout).
2. Render one frame: Workbench or EEVEE, `film_transparent = True`, white lines on black, `view_transform = 'Standard'`.
3. Send the PNG to ComfyUI as a lineart/scribble ControlNet guide, with the Image Studio look as the prompt.

**C. Studio look → line style**
Map each look to Grease Pencil settings: line radius (Thickness modifier), wobble (Noise), ink color (material or Tint), fill on/off, Multiple Strokes for sketchy looks, Glow/Rim/Shadow effects, and held timing for anime looks. Store these per look in the shared style library.

**D. Motion prompt → animatic**
One layer per storyboard panel, or one key per beat. Time Offset to loop cycles, Interpolate Sequence for simple in-betweens, a camera push per shot, then render the MP4 for Ether Cut.

**E. Character turnaround**
Line Art from a 3D model (Mixar or Blender) with a **Custom Camera** for each angle (front, ¾, side, back) → bake → hand-clean → render each angle as a PNG. These become reference sheets in Image Studio.

**F. 3D scene with toon lines**
Meshes + Scene Line Art (Contour + Crease + Intersections, Use Cache on extra Line Art modifiers) + EEVEE + Standard view transform + a flat shader on the meshes (Diffuse → Shader to RGB → Color Ramp, constant) for cel shading.

---

## 13. Troubleshooting

| Problem | Likely cause / fix |
|---|---|
| Lines render dim or grey | Layer **Lights** on → `layer.use_lights = False`; or the AgX view transform → use `'Standard'` |
| Line Art shows nothing | No active camera (`scene.camera`), or target layer/material not set, or the source collection is empty |
| Lines cut off at frame edges | Raise Line Art **Overscan** |
| Line Art very slow | Turn on **Use Cache** for the 2nd and later modifiers; Force Backface Culling; bake |
| `bpy.ops…` fails in background | The operator needs a UI context. Use the data API instead |
| Interpolation looks wrong | Keys need strokes with the same number of points |
| Fill doesn't appear | The stroke isn't closed (`cyclic`), or the material has Fill off |
| Render goes to the wrong path | `-o` was given after `-f`/`-a`; put `-f`/`-a` last |
| Video won't play or won't encode | Container and codec don't match (WebM needs VP9/AV1; ProRes needs QuickTime); use even resolutions |
| Out of memory on the 24 GB Mac | Don't run Blender and ComfyUI at full load together; lower samples or resolution for previews |

---

## 14. Manual pages to go deeper

- Grease Pencil: https://docs.blender.org/manual/en/latest/grease_pencil/index.html
- Structure: https://docs.blender.org/manual/en/latest/grease_pencil/structure.html
- Layers: https://docs.blender.org/manual/en/latest/grease_pencil/properties/layers.html
- Materials: https://docs.blender.org/manual/en/latest/grease_pencil/materials/properties.html
- Modifiers: https://docs.blender.org/manual/en/latest/grease_pencil/modifiers/index.html
- Line Art: https://docs.blender.org/manual/en/latest/grease_pencil/modifiers/generate/line_art.html
- Build: https://docs.blender.org/manual/en/latest/grease_pencil/modifiers/generate/build.html
- Noise: https://docs.blender.org/manual/en/latest/grease_pencil/modifiers/deform/noise.html
- Time Offset: https://docs.blender.org/manual/en/latest/grease_pencil/modifiers/edit/time_offset.html
- Visual effects (Glow): https://docs.blender.org/manual/en/latest/grease_pencil/visual_effects/glow.html
- Interpolation: https://docs.blender.org/manual/en/latest/grease_pencil/animation/interpolation.html
- Onion skinning: https://docs.blender.org/manual/en/latest/grease_pencil/properties/onion_skinning.html
- Command line arguments: https://docs.blender.org/manual/en/latest/advanced/command_line/arguments.html
- Rendering from the command line: https://docs.blender.org/manual/en/latest/advanced/command_line/render.html
- Output and encoding: https://docs.blender.org/manual/en/latest/render/output/properties/output.html
- Video formats: https://docs.blender.org/manual/en/latest/files/media/video_formats.html
- Python API (Grease Pencil drawing): https://docs.blender.org/api/current/bpy.types.GreasePencilDrawing.html
- Python API (Line Art modifier): https://docs.blender.org/api/current/bpy.types.GreasePencilLineartModifier.html
- Python API (FFmpeg settings): https://docs.blender.org/api/current/bpy.types.FFmpegSettings.html
