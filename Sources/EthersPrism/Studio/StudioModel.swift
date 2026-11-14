import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import EthersPrismCore

/// The sections of the PRISM sidebar.
enum AppSection: String, CaseIterable, Identifiable {
    case create, importPaste, autoImport, library, edit, realism, upscale, presets, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: return "Create"
        case .importPaste: return "Import / Paste"
        case .autoImport: return "Auto-Import"
        case .library: return "Library"
        case .edit: return "Edit Studio"
        case .realism: return "Realism Studio"
        case .upscale: return "Upscale Studio"
        case .presets: return "Presets"
        case .export: return "Export"
        }
    }

    var symbol: String {
        switch self {
        case .create: return "sparkles"
        case .importPaste: return "doc.on.clipboard"
        case .autoImport: return "arrow.down.circle"
        case .library: return "photo.on.rectangle.angled"
        case .edit: return "slider.horizontal.3"
        case .realism: return "camera.aperture"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        case .presets: return "square.stack.3d.up"
        case .export: return "square.and.arrow.up"
        }
    }

    /// The inspector tab a studio section opens on.
    var studioTab: StudioTab? {
        switch self {
        case .edit: return .adjust
        case .realism: return .realism
        case .upscale: return .enhance
        default: return nil
        }
    }
}

enum StudioTool: String { case none, pan, crop }

enum ExportSizeChoice: String, CaseIterable, Identifiable {
    case original, x2, x4, uhd, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .original: return "Original"
        case .x2: return "2×"
        case .x4: return "4×"
        case .uhd: return "3840×2160"
        case .custom: return "Custom"
        }
    }
}

/// The Studio: one library picture open for editing, its autosaved project, undo, preview and processing.
@MainActor
final class StudioModel: ObservableObject {
    @Published var section: AppSection {
        didSet {
            UserDefaults.standard.set(section.rawValue, forKey: "prismSection")
            if let t = section.studioTab, t != tab { withAnimation(PrismTheme.spring) { tab = t } }
        }
    }
    @Published var tab: StudioTab = .adjust

    // The open picture
    @Published private(set) var item: ImportedImage?
    @Published private(set) var project: StudioProject?
    @Published private(set) var before: NSImage?
    @Published private(set) var after: NSImage?
    /// The uncropped (rotated) picture, while cropping.
    @Published private(set) var uncropped: NSImage?
    /// Full-resolution size after rotation and crop.
    @Published private(set) var imageSize: CGSize = .zero
    @Published private(set) var sourceSize: CGSize = .zero
    @Published private(set) var rendering = false

    /// The edit being shown. Slider drags change it live; `commit` makes an undo step and saves.
    @Published var edit = StudioEdit() {
        didSet { if edit != oldValue { scheduleRender(geometryChanged: edit.quarterTurns != oldValue.quarterTurns || edit.crop != oldValue.crop) } }
    }

    // View state
    @Published var showBefore = true
    @Published var divider: CGFloat = 0.5
    /// nil = fit to the window.
    @Published var zoom: CGFloat?
    @Published var pan: CGSize = .zero
    @Published var tool: StudioTool = .none { didSet { if tool == .crop { renderUncropped() } } }
    @Published var pendingCrop: UnitRect = .full
    @Published var focusMode = false
    @Published var aiEngine = false

    // Processing
    @Published private(set) var job: String?
    @Published private(set) var progress: Double = 0
    @Published var message: String?

    // Presets
    @Published private(set) var presets: [StudioPreset] = []

    // Export
    @Published var exportFormat: StudioFormat = .png
    @Published var exportSize: ExportSizeChoice = .original
    @Published var customWidth = 2048
    @Published var quality = 0.92
    @Published var keepTransparency = true

    let autoImport: AutoImportController
    let store: StudioStore
    private var source: CIImage?
    private var previewSource: CIImage?
    private var previewScale: Double = 1
    private var committed = StudioEdit()
    private var undoStack: [StudioEdit] = []
    private var redoStack: [StudioEdit] = []
    private var renderTask: Task<Void, Never>?
    private var jobTask: Task<Void, Never>?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasImage: Bool { source != nil }

    init(autoImport: AutoImportController, root: URL) {
        self.autoImport = autoImport
        store = StudioStore(root: root)
        section = AppSection(rawValue: UserDefaults.standard.string(forKey: "prismSection") ?? "") ?? .create
        presets = StudioPreset.builtIns + store.loadPresets()
        if let t = section.studioTab { tab = t }
        if let id = UserDefaults.standard.string(forKey: "studioLastImage"), let it = autoImport.items.first(where: { $0.id == id }) {
            open(it)
        }
    }

    // MARK: - Opening

