# Grease Pencil tools → PRISM automation

Every Grease Pencil tool in Blender 5.2 / 5.3, whether PRISM can drive it from a script (Blender runs
headless, with no window), and how PRISM would use it. Sources: the Blender 5.3 manual and Python API
(`bpy.ops.grease_pencil`), and the Scenario `scenario-blender-grease-pencil` skill's tested notes
(verified on Blender 5.2.1).

## The one rule that shapes everything

**Brushes can't be "played" from a script.** `grease_pencil.brush_stroke` and `sculpt_paint` have no
script entry point: called from Python they log "Invalid operator call" and draw nothing. So PRISM
never presses a brush. It writes strokes **as data** (points with position, radius, opacity, colour),
and reproduces each brush's character itself. That is how every tool below becomes automation.

In the data model a stroke is a curve with attributes:

| Attribute | What it controls | Brush feel it gives |
|---|---|---|
| `position` | the path | gesture, wobble |
| `radius` (per point) | thickness along the stroke | taper, pressure |
| `opacity` (per point) | see-through | pencil grain, washes |
| `vertex_color` (per point) | colour on top of the material | painting colour from a picture |
| `material_index` | which "paint bucket" | texture, dots, gradient |
| `cyclic` | closed loop | shapes |
| `fill_id` (curve) | **fills are geometry**: strokes with the same id fill together (holes by even-odd) | flat colour areas |
| `hide_stroke`, softness, start/end caps | outline on/off, soft edges, round or flat ends | marker vs ink |

## 1. Draw mode tools

| Tool | What it does | Script? | PRISM automation |
|---|---|---|---|
| **Draw** (brushes: Pencil, Ink Pen, Ink Pen Rough, Marker, Pen, Airbrush …) | Freehand strokes. The brushes are setting variations of one Draw brush | Data only | **Brush library**: each brush = material + pressure profile. Pencil puts pressure on radius *and* opacity, Ink Pen on radius only, Marker/Pen constant width, Airbrush soft and low opacity |
| **Fill** | Fills areas closed by strokes | Data (`fill_id` + `cyclic`) | Colour areas in True Trace, Brush Paint washes |
| **Erase** (soft, hard, point, stroke) | Removes strokes or parts | Data (cut by a mask in Python); box/lasso erase work only with a live window | "Erase where" masks, e.g. keep only the subject |
| **Tint** | Paints colour on strokes | Data (`vertex_color`) | Recolour lines from the picture |
| **Trim / Carver** | Cuts stroke ends at crossings / with a lasso | `stroke_trim`, `stroke_carver` need a window → do the maths in Python | Clean overshoots (overlap-then-trim, as 2D artists do) |
| **Eyedropper** | Picks a colour | Data (sample the image) | Palette from the picture |
| **Line, Polyline, Arc, Curve, Box, Circle** | Shapes | Generate the points | Frames, panels (like the ink borders in your Wuxia picture), speed lines |
| **Interpolate / Interpolate Sequence** | In-betweens between two keys, with easing (Linear, Sine, Quad … Back, Bounce, Elastic) | **Yes**: `interpolate_sequence` runs headless (only between keys with matching strokes) | Smooth motion between True Trace keys; boil-free holds |
| **Trace Image** | Traces a black-and-white image (or sequence) into strokes (Radius, Color Threshold, Turn Policy, Single/Sequence) | Operator `grease_pencil.trace_image` (to test headless) | Second tracer for clean logo / line-art inputs |

## 2. Materials ("paint buckets")

All settable from a script.

- **Stroke**: Line type **Line, Dots, Squares**; Style **Solid** or **Texture** (any image: bristle, chalk, dry brush); Alignment Path / Object / Fixed; Rotation; Self Overlap; **Randomize** size, strength, rotation, hue, saturation, value, noise scale.
- **Fill**: **Solid, Gradient (linear or radial), Texture**; offset, rotation, scale, clip.
- **Holdout** (cut-outs), **Pass Index** (target modifiers and compositing).

→ PRISM's **Brush picker** is a set of these materials with texture images shipped in the app: Ink Brush, Sumi Wash, Watercolor, Oil/Bristle, Dry Brush, Pencil, Charcoal, Marker, Dots (stipple), Squares (pixel).

## 3. Sculpt mode brushes

Smooth, Thickness, Strength, Randomize, Grab, Push, Twist, Pinch/Inflate, Clone. Brushes have no script entry point, so PRISM does the same thing to the attributes: smooth positions, scale `radius`, scale `opacity`, add noise, move points inside a radius. Headless edit operators also exist: `stroke_smooth`, `stroke_simplify`, `stroke_subdivide`, `stroke_subdivide_smooth`, `set_uniform_thickness`, `set_uniform_opacity`.

→ PRISM sliders: **Smooth, Weight, Ink Strength, Jitter, Simplify**, applied after tracing or painting.

## 4. Vertex paint and weight paint

