import SwiftUI
import EthersPrismCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("showHistory") private var showHistory = true
    @State private var search = ""

    var body: some View {
        NavigationSplitView {
            SessionSidebar(search: $search)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            if let s = model.current {
                HStack(spacing: 0) {
                    ControlsColumn()
                        .frame(width: 350)
                    Divider()
                    OutputColumn()
                        .frame(minWidth: 360, maxWidth: .infinity)
                }
                .navigationTitle(SessionTitle.display(s.title))
                .navigationSubtitle(model.adapter.name)
                .toolbar { WorkspaceToolbar(showHistory: $showHistory) }
                .inspector(isPresented: $showHistory) {
                    HistoryColumn()
                        .inspectorColumnWidth(min: 230, ideal: 260, max: 360)
                }
            } else {
                ContentUnavailableView {
                    Label("No Session", systemImage: "dial.medium")
                } description: {
                    Text("Build the instrument, then play it.")
                } actions: {
                    Button("New Session") { model.newSession() }
                }
            }
        }
        .alert("Ethers Prism",
               isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alertMessage ?? "")
        }
        .sheet(isPresented: Binding(get: { model.showSweep }, set: { if !$0 { model.closeSweep() } })) {
            SweepSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showCompare) {
            CompareSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showTemplates) {
            TemplatesSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showSaveTemplate) {
            SaveTemplateSheet().environmentObject(model)
        }
    }
}

/// Session names for display: a session named after a file shows the file's name, not its whole path.
enum SessionTitle {
    static func display(_ title: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "Untitled" }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            let name = ((t.components(separatedBy: .newlines).first ?? t) as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            return stem.isEmpty ? name : stem
        }
        return t
    }
}

/// Each field's color, used for its icon in the sidebar and toolbar.
enum FieldStyle {
    static func color(_ id: String) -> Color {
        if Domains.isRetired(id) { return .gray }
        switch id {
        case "text": return .blue
        case "image": return .pink
        case "stage": return .orange
        case "model3d": return .teal
        case "animate": return .purple
        case "linelogo": return .indigo
        case "blenderscript": return .green
        case "beats": return .red
        default: return .secondary
        }
    }
}

/// Sessions grouped by field, with search.
struct SessionSidebar: View {
    @EnvironmentObject var model: AppModel
    @Binding var search: String

    private var groups: [(field: any DomainAdapter, sessions: [Session])] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = model.sessions.filter {
            q.isEmpty || SessionTitle.display($0.title).lowercased().contains(q)
                || Domains.adapter(for: $0.domainID).name.lowercased().contains(q)
        }
        let order = Domains.all.map(\.id) + Domains.retired.map(\.id)
        return order.compactMap { id in
            let items = visible.filter { $0.domainID == id }
            return items.isEmpty ? nil : (Domains.adapter(for: id), items)
        }
    }

    var body: some View {
        List(selection: $model.selectedID) {
            ForEach(groups, id: \.field.id) { group in
                Section(Domains.isRetired(group.field.id) ? "\(group.field.name) (retired)" : group.field.name) {
                    ForEach(group.sessions) { s in
                        SessionRow(session: s)
                            .tag(s.id as UUID?)
                            .contextMenu {
                                Button("Delete Session", role: .destructive) { model.delete(s.id) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search sessions")
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 10) {
                AppLogo(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ether's Prism").font(.headline)
                    Text("Build the instrument, then play it.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Text("Version \(AppVersion.number)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Session") { model.newSession() }
                    Button("New from Template…") { model.showTemplates = true }
                    Divider()
                    Button("Import Session…") { model.importSession() }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                } primaryAction: {
                    model.newSession()
                }
                .help("New session (click and hold for templates and import)")
            }
        }
    }
}

struct SessionRow: View {
    let session: Session

    var body: some View {
        let field = Domains.adapter(for: session.domainID)
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(SessionTitle.display(session.title)).lineLimit(1)
                Text(session.updatedAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: field.symbol)
                .foregroundStyle(FieldStyle.color(field.id))
        }
        .padding(.vertical, 2)
        .help(session.title)
    }
}

/// The window toolbar: what is happening, the result's actions, and Preview / Render.
struct WorkspaceToolbar: ToolbarContent {
    @EnvironmentObject var model: AppModel
    @Binding var showHistory: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .status) {
            if case .working(let what) = model.phase {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(what).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Button("Cancel") { model.cancelGeneration() }.controlSize(.small)
                }
                .fixedSize()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(model.current?.dials ?? []) { d in
                    Button(d.locked ? "\(d.name) (locked: unlock to sweep)" : d.name) { model.sweep(dialID: d.id) }
                        .disabled(d.locked)
                }
            } label: {
                Label("Sweep", systemImage: "slider.horizontal.3")
            }
            .help("Five previews of one dial at 0, 25, 50, 75 and 100")
            .disabled(model.current?.dials.isEmpty ?? true)
            Button { model.showCompare = true } label: { Label("Compare", systemImage: "rectangle.split.2x1") }
                .help("Compare two states side by side")
                .disabled((model.current?.snapshots.count ?? 0) < 2)
            Button { model.toggleChosen() } label: {
                Label("Chosen", systemImage: model.current?.currentSnapshot?.chosen == true ? "star.fill" : "star")
            }
            .help("Mark this state as chosen")
            .disabled(model.current?.currentSnapshot == nil)
            Button { model.copyResult() } label: { Label("Copy", systemImage: "doc.on.doc") }
                .help("Copy result")
                .disabled(model.current?.currentSnapshot == nil)
            Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .help("Export the result, session file and authorship log")
                .disabled(model.current?.currentSnapshot == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.generate(.preview, force: true) } label: { Label("Preview", systemImage: "eye") }
                .help("Preview (⇧⌘P)")
            Button { model.generate(.render, force: true) } label: { Label("Render", systemImage: "wand.and.stars") }
                .help("Render Full Quality (⌘R)")
            Button { showHistory.toggle() } label: { Label("History", systemImage: "sidebar.right") }
                .help(showHistory ? "Hide History" : "Show History")
        }
    }
}

/// A small colored note used for setup, failure and limitation messages.
struct Banner: View {
    enum Style { case info, warning, error }
    let style: Style
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch style {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }

    private var color: Color {
        switch style {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
