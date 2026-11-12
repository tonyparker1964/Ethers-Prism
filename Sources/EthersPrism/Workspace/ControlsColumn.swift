import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EthersPrismCore

struct ControlsColumn: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            GoalSection()
            DialsSection()
            ConstraintsSection()
            PlaySection()
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 10) {
                    Button { model.generate(.preview, force: true) } label: {
                        Label("Preview", systemImage: "eye").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .help("Preview (⇧⌘P)")
                    Button { model.generate(.render, force: true) } label: {
                        Label("Render", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Render Full Quality (⌘R)")
                }
                .padding(12)
            }
            .background(.bar)
        }
    }
}

struct GoalSection: View {
    @EnvironmentObject var model: AppModel

    /// The fields on offer, plus this session's own field if it has been retired.
    private var fields: [any DomainAdapter] {
        Domains.isRetired(model.adapter.id) ? Domains.all + [model.adapter] : Domains.all
    }

    var body: some View {
        Section("Goal") {
            Group {
                Picker("Field", selection: model.domainBinding) {
                    ForEach(fields.map(\.id), id: \.self) { fid in
                        let a = Domains.adapter(for: fid)
                        Label(Domains.isRetired(a.id) ? "\(a.name) (retired)"
                              : a.status.isReady ? a.name : "\(a.name) (unfinished)", systemImage: a.symbol).tag(a.id)
                    }
                }
                // Rebuild the menu per session: otherwise it can keep showing the previous session's field.
                .id(model.current?.id)
                if Domains.isRetired(model.adapter.id) {
                    Banner(style: .info, text: "This field is retired. This session still opens with its results; for new work, choose another field.")
                } else if let note = model.adapter.status.note {
                    Banner(style: .info, text: "Unfinished field. \(note)")
                }
                TextField("Goal", text: model.goalBinding, prompt: Text(placeholder), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(model.adapter.id == "blenderscript" ? 4...12 : 2...6)
                    .font(model.adapter.id == "blenderscript" ? .system(.caption, design: .monospaced) : .body)
                    .accessibilityLabel("Goal")
                if model.adapter.id == "blenderscript" {
                    BlenderScriptRow()
                }
                if model.adapter.id == "i2v" {
                    StartImageRow()
                }
                HStack {
                    if model.adapter.id == "i2v" {
                        Button { chooseFile(types: StartImage.extensions, keepDescription: true) } label: {
                            Label("Choose Image…", systemImage: "photo")
                        }
                    } else if model.adapter.id == "stage" {
                        Button { chooseFile(types: ["glb", "gltf", "obj", "fbx"], keepDescription: false) } label: {
                            Label("Choose Model…", systemImage: "cube")
                        }
                    } else if model.adapter.id == "model3d" {
                        Button { chooseFile(types: ModelFromImageAdapter.imageExtensions, keepDescription: false) } label: {
                            Label("Choose Image…", systemImage: "photo")
                        }
                    } else if model.adapter.id == "linelogo" {
                        Button { chooseFile(types: GreasePencilLogoAdapter.imageExtensions, keepDescription: false) } label: {
                            Label("Choose Logo…", systemImage: "scribble.variable")
                        }
                    } else if model.adapter.id == "animate" {
                        Button { chooseAnimationFile(song: true) } label: {
                            Label("Choose Song…", systemImage: "music.note")
                        }
                        Button { chooseAnimationFile(song: false) } label: {
                            Label("Choose Planet Image…", systemImage: "globe")
                        }
                    }
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
        }
    }

    private var placeholder: String {
        switch model.adapter.id {
        case "i2v": return "Choose a starting image, then say how it should move"
        case "t2v": return "Describe the shot: who or what, doing what, where"
        case "stage": return "Path to a model file (or leave empty for the sample)"
        case "model3d": return "Choose a picture to turn into a 3D model"
        case "linelogo": return "Optional: choose a logo image (empty uses the Ether Frequency emblem)"
        case "blenderscript": return "Copy a Blender script in Claude, then come back: it appears here by itself"
        case "animate": return "Optional: choose a song to pulse to and an image to wrap around the planet"
        default: return "What do you want to make?"
        }
    }

    /// Animation: puts the chosen song or planet image in the goal, replacing the previous one of that kind.
    private func chooseAnimationFile(song: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let types = song ? BlenderAnimationAdapter.audioExtensions : BlenderAnimationAdapter.imageExtensions
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let parts = BlenderAnimationAdapter.files(in: model.current?.goal ?? "")
        let keep: [String?] = [parts.words, song ? parts.texture : parts.audio, url.path]
        model.goalBinding.wrappedValue = keep.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Puts the chosen file's path in the goal. For Image to Video the words about motion are kept.
    private func chooseFile(types: [String], keepDescription: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let words = keepDescription ? StartImage.split(model.current?.goal ?? "").description : ""
        model.goalBinding.wrappedValue = words.isEmpty ? url.path : "\(url.path)\n\(words)"
    }
}

/// Blender Script: paste, the saved-script library, and opening the script in Blender.
struct BlenderScriptRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { model.pasteScript() } label: { Label("Paste Script", systemImage: "doc.on.clipboard") }
                Menu {
                    let items = BlenderScriptAdapter.library()
                    if items.isEmpty { Text("No saved scripts yet") }
                    ForEach(items.prefix(40), id: \.self) { path in
                        Button(((path as NSString).lastPathComponent as NSString).deletingPathExtension) {
                            model.openLibraryScript(path)
                        }
                    }
                    Divider()
                    Button("Show Library in Finder") {
                        try? FileManager.default.createDirectory(atPath: BlenderScriptAdapter.libraryFolder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(URL(fileURLWithPath: BlenderScriptAdapter.libraryFolder))
                    }
                } label: { Label("Library", systemImage: "books.vertical") }
                .fixedSize()
                Spacer(minLength: 0)
            }
            HStack {
                Button { model.openScriptInBlender() } label: { Label("Open in Blender", systemImage: "cube.transparent") }
                    .disabled(model.current?.goal.trimmed.isEmpty ?? true)
                Spacer(minLength: 0)
                Button { model.copyText(BlenderScriptAdapter.claudeInstructions) } label: {
                    Label("Claude Instructions", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy text for a Claude project's instructions, so its scripts suit this field")
            }
            if let note = model.scriptNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shows the starting image for Image to Video, so it is clear what the clip begins from.
struct StartImageRow: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let path = StartImage.split(model.current?.goal ?? "").path
        HStack(spacing: 10) {
            if let path, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text((path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.tertiary)
                Text(path == nil ? "No starting image yet." : "The starting image can't be opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct DialsSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Dials") {
            Group {
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
        Section {
            Group {
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
        } header: {
            Text("Fixed requirements")
        } footer: {
            Text("Things that must always hold, like accuracy, accessibility, required or forbidden content. They are never put on a slider.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
        Section("Play") {
            Group {
                if model.adapter.id == "animate" {
                    Text("Previews are 2-second, low-resolution clips; Render Full Quality makes the full-length 720p clip with your song. Set the dials first, then press Preview. Starting another preview stops the one in progress.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.adapter.id == "model3d" {
                    Text("Previews take a few seconds; Render Full Quality makes a 1080p picture and keeps the model in Documents → Ethers Prism Exports → 3D Models. Open in 3D Stage poses and lights the model.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.adapter.id == "blenderscript" {
                    Text("Preview renders one frame at half size (the Preview frame dial picks which). Render Full Quality makes the whole animation as an MP4 and keeps it in Documents → Ethers Prism Exports → Blender Scripts.")
                        .font(.caption).foregroundStyle(.secondary)
                    if case .failed(let message) = model.phase {
                        Button { model.copyText(message) } label: { Label("Copy Error", systemImage: "exclamationmark.bubble") }
                            .help("Paste this into Claude so it can fix the script")
                    }
                } else if model.adapter.id == "linelogo" {
                    Text("Previews are 2-second, low-resolution clips and take a few seconds; Render Full Quality makes the full-length 720p clip. Set the dials, then press Preview.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.adapter.capabilities.needsVideoProvider {
                    Text("Video previews take a few minutes on a Mac, so set the dials first, then press Preview. Starting another preview stops the one in progress.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("Preview automatically when a dial stops moving", isOn: $model.autoPreview)
                }
                if model.adapter.id == "model3d",
                   let text = model.current?.currentSnapshot?.output.text,
                   let glb = ModelFromImageAdapter.modelPath(in: text),
                   FileManager.default.fileExists(atPath: glb) {
                    Button { model.openInStage(glb) } label: {
                        Label("Open in 3D Stage", systemImage: "cube")
                    }
                    .buttonStyle(.borderedProminent)
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: glb)]) } label: {
                        Label("Show Model in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button { model.exploreNearby() } label: { Label("Explore Nearby", systemImage: "dice") }
                        .help("Nudge every unlocked dial a little")
                    Spacer()
                    Button { model.showSaveTemplate = true } label: {
                        Label("Save Template…", systemImage: "square.and.arrow.down.on.square")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .disabled(model.current?.dials.isEmpty ?? true)
                }
            }
        }
    }
}
