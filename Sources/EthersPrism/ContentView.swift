import SwiftUI
import EthersPrismCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.sessions) { s in
                    Label(s.title.isEmpty ? "Untitled" : s.title,
                          systemImage: Domains.adapter(for: s.domainID).symbol)
                        .lineLimit(1)
                        .tag(s.id as UUID?)
                        .contextMenu {
                            Button("Delete", role: .destructive) { model.delete(s.id) }
                        }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button { model.newSession() } label: {
                        Label("New Session", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if model.current != nil {
                WorkspaceView()
            } else {
                Text("Create a session to begin.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ethers Prism")
        .alert("Something went wrong",
               isPresented: Binding(get: { model.errorMessage != nil },
                                    set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.showSweep) {
            SweepSheet().environmentObject(model)
        }
        .sheet(isPresented: $model.showCompare) {
            CompareSheet().environmentObject(model)
        }
    }
}

struct WorkspaceView: View {
    var body: some View {
        HSplitView {
            ControlsColumn()
                .frame(minWidth: 300, idealWidth: 350, maxWidth: 460)
            OutputColumn()
                .frame(minWidth: 420, maxWidth: .infinity)
            HistoryColumn()
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)
        }
    }
}

// MARK: - Goal and dials

struct ControlsColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Goal") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Field", selection: model.domainBinding) {
                            ForEach(Domains.all.indices, id: \.self) { i in
                                Label(Domains.all[i].name, systemImage: Domains.all[i].symbol)
                                    .tag(Domains.all[i].id)
                            }
                        }
                        TextField("What do you want to make?", text: model.goalBinding, axis: .vertical)
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button {
                                Task { await model.suggestAxes() }
                            } label: {
                                Label((model.current?.axes.isEmpty ?? true) ? "Suggest Dials" : "Re-suggest Dials",
                                      systemImage: "sparkles")
                            }
                            .disabled(model.isSuggesting)
                            if model.isSuggesting { ProgressView().controlSize(.small) }
                        }
                    }
                    .padding(4)
                }

                GroupBox("Dials") {
                    VStack(alignment: .leading, spacing: 16) {
                        let axes = model.current?.axes ?? []
                        if axes.isEmpty {
                            Text("Describe a goal, then let the AI suggest dials, or add your own. Choosing the dials is part of the authorship.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(axes) { axis in
                                AxisRow(axis: model.axisBinding(axis.id),
                                        onCommit: { model.dialsChanged() },
                                        onDelete: { model.removeAxis(axis.id) })
                            }
                        }
                        Button { model.addAxis() } label: {
                            Label("Add Dial", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("Play") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Auto-preview when a dial moves", isOn: $model.autoPreview)
                        HStack {
                            Button { Task { await model.generate(.preview) } } label: {
                                Label("Preview", systemImage: "eye")
                            }
                            Button { model.exploreNearby() } label: {
                                Label("Explore Nearby", systemImage: "dice")
                            }
                            .help("Nudge every unlocked dial a little")
                        }
                        Button { Task { await model.generate(.render) } } label: {
                            Label("Render Full Quality", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }
            .padding()
        }
    }
}

struct AxisRow: View {
    @Binding var axis: Dial
    var onCommit: () -> Void
    var onDelete: () -> Void
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(axis.name).font(.headline).lineLimit(1)
                Spacer()
                Text("\(Int(axis.value.rounded()))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { axis.locked.toggle() } label: {
                    Image(systemName: axis.locked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.borderless)
                .help(axis.locked ? "Unlock this dial" : "Lock this dial so Explore Nearby keeps it fixed")
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename or redefine this dial")
                    .popover(isPresented: $editing) {
                        AxisEditor(axis: $axis, onDelete: {
                            editing = false
                            onDelete()
                        })
                    }
            }
            Slider(value: $axis.value, in: 0...100, onEditingChanged: { isEditing in
                if !isEditing { onCommit() }
            })
            .disabled(axis.locked)
            HStack(alignment: .top) {
                Text(axis.lowPole)
                Spacer(minLength: 12)
                Text(axis.highPole).multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct AxisEditor: View {
    @Binding var axis: Dial
    var onDelete: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $axis.name)
            TextField("0 means", text: $axis.lowPole)
            TextField("100 means", text: $axis.highPole)
            Button("Delete Dial", role: .destructive, action: onDelete)
        }
        .padding()
        .frame(width: 340)
    }
}
