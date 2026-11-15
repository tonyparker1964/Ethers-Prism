
# ====================================================================== Blender
import bpy, sys, json, math

a = json.loads(sys.argv[sys.argv.index('--') + 1])
r = a['recipe']
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def setp(o, name, value):
    try:
        setattr(o, name, value); return True
    except Exception:
        return False


def inp(node, names, value):
    for n in names if isinstance(names, (list, tuple)) else [names]:
        s = node.inputs.get(n)
        if s is not None:
            try:
                s.default_value = value; return True
            except Exception:
                pass
    return False


# ------------------------------------------------------------ picture -> heights
src = bpy.data.images.load(a['image'])
W0, H0 = src.size
px = np.empty(W0 * H0 * 4, dtype=np.float32)
src.pixels.foreach_get(px)
px = px.reshape(H0, W0, 4)[::-1]
rgb_full = px[..., :3].clip(0, 1)
alpha_full = px[..., 3]
grid = int(r.get('grid', 300))
s = grid / max(W0, H0)
gw, gh = max(16, int(W0 * s)), max(16, int(H0 * s))
rgb = resize(rgb_full, gw, gh)
alpha = resize(alpha_full[..., None], gw, gh)[..., 0]
mask, cut = subject_mask(rgb, alpha)
h, R = height_field(rgb, mask, inflate=1.0 if cut else r.get('slab_inflate', 0.2),
                    detail=r.get('detail', 0.25) if cut else r.get('slab_detail', 0.9))
unit = 2.0 / max(gw, gh)
depth = r.get('depth', 0.35) * R * unit if cut else r.get('slab_depth', 0.25)
H = h * depth
print(f'Sculpt 3D: {"cut-out subject" if cut else "full-frame relief"}, {int(mask.sum())} grid points, depth {depth:.3f}', file=sys.stderr)

# ------------------------------------------------------------ the texture painted on the model
tex_rgb = resize(rgb_full, min(W0, 1400), max(1, int(H0 * min(W0, 1400) / W0)))
if r.get('tex_blur'):
    tex_rgb = box_blur(tex_rgb, int(r['tex_blur']))
if r.get('posterize'):
    n = float(r['posterize'])
    tex_rgb = np.round(tex_rgb * n) / n
if r.get('saturation', 1) != 1:
    g = tex_rgb.mean(2, keepdims=True)
    tex_rgb = (g + (tex_rgb - g) * r['saturation']).clip(0, 1)
th, tw = tex_rgb.shape[:2]
tex = bpy.data.images.new('Sculpt Colours', tw, th, alpha=False)
tex.pixels.foreach_set(np.concatenate([tex_rgb[::-1], np.ones((th, tw, 1), np.float32)], 2).ravel().astype(np.float32))
tex.pack()

# ------------------------------------------------------------ mesh: front, back and side wall
idx = -np.ones((gh, gw), dtype=np.int64)
ys, xs = np.nonzero(mask)
n = len(ys)
idx[ys, xs] = np.arange(n)
X = (xs - gw / 2) * unit
Z = (gh / 2 - ys) * unit
front = np.stack([X, -H[ys, xs], Z], 1)
back_y = H[ys, xs] * r.get('back', 0.85) if cut else np.full(n, depth * 0.35)
back = np.stack([X, back_y, Z], 1)
verts = np.concatenate([front, back])

q = (mask[:-1, :-1] & mask[:-1, 1:] & mask[1:, 1:] & mask[1:, :-1])
qy, qx = np.nonzero(q)
a_ = idx[qy, qx]; b_ = idx[qy, qx + 1]; c_ = idx[qy + 1, qx + 1]; d_ = idx[qy + 1, qx]
front_f = np.stack([a_, d_, c_, b_], 1)          # faces toward the camera (−Y)
back_f = np.stack([a_, b_, c_, d_], 1) + n
faces = [front_f, back_f]
# side wall: every front edge used by just one quad is on the rim
edges = {}
for f in front_f:
    for i in range(4):
        e = (int(f[i]), int(f[(i + 1) % 4]))
        k = (min(e), max(e))
        edges[k] = None if k in edges else e
side = [(e[1], e[0], e[0] + n, e[1] + n) for e in edges.values() if e is not None]
if side:
    faces.append(np.array(side, dtype=np.int64))
faces = np.concatenate(faces)

mesh = bpy.data.meshes.new('Sculpt')
mesh.from_pydata(verts.tolist(), [], faces.tolist())
mesh.validate()
uv = mesh.uv_layers.new(name='Picture')
loop_v = np.empty(len(mesh.loops), dtype=np.int64)
mesh.loops.foreach_get('vertex_index', loop_v)
vx = verts[loop_v % len(verts)]
u = vx[:, 0] / (gw * unit) + 0.5
v = vx[:, 2] / (gh * unit) + 0.5
uv.data.foreach_set('uv', np.stack([u, v], 1).ravel().astype(np.float32))
smooth = not r.get('flat_shading')
mesh.polygons.foreach_set('use_smooth', [smooth] * len(mesh.polygons))
obj = bpy.data.objects.new('Sculpt', mesh)
scene.collection.objects.link(obj)