    func open(_ item: ImportedImage) {
        guard let url = autoImport.fileURL(for: item) else { return }
        do {
            let img = try StudioRenderer.load(url)
            source = img
            sourceSize = img.extent.size
            let p = StudioRenderer.preview(of: img, maxPixels: 2400)
            previewSource = p.image
            previewScale = p.scale
            self.item = item
            var proj = store.load(item.id) ?? StudioProject(id: item.id, imagePath: url.path)
            proj.imagePath = url.path
            if proj.history.isEmpty { proj.history.append(StudioVersion(label: "Original", edit: StudioEdit())) }
            project = proj
            undoStack = []; redoStack = []
            committed = proj.edit
            tool = .none
            zoom = nil; pan = .zero
            edit = proj.edit
            scheduleRender(geometryChanged: true)
            UserDefaults.standard.set(item.id, forKey: "studioLastImage")
        } catch {
            message = error.localizedDescription
        }
    }

    /// Opens a library file by path (from Auto-Import or the library).
    func open(url: URL) {
        let hash = try? ImageImportLibrary.sha256(of: url)
        if let it = autoImport.items.first(where: { $0.id == hash }) {
            open(it)
        } else if let it = autoImport.importFiles([url]).first {
            open(it)
        }
    }

    /// Pictures dropped, picked or pasted: imported into the library, the first one opened.
    func importAndOpen(_ urls: [URL]) {
        let items = autoImport.importFiles(urls)
        if let first = items.first {
            open(first)
            if section.studioTab == nil { section = .edit }
        } else if !urls.isEmpty {
            message = "Those files aren't pictures PRISM can import (PNG, JPEG, HEIC, TIFF, WebP)."
        }
    }

