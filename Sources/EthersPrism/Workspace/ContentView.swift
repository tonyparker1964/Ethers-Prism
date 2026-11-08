import SwiftUI
import EthersPrismCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.sessions) { s in
                    Label(s.title, systemImage: Domains.adapter(for: s.domainID).symbol)
                        .lineLimit(1)
                        .tag(s.id as UUID?)
                        .contextMenu {
                            Button("Delete Session", role: .destructive) { model.delete(s.id) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New Session") { model.newSession() }
                        Button("New from Template…") { model.showTemplates = true }
                        Divider()
                        Button("Import Session…") { model.importSession() }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .help("New session, template or import")
                }
            }
        } detail: {
            if model.current != nil {
                HSplitView {
                    ControlsColumn()
                        .frame(minWidth: 320, idealWidth: 370, maxWidth: 480)
                    OutputColumn()
                        .frame(minWidth: 440, maxWidth: .infinity)
                    HistoryColumn()
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 340)
                }
            } else {
                Text("Create a session to begin.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ethers Prism")
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
