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
    @Published var textProviderKind: String { didSet { defaults.set(textProviderKind, forKey: "textProvider") } }
    @Published var modelName: String { didSet { defaults.set(modelName, forKey: "modelName") } }
    @Published var imageProviderKind: String { didSet { defaults.set(imageProviderKind, forKey: "imageProvider") } }
    @Published var comfy: ComfyUISettings {
        didSet { if let d = try? JSONEncoder().encode(comfy) { defaults.set(d, forKey: "comfy") } }
    }
    @Published var hasAPIKey: Bool
    @Published var comfyModels: [String] = []
    @Published var comfyStatus: String?

    private let defaults = UserDefaults.standard
    private let gate = GenerationGate()
    private let sweepGate = GenerationGate()
    private var genTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    init() {
        let key = Keychain.read(Self.keyAccount) ?? ""
        hasAPIKey = !key.isEmpty
        textProviderKind = UserDefaults.standard.string(forKey: "textProvider") ?? (key.isEmpty ? "mock" : "anthropic")
        modelName = UserDefaults.standard.string(forKey: "modelName") ?? "claude-sonnet-5-5"
        imageProviderKind = UserDefaults.standard.string(forKey: "imageProvider") ?? "mock"
        if let d = UserDefaults.standard.data(forKey: "comfy"), let c = try? JSONDecoder().decode(ComfyUISettings.self, from: d) {
            comfy = c
        } else {
            comfy = ComfyUISettings()
        }
        sessions = store.loadAll()
        templates = store.loadTemplates()
        if sessions.isEmpty { newSession() } else { selectedID = sessions.first?.id }
    }

    // MARK: - Providers

    var textProvider: any TextProvider {
        textProviderKind == "mock"
            ? MockTextProvider()
            : AnthropicTextProvider(apiKey: Keychain.read(Self.keyAccount) ?? "", model: modelName)
    }

    var imageProvider: (any ImageProvider)? {
        switch imageProviderKind {
        case "comfyui": return ComfyUIImageProvider(settings: comfy)
        case "svg": return ClaudeSVGImageProvider(text: textProvider)
        default: return MockImageProvider()
        }
    }

    var providers: ProviderSet { ProviderSet(text: textProvider, image: imageProvider) }

    /// A setup step that is still missing for the current field, in plain words.
    var configurationIssue: String? {
        if textProviderKind == "anthropic" && !hasAPIKey {
            return "No Anthropic API key yet. Add one in Settings, or use the Mock provider to test."
        }
        if adapter.capabilities.needsImageProvider && imageProviderKind == "comfyui" && comfy.checkpoint.trimmed.isEmpty {
            return "Choose a ComfyUI model in Settings before generating images."
        }
        return nil
    }

    var usingMock: Bool {
        textProviderKind == "mock" || (adapter.capabilities.needsImageProvider && imageProviderKind == "mock")
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
        Binding(get: { self.current?.goal ?? "" }, set: { v in self.update { $0.setGoal(v) } })
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

    func suggestDials() async {
        guard let s = current, !s.goal.trimmed.isEmpty else {
            alertMessage = "Describe what you want to make first."
            return
        }
        suggesting = true
        defer { suggesting = false }
        do {
            let dials = try await adapter.suggestDials(for: s.goal, using: providers)
            updateSession(s.id) { $0.dials = dials }
            generate(.preview, force: true)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Waits until the dials stop moving, then previews once.
    func dialsChanged() {
        guard autoPreview else { return }
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
        guard !s.goal.trimmed.isEmpty else {
            phase = .failed("Describe what you want to make first.")
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
                    output.assetPath = try store.saveAsset(data, ext: generated.assetExtension ?? "bin",
                                                           sessionID: sessionID, name: UUID().uuidString)
                }
                self.updateSession(sessionID) {
                    $0.record(output, origin: quality == .render ? .render : .preview, state: state)
                }
                self.phase = .idle
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
        guard !s.goal.trimmed.isEmpty else {
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
                        output.assetPath = try store.saveAsset(data, ext: generated.assetExtension ?? "bin",
                                                               sessionID: sessionID, name: "sweep-\(UUID().uuidString)")
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
        if let text = out.text {
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

    // MARK: - Settings

    func saveAPIKey(_ key: String) {
        let ok = Keychain.write(key.trimmed, Self.keyAccount)
        hasAPIKey = ok && !key.trimmed.isEmpty
        if !ok { alertMessage = "The Keychain refused to store the key." }
        if hasAPIKey { textProviderKind = "anthropic" }
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
}
