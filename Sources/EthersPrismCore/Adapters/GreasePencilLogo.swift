import Foundation

/// Line Logo: traces a logo image into Grease Pencil lines in Blender (run in the background)
/// and renders them drawing themselves on, as an MP4. Lines keep the logo's own colors (or
/// glow white), boil slightly like hand-drawn animation, and can step on 1s, 2s or 3s.
/// The goal is the path to the logo image; with none, the Ether Frequency emblem is used.
public struct GreasePencilLogoAdapter: DomainAdapter {
    public let id = "linelogo"
    public let name = "Line Logo (Grease Pencil)"
    public let symbol = "scribble.variable"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .video, editable: false, exportFormats: ["mp4"])
    public let dialHint = "draw speed, line weight, wobble, timing, glow, detail, ink color, camera push, length"

    public static let imageExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "webp", "heic"]
    /// Used when the goal names no image.
    public static var defaultLogo = NSString(string: "~/Documents/EthersPrism/Examples/ether-frequency-emblem.png").expandingTildeInPath

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        Self.standardDials
    }

    private static var standardDials: [Dial] {
        [Dial(name: "Draw speed", detail: "How quickly the lines draw themselves on.", lowPole: "slow reveal", highPole: "quick sketch", value: 50),
         Dial(name: "Line weight", detail: "Thickness of the lines.", lowPole: "fine pen", highPole: "bold marker", value: 30),
         Dial(name: "Wobble", detail: "How much the lines boil from frame to frame, like hand-drawn animation.", lowPole: "steady", highPole: "lively boil", value: 35),
         Dial(name: "Timing", detail: "Smooth motion, or held drawings like traditional animation.", lowPole: "smooth (on 1s)", highPole: "choppy (on 3s)", value: 50),
         Dial(name: "Glow", detail: "Soft light around the lines.", lowPole: "flat ink", highPole: "neon", value: 50),
         Dial(name: "Detail", detail: "How many edges of the logo become lines.", lowPole: "bold outline", highPole: "every detail", value: 50),
         Dial(name: "Ink", detail: "Line color.", lowPole: "logo's own colors", highPole: "white light", value: 0),
         Dial(name: "Camera push", detail: "A slow move in toward the logo.", lowPole: "still", highPole: "push in", value: 30),
         Dial(name: "Length", detail: "Clip length for full renders. Previews are always 2 seconds.", lowPole: "3 seconds", highPole: "12 seconds", value: 20),
         Dial(name: "Resolution", lowPole: "720p", highPole: "4K UHD", value: 0),
         Dial(name: "Framing", lowPole: "Landscape", highPole: "Portrait", value: 0),
         Dial(name: "Photo reveal", lowPole: "Ink only", highPole: "Full photograph", value: 0),
         Dial(name: "Trace resolution", lowPole: "Standard grid", highPole: "Fine grid", value: 0),
         Dial(name: "Micro-detail", lowPole: "Broad contours", highPole: "Fine contours", value: 0),
         Dial(name: "Texture fidelity", lowPole: "Soft", highPole: "Crisp", value: 50),
         Dial(name: "Edge sensitivity", lowPole: "Off", highPole: "Fine edges", value: 0),
         Dial(name: "Path precision", lowPole: "Simplified", highPole: "Precise", value: 0),
         Dial(name: "Anti-aliasing", lowPole: "Standard", highPole: "128 samples", value: 20),
         Dial(name: "Exposure", lowPole: "Darker", highPole: "Brighter", value: 50),
         Dial(name: "Contrast", lowPole: "Lower", highPole: "Higher", value: 50),
         Dial(name: "Saturation", lowPole: "Muted", highPole: "Vivid", value: 50),
         Dial(name: "Warmth", lowPole: "Cool", highPole: "Warm", value: 50),
         Dial(name: "Light falloff", lowPole: "Even", highPole: "Focused center", value: 0),
         Dial(name: "Ink fidelity", lowPole: "Vivid ink", highPole: "Source tones", value: 0),
         Dial(name: "Stroke stability", lowPole: "Boil", highPole: "Steady", value: 0),
         Dial(name: "Reveal easing", lowPole: "Linear", highPole: "Ease in and out", value: 0),
         Dial(name: "Stroke opacity", lowPole: "Transparent", highPole: "Opaque", value: 100)]
    }

    /// The logo image named in the goal, if any.
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
            min(100, max(0, input.state.dials.first { $0.name.lowercased() == key }?.value ?? fallback)) / 100
        }
        return ["draw": v("draw speed", 50), "weight": v("line weight", 30), "wobble": v("wobble", 35),
                "timing": v("timing", 50), "glow": v("glow", 50), "detail": v("detail", 50),
                "ink": v("ink", 0), "drift": v("camera push", 30), "length": v("length", 20),
                "resolution": v("resolution", 0),
                "aspect": v("framing", 0),
                "photo": v("photo reveal", 0),
                "trace": v("trace resolution", 0),
                "micro": v("micro-detail", 0),
                "texture": v("texture fidelity", 50),
                "edges": v("edge sensitivity", 0),
                "precision": v("path precision", 0),
                "aa": v("anti-aliasing", 20),
                "exposure": v("exposure", 50),
                "contrast": v("contrast", 50),
                "saturation": v("saturation", 50),
                "warmth": v("warmth", 50),
                "falloff": v("light falloff", 0),
                "fidelity": v("ink fidelity", 0),
                "stability": v("stroke stability", 0),
                "easing": v("reveal easing", 0),
                "opacity": v("stroke opacity", 100),
                "quality": input.quality.rawValue,
                "image": imagePath(from: input.state.goal) ?? defaultLogo]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let data = (try? JSONSerialization.data(withJSONObject: Self.parameters(input), options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CompiledRequest(input: input, text: TextRequest(system: "grease-pencil-logo", user: json, maxTokens: 0),
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
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use Line Logo.")
        }
        var params = Self.parameters(request.input)
        let image = params["image"] as? String ?? ""
        guard FileManager.default.fileExists(atPath: image) else {
            throw PrismError.local("Choose a logo image first (the Choose Logo… button under the goal). Not found: \(image)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrismLineLogo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("line_logo.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        params["seed"] = Int(request.seed % 1_000_000)
        params["out"] = dir.appendingPathComponent("clip").path
        let args = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"

        // Blender's messages go to a file, so a long render can't fill a pipe and stall.
        let log = dir.appendingPathComponent("blender.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", "--python-exit-code", "1", "--python", script.path, "--", args]
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

        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0,
              let name = files.first(where: { $0.lowercased().hasSuffix(".mp4") }),
              let mp4 = try? Data(contentsOf: dir.appendingPathComponent(name)), !mp4.isEmpty else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't produce a clip. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(300))")
        }
        let lines = text.components(separatedBy: .newlines).first { $0.hasPrefix("Grease Pencil logo:") }?
            .replacingOccurrences(of: "Grease Pencil logo: ", with: "") ?? ""
        let dimensions = text.components(separatedBy: .newlines).first { $0.hasPrefix("Output size: ") }?
            .replacingOccurrences(of: "Output size: ", with: "") ?? ""
        let summary = "\((image as NSString).lastPathComponent) drawn in Grease Pencil" + (lines.isEmpty ? "." : ": \(lines).")
        return Generated(output: Output(kind: .video, text: summary, provider: "Blender",
                                        model: request.input.quality == .preview ? "Grease Pencil preview · 2 s" : "Grease Pencil render · \(dimensions)",
                                        agent: "Line Logo"),
                         asset: mp4, assetExtension: "mp4")
    }

    /// Runs inside Blender. Traces the image into Grease Pencil lines and renders them drawing on.
    static let script = #"""
import bpy, sys, json, math, random
import numpy as np

a = json.loads(sys.argv[sys.argv.index('--') + 1])
preview = a['quality'] == 'preview'
seed = int(a.get('seed', 7))

bpy.ops.wm.read_factory_settings(use_empty=True)

# ---------------------------------------------------------------- image -> grid
img = bpy.data.images.load(a['image'])
W, H = img.size
pixels = np.empty(W * H * 4, dtype=np.float32)
img.pixels.foreach_get(pixels)
px = pixels.reshape(H, W, 4)  # row 0 = bottom
detail = a['detail']
target = int(180 + 200 * detail) if not preview else int(150 + 130 * detail)
target += int(a['trace'] * (220 if preview else 640))
k = min(W, H, max(1, int(math.ceil(max(W, H) / target))))
h2, w2 = H // k, W // k
blk = px[:h2 * k, :w2 * k].reshape(h2, k, w2, k, 4).mean(axis=(1, 3))
rgb, alpha = blk[..., :3], blk[..., 3]
lum = (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]) * alpha
lum = lum / max(float(lum.max()), 1e-6)
edge_field = None
if a['edges'] > 0:
    gx = np.diff(lum, axis=1, append=lum[:, -1:])
    gy = np.diff(lum, axis=0, append=lum[-1:, :])
    edges = np.clip(np.hypot(gx, gy) * (2 + 10 * a['edges']), 0, 1)
    # Suppress soft gradients and retain locally strong edges on top of tone contours.
    local = (np.roll(edges, 1, axis=0) + np.roll(edges, -1, axis=0) +
             np.roll(edges, 1, axis=1) + np.roll(edges, -1, axis=1)) / 4
    edge_field = np.pad(np.maximum(edges - 0.5 * local, 0) * a['edges'], 1)
lum = np.pad(lum, 1)  # closes shapes that touch the border
rgb = np.pad(rgb, ((1, 1), (1, 1), (0, 0)))
gh, gw = lum.shape

# ------------------------------------------------------- marching squares
# corners of cell (i, j): a=(i,j) b=(i,j+1) c=(i+1,j+1) d=(i+1,j); edges B, R, T, L
TABLE = {1: [('L', 'B')], 2: [('B', 'R')], 3: [('L', 'R')], 4: [('R', 'T')], 5: [('L', 'T'), ('B', 'R')],
         6: [('B', 'T')], 7: [('L', 'T')], 8: [('T', 'L')], 9: [('T', 'B')], 10: [('T', 'R'), ('L', 'B')],
         11: [('T', 'R')], 12: [('R', 'L')], 13: [('R', 'B')], 14: [('B', 'L')]}


def contours(v, t):
    up = v > t
    case = (up[:-1, :-1] * 1 + up[:-1, 1:] * 2 + up[1:, 1:] * 4 + up[1:, :-1] * 8)
    pos = {}

    def edge(i, j, e):
        if e == 'B': key = ('h', i, j)
        elif e == 'T': key = ('h', i + 1, j)
        elif e == 'L': key = ('v', i, j)
        else: key = ('v', i, j + 1)
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

    nbr = {}
    for i, j in zip(*np.nonzero((case > 0) & (case < 15))):
        for e0, e1 in TABLE[int(case[i, j])]:
            p, q = edge(i, j, e0), edge(i, j, e1)
            nbr.setdefault(p, []).append(q)
            nbr.setdefault(q, []).append(p)
    seen, out = set(), []
    for start in list(nbr):
        if start in seen:
            continue
        # walk to one end (or around a loop), then collect
        chain, prev, cur = [start], None, start
        seen.add(start)
        while True:
            nxt = [n for n in nbr[cur] if n != prev and n not in seen]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            seen.add(cur); chain.append(cur)
        prev, cur = None, start
        back = []
        while True:
            nxt = [n for n in nbr[cur] if n != prev and n not in seen]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            seen.add(cur); back.append(cur)
        chain = back[::-1] + chain
        closed = len(chain) > 2 and chain[0] in nbr.get(chain[-1], [])
        out.append(([pos[c] for c in chain], closed))
    return out


def rdp(pts, eps):
    if len(pts) < 3:
        return pts
    p = np.array(pts)
    s, e = p[0], p[-1]
    d = e - s
    n = math.hypot(*d)
    if n < 1e-9:
        dist = np.hypot(*(p - s).T)
    else:
        dist = np.abs(d[0] * (p[:, 1] - s[1]) - d[1] * (p[:, 0] - s[0])) / n
    i = int(dist.argmax())
    if dist[i] > eps:
        return rdp(pts[:i + 1], eps)[:-1] + rdp(pts[i:], eps)
    return [pts[0], pts[-1]]


levels = [0.45] if detail < 0.34 else ([0.3, 0.62] if detail < 0.67 else [0.22, 0.45, 0.7])
if a['micro'] > 0.25:
    levels = sorted(set(levels + [0.12, 0.82][:1 + int(a['micro'] > 0.65)]))
min_len = (14 - 9 * detail) * max(gh, gw) / 300 * (1 - 0.85 * a['micro'])
lines = []
passes = [(lum, t) for t in levels]
if edge_field is not None:
    passes.append((edge_field, 0.22))
for field, threshold in passes:
    for chain, closed in contours(field, threshold):
        if closed:
            chain = chain + [chain[0]]
        L = sum(math.dist(chain[i], chain[i + 1]) for i in range(len(chain) - 1))
        if L < min_len * (0.45 if field is edge_field else 1):
            continue
        lines.append((rdp(chain, 0.45 - 0.35 * a['precision']), L))

# ----------------------------------------------------------- to world space
scale = 2.0 / max(gw, gh)
cx, cy = gw / 2, gh / 2
ink = a['ink']


def color_at(x, y):
    r = min(max(int(y), 0), gh - 1); c = min(max(int(x), 0), gw - 1)
    win = rgb[max(r - 3, 0):r + 4, max(c - 3, 0):c + 4].reshape(-1, 3)
    lum_w = (win * [0.2126, 0.7152, 0.0722]).sum(axis=1)
    sat_w = win.max(axis=1) - win.min(axis=1)
    source = rgb[r, c]
    col = win[int((lum_w * (0.25 + sat_w)).argmax())].copy()   # bright and colourful, not a white highlight
    m = max(float(col.max()), 1e-3)
    col = np.clip(col / m, 0, 1)                    # full brightness, keep the hue
    grey = float(col.mean())
    col = np.clip(grey + (col - grey) * 1.6, 0, 1)  # more saturated
    col = col * 0.82 + 0.03                         # just under white, so bloom keeps the hue
    col = col * (1 - a['fidelity']) + source * a['fidelity']
    grey = float(col @ [0.2126, 0.7152, 0.0722])
    col = grey + (col - grey) * (2 * a['saturation'])
    col = (col - 0.5) * (0.5 + a['contrast']) ** 2 + 0.5
    col = np.clip(col * np.exp2((a['warmth'] - 0.5) * np.array([1, 0, -1])), 0, 1)
    white = np.array([1.0, 0.97, 1.0])
    return tuple(col * (1 - ink) + white * ink)


# Keep geometry bounded before resampling and building per-frame drawings.
cap = 900 if preview else 2200
lines.sort(key=lambda line: -line[1])
lines = lines[:cap]
spacing = (0.006 if preview else 0.004) * (1 - 0.5 * a['precision'])
strokes = []
for pts, L in lines:
    w = [((x - cx) * scale, (y - cy) * scale) for x, y in pts]
    seg = [math.dist(w[i], w[i + 1]) for i in range(len(w) - 1)]
    total = sum(seg)
    n = max(2, int(total / spacing))
    out, acc, si = [], 0.0, 0
    for s in range(n + 1):
        target_d = total * s / n
        while si < len(seg) - 1 and acc + seg[si] < target_d:
            acc += seg[si]; si += 1
        f = (target_d - acc) / seg[si] if seg[si] > 0 else 0
        x0, y0 = w[si]; x1, y1 = w[si + 1]
        out.append((x0 + (x1 - x0) * f, y0 + (y1 - y0) * f))
    mid = pts[len(pts) // 2]
    cxw = sum(p[0] for p in out) / len(out); cyw = sum(p[1] for p in out) / len(out)
    strokes.append({'pts': out, 'len': total, 'col': color_at(*mid), 'r': math.hypot(cxw, cyw)})

# draw from the centre outward, long lines first within a ring
strokes.sort(key=lambda s: (round(s['r'] * 6), -s['len']))
total_len = sum(s['len'] for s in strokes) or 1.0
acc = 0.0
for s in strokes:
    s['t0'] = acc / total_len
    acc += s['len']
    s['t1'] = acc / total_len
print(f'Grease Pencil logo: {len(strokes)} lines from a {gw}x{gh} grid', file=sys.stderr)

# ------------------------------------------------------------------- scene
scene = bpy.context.scene
fps = 24
seconds = 2.0 if preview else 3.0 + a['length'] * 9.0
frames = max(2, int(round(seconds * fps)))
step = 1 + int(round(a['timing'] * 2))            # on 1s, 2s or 3s
draw_frames = max(4, int(frames * (0.9 - 0.6 * a['draw'])))
base_r = (0.006 + 0.02 * a['weight'])
wobble = (0.0015 + 0.012 * a['wobble']) * (1 - a['stability'])
glow = a['glow']
use_bloom = a.get('bloom', True)
use_glow_lines = a.get('glow_lines', True)

world = bpy.data.worlds.new('Night'); scene.world = world
world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.006, 0.004, 0.014, 1)

gp_blocks = getattr(bpy.data, 'grease_pencils_v3', None) or bpy.data.grease_pencils
gp = gp_blocks.new('Ether Logo')
obj = bpy.data.objects.new('Ether Logo', gp)
scene.collection.objects.link(obj)

mat = bpy.data.materials.new('Ink')
bpy.data.materials.create_gpencil_data(mat)
mat.grease_pencil.color = (1, 1, 1, 1)
gp.materials.append(mat)

glow_layer = gp.layers.new('Glow') if glow > 0.02 and use_glow_lines else None
ink_layer = gp.layers.new('Ink')
# Blender 4.3+ lights Grease Pencil layers by default; with no lamps the lines
# come out at a quarter brightness. These are drawn lines, so show them unlit.
for lay in gp.layers:
    try: lay.use_lights = False
    except Exception: pass


def noise(seed):
    r = random.Random(seed)
    return r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(0, math.tau)


def build(layer, frame_no, progress, key, radius_mul, opacity):
    frame = layer.frames.new(frame_no)
    d = frame.drawing
    parts = []
    for si, s in enumerate(strokes):
        if progress <= s['t0']:
            continue
        f = 1.0 if progress >= s['t1'] else (progress - s['t0']) / max(s['t1'] - s['t0'], 1e-9)
        tip = (len(s['pts']) - 1) * f
        parts.append((si, math.ceil(tip) + 1, tip))
    if not parts:
        return
    d.add_strokes([n for _, n, _ in parts])
    pos, rad, col, opa = [], [], [], []
    for si, n, tip in parts:
        s = strokes[si]
        ax, ay, ph = noise(seed + key * 7919 + si)
        for pi in range(n):
            x, y = s['pts'][pi]
            if pi > tip:
                x0, y0 = s['pts'][pi - 1]
                mix = tip - (pi - 1)
                x, y = x0 + (x - x0) * mix, y0 + (y - y0) * mix
            u = min(pi, tip) / (len(s['pts']) - 1)
            wob = math.sin(u * 9.0 + ph) * wobble
            pos += [x + ax * wobble * 0.5 + wob * 0.6, 0.0, y + ay * wobble * 0.5 + wob * 0.4]
            taper = 0.55 + 0.45 * math.sin(math.pi * min(1.0, u)) if len(s['pts']) > 4 else 1.0
            rad.append(base_r * radius_mul * taper)
            col += [*s['col'], 1.0]
            opa.append(opacity)
    attrs = d.attributes
    attrs['position'].data.foreach_set('vector', pos)
    if 'radius' in attrs: attrs['radius'].data.foreach_set('value', rad)
    else: attrs.new('radius', 'FLOAT', 'POINT').data.foreach_set('value', rad)
    if 'opacity' in attrs: attrs['opacity'].data.foreach_set('value', opa)
    else: attrs.new('opacity', 'FLOAT', 'POINT').data.foreach_set('value', opa)
    vc = attrs.get('vertex_color') or attrs.new('vertex_color', 'FLOAT_COLOR', 'POINT')
    vc.data.foreach_set('color', col)


key = 0
for f in range(1, frames + 1, step):
    progress = min(1.0, (f - 1) / draw_frames)
    progress += a['easing'] * (progress * progress * (3 - 2 * progress) - progress)
    if progress == 1 and wobble == 0 and f - step > draw_frames:
        break
    if glow_layer is not None:
        build(glow_layer, f, progress, key, 1.8 + 1.4 * glow, 0.06 + 0.16 * glow)
    build(ink_layer, f, progress, key, 1.0, a['opacity'])
    key += 1

# glow breathes once the drawing is done
if glow_layer is not None:
    try:
        for f in range(draw_frames, frames + 1, 6):
            p = (f - draw_frames) / 24.0
            glow_layer.opacity = 0.75 + 0.25 * math.sin(p * math.tau * 0.5)
            gp.keyframe_insert(f'layers["Glow"].opacity', frame=f)
    except Exception as e:
        print('Glow pulse skipped:', e, file=sys.stderr)

# ------------------------------------------------------------ photo reveal
if a['photo'] > 0:
    half_w, half_h = W / max(W, H), H / max(W, H)
    mesh = bpy.data.meshes.new('Photo')
    mesh.from_pydata([(-half_w, 0.04, -half_h), (half_w, 0.04, -half_h),
                      (half_w, 0.04, half_h), (-half_w, 0.04, half_h)], [], [(0, 1, 2, 3)])
    uv = mesh.uv_layers.new()
    for loop, coords in zip(uv.data, [(0, 0), (1, 0), (1, 1), (0, 1)]):
        loop.uv = coords
    photo = bpy.data.objects.new('Photo', mesh)
    scene.collection.objects.link(photo)
    material = bpy.data.materials.new('Photo reveal')
    material.use_nodes = True
    if hasattr(material, 'surface_render_method'):
        material.surface_render_method = 'DITHERED'
    photo.data.materials.append(material)
    nodes, links = material.node_tree.nodes, material.node_tree.links
    output = nodes.get('Material Output')
    image = nodes.new('ShaderNodeTexImage')
    image.image = img
    image.interpolation = 'Cubic'
    soft_image = nodes.new('ShaderNodeTexImage')
    soft_image.image = img
    soft_image.interpolation = 'Linear'
    texture = nodes.new('ShaderNodeMixRGB')
    texture.inputs[0].default_value = a['texture']
    links.new(soft_image.outputs['Color'], texture.inputs[1])
    links.new(image.outputs['Color'], texture.inputs[2])
    uv_node = nodes.new('ShaderNodeTexCoord')
    links.new(uv_node.outputs['UV'], image.inputs['Vector'])
    hue = nodes.new('ShaderNodeHueSaturation')
    hue.inputs['Saturation'].default_value = 2 * a['saturation']
    links.new(uv_node.outputs['UV'], soft_image.inputs['Vector'])
    links.new(texture.outputs['Color'], hue.inputs['Color'])
    contrast = nodes.new('ShaderNodeBrightContrast')
    contrast.inputs['Contrast'].default_value = (a['contrast'] - 0.5) * 100
    links.new(hue.outputs['Color'], contrast.inputs['Color'])

    distance = nodes.new('ShaderNodeVectorMath')
    distance.operation = 'DISTANCE'
    distance.inputs[1].default_value = (0.5, 0.5, 0)
    links.new(uv_node.outputs['UV'], distance.inputs[0])
    light = nodes.new('ShaderNodeMath')
    light.operation = 'MULTIPLY_ADD'
    light.inputs[1].default_value = -a['falloff']
    light.inputs[2].default_value = 1
    links.new(distance.outputs['Value'], light.inputs[0])
    light_color = nodes.new('ShaderNodeVectorMath')
    light_color.operation = 'SCALE'
    links.new(contrast.outputs['Color'], light_color.inputs[0])
    links.new(light.outputs[0], light_color.inputs['Scale'])
    balance = nodes.new('ShaderNodeVectorMath')
    balance.operation = 'MULTIPLY'
    balance.inputs[1].default_value = tuple(np.exp2((a['warmth'] - 0.5) * np.array([1, 0, -1])))
    links.new(light_color.outputs[0], balance.inputs[0])
    emission = nodes.new('ShaderNodeEmission')
    links.new(balance.outputs[0], emission.inputs['Color'])

    reveal = nodes.new('ShaderNodeMath')
    reveal.operation = 'SUBTRACT'
    links.new(distance.outputs['Value'], reveal.inputs[1])
    for f in range(1, frames + 1, step):
        progress = min(1.0, (f - 1) / draw_frames)
        progress += a['easing'] * (progress * progress * (3 - 2 * progress) - progress)
        reveal.inputs[0].default_value = 0.84 * progress - 0.06
        reveal.inputs[0].keyframe_insert('default_value', frame=f)
    strength = nodes.new('ShaderNodeMath')
    strength.operation = 'MULTIPLY'
    strength.use_clamp = True
    strength.inputs[1].default_value = 16
    links.new(reveal.outputs[0], strength.inputs[0])
    alpha = nodes.new('ShaderNodeMath')
    alpha.operation = 'MULTIPLY'
    links.new(image.outputs['Alpha'], alpha.inputs[0])
    alpha.inputs[1].default_value = a['photo']
    mask = nodes.new('ShaderNodeMath')
    mask.operation = 'MULTIPLY'
    links.new(alpha.outputs[0], mask.inputs[0])
    links.new(strength.outputs[0], mask.inputs[1])
    mix = nodes.new('ShaderNodeMixShader')
    links.new(mask.outputs[0], mix.inputs[0])
    links.new(nodes.new('ShaderNodeBsdfTransparent').outputs[0], mix.inputs[1])
    links.new(emission.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs['Surface'])

# ------------------------------------------------------------------ camera
portrait = a['aspect'] >= 0.5
aspect = 9 / 16 if portrait else 16 / 9
frame_width = 2.35 * max(W / max(W, H), aspect * H / max(W, H))
# Blender fits the orthographic scale to the longer output axis.
frame_scale = frame_width / min(1, aspect) if portrait or a['photo'] > 0 else 2.35 * 16 / 9

cam_data = bpy.data.cameras.new('Camera')
cam_data.type = 'ORTHO'
cam_data.ortho_scale = frame_scale
cam = bpy.data.objects.new('Camera', cam_data)
scene.collection.objects.link(cam)
cam.location = (0, -10, 0)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam
drift = a.get('drift', 0.2)
if drift > 0.01:
    cam_data.ortho_scale = frame_scale * (1 + 0.12 * drift)
    cam_data.keyframe_insert('ortho_scale', frame=1)
    cam_data.ortho_scale = frame_scale
    cam_data.keyframe_insert('ortho_scale', frame=frames)

# ------------------------------------------------------- bloom (if allowed)
if glow > 0.02 and use_bloom:
    try:
        tree = getattr(scene, 'compositing_node_group', None)
        if hasattr(scene, 'compositing_node_group'):
            tree = bpy.data.node_groups.new('Bloom', 'CompositorNodeTree')
            scene.compositing_node_group = tree
            rl = tree.nodes.new('CompositorNodeRLayers')
            out = tree.nodes.new('NodeGroupOutput')
            tree.interface.new_socket('Image', in_out='OUTPUT', socket_type='NodeSocketColor')
        else:
            scene.use_nodes = True
            tree = scene.node_tree
            rl = next(n for n in tree.nodes if n.type == 'R_LAYERS')
            out = next(n for n in tree.nodes if n.type == 'COMPOSITE')
        g = tree.nodes.new('CompositorNodeGlare')
        typ = g.inputs.get('Type')
        for v_ in ('Bloom', 'BLOOM', 'Fog Glow', 'FOG_GLOW'):
            try:
                if typ is not None: typ.default_value = v_
                else: g.glare_type = v_
                break
            except Exception: pass
        for name, val in (('Threshold', 0.55), ('Strength', 0.12 + 0.45 * glow), ('Size', 0.6)):
            sock = g.inputs.get(name)
            if sock is not None:
                try: sock.default_value = val
                except Exception: pass
        tree.links.new(rl.outputs['Image'], g.inputs['Image'])
        tree.links.new(g.outputs['Image'], out.inputs[0])
        try: scene.render.use_compositing = True
        except Exception: pass
        print('Bloom:', g.inputs['Type'].default_value if 'Type' in g.inputs else getattr(g, 'glare_type', None), file=sys.stderr)
    except Exception as e:
        print('Bloom skipped:', e, file=sys.stderr)

# ----------------------------------------------------------------- render
scene.frame_start = 1
scene.frame_end = frames
scene.render.fps = fps
for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = engine; break
    except TypeError:
        pass
samples = min(32, round(8 + 120 * a['aa'])) if preview else round(8 + 120 * a['aa'])
if hasattr(scene.eevee, 'taa_render_samples'):
    scene.eevee.taa_render_samples = samples
scene.view_settings.exposure = 4 * (a['exposure'] - 0.5)
for vt in ('Standard', 'sRGB'):
    try:
        scene.view_settings.view_transform = vt; break
    except Exception: pass
try: scene.view_settings.look = 'None'
except Exception: pass
print('Colour:', scene.view_settings.view_transform, scene.view_settings.look, file=sys.stderr)
size = (640, 360) if preview else [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)][round(a['resolution'] * 3)]
scene.render.resolution_x, scene.render.resolution_y = size[::-1] if portrait else size
print(f'Output size: {scene.render.resolution_x}×{scene.render.resolution_y}', file=sys.stderr)
scene.render.resolution_percentage = 100
im = scene.render.image_settings
if a.get('stills'):
    im.file_format = 'PNG'
else:
    if hasattr(im, 'media_type'):
        im.media_type = 'VIDEO'
    im.file_format = 'FFMPEG'
    ff = scene.render.ffmpeg
    ff.format = 'MPEG4'
    ff.codec = 'H264'
    try:
        ff.constant_rate_factor = 'HIGH'
        ff.ffmpeg_preset = 'REALTIME' if preview else 'GOOD'
    except Exception: pass
if a.get('stills'):
    scene.frame_set(frames)
    scene.render.filepath = a['out'] + '.png'
    bpy.ops.render.render(write_still=True)
    try:
        im2 = bpy.data.images.load(a['out'] + '.png')
        pxs = np.array(im2.pixels[:], dtype=np.float32).reshape(-1, 4)[:, :3]
        print('Brightest pixel:', np.round(pxs.max(axis=0), 3), 'background:', np.round(pxs[0], 3), 'engine:', scene.render.engine, file=sys.stderr)
    except Exception as e:
        print('Measure failed:', e, file=sys.stderr)
else:
    scene.render.filepath = a['out']
    bpy.ops.render.render(animation=True)
"""#
}
