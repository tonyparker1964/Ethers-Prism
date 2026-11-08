import Foundation

/// What a sample is used for in a beat.
public enum SampleRole: String, Codable, CaseIterable, Hashable, Sendable {
    case kick, snare, clap, closedHat, openHat, perc, tom, cymbal, bass

    public var label: String {
        switch self {
        case .kick: return "Kick"
        case .snare: return "Snare"
        case .clap: return "Clap"
        case .closedHat: return "Closed hat"
        case .openHat: return "Open hat"
        case .perc: return "Percussion"
        case .tom: return "Tom"
        case .cymbal: return "Cymbal"
        case .bass: return "Bass"
        }
    }

    /// Which role stands in when a kit has none of this one.
    public var fallbacks: [SampleRole] {
        switch self {
        case .kick: return []
        case .snare: return [.clap]
        case .clap: return [.snare]
        case .closedHat: return [.openHat, .perc]
        case .openHat: return [.closedHat]
        case .perc: return [.tom]
        case .tom: return [.perc, .snare]
        case .cymbal: return [.openHat]
        case .bass: return []
        }
    }
}

/// One usable audio file found on disk.
public struct SampleFile: Codable, Hashable, Sendable {
    public var path: String
    public var role: SampleRole
    /// The kit or expansion the file belongs to (for example "Lazer Dice").
    public var group: String

    public init(path: String, role: SampleRole, group: String) {
        self.path = path
        self.role = role
        self.group = group
    }

    public var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
}

/// Every usable sample under the folders the person chose.
public struct SampleIndex: Codable, Hashable, Sendable {
    public var roots: [String]
    public var files: [SampleFile]
    public var scannedAt: Date
    /// Files skipped because they're in Native Instruments' locked formats (.ncw, .nkx and similar).
    public var lockedCount: Int

    public init(roots: [String] = [], files: [SampleFile] = [], scannedAt: Date = Date(), lockedCount: Int = 0) {
        self.roots = roots
        self.files = files
        self.scannedAt = scannedAt
        self.lockedCount = lockedCount
    }

    public var isEmpty: Bool { files.isEmpty }

    public func count(_ role: SampleRole) -> Int { files.filter { $0.role == role }.count }

    public var groups: [String] { Array(Set(files.map(\.group))).sorted() }
}

