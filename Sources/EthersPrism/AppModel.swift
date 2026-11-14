import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EthersPrismCore

enum Phase: Equatable {
    case idle
    case working(String)
    case failed(String)
}

struct SweepItem: Identifiable {
    let id = UUID()
    let value: Double
    let state: WorkingState
    var output: Output?
    var error: String?
}

@MainActor
final class AppModel: ObservableObject {
    static let keyAccount = "anthropic-api-key"

    let store = Store()

    @Published var sessions: [Session] = []
    @Published var selectedID: UUID?
    @Published var templates: [EditorTemplate] = []

    @Published var phase: Phase = .idle
    @Published var suggesting = false
    @Published var autoPreview = true
    @Published var alertMessage: String?
    private var lastFailedQuality: Quality = .preview

    @Published var showSweep = false
    @Published var showCompare = false
    @Published var showTemplates = false
    @Published var showSaveTemplate = false
    @Published var sweepOriginID: UUID?
    @Published var sweepDialID: UUID?
    @Published var sweepItems: [SweepItem] = []

    // Settings
    @Published var team: AgentTeam {
        didSet { if let d = try? JSONEncoder().encode(team) { defaults.set(d, forKey: "agentTeam") } }
    }
    @Published var imageProviderKind: String { didSet { defaults.set(imageProviderKind, forKey: "imageProvider") } }
    @Published var comfy: ComfyUISettings {
        didSet { if let d = try? JSONEncoder().encode(comfy) { defaults.set(d, forKey: "comfy") } }
    }
    @Published var comfyVideo: ComfyVideoSettings {
        didSet { if let d = try? JSONEncoder().encode(comfyVideo) { defaults.set(d, forKey: "comfyVideo") } }
    }
    @Published var videoModelChoices: [String] = []
    @Published var videoEncoderChoices: [String] = []
    @Published var videoStatus: String?
    @Published var hasAPIKey: Bool
    @Published var comfyModels: [String] = []
    @Published var comfyStatus: String?
    @Published var localModels: [AgentBackend: [String]] = [:]
    @Published var localStatus: [AgentBackend: String] = [:]

    // Mixar
    @Published var mixarTools: [MCPTool] = []
    @Published var mixarStatus: String?
    private var mixarClient: StdioMCPClient?

    // Sounds for the Beats field
    @Published var soundFolders: [String] { didSet { defaults.set(soundFolders, forKey: "soundFolders") } }
    @Published var sampleIndex = SampleIndex()
    @Published var scanning = false
    @Published var scanStatus: String?
    /// What the Music Producer chose, or why it couldn't help.
    @Published var producerNote: String?
    /// Changes whenever the taste profile does, so views showing it refresh.
    @Published var tasteVersion = 0

    private let defaults = UserDefaults.standard
    private let gate = GenerationGate()
    private let sweepGate = GenerationGate()
    private var genTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    init() {
        let key = Keychain.read(Self.keyAccount) ?? ""
        hasAPIKey = !key.isEmpty
        if let d = UserDefaults.standard.data(forKey: "agentTeam"), let t = try? JSONDecoder().decode(AgentTeam.self, from: d) {
            team = t
        } else {
            team = .local
        }
        imageProviderKind = UserDefaults.standard.string(forKey: "imageProvider") ?? "mock"
        if let d = UserDefaults.standard.data(forKey: "comfy"), let c = try? JSONDecoder().decode(ComfyUISettings.self, from: d) {
            comfy = c
        } else {
            comfy = ComfyUISettings()
        }
        if let d = UserDefaults.standard.data(forKey: "comfyVideo"), let v = try? JSONDecoder().decode(ComfyVideoSettings.self, from: d) {
            comfyVideo = v
        } else {
            comfyVideo = ComfyVideoSettings()
        }
        soundFolders = UserDefaults.standard.stringArray(forKey: "soundFolders") ?? []
        sessions = store.loadAll()
        templates = store.loadTemplates()
        if let d = try? Data(contentsOf: sampleIndexURL), let idx = try? JSONDecoder().decode(SampleIndex.self, from: d) {
            sampleIndex = idx
            BeatsLibrary.shared.index = idx
        }
        if let d = try? Data(contentsOf: tasteURL), let t = try? JSONDecoder().decode(TasteProfile.self, from: d) {
            BeatsLibrary.shared.taste = t
        }
        if sessions.isEmpty { newSession() } else { selectedID = sessions.first?.id }
        startClipboardWatch()
    }

    // MARK: - Blender Script: scripts copied from Claude

    /// What happened with the last script picked up from the clipboard.
    @Published var scriptNote: String?
    private var clipboardTimer: Timer?
    private var lastPasteboardCount = -1

