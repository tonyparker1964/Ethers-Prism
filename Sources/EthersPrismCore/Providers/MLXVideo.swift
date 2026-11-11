import Foundation

// MARK: - LTX-2.5 on this Mac (MLX)

/// Where the MLX runtime and the LTX-2.5 model live, and how big clips are.
/// Everything stays on the Mac: the runner is a script on the MAC Mini 2 drive.
public struct MLXVideoSettings: Codable, Hashable, Sendable {
    /// The script Install LTX Video.command put on the drive. It runs `ltx-2-mlx`.
    public var runner: String
    /// The LTX-2.5 model folder (4-bit MLX pack).
    public var modelDir: String
    /// Streams the 22B transformer from disk instead of holding it in memory. Needed on 24 GB.
    public var lowRAM: Bool
    /// Long edge in pixels for previews and for full renders.
    public var previewLongEdge: Int
    public var renderLongEdge: Int

    public static let driveRoot = "/Volumes/MAC Mini 2/LTX"

    public init(runner: String = "\(MLXVideoSettings.driveRoot)/ltx.sh",
                modelDir: String = "\(MLXVideoSettings.driveRoot)/models/ltx-2.5-mlx-q4",
                lowRAM: Bool = true, previewLongEdge: Int = 448, renderLongEdge: Int = 704) {
        self.runner = runner
        self.modelDir = modelDir
        self.lowRAM = lowRAM
        self.previewLongEdge = previewLongEdge
        self.renderLongEdge = renderLongEdge
    }

    /// Plain-words reason the engine can't run yet, or nil when the files are in place.
    public var missingPiece: String? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: "/Volumes/MAC Mini 2") { return "The MAC Mini 2 drive isn't connected." }
        if !fm.isExecutableFile(atPath: runner) { return "The LTX runner isn't on the drive yet. Run Install LTX Video.command in MAC Mini 2 → LTX." }
        if !fm.fileExists(atPath: (modelDir as NSString).appendingPathComponent("transformer-distilled.safetensors")) {
            return "The LTX-2.5 model hasn't finished downloading to \(modelDir)."
        }
        return nil
    }
}

public struct MLXVideoProvider: VideoProvider {
    public let name = "LTX-2.5 · MLX on this Mac"
    public var settings: MLXVideoSettings
    /// When set, every model loaded in LM Studio is unloaded first: video needs all the memory.
    public var lmStudioURL: String?
    public var model: String { "LTX-2.5 distilled, 4-bit" + (settings.lowRAM ? ", low-RAM" : "") }

    /// The distilled pipeline always runs 8 steps with guidance off.
    public static let distilledSteps = 8

    public init(settings: MLXVideoSettings, lmStudioURL: String? = nil) {
        self.settings = settings
        self.lmStudioURL = lmStudioURL
    }

    /// LTX-2.5's two-stage distilled pipeline works at half size first, so both sides are multiples of 64.
    static func snap64(_ v: Double) -> Int { max(128, Int((v / 64).rounded()) * 64) }

    public func sized(_ job: VideoJob) -> VideoJob {
        var j = job
        let edge = Double(job.quality == .preview ? settings.previewLongEdge : settings.renderLongEdge)
        let aspect = Double(job.width) / Double(max(job.height, 1))
        if aspect >= 1 { j.width = Self.snap64(edge); j.height = Self.snap64(edge / aspect) }
        else { j.height = Self.snap64(edge); j.width = Self.snap64(edge * aspect) }
        j.steps = Self.distilledSteps
        j.cfg = 1
        return j
    }

    /// The command-line arguments for one clip. `flags` is what this install's `generate --help` lists.
    public func arguments(for job: VideoJob, output: String, startImage: String?, flags: Set<String>) -> [String] {
        var a = ["generate", "--model", settings.modelDir, "--distilled"]
        if settings.lowRAM { a.append("--low-ram") }
        a += ["-p", job.prompt, "-H", String(job.height), "-W", String(job.width),
              "-f", String(job.frames), "--frame-rate", String(job.fps)]
        if flags.contains("--seed") { a += ["--seed", String(job.seed % 2_147_483_647)] }
        if let img = startImage { a += ["--image", img, "0", String(format: "%.2f", job.strength)] }
        a += ["-o", output]
        return a
    }

    /// Reads which flags `generate` accepts, once per app launch.
    static let flagCache = FlagCache()
    actor FlagCache {
        var flags: Set<String>?
        func get(_ runner: String) async -> Set<String> {
            if let flags { return flags }
            let text = (try? await MLXVideoProvider.run(runner, ["generate", "--help"], log: nil)) ?? ""
            let found = Set(text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" || $0 == "[" || $0 == "]" })
                .map(String.init).filter { $0.hasPrefix("--") })
            if !found.isEmpty { flags = found }
            return found
        }
    }

    public func generate(_ job: VideoJob) async throws -> ImageResult {
        if let missing = settings.missingPiece { throw PrismError.local(missing) }
        if let lm = lmStudioURL { await LocalMemory.unloadLMStudioModels(baseURL: lm, onlyLarge: false) }
        let job = sized(job)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ethers-prism-ltx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var imagePath: String?
        if let img = job.startImage {
            let p = dir.appendingPathComponent("start.png")
            try img.write(to: p)
            imagePath = p.path
        }
        let out = dir.appendingPathComponent("clip.mp4")
        let log = dir.appendingPathComponent("ltx.log")
        let flags = await Self.flagCache.get(settings.runner)
        _ = try await Self.run(settings.runner, arguments(for: job, output: out.path, startImage: imagePath, flags: flags), log: log)
        guard let mp4 = try? Data(contentsOf: out), !mp4.isEmpty else {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            let lines = text.components(separatedBy: .newlines).filter { !$0.trimmed.isEmpty }
            let errors = lines.filter { $0.localizedCaseInsensitiveContains("error") || $0.contains("Traceback") }
            let detail = (errors.isEmpty ? lines.suffix(4) : errors.suffix(4)).joined(separator: " ")
            throw PrismError.local("LTX didn't produce a clip. \(detail.suffix(400))")
        }
        return ImageResult(data: mp4, fileExtension: "mp4")
    }

    /// Runs the runner script. Output goes to `log` (so a long render can't fill a pipe) or is returned.
    @discardableResult
    static func run(_ runner: String, _ args: [String], log: URL?) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [runner] + args
        let pipe = Pipe()
        var handle: FileHandle?
        if let log {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            handle = try FileHandle(forWritingTo: log)
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = pipe
            process.standardError = pipe
        }
        defer { try? handle?.close() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in cont.resume() }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        if log != nil { return "" }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    /// For Settings → Video: is everything in place, and does the runner start?
    public static func check(_ settings: MLXVideoSettings) async -> String {
        if let missing = settings.missingPiece { return missing }
        let help = (try? await run(settings.runner, ["--help"], log: nil)) ?? ""
        return help.contains("generate") ? "Ready. LTX-2.5 and its MLX runner were found on MAC Mini 2."
            : "The model is there, but the runner didn't start. \(help.suffix(200))"
    }
}
