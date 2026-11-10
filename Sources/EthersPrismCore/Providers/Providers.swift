import Foundation

// MARK: - Contracts

public protocol TextProvider: Sendable {
    var name: String { get }
    var model: String { get }
    func complete(_ request: TextRequest) async throws -> String
}

public struct ImageJob: Hashable, Sendable {
    public var prompt: String
    public var negative: String
    public var quality: Quality
    public var seed: UInt64

    public init(prompt: String, negative: String, quality: Quality, seed: UInt64) {
        self.prompt = prompt
        self.negative = negative
        self.quality = quality
        self.seed = seed
    }
}

public struct ImageResult: Sendable {
    public var data: Data
    public var fileExtension: String

    public init(data: Data, fileExtension: String) {
        self.data = data
        self.fileExtension = fileExtension
    }
}

public protocol ImageProvider: Sendable {
    var name: String { get }
    var model: String { get }
    /// Plain statement of whether previews really cost less than full renders.
    var previewCostNote: String { get }
    func generate(_ job: ImageJob) async throws -> ImageResult
}

/// The providers for one generation. Each agent role can have its own text provider;
/// roles without one fall back to `text`.
public struct ProviderSet: Sendable {
    public var text: any TextProvider
    public var image: (any ImageProvider)?
    public var video: (any VideoProvider)?
    public var agents: [AgentRole: any TextProvider]

    public init(text: any TextProvider, image: (any ImageProvider)?, agents: [AgentRole: any TextProvider] = [:],
                video: (any VideoProvider)? = nil) {
        self.text = text
        self.image = image
        self.video = video
        self.agents = agents
    }

    public func text(for role: AgentRole) -> any TextProvider { agents[role] ?? text }
}

// MARK: - Anthropic (Claude)

public struct AnthropicTextProvider: TextProvider {
    public let name = "Anthropic"
    public var model: String
    private var apiKey: String

    public init(apiKey: String, model: String) {
        self.apiKey = apiKey
        self.model = model
    }

    private struct MessagesResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    public func complete(_ request: TextRequest) async throws -> String {
        guard !apiKey.trimmed.isEmpty else { throw PrismError.missingAPIKey }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue(apiKey.trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": [["role": "user", "content": request.user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw PrismError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        let text = try JSONDecoder().decode(MessagesResponse.self, from: data).content.compactMap(\.text).joined()
        guard !text.trimmed.isEmpty else { throw PrismError.emptyResponse }
        return text
    }
}

// MARK: - ComfyUI (local images)

public struct ComfyUISettings: Codable, Hashable, Sendable {
    public var baseURL: String
    public var checkpoint: String
    public var previewSize: Int
    public var previewSteps: Int
    public var renderSize: Int
    public var renderSteps: Int
    public var cfg: Double
    public var sampler: String
    public var scheduler: String

    public init(baseURL: String = "http://127.0.0.1:8000", checkpoint: String = "", previewSize: Int = 512,
                previewSteps: Int = 10, renderSize: Int = 1024, renderSteps: Int = 28, cfg: Double = 6.5,
                sampler: String = "euler", scheduler: String = "normal") {
        self.baseURL = baseURL
        self.checkpoint = checkpoint
        self.previewSize = previewSize
        self.previewSteps = previewSteps
        self.renderSize = renderSize
        self.renderSteps = renderSteps
        self.cfg = cfg
        self.sampler = sampler
        self.scheduler = scheduler
    }
}

public struct ComfyUIImageProvider: ImageProvider {
    public let name = "ComfyUI (local)"
    public var settings: ComfyUISettings
    public var model: String { settings.checkpoint }
    public var previewCostNote: String {
        "Runs on this Mac at no per-image cost. Previews use \(settings.previewSize)px and \(settings.previewSteps) steps, so they are much faster than full renders (\(settings.renderSize)px, \(settings.renderSteps) steps)."
    }

    public init(settings: ComfyUISettings) {
        self.settings = settings
    }

    private var base: URL? {
        URL(string: settings.baseURL.trimmed.hasSuffix("/") ? String(settings.baseURL.trimmed.dropLast()) : settings.baseURL.trimmed)
    }

