import XCTest
@testable import EthersPrismCore

/// Records the job it was given and returns a fake clip.
final class FakeVideoProvider: VideoProvider, @unchecked Sendable {
    let name = "Fake video"
    let model = "fake-ltx"
    var jobs: [VideoJob] = []
    func generate(_ job: VideoJob) async throws -> ImageResult {
        jobs.append(job)
        return ImageResult(data: Data("clip".utf8), fileExtension: "mp4")
    }
}

final class VideoTests: XCTestCase {
    private func state(_ goal: String, domain: String, dials: [Dial] = [], avoid: String? = nil) -> WorkingState {
        WorkingState(goal: goal, domainID: domain, dials: dials,
                     constraints: avoid.map { [Constraint(kind: .mustAvoid, text: $0)] } ?? [])
    }

    func testTextAndImageToVideoAreSeparateReadyFields() {
        let ids = Domains.all.map(\.id)
        XCTAssertTrue(ids.contains("t2v"))
        XCTAssertTrue(ids.contains("i2v"))
        XCTAssertTrue(ids.contains("video"), "old storyboard sessions still open")
        XCTAssertTrue(Domains.adapter(for: "t2v").status.isReady)
        XCTAssertTrue(Domains.adapter(for: "i2v").capabilities.needsVideoProvider)
        XCTAssertEqual(Domains.adapter(for: "t2v").capabilities.kind, .video)
    }

    func testSizesFollowLTXRules() {
        let wide = VideoSizing.size(aspect: 16.0 / 9.0, longEdge: 768)
        XCTAssertEqual(wide.width, 768)
        XCTAssertEqual(wide.width % 32, 0)
        XCTAssertEqual(wide.height % 32, 0)
        let tall = VideoSizing.size(aspect: 9.0 / 16.0, longEdge: 512)
        XCTAssertEqual(tall.height, 512)
        XCTAssertLessThan(tall.width, tall.height)
        XCTAssertEqual(VideoSizing.size(aspect: 1, longEdge: 512).width, 512)
        for secs in [0.5, 1.0, 3.3, 8.0] {
            XCTAssertEqual((VideoSizing.frames(seconds: secs, fps: 24) - 1) % 8, 0)
        }
        XCTAssertEqual(VideoSizing.frames(seconds: 1, fps: 24), 25)
    }

    func testStartImagePathIsFoundAnywhereInTheGoal() {
        let a = StartImage.split("/Users/me/Pictures/logo one.png\nslow push-in, stars twinkle")
        XCTAssertEqual(a.path, "/Users/me/Pictures/logo one.png")
        XCTAssertEqual(a.description, "slow push-in, stars twinkle")
        let b = StartImage.split("Animate ~/Desktop/cat.JPG — tail swishes")
        XCTAssertEqual(b.path?.hasSuffix("/Desktop/cat.JPG"), true)
        XCTAssertFalse(b.path?.hasPrefix("~") ?? true)
        XCTAssertTrue(b.description.contains("tail swishes"))
        XCTAssertFalse(b.description.contains("cat.JPG"))
        let c = StartImage.split("a fox running through snow")
        XCTAssertNil(c.path)
        XCTAssertEqual(c.description, "a fox running through snow")
    }