/// Reads folders of samples and sorts each file into a role by its name and the folders it sits in.
public enum SampleScanner {
    public static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "flac"]
    /// Native Instruments' own sample containers. They only play inside NI's plug-ins.
    public static let lockedExtensions: Set<String> = ["ncw", "nkx", "nkc", "nkr", "nicnt"]
    static let maxFileBytes = 40_000_000

    /// Walks every root. Runs on whatever thread calls it; it can take a while on a big library.
    public static func scan(roots: [URL], isCancelled: () -> Bool = { false }) -> SampleIndex {
        var files: [SampleFile] = []
        var locked = 0
        let fm = FileManager.default
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if isCancelled() { break }
                let ext = url.pathExtension.lowercased()
                if lockedExtensions.contains(ext) { locked += 1; continue }
                guard audioExtensions.contains(ext) else { continue }
                if url.lastPathComponent.hasPrefix("._") { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if values?.isRegularFile == false { continue }
                if let size = values?.fileSize, size > maxFileBytes { continue }
                let full = url.standardizedFileURL.path
                var relative = full.hasPrefix(rootPath + "/") ? String(full.dropFirst(rootPath.count + 1)) : url.lastPathComponent
                if relative.isEmpty { relative = url.lastPathComponent }
                guard let role = classify(relativePath: relative) else { continue }
                files.append(SampleFile(path: full, role: role,
                                        group: group(relativePath: relative, rootName: root.lastPathComponent)))
            }
        }
        files.sort { $0.path < $1.path }
        return SampleIndex(roots: roots.map { $0.standardizedFileURL.path }, files: files, scannedAt: Date(), lockedCount: locked)
    }

    /// Splits text into lowercase words, breaking at punctuation, letter/digit changes and camelCase.
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var lastKind = 0 // 1 letter, 2 digit
        var lastWasLower = false
        for ch in text {
            let kind = ch.isLetter ? 1 : (ch.isNumber ? 2 : 0)
            let breakHere = kind == 0 || (kind != lastKind && !current.isEmpty)
                || (kind == 1 && ch.isUppercase && lastWasLower)
            if breakHere, !current.isEmpty {
                out.append(current.lowercased())
                current = ""
            }
            if kind != 0 { current.append(ch) }
            lastKind = kind
            lastWasLower = ch.isLetter && ch.isLowercase
        }
        if !current.isEmpty { out.append(current.lowercased()) }
        return out
    }

    static let skipWords: Set<String> = ["loop", "loops", "bpm", "fx", "sfx", "riser", "risers", "impact", "impacts",
                                         "vox", "vocal", "vocals", "chant", "speech", "phrase", "phrases", "atmo", "texture", "textures"]
    static let kickWords: Set<String> = ["kick", "kicks", "kik", "bd", "bassdrum", "kck"]
    static let hatWords: Set<String> = ["hat", "hats", "hihat", "hihats", "hh", "chh", "ohh", "closedhat", "openhat", "hhc", "hho"]
    static let openWords: Set<String> = ["open", "ohh", "openhat", "hho", "oh", "op"]
    static let clapWords: Set<String> = ["clap", "claps", "clp", "snap", "snaps"]
    static let snareWords: Set<String> = ["snare", "snares", "snr", "sd", "sn", "rim", "rims", "rimshot"]
    static let cymbalWords: Set<String> = ["crash", "crashes", "ride", "rides", "cymbal", "cymbals", "cym", "splash", "china"]
    static let tomWords: Set<String> = ["tom", "toms"]
    static let percWords: Set<String> = ["perc", "percs", "percussion", "conga", "congas", "bongo", "bongos", "shaker", "shakers",
                                         "tamb", "tambourine", "cowbell", "clave", "claves", "block", "guiro", "cabasa",
                                         "triangle", "timbale", "timbales", "woodblock"]
    static let bassWords: Set<String> = ["bass", "basses", "bassline", "808", "sub", "subs", "reese"]

    /// The role for a file, or nil if it isn't a one-shot drum or bass sound.
    /// The file name decides first; if it says nothing, the nearest folder that does decides.
    public static func classify(relativePath: String) -> SampleRole? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard let fileName = parts.last else { return nil }
        let allTokens = Set(parts.flatMap { tokens($0) })
        if !allTokens.isDisjoint(with: skipWords) { return nil }

        let nameTokens = tokens((fileName as NSString).deletingPathExtension)
        var role = classify(tokens: nameTokens)
        if role == nil {
            for folder in parts.dropLast().reversed() {
                if let r = classify(tokens: tokens(folder)) { role = r; break }
            }
        }
        // "Open 1.wav" inside a "Hihat" folder is an open hat.
        if role == .closedHat {
            let nearby = Set(nameTokens + (parts.count > 1 ? tokens(parts[parts.count - 2]) : []))
            if !nearby.isDisjoint(with: openWords) { role = .openHat }
        }
        return role
    }

    static func classify(tokens t: [String]) -> SampleRole? {
        let s = Set(t)
        if !s.isDisjoint(with: kickWords) || (s.contains("bass") && s.contains("drum")) { return .kick }
        if !s.isDisjoint(with: hatWords) || (s.contains("hi") && s.contains("hat")) {
            return s.isDisjoint(with: openWords) ? .closedHat : .openHat
        }
        if !s.isDisjoint(with: clapWords) { return .clap }
        if !s.isDisjoint(with: snareWords) { return .snare }
        if !s.isDisjoint(with: cymbalWords) { return .cymbal }
        if !s.isDisjoint(with: tomWords) { return .tom }
        if !s.isDisjoint(with: percWords) { return .perc }
        if !s.isDisjoint(with: bassWords) { return .bass }
        return nil
    }

    static let containerFolders: Set<String> = ["samples", "sample", "drums", "drum", "one shots", "oneshots", "one-shots",
                                                "sounds", "kits", "kit", "instruments", "audio"]

    /// The kit or expansion a file belongs to: the folder just above "Samples" (or "Drums"),
    /// otherwise the first folder under the root.
    public static func group(relativePath: String, rootName: String) -> String {
        let folders = relativePath.split(separator: "/").map(String.init).dropLast()
        if let i = folders.firstIndex(where: { containerFolders.contains($0.lowercased()) }) {
            return i > 0 ? folders[folders.index(before: i)] : rootName
        }
        return folders.first ?? rootName
    }
}

/// The library the Beats field plays from. The app sets it after a scan; generation only reads it.
public final class BeatsLibrary: @unchecked Sendable {
    public static let shared = BeatsLibrary()
    private let lock = NSLock()
    private var _index = SampleIndex()

    public var index: SampleIndex {
        get { lock.lock(); defer { lock.unlock() }; return _index }
        set { lock.lock(); _index = newValue; lock.unlock() }
    }
}