    /// The node graph sent to ComfyUI: checkpoint → prompts → sampler → decode → save.
    public static func workflow(for job: ImageJob, settings s: ComfyUISettings) -> [String: Any] {
        let size = job.quality == .preview ? s.previewSize : s.renderSize
        let steps = job.quality == .preview ? s.previewSteps : s.renderSteps
        func node(_ cls: String, _ inputs: [String: Any]) -> [String: Any] {
            ["class_type": cls, "inputs": inputs]
        }
        func link(_ id: String, _ slot: Int) -> [Any] { [id, slot] }
        var graph: [String: Any] = [:]
        graph["4"] = node("CheckpointLoaderSimple", ["ckpt_name": s.checkpoint])
        graph["6"] = node("CLIPTextEncode", ["text": job.prompt, "clip": link("4", 1)])
        graph["7"] = node("CLIPTextEncode", ["text": job.negative, "clip": link("4", 1)])
        graph["5"] = node("EmptyLatentImage", ["width": size, "height": size, "batch_size": 1])
        graph["3"] = node("KSampler", [
            "seed": NSNumber(value: job.seed), "steps": steps, "cfg": s.cfg, "sampler_name": s.sampler,
            "scheduler": s.scheduler, "denoise": 1.0,
            "model": link("4", 0), "positive": link("6", 0), "negative": link("7", 0), "latent_image": link("5", 0)
        ])
        graph["8"] = node("VAEDecode", ["samples": link("3", 0), "vae": link("4", 2)])
        graph["9"] = node("SaveImage", ["filename_prefix": "EthersPrism", "images": link("8", 0)])
        return graph
    }

    public func generate(_ job: ImageJob) async throws -> ImageResult {
        guard let base else { throw PrismError.comfy("the address in Settings isn't a valid URL.") }
        guard !settings.checkpoint.trimmed.isEmpty else {
            throw PrismError.comfy("choose a model (checkpoint) in Settings.")
        }
        var req = URLRequest(url: base.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": Self.workflow(for: job, settings: settings),
            "client_id": "ethers-prism"
        ])
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw PrismError.comfy("it rejected the job (\(status)). \(String(data: d, encoding: .utf8)?.prefix(300) ?? "")")
            }
            data = d
        } catch let e as PrismError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PrismError.comfy("can't reach \(settings.baseURL). Start your ComfyUI instance, then try again.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let promptID = json["prompt_id"] as? String else {
            throw PrismError.comfy("unexpected reply when queueing the job.")
        }

        // Poll until the image is ready (cancellable: Task.sleep throws on cancel).
        let deadline = Date().addingTimeInterval(job.quality == .preview ? 300 : 900)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 700_000_000)
            let (hData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("history/\(promptID)"))
            guard let history = try JSONSerialization.jsonObject(with: hData) as? [String: Any],
                  let entry = history[promptID] as? [String: Any] else { continue }
            if let status = entry["status"] as? [String: Any], (status["status_str"] as? String) == "error" {
                throw PrismError.comfy("the job failed inside ComfyUI. Check that the chosen model loads there.")
            }
            guard let outputs = entry["outputs"] as? [String: Any] else { continue }
            for case let node as [String: Any] in outputs.values {
                guard let images = node["images"] as? [[String: Any]], let first = images.first,
                      let filename = first["filename"] as? String else { continue }
                var comps = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
                comps.queryItems = [
                    URLQueryItem(name: "filename", value: filename),
                    URLQueryItem(name: "subfolder", value: first["subfolder"] as? String ?? ""),
                    URLQueryItem(name: "type", value: first["type"] as? String ?? "output")
                ]
                let (img, _) = try await URLSession.shared.data(from: comps.url!)
                let ext = (filename as NSString).pathExtension.lowercased()
                return ImageResult(data: img, fileExtension: ext.isEmpty ? "png" : ext)
            }
        }
        throw PrismError.comfy("timed out waiting for the image.")
    }

    /// Lists the checkpoints ComfyUI can load, for the Settings picker.
    public static func checkpoints(baseURL: String) async throws -> [String] {
        guard let url = URL(string: baseURL.trimmed)?.appendingPathComponent("object_info/CheckpointLoaderSimple") else {
            throw PrismError.comfy("the address isn't a valid URL.")
        }
        let data: Data
        do {
            data = try await URLSession.shared.data(from: url).0
        } catch {
            throw PrismError.comfy("can't reach \(baseURL). Is your ComfyUI instance running?")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = json["CheckpointLoaderSimple"] as? [String: Any],
              let input = node["input"] as? [String: Any],
              let required = input["required"] as? [String: Any],
              let ckpt = required["ckpt_name"] as? [Any],
              let names = ckpt.first as? [String] else {
            throw PrismError.comfy("couldn't read the model list.")
        }
        return names
    }
}

// MARK: - Claude SVG (drawings, no image model needed)

