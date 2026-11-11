import Foundation

/// 3D from Image: turns a picture into a 3D model in Blender (run in the background), renders it,
/// and saves the model as a GLB that 3D Stage (or any 3D app) can open.
/// Relief raises the light parts and sinks the dark parts; Extrude pulls the outline (or a logo's
/// lines) out into a solid with bevelled edges. No AI is involved.
public struct ModelFromImageAdapter: DomainAdapter {
    public let id = "model3d"
    public let name = "3D from Image (Blender)"
    public let symbol = "cube.transparent"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .image, editable: false, exportFormats: ["png"])
    public let dialHint = "relief or extrude, depth, bevel, material, detail, color, light, camera"

    public static let imageExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "webp", "heic"]
    /// Full renders keep their model here; previews keep theirs in the temporary folder.
    public static var modelsFolder = NSString(string: "~/Documents/Ethers Prism Exports/3D Models").expandingTildeInPath

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        [Dial(name: "Mode", detail: "Relief carves the whole picture by brightness; Extrude pulls its outline or a logo's lines out into a solid.", lowPole: "relief", highPole: "extrude", value: 25),
         Dial(name: "Depth", detail: "How far the shapes rise.", lowPole: "shallow", highPole: "deep", value: 50),
         Dial(name: "Bevel", detail: "Rounded edges on extruded shapes.", lowPole: "sharp", highPole: "soft rounded", value: 40),
         Dial(name: "Material", detail: "What it's made of: metal, glass (the middle) or neon light.", lowPole: "metal", highPole: "neon", value: 85),
         Dial(name: "Detail", detail: "How much of the picture becomes shape.", lowPole: "bold and simple", highPole: "every detail", value: 60),
         Dial(name: "Color", detail: "One material color, or the picture's own colors.", lowPole: "one tint", highPole: "picture's colors", value: 100),
         Dial(name: "Light angle", detail: "Low light skims across and makes the carving pop.", lowPole: "low, raking", highPole: "overhead", value: 30),
         Dial(name: "Camera angle", detail: "Looking straight at it, or from a low angle.", lowPole: "straight on", highPole: "low angle", value: 35)]
    }

    /// The picture named in the goal, if any.
    public static func imagePath(from goal: String) -> String? {
        for line in goal.components(separatedBy: .newlines) {
            var p = line.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if p.hasPrefix("~") { p = NSString(string: p).expandingTildeInPath }
            if p.hasPrefix("/"), imageExtensions.contains((p as NSString).pathExtension.lowercased()) { return p }
        }
        return nil
    }

    /// Scene parameters (0...1) read from dials by name, in a fixed order so output is deterministic.
    public static func parameters(_ input: CompileInput) -> [String: Any] {
        func v(_ key: String, _ fallback: Double) -> Double {
            (input.state.dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback) / 100
        }
        return ["mode": v("mode", 25), "depth": v("depth", 50), "bevel": v("bevel", 40), "material": v("material", 85),
                "detail": v("detail", 60), "color": v("color", 100), "light": v("light", 30), "tilt": v("camera", 35),
                "quality": input.quality.rawValue, "image": imagePath(from: input.state.goal) ?? ""]
    }

    /// The model file a result mentions, for Open in 3D Stage.
    public static func modelPath(in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(/[^\\n]*?\\.glb)"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let data = (try? JSONSerialization.data(withJSONObject: Self.parameters(input), options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CompiledRequest(input: input, text: TextRequest(system: "model-from-image", user: json, maxTokens: 0),
                               seed: Compiler.seed(for: json))
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    private func run(_ request: CompiledRequest) async throws -> Generated {
        let blender = BlenderStageAdapter.blenderPath
        guard FileManager.default.isExecutableFile(atPath: blender) else {
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use 3D from Image.")
        }
        var params = Self.parameters(request.input)
        let image = params["image"] as? String ?? ""
        guard !image.isEmpty else {
            throw PrismError.local("Choose a picture first (the Choose Image… button under the goal).")
        }
        guard FileManager.default.fileExists(atPath: image) else {
            throw PrismError.local("This picture wasn't found: \(image)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrism3D-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("model3d.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)

        let stem = ((image as NSString).lastPathComponent as NSString).deletingPathExtension
        let mode = (params["mode"] as? Double ?? 0) >= 0.5 ? "extrude" : "relief"
        let modelDir = request.input.quality == .preview
            ? FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrism 3D Previews").path
            : Self.modelsFolder
        try FileManager.default.createDirectory(atPath: modelDir, withIntermediateDirectories: true)
        let model = (modelDir as NSString).appendingPathComponent("\(stem) \(mode) \(request.seed % 100_000).glb")
        params["out"] = dir.appendingPathComponent("render").path
        params["model_out"] = model
        let args = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"

        // Blender's messages go to a file, so a long render can't fill a pipe and stall.
        let log = dir.appendingPathComponent("blender.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", "--python", script.path, "--", args]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()

        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard let png = try? Data(contentsOf: dir.appendingPathComponent("render.png")), !png.isEmpty else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't produce a picture. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(300))")
        }
        let saved = FileManager.default.fileExists(atPath: model)
        let summary = "\((image as NSString).lastPathComponent) as a 3D \(mode)."
            + (saved ? " Model: \(model)" : " (The model file couldn't be saved.)")
        return Generated(output: Output(kind: .image, text: summary, provider: "Blender",
                                        model: request.input.quality == .preview ? "Eevee preview" : "Eevee render · 1080p",
                                        agent: "3D from Image"),
                         asset: png, assetExtension: "png")
    }

    /// Runs inside Blender. Builds the model from the picture, renders it and exports it as GLB.
    static let script = #"""
