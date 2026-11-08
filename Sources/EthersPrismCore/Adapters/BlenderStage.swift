import Foundation

/// 3D Stage: stages a model file in Blender (run in the background) and renders it.
/// The goal is the path to a GLB, GLTF, OBJ or FBX file; with no file, a sample model is used.
/// Dials map straight onto camera, lens and lighting, so the same dials always give the same render.
public struct BlenderStageAdapter: DomainAdapter {
    public let id = "stage"
    public let name = "3D Stage (Blender)"
    public let symbol = "cube"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .image, editable: false, exportFormats: ["png"])
    public let dialHint = "camera orbit, camera height, lens, lighting contrast, mood"

    public static var blenderPath = "/Applications/Blender.app/Contents/MacOS/Blender"

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        [Dial(name: "Camera orbit", detail: "Where the camera circles around the model.", lowPole: "front", highPole: "all the way around", value: 10),
         Dial(name: "Camera height", detail: "Looking up at or down on the model.", lowPole: "low, looking up", highPole: "high, looking down", value: 35),
         Dial(name: "Lens", detail: "Field of view.", lowPole: "wide 18 mm", highPole: "telephoto 135 mm", value: 35),
         Dial(name: "Lighting contrast", detail: "Soft studio light or dramatic shadows.", lowPole: "soft and even", highPole: "dramatic", value: 50),
         Dial(name: "Mood", detail: "Color temperature of the light.", lowPole: "warm", highPole: "cool", value: 40)]
    }

    /// The model path from the goal, if it names a file.
    public static func modelPath(from goal: String) -> String? {
        var p = goal.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if p.hasPrefix("~") { p = NSString(string: p).expandingTildeInPath }
        let ext = (p as NSString).pathExtension.lowercased()
        return ["glb", "gltf", "obj", "fbx"].contains(ext) ? p : nil
    }

    /// Scene parameters (0...1) read from dials by name, in a fixed order so output is deterministic.
    public static func parameters(_ input: CompileInput) -> [String: Any] {
        func v(_ key: String, _ fallback: Double) -> Double {
            (input.state.dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback) / 100
        }
        return ["orbit": v("orbit", 10), "height": v("height", 35), "lens": v("lens", 35),
                "light": v("light", 50), "mood": v("mood", 40),
                "quality": input.quality.rawValue, "model": modelPath(from: input.state.goal) ?? ""]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let data = (try? JSONSerialization.data(withJSONObject: Self.parameters(input), options: [.sortedKeys])) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return CompiledRequest(input: input, text: TextRequest(system: "blender-stage", user: json, maxTokens: 0),
                               seed: Compiler.seed(for: json))
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request)
    }

    private func run(_ request: CompiledRequest) async throws -> Generated {
        guard FileManager.default.isExecutableFile(atPath: Self.blenderPath) else {
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use the 3D Stage.")
        }
        if let m = Self.modelPath(from: request.input.state.goal), !FileManager.default.fileExists(atPath: m) {
            throw PrismError.local("The model file wasn't found: \(m)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrismStage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("stage.py")
        let out = dir.appendingPathComponent("render.png")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        var params = Self.parameters(request.input)
        params["out"] = out.path
        let args = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.blenderPath)
        process.arguments = ["-b", "--factory-startup", "--python", script.path, "--", args]
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        guard let png = try? Data(contentsOf: out) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PrismError.local("Blender didn't produce an image. \(err.suffix(300))")
        }
        let model = Self.modelPath(from: request.input.state.goal).map { ($0 as NSString).lastPathComponent } ?? "sample model"
        return Generated(output: Output(kind: .image, provider: "Blender",
                                        model: request.input.quality == .preview ? "Eevee preview" : "Cycles render",
                                        agent: "3D Stage · \(model)"),
                         asset: png, assetExtension: "png")
    }

    /// Runs inside Blender. Builds the scene from the parameters and renders one still.
    static let script = #"""
