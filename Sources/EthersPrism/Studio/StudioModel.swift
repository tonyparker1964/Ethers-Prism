import SwiftUI
import AppKit
import CoreImage
import UniformTypeIdentifiers
import EthersPrismCore

/// The sections of the PRISM sidebar.
enum AppSection: String, CaseIterable, Identifiable {
    case create, importPaste, autoImport, library, edit, color, realism, upscale, scriptLab, presets, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .create: return "Create"
        case .importPaste: return "Import / Paste"
        case .autoImport: return "Auto-Import"
        case .library: return "Library"
        case .edit: return "Edit Studio"
        case .color: return "Color Studio"
        case .realism: return "Realism Studio"
        case .upscale: return "Upscale Studio"
        case .scriptLab: return "Script Lab"
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
        case .color: return "paintpalette"
        case .realism: return "camera.aperture"
        case .upscale: return "arrow.up.left.and.arrow.down.right"
        case .scriptLab: return "chevron.left.forwardslash.chevron.right"
        case .presets: return "square.stack.3d.up"
        case .export: return "square.and.arrow.up"
        }
    }

    /// The inspector tab a studio section opens on.
    var studioTab: StudioTab? {
        switch self {
        case .edit: return .adjust
        case .color: return .color
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
            if section == .color && oldValue != .color { scheduleRender(geometryChanged: false) }
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

    // Color Studio
    enum GradingTab: String, CaseIterable, Identifiable {
        case primaries, curves, hueCurves, matchLUT
        var id: String { rawValue }
        var title: String {
            switch self {
            case .primaries: return "Primaries"
            case .curves: return "Curves"
            case .hueCurves: return "Hue Curves"
            case .matchLUT: return "Shot Match & LUT"
            }
        }
    }
    @Published var gradingTab: GradingTab = .primaries
    @Published var logWheels = false
    @Published var curveKind: CurveKind = .luma
    @Published var hueCurveKind: CurveKind = .hueHue
    @Published var scopeKind: ScopeKind = .parade { didSet { refreshScope() } }
    @Published private(set) var scopeImage: CGImage?
    @Published private(set) var histogram: [[Int]] = []
    private var scopeSample: ScopeSample?

    // Export
    @Published var exportFormat: StudioFormat = .png
    @Published var exportSize: ExportSizeChoice = .original
    @Published var customWidth = 2048
    @Published var quality = 0.92
    @Published var keepTransparency = true
    @Published var exportReframe: StudioReframe = .original { didSet { if exportReframe != .original { findFocus() } } }
    /// Where the subject is in the open picture (for Smart Reframe), unit coordinates.
    @Published private(set) var focus: UnitRect?

    /// Copy / Paste Settings.
    @Published private(set) var copiedLook: StudioEdit?

    let autoImport: AutoImportController
    let store: StudioStore
    private var source: CIImage?
    private var previewSource: CIImage?
    private var previewScale: Double = 1
    private var committed = StudioEdit()
    private var undoStack: [StudioEdit] = []
    private var redoStack: [StudioEdit] = []
    private var renderTask: Task<Void, Never>?
    /// The subject mask for the preview, kept while the crop and rotation stay the same.
    private var subjectCache: (key: String, mask: CIImage?)?
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
            divider = 0.5
            focus = nil
            subjectCache = nil
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
        if tab == .color { resetColor(); return }
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
        let needsSubject = StudioRenderer.needsSubject(e)
        let key = "\(item?.id ?? "")|\(e.quarterTurns)|\(String(describing: e.crop))"
        let haveSubject = subjectCache?.key == key
        let cachedSubject = haveSubject ? subjectCache?.mask : nil
        let wantScopes = section == .color, scopeKind = self.scopeKind
        renderTask = Task { [weak self] in
            // A short pause groups quick slider moves into one render.
            try? await Task.sleep(nanoseconds: 16_000_000)
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage?, NSImage?, CGSize, CIImage?, ScopeSample?, CGImage?) in
                let base = StudioRenderer.geometry(src, e)
                // Apple Vision finds the subject once per crop/rotation (for Background Defocus and Depth).
                let subject = needsSubject ? (haveSubject ? cachedSubject : StudioVision.subjectMask(for: base)) : nil
                let out = StudioRenderer.apply(base, e, scale: scale, subject: subject)
                let size = StudioRenderer.pixelSize(source: full, edit: e, size: .original)
                let a = (try? StudioRenderer.cgImage(out)).map { NSImage(cgImage: $0, size: size) }
                let b = geometryChanged ? (try? StudioRenderer.cgImage(base)).map { NSImage(cgImage: $0, size: size) } : nil
                // Scopes measure the graded picture (Color Studio only).
                let sample = wantScopes ? ScopeSample.make(out) : nil
                let scope = sample.flatMap { StudioScopes.render(scopeKind, $0) }
                return (a, b, size, subject, sample, scope)
            }.value
            guard let self, !Task.isCancelled else { return }
            if needsSubject && !haveSubject { self.subjectCache = (key, result.3) }
            self.after = result.0
            if let b = result.1 { self.before = b }
            self.imageSize = result.2
            if let sample = result.4 {
                self.scopeSample = sample
                self.scopeImage = result.5
                self.histogram = sample.histogram()
            }
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

    // MARK: - Color tab

    /// Match this picture's colours to a library picture.
    func matchTo(_ reference: ImportedImage) {
        guard let url = autoImport.fileURL(for: reference) else { return }
        matchTo(url: url, name: reference.fileName)
    }

    func chooseMatchFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .webP]
        panel.message = "Choose a picture whose colours this one should match."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        matchTo(url: url, name: url.lastPathComponent)
    }

    private func matchTo(url: URL, name: String) {
        guard let src = previewSource else { return }
        do {
            let ref = StudioRenderer.preview(of: try StudioRenderer.load(url), maxPixels: 512).image
            let srcStats = StudioColor.stats(of: StudioRenderer.geometry(src, edit))
            var e = edit
            StudioColor.setMatch(&e, source: srcStats, reference: StudioColor.stats(of: ref), name: name)
            edit = e
            commit("Match to \(name)")
        } catch {
            message = error.localizedDescription
        }
    }

    func clearMatch() {
        var e = edit
        StudioColor.clearMatch(&e)
        edit = e
        commit("Clear Match")
    }

    func loadLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cube") ?? .data]
        panel.message = "Choose a 3D LUT (.cube)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            _ = try StudioColor.parseCube(text, name: url.lastPathComponent)
            // Keep a copy, so the look survives if the original file moves.
            let folder = store.folder.appendingPathComponent("LUTs", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: url, to: dest) }
            var e = edit
            e.lutPath = dest.path
            edit = e
            commit("LUT \(url.deletingPathExtension().lastPathComponent)")
        } catch {
            message = error.localizedDescription
        }
    }

    func clearLUT() {
        var e = edit
        e.lutPath = nil
        e["lutStrength"] = 100
        edit = e
        commit("Clear LUT")
    }

    func resetColor() {
        var e = edit
        for k in StudioColor.allKeys { e.values[k] = nil }
        e.curves = nil
        e.lutPath = nil
        e.matchReferenceName = nil
        edit = e
        commit("Reset Color")
    }

    func setWheel(_ w: StudioColor.Wheel, x: Double, y: Double) {
        edit[w.xKey] = x
        edit[w.yKey] = y
    }

    // MARK: - Color Studio

    private func refreshScope() {
        guard let s = scopeSample else { return }
        let kind = scopeKind
        Task { [weak self] in
            let img = await Task.detached(priority: .userInitiated) { StudioScopes.render(kind, s) }.value
            self?.scopeImage = img
        }
    }

    /// Resolve's "A": balances black, white and colour cast from the picture as it comes in.
    func autoBalance() {
        guard let src = previewSource, let s = ScopeSample.make(StudioRenderer.geometry(src, edit)) else { return }
        var e = edit
        StudioColor.autoBalance(s, into: &e)
        edit = e
        commit("Auto Balance")
    }

    func wheelNumbers(_ w: StudioColor.Wheel) -> (y: Double, r: Double, g: Double, b: Double) {
        StudioColor.numbers(w, edit)
    }

    func setWheelNumbers(_ w: StudioColor.Wheel, y: Double? = nil, r: Double? = nil, g: Double? = nil, b: Double? = nil) {
        var e = edit
        let n = StudioColor.numbers(w, e)
        if let y { e[w.levelKey] = min(max(y * 100, -100), 100) }
        if r != nil || g != nil || b != nil {
            StudioColor.setNumbers(w, &e, r: r ?? n.r, g: g ?? n.g, b: b ?? n.b)
        }
        edit = e
        commit(w.label)
    }

    func resetWheel(_ w: StudioColor.Wheel) {
        edit[w.xKey] = 0; edit[w.yKey] = 0; edit[w.levelKey] = 0
        commit("Reset \(w.label)")
    }

    func setCurve(_ k: CurveKind, _ points: [CurvePoint]) {
        var e = edit
        e.setCurve(k, points)
        edit = e
    }

    func resetCurve(_ k: CurveKind) {
        setCurve(k, [])
        commit("Reset \(k.label) Curve")
    }

    // MARK: - Copy / Paste Settings

    func copySettings() {
        guard hasImage else { return }
        copiedLook = edit.lookOnly
        message = "Copied this picture's settings. Paste them in the Library or on another picture."
    }

    /// Pastes the copied look (not crop or rotation) onto library pictures. A Match to Reference is
    /// re-measured for each picture so they all land on the reference's colours.
    func pasteSettings(to items: [ImportedImage]) {
        guard let look = copiedLook else { message = "Copy settings from a picture first (⌥⌘C)."; return }
        var count = 0
        for it in items {
            guard let url = autoImport.fileURL(for: it) else { continue }
            if it.id == item?.id {
                var e = edit.withLook(of: look)
                if StudioColor.hasMatch(e), let src = previewSource { remeasure(&e, StudioRenderer.geometry(src, e)) }
                edit = e
                commit("Paste Settings")
            } else {
                var p = store.load(it.id) ?? StudioProject(id: it.id, imagePath: url.path)
                if p.history.isEmpty { p.history.append(StudioVersion(label: "Original", edit: StudioEdit())) }
                var e = p.edit.withLook(of: look)
                if StudioColor.hasMatch(e), let img = try? StudioRenderer.load(url) {
                    remeasure(&e, StudioRenderer.geometry(StudioRenderer.preview(of: img, maxPixels: 512).image, e))
                }
                p.edit = e
                p.record("Pasted Settings")
                try? store.save(p)
            }
            count += 1
        }
        message = "Pasted settings onto \(count) picture\(count == 1 ? "" : "s")."
    }

    private func remeasure(_ e: inout StudioEdit, _ image: CIImage) {
        let s = StudioColor.stats(of: image)
        for i in 0..<6 { e.values["matchSrc\(i)"] = s[i] }
    }

    // MARK: - Smart Reframe

    func findFocus() {
        guard focus == nil, let src = previewSource else { return }
        let e = edit
        Task { [weak self] in
            let f = await Task.detached(priority: .userInitiated) {
                StudioVision.focus(for: StudioRenderer.geometry(src, e))
            }.value
            self?.focus = f ?? UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
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
        StudioRenderer.pixelSize(source: sourceSize, edit: edit, size: exportStudioSize, reframe: exportReframe)
    }

    /// Export… with the native save dialog.
    func export() {
        guard let src = source, let item, !isBusy else { return }
        commit("Export")
        let panel = NSSavePanel()
        let stem = (item.fileName as NSString).deletingPathExtension
        let shape = exportReframe == .original ? "" : " \(exportReframe.label.replacingOccurrences(of: ":", with: "x"))"
        let suffix = (exportSize == .original ? "" : " \(exportSize.label)") + shape
        panel.nameFieldStringValue = "\(stem) – PRISM\(suffix).\(exportFormat.ext)"
        panel.allowedContentTypes = [exportFormat.type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let e = edit, size = exportStudioSize, format = exportFormat, q = quality, alpha = keepTransparency
        let reframe = exportReframe
        let px = exportPixelSize
        job = "Exporting \(format.label) \(Int(px.width))×\(Int(px.height))"
        progress = 0.2
        jobTask = Task { [weak self] in
            self?.progress = 0.4
            let ok: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try StudioRenderer.write(StudioRenderer.render(src, e, size: size, reframe: reframe), to: url,
                                                  format: format, quality: q, transparency: alpha) }
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
