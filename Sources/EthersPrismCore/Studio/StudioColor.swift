import Foundation
import CoreImage

/// The Color tab: color wheels (Lift / Gamma / Gain / Offset and Shadows / Midtones / Highlights),
/// Match to Reference (Lab statistics transfer) and an imported .cube LUT. All three are baked into one
/// 33-point 3D LUT so they cost a single GPU pass.
public enum StudioColor {
    public static let cubeSize = 33

    // MARK: - Wheels

    public enum Wheel: String, CaseIterable, Identifiable, Sendable {
        case lift, gamma, gain, offset, shadows, midtones, highlights
        public var id: String { rawValue }
        public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        public var xKey: String { rawValue + "X" }
        public var yKey: String { rawValue + "Y" }
        /// The wheel's luminance (master) slider.
        public var levelKey: String { rawValue + "L" }
        public static let primary: [Wheel] = [.lift, .gamma, .gain, .offset]
        public static let log: [Wheel] = [.shadows, .midtones, .highlights]
    }

    /// How a wheel position (x right, y up; unit circle) tints red, green and blue.
    public static func tint(x: Double, y: Double) -> (r: Double, g: Double, b: Double) {
        let mag = min(hypot(x, y), 1)
        guard mag > 0.0001 else { return (0, 0, 0) }
        let a = atan2(y, x)
        return (mag * cos(a), mag * cos(a - 2 * .pi / 3), mag * cos(a + 2 * .pi / 3))
    }

    /// The hue shown at a wheel position (for drawing the wheel).
    public static func displayColor(angle: Double) -> (r: Double, g: Double, b: Double) {
        let t = tint(x: cos(angle), y: sin(angle))
        return (0.5 + 0.5 * t.r, 0.5 + 0.5 * t.g, 0.5 + 0.5 * t.b)
    }

    /// Every key the Color tab writes (for Reset Color).
    public static var allKeys: [String] {
        Wheel.allCases.flatMap { [$0.xKey, $0.yKey, $0.levelKey] } + ["matchStrength", "lutStrength"] + matchKeys
            + StudioControls.primaries.map(\.id)
    }

    /// Wheel numbers as DaVinci Resolve shows them: Y (master) and R, G, B (the colour push).
    public static func numbers(_ w: Wheel, _ e: StudioEdit) -> (y: Double, r: Double, g: Double, b: Double) {
        let t = tint(x: e[w.xKey], y: e[w.yKey])
        return (e[w.levelKey] / 100, t.r, t.g, t.b)
    }

    /// Sets a wheel from typed R, G, B values: the shared part goes to Y, the rest becomes the wheel position.
    public static func setNumbers(_ w: Wheel, _ e: inout StudioEdit, r: Double, g: Double, b: Double) {
        let m = (r + g + b) / 3
        var x = r - m, y = (g - b) / 3.0.squareRoot()
        let mag = hypot(x, y)
        if mag > 1 { x /= mag; y /= mag }
        e[w.xKey] = x; e[w.yKey] = y
        e[w.levelKey] = min(max(e[w.levelKey] + m * 100, -100), 100)
    }

    static func usesPrimaries(_ e: StudioEdit) -> Bool {
        StudioControls.primaries.contains { $0.id != "midDetail" && $0.id != "tint" && e.isChanged($0.id) }
    }