import bpy, sys, json, math, os
from mathutils import Vector
a = json.loads(sys.argv[sys.argv.index('--') + 1])
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
path = a.get('model') or ''
if path and os.path.exists(path):
    ext = path.lower().rsplit('.', 1)[-1]
    if ext in ('glb', 'gltf'):
        bpy.ops.import_scene.gltf(filepath=path)
    elif ext == 'obj':
        bpy.ops.wm.obj_import(filepath=path)
    elif ext == 'fbx':
        bpy.ops.import_scene.fbx(filepath=path)
else:
    bpy.ops.mesh.primitive_monkey_add(location=(0, 0, 1))
    o = bpy.context.object
    o.modifiers.new('smooth', 'SUBSURF').levels = 2
    bpy.ops.object.shade_smooth()
    mat = bpy.data.materials.new('clay'); mat.use_nodes = True
    mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.8, 0.45, 0.25, 1)
    o.data.materials.append(mat)
meshes = [o for o in scene.objects if o.type == 'MESH']
pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box] or [Vector((0, 0, 0))]
mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
center = (mn + mx) / 2
radius = max((mx - mn).length / 2, 0.5)
bpy.ops.mesh.primitive_plane_add(size=radius * 40, location=(center.x, center.y, mn.z))
target = bpy.data.objects.new('target', None); target.location = center; scene.collection.objects.link(target)
lens = 18 + a['lens'] * 117
fov = 2 * math.atan(18 / lens)
dist = radius / math.tan(fov / 2) * 1.25
theta = math.radians(a['orbit'] * 360)
el = math.radians(-10 + a['height'] * 70)
cam_data = bpy.data.cameras.new('cam'); cam_data.lens = lens
cam = bpy.data.objects.new('cam', cam_data); scene.collection.objects.link(cam)
cam.location = center + Vector((dist * math.cos(el) * math.sin(theta), -dist * math.cos(el) * math.cos(theta), dist * math.sin(el)))
c = cam.constraints.new('TRACK_TO'); c.target = target; c.track_axis = 'TRACK_NEGATIVE_Z'; c.up_axis = 'UP_Y'
scene.camera = cam
m = a['mood']
warm, cool = Vector((1.0, 0.82, 0.65)), Vector((0.68, 0.82, 1.0))
key_color = warm.lerp(cool, m)
contrast = a['light']
def area(name, loc, energy, size, color):
    d = bpy.data.lights.new(name, 'AREA'); d.energy = energy; d.size = size; d.color = color
    o = bpy.data.objects.new(name, d); o.location = loc; scene.collection.objects.link(o)
    t = o.constraints.new('TRACK_TO'); t.target = target; t.track_axis = 'TRACK_NEGATIVE_Z'; t.up_axis = 'UP_Y'
r2 = radius * radius
area('key', center + Vector((radius * 3, -radius * 3, radius * 4)), (400 + 1600 * contrast) * r2, radius * (4 - 3.2 * contrast), key_color)
area('fill', center + Vector((-radius * 4, -radius * 2, radius * 2)), (500 * (1 - contrast) + 30) * r2, radius * 4, cool.lerp(warm, m))
area('rim', center + Vector((0, radius * 4, radius * 3)), 500 * r2, radius * 2, (1, 1, 1))
world = bpy.data.worlds.new('world'); scene.world = world; world.use_nodes = True
world.node_tree.nodes['Background'].inputs['Color'].default_value = (*(key_color * (0.05 + 0.15 * (1 - contrast))), 1)
preview = a['quality'] == 'preview'
if preview:
    for engine in ('BLENDER_EEVEE_NEXT', 'BLENDER_EEVEE'):
        try:
            scene.render.engine = engine; break
        except TypeError:
            pass
    scene.render.resolution_x = scene.render.resolution_y = 512
else:
    scene.render.engine = 'CYCLES'
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'; prefs.get_devices()
        for d in prefs.devices: d.use = True
        scene.cycles.device = 'GPU'
    except Exception:
        pass
    scene.cycles.samples = 64
    scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.filepath = a['out']
bpy.ops.render.render(write_still=True)
"""#
}
