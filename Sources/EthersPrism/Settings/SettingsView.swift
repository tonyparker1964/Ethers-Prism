import SwiftUI
import AppKit
import EthersPrismCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyDraft = ""

    var body: some View {
        TabView {
            textTab.tabItem { Label("Text", systemImage: "text.alignleft") }
            imageTab.tabItem { Label("Images", systemImage: "photo") }
            storageTab.tabItem { Label("Storage", systemImage: "folder") }
        }
        .frame(width: 560, height: 470)
    }

    private var textTab: some View {
        Form {
            Picker("Text provider", selection: $model.textProviderKind) {
                Text("Anthropic (Claude)").tag("anthropic")
                Text("Mock (test only)").tag("mock")
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
                    Label("Key saved in your Keychain", systemImage: "checkmark.seal").foregroundStyle(.green)
                    Button("Remove Key") { model.saveAPIKey("") }
                }
            }
            Text("The key stays in your Keychain. It is never written into sessions, templates or exports.")
                .font(.caption).foregroundStyle(.secondary)
            Section("Local models") {
                Text("Ollama and LM Studio support is planned but not available yet.")
                    .font(.callout).foregroundStyle(.secondary)
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
                    Text("Comfy Desktop usually listens on port 8000; a plain ComfyUI install on 8188. Your ComfyUI instance must be running. Flux models usually work best with CFG 1.")
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