    /// While the Blender Script field is open and Prism is in front, a copied script fills itself in.
    private func startClipboardWatch() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkClipboard() }
        }
    }

    private func checkClipboard() {
        guard adapter.id == "blenderscript", NSApp.isActive else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardCount else { return }
        lastPasteboardCount = pb.changeCount
        guard let raw = pb.string(forType: .string), BlenderScriptAdapter.looksLikeScript(raw) else { return }
        importScript(raw, automatic: true)
    }

    /// Paste Script button: takes whatever is on the clipboard now.
    func pasteScript() {
        lastPasteboardCount = NSPasteboard.general.changeCount
        guard let raw = NSPasteboard.general.string(forType: .string), BlenderScriptAdapter.looksLikeScript(raw) else {
            scriptNote = "The clipboard doesn't hold a Blender script. In Claude, press Copy on the script's code block."
            return
        }
        importScript(raw, automatic: false)
    }

    /// Copies text from Prism itself, without the clipboard watcher treating it as a new script.
    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastPasteboardCount = NSPasteboard.general.changeCount
    }

    /// Saves the script to the library, puts it in a session and previews it.
    func importScript(_ raw: String, automatic: Bool) {
        let script = BlenderScriptAdapter.extractScript(raw)
        if let existing = sessions.first(where: { $0.domainID == "blenderscript" && $0.goal == script }) {
            if !automatic {
                selectedID = existing.id
                scriptNote = "That script is already open here."
            }
            return
        }
        let title = BlenderScriptAdapter.title(of: script)
        let saved: String?
        do { saved = try BlenderScriptAdapter.saveToLibrary(script) } catch { saved = nil }
        if let s = current, s.domainID == "blenderscript", s.goal.trimmed.isEmpty {
            update {
                $0.goal = script
                $0.title = title
                if $0.dials.isEmpty { $0.dials = BlenderScriptAdapter.dials }
            }
        } else {
            let s = Session(title: title, goal: script, domainID: "blenderscript", dials: BlenderScriptAdapter.dials)
            sessions.insert(s, at: 0)
            selectedID = s.id
            try? store.save(s)
        }
        scriptNote = "Got “\(title)” from Claude" + (saved.map { " and saved it as \(($0 as NSString).lastPathComponent)." } ?? ". (It couldn't be saved to the library.)")
        generate(.preview, force: true)
    }

    /// Opens a saved script from the library.
    func openLibraryScript(_ path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            scriptNote = "Couldn't read \((path as NSString).lastPathComponent)."
            return
        }
        importScript(text, automatic: false)
    }

    func openScriptInBlender() {
        guard let s = current else { return }
        do {
            try BlenderScriptAdapter.openInBlender(BlenderScriptAdapter.extractScript(s.goal))
            scriptNote = "Opening in Blender…"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Providers

    /// The text provider for one agent, wrapped so large local models and ComfyUI take turns with memory.
    func provider(for role: AgentRole) -> any TextProvider {
        let a = team.assignment(role)
        let base: any TextProvider
        switch a.backend {
        case .anthropic: base = AnthropicTextProvider(apiKey: Keychain.read(Self.keyAccount) ?? "", model: a.model)
        case .lmStudio: base = OpenAICompatibleTextProvider(name: "LM Studio", baseURL: team.lmStudioURL, model: a.model)
        case .ollama: base = OpenAICompatibleTextProvider(name: "Ollama", baseURL: team.ollamaURL, model: a.model)
        case .mock: base = MockTextProvider()
        }
        var worker = base
        if team.teachByExample, let examples = TeachByExample.examples(for: role, in: sessions) {
            worker = ExampleTaughtTextProvider(inner: base, examples: examples)
        }
        if team.memoryHandoff && a.backend.isLocal && (imageProviderKind == "comfyui" || adapter.capabilities.needsVideoProvider) {
            return MemoryAwareTextProvider(inner: worker, comfyURL: comfy.baseURL)
        }
        return worker
    }

    var imageProvider: (any ImageProvider)? {
        switch imageProviderKind {
        case "comfyui":
            let comfyProvider = ComfyUIImageProvider(settings: comfy)
            return team.memoryHandoff ? MemoryAwareImageProvider(inner: comfyProvider, lmStudioURL: team.lmStudioURL) : comfyProvider
        case "svg": return ClaudeSVGImageProvider(text: provider(for: .artDirector))
        default: return MockImageProvider()
        }
    }

    var providers: ProviderSet {
        var agents: [AgentRole: any TextProvider] = [:]
        for role in AgentRole.allCases { agents[role] = provider(for: role) }
        return ProviderSet(text: provider(for: .writer), image: imageProvider, agents: agents, video: videoProvider)
    }

    /// Video always runs through ComfyUI (same address as images) with LTX Video.
    var videoProvider: any VideoProvider {
        ComfyVideoProvider(baseURL: comfy.baseURL, settings: comfyVideo,
                           lmStudioURL: team.memoryHandoff ? team.lmStudioURL : nil)
    }

    /// The agents the current field actually uses.
    var activeRoles: [AgentRole] {
        // Beats are made from your samples directly; only the Music Producer helps set them up.
        if adapter.id == "beats" { return [.producer] }
        if adapter.id == "image", current?.imageReference != nil { return [] }
        var roles: [AgentRole] = [.dialDesigner]
        if adapter.capabilities.needsImageProvider || adapter.capabilities.needsVideoProvider { roles.append(.artDirector) }
        else if adapter.capabilities.kind == .code { roles.append(.coder) }
        else { roles.append(.writer) }
        if team.checkerEnabled { roles.append(.checker) }
        return roles
    }

    /// A setup step that is still missing for the current field, in plain words.
    var configurationIssue: String? {
        if adapter.id == "beats", sampleIndex.isEmpty {
            return "Add your sample folders in Settings → Sounds → Add Folders…. The scan starts by itself."
        }
        let needKey = activeRoles.filter { team.assignment($0).backend == .anthropic }
        if !needKey.isEmpty && !hasAPIKey {
            return "\(needKey.map(\.title).joined(separator: ", ")) use Claude, but no Anthropic API key is set. Add one in Settings → Agents, or switch those agents to LM Studio."
        }
        let noModel = activeRoles.filter { team.assignment($0).backend != .mock && team.assignment($0).model.trimmed.isEmpty }
        if !noModel.isEmpty {
            return "Choose a model for \(noModel.map(\.title).joined(separator: ", ")) in Settings → Agents."
        }
        if adapter.capabilities.needsImageProvider && imageProviderKind == "comfyui" && comfy.checkpoint.trimmed.isEmpty {
            return "Choose a ComfyUI model in Settings before generating images."
        }
        if adapter.capabilities.needsVideoProvider
            && (comfyVideo.checkpoint.trimmed.isEmpty || comfyVideo.textEncoder.trimmed.isEmpty) {
            return "Choose the LTX Video model and its text encoder in Settings → Video."
        }
        return nil
    }

    var usingMock: Bool {
        // Beats are always real audio; a mock producer just means standard dials.
        if adapter.id == "beats" { return false }
        return activeRoles.contains { team.assignment($0).backend == .mock }
            || (adapter.capabilities.needsImageProvider && imageProviderKind == "mock")
    }

    // MARK: - Current session

    var current: Session? { sessions.first { $0.id == selectedID } }

    var adapter: any DomainAdapter { Domains.adapter(for: current?.domainID ?? "text") }

    func update(_ change: (inout Session) -> Void) {
        guard let id = selectedID else { return }
        updateSession(id, change)
    }

    func updateSession(_ id: UUID, _ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        sessions[i].updatedAt = Date()
        do { try store.save(sessions[i]) } catch { alertMessage = "Couldn't save: \(error.localizedDescription)" }
    }

    var goalBinding: Binding<String> {
        Binding(get: { self.current?.goal ?? "" }, set: { v in
            self.update {
                $0.setGoal(v)
                if $0.domainID == "blenderscript" { $0.title = BlenderScriptAdapter.title(of: v) }
            }
        })
    }

    var domainBinding: Binding<String> {
        Binding(get: { self.current?.domainID ?? "text" }, set: { v in self.update { $0.domainID = v } })
    }

    func dialBinding(_ id: UUID) -> Binding<Dial> {
        Binding(
            get: { self.current?.dials.first(where: { $0.id == id }) ?? Dial(name: "", lowPole: "", highPole: "") },
            set: { new in
                let old = self.current?.dials.first(where: { $0.id == id })
                self.update { $0.updateDial(new) }
                if let old, old.intValue != new.intValue { self.dialsChanged() }
            })
    }

    func constraintBinding(_ id: UUID) -> Binding<Constraint> {
        Binding(
            get: { self.current?.constraints.first(where: { $0.id == id }) ?? Constraint(kind: .other, text: "") },
            set: { new in
                self.update { s in
                    if let i = s.constraints.firstIndex(where: { $0.id == id }) { s.constraints[i] = new }
                }
            })
    }

    // MARK: - Sessions and templates

    func newSession() {
        let s = Session()
        sessions.insert(s, at: 0)
        selectedID = s.id
        try? store.save(s)
    }

    /// Opens a 3D model file in a new 3D Stage session, ready for camera and lighting dials.
    func openInStage(_ modelPath: String) {
        // Previews keep their model in a temporary folder macOS clears; keep a copy with the exports.
        var path = modelPath
        if !path.hasPrefix(ModelFromImageAdapter.modelsFolder) {
            let dest = (ModelFromImageAdapter.modelsFolder as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            try? FileManager.default.createDirectory(atPath: ModelFromImageAdapter.modelsFolder, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: dest) { try? FileManager.default.copyItem(atPath: path, toPath: dest) }
            if FileManager.default.fileExists(atPath: dest) { path = dest }
        }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let s = Session(title: name, goal: path, domainID: "stage")
        sessions.insert(s, at: 0)
        selectedID = s.id
        try? store.save(s)
    }

    @Published private(set) var creatingDrawing = false

    func drawingProject(for sessionID: UUID) -> URL {
        store.assetsDir.appendingPathComponent(sessionID.uuidString).appendingPathComponent("Drawing.blend")
    }

    func openGreasePencilDrawing(reference: URL? = nil, automaticTrace: Bool = false, multiShot: Bool = false, walkPoses: [URL] = []) {
        guard !creatingDrawing else { return }
        let existing = adapter.id == "linelogo" && reference == nil && walkPoses.isEmpty ? current : nil
        let session = existing ?? Session(title: walkPoses.isEmpty ? "Grease Pencil Drawing" : "Walk Cycle", domainID: "linelogo")
        let drawing = drawingProject(for: session.id)
        let projectName = multiShot ? "Multi-Shot.blend" : "Auto Trace.blend"
        let project = automaticTrace ? drawing.deletingLastPathComponent().appendingPathComponent(projectName) : drawing
        let blender = URL(fileURLWithPath: BlenderStageAdapter.blenderPath)
        guard FileManager.default.isExecutableFile(atPath: blender.path) else {
            alertMessage = "Install Blender in Applications to open a Grease Pencil drawing."
            return
        }
        if FileManager.default.fileExists(atPath: project.path) {
            NSWorkspace.shared.open([project], withApplicationAt: blender.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent(), configuration: .init()) { _, error in
                if let error { Task { @MainActor in self.alertMessage = error.localizedDescription } }
            }
            return
        }
        let reference = reference ?? existing.flatMap { GreasePencilLogoAdapter.imagePath(from: $0.goal) }
            .map { URL(fileURLWithPath: $0) }
        let folder = project.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let script = folder.appendingPathComponent("Create Drawing.py")
            let movie = folder.appendingPathComponent(multiShot ? "Multi-Shot Animation" : (automaticTrace ? "Auto Trace Animation" : "Animation"))
            let setup: String
            if !walkPoses.isEmpty {
                setup = try GreasePencilProject.walkScript(poses: walkPoses)
            } else if automaticTrace, let reference {
                var state = session.workingState
                state.goal = reference.path
                setup = try GreasePencilLogoAdapter.editableTrace(state, project: project, movie: movie, multiShot: multiShot)
            } else {
                setup = GreasePencilProject.setupScript
            }
            try setup.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = blender
            process.arguments = GreasePencilProject.arguments(for: project, script: script, reference: reference,
                                                              movie: movie)
            try process.run()
            if existing == nil {
                try store.save(session)
                sessions.insert(session, at: 0)
                selectedID = session.id
            }
            creatingDrawing = true
            Task {
                defer {
                    creatingDrawing = false
                    try? FileManager.default.removeItem(at: script)
                }
                for _ in 0..<120 {
                    if FileManager.default.fileExists(atPath: project.path) { return }
                    if !process.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if !FileManager.default.fileExists(atPath: project.path) {
                    alertMessage = "Blender didn't save the drawing. Check the Blender window and try again."
                }
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func renderPhotoReveal4K() {
        guard let goal = current?.goal, let path = GreasePencilLogoAdapter.imagePath(from: goal),
              let image = NSImage(contentsOfFile: path), image.size.width > 0, image.size.height > 0 else {
            alertMessage = "Choose a readable image first."
            return
        }
        let preset: [String: Double] = [
            "Resolution": 100, "Framing": image.size.height > image.size.width ? 100 : 0,
            "Photo reveal": 100, "Stroke opacity": 0, "Glow": 0, "Texture fidelity": 100,
            "Anti-aliasing": 60, "Exposure": 50, "Contrast": 50, "Saturation": 50,
            "Warmth": 50, "Light falloff": 0, "Camera push": 0
        ]
        applyGreasePencilStyle(preset)
        generate(.render, force: true)
    }

    func applyGreasePencilStyle(_ preset: [String: Double]) {
        let values = Dictionary(uniqueKeysWithValues: preset.map { ($0.key.lowercased(), $0.value) })
        update { session in
            let names = Set(session.dials.map { $0.name.lowercased() })
            session.dials += GreasePencilLogoAdapter.standardDials.filter { !names.contains($0.name.lowercased()) }
            for index in session.dials.indices {
                if let value = values[session.dials[index].name.lowercased()] {
                    session.dials[index].value = value
                }
            }
        }
    }

    func chooseWalkPoses() {
        let panel = NSOpenPanel()
        panel.title = "Choose Walk Poses"
        panel.message = "Choose four or eight transparent PNGs named in playback order (01.png, 02.png, …)."
        panel.allowedContentTypes = [.png]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let poses = panel.urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard [4, 8].contains(poses.count) else {
            alertMessage = "Choose four or eight pose images."
            return
        }
        openGreasePencilDrawing(walkPoses: poses)
    }

    func importGreasePencilAnimation() {
        guard let session = current else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = drawingProject(for: session.id).deletingLastPathComponent()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let asset = try store.saveAsset(Data(contentsOf: url, options: .mappedIfSafe),
                                            ext: url.pathExtension, sessionID: session.id, name: UUID().uuidString)
            updateSession(session.id) {
                $0.record(Output(kind: .video, text: url.lastPathComponent, assetPath: asset,
                                 provider: "Blender", model: "Grease Pencil"), origin: .imported, state: session.workingState)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func openInLineLogo(_ url: URL) {
        var s = Session(title: "Image variation animation", domainID: "linelogo")
        do {
            let asset = try store.saveAsset(Data(contentsOf: url), ext: url.pathExtension,
                                            sessionID: s.id, name: "source-image")
            guard let source = store.assetURL(asset) else {
                throw PrismError.local("Couldn't locate the copied image.")
            }
            s.goal = source.path
            try store.save(s)
            sessions.insert(s, at: 0)
            selectedID = s.id
        } catch {
            alertMessage = "Couldn't create the Line Logo session: \(error.localizedDescription)"
        }
    }

    func newSession(from template: EditorTemplate, goal: String) {
        let s = template.makeSession(goal: goal)
        sessions.insert(s, at: 0)
        selectedID = s.id
        try? store.save(s)
        showTemplates = false
        generate(.preview, force: true)
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.delete(id)
        if selectedID == id { selectedID = sessions.first?.id }
        if sessions.isEmpty { newSession() }
    }

    func saveTemplate(name: String, summary: String, replacing existing: EditorTemplate?) {
        guard let s = current else { return }
        var t = EditorTemplate.from(s, name: name.trimmed.isEmpty ? "Untitled editor" : name.trimmed, summary: summary)
        if let existing {
            t.id = existing.id
            t.builtIn = existing.builtIn
        }
        do {
            try store.saveTemplate(t)
            templates = store.loadTemplates()
            update { $0.templateID = t.id }
        } catch {
            alertMessage = "Couldn't save the template: \(error.localizedDescription)"
        }
        showSaveTemplate = false
    }

    func deleteTemplate(_ id: UUID) {
        store.deleteTemplate(id)
        templates = store.loadTemplates()
    }

    // MARK: - Dials and constraints

    func addDial() {
        update { $0.addDial(Dial(name: "New dial", lowPole: "less", highPole: "more")) }
    }

    func removeDial(_ id: UUID) { update { $0.removeDial(id) } }

    func moveDial(_ id: UUID, by offset: Int) { update { $0.moveDial(id, by: offset) } }

    func addConstraint(_ kind: ConstraintKind) {
        update { $0.constraints.append(Constraint(kind: kind, text: "")) }
    }

    func removeConstraint(_ id: UUID) {
        update { s in s.constraints.removeAll { c in c.id == id } }
    }

    /// Fields that work without a goal: Line Logo uses the emblem, Animation and 3D Stage their samples.
    var goalOptional: Bool {
        ["linelogo", "animate", "stage"].contains(adapter.id)
            || (adapter.id == "image" && current?.imageReference != nil)
    }

    func suggestDials() async {
        guard let s = current, goalOptional || !s.goal.trimmed.isEmpty else {
            alertMessage = "Describe what you want to make first."
            return
        }
        suggesting = true
        defer { suggesting = false }
        if adapter.id == "image", s.imageReference != nil {
            generate(.preview, force: true)
            return
        }
        if adapter.id == "beats" {
            await suggestBeatDials(s)
            return
        }
        do {
            let selectedAdapter = adapter
            let dials = try await selectedAdapter.suggestDials(for: s.goal, using: providers)
            updateSession(s.id) { session in
                if selectedAdapter.id == "linelogo" {
                    let names = Set(session.dials.map { $0.name.lowercased() })
                    session.dials += dials.filter { !names.contains($0.name.lowercased()) }
                } else {
                    session.dials = dials
                }
            }
            generate(.preview, force: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Beats: standard dials, then the Music Producer (if it's set up) picks the style, kits and starting positions.
    /// Its picks show up as dial positions and as "Style:" and "Kit:" requirements you can edit or delete.
    private func suggestBeatDials(_ s: Session) async {
        guard let base = try? await adapter.suggestDials(for: s.goal, using: providers) else { return }
        var dials = base
        var constraints = s.constraints
        producerNote = nil
        if !sampleIndex.isEmpty {
            // The AI producer when one is set up; the built-in one (no AI) when it's off or can't answer.
            let taste = BeatsLibrary.shared.taste
            var plan = BeatProducer.builtIn(goal: s.goal, kits: sampleIndex.drumKits, taste: taste)
            var who = "Built-in producer (no AI)"
            var fellBack: String?
            if team.assignment(.producer).backend != .mock {
                let agent = provider(for: .producer)
                do {
                    plan = try await BeatProducer.plan(goal: s.goal, index: sampleIndex, constraints: s.constraints,
                                                       using: agent, taste: taste)
                    who = "Music Producer (\(agent.name))"
                } catch {
                    fellBack = error.localizedDescription
                }
            }
            do {
                dials = BeatProducer.apply(plan, to: base)
                constraints = BeatProducer.constraints(for: plan, keeping: s.constraints)
                if let style = plan.style {
                    // Tempo poles follow the style the producer chose, not just the goal's words.
                    let lo = Int(style.tempo.lowerBound), hi = Int(style.tempo.upperBound)
                    if let i = dials.firstIndex(where: { $0.name.lowercased() == "tempo" }) {
                        dials[i].lowPole = "\(lo) BPM"
                        dials[i].highPole = "\(hi) BPM"
                        dials[i].detail = "Speed within the \(style.name.lowercased()) range."
                    }
                }
                let kits = plan.kits.isEmpty ? "" : " Kits: \(plan.kits.joined(separator: ", "))."
                var note = "\(who): \(plan.note.isEmpty ? "set up the dials." : plan.note)\(kits)"
                if let fellBack { note += " (The AI producer couldn't answer: \(fellBack))" }
                producerNote = note
            }
        }
        updateSession(s.id) {
            $0.dials = dials
            $0.constraints = constraints
        }
        generate(.preview, force: true)
    }

    /// Waits until the dials stop moving, then previews once.
    func dialsChanged() {
        // Video previews take minutes, so they start only when the person presses Preview.
        guard autoPreview, adapter.capabilities.kind != .video else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self?.generate(.preview)
        }
    }

    func exploreNearby() {
        var rng = SystemRandomNumberGenerator()
        update { $0.nudgeUnlocked(spread: 18, using: &rng) }
        generate(.preview, force: true)
    }

    // MARK: - Generation

    /// Starts a generation. Older requests are cancelled and their late answers ignored.
    /// An automatic preview of a state that is already showing is skipped.
    func generate(_ quality: Quality, force: Bool = false) {
        guard let s = current else { return }
        guard goalOptional || !s.goal.trimmed.isEmpty else {
            phase = .failed(adapter.id == "blenderscript"
                ? "Copy a Blender script from Claude and it fills in here by itself (or press Paste Script)."
                : "Describe what you want to make first.")
            return
        }
        let issues = DialRules.issues(in: s.dials)
        guard issues.isEmpty else {
            phase = .failed(issues.map(\.message).joined(separator: " "))
            return
        }
        let state = s.workingState
        if quality == .preview, !force, let cur = s.currentSnapshot, cur.state.generatesSame(as: state) { return }

        debounceTask?.cancel()
        genTask?.cancel()
        let ticket = gate.begin()
        let adapter = self.adapter
        let providers = self.providers
        let store = self.store
        let sessionID = s.id
        lastFailedQuality = quality
        phase = .working(quality == .preview ? "Previewing…" : "Rendering full quality…")

        genTask = Task { [weak self] in
            do {
                let request = adapter.compile(CompileInput(state: state, quality: quality))
                let generated = try await adapter.generate(request, using: providers)
                guard let self, self.gate.isCurrent(ticket) else { return }
                var output = generated.output
                if let data = generated.asset {
                    let name = UUID().uuidString
                    output.assetPath = try store.saveAsset(data, ext: generated.assetExtension ?? "bin",
                                                           sessionID: sessionID, name: name)
                    for (ext, extra) in generated.extraAssets {
                        _ = try store.saveAsset(extra, ext: ext, sessionID: sessionID, name: name)
                    }
                }
                var snapID: UUID?
                self.updateSession(sessionID) {
                    snapID = $0.record(output, origin: quality == .render ? .render : .preview, state: state).id
                }
                self.phase = .idle
                if let snapID { self.review(snapID, in: sessionID, output: output, constraints: state.constraints) }
            } catch {
                guard let self, self.gate.isCurrent(ticket) else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.phase = .idle
                } else {
                    self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    func retry() { generate(lastFailedQuality, force: true) }

    func cancelGeneration() {
        genTask?.cancel()
        gate.invalidate()
        phase = .idle
    }

    // MARK: - History

    func restore(_ id: UUID) {
        debounceTask?.cancel()
        update { $0.restore(id) }
    }

    func toggleChosen() {
        guard let id = current?.currentSnapshotID else { return }
        update { $0.toggleChosen(id) }
    }

    func saveManualEdit(_ text: String) {
        update { $0.recordManualEdit(text: text) }
    }

    // MARK: - Sweep

    func sweep(dialID: UUID) {
        guard let s = current else { return }
        let variants: [SweepVariant]
        do {
            variants = try Sweep.variants(of: s.workingState, dialID: dialID)
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        guard goalOptional || !s.goal.trimmed.isEmpty else {
            alertMessage = "Describe what you want to make first."
            return
        }
        let ticket = sweepGate.begin()
        sweepOriginID = s.currentSnapshotID
        sweepDialID = dialID
        sweepItems = variants.map { SweepItem(value: $0.value, state: $0.state) }
        showSweep = true

        let adapter = self.adapter
        let providers = self.providers
        let store = self.store
        let sessionID = s.id
        for (i, v) in variants.enumerated() {
            Task { [weak self] in
                do {
                    let generated = try await adapter.generate(
                        adapter.compile(CompileInput(state: v.state, quality: .preview)), using: providers)
                    guard let self, self.sweepGate.isCurrent(ticket), self.sweepItems.indices.contains(i) else { return }
                    var output = generated.output
                    if let data = generated.asset {
                        let name = "sweep-\(UUID().uuidString)"
                        output.assetPath = try store.saveAsset(data, ext: generated.assetExtension ?? "bin",
                                                               sessionID: sessionID, name: name)
                        for (ext, extra) in generated.extraAssets {
                            _ = try store.saveAsset(extra, ext: ext, sessionID: sessionID, name: name)
                        }
                    }
                    self.sweepItems[i].output = output
                } catch {
                    guard let self, self.sweepGate.isCurrent(ticket), self.sweepItems.indices.contains(i) else { return }
                    self.sweepItems[i].error = error.localizedDescription
                }
            }
        }
    }

    /// Saves the picked variant as a branch from the state the sweep started from.
    func useSweep(_ item: SweepItem) {
        guard let output = item.output else { return }
        let dialName = item.state.dials.first { $0.id == sweepDialID }?.name ?? "dial"
        let origin = sweepOriginID
        update { s in
            s.recordChild(of: origin, output, origin: .sweep, state: item.state,
                          note: "sweep: \(dialName) at \(Int(item.value))")
            s.workingState = item.state
        }
        closeSweep()
    }

    func closeSweep() {
        sweepGate.invalidate()
        showSweep = false
    }

    // MARK: - Files

    func assetURL(_ output: Output) -> URL? { store.assetURL(output.assetPath) }

    func copyResult() {
        guard let out = current?.currentSnapshot?.output else { return }
        NSPasteboard.general.clearContents()
        if out.kind == .audio, let url = assetURL(out) {
            NSPasteboard.general.writeObjects([url as NSURL])
        } else if let text = out.text {
            NSPasteboard.general.setString(text, forType: .string)
        } else if let url = assetURL(out), let img = NSImage(contentsOf: url) {
            NSPasteboard.general.writeObjects([img])
        }
    }

    /// Writes the selected result, the portable session file and the authorship log into a folder.
    func export() {
        guard let s = current, let snap = s.currentSnapshot else {
            alertMessage = "Generate something first, then export it."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the result, the session file and the authorship log."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let base = Exporter.safeFileName(s.title)
        do {
            if let file = Exporter.resultFile(snap, store: store) {
                try file.data.write(to: dir.appendingPathComponent("\(base) — result.\(file.ext)"), options: .atomic)
            }
            // A beat also comes with its MIDI file, for use in Maschine, Logic or any DAW.
            if snap.output.kind == .audio, let url = assetURL(snap.output),
               let midi = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("mid")) {
                try midi.write(to: dir.appendingPathComponent("\(base) — beat.mid"), options: .atomic)
            }
            try store.exportData(s).write(to: dir.appendingPathComponent("\(base) — session.json"), options: .atomic)
            try Exporter.authorshipLog(s, adapterName: adapter.name)
                .write(to: dir.appendingPathComponent("\(base) — authorship.md"), atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("\(base) — authorship.md")])
        } catch {
            alertMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose an Ethers Prism session file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let s = try store.importSession(from: url)
            sessions.insert(s, at: 0)
            selectedID = s.id
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    // MARK: - Checker

    /// Asks the Checker agent to review a result against the fixed requirements. Never changes the result.
    func review(_ snapshotID: UUID, in sessionID: UUID, output: Output, constraints: [Constraint]) {
        guard team.checkerEnabled, let request = Checker.request(for: output, constraints: constraints) else { return }
        let checker = provider(for: .checker)
        let reviewer = "Checker · \(checker.name) \(checker.model)"
        Task { [weak self] in
            let review: Review
            do {
                review = Checker.parse(try await checker.complete(request), reviewer: reviewer)
            } catch {
                review = Review(passed: false, issues: ["Review failed: \(error.localizedDescription)"], reviewer: reviewer)
            }
            self?.updateSession(sessionID) { $0.setReview(review, for: snapshotID) }
        }
    }

    // MARK: - Settings

    func saveAPIKey(_ key: String) {
        let ok = Keychain.write(key.trimmed, Self.keyAccount)
        hasAPIKey = ok && !key.trimmed.isEmpty
        if !ok { alertMessage = "The Keychain refused to store the key." }
    }

    func checkComfy() async {
        comfyStatus = "Checking…"
        do {
            comfyModels = try await ComfyUIImageProvider.checkpoints(baseURL: comfy.baseURL)
            comfyStatus = comfyModels.isEmpty ? "Connected, but no models were found." : "Connected. \(comfyModels.count) models found."
            if comfy.checkpoint.isEmpty, let first = comfyModels.first { comfy.checkpoint = first }
        } catch {
            comfyModels = []
            comfyStatus = error.localizedDescription
        }
    }

    /// Reads which LTX checkpoints and text encoders ComfyUI can load.
    func checkVideo() async {
        videoStatus = "Checking…"
        let client = ComfyClient(baseURL: comfy.baseURL)
        do {
            let all = try await client.options(node: "CheckpointLoaderSimple", input: "ckpt_name")
            let encoders = try await client.options(node: "CLIPLoader", input: "clip_name")
            _ = try await client.options(node: "LTXVImgToVideo", input: "vae")
            videoModelChoices = all.filter { $0.lowercased().contains("ltx") }
            videoEncoderChoices = encoders.filter { $0.lowercased().contains("t5") }
            let hasModel = videoModelChoices.contains(comfyVideo.checkpoint)
            let hasEncoder = videoEncoderChoices.contains(comfyVideo.textEncoder)
            if !hasModel, let first = videoModelChoices.first { comfyVideo.checkpoint = first }
            if !hasEncoder, let first = videoEncoderChoices.first { comfyVideo.textEncoder = first }
            switch (videoModelChoices.isEmpty, videoEncoderChoices.isEmpty) {
            case (true, true): videoStatus = "ComfyUI is ready for LTX Video, but the model and the T5 text encoder aren't downloaded yet."
            case (true, false): videoStatus = "The LTX Video model isn't in ComfyUI's checkpoints folder yet."
            case (false, true): videoStatus = "The T5 text encoder isn't in ComfyUI's text encoders folder yet."
            case (false, false): videoStatus = "Ready. LTX Video and its text encoder were found."
            }
        } catch {
            videoModelChoices = []
            videoEncoderChoices = []
            videoStatus = error.localizedDescription
        }
    }

    func checkLocal(_ backend: AgentBackend) async {
        let url = backend == .lmStudio ? team.lmStudioURL : team.ollamaURL
        localStatus[backend] = "Checking…"
        do {
            let models = try await OpenAICompatibleTextProvider.models(baseURL: url)
            localModels[backend] = models
            localStatus[backend] = models.isEmpty ? "Connected, but no models were found." : "Connected. \(models.count) models available."
        } catch {
            localModels[backend] = []
            localStatus[backend] = error.localizedDescription
        }
    }

    func assignmentBinding(_ role: AgentRole) -> Binding<AgentAssignment> {
        Binding(get: { self.team.assignment(role) }, set: { self.team.set($0) })
    }

    // MARK: - Sounds

    var sampleIndexURL: URL { store.root.appendingPathComponent("SampleIndex.json") }
    var tasteURL: URL { store.root.appendingPathComponent("Taste.json") }

    /// Like (+1) or "not for me" (-1) on a beat. Pressing the same one again clears it.
    /// Teaches the local taste profile which sounds, kits and dial positions you like.
    func rateBeat(_ snapshotID: UUID, _ rating: Int) {
        guard let s = current, let snap = s.snapshots.first(where: { $0.id == snapshotID }) else { return }
        let old = snap.output.rating ?? 0
        let new = old == rating ? 0 : rating
        updateSession(s.id) { session in
            if let i = session.snapshots.firstIndex(where: { $0.id == snapshotID }) {
                session.snapshots[i].output.rating = new == 0 ? nil : new
            }
        }
        let paths = snap.output.samples ?? []
        let groups = paths.compactMap { p in sampleIndex.files.first { $0.path == p }?.group }
        var taste = BeatsLibrary.shared.taste
        taste.rate(samples: paths, kits: groups, style: BeatsAdapter.style(for: snap.state).id,
                   dials: BeatParameters(dials: snap.state.dials), from: old, to: new)
        BeatsLibrary.shared.taste = taste
        if let d = try? JSONEncoder().encode(taste) { try? d.write(to: tasteURL, options: .atomic) }
        tasteVersion += 1
    }

    func forgetTaste() {
        BeatsLibrary.shared.taste = TasteProfile()
        try? FileManager.default.removeItem(at: tasteURL)
        tasteVersion += 1
    }

    func addSoundFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders with your samples, for example your Native Instruments drive or its Maschine expansions folder."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !soundFolders.contains(url.path) { soundFolders.append(url.path) }
        scanSounds()
    }

    func removeSoundFolder(_ path: String) {
        soundFolders.removeAll { $0 == path }
        scanSounds()
    }

    /// Reads every folder in the background and saves the result, so the next launch doesn't rescan.
    func scanSounds() {
        guard !scanning else { return }
        let missing = soundFolders.filter { !FileManager.default.fileExists(atPath: $0) }
        scanning = true
        scanStatus = "Scanning… big libraries can take a minute."
        let roots = soundFolders.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        let indexURL = sampleIndexURL
        Task.detached(priority: .userInitiated) {
            let idx = SampleScanner.scan(roots: roots)
            if let d = try? JSONEncoder().encode(idx) { try? d.write(to: indexURL, options: .atomic) }
            BeatsLibrary.shared.index = idx
            await self.finishScan(idx, missing: missing)
        }
    }

    private func finishScan(_ idx: SampleIndex, missing: [String]) {
        sampleIndex = idx
        scanning = false
        var status = "Found \(idx.files.count) samples in \(idx.groups.count) kits."
        if idx.lockedCount > 0 {
            status += " Skipped \(idx.lockedCount) files in Native Instruments' locked formats (those play only inside Kontakt or Maschine)."
        }
        if !missing.isEmpty { status += " Not connected: \(missing.joined(separator: ", "))." }
        scanStatus = status
    }

    // MARK: - Mixar

    func connectMixar() async {
        mixarStatus = "Connecting…"
        mixarClient?.stop()
        do {
            let (client, tools) = try await Mixar.connect()
            mixarClient = client
            mixarTools = tools
            mixarStatus = "Connected. Mixar offers \(tools.count) tools."
        } catch {
            mixarTools = []
            mixarStatus = error.localizedDescription
        }
    }
}
