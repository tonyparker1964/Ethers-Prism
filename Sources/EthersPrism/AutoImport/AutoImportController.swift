import SwiftUI
import AppKit
import UserNotifications
import EthersPrismCore

/// PRISM Auto-Import: watches a folder you choose (where you save images from the ChatGPT desktop app,
/// or your Downloads folder) and copies each new picture, unchanged, into the PRISM image library.
///
/// It only reads the folder you pick. It never looks inside ChatGPT or its data: you save the picture,
/// PRISM notices the new file.
@MainActor
final class AutoImportController: ObservableObject {
    enum OpenTarget: String, CaseIterable, Identifiable {
        case studio, trueTrace, imageReference
        var id: String { rawValue }
        var label: String {
            switch self {
            case .studio: return "Edit Studio"
            case .trueTrace: return "True Trace"
            case .imageReference: return "Image (as reference)"
            }
        }
    }

    // Settings
    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled); restart() }
    }
    @Published var notify: Bool {
        didSet { defaults.set(notify, forKey: Keys.notify); if notify { requestNotificationPermission() } }
    }
    @Published var openAutomatically: Bool {
        didSet { defaults.set(openAutomatically, forKey: Keys.openAuto) }
    }
    @Published var openTarget: OpenTarget {
        didSet { defaults.set(openTarget.rawValue, forKey: Keys.openTarget) }
    }

    // State
    @Published private(set) var watchedFolder: URL?
    @Published private(set) var items: [ImportedImage] = []
    @Published private(set) var status = "Off"
    @Published var showLibrary = false

    /// Set by AppModel: opens a library picture in the editor.
    var onOpen: (@MainActor (URL, OpenTarget) -> Void)?

    private(set) var library: ImageImportLibrary?
    private let defaults = UserDefaults.standard
    private var source: DispatchSourceFileSystemObject?
    private var settler = DownloadSettler(quiet: 1.5)
    private var pollTimer: Timer?
    private var rescanTimer: Timer?
    private var accessing: URL?
    private var knownNames: Set<String> = []

    private enum Keys {
        static let enabled = "autoImport.enabled"
        static let notify = "autoImport.notify"
        static let openAuto = "autoImport.openAutomatically"
        static let openTarget = "autoImport.openTarget"
        static let bookmark = "autoImport.folderBookmark"
        static let lastSeen = "autoImport.lastSeen"
    }

    var libraryFolder: URL { library?.folder ?? ImageImportLibrary.defaultFolder }

    /// `~/Downloads/ChatGPT Images`: a folder just for pictures saved from ChatGPT.
    static var dedicatedFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatGPT Images", isDirectory: true)
    }
    static var downloadsFolder: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Keys.enabled)
        notify = d.bool(forKey: Keys.notify)
        openAutomatically = d.bool(forKey: Keys.openAuto)
        openTarget = OpenTarget(rawValue: d.string(forKey: Keys.openTarget) ?? "") ?? .studio
        do {
            let lib = try ImageImportLibrary()
            lib.repairThumbnails()
            library = lib
            items = lib.items
        } catch {
            status = "Couldn't create the PRISM library folder: \(error.localizedDescription)"
        }
        watchedFolder = resolveBookmark()
    }

    // MARK: - Starting and stopping

    /// Called once at launch: picks up anything saved while PRISM was closed, then watches.
    func start() { restart() }

    private func restart() {
        stopWatching()
        guard enabled else { status = "Off"; return }
        guard library != nil else { return }
        guard let folder = watchedFolder else { status = "Choose a folder to watch."; return }
        if folder.standardizedFileURL.path.hasPrefix(libraryFolder.standardizedFileURL.path) {
            status = "Choose a folder other than the PRISM library."
            return
        }
        if folder.startAccessingSecurityScopedResource() { accessing = folder }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            status = "The watched folder isn't there. Choose it again."
            return
        }

        // Missed while PRISM was closed: pictures changed since the last time PRISM looked.
        // The first time a folder is watched there's no date, so only new pictures are imported
        // (use Import Existing Images to bring in older ones).
        if let lastSeen = defaults.object(forKey: Keys.lastSeen) as? Date {
            for url in ImageImportLibrary.candidates(in: folder, modifiedAfter: lastSeen.addingTimeInterval(-5)) {
                settler.track(url)
            }
        }
        knownNames = currentNames(in: folder)

        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { status = "Can't watch \(folder.lastPathComponent). Choose it again to grant access."; return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                            queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.folderChanged() }
        }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
        // Some apps write without changing the folder listing; a slow look now and then catches those.
        rescanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.folderChanged() }
        }
        status = "Watching \(folder.lastPathComponent)"
        schedulePoll()
        if settler.pending.isEmpty { markSeen() }
    }

    private func stopWatching() {
        source?.cancel(); source = nil
        pollTimer?.invalidate(); pollTimer = nil
        rescanTimer?.invalidate(); rescanTimer = nil
        if let a = accessing { a.stopAccessingSecurityScopedResource(); accessing = nil }
        settler = DownloadSettler(quiet: 1.5)
    }

    // MARK: - Watching

    private func currentNames(in folder: URL) -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return Set(names)
    }

    private func folderChanged() {
        guard let folder = watchedFolder, source != nil else { return }
        let now = currentNames(in: folder)
        for name in now.subtracting(knownNames) {
            let url = folder.appendingPathComponent(name)
            if ImageImportLibrary.isCandidate(url) { settler.track(url) }
        }
        // A finished download is often renamed from "picture.png.crdownload" to "picture.png":
        // the new name shows up above. Files still growing are re-checked by the poll.
        knownNames = now
        schedulePoll()
    }

    /// While files are waiting to finish downloading, check them every second.
    private func schedulePoll() {
        guard pollTimer == nil, !settler.pending.isEmpty else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        for url in settler.settled() { importOne(url, retry: true) }
        if settler.pending.isEmpty {
            pollTimer?.invalidate(); pollTimer = nil
            markSeen()
        }
    }

    private func markSeen() { defaults.set(Date(), forKey: Keys.lastSeen) }

    // MARK: - Importing

    private var retries: [String: Int] = [:]

    @discardableResult
    private func importOne(_ url: URL, retry: Bool, quiet: Bool = false) -> ImportedImage? {
        guard let library else { return nil }
        do {
            switch try library.importFile(url) {
            case .imported(let item):
                items = library.items
                retries[url.path] = nil
                status = "Imported \(item.originalName)"
                if notify && !quiet { postNotification(for: item) }
                if openAutomatically && !quiet { onOpen?(library.fileURL(for: item), openTarget) }
                return item
            case .duplicate(let item):
                retries[url.path] = nil
                status = "\(url.lastPathComponent) is already in the library (as \(item.fileName))."
                return item
            case .notReady:
                // Still downloading or not readable yet: try a few more times.
                let n = (retries[url.path] ?? 0) + 1
                retries[url.path] = n
                if retry && n <= 10 { settler.track(url); schedulePoll() } else { retries[url.path] = nil }
            case .unsupported:
                break
            }
        } catch {
            status = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
        }
        return nil
    }

    /// Imports the pictures already in the watched folder (duplicates are skipped).
    func importExisting() {
        guard let folder = watchedFolder, library != nil else { return }
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let before = items.count
        let wasOpening = openAutomatically
        openAutomatically = false              // don't open dozens of sessions at once
        defer { openAutomatically = wasOpening }
        for url in ImageImportLibrary.candidates(in: folder) { importOne(url, retry: false) }
        status = "Imported \(items.count - before) existing picture\(items.count - before == 1 ? "" : "s")."
    }

    /// Imports pictures you choose by hand (or drop on the library).
    @discardableResult
    func importFiles(_ urls: [URL]) -> [ImportedImage] {
        urls.compactMap { importOne($0, retry: false, quiet: true) }
    }

    /// Imports a picture that only exists in memory (pasted, or rendered by the Studio) by writing it to a
    /// temporary file with `name` first.
    @discardableResult
    func importData(_ data: Data, name: String) -> ImportedImage? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prism-import-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        guard (try? data.write(to: url)) != nil else { return nil }
        return importOne(url, retry: false, quiet: true)
    }

    func fileURL(for item: ImportedImage) -> URL? { library?.fileURL(for: item) }

    func remove(_ item: ImportedImage) {
        guard let library else { return }
        let file = library.fileURL(for: item)
        // Moves the library copy to the Trash; the original where you saved it is untouched.
        NSWorkspace.shared.recycle([file]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, let lib = try? ImageImportLibrary(folder: self.libraryFolder) else { return }
                self.library = lib
                self.items = lib.items
            }
        }
    }

    func thumbnail(for item: ImportedImage) -> NSImage? {
        guard let library else { return nil }
        return NSImage(contentsOf: library.thumbnailURL(for: item))
    }

    func open(_ item: ImportedImage, in target: OpenTarget) {
        guard let library else { return }
        onOpen?(library.fileURL(for: item), target)
        showLibrary = false
    }

    func showInFinder(_ item: ImportedImage? = nil) {
        if let item, let library {
            NSWorkspace.shared.activateFileViewerSelecting([library.fileURL(for: item)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([libraryFolder])
        }
    }

    // MARK: - Choosing the folder

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch This Folder"
        panel.message = "Choose the folder where you save images from the ChatGPT app."
        panel.directoryURL = watchedFolder ?? Self.downloadsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url)
    }

    func useDownloads() { setFolder(Self.downloadsFolder) }

    func useDedicatedFolder() {
        try? FileManager.default.createDirectory(at: Self.dedicatedFolder, withIntermediateDirectories: true)
        setFolder(Self.dedicatedFolder)
    }

    private func setFolder(_ url: URL) {
        if url.standardizedFileURL.path.hasPrefix(libraryFolder.standardizedFileURL.path) {
            status = "That's the PRISM library itself. Choose the folder you save into."
            return
        }
        if let data = Self.makeBookmark(url) { defaults.set(data, forKey: Keys.bookmark) }
        // A new folder starts from now; older pictures there come in only with Import Existing Images.
        markSeen()
        watchedFolder = url
        if enabled { restart() } else { enabled = true }
    }

    /// A security-scoped bookmark keeps access to the folder across launches (a plain bookmark where
    /// security scope isn't available).
    static func makeBookmark(_ url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Keys.bookmark) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        if let url, stale, let fresh = Self.makeBookmark(url) { defaults.set(fresh, forKey: Keys.bookmark) }
        return url
    }

    // MARK: - Notifications

    /// Notifications need a real app bundle (not `swift run`).
    private var canNotify: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func requestNotificationPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotification(for item: ImportedImage) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Imported to PRISM"
        content.body = item.originalName
        let request = UNNotificationRequest(identifier: item.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

