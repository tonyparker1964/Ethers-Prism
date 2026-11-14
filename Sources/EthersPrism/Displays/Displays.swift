import SwiftUI
import WebKit
import AVKit
import AVFoundation
import EthersPrismCore

/// The display for each kind of output lives here, in the UI layer, separate from the adapters.
/// A new output kind needs one new case below.
struct ResultDisplay: View {
    let snapshot: Snapshot
    let editable: Bool

    var body: some View {
        switch snapshot.output.kind {
        case .text:
            TextResultView(snapshot: snapshot, editable: editable, monospaced: false)
        case .code:
            TextResultView(snapshot: snapshot, editable: editable, monospaced: true)
        case .storyboard:
            StoryboardResultView(snapshot: snapshot, editable: editable)
        case .image:
            ImageResultView(output: snapshot.output)
        case .video:
            VideoResultView(output: snapshot.output)
        case .audio:
            AudioResultView(output: snapshot.output, snapshotID: snapshot.id)
        }
    }
}

/// Read-only rendering for sweep and compare.
struct OutputPreview: View {
    let output: Output

    var body: some View {
        switch output.kind {
        case .text, .code:
            ScrollView {
                Text(markdown(output.text ?? ""))
                    .font(output.kind == .code ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .storyboard:
            ScrollView { StoryboardCards(text: output.text ?? "").padding(10) }
        case .image:
            ImageResultView(output: output, showPrompt: false)
        case .video:
            VideoResultView(output: output, showPrompt: false)
        case .audio:
            AudioResultView(output: output, compact: true)
        }
    }
}

func markdown(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(s)
}

/// Editable text. Saving an edit makes a new history state; regenerating never overwrites it.
struct TextResultView: View {
    @EnvironmentObject var model: AppModel
    let snapshot: Snapshot
    let editable: Bool
    let monospaced: Bool
    @State private var draft = ""
    @State private var isEditing = false

    private var original: String { snapshot.output.text ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                TextEditor(text: $draft)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .accessibilityLabel("Result text")
            } else {
                ScrollView {
                    Text(markdown(original))
                        .font(monospaced ? .system(.body, design: .monospaced) : .body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            if editable {
                Divider()
                HStack {
                    if isEditing {
                        Text(draft == original ? "Editing" : "Unsaved changes")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Discard") {
                            draft = original
                            isEditing = false
                        }
                        Button("Save Edit as New State") {
                            model.saveManualEdit(draft)
                            isEditing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original)
                    } else {
                        Spacer()
                        Button {
                            draft = original
                            isEditing = true
                        } label: {
                            Label("Edit Text", systemImage: "pencil")
                        }
                    }
                }
                .padding(8)
            }
        }
        .onAppear { draft = original }
    }
}

struct StoryboardResultView: View {
    let snapshot: Snapshot
    let editable: Bool
    @State private var showText = false

    var body: some View {
        VStack(spacing: 0) {
            if showText {
                TextResultView(snapshot: snapshot, editable: editable, monospaced: false)
            } else {
                ScrollView { StoryboardCards(text: snapshot.output.text ?? "").padding(16) }
            }
            Divider()
            HStack {
                Spacer()
                Toggle("Show as text", isOn: $showText).toggleStyle(.switch).controlSize(.small)
            }
            .padding(8)
        }
    }
}

struct StoryboardCards: View {
    let text: String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            ForEach(Storyboard.parse(text)) { scene in
                VStack(alignment: .leading, spacing: 6) {
                    Text(scene.title).font(.headline)
                    Text(markdown(scene.body)).textSelection(.enabled)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}

struct ImageResultView: View {
    @EnvironmentObject var model: AppModel
    let output: Output
    var showPrompt = true

    var body: some View {
        VStack(spacing: 8) {
            if let url = model.assetURL(output), FileManager.default.fileExists(atPath: url.path) {
                if url.pathExtension.lowercased() == "svg" {
                    SVGView(url: url)
                } else if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(output.imagePrompt ?? "Generated image")
                } else {
                    missing("The image file couldn't be read.")
                }
            } else {
                missing("Image file not found. Imported sessions don't include media files.")
            }
            if showPrompt, let url = model.assetURL(output),
               GreasePencilLogoAdapter.imageExtensions.contains(url.pathExtension.lowercased()),
               FileManager.default.fileExists(atPath: url.path) {
                Button("Open in Line Logo") { model.openInLineLogo(url) }
                Button("Open in Blender for Drawing") { model.openGreasePencilDrawing(reference: url) }
                    .disabled(model.creatingDrawing)
            }
            if showPrompt, let prompt = output.imagePrompt {
                DisclosureGroup("Image prompt") {
                    Text(prompt).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
        .padding(showPrompt ? 12 : 0)
    }

    private func missing(_ text: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary)
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Plays a clip on a loop. MP4 plays in a standard player; an animated WebP (older ComfyUI) animates in an image view.
struct VideoResultView: View {
    @EnvironmentObject var model: AppModel
    let output: Output
    var showPrompt = true

    var body: some View {
        VStack(spacing: 8) {
            if let url = model.assetURL(output), FileManager.default.fileExists(atPath: url.path) {
                if ["webp", "gif"].contains(url.pathExtension.lowercased()) {
                    AnimatedImageView(url: url)
                } else {
                    // Blender animations carry the song they pulse to, so the main player plays sound.
                    LoopingPlayerView(url: url, muted: !(showPrompt && output.provider == "Blender"))
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "film").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Video file not found. Imported sessions don't include media files.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showPrompt {
                if let summary = output.text {
                    Text(summary).font(.caption).foregroundStyle(.secondary)
                }
                if let prompt = output.imagePrompt {
                    DisclosureGroup("Video prompt") {
                        Text(prompt).font(.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .padding(showPrompt ? 12 : 0)
    }
}

/// AVPlayerView that loops one file and swaps players only when the file changes.
struct LoopingPlayerView: NSViewRepresentable {
    let url: URL
    var muted = true

    final class Coordinator {
        var url: URL?
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        load(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if context.coordinator.url != url { load(view, context.coordinator) }
    }

    private func load(_ view: AVPlayerView, _ c: Coordinator) {
        let player = AVQueuePlayer()
        player.isMuted = muted
        c.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        c.url = url
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        view.player?.pause()
        coordinator.looper = nil
    }
}

struct AnimatedImageView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = NSImage(contentsOf: url)
        return v
    }

    func updateNSView(_ v: NSImageView, context: Context) {
        v.image = NSImage(contentsOf: url)
    }
}

/// Renders SVG with WebKit, reloading only when the file changes.
struct SVGView: NSViewRepresentable {
    let url: URL

    final class Coordinator { var last: URL? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.last != url, let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
        context.coordinator.last = url
        let html = """
        <html><head><style>
        html,body{margin:0;height:100%;background:transparent;}
        body{display:flex;align-items:center;justify-content:center;}
        svg{max-width:98%;max-height:98%;width:auto;height:auto;}
        </style></head><body>\(svg)</body></html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - Audio

/// One player for the whole app, so starting a beat stops the one before it.
final class BeatPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = BeatPlayer()
    @Published private(set) var playingURL: URL?
    private var player: AVAudioPlayer?

    func play(_ url: URL, loop: Bool) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.numberOfLoops = loop ? -1 : 0
        p.delegate = self
        p.play()
        player = p
        playingURL = url
    }

    func toggle(_ url: URL, loop: Bool) {
        if playingURL == url { stop() } else { play(url, loop: loop) }
    }

    func stop() {
        player?.stop()
        player = nil
        playingURL = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            if self.player === player {
                self.player = nil
                self.playingURL = nil
            }
        }
    }
}

struct AudioResultView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var player = BeatPlayer.shared
    @AppStorage("beatLoop") private var loop = true
    let output: Output
    var snapshotID: UUID?
    var compact = false
    @State private var peaks: [Float] = []

    var body: some View {
        if let url = model.assetURL(output), FileManager.default.fileExists(atPath: url.path) {
            VStack(spacing: 10) {
                Waveform(peaks: peaks, active: player.playingURL == url)
                    .frame(height: compact ? 70 : 140)
                    .contentShape(Rectangle())
                    .onTapGesture { player.toggle(url, loop: loop) }
                    .accessibilityLabel("Waveform. Click to play or stop.")
                HStack {
                    Button {
                        player.toggle(url, loop: loop)
                    } label: {
                        Label(player.playingURL == url ? "Stop" : "Play",
                              systemImage: player.playingURL == url ? "stop.fill" : "play.fill")
                    }
                    if !compact {
                        Toggle("Loop", isOn: $loop).toggleStyle(.switch).controlSize(.small)
                        if let id = snapshotID {
                            Divider().frame(height: 16)
                            Button { model.rateBeat(id, 1) } label: {
                                Label("Like", systemImage: output.rating == 1 ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }
                            .help("Teach Prism: more sounds and settings like this")
                            Button { model.rateBeat(id, -1) } label: {
                                Label("Not for me", systemImage: output.rating == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            }
                            .help("Teach Prism: fewer sounds like these")
                        }
                        Spacer()
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                if !compact {
                    ScrollView {
                        Text(markdown(output.text ?? ""))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Export writes the WAV and a MIDI file of the same beat (drums on channel 10, bass on channel 2).")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(compact ? 6 : 16)
            .task(id: url) {
                if let data = try? Data(contentsOf: url) { peaks = BeatAudio.peaks(ofWAV: data, count: 300) }
                // While you're listening, each new version takes over so you hear dial changes right away.
                if !compact, let playing = player.playingURL, playing != url { player.play(url, loop: loop) }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "waveform").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Audio file not found. Imported sessions don't include media files.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct Waveform: View {
    let peaks: [Float]
    let active: Bool

    var body: some View {
        Canvas { context, size in
            guard !peaks.isEmpty else { return }
            let w = size.width / CGFloat(peaks.count)
            let mid = size.height / 2
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let h = max(1, CGFloat(p) * size.height * 0.95)
                path.addRect(CGRect(x: CGFloat(i) * w, y: mid - h / 2, width: max(1, w * 0.7), height: h))
            }
            context.fill(path, with: .color(active ? Color.accentColor : Color.secondary))
        }
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}
