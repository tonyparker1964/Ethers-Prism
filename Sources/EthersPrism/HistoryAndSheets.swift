import SwiftUI
import EthersPrismCore

struct HistoryColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(10)
            Divider()
            if let s = model.current {
                let rows = s.treeRows()
                if rows.isEmpty {
                    Text("Every state you visit is kept here. Click one to go back, then move a dial to branch off in a new direction.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    Spacer()
                } else {
                    List(rows) { row in
                        Button { model.restore(row.id) } label: {
                            HStack(spacing: 6) {
                                if row.depth > 0 {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.35))
                                        .frame(width: 2)
                                        .padding(.leading, CGFloat(row.depth - 1) * 10)
                                }
                                Image(systemName: icon(for: row.snapshot))
                                    .foregroundStyle(row.snapshot.chosen ? Color.yellow : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.summary(for: row.snapshot))
                                        .font(.callout)
                                        .lineLimit(2)
                                    Text(row.snapshot.createdAt, style: .time)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(row.id == s.currentSnapshotID
                                           ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
            }
        }
    }

    private func icon(for snap: Snapshot) -> String {
        if snap.chosen { return "star.fill" }
        return snap.quality == .render ? "wand.and.stars" : "circle"
    }
}

struct SweepSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let axis = model.current?.axes.first { $0.id == model.sweepAxisID }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sweep: \(axis?.name ?? "")").font(.title2.bold())
                    Text("Everything else held still. This dial moves from “\(axis?.lowPole ?? "")” to “\(axis?.highPole ?? "")”. Feel what it does, then pick one.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.sweepResults) { r in
                        VStack(spacing: 8) {
                            Text("\(Int(r.value))").font(.headline.monospacedDigit())
                            Group {
                                if let out = r.output {
                                    OutputView(kind: model.adapter.outputKind, text: out)
                                } else if let e = r.error {
                                    Text(e).foregroundStyle(.red).padding()
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(width: 300, height: 380)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            Button("Use this") { model.useSweep(r) }
                                .disabled(r.output == nil)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 540)
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
                Button("Close") { dismiss() }
            }
            HStack(alignment: .top, spacing: 16) {
                column("A", selection: $aID, snaps: snaps, session: session)
                column("B", selection: $bID, snaps: snaps, session: session)
            }
            if let session,
               let a = aID.flatMap({ session.snapshot($0) }),
               let b = bID.flatMap({ session.snapshot($0) }) {
                let diffs = Session.changes(from: a.axes, to: b.axes)
                Text(diffs.isEmpty ? "Same dial settings." : "A → B: " + diffs.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 920, minHeight: 580)
        .onAppear {
            let cur = session?.currentSnapshot
            bID = cur?.id
            aID = cur?.parentID ?? snaps.first?.id
        }
    }

    @ViewBuilder
    private func column(_ label: String, selection: Binding<UUID?>, snaps: [Snapshot], session: Session?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(label, selection: selection) {
                ForEach(Array(snaps.enumerated()), id: \.element.id) { i, snap in
                    Text("#\(i + 1) · \(session?.summary(for: snap) ?? "")")
                        .lineLimit(1)
                        .tag(snap.id as UUID?)
                }
            }
            if let id = selection.wrappedValue, let snap = session?.snapshot(id) {
                OutputView(kind: model.adapter.outputKind, text: snap.output)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("Go to this state") {
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""

    var body: some View {
        Form {
            Picker("AI provider", selection: $model.providerKind) {
                Text("Anthropic (Claude)").tag("anthropic")
                Text("Offline demo (no AI)").tag("mock")
            }
            TextField("Model", text: $model.modelName)
            SecureField("Anthropic API key", text: $keyDraft)
            HStack {
                Button("Save Key") {
                    model.saveAPIKey(keyDraft)
                    keyDraft = ""
                }
                .disabled(keyDraft.trimmed.isEmpty)
                if model.hasAPIKey {
                    Label("Key saved in Keychain", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                }
            }
            Text("Get a key at console.anthropic.com. Offline demo lets you try the instrument without one.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 500)
    }
}