public struct ClaudeSVGImageProvider: ImageProvider {
    public let name = "Claude SVG drawing"
    public var text: any TextProvider
    public var model: String { text.model }
    public let previewCostNote = "Claude draws vector images. A preview costs about the same as a full render; previews are only simpler drawings."

    public init(text: any TextProvider) {
        self.text = text
    }

    public func generate(_ job: ImageJob) async throws -> ImageResult {
        let req = TextRequest(
            system: "You are an illustrator who draws in SVG. Respond with one complete, valid SVG document with viewBox=\"0 0 1024 1024\" and nothing else. No external images or fonts.",
            user: "Draw: \(job.prompt)\nAvoid: \(job.negative)\n\(job.quality == .preview ? "Keep it simple: fewer elements." : "Make it detailed and polished.")",
            maxTokens: job.quality == .preview ? 3000 : 9000)
        let raw = try await text.complete(req)
        guard let svg = OutputCleaner.svgBody(raw) else { throw PrismError.emptyResponse }
        return ImageResult(data: Data(svg.utf8), fileExtension: "svg")
    }
}

// MARK: - Mock providers (clearly labeled, for development and tests)

public struct MockTextProvider: TextProvider {
    public let name = "Mock (test only)"
    public let model = "mock"

    public init() {}

    public func complete(_ request: TextRequest) async throws -> String {
        try await Task.sleep(nanoseconds: 200_000_000)
        let seed = Compiler.seed(for: request.user)
        if request.system.contains(Checker.marker) {
            let flagged = request.user.lowercased().contains("must avoid: mock")
            return flagged ? #"{"passes": false, "issues": ["Mentions MOCK"]}"# : #"{"passes": true, "issues": []}"#
        }
        if request.system.contains(DialSuggester.marker) {
            return """
            [{"name":"Detail","detail":"How much is included.","low":"bare essentials","high":"richly detailed"},
             {"name":"Tone","detail":"Emotional color.","low":"serious","high":"playful"},
             {"name":"Symbolic depth","detail":"Meaning beyond the literal.","low":"direct and literal","high":"layered metaphor"},
             {"name":"Energy","detail":"Pace and intensity.","low":"calm","high":"intense"},
             {"name":"Audience","detail":"Who it is pitched at.","low":"beginners","high":"experts"}]
            """
        }
        let lines = request.user.components(separatedBy: "\n")
        let goal = lines.first ?? ""
        let dials = lines.filter { $0.hasPrefix("- ") }.joined(separator: "\n")
        if request.system.contains(ImageAdapter.promptMarker) || request.system.contains(VideoDirection.marker) {
            return #"{"prompt": "MOCK image prompt for \#(goal.replacingOccurrences(of: "\"", with: "'")) (variation \#(seed % 997))", "negative": "blurry"}"#
        }
        if request.system.lowercased().contains("storyboard") {
            return "## Scene 1 — Opening (0:00–0:20)\nVisual: Mock scene \(seed % 97)\nNarration: \(goal)\n\n## Scene 2 — Dials (0:20–0:50)\nVisual: Shapes rearranging\nNarration: Shaped by:\n\(dials)"
        }
        return "**MOCK OUTPUT** (variation \(seed % 997))\n\n\(goal)\n\nThis text would be shaped by:\n\(dials)\n\nUse a real provider in Settings for real results."
    }
}

public struct MockImageProvider: ImageProvider {
    public let name = "Mock (test only)"
    public let model = "mock"
    public let previewCostNote = "Test images only. Nothing is generated."

    public init() {}

    public func generate(_ job: ImageJob) async throws -> ImageResult {
        try await Task.sleep(nanoseconds: 200_000_000)
        var rng = job.seed | 1
        func next() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int((rng >> 33) % 1000)
        }
        let hue = Int(job.seed % 360)
        var shapes = ""
        for _ in 0..<(job.quality == .preview ? 5 : 14) {
            shapes += "<circle cx=\"\(next())\" cy=\"\(next())\" r=\"\(30 + next() % 160)\" fill=\"hsl(\((hue + next() % 90) % 360),70%,60%)\" fill-opacity=\"0.7\"/>"
        }
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1000 1000\"><rect width=\"1000\" height=\"1000\" fill=\"hsl(\(hue),40%,14%)\"/>\(shapes)<text x=\"30\" y=\"965\" fill=\"white\" font-family=\"sans-serif\" font-size=\"34\">MOCK \(job.quality == .preview ? "preview" : "render")</text></svg>"
        return ImageResult(data: Data(svg.utf8), fileExtension: "svg")
    }
}
