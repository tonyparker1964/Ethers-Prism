import Foundation

/// Blender Script: runs a Blender Python script (usually written by Claude) in Blender in the
/// background. Preview renders one frame; Render Full Quality renders the whole animation as MP4
/// (or a still picture when the scene has one frame). Every script is kept in a library folder.
public struct BlenderScriptAdapter: DomainAdapter {
    public let id = "blenderscript"
    public let name = "Blender Script (from Claude)"
    public let symbol = "chevron.left.forwardslash.chevron.right"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .video, editable: false, exportFormats: ["mp4", "png"])
    public let dialHint = "preview frame, render quality"

    /// Scripts (and their full renders) are kept here.
    public static var libraryFolder = NSString(string: "~/Documents/Ethers Prism Exports/Blender Scripts").expandingTildeInPath

    public init() {}

    public static let dials: [Dial] = [
        Dial(name: "Preview frame", detail: "Which moment of the animation the preview picture shows.", lowPole: "start", highPole: "end", value: 50),
        Dial(name: "Render quality", detail: "More samples look smoother but take longer.", lowPole: "fast", highPole: "best", value: 50)]

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] { Self.dials }

    // MARK: - Recognising and saving scripts

    /// True when the text looks like a Blender Python script.
    /// It must import bpy on a line of its own, so ordinary text that mentions bpy isn't picked up.
    public static func looksLikeScript(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let l = line.trimmed
            return l.hasPrefix("from bpy") || (l.hasPrefix("import ") && l.components(separatedBy: CharacterSet(charactersIn: " ,")).contains("bpy"))
        }
    }

    /// A Claude reply copied whole may wrap the script in a ``` fence; keep only the code.
    public static func extractScript(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "```(?:python|py)?[ \\t]*\\n([\\s\\S]*?)```"),
              let m = re.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .first(where: { m in Range(m.range(at: 1), in: text).map { looksLikeScript(String(text[$0])) } ?? false }),
              let r = Range(m.range(at: 1), in: text) else { return text.trimmed + "\n" }
        return String(text[r]).trimmed + "\n"
    }

    /// The script's title: a "# Title:" line, else its first comment, else "Blender script".
    public static func title(of script: String) -> String {
        let lines = script.components(separatedBy: .newlines).map(\.trimmed)
        if let t = lines.first(where: { $0.lowercased().hasPrefix("# title:") }) {
            let v = String(t.dropFirst("# title:".count)).trimmed
            if !v.isEmpty { return String(v.prefix(60)) }
        }
        for l in lines.prefix(15) where l.hasPrefix("#") && !l.hasPrefix("#!") {
            let v = l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).trimmed
            if v.count > 2, !v.lowercased().hasPrefix("-*-") { return String(v.prefix(60)) }
        }
        return "Blender script"
    }

    /// Saves the script in the library (once per distinct script) and returns its path.
    @discardableResult
    public static func saveToLibrary(_ script: String, date: Date = Date()) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: libraryFolder, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: libraryFolder)) ?? [] where f.hasSuffix(".py") {
            let p = (libraryFolder as NSString).appendingPathComponent(f)
            if let existing = try? String(contentsOfFile: p, encoding: .utf8), existing == script { return p }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title(of: script).components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        var path = (libraryFolder as NSString).appendingPathComponent("\(df.string(from: date)) \(safe).py")
        var n = 2
        while fm.fileExists(atPath: path) {
            path = (libraryFolder as NSString).appendingPathComponent("\(df.string(from: date)) \(safe) \(n).py")
            n += 1
        }
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// Library scripts, newest first.
    public static func library() -> [String] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: libraryFolder)) ?? []).filter { $0.hasSuffix(".py") }
        return files.map { (libraryFolder as NSString).appendingPathComponent($0) }.sorted { a, b in
            let da = (try? fm.attributesOfItem(atPath: a)[.modificationDate] as? Date) ?? .distantPast
            let db = (try? fm.attributesOfItem(atPath: b)[.modificationDate] as? Date) ?? .distantPast
            return da > db
        }
    }

    /// Prism does the rendering, so the script's own render and quit calls are switched off.
    public static func sanitized(_ script: String) -> String {
        script.replacingOccurrences(of: "bpy.ops.render.render(", with: "_prism_skip(")
            .replacingOccurrences(of: "bpy.ops.wm.quit_blender(", with: "_prism_skip(")
    }

    /// Opens the script in Blender's window (not in the background) so it can be tweaked by hand.
    public static func openInBlender(_ script: String) throws {
        let blender = BlenderStageAdapter.blenderPath
        guard FileManager.default.isExecutableFile(atPath: blender) else {
            throw PrismError.local("Blender wasn't found in /Applications.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrism Open in Blender")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(UUID().uuidString.prefix(8)).py")
        try ("def _prism_skip(*a, **k):\n    return {'CANCELLED'}\n\n" + sanitized(script)).write(to: path, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: blender)
        p.arguments = ["--python", path.path]
        try p.run()
    }

    // MARK: - Running

    public static func parameters(_ input: CompileInput) -> [String: Any] {
        func v(_ key: String, _ fallback: Double) -> Double {
            (input.state.dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback) / 100
        }
        return ["frame": v("frame", 50), "quality": v("quality", 50), "preview": input.quality == .preview]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let data = (try? JSONSerialization.data(withJSONObject: Self.parameters(input), options: [.sortedKeys])) ?? Data()
        let json = (String(data: data, encoding: .utf8) ?? "{}") + "\n" + input.state.goal
        return CompiledRequest(input: input, text: TextRequest(system: "blender-script", user: json, maxTokens: 0),
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
            throw PrismError.local("Blender wasn't found in /Applications. Install Blender to use Blender Script.")
        }
        let source = Self.extractScript(request.input.state.goal)
        guard Self.looksLikeScript(source) else {
            throw PrismError.local("Copy a Blender script from Claude (it starts with import bpy) and Prism will fill it in here.")
        }
        let preview = request.input.quality == .preview
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EthersPrismScript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = dir.appendingPathComponent("user_script.py")
        try Self.sanitized(source).write(to: user, atomically: true, encoding: .utf8)
        let runner = dir.appendingPathComponent("runner.py")
        try Self.runner.write(to: runner, atomically: true, encoding: .utf8)

        var params = Self.parameters(request.input)
        params["script"] = user.path
        params["out"] = dir.appendingPathComponent("render").path
        params["error"] = dir.appendingPathComponent("error.txt").path
        let args = String(data: try JSONSerialization.data(withJSONObject: params), encoding: .utf8) ?? "{}"

        let log = dir.appendingPathComponent("blender.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: blender)
        process.arguments = ["-b", "--factory-startup", "--python", runner.path, "--", args]
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

        if let err = try? String(contentsOf: dir.appendingPathComponent("error.txt"), encoding: .utf8), !err.trimmed.isEmpty {
            throw PrismError.local("The script stopped with an error. Press Copy Error and paste it into Claude to fix it.\n\n\(err.trimmed.suffix(1500))")
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let info = text.components(separatedBy: .newlines).first { $0.hasPrefix("PRISM:") }?
            .replacingOccurrences(of: "PRISM: ", with: "") ?? ""
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let title = Self.title(of: source)

        if let name = files.first(where: { $0.lowercased().hasSuffix(".mp4") }),
           let mp4 = try? Data(contentsOf: dir.appendingPathComponent(name)), !mp4.isEmpty {
            let kept = Self.keepRender(mp4, title: title, ext: "mp4")
            return Generated(output: Output(kind: .video, text: "\(title). \(info)" + (kept.map { " Saved: \($0)" } ?? ""),
                                            provider: "Blender", model: "Full render", agent: "Blender Script"),
                             asset: mp4, assetExtension: "mp4")
        }
        guard let png = try? Data(contentsOf: dir.appendingPathComponent("render.png")), !png.isEmpty else {
            let errors = text.components(separatedBy: .newlines).filter { $0.contains("Error") || $0.contains("rror:") }
            throw PrismError.local("Blender didn't produce a picture. \((errors.isEmpty ? text : errors.joined(separator: " ")).suffix(400))")
        }
        let kept = preview ? nil : Self.keepRender(png, title: title, ext: "png")
        return Generated(output: Output(kind: .image, text: "\(title). \(info)" + (kept.map { " Saved: \($0)" } ?? ""),
                                        provider: "Blender", model: preview ? "Preview frame" : "Full render",
                                        agent: "Blender Script"),
                         asset: png, assetExtension: "png")
    }

    /// Full renders are also kept next to the scripts.
    private static func keepRender(_ data: Data, title: String, ext: String) -> String? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HHmmss"
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?*\"<>|")).joined(separator: "-")
        let path = (libraryFolder as NSString).appendingPathComponent("\(df.string(from: Date())) \(safe).\(ext)")
        try? FileManager.default.createDirectory(atPath: libraryFolder, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil ? path : nil
    }

    /// Text for a Claude project's instructions, so Claude writes scripts that suit this field.
    public static let claudeInstructions = """
    I use Blender 5.2.2 on a Mac mini M4 (24 GB) and an app called Ethers Prism that runs your scripts. When I ask for something, reply with ONE complete Python script in a single ```python code block.

    Script rules:
    - First line: # Title: <short name for the scene>
    - Start by clearing the scene, then build everything: objects, materials, lights, camera (set scene.camera), animation (scene.frame_start / frame_end), world and render settings.
    - Don't call bpy.ops.render.render or quit Blender; Prism does the rendering (a quick preview frame, then the full MP4).
    - Use EEVEE (scene.render.engine = 'BLENDER_EEVEE_NEXT', fall back to 'BLENDER_EEVEE'), 1920x1080, 24 fps, unless I say otherwise.
    - Grease Pencil (v3 API): bpy.data.grease_pencils_v3 if it exists, else bpy.data.grease_pencils. Drawings via layer.frames.new(frame).drawing, drawing.add_strokes(sizes); point data through attributes['position'/'radius'/'opacity'/'vertex_color'] with foreach_set.
    - ALWAYS set layer.use_lights = False on Grease Pencil layers (otherwise lines render dim).
    - Glow/bloom: compositor via scene.compositing_node_group = bpy.data.node_groups.new(name, 'CompositorNodeTree') with a Glare node; set glare.inputs['Type'].default_value = 'Bloom'.
    - Wrap risky API calls in try/except so the script doesn't stop halfway.
    - Aim for professional quality: good lighting, smooth eased camera moves, clean materials, a strong composition.
    - After the code block, tell me in 2-3 lines what it makes and which values to change to adjust it.
    - If I paste an error or a screenshot, fix the script and give me the whole script again.
    """

    /// Runs inside Blender: runs the user's script, then renders a preview frame or the full animation.
    static let runner = #"""
import bpy, sys, json, math, traceback

a = json.loads(sys.argv[sys.argv.index('--') + 1])

def _prism_skip(*args, **kwargs):
    return {'CANCELLED'}

src = open(a['script'], encoding='utf-8').read()
g = {'__name__': '__main__', '__file__': a['script'], '_prism_skip': _prism_skip}
try:
    exec(compile(src, 'script.py', 'exec'), g)
except Exception:
    tb = traceback.format_exc()
    # Keep only the part about the user's script.
    lines = tb.splitlines()
    # Leave out Prism's own lines: the runner's frame and the ~~~^^^ markers under it.
    keep = []
    skip = False
    for l in lines:
        if 'runner.py' in l:
            skip = True
            continue
        if skip and (l.strip().startswith('exec(') or set(l.strip()) <= set('~^ ')):
            continue
        skip = False
        keep.append(l)
    open(a['error'], 'w', encoding='utf-8').write('\n'.join(keep))
    sys.exit(0)

scene = bpy.context.scene

# A camera is needed to render; add one looking at the scene if the script made none.
if scene.camera is None:
    cams = [o for o in scene.objects if o.type == 'CAMERA']
    if cams:
        scene.camera = cams[0]
    else:
        cd = bpy.data.cameras.new('Prism Camera')
        cam = bpy.data.objects.new('Prism Camera', cd)
        scene.collection.objects.link(cam)
        cam.location = (7.0, -7.0, 5.0)
        tgt = bpy.data.objects.new('Prism Target', None)
        scene.collection.objects.link(tgt)
        con = cam.constraints.new('TRACK_TO')
        con.target = tgt
        con.track_axis = 'TRACK_NEGATIVE_Z'
        con.up_axis = 'UP_Y'
        scene.camera = cam
        print('PRISM-NOTE: no camera in script, added one', file=sys.stderr)

preview = a['preview']
q = float(a['quality'])
start, end = scene.frame_start, scene.frame_end
fps = scene.render.fps / max(scene.render.fps_base, 0.001)

eng = scene.render.engine
try:
    if eng == 'CYCLES':
        scene.cycles.samples = 24 if preview else int(64 + 448 * q)
        try:
            scene.cycles.device = 'GPU'
        except Exception:
            pass
    elif 'EEVEE' in eng:
        scene.eevee.taa_render_samples = 12 if preview else int(16 + 112 * q)
except Exception:
    pass

im = scene.render.image_settings
if preview or end <= start:
    if preview:
        scene.render.resolution_percentage = 50
    f = int(round(start + (end - start) * float(a['frame']))) if end > start else start
    scene.frame_set(f)
    try:
        im.media_type = 'IMAGE'
    except Exception:
        pass
    im.file_format = 'PNG'
    scene.render.filepath = a['out'] + '.png'
    bpy.ops.render.render(write_still=True)
    secs = (end - start + 1) / fps if end > start else 0
    print('PRISM: %dx%d %s, frame %d of %d-%d (%.1f s long).' % (scene.render.resolution_x, scene.render.resolution_y,
          eng.replace('BLENDER_', '').title(), f, start, end, secs))
else:
    try:
        im.media_type = 'VIDEO'
    except Exception:
        pass
    im.file_format = 'FFMPEG'
    ff = scene.render.ffmpeg
    ff.format = 'MPEG4'
    ff.codec = 'H264'
    try:
        ff.constant_rate_factor = 'HIGH'
        ff.ffmpeg_preset = 'GOOD'
    except Exception:
        pass
    try:
        if any(s.sound for s in (scene.sequence_editor.strips_all if scene.sequence_editor else [])):
            ff.audio_codec = 'AAC'
    except Exception:
        pass
    scene.render.filepath = a['out']
    bpy.ops.render.render(animation=True)
    print('PRISM: %dx%d %s, %d frames (%.1f s).' % (scene.render.resolution_x, scene.render.resolution_y,
          eng.replace('BLENDER_', '').title(), end - start + 1, (end - start + 1) / fps))
"""#
}
