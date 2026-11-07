import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EthersPrismCore

struct SweepResult: Identifiable {
    let id = UUID()
    let value: Double
    var output: String?
    var error: String?
}

@MainActor
final class AppModel: ObservableObject {
    static let keyAccount = "anthropic-api-key"

    @Published var sessions: [Session] = []
    @Published var selectedID: UUID?
    @Published var isGenerating = false
    @Published var isSuggesting = false
    @Published var errorMessage: String?
    @Published var autoPreview = true

    @Published var showSweep = false
    @Published var showCompare = false
    @Published var sweepAxisID: UUID?
    @Published var sweepResults: [SweepResult] = []

    @Published var providerKind: String {
        didSet { UserDefaults.standard.set(providerKind, forKey: "providerKind") }
    }
    @Published var modelName: String {
        didSet { UserDefaults.standard.set(modelName, forKey: "modelName") }
    }
    @Published var hasAPIKey: Bool

    private let store = SessionStore()
    private var previewTask: Task<Void, Never>?
    private var generationToken = UUID()
    private var sweepToken = UUID()

    init() {
        let key = Keychain.read(Self.keyAccount) ?? ""
        hasAPIKey = !key.isEmpty
        // First run with no key: start in offline demo so the instrument works immediately.
        providerKind = UserDefaults.standard.string(forKey: "providerKind") ?? (key.isEmpty ? "mock" : "anthropic")
        modelName = UserDefaults.standard.string(forKey: "modelName") ?? "claude-sonnet-5-5"
        sessions = store.loadAll()
        if sessions.isEmpty { newSession() } else { selectedID = sessions.first?.id }
    }

    // MARK: - Current session

    var current: Session? { sessions.first { $0.id == selectedID } }

    var adapter: any DomainAdapter { Domains.adapter(for: current?.domainID ?? "text") }

    var provider: any ModelProvider {
        providerKind == "mock"
            ? MockProvider()
            : AnthropicProvider(apiKey: Keychain.read(Self.keyAccount) ?? "", model: modelName)
    }

