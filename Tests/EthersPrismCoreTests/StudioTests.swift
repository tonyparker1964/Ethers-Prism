import XCTest
import CoreImage
import UniformTypeIdentifiers
@testable import EthersPrismCore

final class StudioTests: XCTestCase {
    /// A 200×100 picture: left half dark blue-grey, right half light warm grey, with a few hard edges.
    private func sample(width: CGFloat = 200, height: CGFloat = 100) -> CIImage {
        let left = CIImage(color: CIColor(red: 0.2, green: 0.25, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
        let right = CIImage(color: CIColor(red: 0.7, green: 0.65, blue: 0.6)).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        // Fine grain so noise reduction and detail filters have something to work on.
        let grain = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.12)])
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return grain.composited(over: right.composited(over: left))
    }

    /// Average colour of an image.
    private func mean(_ image: CIImage) -> (r: Double, g: Double, b: Double) {
        let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var px = [Float](repeating: 0, count: 4)
        StudioRenderer.context.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    func testEveryControlHasAUniqueIDAndNeutralInRange() {
        XCTAssertEqual(Set(StudioControls.all.map(\.id)).count, StudioControls.all.count)
        for c in StudioControls.all { XCTAssertTrue(c.range.contains(c.neutral), c.id) }
        XCTAssertEqual(StudioControls.adjust.count, 9)
        XCTAssertEqual(StudioControls.realism.count, 10)
    }

    func testNeutralEditChangesNothing() {
        let e = StudioEdit()
        XCTAssertTrue(e.isIdentity)
        let m0 = mean(sample()), m1 = mean(StudioRenderer.apply(sample(), e))
        XCTAssertEqual(m0.r, m1.r, accuracy: 0.01); XCTAssertEqual(m0.b, m1.b, accuracy: 0.01)
    }

    func testSettingNeutralClearsTheValue() {
        var e = StudioEdit()
        e["exposure"] = 1
        XCTAssertTrue(e.isChanged("exposure"))
        e["exposure"] = 0
        XCTAssertFalse(e.isChanged("exposure"))
        e["enhanceDetail"] = 60           // its neutral
        XCTAssertTrue(e.values.isEmpty)
    }

    /// Each Adjust and Realism slider changes the picture: no placeholder controls.
    func testEverySliderDoesSomething() {
        let base = StudioRenderer.apply(sample(), StudioEdit())
        let baseData = pixels(base)
        for c in StudioControls.adjust + StudioControls.realism {
            var e = StudioEdit()
            e[c.id] = c.range.upperBound
            if c.id == "skinDetail" { e["noiseReduction"] = 0 }   // it also works on its own
            XCTAssertNotEqual(pixels(StudioRenderer.apply(sample(), e)), baseData, "\(c.id) had no effect")
        }
    }

    func testEnhanceSlidersChangeTheUpscale() {
        let base = pixels(StudioRenderer.upscale(sample(), factor: 2, StudioEdit()))
        for c in StudioControls.enhance where c.id != "upscaleFactor" {
            var e = StudioEdit()
            e[c.id] = c.id == "enhanceDetail" ? 100 : (c.neutral == 0 ? 100 : 0)
            XCTAssertNotEqual(pixels(StudioRenderer.upscale(sample(), factor: 2, e)), base, "\(c.id) had no effect")
        }
    }

    func testFourKSliderAndModes() {
        var e = StudioEdit()
        XCTAssertEqual(e.upscaleFactor, 2)
        e["upscaleFactor"] = 3.5
        XCTAssertEqual(StudioRenderer.render(sample(), e, size: .scale(e.upscaleFactor)).extent.size, CGSize(width: 700, height: 350))
        XCTAssertEqual(StudioControls.byID["upscaleFactor"]?.format(3.5), "3.5×")
        XCTAssertEqual(StudioControls.byID["upscaleFactor"]?.format(4), "4×")
        let standard = pixels(StudioRenderer.upscale(sample(), factor: 2, e))
        e.upscaleMode = .sharper
        XCTAssertNotEqual(pixels(StudioRenderer.upscale(sample(), factor: 2, e)), standard)
        e.upscaleMode = .standard
        XCTAssertNil(e.values["upscaleMode"])
    }

    func testExposureBrightensAndWarmthWarms() {
        var e = StudioEdit(); e["exposure"] = 1
        XCTAssertGreaterThan(mean(StudioRenderer.apply(sample(), e)).g, mean(sample()).g + 0.05)
        var warm = StudioEdit(); warm["temperature"] = 80
        var cool = StudioEdit(); cool["temperature"] = -80
        let w = mean(StudioRenderer.apply(sample(), warm)), c = mean(StudioRenderer.apply(sample(), cool))
        XCTAssertGreaterThan(w.r - w.b, c.r - c.b, "White Balance + should be warmer than −")
    }

    func testRotateAndCrop() {
        var e = StudioEdit(quarterTurns: 1)
        XCTAssertEqual(StudioRenderer.geometry(sample(), e).extent.size, CGSize(width: 100, height: 200))
        e = StudioEdit(crop: UnitRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        let cropped = StudioRenderer.geometry(sample(), e)
        XCTAssertEqual(cropped.extent, CGRect(x: 0, y: 0, width: 100, height: 50))
        XCTAssertGreaterThan(mean(cropped).r, 0.5, "the crop keeps the right (light) half")
        XCTAssertEqual(StudioRenderer.pixelSize(source: CGSize(width: 200, height: 100), edit: e, size: .scale(4)),
                       CGSize(width: 400, height: 200))
    }

    func testSizes() {
        let s = sample()
        XCTAssertEqual(StudioRenderer.render(s, StudioEdit(), size: .scale(2)).extent.size, CGSize(width: 400, height: 200))
        XCTAssertEqual(StudioRenderer.render(s, StudioEdit(), size: .scale(4)).extent.size, CGSize(width: 800, height: 400))
        XCTAssertEqual(StudioRenderer.render(s, StudioEdit(), size: .uhd4K).extent.size, CGSize(width: 3840, height: 2160))
        XCTAssertEqual(StudioRenderer.render(s, StudioEdit(), size: .longEdge4K).extent.width, 3840, accuracy: 1)
        XCTAssertEqual(StudioRenderer.render(s, StudioEdit(), size: .width(300)).extent.width, 300, accuracy: 1)
    }

    func testExportFormats() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(StudioFormat.writable.contains(.png))
        XCTAssertTrue(StudioFormat.writable.contains(.jpeg))
        for f in StudioFormat.writable {
            let url = dir.appendingPathComponent("out.\(f.ext)")
            try StudioRenderer.write(StudioRenderer.render(sample(), StudioEdit(), size: .scale(2)), to: url, format: f, quality: 0.8)
            let back = try StudioRenderer.load(url)
            XCTAssertEqual(back.extent.size, CGSize(width: 400, height: 200), f.rawValue)
        }
    }

    func testProjectsAndPresetsPersist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("studio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudioStore(root: root)
        var p = StudioProject(id: "abc", imagePath: "/tmp/x.png")
        p.edit["contrast"] = 20
        p.record("Contrast")
        p.record("Contrast")                    // same state: not recorded twice
        try store.save(p)
        let back = try XCTUnwrap(store.load("abc"))
        XCTAssertEqual(back.edit["contrast"], 20)
        XCTAssertEqual(back.history.count, 1)

        try store.savePresets(StudioPreset.builtIns + [StudioPreset(name: "Mine", values: ["vibrance": 30])])
        XCTAssertEqual(store.loadPresets().map(\.name), ["Mine"], "built-ins aren't saved")
    }

    private func pixels(_ image: CIImage) -> Data {
        let rect = image.extent.integral
        var data = Data(count: Int(rect.width * rect.height) * 4)
        data.withUnsafeMutableBytes { buf in
            StudioRenderer.context.render(image, toBitmap: buf.baseAddress!, rowBytes: Int(rect.width) * 4, bounds: rect,
                                          format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        return data
    }
}
