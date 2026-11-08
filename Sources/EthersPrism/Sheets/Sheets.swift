import SwiftUI
import EthersPrismCore

struct SweepSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let dial = model.sweepItems.first?.state.dials.first { $0.id == model.sweepDialID }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sweep: \(dial?.name ?? "")").font(.title2.bold())
                    Text("Every other dial and requirement is held fixed. This one moves from “\(dial?.lowPole ?? "")” (0) to “\(dial?.highPole ?? "")” (100). Picking one saves it as a branch from where you started.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Close") { model.closeSweep() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.sweepItems) { item in
                        VStack(spacing: 8) {
                            Text("\(dial?.name ?? "Value") = \(Int(item.value))")
                                .font(.headline.monospacedDigit())
                            Group {
                                if let out = item.output {
                                    OutputPreview(output: out)
                                } else if let e = item.error {
                                    Text(e).foregroundStyle(.red).padding()
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(width: 300, height: 360)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button("Use This") { model.useSweep(item) }
                                .disabled(item.output == nil)
                                .accessibilityLabel("Use the version at \(Int(item.value))")
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(20)
        .frame(minWidth: 960, minHeight: 540)
    }
}

struct CompareSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var aID: UUID?
    @State private var bID: UUID?

    var body: some View {
        let session = model.current
        let snaps = session?.snapshots ?? []
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top, spacing: 16) {
                column("A", selection: $aID, snaps: snaps, session: session)
                column("B", selection: $bID, snaps: snaps, session: session)
            }
            if let session,
               let a = aID.flatMap({ session.snapshot($0) }),
               let b = bID.flatMap({ session.snapshot($0) }) {
                differences(a, b)
            }
        }
        .padding(20)
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            let cur = session?.currentSnapshot
            bID = cur?.id
            aID = cur?.parentID ?? snaps.first?.id
        }
    }

    @ViewBuilder
    private func differences(_ a: Snapshot, _ b: Snapshot) -> some View {
        let changes = StateDiff.changes(from: a.state, to: b.state)
        GroupBox("A → B") {
            VStack(alignment: .leading, spacing: 4) {
                if a.state.goal.trimmed != b.state.goal.trimmed {
                    Text("Goal A: \(a.state.goal)").font(.callout)
                    Text("Goal B: \(b.state.goal)").font(.callout)
                }
                Text(changes.isEmpty ? "Same goal, dials and requirements." : changes.joined(separator: " · "))
                    .font(.callout)
                if a.origin == .manualEdit || b.origin == .manualEdit {
                    Text("At least one side includes hand edits.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func column(_ label: String, selection: Binding<UUID?>, snaps: [Snapshot], session: Session?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(label, selection: selection) {
                ForEach(Array(snaps.enumerated()), id: \.element.id) { i, snap in
                    Text("#\(i + 1) · \(snap.origin.label) · \(session?.summary(for: snap) ?? "")")
                        .lineLimit(1)
                        .tag(snap.id as UUID?)
                }
            }
            if let id = selection.wrappedValue, let snap = session?.snapshot(id) {
                OutputPreview(output: snap.output)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Text(snap.state.dials.map { "\($0.name) \($0.intValue)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let fixed = Compiler.describe(snap.state.constraints)
                if !fixed.isEmpty {
                    Text(fixed).font(.caption).foregroundStyle(.secondary)
                }
                Button("Go to This State") {
                    model.restore(id)
                    dismiss()
                }
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TemplatesSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New from Template").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Goal for the new session", text: $goal, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
            Text("A template brings its dials and requirements. The new session starts with no history.")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(model.templates) { t in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: Domains.adapter(for: t.domainID).symbol)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(t.name).font(.headline)
                            if t.builtIn { Text("Example").font(.caption2).foregroundStyle(.secondary) }
                        }
                        if !t.summary.isEmpty { Text(t.summary).font(.callout) }
                        Text(t.dials.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use") { model.newSession(from: t, goal: goal) }
                        .disabled(goal.trimmed.isEmpty)
                        .help(goal.trimmed.isEmpty ? "Type a goal first" : "Start a new session with this editor")
                    Button { model.deleteTemplate(t.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete template \(t.name)")
                }
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct SaveTemplateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""

    private var existing: EditorTemplate? {
        guard let id = model.current?.templateID else { return nil }
        return model.templates.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Editor as Template").font(.title2.bold())
            Text("Saves the dials (with their current values as defaults) and the requirements. The goal and history are not included.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            TextField("Description", text: $summary, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if let existing {
                    Button("Update “\(existing.name)”") {
                        model.saveTemplate(name: name, summary: summary, replacing: existing)
                    }
                }
                Button("Save as New Template") {
                    model.saveTemplate(name: name, summary: summary, replacing: nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            name = existing?.name ?? ""
            summary = existing?.summary ?? ""
        }
    }
}
