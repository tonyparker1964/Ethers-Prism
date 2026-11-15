import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import EthersPrismCore

final class ImageImportTests: XCTestCase {
    private var root: URL!
    private var watched: URL!
    private var libraryFolder: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("prism-import-\(UUID().uuidString)")
        watched = root.appendingPathComponent("Downloads")
        libraryFolder = root.appendingPathComponent("PRISM/ChatGPT Imports")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a small picture of one colour.
    @discardableResult
    private func writeImage(_ name: String, red: CGFloat = 1, type: UTType = .png, size: Int = 64) throws -> URL {
        let url = watched.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0.3, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testDefaultLibraryFolderIsPrismChatGPTImports() {
        let f = ImageImportLibrary.defaultFolder
        XCTAssertEqual(f.lastPathComponent, "ChatGPT Imports")
        XCTAssertEqual(f.deletingLastPathComponent().lastPathComponent, "PRISM")
    }

    func testCandidatesAreSupportedFinishedPictures() {
        let ok = ["a.png", "b.PNG", "c.jpg", "d.jpeg", "e.heic", "f.tiff", "g.tif", "h.webp"]
        for n in ok { XCTAssertTrue(ImageImportLibrary.isCandidate(URL(fileURLWithPath: "/x/\(n)")), n) }
        let no = ["a.png.crdownload", "b.png.download", "c.jpg.part", "d.tmp", ".hidden.png", "notes.txt",
                  "movie.mp4", "Unconfirmed 1234.crdownload", "doc.pdf"]
        for n in no { XCTAssertFalse(ImageImportLibrary.isCandidate(URL(fileURLWithPath: "/x/\(n)")), n) }
    }

    func testImportCopiesOriginalUnchangedAndMakesThumbnail() throws {
        let src = try writeImage("ChatGPT Image Nov 14, 2026.png")
        let before = try Data(contentsOf: src)
        let lib = try ImageImportLibrary(folder: libraryFolder)
        guard case .imported(let item) = try lib.importFile(src) else { return XCTFail("not imported") }

        XCTAssertEqual(try Data(contentsOf: lib.fileURL(for: item)), before, "library copy is byte-for-byte")
        XCTAssertEqual(try Data(contentsOf: src), before, "original untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "original stays where it was")
        XCTAssertTrue(FileManager.default.fileExists(atPath: lib.thumbnailURL(for: item).path))
        XCTAssertEqual(item.pixelWidth, 64)
        XCTAssertEqual(item.id, try ImageImportLibrary.sha256(of: src))
        XCTAssertEqual(lib.items.count, 1)
    }

    func testSamePictureTwiceIsADuplicateEvenWithAnotherName() throws {
        let a = try writeImage("one.png")
        let b = watched.appendingPathComponent("one copy.png")
        try FileManager.default.copyItem(at: a, to: b)
        let lib = try ImageImportLibrary(folder: libraryFolder)
        guard case .imported = try lib.importFile(a) else { return XCTFail() }
        guard case .duplicate = try lib.importFile(b) else { return XCTFail("duplicate not detected") }
        XCTAssertEqual(lib.items.count, 1)
    }

    func testDifferentPicturesWithTheSameNameBothImport() throws {
        let a = try writeImage("image.png", red: 1)
        let lib = try ImageImportLibrary(folder: libraryFolder)
        guard case .imported(let first) = try lib.importFile(a) else { return XCTFail() }
        try writeImage("image.png", red: 0)          // overwritten with a new picture
        guard case .imported(let second) = try lib.importFile(a) else { return XCTFail() }
        XCTAssertEqual(first.fileName, "image.png")
        XCTAssertEqual(second.fileName, "image 2.png")
    }

    func testOtherFormatsImport() throws {
        let lib = try ImageImportLibrary(folder: libraryFolder)
        for (name, type, red) in [("j.jpg", UTType.jpeg, 0.1), ("t.tiff", .tiff, 0.2), ("h.heic", .heic, 0.3)] as [(String, UTType, CGFloat)] {
            let url = try writeImage(name, red: red, type: type)
            guard case .imported = try lib.importFile(url) else { return XCTFail(name) }
        }
        XCTAssertEqual(lib.items.count, 3)
    }

    func testHalfWrittenFileIsNotReady() throws {
        let full = try writeImage("big.png", size: 256)
        let data = try Data(contentsOf: full)
        let half = watched.appendingPathComponent("half.png")
        try data.prefix(data.count / 2).write(to: half)
        let lib = try ImageImportLibrary(folder: libraryFolder)
        XCTAssertEqual(try lib.importFile(half), .notReady)
        XCTAssertTrue(lib.items.isEmpty)
        XCTAssertEqual(try lib.importFile(watched.appendingPathComponent("x.png.crdownload")), .unsupported)
    }

    func testLibraryRemembersItsPicturesBetweenLaunches() throws {
        let src = try writeImage("keep.png")
        do {
            let lib = try ImageImportLibrary(folder: libraryFolder)
            _ = try lib.importFile(src)
        }
        let reopened = try ImageImportLibrary(folder: libraryFolder)
        XCTAssertEqual(reopened.items.count, 1)
        guard case .duplicate = try reopened.importFile(src) else { return XCTFail("index not persisted") }
    }

    func testMissedFilesScanUsesDate() throws {
        let old = try writeImage("old.png", red: 0.1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600),
                                               .creationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try writeImage("new.png", red: 0.9)
        try "hi".write(to: watched.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let found = ImageImportLibrary.candidates(in: watched, modifiedAfter: Date(timeIntervalSinceNow: -60))
        XCTAssertEqual(found.map(\.lastPathComponent), ["new.png"])
        XCTAssertEqual(ImageImportLibrary.candidates(in: watched).count, 2)
    }

    func testSettlerWaitsForTheFileToStopChanging() throws {
        let url = try writeImage("growing.png")
        var settler = DownloadSettler(quiet: 2)
        let t0 = Date()
        settler.track(url, now: t0)
        XCTAssertTrue(settler.settled(now: t0.addingTimeInterval(1)).isEmpty, "too soon")
        // It grows: the clock starts again.
        let h = try FileHandle(forWritingTo: url); try h.seekToEnd(); try h.write(contentsOf: Data([0])); try h.close()
        XCTAssertTrue(settler.settled(now: t0.addingTimeInterval(2.5)).isEmpty, "changed, so not settled")
        XCTAssertEqual(settler.settled(now: t0.addingTimeInterval(5)).map(\.lastPathComponent), ["growing.png"])
        XCTAssertTrue(settler.pending.isEmpty)
    }
}