import bpy, bmesh, sys, json, math, os
import numpy as np

a = json.loads(sys.argv[sys.argv.index('--') + 1])
preview = a['quality'] == 'preview'
extrude = a['mode'] >= 0.5          # Mode dial: relief (low) ... extrude (high)

# ---------------------------------------------------------------- the picture
img = bpy.data.images.load(a['image'])
W, H = img.size
px = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)  # row 0 = bottom
has_alpha = float(px[..., 3].min()) < 0.99
rgb = px[..., :3]
alpha = px[..., 3] if has_alpha else np.ones((H, W), np.float32)
lum = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]


def blur(x, passes):
    for _ in range(passes):
        x = (x + np.roll(x, 1, 0) + np.roll(x, -1, 0) + np.roll(x, 1, 1) + np.roll(x, -1, 1)) / 5.0
    return x


detail = a['detail']
k = max(1, int(round(max(W, H) / (512 if extrude else 1024))))
lum_s = blur(lum[::k, ::k], 1 + int((1 - detail) * 8))
alpha_s = blur(alpha[::k, ::k], 1)
if not has_alpha:
    # No transparency: treat the background (the colour along the border) as empty space.
    border = np.concatenate([lum_s[0], lum_s[-1], lum_s[:, 0], lum_s[:, -1]])
    bg_l = float(np.median(border))
    fg = np.abs(lum_s - bg_l) > 0.08
    fg = blur(fg.astype(np.float32), 3 + int((1 - detail) * 6))
    if 0.05 < float((fg > 0.5).mean()) < 0.95:
        alpha_s = np.clip(fg * 1.6 - 0.3, 0, 1)
        has_alpha = True
        print('Background treated as empty (no transparency in the picture)', file=sys.stderr)
hh, hw = lum_s.shape
aspect = W / H
size_x, size_y = (2.0, 2.0 / aspect) if aspect >= 1 else (2.0 * aspect, 2.0)
depth_d = a['depth']
bevel_d = a['bevel']

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


