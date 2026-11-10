import Foundation

/// Animation: builds a planet scene in Blender (run in the background) and renders a short MP4.
/// The goal can name a song (it pulses to the music, and the song is in the clip) and a planet image
/// (wrapped around the planet). With no song, it pulses to a steady 90 BPM; with no image, the surface
/// is procedural. Dials map straight onto spin, beat, glow, mood, camera drift and length.
public struct BlenderAnimationAdapter: DomainAdapter {
    public let id = "animate"
    public let name = "Animation (Blender)"
    public let symbol = "globe.americas"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .video, editable: false, exportFormats: ["mp4"])
    public let dialHint = "spin speed, beat strength, glow, mood, camera drift, length"

    public static let audioExtensions = ["wav", "mp3", "m4a", "aif", "aiff", "flac", "ogg"]
    public static let imageExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "exr", "hdr"]

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        [Dial(name: "Spin speed", detail: "How fast the planet turns.", lowPole: "slow drift", highPole: "fast spin", value: 30),
         Dial(name: "Beat strength", detail: "How hard the planet and its glow pulse with the music.", lowPole: "subtle", highPole: "punchy", value: 60),
         Dial(name: "Glow", detail: "Brightness of the atmosphere around the planet.", lowPole: "faint", highPole: "blazing", value: 50),
         Dial(name: "Mood", detail: "Colors of the planet and its light.", lowPole: "warm fire", highPole: "cool ice", value: 40),
         Dial(name: "Camera drift", detail: "How far the camera moves in and around during the clip.", lowPole: "still", highPole: "sweeping", value: 30),
         Dial(name: "Length", detail: "Clip length for full renders. Previews are always 2 seconds.", lowPole: "2 seconds", highPole: "10 seconds", value: 25)]
    }

    /// The song and planet image named in the goal (each path on its own or among words), and the remaining words.
    public static func files(in goal: String) -> (audio: String?, texture: String?, words: String) {
        let exts = (audioExtensions + imageExtensions).joined(separator: "|")
        let pattern = "(?<![^\\s\"'])((?:~|/)[^\\n\"']*?\\.(?:\(exts)))(?![^\\s\"'])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (nil, nil, goal.trimmed)
        }
        let ns = goal as NSString
        var audio: String?
        var texture: String?
        var words = goal
        for match in re.matches(in: goal, range: NSRange(location: 0, length: ns.length)).reversed() {
            let raw = ns.substring(with: match.range(at: 1))
            let path = NSString(string: raw).expandingTildeInPath
            let ext = (path as NSString).pathExtension.lowercased()
            if audioExtensions.contains(ext) { audio = path } else { texture = path }
            words = (words as NSString).replacingCharacters(in: match.range(at: 1), with: "")
        }
        let cleaned = words.components(separatedBy: .newlines).map(\.trimmed).filter { !$0.isEmpty }.joined(separator: "\n")
        return (audio, texture, cleaned)
    }

    /// Scene parameters (0...1) read from dials by name, in a fixed order so output is deterministic.
    public static func parameters(_ input: CompileInput) -> [String: Any] {
        func v(_ key: String, _ fallback: Double) -> Double {
            (input.state.dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback) / 100
        }
        let f = files(in: input.state.goal)
        return ["spin": v("spin", 30), "beat": v("beat", 60), "glow": v("glow", 50), "mood": v("mood", 40),
                "drift": v("drift", 30), "length": v("length", 25), "quality": input.quality.rawValue,
                "audio": f.audio ?? "", "texture": f.texture ?? ""]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let data = (try? JSONSerialization.data(withJSONObject: Self.parameters(input), options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CompiledRequest(input: input, text: TextRequest(system: "blender-animation", user: json, maxTokens: 0),
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
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use Animation.")
        }
        let f = Self.files(in: request.input.state.goal)
        for path in [f.audio, f.texture].compactMap({ $0 }) where !FileManager.default.fileExists(atPath: path) {
            throw PrismError.local("This file wasn't found: \(path)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrismAnimation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("animate.py")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        var params = Self.parameters(request.input)
        params["out"] = dir.appendingPathComponent("clip").path
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

        // Blender adds the frame range to the name (clip0001-0048.mp4), so take whichever MP4 it wrote.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let name = files.first(where: { $0.lowercased().hasSuffix(".mp4") }),
              let mp4 = try? Data(contentsOf: dir.appendingPathComponent(name)), !mp4.isEmpty else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't produce a clip. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(300))")
        }
        let song = f.audio.map { "pulsing to \(($0 as NSString).lastPathComponent)" } ?? "pulsing at 90 BPM (no song chosen)"
        let surface = f.texture.map { "planet image \(($0 as NSString).lastPathComponent)" } ?? "procedural surface"
        return Generated(output: Output(kind: .video, text: "Spinning planet, \(song), \(surface).",
                                        provider: "Blender",
                                        model: request.input.quality == .preview ? "Eevee preview · 2 s" : "Eevee render",
                                        agent: "Animation"),
                         asset: mp4, assetExtension: "mp4")
    }

    /// Runs inside Blender. Builds the planet scene from the parameters and renders an MP4 (with the song, if any).
    static let script = #"""
import bpy, sys, json, math, os
from mathutils import Vector
a = json.loads(sys.argv[sys.argv.index('--') + 1])
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
preview = a['quality'] == 'preview'
fps = 12 if preview else 24
seconds = 2.0 if preview else 2.0 + a['length'] * 8.0

# --- Song: read it and turn its loudness into a pulse per frame ---
audio = a.get('audio') or ''
samples, rate = None, 0
if audio and os.path.exists(audio):
    try:
        import aud, numpy as np
        snd = aud.Sound(audio)
        rate = int(snd.specs[0])
        samples = np.asarray(snd.data(), dtype=np.float32)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        if not preview:
            seconds = min(seconds, max(1.0, len(samples) / rate))
    except Exception as e:
        print('Could not read the song:', e, file=sys.stderr)
        samples = None
frames = max(2, int(round(seconds * fps)))

def pulse_from_song():
    import numpy as np
    hop = max(1, int(rate / fps))
    rms = []
    for i in range(frames):
        chunk = samples[i * hop:(i + 1) * hop]
        rms.append(float(np.sqrt(np.mean(chunk * chunk))) if len(chunk) else 0.0)
    peak = float(np.percentile(rms, 95)) or 1.0
    return [min(1.0, x / peak) for x in rms]

def steady_pulse(bpm=90.0):
    beat = 60.0 / bpm
    return [math.exp(-((i / fps) % beat) * 8.0) for i in range(frames)]

level = pulse_from_song() if samples is not None else steady_pulse()
decay = 0.5 ** (1.0 / (fps * 0.12))  # hits snap up, then fade with a 0.12 s half-life
env, prev = [], 0.0
for x in level:
    prev = max(x * x, prev * decay)
    env.append(prev)

# --- Colors from mood (0 warm fire, 1 cool ice) ---
m = a['mood']
def mix(w, c):
    return tuple(w[i] + (c[i] - w[i]) * m for i in range(3)) + (1.0,)
deep = mix((0.25, 0.04, 0.02), (0.02, 0.06, 0.22))
mid = mix((0.85, 0.32, 0.06), (0.10, 0.45, 0.70))
light = mix((1.00, 0.80, 0.35), (0.75, 0.95, 1.00))
rim = mix((1.00, 0.55, 0.20), (0.40, 0.75, 1.00))

# --- Planet ---
bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=1.0, location=(0, 0, 0))
planet = bpy.context.object
planet.name = 'Planet'
bpy.ops.object.shade_smooth()
planet.rotation_mode = 'ZYX'  # spin around the planet's own tilted axis
tilt = math.radians(20)
mat = bpy.data.materials.new('Planet'); mat.use_nodes = True
nt = mat.node_tree
bsdf = nt.nodes['Principled BSDF']
bsdf.inputs['Roughness'].default_value = 0.7
texture = a.get('texture') or ''
if texture and os.path.exists(texture):
    tex = nt.nodes.new('ShaderNodeTexImage')
    tex.image = bpy.data.images.load(texture)
    color = tex.outputs['Color']
else:
    noise = nt.nodes.new('ShaderNodeTexNoise')
    noise.inputs['Scale'].default_value = 2.5
    noise.inputs['Detail'].default_value = 10.0
    ramp = nt.nodes.new('ShaderNodeValToRGB')
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.35, deep
    els[1].position, els[1].color = 0.70, light
    e = els.new(0.52); e.color = mid
    nt.links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
    color = ramp.outputs['Color']
nt.links.new(color, bsdf.inputs['Base Color'])
emit_color = bsdf.inputs.get('Emission Color') or bsdf.inputs.get('Emission')
emit_strength = bsdf.inputs.get('Emission Strength')
if emit_color is not None:
    nt.links.new(color, emit_color)
planet.data.materials.append(mat)

# --- Atmosphere: a glowing rim that brightens on each beat ---
bpy.ops.mesh.primitive_uv_sphere_add(segments=96, ring_count=48, radius=1.06, location=(0, 0, 0))
atmo = bpy.context.object
atmo.name = 'Atmosphere'
bpy.ops.object.shade_smooth()
atmo.parent = planet
for attr in ('visible_shadow',):
    try: setattr(atmo, attr, False)
    except Exception: pass
amat = bpy.data.materials.new('Atmosphere'); amat.use_nodes = True
an = amat.node_tree
for n in list(an.nodes):
    if n.type != 'OUTPUT_MATERIAL': an.nodes.remove(n)
out = next(n for n in an.nodes if n.type == 'OUTPUT_MATERIAL')
lw = an.nodes.new('ShaderNodeLayerWeight'); lw.inputs['Blend'].default_value = 0.35
power = an.nodes.new('ShaderNodeMath'); power.operation = 'POWER'; power.inputs[1].default_value = 2.0
clear = an.nodes.new('ShaderNodeBsdfTransparent')
glow = an.nodes.new('ShaderNodeEmission'); glow.inputs['Color'].default_value = rim
mixer = an.nodes.new('ShaderNodeMixShader')
an.links.new(lw.outputs['Facing'], power.inputs[0])
an.links.new(power.outputs[0], mixer.inputs['Fac'])
an.links.new(clear.outputs[0], mixer.inputs[1])
an.links.new(glow.outputs[0], mixer.inputs[2])
an.links.new(mixer.outputs[0], out.inputs['Surface'])
try: amat.surface_render_method = 'BLENDED'
except Exception:
    try: amat.blend_method = 'BLEND'
    except Exception: pass
atmo.data.materials.append(amat)

# --- Stars ---
world = bpy.data.worlds.new('Space'); scene.world = world; world.use_nodes = True
wn = world.node_tree
bg = wn.nodes['Background']
coords = wn.nodes.new('ShaderNodeTexCoord')
vor = wn.nodes.new('ShaderNodeTexVoronoi'); vor.inputs['Scale'].default_value = 150.0
stars = wn.nodes.new('ShaderNodeValToRGB')
se = stars.color_ramp.elements
se[0].position, se[0].color = 0.0, (1, 1, 1, 1)
se[1].position, se[1].color = 0.07, (0, 0, 0, 1)
wn.links.new(coords.outputs['Generated'], vor.inputs['Vector'])
wn.links.new(vor.outputs['Distance'], stars.inputs['Fac'])
wn.links.new(stars.outputs['Color'], bg.inputs['Color'])
bg.inputs['Strength'].default_value = 0.8

# --- Sun ---
sun_data = bpy.data.lights.new('Sun', 'SUN'); sun_data.energy = 4.0; sun_data.color = light[:3]
sun = bpy.data.objects.new('Sun', sun_data); scene.collection.objects.link(sun)
sun.rotation_euler = (math.radians(55), 0, math.radians(65))

# --- Camera ---
target = bpy.data.objects.new('Target', None); scene.collection.objects.link(target)
cam_data = bpy.data.cameras.new('Camera'); cam_data.lens = 50
cam = bpy.data.objects.new('Camera', cam_data); scene.collection.objects.link(cam)
c = cam.constraints.new('TRACK_TO'); c.target = target; c.track_axis = 'TRACK_NEGATIVE_Z'; c.up_axis = 'UP_Y'
scene.camera = cam

# --- Keyframes, one per frame ---
spin_rate = math.radians(5 + a['spin'] * 85)  # 5 to 90 degrees per second
drift = a['drift']
for i in range(frames):
    f = i + 1
    t = i / fps
    p = i / max(1, frames - 1)
    e = env[i]
    planet.rotation_euler = (tilt, 0.0, spin_rate * t)
    planet.keyframe_insert('rotation_euler', frame=f)
    s = 1.0 + a['beat'] * 0.12 * e
    planet.scale = (s, s, s)
    planet.keyframe_insert('scale', frame=f)
    if emit_strength is not None:
        emit_strength.default_value = a['glow'] * (0.1 + 1.2 * a['beat'] * e)
        emit_strength.keyframe_insert('default_value', frame=f)
    glow.inputs['Strength'].default_value = 1.0 + a['glow'] * 6.0 + a['beat'] * e * 8.0
    glow.inputs['Strength'].keyframe_insert('default_value', frame=f)
    dist = 8.0 * (1.0 - 0.25 * drift * p)
    ang = math.radians(-15 + 35 * drift * p)
    cam.location = Vector((dist * math.sin(ang), -dist * math.cos(ang), 1.2 + 0.8 * drift * p))
    cam.keyframe_insert('location', frame=f)

# --- Bloom, where this Blender version's compositor allows it ---
try:
    scene.use_nodes = True
    tree = scene.node_tree
    rl = next(n for n in tree.nodes if n.type == 'R_LAYERS')
    comp = next(n for n in tree.nodes if n.type == 'COMPOSITE')
    g = tree.nodes.new('CompositorNodeGlare')
    for key, value in (('glare_type', 'FOG_GLOW'), ('threshold', 0.7), ('size', 8)):
        try: setattr(g, key, value)
        except Exception:
            sock = g.inputs.get(key.replace('_', ' ').title())
            if sock is not None and not isinstance(value, str): sock.default_value = value
    tree.links.new(rl.outputs['Image'], g.inputs['Image'])
    tree.links.new(g.outputs['Image'], comp.inputs['Image'])
except Exception as e:
    print('Bloom skipped:', e, file=sys.stderr)

# --- Render settings ---
scene.frame_start = 1
scene.frame_end = frames
scene.render.fps = fps
for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
    try:
        scene.render.engine = engine; break
    except TypeError:
        pass
try: scene.eevee.taa_render_samples = 8 if preview else 32
except Exception: pass
scene.render.resolution_x, scene.render.resolution_y = (640, 360) if preview else (1280, 720)
scene.render.resolution_percentage = 100
img = scene.render.image_settings
try: img.media_type = 'VIDEO'
except Exception: pass
img.file_format = 'FFMPEG'
ff = scene.render.ffmpeg
ff.format = 'MPEG4'
ff.codec = 'H264'
try:
    ff.constant_rate_factor = 'MEDIUM' if preview else 'HIGH'
    ff.ffmpeg_preset = 'REALTIME' if preview else 'GOOD'
except Exception: pass
if samples is not None:
    seq = scene.sequence_editor_create()
    strips = getattr(seq, 'strips', None)
    if strips is None:
        strips = seq.sequences
    strips.new_sound('Song', audio, 1, 1)
    ff.audio_codec = 'AAC'
    ff.audio_bitrate = 192
scene.render.filepath = a['out']
bpy.ops.render.render(animation=True)
"""#
}