    func update(_ change: (inout Session) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&sessions[i])
        sessions[i].updatedAt = Date()
        try? store.save(sessions[i])
    }

    var goalBinding: Binding<String> {
        Binding(get: { self.current?.goal ?? "" },
                set: { value in
                    self.update {
                        $0.goal = value
                        $0.title = value.trimmed.isEmpty ? "Untitled" : String(value.trimmed.prefix(48))
                    }
                })
    }

    var domainBinding: Binding<String> {
        Binding(get: { self.current?.domainID ?? "text" },
                set: { value in self.update { $0.domainID = value } })
    }

    func axisBinding(_ id: UUID) -> Binding<Dial> {
        Binding(get: { self.current?.axes.first(where: { $0.id == id }) ?? Dial(name: "", lowPole: "", highPole: "") },
                set: { new in
                    self.update { s in
                        if let i = s.axes.firstIndex(where: { $0.id == id }) { s.axes[i] = new }
                    }
                })
    }

    // MARK: - Sessions

    func newSession() {
        let s = Session()
        sessions.insert(s, at: 0)
        selectedID = s.id
        try? store.save(s)
    }

    func delete(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        store.delete(id)
        if selectedID == id { selectedID = sessions.first?.id }
        if sessions.isEmpty { newSession() }
    }

    // MARK: - Dials

    func addAxis() {
        update { $0.axes.append(Dial(name: "New dial", lowPole: "less", highPole: "more")) }
    }

    func removeAxis(_ id: UUID) {
        update { s in s.axes.removeAll { axis in axis.id == id } }
    }

    func suggestAxes() async {
        guard let s = current, !s.goal.trimmed.isEmpty else {
            errorMessage = "Describe what you want to make first."
            return
        }
        isSuggesting = true
        do {
            let text = try await provider.complete(AxisSuggester.request(goal: s.goal, adapter: adapter))
            let axes = try AxisSuggester.parse(text)
            update { $0.axes = axes }
            isSuggesting = false
            await generate(.preview)
        } catch {
            isSuggesting = false
            errorMessage = error.localizedDescription
        }
    }

    /// Called when a slider is released. Waits briefly so a flurry of moves becomes one preview.
    func dialsChanged() {
        guard autoPreview else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await self?.generate(.preview)
        }
    }

    /// Nudges every unlocked dial a little and previews the result.
    func exploreNearby() {
        update { s in
            for i in s.axes.indices where !s.axes[i].locked {
                s.axes[i].value = min(100, max(0, s.axes[i].value + Double.random(in: -18...18))).rounded()
            }
        }
        Task { await generate(.preview) }
    }

    // MARK: - Generation

    func generate(_ quality: Quality) async {
        guard let s = current else { return }
        guard !s.goal.trimmed.isEmpty else {
            errorMessage = "Describe what you want to make first."
            return
        }
        let sessionID = s.id
        let usedAxes = s.axes
        let request = adapter.compile(goal: s.goal, axes: usedAxes, quality: quality)
        let kind = adapter.outputKind
        let token = UUID()
        generationToken = token
        isGenerating = true
        do {
            let raw = try await provider.complete(request)
            guard token == generationToken else { return } // a newer request replaced this one
            let output = OutputCleaner.clean(raw, kind: kind)
            if let i = sessions.firstIndex(where: { $0.id == sessionID }) {
                sessions[i].record(output: output, quality: quality, axes: usedAxes)
                try? store.save(sessions[i])
            }
        } catch {
            if token == generationToken, !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }
        if token == generationToken { isGenerating = false }
    }

    // MARK: - History

    func restore(_ id: UUID) {
        update { $0.restore(id) }
    }

    func toggleChosen() {
        guard let id = current?.currentSnapshotID else { return }
        update { $0.toggleChosen(id) }
    }

    // MARK: - Sweep

    func sweep(axisID: UUID) {
        guard let s = current else { return }
        let values: [Double] = [0, 25, 50, 75, 100]
        let token = UUID()
        sweepToken = token
        sweepAxisID = axisID
        sweepResults = values.map { SweepResult(value: $0) }
        showSweep = true

        let adapter = self.adapter
        let provider = self.provider
        let kind = adapter.outputKind
        for (i, v) in values.enumerated() {
            var axes = s.axes
            if let j = axes.firstIndex(where: { $0.id == axisID }) { axes[j].value = v }
            let request = adapter.compile(goal: s.goal, axes: axes, quality: .preview)
            Task {
                do {
                    let raw = try await provider.complete(request)
                    self.setSweep(i, token: token, output: OutputCleaner.clean(raw, kind: kind), error: nil)
                } catch {
                    self.setSweep(i, token: token, output: nil, error: error.localizedDescription)
                }
            }
        }
    }

    private func setSweep(_ index: Int, token: UUID, output: String?, error: String?) {
        guard token == sweepToken, sweepResults.indices.contains(index) else { return }
        sweepResults[index].output = output
        sweepResults[index].error = error
    }

    func useSweep(_ result: SweepResult) {
        guard let axisID = sweepAxisID, let output = result.output else { return }
        update { s in
            if let i = s.axes.firstIndex(where: { $0.id == axisID }) { s.axes[i].value = result.value }
            s.record(output: output, quality: .preview)
        }
        showSweep = false
    }

    // MARK: - Output

    func copyResult() {
        guard let output = current?.currentSnapshot?.output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
    }

    func export() {
        guard let s = current, s.currentSnapshot != nil else { return }
        let panel = NSSavePanel()
        let safeTitle = s.title.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeTitle) — authorship.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Exporter.authorshipLog(s, adapter: adapter).write(to: url, atomically: true, encoding: .utf8)
            if adapter.outputKind == .svg, let svg = s.currentSnapshot?.output {
                try svg.write(to: url.deletingPathExtension().appendingPathExtension("svg"),
                              atomically: true, encoding: .utf8)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Settings

    func saveAPIKey(_ key: String) {
        Keychain.write(key.trimmed, Self.keyAccount)
        hasAPIKey = !key.trimmed.isEmpty
        if hasAPIKey { providerKind = "anthropic" }
    }
}