# ------------------------------------------------------------ marching squares
TABLE = {1: [('L', 'B')], 2: [('B', 'R')], 3: [('L', 'R')], 4: [('R', 'T')], 5: [('L', 'T'), ('B', 'R')],
         6: [('B', 'T')], 7: [('L', 'T')], 8: [('T', 'L')], 9: [('T', 'B')], 10: [('T', 'R'), ('L', 'B')],
         11: [('T', 'R')], 12: [('R', 'L')], 13: [('R', 'B')], 14: [('B', 'L')]}


def contours(v, t):
    up = v > t
    case = (up[:-1, :-1] * 1 + up[:-1, 1:] * 2 + up[1:, 1:] * 4 + up[1:, :-1] * 8)
    pos, nbr = {}, {}

    def edge(i, j, e):
        key = {'B': ('h', i, j), 'T': ('h', i + 1, j), 'L': ('v', i, j), 'R': ('v', i, j + 1)}[e]
        if key not in pos:
            kind, r, c = key
            if kind == 'h':
                v0, v1 = v[r, c], v[r, c + 1]
                f = (t - v0) / (v1 - v0) if v1 != v0 else 0.5
                pos[key] = (c + f, r)
            else:
                v0, v1 = v[r, c], v[r + 1, c]
                f = (t - v0) / (v1 - v0) if v1 != v0 else 0.5
                pos[key] = (c, r + f)
        return key

    for i, j in zip(*np.nonzero((case > 0) & (case < 15))):
        for e0, e1 in TABLE[int(case[i, j])]:
            p, q = edge(i, j, e0), edge(i, j, e1)
            nbr.setdefault(p, []).append(q)
            nbr.setdefault(q, []).append(p)
    seen, out = set(), []
    for start in list(nbr):
        if start in seen:
            continue
        chain, prev, cur = [start], None, start
        seen.add(start)
        while True:
            nxt = [m for m in nbr[cur] if m != prev and m not in seen]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            seen.add(cur); chain.append(cur)
        if len(chain) > 3 and chain[0] in nbr.get(chain[-1], []):
            out.append([pos[c] for c in chain])
    return out


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    p = np.array(pts)
    s, e = p[0], p[-1]
    d = e - s
    n = math.hypot(*d)
    dist = np.hypot(*(p - s).T) if n < 1e-9 else np.abs(d[0] * (p[:, 1] - s[1]) - d[1] * (p[:, 0] - s[0])) / n
    i = int(dist.argmax())
    if dist[i] > eps:
        return rdp(pts[:i + 1], eps)[:-1] + rdp(pts[i:], eps)
    return [pts[0], pts[-1]]


def area(poly):
    return 0.5 * abs(sum(poly[i][0] * poly[i - 1][1] - poly[i - 1][0] * poly[i][1] for i in range(len(poly))))


# ------------------------------------------------------------------ geometry
if extrude:
    # The shape: the picture's own outline when it has a transparent background,
    # otherwise its bright parts (a logo's lines on a dark background).
    if has_alpha and float(alpha[::k, ::k].min()) < 0.99:
        mask = alpha_s
    else:
        lo, hi = np.percentile(lum_s, [5, 99])
        mask = np.clip((lum_s - lo) / max(hi - lo, 1e-4), 0, 1)
    mask = np.pad(mask, 1)
    level = 0.5 if has_alpha else 0.45 - 0.15 * detail
    loops = contours(mask, level)
    min_area = (60 - 55 * detail) * (mask.shape[0] / 400) ** 2
    loops = [rdp(l + [l[0]], 0.35 + 0.9 * (1 - detail))[:-1] for l in loops]
    loops = [l for l in loops if len(l) >= 3 and area(l) >= min_area]
    mh, mw = mask.shape
    sx, sy = size_x / (mw - 2), size_y / (mh - 2)
    cu = bpy.data.curves.new('Shape', 'CURVE')
    cu.dimensions = '2D'
    cu.fill_mode = 'BOTH'
    cu.extrude = 0.02 + 0.22 * depth_d
    cu.bevel_depth = 0.002 + 0.03 * bevel_d
    cu.bevel_resolution = 2 if preview else 4
    for l in loops:
        sp = cu.splines.new('POLY')
        sp.points.add(len(l) - 1)
        for pi, (x, y) in enumerate(l):
            sp.points[pi].co = ((x - 1) * sx - size_x / 2, (y - 1) * sy - size_y / 2, 0, 1)
        sp.use_cyclic_u = True
    obj = bpy.data.objects.new('Model', cu)
    scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.convert(target='MESH')
    obj = bpy.context.active_object
    print(f'Extrude: {len(loops)} outlines', file=sys.stderr)