if r.get('decimate'):
    dm = obj.modifiers.new('Facets', 'DECIMATE')
    setp(dm, 'ratio', float(r['decimate']))
if smooth and r.get('subdivide', 0):
    sd = obj.modifiers.new('Smooth', 'SUBSURF')
    setp(sd, 'levels', int(r['subdivide'])); setp(sd, 'render_levels', int(r['subdivide']))

# ------------------------------------------------------------ material for the look
mat = bpy.data.materials.new(r.get('name', 'Look'))
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes.get('Principled BSDF')
img_node = nt.nodes.new('ShaderNodeTexImage')
img_node.image = tex
img_node.interpolation = 'Cubic'
colour = img_node.outputs['Color']
mono = r.get('mono')
if mono:
    mix = nt.nodes.new('ShaderNodeMixRGB')
    mix.inputs[0].default_value = r.get('picture_mix', 0.15)
    mix.inputs[1].default_value = (*mono, 1)
    nt.links.new(colour, mix.inputs[2])
    colour = mix.outputs['Color']
pattern = r.get('pattern')
if pattern in ('marble', 'wood'):
    wave = nt.nodes.new('ShaderNodeTexWave')
    inp(wave, 'Scale', 3.0 if pattern == 'marble' else 9.0)
    inp(wave, 'Distortion', 12.0 if pattern == 'marble' else 4.0)
    inp(wave, 'Detail', 6.0)
    if pattern == 'wood':
        setp(wave, 'wave_type', 'RINGS')
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    dark = r.get('vein', [0.35, 0.33, 0.32])
    ramp.color_ramp.elements[0].color = (*dark, 1)
    ramp.color_ramp.elements[0].position = 0.45 if pattern == 'marble' else 0.3
    ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
    nt.links.new(wave.outputs['Fac'], ramp.inputs['Fac'])
    vein = nt.nodes.new('ShaderNodeMixRGB')
    vein.blend_type = 'MULTIPLY'
    vein.inputs[0].default_value = 1.0
    nt.links.new(colour, vein.inputs[1])
    nt.links.new(ramp.outputs['Color'], vein.inputs[2])
    colour = vein.outputs['Color']
nt.links.new(colour, bsdf.inputs['Base Color'])
inp(bsdf, 'Roughness', r.get('roughness', 0.5))
inp(bsdf, 'Metallic', r.get('metallic', 0.0))
if r.get('subsurface'):
    inp(bsdf, ['Subsurface Weight', 'Subsurface'], r['subsurface'])
    inp(bsdf, 'Subsurface Radius', (0.05, 0.03, 0.02))
if r.get('coat'):
    inp(bsdf, ['Coat Weight', 'Clearcoat'], r['coat'])
if r.get('sheen'):
    inp(bsdf, ['Sheen Weight', 'Sheen'], r['sheen'])
if r.get('transmission'):
    inp(bsdf, ['Transmission Weight', 'Transmission'], r['transmission'])
    inp(bsdf, 'IOR', 1.45)
    setp(mat, 'surface_render_method', 'BLENDED')
bump_kind = r.get('bump')
if bump_kind:
    noise = nt.nodes.new('ShaderNodeTexNoise')
    inp(noise, 'Scale', {'fingerprints': 60.0, 'fuzz': 400.0, 'knit': 120.0, 'hammered': 25.0}.get(bump_kind, 60.0))
    inp(noise, 'Detail', 8.0)
    bump = nt.nodes.new('ShaderNodeBump')
    inp(bump, 'Strength', r.get('bump_strength', 0.15))
    inp(bump, 'Distance', 0.02)
    nt.links.new(noise.outputs['Fac'], bump.inputs['Height'])
    nt.links.new(bump.outputs['Normal'], bsdf.inputs['Normal'])
mesh.materials.append(mat)

# ------------------------------------------------------------ set: floor, lights, world
zmin = float(Z.min()) if n else -1.0
floor_mesh = bpy.data.meshes.new('Floor')
floor_mesh.from_pydata([(-20, -20, 0), (20, -20, 0), (20, 20, 0), (-20, 20, 0)], [], [(0, 1, 2, 3)])
floor = bpy.data.objects.new('Floor', floor_mesh)
floor.location.z = zmin - 0.005
scene.collection.objects.link(floor)
fm = bpy.data.materials.new('Floor')
fm.use_nodes = True
fb = fm.node_tree.nodes.get('Principled BSDF')
inp(fb, 'Base Color', (*r.get('floor', [0.55, 0.52, 0.5]), 1))
inp(fb, 'Roughness', 0.8)
floor_mesh.materials.append(fm)
floor.hide_render = not cut and not r.get('floor_always')

