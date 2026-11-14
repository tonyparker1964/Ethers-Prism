
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


def world(x, y):
    return ((x - w / 2) * unit, (h / 2 - y) * unit)


def tint(col):
    t = r.get('tint')
    if t:
        col = tuple(c * k for c, k in zip(col, t))
    return col


# ------------------------------------------------------------ grease pencil
gp_blocks = getattr(bpy.data, 'grease_pencils_v3', None) or bpy.data.grease_pencils
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
    g.fill_color = (col[0] * dim, col[1] * dim, col[2] * dim, 1.0)
    gp.materials.append(m)
ink_mat = bpy.data.materials.new('Ink')
bpy.data.materials.create_gpencil_data(ink_mat)
ink_mat.grease_pencil.color = (1, 1, 1, 1)   # each point carries its own ink colour
gp.materials.append(ink_mat)
ink_index = len(palette)


def attr(d, name, kind, domain):
    at = d.attributes.get(name)
    return at if at is not None else d.attributes.new(name, kind, domain)


# Colour: every traced shape, biggest first so details land on top
d = fill_layer.frames.new(1).drawing
fills = [f for f in res['fills'] if len(f['pts']) >= 3]
d.add_strokes([len(f['pts']) for f in fills])
pos = []
for f in fills:
    for x, y in f['pts']:
        X, Z = world(x, y)
        pos += [X, 0.0, Z]
d.attributes['position'].data.foreach_set('vector', pos)
n_pts = len(pos) // 3
attr(d, 'radius', 'FLOAT', 'POINT').data.foreach_set('value', [0.0005] * n_pts)
attr(d, 'material_index', 'INT', 'CURVE').data.foreach_set('value', [f['label'] for f in fills])
attr(d, 'cyclic', 'BOOLEAN', 'CURVE').data.foreach_set('value', [True] * len(fills))

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
            col += [c[0], c[1], c[2], 1.0]
    d.attributes['position'].data.foreach_set('vector', pos)
    attr(d, 'radius', 'FLOAT', 'POINT').data.foreach_set('value', rad)
    attr(d, 'opacity', 'FLOAT', 'POINT').data.foreach_set('value', opa)
    attr(d, 'vertex_color', 'FLOAT_COLOR', 'POINT').data.foreach_set('color', col)
    attr(d, 'material_index', 'INT', 'CURVE').data.foreach_set('value', [ink_index] * len(lines))

# ------------------------------------------------------------ drawing-on animation
fps = 24
frames = int(fps * a.get('seconds', 6))
ink_end = int(frames * 0.5)
fill_start, fill_end = int(frames * 0.35), int(frames * 0.75)


def setp(o, name, value):
    try:
        setattr(o, name, value); return True
    except Exception:
        return False


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


def key_opacity(layer, frame, value):
    layer.opacity = value
    gp.keyframe_insert(f'layers["{layer.name}"].opacity', frame=frame)


try:
    key_opacity(fill_layer, 1, 0.0)
    key_opacity(fill_layer, fill_start, 0.0)
    key_opacity(fill_layer, fill_end, 1.0)
    if not final_ink:                     # the pencil sketch fades once the colour is in
        key_opacity(ink_layer, fill_end, 1.0)
        key_opacity(ink_layer, min(frames, fill_end + fps), 0.0)
except Exception as e:
    print('Fade skipped:', e, file=sys.stderr)
    fill_layer.opacity = 1.0

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
world_.node_tree.nodes['Background'].inputs['Color'].default_value = (*bg, 1)

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
for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = engine; break
    except TypeError:
        pass
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