else:
    res = int((120 + 280 * detail) if preview else (220 + 520 * detail))
    nx = res if aspect >= 1 else max(8, int(res * aspect))
    ny = max(8, int(res / aspect)) if aspect >= 1 else res
    bpy.ops.mesh.primitive_grid_add(x_subdivisions=nx, y_subdivisions=ny, size=1)
    obj = bpy.context.active_object
    obj.scale = (size_x, size_y, 1)
    bpy.ops.object.transform_apply(scale=True)
    me = obj.data
    lo, hi = np.percentile(lum_s[alpha_s > 0.5], [2, 98]) if (alpha_s > 0.5).any() else (0.0, 1.0)
    height = np.clip((lum_s - lo) / max(hi - lo, 1e-4), 0, 1) * np.clip(alpha_s * 1.5 - 0.25, 0, 1)
    n = len(me.vertices)
    co = np.zeros(n * 3, dtype=np.float32)
    me.vertices.foreach_get('co', co)
    co = co.reshape(n, 3)
    u = np.clip((co[:, 0] / size_x + 0.5) * (hw - 1), 0, hw - 1).astype(np.int32)
    v = np.clip((co[:, 1] / size_y + 0.5) * (hh - 1), 0, hh - 1).astype(np.int32)
    co[:, 2] = height[v, u] * (0.02 + 0.28 * depth_d)
    me.vertices.foreach_set('co', co.ravel())
    if has_alpha:   # cut out to the picture's own shape
        mv = alpha_s[v, u]
        bm = bmesh.new(); bm.from_mesh(me)
        drop = [f for f in bm.faces if sum(mv[x.index] for x in f.verts) / len(f.verts) < 0.5]
        bmesh.ops.delete(bm, geom=drop, context='FACES')
        bm.to_mesh(me); bm.free()
    sol = obj.modifiers.new('Thickness', 'SOLIDIFY')
    sol.thickness = 0.04 if has_alpha else 0.1
    sol.offset = -1
    bpy.ops.object.modifier_apply(modifier='Thickness')
    print(f'Relief: {nx}x{ny} grid, cut out: {has_alpha}', file=sys.stderr)

obj.name = 'Model'
me = obj.data
for p in me.polygons:
    p.use_smooth = True
# UVs from position, so the picture's colors land where they came from (and survive export)
uvl = me.uv_layers.new(name='UVMap') if not me.uv_layers else me.uv_layers[0]
co = np.zeros(len(me.vertices) * 3, dtype=np.float32)
me.vertices.foreach_get('co', co)
co = co.reshape(-1, 3)
li = np.zeros(len(me.loops), dtype=np.int32)
me.loops.foreach_get('vertex_index', li)
uv = np.stack([co[li, 0] / size_x + 0.5, co[li, 1] / size_y + 0.5], axis=1)
uvl.data.foreach_set('uv', uv.ravel())

