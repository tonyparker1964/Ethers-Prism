import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(CoreImage)
import CoreImage
#endif

// MARK: - Contracts

/// One video clip to make. Sizes follow LTX Video's rules: width and height are multiples
/// of 32, and the frame count is a multiple of 8 plus 1.
public struct VideoJob: Hashable, Sendable {
    public var prompt: String
    public var negative: String
    /// PNG or JPEG bytes of the first frame. Nil means text to video.
    public var startImage: Data?
    public var width: Int
    public var height: Int
    public var frames: Int
    public var fps: Int
    public var steps: Int
    public var cfg: Double
    /// How closely the clip keeps the starting image (0...1). Ignored for text to video.
    public var strength: Double
    public var seed: UInt64
    public var quality: Quality

    public init(prompt: String, negative: String, startImage: Data? = nil, width: Int, height: Int, frames: Int,
                fps: Int = 24, steps: Int, cfg: Double = 3, strength: Double = 1, seed: UInt64, quality: Quality) {
        self.prompt = prompt
        self.negative = negative
        self.startImage = startImage
        self.width = width
        self.height = height
        self.frames = frames
        self.fps = fps
        self.steps = steps
        self.cfg = cfg
        self.strength = strength
        self.seed = seed
        self.quality = quality
    }

    public var seconds: Double { Double(frames - 1) / Double(max(fps, 1)) }
}

public protocol VideoProvider: Sendable {
    var name: String { get }
    var model: String { get }
    func generate(_ job: VideoJob) async throws -> ImageResult
}

// MARK: - Settings

public struct ComfyVideoSettings: Codable, Hashable, Sendable {
    public var checkpoint: String
    public var textEncoder: String
    public var previewSteps: Int
    public var renderSteps: Int
    public var cfg: Double

    public init(checkpoint: String = "ltx-video-2b-v0.9.5.safetensors", textEncoder: String = "t5xxl_fp16.safetensors",
                previewSteps: Int = 15, renderSteps: Int = 30, cfg: Double = 3) {
        self.checkpoint = checkpoint
        self.textEncoder = textEncoder
        self.previewSteps = previewSteps
        self.renderSteps = renderSteps
        self.cfg = cfg
    }
}

// MARK: - Shared ComfyUI plumbing

/// Queue a graph, wait for it, fetch the file it saved. Used by images and video.
public struct ComfyClient: Sendable {
    public var baseURL: String

    public init(baseURL: String) { self.baseURL = baseURL }