    func testTextToVideoGraphUsesBuiltInLTXNodes() {
        let job = VideoJob(prompt: "p", negative: "n", width: 512, height: 288, frames: 25, steps: 15, seed: 7, quality: .preview)
        let g = ComfyVideoProvider.workflow(for: job, settings: ComfyVideoSettings(), startImageName: nil)
        let classes = Set(g.values.compactMap { ($0 as? [String: Any])?["class_type"] as? String })
        XCTAssertTrue(classes.isSuperset(of: ["CheckpointLoaderSimple", "CLIPLoader", "EmptyLTXVLatentVideo",
                                              "LTXVConditioning", "LTXVScheduler", "SamplerCustom", "VAEDecode",
                                              "CreateVideo", "SaveVideo"]))
        XCTAssertFalse(classes.contains("LTXVImgToVideo"))
        let clip = (g["2"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(clip?["type"] as? String, "ltxv")
        XCTAssertEqual(clip?["clip_name"] as? String, "t5xxl_fp16.safetensors")
        let empty = (g["5"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(empty?["length"] as? Int, 25)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(g))
    }

    func testImageToVideoGraphStartsFromTheUploadedImage() {
        let job = VideoJob(prompt: "p", negative: "n", startImage: Data([1]), width: 512, height: 512, frames: 25,
                           steps: 15, strength: 0.8, seed: 7, quality: .preview)
        let g = ComfyVideoProvider.workflow(for: job, settings: ComfyVideoSettings(), startImageName: "start.png")
        let load = (g["10"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual(load?["image"] as? String, "start.png")
        let i2v = g["5"] as? [String: Any]
        XCTAssertEqual(i2v?["class_type"] as? String, "LTXVImgToVideo")
        XCTAssertEqual((i2v?["inputs"] as? [String: Any])?["strength"] as? Double, 0.8)
        // The conditioning and sampler read the image-to-video node's outputs.
        let cond = (g["6"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual((cond?["negative"] as? [Any])?.first as? String, "5")
        XCTAssertEqual((cond?["negative"] as? [Any])?.last as? Int, 1)
        let sampler = (g["9"] as? [String: Any])?["inputs"] as? [String: Any]
        XCTAssertEqual((sampler?["latent_image"] as? [Any])?.last as? Int, 2)
        let webp = ComfyVideoProvider.workflow(for: job, settings: ComfyVideoSettings(), startImageName: "s.png", container: .webp)
        XCTAssertEqual((webp["13"] as? [String: Any])?["class_type"] as? String, "SaveAnimatedWEBP")
        XCTAssertNil(webp["12"])
    }

    func testTextToVideoPreviewIsShortAndRenderFollowsLength() async throws {
        let fake = FakeVideoProvider()
        let providers = ProviderSet(text: MockTextProvider(), image: nil, video: fake)
        let adapter = TextToVideoAdapter()
        let dials = try await adapter.suggestDials(for: "a fox", using: providers)
        XCTAssertEqual(dials.map(\.name), ["Motion", "Camera move", "Realism", "Mood", "Length"])
        var long = dials
        long[4].value = 100
        let s = state("a fox running through snow", domain: "t2v", dials: long, avoid: "people")

        let preview = try await adapter.generate(adapter.compile(CompileInput(state: s, quality: .preview)), using: providers)
        let render = try await adapter.generate(adapter.compile(CompileInput(state: s, quality: .render)), using: providers)
        XCTAssertEqual(fake.jobs[0].frames, 25, "previews are one second")
        XCTAssertEqual(fake.jobs[0].width, 512)
        XCTAssertEqual(fake.jobs[1].frames, 193, "8 seconds at 24 fps")
        XCTAssertEqual(fake.jobs[1].width, 768)
        XCTAssertGreaterThan(fake.jobs[1].steps, fake.jobs[0].steps)
        XCTAssertNil(fake.jobs[0].startImage)
        XCTAssertTrue(fake.jobs[0].negative.contains("people"), "Must avoid goes to the negative prompt")
        XCTAssertEqual(fake.jobs[0].seed, fake.jobs[1].seed, "preview and render share a seed")
        XCTAssertEqual(preview.output.kind, .video)
        XCTAssertEqual(render.assetExtension, "mp4")
        XCTAssertNotNil(render.output.imagePrompt)
        // Same prompt request for preview and render, so the preview predicts the render.
        XCTAssertEqual(adapter.compile(CompileInput(state: s, quality: .preview)).text,
                       adapter.compile(CompileInput(state: s, quality: .render)).text)
    }

    func testImageToVideoUsesTheImageAndFaithfulness() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prism-i2v-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("start.png")
        // 2×1 PNG (wide), so the clip comes out landscape.
        let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                              0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x7B, 0x40, 0xE8,
                              0xDD, 0x00, 0x00, 0x00, 0x0F, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
                              0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x56, 0xC7, 0x2F, 0x0D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
                              0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
        try Data(bytes).write(to: png)

        let fake = FakeVideoProvider()
        let providers = ProviderSet(text: MockTextProvider(), image: nil, video: fake)
        let adapter = ImageToVideoAdapter()
        var dials = try await adapter.suggestDials(for: "", using: providers)
        dials[2].value = 0 // Faithfulness: free to change
        let s = state("\(png.path)\nthe stars drift slowly", domain: "i2v", dials: dials)
        let request = adapter.compile(CompileInput(state: s, quality: .preview))
        XCTAssertFalse(request.text.user.contains(png.path), "the Art Director gets the words, not the file path")
        XCTAssertTrue(request.text.user.contains("the stars drift slowly"))
        _ = try await adapter.generate(request, using: providers)
        let job = try XCTUnwrap(fake.jobs.first)
        XCTAssertNotNil(job.startImage)
        XCTAssertEqual(job.strength, 0.55, accuracy: 0.001)
        XCTAssertGreaterThan(job.width, job.height)

        dials[2].value = 100
        XCTAssertEqual(ImageToVideoAdapter.strength(CompileInput(state: state("x", domain: "i2v", dials: dials), quality: .preview)), 1, accuracy: 0.001)
    }

    func testImageToVideoWithoutAnImageSaysWhatToDo() async {
        let providers = ProviderSet(text: MockTextProvider(), image: nil, video: FakeVideoProvider())
        let adapter = ImageToVideoAdapter()
        do {
            _ = try await adapter.generate(adapter.compile(CompileInput(state: state("make it move", domain: "i2v"), quality: .preview)), using: providers)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Choose a starting image"))
        }
    }

    func testComfyRepliesAreReadable() {
        let rejection = #"{"error":{"message":"Prompt outputs failed validation"},"node_errors":{"5":{"class_type":"LTXVImgToVideo","errors":[{"message":"Value not in list","details":"strength: unknown input"}]}}}"#
        let reason = ComfyClient.rejectionReason(Data(rejection.utf8))
        XCTAssertTrue(reason.contains("LTXVImgToVideo: strength: unknown input"))
        let outputs: [String: Any] = ["13": ["images": [["filename": "video_0001.mp4", "subfolder": "EthersPrism", "type": "output"]],
                                             "animated": [true]]]
        XCTAssertEqual(ComfyClient.firstFile(in: outputs), .init(name: "video_0001.mp4", subfolder: "EthersPrism", type: "output"))
        let failed: [String: Any] = ["status_str": "error",
                                     "messages": [["execution_error", ["node_type": "CLIPLoader", "exception_message": "out of memory"]]]]
        XCTAssertTrue(ComfyClient.executionError(failed).contains("CLIPLoader: out of memory"))
    }

    func testVideoResultsExportAsTheirFile() throws {
        let store = Store(root: FileManager.default.temporaryDirectory.appendingPathComponent("prism-vid-\(UUID().uuidString)"))
        let path = try store.saveAsset(Data("clip".utf8), ext: "mp4", sessionID: UUID(), name: "a")
        var s = Session(goal: "g")
        s.domainID = "t2v"
        let snap = s.record(Output(kind: .video, assetPath: path, provider: "p", model: "m"), origin: .render, state: s.workingState)
        let file = try XCTUnwrap(Exporter.resultFile(snap, store: store))
        XCTAssertEqual(file.ext, "mp4")
        XCTAssertTrue(Exporter.authorshipLog(s, adapterName: "Text to Video").contains("Video file:"))
    }
}