    /// Contrast / Pivot, Shadows / Highlights, curves, Color Boost, Saturation, Hue (in that order).
    static func primariesAndCurves(_ c0: SIMD3<Double>, _ e: StudioEdit) -> SIMD3<Double> {
        var c = c0
        let k = e["contrastP"], p = e["pivot"]
        if k != 1 { c = (c - SIMD3(repeating: p)) * k + SIMD3(repeating: p) }
        func luma(_ v: SIMD3<Double>) -> Double { 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z }
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t)
        }
        let sh = e["shadowsP"] / 100, hi = e["highlightsP"] / 100
        if sh != 0 || hi != 0 {
            let l = luma(c)
            c = c + SIMD3(repeating: sh * 0.25 * (1 - smooth(0.0, 0.5, l)) + hi * 0.25 * smooth(0.5, 1.0, l))
        }
        // Custom curves: Y on luminance, then each channel.
        let y = e.curve(.luma)
        if !y.isEmpty {
            let l = min(max(luma(c), 0), 1)
            c = c + SIMD3(repeating: StudioCurves.evaluate(.luma, y, at: l) - l)
        }
        for (i, kind) in [(0, CurveKind.red), (1, .green), (2, .blue)] {
            let pts = e.curve(kind)
            if !pts.isEmpty { c[i] = StudioCurves.evaluate(kind, pts, at: min(max(c[i], 0), 1)) }
        }
        // Hue curves and saturation work in HSV.
        let hh = e.curve(.hueHue), hs = e.curve(.hueSat), hl = e.curve(.hueLum), ls = e.curve(.lumSat)
        let boost = e["colorBoost"] / 100, sat = e["saturationP"] / 50, hueShift = (e["hue"] - 50) / 100
        if !hh.isEmpty || !hs.isEmpty || !hl.isEmpty || !ls.isEmpty || boost != 0 || sat != 1 || hueShift != 0 {
            let l0 = min(max(luma(c), 0), 1)
            var hsv = StudioCurves.toHSV(clamp(c))
            let h0 = hsv.x, s0 = hsv.y
            if !hh.isEmpty { hsv.x += (StudioCurves.evaluate(.hueHue, hh, at: h0) - 0.5) * 0.5 }
            if !hs.isEmpty { hsv.y *= StudioCurves.evaluate(.hueSat, hs, at: h0) * 2 }
            if !ls.isEmpty { hsv.y *= StudioCurves.evaluate(.lumSat, ls, at: l0) * 2 }
            if !hl.isEmpty { hsv.z *= 1 + (StudioCurves.evaluate(.hueLum, hl, at: h0) - 0.5) * 1.2 * s0 }
            // Color Boost lifts the least saturated colours most (like vibrance).
            if boost != 0 { hsv.y = hsv.y + boost * hsv.y * (1 - hsv.y) * 1.5 }
            hsv.y *= sat
            hsv.x += hueShift
            hsv.y = min(max(hsv.y, 0), 1)
            c = StudioCurves.fromHSV(hsv)
        }
        return c
    }

    static func usesCurves(_ e: StudioEdit) -> Bool { e.curves != nil }

    static func usesWheels(_ e: StudioEdit) -> Bool {
        Wheel.allCases.contains { e[$0.xKey] != 0 || e[$0.yKey] != 0 || e[$0.levelKey] != 0 }
    }

    /// Applies the wheels to one sRGB colour (0...1).
    static func wheels(_ c: SIMD3<Double>, _ e: StudioEdit) -> SIMD3<Double> {
        func t(_ w: Wheel) -> SIMD3<Double> { let v = tint(x: e[w.xKey], y: e[w.yKey]); return SIMD3(v.r, v.g, v.b) }
        func l(_ w: Wheel) -> Double { e[w.levelKey] / 100 }
        var v = c
        // Lift raises or lowers blacks (whites stay), Gain scales whites, Gamma bends the middle, Offset shifts all.
        let lift = SIMD3(repeating: l(.lift) * 0.25) + t(.lift) * 0.15
        let gain = SIMD3(repeating: l(.gain) * 0.5) + t(.gain) * 0.3
        let gamma = SIMD3(repeating: l(.gamma) * 0.6) + t(.gamma) * 0.4
        let offset = SIMD3(repeating: l(.offset) * 0.2) + t(.offset) * 0.1
        v = v + lift * (SIMD3(repeating: 1) - v)
        v = v * (SIMD3(repeating: 1) + gain)
        for i in 0..<3 { v[i] = pow(max(v[i], 0), exp(-gamma[i])) }
        v = v + offset
        // Log wheels: each touches only its tonal range.
        let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let k = min(max((x - a) / (b - a), 0), 1); return k * k * (3 - 2 * k)
        }
        let ws = 1 - smooth(0.05, 0.45, luma)
        let wh = smooth(0.55, 0.95, luma)
        let wm = max(0, 1 - ws - wh)
        for (w, weight) in [(Wheel.shadows, ws), (.midtones, wm), (.highlights, wh)] where weight > 0 {
            v = v + (SIMD3(repeating: l(w) * 0.2) + t(w) * 0.12) * weight
        }
        return v
    }

    // MARK: - Match to Reference

    static let matchKeys = (0..<6).map { "matchSrc\($0)" } + (0..<6).map { "matchRef\($0)" }

    /// Lab mean and spread (L, a, b means then L, a, b standard deviations) of a picture.
    public static func stats(of image: CIImage, context: CIContext = StudioRenderer.context) -> [Double] {
        let e = image.extent
        let s = 96 / max(e.width, e.height)
        let small = image.transformed(by: CGAffineTransform(scaleX: min(s, 1), y: min(s, 1)))
        let rect = small.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return [50, 0, 0, 20, 10, 10] }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: rect, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var sum = SIMD3<Double>(0, 0, 0), sq = SIMD3<Double>(0, 0, 0)
        var n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 8 {
            let lab = toLab(SIMD3(Double(px[i]) / 255, Double(px[i + 1]) / 255, Double(px[i + 2]) / 255))
            sum += lab; sq += lab * lab; n += 1
        }
        guard n > 0 else { return [50, 0, 0, 20, 10, 10] }
        let mean = sum / n
        let sd = (sq / n - mean * mean)
        return [mean.x, mean.y, mean.z, sqrt(max(sd.x, 1)), sqrt(max(sd.y, 1)), sqrt(max(sd.z, 1))]
    }

    /// Stores source and reference statistics in the edit (strength starts at 100%).
    public static func setMatch(_ e: inout StudioEdit, source: [Double], reference: [Double], name: String) {
        for i in 0..<6 { e.values["matchSrc\(i)"] = source[i]; e.values["matchRef\(i)"] = reference[i] }
        e.matchReferenceName = name
    }

    public static func clearMatch(_ e: inout StudioEdit) {
        for k in matchKeys { e.values[k] = nil }
        e["matchStrength"] = 100
        e.matchReferenceName = nil
    }

    public static func hasMatch(_ e: StudioEdit) -> Bool { e.values["matchRef0"] != nil }

    static func match(_ c: SIMD3<Double>, _ e: StudioEdit) -> SIMD3<Double> {
        let k = e["matchStrength"] / 100
        guard k > 0 else { return c }
        let src = (0..<6).map { e.values["matchSrc\($0)"] ?? 0 }
        let ref = (0..<6).map { e.values["matchRef\($0)"] ?? 0 }
        var lab = toLab(c)
        for i in 0..<3 {
            let scale = min(max(ref[i + 3] / max(src[i + 3], 0.5), 0.4), 2.5)
            lab[i] = (lab[i] - src[i]) * scale + ref[i]
        }
        let out = fromLab(lab)
        return c + (out - c) * k
    }

    // MARK: - LUT files

    /// A parsed .cube 3D LUT.
    public struct CubeLUT: Sendable {
        public let size: Int
        public let data: [SIMD3<Float>]       // red fastest
        public let domainMin: SIMD3<Float>
        public let domainMax: SIMD3<Float>

        public func sample(_ c: SIMD3<Double>) -> SIMD3<Double> {
            let n = size - 1
            var p = [0.0, 0.0, 0.0]
            for i in 0..<3 {
                let lo = Double(domainMin[i]), hi = Double(domainMax[i])
                p[i] = min(max((c[i] - lo) / max(hi - lo, 1e-6), 0), 1) * Double(n)
            }
            let i0 = p.map { min(Int($0), n - 1) }
            let f = (0..<3).map { p[$0] - Double(i0[$0]) }
            func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Double> {
                let v = data[r + g * size + b * size * size]; return SIMD3(Double(v.x), Double(v.y), Double(v.z))
            }
            var out = SIMD3<Double>(0, 0, 0)
            for dr in 0...1 { for dg in 0...1 { for db in 0...1 {
                let w = (dr == 1 ? f[0] : 1 - f[0]) * (dg == 1 ? f[1] : 1 - f[1]) * (db == 1 ? f[2] : 1 - f[2])
                if w > 0 { out += at(i0[0] + dr, i0[1] + dg, i0[2] + db) * w }
            } } }
            return out
        }
    }

    public enum LUTError: LocalizedError {
        case notACube(String)
        public var errorDescription: String? {
            if case .notACube(let n) = self { return "\(n) isn't a 3D .cube LUT PRISM can read." }
            return nil
        }
    }

    public static func parseCube(_ text: String, name: String = "LUT") throws -> CubeLUT {
        var size = 0
        var lo = SIMD3<Float>(0, 0, 0), hi = SIMD3<Float>(1, 1, 1)
        var data: [SIMD3<Float>] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            let nums = parts.compactMap { Float($0) }
            switch parts.first?.uppercased() {
            case "LUT_3D_SIZE": size = Int(nums.first ?? 0)
            case "LUT_1D_SIZE": throw LUTError.notACube(name)
            case "DOMAIN_MIN" where nums.count == 3: lo = SIMD3(nums[0], nums[1], nums[2])
            case "DOMAIN_MAX" where nums.count == 3: hi = SIMD3(nums[0], nums[1], nums[2])
            default:
                if nums.count == 3 && parts.count == 3 { data.append(SIMD3(nums[0], nums[1], nums[2])) }
            }
        }
        guard size >= 2, data.count == size * size * size else { throw LUTError.notACube(name) }
        return CubeLUT(size: size, data: data, domainMin: lo, domainMax: hi)
    }

    private static let lock = NSLock()
    private static var lutCache: [String: CubeLUT] = [:]
    private static var cubeCache: [String: Data] = [:]

    public static func loadLUT(path: String) -> CubeLUT? {
        lock.lock(); defer { lock.unlock() }
        if let l = lutCache[path] { return l }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let lut = try? parseCube(text, name: (path as NSString).lastPathComponent) else { return nil }
        lutCache[path] = lut
        return lut
    }

    // MARK: - The combined cube

    /// The 3D LUT for this edit's Color tab, or nil when the Color tab is untouched.
    public static func cube(for e: StudioEdit) -> Data? {
        let wheelsOn = usesWheels(e)
        let primOn = usesPrimaries(e) || usesCurves(e)
        let matchOn = hasMatch(e) && e["matchStrength"] > 0
        let lut = e.lutPath.flatMap { loadLUT(path: $0) }
        let lutK = lut == nil ? 0 : e["lutStrength"] / 100
        guard wheelsOn || primOn || matchOn || lutK > 0 else { return nil }

        let keyValues = allKeys.map { "\($0)=\(e[$0])" }.joined(separator: ",") + "|\(e.lutPath ?? "")"
            + "|\(String(describing: e.curves?.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value.map { "\($0.x),\($0.y)" })" }))"
        // Lum Mix: 100 = the wheels' Y (master) moves change brightness only; 0 = per channel.
        var levelsOnly = StudioEdit()
        for w in Wheel.allCases { levelsOnly[w.levelKey] = e[w.levelKey] }
        let lumMix = e["lumMix"] / 100
        lock.lock()
        if let d = cubeCache[keyValues] { lock.unlock(); return d }
        lock.unlock()

        let n = cubeSize
        var out = [Float](repeating: 1, count: n * n * n * 4)
        var i = 0
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            var c = SIMD3(Double(r), Double(g), Double(b)) / Double(n - 1)
            if wheelsOn {
                let full = wheels(c, e)
                if lumMix > 0 {
                    let lv = wheels(c, levelsOnly) - c
                    let ly = 0.2126 * lv.x + 0.7152 * lv.y + 0.0722 * lv.z
                    // At 100 the Y moves are spread evenly (luminance); lower lets them act per channel.
                    c = full - lv + (SIMD3(repeating: ly) * lumMix + lv * (1 - lumMix))
                } else {
                    c = full
                }
            }
            if primOn { c = primariesAndCurves(c, e) }
            if matchOn { c = match(clamp(c), e) }
            if let lut, lutK > 0 { let l = lut.sample(clamp(c)); c = c + (l - c) * lutK }
            c = clamp(c)
            out[i] = Float(c.x); out[i + 1] = Float(c.y); out[i + 2] = Float(c.z); out[i + 3] = 1
            i += 4
        } } }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if cubeCache.count > 24 { cubeCache.removeAll() }
        cubeCache[keyValues] = data
        lock.unlock()
        return data
    }

    public static func apply(_ image: CIImage, _ e: StudioEdit) -> CIImage {
        guard let data = cube(for: e) else { return image }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize, "inputCubeData": data,
            "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB)!])
    }

    // MARK: - Lab

    static func clamp(_ c: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(min(max(c.x, 0), 1), min(max(c.y, 0), 1), min(max(c.z, 0), 1))
    }

    static func toLab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = lin(c.x), g = lin(c.y), b = lin(c.z)
        let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func fromLab(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func inv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116) / 7.787 }
        let x = inv(fx) * 0.95047, y = inv(fy), z = inv(fz) * 1.08883
        let r = 3.2406 * x - 1.5372 * y - 0.4986 * z
        let g = -0.9689 * x + 1.8758 * y + 0.0415 * z
        let b = 0.0557 * x - 0.2040 * y + 1.0570 * z
        func gam(_ v: Double) -> Double { let v = max(v, 0); return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        return SIMD3(gam(r), gam(g), gam(b))
    }
}