    /// ⌘V: an image or image files on the clipboard (for example after Copy Image in the ChatGPT app).
    func paste() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            importAndOpen(urls)
            return
        }
        guard let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else {
            message = "There's no image on the clipboard. In the ChatGPT app, right-click an image and choose Copy Image."
            return
        }
        let stamp = Date().formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().second())
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if let it = autoImport.importData(png, name: "Pasted image \(stamp).png") {
            open(it)
            if section.studioTab == nil { section = .edit }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.message = "Choose images to add to the PRISM library."
        guard panel.runModal() == .OK else { return }
        importAndOpen(panel.urls)
    }

    // MARK: - Editing and undo

    func binding(_ id: String) -> Binding<Double> {
        Binding(get: { self.edit[id] }, set: { self.edit[id] = $0 })
    }

    /// Makes an undo step and autosaves.
    func commit(_ label: String) {
        guard edit != committed else { return }
        undoStack.append(committed)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack = []
        committed = edit
        save(label)
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(edit)
        committed = prev
        edit = prev
        save("Undo")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(edit)
        committed = next
        edit = next
        save("Redo")
    }

    func reset(_ tab: StudioTab) {
        for c in StudioControls.controls(for: tab) { edit[c.id] = c.neutral }
        commit("Reset \(tab.title)")
    }

    func resetAll() {
        edit = StudioEdit(upscale: edit.upscale)
        commit("Reset All")
    }

    func rotate(_ quarter: Int) {
        edit.quarterTurns = ((edit.quarterTurns + quarter) % 4 + 4) % 4
        edit.crop = nil
        commit(quarter > 0 ? "Rotate Right" : "Rotate Left")
    }

    func applyCrop() {
        let c = pendingCrop.clamped
        edit.crop = c == .full ? nil : c
        tool = .none
        commit("Crop")
    }

    func clearCrop() {
        edit.crop = nil
        pendingCrop = .full
        tool = .none
        commit("Clear Crop")
    }

    func restore(_ version: StudioVersion) {
        edit = version.edit
        commit("Restore \(version.label)")
    }

    private func save(_ label: String) {
        guard var p = project else { return }
        p.edit = edit
        p.record(label)
        project = p
        do { try store.save(p) } catch { message = "Couldn't autosave: \(error.localizedDescription)" }
    }

    // MARK: - Presets

    func apply(_ preset: StudioPreset) {
        var e = edit
        e.values = preset.values
        edit = e
        commit("Preset \(preset.name)")
    }

    func saveAsPreset(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        presets.append(StudioPreset(name: n, values: edit.values))
        persistPresets()
        message = "Saved preset “\(n)”."
    }

    func delete(_ preset: StudioPreset) {
        guard !preset.builtIn else { return }
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func persistPresets() {
        do { try store.savePresets(presets) } catch { message = error.localizedDescription }
    }

    // MARK: - Live preview (in the background)

    private func scheduleRender(geometryChanged: Bool) {
        guard let src = previewSource else { before = nil; after = nil; return }
        renderTask?.cancel()
        let e = edit, scale = previewScale, full = sourceSize
        rendering = true
        renderTask = Task { [weak self] in
            // A short pause groups quick slider moves into one render.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage?, NSImage?, CGSize) in
                let base = StudioRenderer.geometry(src, e)
                let out = StudioRenderer.apply(base, e, scale: scale)
                let size = StudioRenderer.pixelSize(source: full, edit: e, size: .original)
                let a = (try? StudioRenderer.cgImage(out)).map { NSImage(cgImage: $0, size: size) }
                let b = geometryChanged ? (try? StudioRenderer.cgImage(base)).map { NSImage(cgImage: $0, size: size) } : nil
                return (a, b, size)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.after = result.0
            if let b = result.1 { self.before = b }
            self.imageSize = result.2
            self.rendering = false
        }
    }

    private func renderUncropped() {
        guard let src = previewSource else { return }
        var e = edit
        pendingCrop = e.crop ?? .full
        e.crop = nil
        let scale = previewScale, full = sourceSize
        Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                let out = StudioRenderer.apply(StudioRenderer.geometry(src, e), e, scale: scale)
                let size = StudioRenderer.pixelSize(source: full, edit: e, size: .original)
                return (try? StudioRenderer.cgImage(out)).map { NSImage(cgImage: $0, size: size) }
            }.value
            self?.uncropped = img
        }
    }

    // MARK: - Processing jobs (enhance, upscale, export)

    var isBusy: Bool { job != nil }

    func cancelJob() {
        jobTask?.cancel()
        jobTask = nil
        job = nil
        progress = 0
        message = "Cancelled."
    }

    /// Enhance to 4K, Upscale 2×/4×: renders at full resolution and adds the result to the library as an edited version.
    func enhance(_ size: StudioSize, tag: String) {
        guard let src = source, let item, !isBusy else { return }
        if aiEngine {
            message = "AI processing isn't set up. PRISM enhanced on this Mac instead."
            aiEngine = false
        }
        commit("Before \(tag)")
        let e = edit
        let stem = (item.fileName as NSString).deletingPathExtension
        let target = StudioRenderer.pixelSize(source: sourceSize, edit: e, size: size)
        job = "\(tag): \(Int(target.width))×\(Int(target.height))"
        progress = 0.15
        jobTask = Task { [weak self] in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(stem) – PRISM \(tag).png")
            self?.progress = 0.35
            let ok: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try StudioRenderer.write(StudioRenderer.render(src, e, size: size), to: tmp, format: .png) }
            }.value
            guard let self, !Task.isCancelled else { try? FileManager.default.removeItem(at: tmp); return }
            self.progress = 0.85
            switch ok {
            case .success:
                if let new = self.autoImport.importFiles([tmp]).first {
                    self.message = "Saved \(new.fileName) to the library (\(Int(target.width))×\(Int(target.height)))."
                }
            case .failure(let error):
                self.message = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: tmp)
            self.progress = 1
            self.job = nil
        }
    }

    var exportStudioSize: StudioSize {
        switch exportSize {
        case .original: return .original
        case .x2: return .scale(2)
        case .x4: return .scale(4)
        case .uhd: return .uhd4K
        case .custom: return .width(max(16, min(customWidth, 16384)))
        }
    }

    var exportPixelSize: CGSize {
        StudioRenderer.pixelSize(source: sourceSize, edit: edit, size: exportStudioSize)
    }

    /// Export… with the native save dialog.
    func export() {
        guard let src = source, let item, !isBusy else { return }
        commit("Export")
        let panel = NSSavePanel()
        let stem = (item.fileName as NSString).deletingPathExtension
        let suffix = exportSize == .original ? "" : " \(exportSize.label)"
        panel.nameFieldStringValue = "\(stem) – PRISM\(suffix).\(exportFormat.ext)"
        panel.allowedContentTypes = [exportFormat.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let e = edit, size = exportStudioSize, format = exportFormat, q = quality, alpha = keepTransparency
        let px = exportPixelSize
        job = "Exporting \(format.label) \(Int(px.width))×\(Int(px.height))"
        progress = 0.2
        jobTask = Task { [weak self] in
            self?.progress = 0.4
            let ok: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try StudioRenderer.write(StudioRenderer.render(src, e, size: size), to: url, format: format,
                                                  quality: q, transparency: alpha) }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch ok {
            case .success:
                self.message = "Exported \(url.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                self.message = error.localizedDescription
            }
            self.progress = 1
            self.job = nil
        }
    }

    // MARK: - Library strip

    /// Library pictures, newest first; edited versions are named "… – PRISM …".
    var stripItems: [ImportedImage] { autoImport.items }

    static func isEdited(_ item: ImportedImage) -> Bool { item.fileName.contains(" – PRISM") }
}
