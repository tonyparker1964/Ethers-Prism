import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One picture in the PRISM image library.
public struct ImportedImage: Codable, Identifiable, Hashable, Sendable {
    /// SHA-256 of the file's bytes: the same picture saved twice has the same id.
    public var id: String
    /// The copy's name inside the library folder.
    public var fileName: String
    /// The name it had where it was found.
    public var originalName: String
    public var sourcePath: String
    public var importedAt: Date
    public var byteCount: Int
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(id: String, fileName: String, originalName: String, sourcePath: String, importedAt: Date,
                byteCount: Int, pixelWidth: Int?, pixelHeight: Int?) {
        self.id = id; self.fileName = fileName; self.originalName = originalName; self.sourcePath = sourcePath
        self.importedAt = importedAt; self.byteCount = byteCount; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }
}

/// The PRISM image library: a folder of imported pictures (exact copies of the originals), their thumbnails,
/// and an index keyed by content hash so the same picture is never imported twice.
///
/// Layout:
///   <folder>/<picture files>            byte-for-byte copies of what was imported
///   <folder>/.thumbnails/<hash>.jpg     thumbnails for the library view
///   <folder>/.prism-library.json        the index
public final class ImageImportLibrary {
    public enum Outcome: Equatable {
        case imported(ImportedImage)
        case duplicate(ImportedImage)
        /// Not a picture type PRISM imports.
        case unsupported
        /// Looks like a picture that is still being written (or can't be read yet); try again later.
        case notReady
    }

