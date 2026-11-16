import SwiftUI
import AppKit
import EthersPrismCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""

    var body: some View {
        TabView {
            agentsTab.tabItem { Label("Agents", systemImage: "person.3") }
            imageTab.tabItem { Label("Images", systemImage: "photo") }
            mixarTab.tabItem { Label("Mixar", systemImage: "cube") }
            soundsTab.tabItem { Label("Sounds", systemImage: "waveform") }
            storageTab.tabItem { Label("Storage", systemImage: "folder") }
        }
        .frame(width: 640, height: 620)
    }

    private var agentsTab: some View {
        Form {
            Section {
                AccountRow(cli: .claude)
                AccountRow(cli: .codex)
                Text("No API keys: Claude runs through Claude Code and ChatGPT through OpenAI's Codex, both signed in with your own accounts on this Mac, and they use your plans' usage. ChatGPT needs a paid ChatGPT plan (Plus or higher). Choose them per agent below, or press Use for All.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Claude and ChatGPT")
            }
            .task { await model.checkAccounts() }
            // Coming back from the Terminal sign-in updates the status by itself.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.checkAccounts() }
            }
            Section {
                Text("One agent per job. You still choose the dials and the results; agents only do the job they're given.")
                    .font(.caption).foregroundStyle(.secondary)
                // The Coder only served the retired Code field.
                ForEach(AgentRole.allCases.filter { $0 != .coder }, id: \.self) { role in
                    AgentRow(role: role, assignment: model.assignmentBinding(role))
                }
                Toggle("Checker reviews every result against the fixed requirements", isOn: $model.team.checkerEnabled)
                Toggle("Large local models (20B+) and ComfyUI take turns with memory", isOn: $model.team.memoryHandoff)
                Toggle("Teach agents with my starred results and hand edits", isOn: $model.team.teachByExample)
                Text("Before each job, the Writer, Coder, Art Director and Dial Designer see up to 3 of your recent starred results or hand edits, so they learn your taste. Nothing is trained and nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
                    Button("All Claude") { model.useAccountForAllAgents(.claude) }
                    Button("All ChatGPT") { model.useAccountForAllAgents(.codex) }
                    Button("All Local") { model.team.assignments = AgentTeam.local.assignments }
                    Button("All Mock") { model.team.assignments = AgentTeam.mock.assignments }
                }
            }
            Section("LM Studio") {
                TextField("Address", text: $model.team.lmStudioURL)
                HStack {
                    Button("Check Connection") { Task { await model.checkLocal(.lmStudio) } }
                    if let s = model.localStatus[.lmStudio] { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                Text("In LM Studio: Developer → Status: Running. Models load when an agent first needs them and unload after an hour idle.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ollama") {
                TextField("Address", text: $model.team.ollamaURL)
                HStack {
                    Button("Check Connection") { Task { await model.checkLocal(.ollama) } }
                    if let s = model.localStatus[.ollama] { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Claude (Anthropic)") {
                SecureField("Anthropic API key", text: $keyDraft)
                HStack {
                    Button("Save Key") {
                        model.saveAPIKey(keyDraft)
                        keyDraft = ""
                    }
                    .disabled(keyDraft.trimmed.isEmpty)
                    if model.hasAPIKey {
                        Label("Key saved in your Keychain", systemImage: "checkmark.seal").foregroundStyle(.green)
                        Button("Remove Key") { model.saveAPIKey("") }
                    }
                }
                Text("The key stays in your Keychain. It is never written into sessions, templates or exports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var mixarTab: some View {
        Form {
            Section("Mixar (3D)") {
                Text("Mixar is an AI 3D editor built on Blender. Through Connect MCP, Ethers Prism can use its scene, camera, lighting and render tools. Inspecting and rendering are free; AI generation in Mixar costs Mixar credits.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect and List Tools") { Task { await model.connectMixar() } }
                    if let s = model.mixarStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
                }
                Text("If it says Connect MCP is off: open Mixar, sign in, then profile menu (top right) → Connect MCP → Turn on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.mixarTools.isEmpty {
                Section("Tools Mixar offers (\(model.mixarTools.count))") {
                    ForEach(model.mixarTools) { tool in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.name).font(.callout.monospaced())
                            if !tool.description.isEmpty {
                                Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var imageTab: some View {
        Form {
            Picker("Image provider", selection: $model.imageProviderKind) {
                Text("ComfyUI on this Mac").tag("comfyui")
                Text("Claude SVG drawing").tag("svg")
                Text("Mock (test only)").tag("mock")
            }
            if let p = model.imageProvider {
                Text(p.previewCostNote).font(.caption).foregroundStyle(.secondary)
            }
            if model.imageProviderKind == "comfyui" {
                Section("ComfyUI") {
                    TextField("Address", text: $model.comfy.baseURL)
                    HStack {
                        Button("Check Connection") { Task { await model.checkComfy() } }
                        if let status = model.comfyStatus {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if model.comfyModels.isEmpty {
                        TextField("Model file (checkpoint)", text: $model.comfy.checkpoint)
                    } else {
                        Picker("Model", selection: $model.comfy.checkpoint) {
                            ForEach(model.comfyModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Stepper("Preview: \(model.comfy.previewSize) px", value: $model.comfy.previewSize, in: 256...1024, step: 128)
                    Stepper("Preview steps: \(model.comfy.previewSteps)", value: $model.comfy.previewSteps, in: 1...40)
                    Stepper("Render: \(model.comfy.renderSize) px", value: $model.comfy.renderSize, in: 512...2048, step: 128)
                    Stepper("Render steps: \(model.comfy.renderSteps)", value: $model.comfy.renderSteps, in: 4...80)
                    HStack {
                        Text("CFG")
                        Slider(value: $model.comfy.cfg, in: 1...12, step: 0.5)
                        Text(String(format: "%.1f", model.comfy.cfg)).monospacedDigit()
                    }
                    TextField("Sampler", text: $model.comfy.sampler)
                    TextField("Scheduler", text: $model.comfy.scheduler)
                    Text("ComfyUI usually listens on port 8188 (some Comfy Desktop setups use 8000). Your ComfyUI instance must be running. Flux models usually work best with CFG 1.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var videoTab: some View {
        Form {
            Section("LTX Video through ComfyUI") {
                Text("Text to Video and Image to Video run on this Mac through ComfyUI at \(model.comfy.baseURL) (the address on the Images tab). They need two files in ComfyUI: the LTX Video model in models/checkpoints and the T5 text encoder in models/text_encoders.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check ComfyUI") { Task { await model.checkVideo() } }
                    if let status = model.videoStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.videoModelChoices.isEmpty {
                    TextField("Video model (checkpoint)", text: $model.comfyVideo.checkpoint)
                } else {
                    Picker("Video model", selection: $model.comfyVideo.checkpoint) {
                        ForEach(model.videoModelChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
                if model.videoEncoderChoices.isEmpty {
                    TextField("Text encoder", text: $model.comfyVideo.textEncoder)
                } else {
                    Picker("Text encoder", selection: $model.comfyVideo.textEncoder) {
                        ForEach(model.videoEncoderChoices, id: \.self) { Text($0).tag($0) }
                    }
                }
                Stepper("Preview steps: \(model.comfyVideo.previewSteps)", value: $model.comfyVideo.previewSteps, in: 4...40)
                Stepper("Render steps: \(model.comfyVideo.renderSteps)", value: $model.comfyVideo.renderSteps, in: 8...80)
                HStack {
                    Text("CFG")
                    Slider(value: $model.comfyVideo.cfg, in: 1...8, step: 0.5)
                    Text(String(format: "%.1f", model.comfyVideo.cfg)).monospacedDigit()
                }
                Text("Previews are 1 second at 512 px; full renders use the Length dial (1–8 seconds) at 768 px. On a Mac, a full render can take a long time, so try ideas with previews first. While a clip renders, LM Studio's models are unloaded to make room.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var soundsTab: some View {
        Form {
            Section {
                Text("The Beats field plays your own samples: Maschine expansions, Battery kits and any folders of WAV or AIFF one-shots. Kontakt instruments keep their samples in Native Instruments' locked formats, so those are skipped here.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.soundFolders.isEmpty {
                    Text("No folders yet.").foregroundStyle(.secondary)
                }
                ForEach(model.soundFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path) ? "folder" : "exclamationmark.triangle")
                            .foregroundStyle(FileManager.default.fileExists(atPath: path) ? Color.secondary : Color.orange)
                        Text(path).font(.callout).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(role: .destructive) { model.removeSoundFolder(path) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(path)")
                    }
                }
                HStack {
                    Button("Add Folders…") { model.addSoundFolders() }
                    Button("Scan Again") { model.scanSounds() }
                        .disabled(model.soundFolders.isEmpty || model.scanning)
                    if model.scanning { ProgressView().controlSize(.small) }
                }
                if let s = model.scanStatus { Text(s).font(.caption).foregroundStyle(.secondary) }
            } header: {
                Text("Sample folders")
            }
            if !model.sampleIndex.isEmpty {
                Section("What was found") {
                    ForEach(SampleRole.allCases, id: \.self) { role in
                        LabeledContent(role.label) { Text("\(model.sampleIndex.count(role))").monospacedDigit() }
                    }
                    LabeledContent("Kits") { Text("\(model.sampleIndex.groups.count)").monospacedDigit() }
                    let taste = BeatsLibrary.shared.taste
                    LabeledContent("Taste learned from your ratings") {
                        Text(taste.isEmpty ? "none yet" : "\(taste.likedKits.count) liked kits, \(taste.dislikedKits.count) turned down")
                    }
                    .id(model.tasteVersion)
                    if !taste.isEmpty {
                        Button("Forget My Ratings") { model.forgetTaste() }
                    }
                    Text("The Kit dial steps through kits that have a kick and a snare or clap. Put a kit's name in your goal, or in a Must include requirement, to use only kits with that name. A Must avoid requirement leaves out any sample whose name or folder contains those words.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        Form {
            LabeledContent("Sessions, media and templates") {
                Text(model.store.root.path).font(.caption).textSelection(.enabled)
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.store.root]) }
            Text("Sessions are versioned JSON files saved atomically. Images live in the Assets folder and are referenced by relative paths, so a session folder can be moved.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

/// One agent: which backend and model does this job.
struct AgentRow: View {
    @EnvironmentObject var model: AppModel
    let role: AgentRole
    @Binding var assignment: AgentAssignment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(role.title).font(.headline)
                Spacer()
                Picker("", selection: $assignment.backend) {
                    ForEach(AgentBackend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Text(role.job).font(.caption).foregroundStyle(.secondary)
            if let cli = assignment.backend.account, let st = model.accountStatus[cli], !st.ready {
                Text(st.installed ? "\(cli.toolName) isn't signed in yet. Press Sign In above." : "\(cli.toolName) isn't on this Mac yet. Press Set Up above.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if assignment.backend != .mock {
                let options = model.localModels[assignment.backend] ?? []
                if assignment.backend.isLocal && !options.isEmpty {
                    Picker("Model", selection: $assignment.model) {
                        if !options.contains(assignment.model) { Text(assignment.model).tag(assignment.model) }
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField(placeholder, text: $assignment.model)
                }
                if assignment.backend.isLocal && LocalMemory.isLarge(assignment.model) {
                    Text("Large model: needs about 19 GB of memory. It takes turns with ComfyUI.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var placeholder: String {
        switch assignment.backend {
        case .claudeAccount: return "Model (empty = your default; or sonnet, opus, haiku)"
        case .chatGPT: return "Model (empty = your ChatGPT default)"
        case .anthropic: return "Model (for example claude-sonnet-5-5)"
        default: return "Model id"
        }
    }
}

/// Claude or ChatGPT: installed? signed in? with buttons to set up, sign in and check.
struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let cli: AccountCLI

    var body: some View {
        let st = model.accountStatus[cli]
        let checking = model.accountChecking.contains(cli)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: st?.ready == true ? "checkmark.circle.fill" : (st == nil || checking ? "circle.dotted" : "exclamationmark.circle"))
                .foregroundStyle(st?.ready == true ? Color.green : (st == nil || checking ? Color.secondary : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(st, checking)).font(.headline)
                Text(detail(st)).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            Button("Check") { Task { await model.checkAccount(cli) } }
                .disabled(checking)
            if let st, !st.ready {
                Button(st.installed ? "Sign In" : "Set Up") { model.connectAccount(cli) }
                    .buttonStyle(.borderedProminent)
            } else if st?.ready == true {
                Button("Use for All") { model.useAccountForAllAgents(cli) }
            }
        }
        .padding(.vertical, 2)
    }

    private func title(_ st: AccountStatus?, _ checking: Bool) -> String {
        if checking || st == nil { return "\(cli.serviceName): checking…" }
        guard let st else { return cli.serviceName }
        if st.ready { return "\(cli.serviceName) is connected" }
        return st.installed ? "\(cli.serviceName): sign in to \(cli.toolName)" : "\(cli.serviceName): \(cli.toolName) isn't on this Mac yet"
    }

    private func detail(_ st: AccountStatus?) -> String {
        guard let st else { return "Through \(cli.toolName), signed in with your \(cli.serviceName) account." }
        if !st.installed {
            return "Set Up installs \(cli.toolName) and signs in, in Terminal. Then press Check."
        }
        if !st.ready { return "Sign In opens Terminal and your browser. Then come back and press Check." }
        return [st.detail, st.version].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
