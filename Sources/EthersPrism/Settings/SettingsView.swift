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
            storageTab.tabItem { Label("Storage", systemImage: "folder") }
        }
        .frame(width: 640, height: 620)
    }

    private var agentsTab: some View {
        Form {
            Section {
                Text("One agent per job. You still choose the dials and the results; agents only do the job they're given.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(AgentRole.allCases, id: \.self) { role in
                    AgentRow(role: role, assignment: model.assignmentBinding(role))
                }
                Toggle("Checker reviews every result against the fixed requirements", isOn: $model.team.checkerEnabled)
                Toggle("Large local models (20B+) and ComfyUI take turns with memory", isOn: $model.team.memoryHandoff)
            } header: {
                HStack {
                    Text("Agents")
                    Spacer()
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
            if assignment.backend != .mock {
                let options = model.localModels[assignment.backend] ?? []
                if assignment.backend.isLocal && !options.isEmpty {
                    Picker("Model", selection: $assignment.model) {
                        if !options.contains(assignment.model) { Text(assignment.model).tag(assignment.model) }
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                } else {
                    TextField(assignment.backend == .anthropic ? "Model (for example claude-sonnet-5-5)" : "Model id",
                              text: $assignment.model)
                }
                if assignment.backend.isLocal && LocalMemory.isLarge(assignment.model) {
                    Text("Large model: needs about 19 GB of memory. It takes turns with ComfyUI.")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
