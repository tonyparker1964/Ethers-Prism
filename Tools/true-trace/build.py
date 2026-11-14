
# ====================================================================== Blender
import bpy, sys, json, math

a = json.loads(sys.argv[sys.argv.index('--') + 1])
r = a['recipe']
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ------------------------------------------------------------ image -> trace
img = bpy.data.images.load(a['image'])
W0, H0 = img.size
px = np.empty(W0 * H0 * 4, dtype=np.float32)
img.pixels.foreach_get(px)
px = px.reshape(H0, W0, 4)[::-1]          # Blender rows run bottom-up
rgb = px[..., :3].clip(0, 1)
alpha = px[..., 3:4]
rgb = rgb * alpha + np.array(r.get('bg', [0.02, 0.02, 0.03])) * (1 - alpha)   # transparent → background
if img.colorspace_settings.name.lower().startswith('linear') or img.is_float:
    rgb = rgb ** (1 / 2.2)
work = int(r.get('work', 720))
s = work / max(W0, H0)
small = resize(rgb, max(8, int(W0 * s)), max(8, int(H0 * s)))
if r.get('grey'):
    small = np.repeat(small.mean(2, keepdims=True), 3, axis=2)
res = trace(small, r)
w, h = res['w'], res['h']
print(f"True Trace: {len(res['fills'])} shapes, {len(res['lines'])} ink lines from a {w}x{h} trace", file=sys.stderr)

unit = 2.0 / max(w, h)                   # long side of the picture = 2 Blender units


def attr(d, name, kind, domain):
    at = d.attributes.get(name)
    return at if at is not None else d.attributes.new(name, kind, domain)


def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


gp_blocks = getattr(bpy.data, 'grease_pencils_v3', None) or bpy.data.grease_pencils


def calibrate():
    """Render a tiny test card: does Grease Pencil fill shapes here, and how does it read colours?
    Returns {'fill': 'srgb' | 'linear' | 'none', 'ink': 'srgb' | 'linear'}."""
    import os, tempfile
    result = {'fill': 'srgb', 'ink': 'linear'}
    made = []
    try:
        tgp = gp_blocks.new('Calibrate'); tob = bpy.data.objects.new('Calibrate', tgp)
        scene.collection.objects.link(tob); made.append(tob)
        fm = bpy.data.materials.new('Cal fill'); bpy.data.materials.create_gpencil_data(fm)
        fm.grease_pencil.show_stroke = False; fm.grease_pencil.show_fill = True
        fm.grease_pencil.fill_color = (0.5, 0.5, 0.5, 1.0)
        im_ = bpy.data.materials.new('Cal ink'); bpy.data.materials.create_gpencil_data(im_)
        im_.grease_pencil.color = (1, 1, 1, 1)
        tgp.materials.append(fm); tgp.materials.append(im_)
        lay = tgp.layers.new('Cal')
        try: lay.use_lights = False
        except Exception: pass
        dd = lay.frames.new(1).drawing
        dd.add_strokes([4, 2])
        dd.attributes['position'].data.foreach_set('vector', [-0.9, 0, -0.9, -0.1, 0, -0.9, -0.1, 0, 0.9, -0.9, 0, 0.9,
                                                              0.5, 0, -0.9, 0.5, 0, 0.9])
        attr(dd, 'radius', 'FLOAT', 'POINT').data.foreach_set('value', [0.001] * 4 + [0.2, 0.2])
        attr(dd, 'material_index', 'INT', 'CURVE').data.foreach_set('value', [0, 1])
        attr(dd, 'cyclic', 'BOOLEAN', 'CURVE').data.foreach_set('value', [True, False])
        attr(dd, 'vertex_color', 'FLOAT_COLOR', 'POINT').data.foreach_set('color', [0, 0, 0, 0] * 4 + [0.5, 0.5, 0.5, 1] * 2)
        cd = bpy.data.cameras.new('Cal cam'); cd.type = 'ORTHO'; cd.ortho_scale = 2.0
        co = bpy.data.objects.new('Cal cam', cd); scene.collection.objects.link(co); made.append(co)
        co.location = (0, -10, 0); co.rotation_euler = (math.radians(90), 0, 0)
        scene.camera = co
        wd = bpy.data.worlds.new('Cal world'); scene.world = wd; wd.use_nodes = True
        wd.node_tree.nodes['Background'].inputs['Color'].default_value = (0, 0, 0, 1)
        set_engine()
        scene.render.resolution_x = scene.render.resolution_y = 32
        scene.render.resolution_percentage = 100
        im = scene.render.image_settings
        if hasattr(im, 'media_type'): im.media_type = 'IMAGE'
        im.file_format = 'PNG'; im.color_mode = 'RGB'
        path = os.path.join(tempfile.gettempdir(), f'prism-true-trace-cal-{os.getpid()}.png')
        scene.render.filepath = path
        bpy.ops.render.render(write_still=True)
        out = bpy.data.images.load(path)
        p = np.empty(32 * 32 * 4, dtype=np.float32); out.pixels.foreach_get(p)
        p = p.reshape(32, 32, 4)
        fill_v = float(p[16, 8, :3].mean()); ink_v = float(p[16, 24, :3].mean())
        bpy.data.images.remove(out)
        try: os.remove(path)
        except Exception: pass
        # 0.5 shown as 0.5 means display (sRGB) values; shown as ~0.74 means linear values
        result['fill'] = 'none' if fill_v < 0.08 else ('srgb' if abs(fill_v - 0.5) < abs(fill_v - 0.735) else 'linear')
        if ink_v >= 0.08:
            result['ink'] = 'srgb' if abs(ink_v - 0.5) < abs(ink_v - 0.735) else 'linear'
        print(f'Calibration: fill {fill_v:.3f} → {result["fill"]}, ink {ink_v:.3f} → {result["ink"]}', file=sys.stderr)
    except Exception as e:
        print('Calibration skipped:', e, file=sys.stderr)
    for o in made:
        bpy.data.objects.remove(o, do_unlink=True)
    if a.get('calibration'):            # a manual override, for testing
        result.update(a['calibration'])
    return result