    var base: URL? {
        var b = baseURL.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b)
    }

    /// Sends a workflow and returns its prompt id. A rejection carries ComfyUI's own reason.
    public func queue(_ graph: [String: Any]) async throws -> String {
        guard let base else { throw PrismError.comfy("the address in Settings isn't a valid URL.") }
        var req = URLRequest(url: base.appendingPathComponent("prompt"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": graph, "client_id": "ethers-prism"])
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw PrismError.comfy("it rejected the job (\(status)). \(Self.rejectionReason(d))")
            }
            data = d
        } catch let e as PrismError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PrismError.comfy("can't reach \(baseURL). Start your ComfyUI instance, then try again.")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["prompt_id"] as? String else {
            throw PrismError.comfy("unexpected reply when queueing the job.")
        }
        return id
    }

    /// Picks the readable part of a ComfyUI rejection (which node and why).
    static func rejectionReason(_ data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(String(data: data, encoding: .utf8)?.prefix(300) ?? "")
        }
        var parts: [String] = []
        if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { parts.append(m) }
        if let nodes = obj["node_errors"] as? [String: Any] {
            for case let n as [String: Any] in nodes.values {
                let cls = n["class_type"] as? String ?? "node"
                for case let err as [String: Any] in (n["errors"] as? [Any] ?? []) {
                    let detail = (err["details"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (err["message"] as? String ?? "")
                    parts.append("\(cls): \(detail)")
                }
            }
        }
        return String(parts.joined(separator: " · ").prefix(400))
    }

    /// Waits for the job and downloads the first file any output node saved.
    public func result(of promptID: String, timeout: TimeInterval) async throws -> ImageResult {
        guard let base else { throw PrismError.comfy("the address in Settings isn't a valid URL.") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                stop(promptID) // the person moved on: don't leave ComfyUI working on an unwanted clip
                throw error
            }
            guard let reply = try? await URLSession.shared.data(from: base.appendingPathComponent("history/\(promptID)")),
                  let history = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
                  let entry = history[promptID] as? [String: Any] else { continue }
            if let status = entry["status"] as? [String: Any], (status["status_str"] as? String) == "error" {
                throw PrismError.comfy("the job failed inside ComfyUI. \(Self.executionError(status))")
            }
            guard let outputs = entry["outputs"] as? [String: Any],
                  let file = Self.firstFile(in: outputs) else { continue }
            var comps = URLComponents(url: base.appendingPathComponent("view"), resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "filename", value: file.name),
                                URLQueryItem(name: "subfolder", value: file.subfolder),
                                URLQueryItem(name: "type", value: file.type)]
            let (bytes, _) = try await URLSession.shared.data(from: comps.url!)
            let ext = (file.name as NSString).pathExtension.lowercased()
            return ImageResult(data: bytes, fileExtension: ext.isEmpty ? "png" : ext)
        }
        throw PrismError.comfy("timed out waiting for the result.")
    }

    /// Removes a job from ComfyUI's queue and interrupts it if it is running. Detached so it
    /// still goes out when the calling task has been cancelled.
    public func stop(_ promptID: String) {
        guard let base else { return }
        Task.detached {
            var del = URLRequest(url: base.appendingPathComponent("queue"))
            del.httpMethod = "POST"
            del.setValue("application/json", forHTTPHeaderField: "content-type")
            del.httpBody = try? JSONSerialization.data(withJSONObject: ["delete": [promptID]])
            _ = try? await URLSession.shared.data(for: del)
            var current = URLRequest(url: base.appendingPathComponent("interrupt"))
            current.httpMethod = "POST"
            current.setValue("application/json", forHTTPHeaderField: "content-type")
            current.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt_id": promptID])
            _ = try? await URLSession.shared.data(for: current)
        }
    }

    struct SavedFile: Equatable { var name, subfolder, type: String }

    /// Output nodes list saved files under "images", "gifs" or "videos" depending on the node.
    static func firstFile(in outputs: [String: Any]) -> SavedFile? {
        for key in outputs.keys.sorted() {
            guard let node = outputs[key] as? [String: Any] else { continue }
            for list in ["videos", "gifs", "images"] {
                if let files = node[list] as? [[String: Any]], let f = files.first, let name = f["filename"] as? String {
                    return SavedFile(name: name, subfolder: f["subfolder"] as? String ?? "", type: f["type"] as? String ?? "output")
                }
            }
        }
        return nil
    }

    static func executionError(_ status: [String: Any]) -> String {
        for case let m as [Any] in (status["messages"] as? [Any] ?? []) {
            if (m.first as? String) == "execution_error", let d = m.last as? [String: Any] {
                let node = d["node_type"] as? String ?? "a node"
                let msg = d["exception_message"] as? String ?? ""
                return "\(node): \(msg.prefix(300))"
            }
        }
        return "Check that the chosen models load there."
    }

    /// Uploads an image into ComfyUI's input folder and returns the name LoadImage expects.
    public func upload(_ image: Data, fileName: String) async throws -> String {
        guard let base else { throw PrismError.comfy("the address in Settings isn't a valid URL.") }
        let boundary = "EthersPrism-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(fileName)\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(image)
        add("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ninput\r\n--\(boundary)--\r\n")
        var req = URLRequest(url: base.appendingPathComponent("upload/image"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        req.httpBody = body
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(for: req)
            guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                throw PrismError.comfy("it refused the starting image.")
            }
            data = d
        } catch let e as PrismError {
            throw e
        } catch {
            throw PrismError.comfy("can't reach \(baseURL). Start your ComfyUI instance, then try again.")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let name = obj["name"] as? String else {
            throw PrismError.comfy("unexpected reply after uploading the starting image.")
        }
        let sub = obj["subfolder"] as? String ?? ""
        return sub.isEmpty ? name : "\(sub)/\(name)"
    }

    /// Lists the choices ComfyUI offers for one input of one node (for the Settings pickers).
    public func options(node: String, input: String) async throws -> [String] {
        guard let url = base?.appendingPathComponent("object_info/\(node)") else {
            throw PrismError.comfy("the address isn't a valid URL.")
        }
        let data: Data
        do { data = try await URLSession.shared.data(from: url).0 } catch {
            throw PrismError.comfy("can't reach \(baseURL). Is your ComfyUI instance running?")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json[node] as? [String: Any],
              let inputs = info["input"] as? [String: Any],
              let required = inputs["required"] as? [String: Any],
              let spec = required[input] as? [Any] else {
            throw PrismError.comfy("this ComfyUI has no \(node) node. Update ComfyUI to get LTX Video support.")
        }
        if let names = spec.first as? [String] { return names }
        if let opts = spec.last as? [String: Any], let names = opts["options"] as? [String] { return names }
        return []
    }
}

// MARK: - LTX Video through ComfyUI

public struct ComfyVideoProvider: VideoProvider {
    public let name = "ComfyUI · LTX Video"
    public var baseURL: String
    public var settings: ComfyVideoSettings
    /// When set, every model loaded in LM Studio is unloaded first: video needs all the memory.
    public var lmStudioURL: String?
    public var model: String { settings.checkpoint }

    public init(baseURL: String, settings: ComfyVideoSettings, lmStudioURL: String? = nil) {
        self.baseURL = baseURL
        self.settings = settings
        self.lmStudioURL = lmStudioURL
    }

    public enum Container: String, Sendable { case mp4, webp }

    /// The node graph: LTX checkpoint + T5 text encoder → (empty latent | first frame) →
    /// LTX scheduler and sampler → decode → saved clip. Uses ComfyUI's built-in LTX nodes only.
    public static func workflow(for job: VideoJob, settings s: ComfyVideoSettings, startImageName: String?,
                                container: Container = .mp4) -> [String: Any] {
        func node(_ cls: String, _ inputs: [String: Any]) -> [String: Any] { ["class_type": cls, "inputs": inputs] }
        func link(_ id: String, _ slot: Int) -> [Any] { [id, slot] }
        var g: [String: Any] = [:]
        g["1"] = node("CheckpointLoaderSimple", ["ckpt_name": s.checkpoint])
        g["2"] = node("CLIPLoader", ["clip_name": s.textEncoder, "type": "ltxv"])
        g["3"] = node("CLIPTextEncode", ["text": job.prompt, "clip": link("2", 0)])
        g["4"] = node("CLIPTextEncode", ["text": job.negative, "clip": link("2", 0)])
        let latent: [Any]
        let positive: [Any]
        let negative: [Any]
        if let name = startImageName {
            g["10"] = node("LoadImage", ["image": name])
            g["5"] = node("LTXVImgToVideo", [
                "positive": link("3", 0), "negative": link("4", 0), "vae": link("1", 2), "image": link("10", 0),
                "width": job.width, "height": job.height, "length": job.frames, "batch_size": 1,
                "strength": job.strength])
            positive = link("5", 0); negative = link("5", 1); latent = link("5", 2)
        } else {
            g["5"] = node("EmptyLTXVLatentVideo", ["width": job.width, "height": job.height,
                                                   "length": job.frames, "batch_size": 1])
            positive = link("3", 0); negative = link("4", 0); latent = link("5", 0)
        }
        g["6"] = node("LTXVConditioning", ["positive": positive, "negative": negative, "frame_rate": Double(job.fps)])
        g["7"] = node("LTXVScheduler", ["steps": job.steps, "max_shift": 2.05, "base_shift": 0.95,
                                        "stretch": true, "terminal": 0.1, "latent": latent])
        g["8"] = node("KSamplerSelect", ["sampler_name": "euler"])
        g["9"] = node("SamplerCustom", [
            "model": link("1", 0), "add_noise": true, "noise_seed": NSNumber(value: job.seed), "cfg": job.cfg,
            "positive": link("6", 0), "negative": link("6", 1), "sampler": link("8", 0), "sigmas": link("7", 0),
            "latent_image": latent])
        g["11"] = node("VAEDecode", ["samples": link("9", 0), "vae": link("1", 2)])
        switch container {
        case .mp4:
            g["12"] = node("CreateVideo", ["images": link("11", 0), "fps": Double(job.fps)])
            g["13"] = node("SaveVideo", ["video": link("12", 0), "filename_prefix": "EthersPrism/video",
                                         "format": "mp4", "codec": "h264"])
        case .webp:
            g["13"] = node("SaveAnimatedWEBP", ["images": link("11", 0), "filename_prefix": "EthersPrism/video",
                                                "fps": Double(job.fps), "lossless": false, "quality": 90, "method": "default"])
        }
        return g
    }

    public func generate(_ job: VideoJob) async throws -> ImageResult {
        guard !settings.checkpoint.trimmed.isEmpty, !settings.textEncoder.trimmed.isEmpty else {
            throw PrismError.comfy("choose the LTX Video model and its text encoder in Settings → Video.")
        }
        if let lm = lmStudioURL { await LocalMemory.unloadLMStudioModels(baseURL: lm, onlyLarge: false) }
        let client = ComfyClient(baseURL: baseURL)
        var imageName: String?
        if let img = job.startImage {
            imageName = try await client.upload(img, fileName: "ethers-prism-start-\(job.seed % 1_000_000).png")
        }
        let timeout: TimeInterval = job.quality == .preview ? 1800 : 3 * 3600
        do {
            let id = try await client.queue(Self.workflow(for: job, settings: settings, startImageName: imageName))
            return try await client.result(of: id, timeout: timeout)
        } catch PrismError.comfy(let message) where message.contains("CreateVideo") || message.contains("SaveVideo") {
            // Older ComfyUI without the video save nodes: fall back to an animated WebP.
            let id = try await client.queue(Self.workflow(for: job, settings: settings, startImageName: imageName,
                                                          container: .webp))
            return try await client.result(of: id, timeout: timeout)
        }
    }
}

// MARK: - Starting images

public enum StartImage {
    public static let extensions = ["png", "jpg", "jpeg", "webp", "heic", "tif", "tiff"]

    /// Splits a goal into the starting-image path it names (anywhere in it) and the rest.
    public static func split(_ goal: String) -> (path: String?, description: String) {
        let pattern = #"(?:~|/)[^\n"']*?\.(?:png|jpe?g|webp|heic|tiff?)\b"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let r = Range(m.range, in: goal) else {
            return (nil, goal.trimmed)
        }
        var path = String(goal[r])
        if path.hasPrefix("~") { path = NSString(string: path).expandingTildeInPath }
        var rest = goal
        rest.removeSubrange(r)
        let description = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-—–:,\"'")))
        return (path, description)
    }

    /// Pixel size of an image file, if it can be read.
    public static func pixelSize(_ data: Data) -> (width: Int, height: Int)? {
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
        #else
        return nil
        #endif
    }

    /// Re-encodes as PNG, slightly softened when lots of motion is wanted: LTX Video moves
    /// more from a soft first frame than from a crisp one.
    public static func prepared(_ data: Data, motion: Double) -> Data {
        #if canImport(CoreImage)
        guard let input = CIImage(data: data) else { return data }
        var image = input
        if motion > 0.45 {
            let radius = (motion - 0.45) * 3
            image = image.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        }
        let ctx = CIContext()
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let png = ctx.pngRepresentation(of: image, format: .RGBA8, colorSpace: space, options: [:]) else { return data }
        return png
        #else
        return data
        #endif
    }
}

// MARK: - Clip sizes

public enum VideoSizing {
    static func snap32(_ v: Double) -> Int { max(64, Int((v / 32).rounded()) * 32) }

    /// Width and height (multiples of 32) keeping the aspect, with the long edge at `longEdge`.
    public static func size(aspect: Double, longEdge: Int) -> (width: Int, height: Int) {
        let a = aspect.isFinite && aspect > 0 ? min(max(aspect, 0.4), 2.5) : 16.0 / 9.0
        if a >= 1 { return (snap32(Double(longEdge)), snap32(Double(longEdge) / a)) }
        return (snap32(Double(longEdge) * a), snap32(Double(longEdge)))
    }

    /// Frame count of the form 8n + 1 closest to `seconds` at `fps`.
    public static func frames(seconds: Double, fps: Int) -> Int {
        let n = max(1, Int((seconds * Double(fps) / 8).rounded()))
        return n * 8 + 1
    }
}
