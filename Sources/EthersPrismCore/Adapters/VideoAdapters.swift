import Foundation

/// What both video fields share: the Art Director writes the long, descriptive prompt LTX Video
/// needs from the goal and every dial; a few dials (length, faithfulness) also set numbers directly.
public enum VideoDirection {
    public static let marker = "[[VIDEO-PROMPT]]"

    static let format = #"JSON only: {"prompt": "one paragraph of 120 to 180 words", "negative": "comma-separated things to keep out"}. Write the prompt as LTX Video likes it: start with the main action, then specific movements and gestures, then appearance of subjects and objects, then the background and setting, then the camera angle and camera movement, then lighting and colors. Describe what is seen and how it moves, in the present tense, as one flowing paragraph. No dialogue, no lists, no line breaks. Put every 'Must avoid' requirement into negative."#

    static let defaultNegative = "worst quality, inconsistent motion, blurry, jittery, distorted, warped, watermark, text artifacts"

    /// Reads a dial by a word in its name, as 0...1.
    static func dial(_ input: CompileInput, _ key: String, _ fallback: Double) -> Double {
        (input.state.dials.first { $0.name.lowercased().contains(key) }?.value ?? fallback) / 100
    }

    /// Seconds from the Length dial: 1 s at the low end, 8 s at the high end.
    public static func seconds(_ input: CompileInput) -> Double {
        1 + 7 * dial(input, "length", 30)
    }

    /// Clip sizes. Previews are short and small so they come back in minutes on a Mac;
    /// full renders use the Length dial and a larger frame.
    public static func plan(_ input: CompileInput, aspect: Double, settings: ComfyVideoSettings) -> (w: Int, h: Int, frames: Int, steps: Int) {
        let preview = input.quality == .preview
        let size = VideoSizing.size(aspect: aspect, longEdge: preview ? 512 : 768)
        let secs = preview ? min(seconds(input), 1.0) : seconds(input)
        return (size.width, size.height, VideoSizing.frames(seconds: secs, fps: 24),
                preview ? settings.previewSteps : settings.renderSteps)
    }

    static func compile(_ input: CompileInput, role: String, goal: String) -> CompiledRequest {
        // Previews and full renders get the same prompt, so the preview shows what the render will be.
        var aimed = input
        aimed.state.goal = goal
        aimed.quality = .render
        var text = Compiler.buildText(role: "\(marker) \(role)", format: format, input: aimed,
                                      previewTokens: 500, renderTokens: 600)
        text.schema = Schemas.imagePrompt
        return CompiledRequest(input: input, text: text, seed: Compiler.seed(for: input.state.goal + text.user))
    }

    /// Asks the Art Director for the prompt and merges the person's "Must avoid" requirements.
    static func prompt(for request: CompiledRequest, providers: ProviderSet) async throws -> (prompt: String, negative: String, director: any TextProvider) {
        let director = providers.text(for: .artDirector)
        let p = ImageAdapter.parsePrompt(try await director.complete(request.text))
        let avoid = request.input.state.constraints.filter { $0.isActive && $0.kind == .mustAvoid }.map(\.text)
        let negative = ([p.negative ?? "", defaultNegative] + avoid).map(\.trimmed).filter { !$0.isEmpty }
            .joined(separator: ", ")
        return (p.prompt, negative, director)
    }

    static func output(_ result: ImageResult, prompt: String, job: VideoJob, video: any VideoProvider,
                       director: any TextProvider, agent: String) -> Generated {
        let summary = "\(job.width)×\(job.height), \(String(format: "%.1f", job.seconds)) s at \(job.fps) fps, \(job.steps) steps"
        return Generated(
            output: Output(kind: .video, text: summary, imagePrompt: prompt, provider: video.name, model: video.model,
                           promptModel: "Art Director: \(director.name) \(director.model)", agent: agent),
            asset: result.data, assetExtension: result.fileExtension)
    }
}

// MARK: - Text to Video