def set_engine():
    for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
        try:
            scene.render.engine = engine; return
        except TypeError:
            pass


def world(x, y):
    return ((x - w / 2) * unit, (h / 2 - y) * unit)


def tint(col):
    t = r.get('tint')
    if t:
        col = tuple(c * k for c, k in zip(col, t))
    return col


cal = calibrate()


def fill_rgb(c):
    return [float(v) for v in (srgb_to_linear(c) if cal['fill'] == 'linear' else np.asarray(c))]


def ink_rgb_(c):
    return [float(v) for v in (srgb_to_linear(c) if cal['ink'] == 'linear' else np.asarray(c))]


# ------------------------------------------------------------ grease pencil
gp = gp_blocks.new('True Trace')
obj = bpy.data.objects.new('True Trace', gp)
scene.collection.objects.link(obj)

fill_layer = gp.layers.new('Colour')
ink_layer = gp.layers.new('Ink')
for lay in (fill_layer, ink_layer):
    try: lay.use_lights = False          # drawn colour, not lit colour
    except Exception: pass

# one fill material per palette colour (fills read their colour from the material)
palette = [tint(tuple(float(c) for c in col)) for col in res['palette']]
dim = r.get('fill_dim', 1.0)
for j, col in enumerate(palette):
    m = bpy.data.materials.new(f'Colour {j + 1:02d}')
    bpy.data.materials.create_gpencil_data(m)
    g = m.grease_pencil
    g.show_stroke = False
    g.show_fill = True
    g.fill_color = (*fill_rgb([col[0] * dim, col[1] * dim, col[2] * dim]), 1.0)
    gp.materials.append(m)
ink_mat = bpy.data.materials.new('Ink')
bpy.data.materials.create_gpencil_data(ink_mat)
ink_mat.grease_pencil.color = (1, 1, 1, 1)   # each point carries its own ink colour
gp.materials.append(ink_mat)
ink_index = len(palette)


# Colour: every traced shape, biggest first so details land on top. The colour appears in stages
# (big shapes, then details) as Grease Pencil keyframes, so no layer fade is needed.
fills = [f for f in res['fills'] if len(f['pts']) >= 3]
fps = 24
frames = int(fps * a.get('seconds', 6))
ink_end = int(frames * 0.5)
fill_start, fill_end = int(frames * 0.35), int(frames * 0.75)
stages = 8
cuts = [round(len(fills) * (i + 1) / stages) for i in range(stages)]
stage_frames = [fill_start + round((fill_end - fill_start) * i / (stages - 1)) for i in range(stages)]


