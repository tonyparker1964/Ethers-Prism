import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EthersPrismCore

/// Settings → Auto-Import.
struct AutoImportSettingsTab: View {
    @EnvironmentObject var auto: AutoImportController
    @EnvironmentObject var studio: StudioModel

    var body: some View {
        Form {
            Section {
                Toggle("Auto-Import new images", isOn: $auto.enabled)
                Text(auto.status).font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("In the ChatGPT app, save a picture into the watched folder. PRISM notices the new file, waits until it has finished saving, and copies it into the PRISM library. PRISM only looks at the folder you choose; it doesn't read anything inside ChatGPT.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Watched folder") {
                LabeledContent("Folder") {
                    Text(auto.watchedFolder?.path ?? "None chosen")
                        .font(.caption).textSelection(.enabled).lineLimit(2)
                }
                HStack {
                    Button("Choose Folder…") { auto.chooseFolder() }
                    Button("Use Downloads") { auto.useDownloads() }
                    Button("Use a ChatGPT Folder") { auto.useDedicatedFolder() }
                        .help("Creates and watches Downloads/ChatGPT Images")
                }
                Button("Import Existing Images Now") { auto.importExisting() }
                    .disabled(auto.watchedFolder == nil)
                Text("Only pictures saved after you choose a folder come in automatically. Import Existing Images brings in the ones already there; pictures already in the library are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When a picture comes in") {
                Toggle("Show a notification", isOn: $auto.notify)
                Toggle("Open it in the editor", isOn: $auto.openAutomatically)
                Picker("Open in", selection: $auto.openTarget) {
                    ForEach(AutoImportController.OpenTarget.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!auto.openAutomatically)
            }

            Section("PRISM library") {
                LabeledContent("Library folder") {
                    Text(auto.libraryFolder.path).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button("Show Library") { studio.section = .library }
                    Button("Show in Finder") { auto.showInFinder() }
                }
                Text("PNG, JPEG, HEIC, TIFF and WebP. Each picture is copied byte-for-byte; the original stays where you saved it. The same picture saved twice is imported once.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The PRISM library: imported pictures as thumbnails. Double-click to open in the editor.
struct ImportLibrarySheet: View {
    @EnvironmentObject var auto: AutoImportController
    /// Shown as the Library page rather than a sheet.
    var embedded = false
    @EnvironmentObject var studio: StudioModel
    @State private var dropping = false
    @State private var selecting = false
    @State private var selected: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatGPT Imports").font(.title3.bold())
                    Text(auto.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if selecting {
                    Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                    Button("Select All") { selected = Set(auto.items.map(\.id)) }
                    Button("Paste Settings to \(selected.count)") {
                        studio.pasteSettings(to: auto.items.filter { selected.contains($0.id) })
                        selecting = false; selected = []
                    }
                    .disabled(selected.isEmpty || studio.copiedLook == nil)
                    .help(studio.copiedLook == nil ? "Copy settings from a picture in Edit Studio first (⌥⌘C)." : "Paste the copied look onto the selected pictures.")
                    Button("Done") { selecting = false; selected = [] }
                } else {
                    Button("Select…") { selecting = true }
                        .help("Select pictures to paste settings onto")
                    Button("Add Images…") { addImages() }
                    Button("Show in Finder") { auto.showInFinder() }
                }
                if !embedded {
                    Button("Done") { auto.showLibrary = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            Divider()
            if auto.items.isEmpty {
                ContentUnavailableView {
                    Label("No images yet", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(auto.enabled
                         ? "Save a picture from the ChatGPT app into \(auto.watchedFolder?.lastPathComponent ?? "the watched folder") and it appears here."
                         : "Turn on Auto-Import in Settings, or drop pictures here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(auto.items) { item in
                            ImportTile(item: item)
                                .overlay(alignment: .topTrailing) {
                                    if selecting {
                                        Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title2).foregroundStyle(selected.contains(item.id) ? PrismTheme.teal : .white)
                                            .shadow(radius: 3).padding(6)
                                    }
                                }
                                .overlay {
                                    if selecting {
                                        Color.clear.contentShape(Rectangle()).onTapGesture {
                                            if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                                        }
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
            Divider()
            Text("Double-click a picture to open it in \(auto.openTarget.label). Right-click for more.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(minWidth: embedded ? nil : 720, minHeight: embedded ? nil : 520)
        .overlay {
            if dropping { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 3).padding(4) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in auto.importFiles([url]) } }
                }
            }
            return true
        }
    }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        guard panel.runModal() == .OK else { return }
        auto.importFiles(panel.urls)
    }
}

struct ImportTile: View {
    @EnvironmentObject var auto: AutoImportController
    @EnvironmentObject var studio: StudioModel
    let item: ImportedImage

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let img = auto.thumbnail(for: item) {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            Text(item.fileName).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.importedAt.formatted(.relative(presentation: .named)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { auto.open(item, in: auto.openTarget) }
        .contextMenu {
            ForEach(AutoImportController.OpenTarget.allCases) { t in
                Button("Open in \(t.label)") { auto.open(item, in: t) }
            }
            Divider()
            Button("Paste Settings") { studio.pasteSettings(to: [item]) }.disabled(studio.copiedLook == nil)
            Divider()
            Button("Show in Finder") { auto.showInFinder(item) }
            Button("Remove from Library", role: .destructive) { auto.remove(item) }
        }
        .help("\(item.originalName)\(item.pixelWidth.map { " · \($0)×\(item.pixelHeight ?? 0)" } ?? "")")
    }
}