# ---------------------------------------------------------------- material
m = a['material']                    # metal (0) ... glass (0.5) ... neon (1)
w_metal = max(0.0, 1 - 2 * m)
w_glass = 1 - abs(2 * m - 1)
w_neon = max(0.0, 2 * m - 1)
color = a['color']                   # one tint (0) ... the picture's colors (1)
mat = bpy.data.materials.new('Model')
mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes['Principled BSDF']
tex = nt.nodes.new('ShaderNodeTexImage')
tex.image = bpy.data.images.load(a['image'])
tint = (1.0, 0.66, 0.22, 1) if w_metal >= w_neon else (0.75, 0.55, 1.0, 1)    # gold, or violet light
if w_glass > 0.5:
    tint = (0.85, 0.92, 1.0, 1)                                                  # clear glass
mix = nt.nodes.new('ShaderNodeMix'); mix.data_type = 'RGBA'
mix.inputs['Factor'].default_value = color
mix.inputs[6].default_value = tint
nt.links.new(tex.outputs['Color'], mix.inputs[7])
nt.links.new(mix.outputs[2], bsdf.inputs['Base Color'])
bsdf.inputs['Metallic'].default_value = w_metal
bsdf.inputs['Roughness'].default_value = 0.22 * w_metal + 0.03 * w_glass + 0.45 * w_neon
if w_glass > 0.05:
    mix.inputs['Factor'].default_value = color * 0.55          # glass keeps some clarity
for name in ('Transmission Weight', 'Transmission'):
    if name in bsdf.inputs:
        bsdf.inputs[name].default_value = w_glass
        break
if w_neon > 0:
    if extrude:
        nt.links.new(mix.outputs[2], bsdf.inputs['Emission Color'])
    else:   # in relief, only the bright parts light up (lava, eyes, symbols)
        ramp = nt.nodes.new('ShaderNodeValToRGB')
        ramp.color_ramp.elements[0].position = 0.5
        ramp.color_ramp.elements[1].position = 0.9
        nt.links.new(tex.outputs['Color'], ramp.inputs['Fac'])
        em = nt.nodes.new('ShaderNodeMix'); em.data_type = 'RGBA'; em.blend_type = 'MULTIPLY'
        em.inputs['Factor'].default_value = 1.0
        nt.links.new(ramp.outputs['Color'], em.inputs[6])
        nt.links.new(mix.outputs[2], em.inputs[7])
        nt.links.new(em.outputs[2], bsdf.inputs['Emission Color'])
    bsdf.inputs['Emission Strength'].default_value = 7.0 * w_neon
try: mat.surface_render_method = 'DITHERED'
except Exception: pass
me.materials.append(mat)

# ------------------------------------------------------------------- light
world = bpy.data.worlds.new('Studio'); scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes['Background']
bg.inputs['Color'].default_value = (0.02, 0.018, 0.03, 1)
bg.inputs['Strength'].default_value = 1.0 + 2.5 * w_glass      # glass needs something to refract
if w_glass > 0.05:
    bg.inputs['Color'].default_value = (0.05, 0.045, 0.07, 1)
key_d = bpy.data.lights.new('Key', 'SUN'); key_d.energy = 4.5 * (1 - 0.6 * w_neon); key_d.angle = math.radians(3)
key = bpy.data.objects.new('Key', key_d); scene.collection.objects.link(key)
elev = math.radians(12 + 63 * a['light'])            # low raking light ... high overhead
key.rotation_euler = (math.pi / 2 - elev, 0, math.radians(-35))
fill_d = bpy.data.lights.new('Fill', 'SUN'); fill_d.energy = 0.8
fill = bpy.data.objects.new('Fill', fill_d); scene.collection.objects.link(fill)
fill.rotation_euler = (math.radians(35), 0, math.radians(150))
rim_d = bpy.data.lights.new('Rim', 'AREA'); rim_d.energy = 300; rim_d.size = 3
rim = bpy.data.objects.new('Rim', rim_d); scene.collection.objects.link(rim)
rim.location = (0, 3.5, 2.5); rim.rotation_euler = (math.radians(-55), 0, 0)