def fill_drawing(d, subset):
    d.add_strokes([len(f['pts']) for f in subset])
    pos = []
    for f in subset:
        for x, y in f['pts']:
            X, Z = world(x, y)
            pos += [X, 0.0, Z]
    d.attributes['position'].data.foreach_set('vector', pos)
    attr(d, 'radius', 'FLOAT', 'POINT').data.foreach_set('value', [0.0005] * (len(pos) // 3))
    attr(d, 'material_index', 'INT', 'CURVE').data.foreach_set('value', [f['label'] for f in subset])
    attr(d, 'cyclic', 'BOOLEAN', 'CURVE').data.foreach_set('value', [True] * len(subset))


if cal['fill'] != 'none':
    fill_layer.frames.new(1)                       # empty until the colour starts
    for fr, cut in zip(stage_frames, cuts):
        if cut > 0:
            fill_drawing(fill_layer.frames.new(fr).drawing, fills[:cut])
else:
    # This Blender didn't fill Grease Pencil shapes in the test: draw the same shapes as flat, unlit
    # surfaces under the Grease Pencil ink, so the result is still in full colour.
    print('Colour shapes: flat surfaces under the Grease Pencil ink', file=sys.stderr)
    surf_mats = []
    for j, col in enumerate(palette):
        sm = bpy.data.materials.new(f'Surface {j + 1:02d}')
        sm.use_nodes = True
        nt_ = sm.node_tree
        for nd in list(nt_.nodes):
            if nd.type != 'OUTPUT_MATERIAL':
                nt_.nodes.remove(nd)
        em = nt_.nodes.new('ShaderNodeEmission')
        em.inputs['Color'].default_value = (*[float(v) for v in srgb_to_linear([col[0] * dim, col[1] * dim, col[2] * dim])], 1)
        nt_.links.new(em.outputs[0], nt_.nodes['Material Output'].inputs['Surface'])
        surf_mats.append(sm)
    start = 0
    for si, (fr, cut) in enumerate(zip(stage_frames, cuts)):
        chunk = fills[start:cut]
        base_index = start
        start = cut
        if not chunk:
            continue
        verts, faces, mats = [], [], []
        for k, f in enumerate(chunk):
            depth = -0.0004 - (base_index + k) * 2e-6     # later (smaller) shapes sit in front
            first = len(verts)
            for x, y in f['pts']:
                X, Z = world(x, y)
                verts.append((X, depth, Z))
            faces.append(list(range(first, len(verts))))
            mats.append(f['label'])
        me = bpy.data.meshes.new(f'Colour {si + 1}')
        me.from_pydata(verts, [], faces)
        for sm in surf_mats:
            me.materials.append(sm)
        me.polygons.foreach_set('material_index', mats)
        ob = bpy.data.objects.new(f'Colour {si + 1}', me)
        scene.collection.objects.link(ob)
        for value, at in ((True, 1), (False, fr)):
            ob.hide_render = ob.hide_viewport = value
            ob.keyframe_insert('hide_render', frame=at)
            ob.keyframe_insert('hide_viewport', frame=at)

# Ink: the look's line art, or a light pencil sketch that guides the drawing-on
final_ink = r.get('ink', 0) > 0
sketch_opacity = 0.0 if final_ink else 0.45
lines = [l for l in res['lines'] if len(l['pts']) >= 2]
ink_dark = r.get('ink_dark', 0.65)
ink_rgb = r.get('ink_rgb', [0.06, 0.05, 0.08])
ink_w = r.get('ink_w', 1.2) if final_ink else 0.6
if lines:
    d = ink_layer.frames.new(1).drawing
    d.add_strokes([len(l['pts']) + 1 for l in lines])   # +1 closes the outline
    pos, rad, opa, col = [], [], [], []
    for l in lines:
        base = tint(l['col'])
        if ink_dark >= 0:
            c = [base[i] * (1 - ink_dark) + ink_rgb[i] * ink_dark for i in range(3)]
        else:   # glowing lines: brighter than the colour they edge
            c = [min(1.0, base[i] * (1 - ink_dark) + 0.15) for i in range(3)]
        pts = l['pts'] + [l['pts'][0]]
        st = l['strength'] + [l['strength'][0]]
        for (x, y), k in zip(pts, st):
            X, Z = world(x, y)
            pos += [X, -0.001, Z]
            rad.append(ink_w * 0.5 * unit * (0.6 + 0.4 * k))
            opa.append(k if final_ink else sketch_opacity)
            c2 = ink_rgb_(c)
            col += [c2[0], c2[1], c2[2], 1.0]
    d.attributes['position'].data.foreach_set('vector', pos)
    attr(d, 'radius', 'FLOAT', 'POINT').data.foreach_set('value', rad)
    attr(d, 'opacity', 'FLOAT', 'POINT').data.foreach_set('value', opa)
    attr(d, 'vertex_color', 'FLOAT_COLOR', 'POINT').data.foreach_set('color', col)
    attr(d, 'material_index', 'INT', 'CURVE').data.foreach_set('value', [ink_index] * len(lines))

# ------------------------------------------------------------ drawing-on animation


build_ok = False
try:
    b = obj.modifiers.new('Draw On', 'GREASE_PENCIL_BUILD')
    setp(b, 'layer_filter', 'Ink')
    setp(b, 'mode', 'SEQUENTIAL')
    setp(b, 'transition', 'GROW')
    setp(b, 'time_mode', 'FRAMES')
    setp(b, 'length', ink_end)
    setp(b, 'start_delay', 0)
    build_ok = True
except Exception as e:
    print('Draw-on modifier skipped:', e, file=sys.stderr)


if not final_ink and lines:
    # the pencil sketch steps aside once the colour is in
    ink_layer.frames.new(min(frames, fill_end + fps))

# ------------------------------------------------------------ look effects
if r.get('glow'):
    try:
        fx = obj.shader_effects.new('Glow', 'FX_GLOW')
        setp(fx, 'mode', 'LUMINANCE'); setp(fx, 'threshold', 0.25)
        setp(fx, 'size', (12, 12)); setp(fx, 'opacity', r['glow']); setp(fx, 'samples', 8)
    except Exception as e:
        print('Glow skipped:', e, file=sys.stderr)
if r.get('pixel'):
    try:
        fx = obj.shader_effects.new('Pixels', 'FX_PIXEL')
        setp(fx, 'size', (int(r['pixel']), int(r['pixel'])))
    except Exception as e:
        print('Pixelate skipped:', e, file=sys.stderr)

# ------------------------------------------------------------ world + camera
world_ = bpy.data.worlds.new('Paper'); scene.world = world_
world_.use_nodes = True
bg = tint(tuple(r.get('bg', [0.02, 0.02, 0.03])))
world_.node_tree.nodes['Background'].inputs['Color'].default_value = (*[float(v) for v in srgb_to_linear(bg)], 1)

cam_data = bpy.data.cameras.new('Camera')
cam_data.type = 'ORTHO'
cam_data.ortho_scale = 2.0
cam = bpy.data.objects.new('Camera', cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -10, 0)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
if a.get('push', True):
    cam_data.ortho_scale = 2.06
    cam_data.keyframe_insert('ortho_scale', frame=1)
    cam_data.ortho_scale = 1.98
    cam_data.keyframe_insert('ortho_scale', frame=frames)

# ------------------------------------------------------------ render settings
scene.frame_start, scene.frame_end = 1, frames
scene.render.fps = fps
set_engine()
if hasattr(scene.eevee, 'taa_render_samples'):
    scene.eevee.taa_render_samples = 32
for vt in ('Standard', 'sRGB'):
    try:
        scene.view_settings.view_transform = vt; break
    except Exception: pass
try: scene.view_settings.look = 'None'
except Exception: pass
long_side = int(a.get('size', 1920))
rx, ry = (long_side, round(long_side * h / w)) if w >= h else (round(long_side * w / h), long_side)
scene.render.resolution_x, scene.render.resolution_y = rx - rx % 2, ry - ry % 2
scene.render.resolution_percentage = 100
print(f'Output size: {scene.render.resolution_x}×{scene.render.resolution_y}', file=sys.stderr)

# 1. editable project
scene.frame_set(frames)
bpy.context.view_layer.objects.active = obj
obj.select_set(True)
bpy.ops.wm.save_as_mainfile(filepath=a['project'])

# 2. the finished still
im = scene.render.image_settings
if hasattr(im, 'media_type'):
    im.media_type = 'IMAGE'
im.file_format = 'PNG'
im.color_mode = 'RGB'
scene.render.filepath = a['still']
bpy.ops.render.render(write_still=True)

# 3. the drawing-on video
if hasattr(im, 'media_type'):
    im.media_type = 'VIDEO'
im.file_format = 'FFMPEG'
ff = scene.render.ffmpeg
ff.format = 'MPEG4'
ff.codec = 'H264'
try:
    ff.constant_rate_factor = 'HIGH'
    ff.ffmpeg_preset = 'GOOD'
except Exception: pass
scene.render.filepath = a['movie']
bpy.ops.render.render(animation=True)
print('True Trace done', file=sys.stderr)