public struct TextToVideoAdapter: DomainAdapter {
    public let id = "t2v"
    public let name = "Text to Video"
    public let symbol = "film"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .video, editable: false, exportFormats: ["mp4"],
                                                 needsVideoProvider: true)
    public let dialHint = "motion, camera movement, realism, mood, pacing, length"

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        [Dial(name: "Motion", detail: "How much moves in the shot.", lowPole: "almost still", highPole: "lively", value: 40),
         Dial(name: "Camera move", detail: "What the camera does.", lowPole: "locked off", highPole: "sweeping", value: 35),
         Dial(name: "Realism", detail: "Look of the footage.", lowPole: "painterly, stylized", highPole: "photoreal", value: 60),
         Dial(name: "Mood", detail: "Light and atmosphere.", lowPole: "bright, warm", highPole: "dark, moody", value: 45),
         Dial(name: "Length", detail: "Clip length for the full render (previews are 1 second).", lowPole: "1 second", highPole: "8 seconds", value: 30)]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        VideoDirection.compile(input, role: "You are a cinematographer who writes prompts for the LTX Video model. The clip is made from your words alone.",
                               goal: input.state.goal)
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    private func run(_ request: CompiledRequest, _ providers: ProviderSet) async throws -> Generated {
        guard let video = providers.video else { throw PrismError.local("Video isn't set up. Open Settings → Video.") }
        let settings = (video as? ComfyVideoProvider)?.settings ?? ComfyVideoSettings()
        let (prompt, negative, director) = try await VideoDirection.prompt(for: request, providers: providers)
        let plan = VideoDirection.plan(request.input, aspect: 16.0 / 9.0, settings: settings)
        let job = video.sized(VideoJob(prompt: prompt, negative: negative, width: plan.w, height: plan.h, frames: plan.frames,
                                       steps: plan.steps, cfg: settings.cfg, seed: request.seed, quality: request.input.quality))
        let result = try await video.generate(job)
        return VideoDirection.output(result, prompt: prompt, job: job, video: video, director: director,
                                     agent: "Art Director + \(video.name)")
    }
}

// MARK: - Image to Video

/// The goal holds the path of the starting image (Choose Image… fills it in) and, around it,
/// a few words about how it should move.
public struct ImageToVideoAdapter: DomainAdapter {
    public let id = "i2v"
    public let name = "Image to Video"
    public let symbol = "photo.on.rectangle.angled"
    public let status = AdapterStatus.ready
    public let capabilities = OutputCapabilities(kind: .video, editable: false, exportFormats: ["mp4"],
                                                 needsVideoProvider: true)
    public let dialHint = "motion, camera movement, faithfulness to the image, atmosphere, length"

    public init() {}

    public func suggestDials(for goal: String, using providers: ProviderSet) async throws -> [Dial] {
        [Dial(name: "Motion", detail: "How much moves in the shot.", lowPole: "almost still", highPole: "lively", value: 40),
         Dial(name: "Camera move", detail: "What the camera does.", lowPole: "locked off", highPole: "sweeping", value: 30),
         Dial(name: "Faithfulness", detail: "How closely the clip keeps your image.", lowPole: "free to change", highPole: "exact first frame", value: 85),
         Dial(name: "Atmosphere", detail: "Light, particles and air around the subject.", lowPole: "calm, clear", highPole: "dramatic, glowing", value: 50),
         Dial(name: "Length", detail: "Clip length for the full render (previews are 1 second).", lowPole: "1 second", highPole: "8 seconds", value: 30)]
    }

    public func compile(_ input: CompileInput) -> CompiledRequest {
        let described = StartImage.split(input.state.goal).description
        let goal = described.isEmpty ? "Bring the starting image to life with gentle, natural motion." : described
        return VideoDirection.compile(input, role: "You are a cinematographer who writes prompts for the LTX Video model. The clip starts from the person's own image, which the goal describes; keep its subject, colors and design, and describe how it moves.",
                                      goal: goal)
    }

    public func preview(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    public func render(_ request: CompiledRequest, using providers: ProviderSet) async throws -> Generated {
        try await run(request, providers)
    }

    /// 0.55 when free to change, 1.0 when the first frame must match exactly.
    public static func strength(_ input: CompileInput) -> Double {
        0.55 + 0.45 * VideoDirection.dial(input, "faithful", 85)
    }

    private func run(_ request: CompiledRequest, _ providers: ProviderSet) async throws -> Generated {
        guard let video = providers.video else { throw PrismError.local("Video isn't set up. Open Settings → Video.") }
        guard let path = StartImage.split(request.input.state.goal).path else {
            throw PrismError.local("Choose a starting image first (the Choose Image… button under the goal).")
        }
        guard let original = FileManager.default.contents(atPath: path) else {
            throw PrismError.local("The starting image wasn't found: \(path)")
        }
        let settings = (video as? ComfyVideoProvider)?.settings ?? ComfyVideoSettings()
        let (prompt, negative, director) = try await VideoDirection.prompt(for: request, providers: providers)
        let px = StartImage.pixelSize(original)
        let aspect = px.map { Double($0.width) / Double(max($0.height, 1)) } ?? 1
        let plan = VideoDirection.plan(request.input, aspect: aspect, settings: settings)
        let start = StartImage.prepared(original, motion: VideoDirection.dial(request.input, "motion", 40))
        let job = video.sized(VideoJob(prompt: prompt, negative: negative, startImage: start, width: plan.w, height: plan.h,
                                       frames: plan.frames, steps: plan.steps, cfg: settings.cfg,
                                       strength: Self.strength(request.input), seed: request.seed, quality: request.input.quality))
        let result = try await video.generate(job)
        return VideoDirection.output(result, prompt: prompt, job: job, video: video, director: director,
                                     agent: "Art Director + \(video.name) (from \((path as NSString).lastPathComponent))")
    }
}
