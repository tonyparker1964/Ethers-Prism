import SwiftUI
import AppKit
import EthersPrismCore

/// Script Lab: write Python that makes brushes, colours and strokes; run it in Blender; see the result.
@MainActor
final class ScriptLabModel: ObservableObject {
    @Published var code: String { didSet { if code != oldValue { dirty = true; scheduleAutosave() } } }
    @Published var name: String
    @Published private(set) var fileURL: URL?
    @Published private(set) var dirty = false
    @Published private(set) var scripts: [URL] = []

    /// The picture passed to the script as IMAGE (a Library item).
    @Published var picture: ImportedImage?

    @Published private(set) var running: String?
    @Published private(set) var still: URL?
    @Published private(set) var movie: URL?
    @Published private(set) var console: [ConsoleLine] = []
    @Published private(set) var errorLine: Int?
    @Published var jumpTo: Int?
    @Published var showReference = false

    struct ConsoleLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    let folder: URL
    let rendersFolder: URL
    let autoImport: AutoImportController
    private var task: Task<Void, Never>?
    private var autosave: Task<Void, Never>?

    init(root: URL, autoImport: AutoImportController) {
        folder = root.appendingPathComponent("Script Lab", isDirectory: true)
        rendersFolder = folder.appendingPathComponent("Renders", isDirectory: true)
        self.autoImport = autoImport
        let draft = folder.appendingPathComponent(".draft.py")
        if let saved = try? String(contentsOf: draft, encoding: .utf8), !saved.isEmpty {
            code = saved
            name = UserDefaults.standard.string(forKey: "scriptLabName") ?? "Untitled"
        } else {
            code = ScriptLab.templates.first?.code ?? "canvas()\n"
            name = ScriptLab.templates.first?.name ?? "Untitled"
        }
        if let path = UserDefaults.standard.string(forKey: "scriptLabFile") { fileURL = URL(fileURLWithPath: path) }
        if let id = UserDefaults.standard.string(forKey: "scriptLabPicture") { picture = autoImport.items.first { $0.id == id } }
        refresh()
    }

    func refresh() { scripts = ScriptLab.scripts(in: folder) }

    private func scheduleAutosave() {
        autosave?.cancel()
        let text = code, url = folder.appendingPathComponent(".draft.py"), dir = folder
        autosave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(self?.name, forKey: "scriptLabName")
        }
    }

    // MARK: - Files

    func newScript() {
        load(code: "# New script\ncanvas(1920, 1080, background=\"#f3ede1\", seconds=4)\n\nb = brush(\"My brush\", kind=\"ink\", color=\"#1b2a4a\", size=10)\nline(b, (300, 540), (1620, 540))\n\ndraw_on()\n",
             name: "Untitled", url: nil)
    }

    func open(template: (name: String, code: String)) { load(code: template.code, name: template.name, url: nil) }

    func open(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        load(code: text, name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    private func load(code: String, name: String, url: URL?) {
        self.code = code
        self.name = name
        fileURL = url
        dirty = false
        errorLine = nil
        UserDefaults.standard.set(url?.path, forKey: "scriptLabFile")
        UserDefaults.standard.set(name, forKey: "scriptLabName")
    }

    func save() {
        do {
            if let old = fileURL, old.deletingPathExtension().lastPathComponent != name {
                try? FileManager.default.removeItem(at: old)       // renamed
            }
            let url = try ScriptLab.save(code, name: name, in: folder)
            fileURL = url
            dirty = false
            UserDefaults.standard.set(url.path, forKey: "scriptLabFile")
            refresh()
            log("Saved \(url.lastPathComponent).")
        } catch {
            log("Couldn't save: \(error.localizedDescription)", error: true)
        }
    }

    func delete(_ url: URL) {
        NSWorkspace.shared.recycle([url]) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        if url == fileURL { fileURL = nil }
    }

    // MARK: - Running

    var isRunning: Bool { running != nil }

    func run(video: Bool) {
        guard !isRunning else { return }
        let code = self.code, title = name.isEmpty ? "Script" : name
        let pic = picture.flatMap { autoImport.fileURL(for: $0)?.path }
        errorLine = nil
        console = []
        running = video ? "Rendering video in Blender…" : "Running in Blender…"
        log(video ? "▶︎ Render video" : "▶︎ Run (finished frame, half size)")
        let keep = rendersFolder
        task = Task { [weak self] in
            do {
                let out = try await ScriptLab.run(code: code, picture: pic, video: video, keepIn: keep, title: title)
                guard let self else { return }
                if let m = out.movie { self.movie = m; self.still = nil } else { self.still = out.still; self.movie = nil }
                for l in out.log.components(separatedBy: .newlines) where !l.isEmpty {
                    self.log(l.replacingOccurrences(of: "PRISM: ", with: "").replacingOccurrences(of: "PRISM-NOTE: ", with: "Note: "))
                }
                self.log("Done.")
            } catch is CancellationError {
                self?.log("Stopped.")
            } catch let e as ScriptLab.ScriptError {
                self?.errorLine = e.line
                self?.jumpTo = e.line
                self?.log(e.message, error: true)
                if let line = e.line { self?.log("The error is on line \(line), highlighted in red.", error: true) }
            } catch {
                self?.log(error.localizedDescription, error: true)
            }
            self?.running = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = nil
    }

    private func log(_ text: String, error: Bool = false) {
        console.append(ConsoleLine(text: text, isError: error))
        if console.count > 300 { console.removeFirst(console.count - 300) }
    }

    // MARK: - Results

    func addResultToLibrary() {
        guard let still else { return }
        if let item = autoImport.importFiles([still]).first { log("Added \(item.fileName) to the Library.") }
    }

    func showResult() {
        if let url = movie ?? still { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func choosePicture(_ item: ImportedImage?) {
        picture = item
        UserDefaults.standard.set(item?.id, forKey: "scriptLabPicture")
    }

    /// Copies the script with the library's reference, ready to paste into Claude.
    func copyForClaude() {
        let text = """
        Please improve this PRISM Script Lab script. Keep using the prism_gp functions below and reply with the whole script.

        \(ScriptLab.apiReference)

        ```python
        \(code)
        ```
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log("Copied the script and the brush library reference for Claude.")
    }

    /// Takes a script copied from Claude (Edit ▸ Paste works too).
    func pasteFromClaude() {
        guard let raw = NSPasteboard.general.string(forType: .string) else { return }
        let script = BlenderScriptAdapter.extractScript(raw)
        code = script.isEmpty ? raw : script
        log("Pasted a script from the clipboard.")
    }

    func openInBlender() {
        // Opens the scene this script builds in Blender's window, to keep drawing by hand.
        let pic = picture.flatMap { autoImport.fileURL(for: $0)?.path }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrismScriptLab-open-\(UUID().uuidString.prefix(6))")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try ScriptLab.library.write(to: dir.appendingPathComponent("prism_gp.py"), atomically: true, encoding: .utf8)
            let script = ScriptLab.header(libraryFolder: dir.path, picture: pic) + code
            try BlenderScriptAdapter.openInBlender(script)
            log("Opened in Blender: draw on top with Blender's own brushes.")
        } catch {
            log(error.localizedDescription, error: true)
        }
    }

    func insert(_ snippet: String) {
        code += (code.hasSuffix("\n") ? "" : "\n") + snippet + "\n"
    }
}