world_ = bpy.data.worlds.new('Studio'); scene.world = world_
world_.use_nodes = True
bg = world_.node_tree.nodes['Background']
bg.inputs['Color'].default_value = (*r.get('bg', [0.18, 0.17, 0.17]), 1)
bg.inputs['Strength'].default_value = r.get('ambient', 0.6)


def area_light(name, loc, energy, size, colour=(1, 1, 1)):
    ld = bpy.data.lights.new(name, 'AREA')
    ld.energy = energy; ld.size = size; ld.color = colour
    lo = bpy.data.objects.new(name, ld)
    lo.location = loc
    scene.collection.objects.link(lo)
    tr = lo.constraints.new('TRACK_TO')
    tr.target = obj; tr.track_axis = 'TRACK_NEGATIVE_Z'; tr.up_axis = 'UP_Y'
    return lo


key = r.get('key', 1.0)
area_light('Key', (-3.0, -3.5, 3.0), 600 * key, 3.0, tuple(r.get('key_colour', [1.0, 0.96, 0.9])))
area_light('Fill', (3.5, -3.0, 0.8), 180 * key, 4.0, (0.9, 0.95, 1.0))
area_light('Rim', (0.5, 4.0, 2.5), 450 * key * r.get('rim', 1.0), 2.0)

# ------------------------------------------------------------ turntable + camera
pivot = bpy.data.objects.new('Turntable', None)
scene.collection.objects.link(pivot)
obj.parent = pivot
fps = 24
frames = int(fps * a.get('seconds', 5))
swing = math.radians(r.get('swing', 28 if cut else 12))
for f in range(1, frames + 1, 4):
    pivot.rotation_euler.z = swing * math.sin((f - 1) / frames * math.tau)
    pivot.keyframe_insert('rotation_euler', frame=f)

cam_data = bpy.data.cameras.new('Camera')
cam_data.lens = 70
cam = bpy.data.objects.new('Camera', cam_data)
scene.collection.objects.link(cam)
aspect = max(9 / 16, min(16 / 9, gw / gh))
fit = max(1.0, 1.0 / aspect) * (2.25 if cut else 2.05)
dist = fit / 2 / math.tan(cam_data.angle / 2) * (1.0 if aspect >= 1 else aspect)
tilt = math.radians(r.get('camera_tilt', 8))
cam.location = (0, -dist * math.cos(tilt), dist * math.sin(tilt))
tr = cam.constraints.new('TRACK_TO')
tr.target = pivot; tr.track_axis = 'TRACK_NEGATIVE_Z'; tr.up_axis = 'UP_Y'
scene.camera = cam
if r.get('dof'):
    cam_data.dof.use_dof = True
    cam_data.dof.focus_object = pivot
    cam_data.dof.aperture_fstop = r['dof']

# ------------------------------------------------------------ render
scene.frame_start, scene.frame_end = 1, frames
scene.render.fps = fps
for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = engine; break
    except TypeError:
        pass
setp(scene.eevee, 'taa_render_samples', 64)
setp(scene.eevee, 'use_raytracing', True)
setp(scene.eevee, 'use_shadows', True)
setp(scene.eevee, 'use_gtao', True)
try: scene.view_settings.view_transform = 'AgX'
except Exception: pass
long_side = int(a.get('size', 1920))
rx, ry = (long_side, round(long_side / aspect)) if aspect >= 1 else (round(long_side * aspect), long_side)
scene.render.resolution_x, scene.render.resolution_y = rx - rx % 2, ry - ry % 2
scene.render.resolution_percentage = 100
print(f'Output size: {scene.render.resolution_x}×{scene.render.resolution_y}', file=sys.stderr)

# 1. editable project (and a GLB for 3D Stage or any 3D app)
hero = max(1, int(frames * 0.85))
scene.frame_set(hero)
bpy.context.view_layer.objects.active = obj
obj.select_set(True)
bpy.ops.wm.save_as_mainfile(filepath=a['project'])
if a.get('model'):
    try:
        for o in scene.objects:
            o.select_set(o == obj)
        bpy.ops.export_scene.gltf(filepath=a['model'], use_selection=True, export_apply=True)
    except Exception as e:
        print('Model export skipped:', e, file=sys.stderr)

# 2. the still
im = scene.render.image_settings
if hasattr(im, 'media_type'):
    im.media_type = 'IMAGE'
im.file_format = 'PNG'
im.color_mode = 'RGB'
scene.render.filepath = a['still']
bpy.ops.render.render(write_still=True)

# 3. the turntable
setp(scene.eevee, 'taa_render_samples', 24)
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
print('Sculpt 3D done', file=sys.stderr)