# ------------------------------------------------------------------ camera
cam_d = bpy.data.cameras.new('Camera'); cam_d.lens = 50
cam = bpy.data.objects.new('Camera', cam_d); scene.collection.objects.link(cam)
tilt = math.radians(5 + 55 * a['tilt'])              # straight on ... low angle
turn = math.radians(-25 * a['tilt'])
dist = 4.8 * max(size_x / 2.0 * 0.9, size_y / 2.0 * 1.6, 1.0) * 0.9
cam.location = (dist * math.sin(tilt) * math.sin(turn), -dist * math.sin(tilt) * math.cos(turn), dist * math.cos(tilt))
target = bpy.data.objects.new('Target', None); scene.collection.objects.link(target)
track = cam.constraints.new('TRACK_TO'); track.target = target
track.track_axis = 'TRACK_NEGATIVE_Z'; track.up_axis = 'UP_Y'
scene.camera = cam

# ------------------------------------------------------- bloom (neon)
if w_neon > 0.05:
    try:
        if hasattr(scene, 'compositing_node_group'):
            tree = bpy.data.node_groups.new('Bloom', 'CompositorNodeTree')
            scene.compositing_node_group = tree
            rl = tree.nodes.new('CompositorNodeRLayers')
            out = tree.nodes.new('NodeGroupOutput')
            tree.interface.new_socket('Image', in_out='OUTPUT', socket_type='NodeSocketColor')
        else:
            scene.use_nodes = True
            tree = scene.node_tree
            rl = next(nn for nn in tree.nodes if nn.type == 'R_LAYERS')
            out = next(nn for nn in tree.nodes if nn.type == 'COMPOSITE')
        g = tree.nodes.new('CompositorNodeGlare')
        typ = g.inputs.get('Type')
        for v_ in ('Bloom', 'BLOOM', 'Fog Glow', 'FOG_GLOW'):
            try:
                if typ is not None: typ.default_value = v_
                else: g.glare_type = v_
                break
            except Exception: pass
        for name, val in (('Threshold', 1.0), ('Strength', 0.2 + 0.5 * w_neon), ('Size', 0.5)):
            sock = g.inputs.get(name)
            if sock is not None:
                try: sock.default_value = val
                except Exception: pass
        tree.links.new(rl.outputs['Image'], g.inputs['Image'])
        tree.links.new(g.outputs['Image'], out.inputs[0])
    except Exception as e:
        print('Bloom skipped:', e, file=sys.stderr)

# ----------------------------------------------------------------- render
for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = engine; break
    except TypeError:
        pass
try: scene.eevee.taa_render_samples = 24 if preview else 96
except Exception: pass
if w_glass > 0.05:
    for attr in ('use_raytracing', 'use_ssr', 'use_ssr_refraction'):
        try: setattr(scene.eevee, attr, True)
        except Exception: pass
scene.render.resolution_x, scene.render.resolution_y = (640, 360) if preview else (1920, 1080)
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = a['out'] + '.png'
bpy.ops.render.render(write_still=True)

# the model, for 3D Stage or any 3D app
if a.get('model_out'):
    try:
        os.makedirs(os.path.dirname(a['model_out']), exist_ok=True)
        bpy.ops.object.select_all(action='DESELECT')
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        # stand it up: the carved face looks forward, the bottom edge sits at the floor
        obj.rotation_euler = (math.radians(90), 0, 0)
        bpy.ops.object.transform_apply(rotation=True)
        zmin = min((obj.matrix_world @ vv.co).z for vv in obj.data.vertices)
        obj.location.z -= zmin
        bpy.ops.object.transform_apply(location=True)
        bpy.ops.export_scene.gltf(filepath=a['model_out'], use_selection=True, export_apply=True)
        print('Model saved:', a['model_out'], file=sys.stderr)
    except Exception as e:
        print('Model export skipped:', e, file=sys.stderr)
"""#
}