- Vertex paint brushes: Draw, Blur, Average, Smear, Replace → maths on `vertex_color`. Headless colour operators: `vertex_color_hsv`, `vertex_color_brightness_contrast`, `vertex_color_levels`, `vertex_color_invert`, `vertex_color_set`.
- Weight paint (vertex groups) drives modifiers on parts of a drawing.

→ **Colour the strokes from the picture**, then grade them (hue, levels) like Color Studio, inside Blender.

## 5. Edit operators that run headless

`stroke_smooth`, `stroke_simplify`, `stroke_subdivide(_smooth)`, `outline` (stroke → filled shape), `join_fills` (make holes), `separate_fills`, `set_uniform_thickness`, `set_uniform_opacity`, `caps_set` (round/flat ends), `set_start_point`, `stroke_switch_direction` (reverse draw-on direction), `reorder`, `stroke_merge_by_distance`, `cyclical_set`, `set_stroke_type` (stroke / fill / both), `bake_grease_pencil_animation`, layer and mask operators (`layer_add`, `layer_mask_add`, `layer_group_add`, `layer_merge`), frame operators (`insert_blank_frame`, `frame_duplicate`, `frame_clean_duplicate`). They run in Edit mode on selected strokes (the skill's `edit_op` helper does the mode switching).

## 6. Modifiers (all scriptable, non-destructive)

| Group | Modifiers | PRISM use |
|---|---|---|
| Generate | **Build**, Array, Dot Dash, **Envelope**, Length, **Line Art**, Mirror, **Multiple Strokes**, **Outline**, **Simplify**, **Subdivide** | Draw-on animation; sketchy double lines; dashed / dotted ink; overshoot; hatched shells |
| Deform | Armature, Hook, Lattice, **Noise**, Offset, Shrinkwrap, **Smooth**, **Thickness** | Line boil, wobble, weight, cut-out motion |
| Color | Hue/Saturation, **Opacity**, **Tint** | Fade-ins, gradients, colour grading of lines |
| Edit | Texture Mapping, **Time Offset**, Vertex Weight Angle / Proximity | Staggered animation, loops, calligraphic weight by angle |

Blender 5.x Build timing: `time_mode`, `start_delay`, `length` (see the cheat sheet).

## 7. Visual effects (all scriptable)

Blur, Colorize, Flip, **Glow**, Pixelate, **Rim**, **Shadow**, Swirl, Wave Distortion → an **Effects** panel in PRISM with an on/off and sliders for each.

## 8. Layers, animation, 3D

- **Layers**: blend modes (Regular, Multiply, Add …), opacity, **masks** (`layer.mask_layers.add`), groups, onion skin, `use_lights=False` for true colours (lit layers render dark), per-layer transform and parenting. Studio stack: **Lines** on top, **Shadow** (Multiply, masked by the fills), **Fills**, then a **painting plate**.
- **Animation**: keys (`frames.new`), frame instancing (holds and cycles without copies), interpolation (above), Build, Time Offset, Noise boil, object transforms for cut-out moves.
- **Line Art**: drawn outlines from 3D models (scene, collection or object) → for PRISM's **3D from Image** and **3D Stage** models.
- **Geometry Nodes for Grease Pencil** (Blender 4.3+): Curves to Grease Pencil, Set Grease Pencil Color / Depth / Softness, Fill ID, Merge Layers … → procedural strokes (thousands of brush marks) that bake back to editable drawings. Note for 5.1+: store an INT `fill_id` on curves to get fills.

## What stays manual

Live drawing with a tablet (pressure, stabiliser), the interactive Trim / Erase / Reproject tools, and Draw / Sculpt / Vertex / Weight brushes as you use them by hand. PRISM's **Open in Blender for Drawing** hands the `.blend` over for that, with every PRISM stroke still editable.

## Plan for PRISM

1. **Brush library + Brush Paint**: brushes as materials (textures shipped with PRISM) and pressure profiles; a stroke painter that lays thousands of strokes coarse → fine, following the picture's direction, coloured from the picture, with ink on top. Controls: brush, size, length, direction, density, layers, jitter, colour variation.
2. **Ink Reveal**: ink lines draw on (Build), then the original painting washes in under them through a growing mask.
3. **Stroke finishing tools**: Smooth, Simplify, Weight, Taper, Caps, Reverse direction, Trim overshoots, as sliders after any trace or paint.
4. **Effects and modifiers panel**: Glow, Rim, Shadow, Blur, Pixelate, Wave, Swirl; Noise boil, Multiple Strokes, Envelope, Dot Dash, Time Offset.
5. **Studio layer stack**: Lines / masked Multiply Shadow / Fills / painting plate, unlit for exact colours.
6. **Motion**: Interpolate Sequence between keys with easing; frame instancing for holds and loops.
7. **3D → ink**: Line Art on 3D from Image and 3D Stage models.
8. **Procedural** (later): Geometry Nodes stroke generators, baked to editable strokes.