    /// `~/Pictures/PRISM/ChatGPT Imports`
    public static var defaultFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PRISM", isDirectory: true)
            .appendingPathComponent("ChatGPT Imports", isDirectory: true)
    }

    /// PNG, JPEG, HEIC, TIFF and WebP.
    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp"]

    /// Names browsers and download tools give files that aren't finished yet.
    public static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "tmp", "opdownload"]

    public let folder: URL
    public var thumbnailsFolder: URL { folder.appendingPathComponent(".thumbnails", isDirectory: true) }
    private var indexURL: URL { folder.appendingPathComponent(".prism-library.json") }

    /// Newest first.
    public private(set) var items: [ImportedImage] = []

    public init(folder: URL = ImageImportLibrary.defaultFolder) throws {
        self.folder = folder
        try FileManager.default.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? Self.decoder().decode([ImportedImage].self, from: data) {
            // Pictures deleted from the folder by hand leave the library too.
            items = saved.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        }
    }

    public func fileURL(for item: ImportedImage) -> URL { folder.appendingPathComponent(item.fileName) }
    public func thumbnailURL(for item: ImportedImage) -> URL { thumbnailsFolder.appendingPathComponent("\(item.id).jpg") }
    public func item(withID id: String) -> ImportedImage? { items.first { $0.id == id } }

    // MARK: - Which files

    /// A picture type PRISM imports, not hidden, not a half-finished download.
    public static func isCandidate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        let ext = url.pathExtension.lowercased()
        return supportedExtensions.contains(ext) && !isPartialDownload(url)
    }

    public static func isPartialDownload(_ url: URL) -> Bool {
        let lower = url.lastPathComponent.lowercased()
        if partialExtensions.contains(url.pathExtension.lowercased()) { return true }
        // e.g. "picture.png.crdownload" or Safari's "picture.png.download" bundles
        return partialExtensions.contains { lower.hasSuffix(".\($0)") } || lower.hasPrefix("unconfirmed ")
    }

    /// Picture files directly inside `folder` (not its subfolders), changed after `since` if given, oldest first.
    public static func candidates(in folder: URL, modifiedAfter since: Date? = nil) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles]) else { return [] }
        let dated: [(URL, Date)] = urls.compactMap { url in
            guard isCandidate(url), let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            let date = max(v.contentModificationDate ?? .distantPast, v.creationDate ?? .distantPast)
            if let since, date <= since { return nil }
            return (url, date)
        }
        return dated.sorted { $0.1 < $1.1 }.map(\.0)
    }

    // MARK: - Importing

    /// Imports one file: checks it's a finished picture, skips it if the same bytes are already in the library,
    /// otherwise copies it unchanged into the library folder and makes a thumbnail.
    @discardableResult
    public func importFile(_ url: URL, date: Date = Date()) throws -> Outcome {
        guard Self.isCandidate(url) else { return .unsupported }
        guard let info = Self.readableImage(url) else { return .notReady }
        let hash = try Self.sha256(of: url)
        if let existing = item(withID: hash) { return .duplicate(existing) }

        let name = uniqueName(for: url.lastPathComponent)
        let dest = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: dest)          // the original is never touched
        // A copy that changed on the way in (the source was still being written) is not kept.
        guard try Self.sha256(of: dest) == hash else {
            try? FileManager.default.removeItem(at: dest)
            return .notReady
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
        let item = ImportedImage(id: hash, fileName: name, originalName: url.lastPathComponent, sourcePath: url.path,
                                 importedAt: date, byteCount: bytes, pixelWidth: info.width, pixelHeight: info.height)
        Self.writeThumbnail(from: dest, to: thumbnailURL(for: item))
        items.insert(item, at: 0)
        try saveIndex()
        return .imported(item)
    }

    /// Makes any missing thumbnails (for example after the .thumbnails folder was cleared).
    public func repairThumbnails() {
        for item in items where !FileManager.default.fileExists(atPath: thumbnailURL(for: item).path) {
            Self.writeThumbnail(from: fileURL(for: item), to: thumbnailURL(for: item))
        }
    }

    private func uniqueName(for original: String) -> String {
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var name = original
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
            name = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            n += 1
        }
        return name
    }

    private func saveIndex() throws {
        let data = try Self.encoder().encode(items)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Helpers

    /// The picture's size, when the whole file can be read as an image; nil while it is incomplete.
    public static func readableImage(_ url: URL) -> (width: Int?, height: Int?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        // Decoding a small thumbnail proves the data is all there.
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 64]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) != nil else { return nil }
        return ((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
    }

    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public static func writeThumbnail(from url: URL, to dest: URL, maxPixels: Int = 512) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary),
              let out = CGImageDestinationCreateWithURL(dest as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(out, thumb, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        return CGImageDestinationFinalize(out)
    }

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

/// Decides when a newly seen file has finished downloading: its size and modification date must stay the same
/// across two checks at least `quiet` seconds apart, and it must not be empty.
public struct DownloadSettler {
    public var quiet: TimeInterval
    private var seen: [String: (size: Int64, modified: Date, since: Date)] = [:]

    public init(quiet: TimeInterval = 2) { self.quiet = quiet }

    public var pending: [String] { Array(seen.keys) }

    /// Starts (or keeps) watching a file.
    public mutating func track(_ url: URL, now: Date = Date()) {
        guard seen[url.path] == nil, let s = Self.stat(url) else { return }
        seen[url.path] = (s.size, s.modified, now)
    }

    /// Files that have settled since they were tracked. They stop being tracked once returned.
    public mutating func settled(now: Date = Date()) -> [URL] {
        var ready: [URL] = []
        for (path, last) in seen {
            let url = URL(fileURLWithPath: path)
            guard let s = Self.stat(url) else { seen[path] = nil; continue }      // gone (renamed or deleted)
            if s.size != last.size || s.modified != last.modified {
                seen[path] = (s.size, s.modified, now)                           // still changing: start over
            } else if s.size > 0, now.timeIntervalSince(last.since) >= quiet {
                ready.append(url)
                seen[path] = nil
            }
        }
        return ready
    }

    /// Stops tracking a file (for example after it was imported another way).
    public mutating func forget(_ url: URL) { seen[url.path] = nil }

    static func stat(_ url: URL) -> (size: Int64, modified: Date)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (a[.size] as? NSNumber)?.int64Value, let modified = a[.modificationDate] as? Date else { return nil }
        return (size, modified)
    }
}
