import SwiftUI
import EthersPrismCore

struct ControlsColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GoalSection()
                DialsSection()
                ConstraintsSection()
                PlaySection()
            }
            .padding()
        }
    }
}

struct GoalSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Goal") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Field", selection: model.domainBinding) {
                    ForEach(Domains.all.indices, id: \.self) { i in
                        let a = Domains.all[i]
                        Text(a.status.isReady ? a.name : "\(a.name) (unfinished)").tag(a.id)
                    }
                }
                if let note = model.adapter.status.note {
                    Banner(style: .info, text: "Unfinished field. \(note)")
                }
                TextField("What do you want to make?", text: model.goalBinding, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Goal")
                HStack {
                    Button {
                        Task { await model.suggestDials() }
                    } label: {
                        Label((model.current?.dials.isEmpty ?? true) ? "Suggest Dials" : "Re-suggest Dials",
                              systemImage: "sparkles")
                    }
                    .disabled(model.suggesting)
                    if model.suggesting { ProgressView().controlSize(.small) }
                }
            }
            .padding(4)
        }
    }
}

struct DialsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Dials") {
            VStack(alignment: .leading, spacing: 16) {
                let dials = model.current?.dials ?? []
                if dials.isEmpty {
                    Text("Describe a goal and let the AI suggest dials, or add your own. Choosing the dials is part of the authorship.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(dials.enumerated()), id: \.element.id) { index, dial in
                        DialRow(dial: model.dialBinding(dial.id), isFirst: index == 0, isLast: index == dials.count - 1)
                    }
                }
                let issues = DialRules.issues(in: dials)
                if !issues.isEmpty {
                    Banner(style: .warning, text: Array(Set(issues.map(\.message))).sorted().joined(separator: " "))
                }
                Button { model.addDial() } label: { Label("Add Dial", systemImage: "plus.circle") }
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct DialRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var dial: Dial
    let isFirst: Bool
    let isLast: Bool
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(dial.name).font(.headline).lineLimit(1)
                    .help(dial.detail)
                Spacer()
                Text("\(dial.intValue)").monospacedDigit().foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button { dial.locked.toggle() } label: {
                    Image(systemName: dial.locked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(dial.locked ? "Unlock \(dial.name)" : "Lock \(dial.name)")
                .help(dial.locked ? "Locked: stays fixed during Explore Nearby and can't be swept" : "Lock this dial")
                Button { editing = true } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Edit \(dial.name)")
                    .help("Rename, redefine, reorder or delete")
                    .popover(isPresented: $editing) {
                        DialEditor(dial: $dial, isFirst: isFirst, isLast: isLast, close: { editing = false })
                    }
            }
            Slider(value: $dial.value, in: 0...100, step: 1)
                .disabled(dial.locked)
                .accessibilityLabel(dial.name)
                .accessibilityValue("\(dial.intValue) of 100. 0 means \(dial.lowPole); 100 means \(dial.highPole).")
            HStack(alignment: .top) {
                Text(dial.lowPole)
                Spacer(minLength: 12)
                Text(dial.highPole).multilineTextAlignment(.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}

struct DialEditor: View {
    @EnvironmentObject var model: AppModel
    @Binding var dial: Dial
    let isFirst: Bool
    let isLast: Bool
    let close: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $dial.name)
            TextField("What it changes", text: $dial.detail, axis: .vertical).lineLimit(1...3)
            TextField("0 means", text: $dial.lowPole)
            TextField("100 means", text: $dial.highPole)
            HStack {
                Button { model.moveDial(dial.id, by: -1) } label: { Label("Move Up", systemImage: "arrow.up") }
                    .disabled(isFirst)
                Button { model.moveDial(dial.id, by: 1) } label: { Label("Move Down", systemImage: "arrow.down") }
                    .disabled(isLast)
                Spacer()
                Button("Delete Dial", role: .destructive) {
                    close()
                    model.removeDial(dial.id)
                }
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct ConstraintsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Fixed requirements") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Things that must always hold, like accuracy, accessibility, required or forbidden content. They are never put on a slider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.current?.constraints ?? []) { c in
                    ConstraintRow(constraint: model.constraintBinding(c.id))
                }
                Menu {
                    ForEach(ConstraintKind.allCases, id: \.self) { kind in
                        Button(kind.label) { model.addConstraint(kind) }
                    }
                } label: {
                    Label("Add Requirement", systemImage: "plus.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct ConstraintRow: View {
    @EnvironmentObject var model: AppModel
    @Binding var constraint: Constraint

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $constraint.isActive)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Use this requirement")
            Picker("", selection: $constraint.kind) {
                ForEach(ConstraintKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Describe the requirement", text: $constraint.text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(constraint.kind.label)
            Button { model.removeConstraint(constraint.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove requirement")
        }
        .opacity(constraint.isActive ? 1 : 0.5)
    }
}

struct PlaySection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GroupBox("Play") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Preview automatically when a dial stops moving", isOn: $model.autoPreview)
                HStack {
                    Button { model.generate(.preview, force: true) } label: { Label("Preview", systemImage: "eye") }
                    Button { model.exploreNearby() } label: { Label("Explore Nearby", systemImage: "dice") }
                        .help("Nudge every unlocked dial a little")
                }
                Button { model.generate(.render, force: true) } label: {
                    Label("Render Full Quality", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                Divider()
                Button { model.showSaveTemplate = true } label: {
                    Label("Save Editor as Template…", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderless)
                .disabled(model.current?.dials.isEmpty ?? true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}
