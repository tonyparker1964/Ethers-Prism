import Foundation

/// A point on a curve, both coordinates 0...1.
public struct CurvePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// The curves of Color Studio (after DaVinci Resolve): custom Y/R/G/B curves and the hue curves.
public enum CurveKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case luma, red, green, blue, hueHue, hueSat, hueLum, lumSat
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .luma: return "Y"
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        case .hueHue: return "Hue vs Hue"
        case .hueSat: return "Hue vs Sat"
        case .hueLum: return "Hue vs Lum"
        case .lumSat: return "Lum vs Sat"
        }
    }

    public static let custom: [CurveKind] = [.luma, .red, .green, .blue]
    public static let hue: [CurveKind] = [.hueHue, .hueSat, .hueLum, .lumSat]

    /// Hue curves wrap around (red at both ends).
    public var isPeriodic: Bool { self == .hueHue || self == .hueSat || self == .hueLum }
    /// Custom curves are identity (y = x) by default; the others are flat at 0.5 (no change).
    public var isCustom: Bool { CurveKind.custom.contains(self) }

    /// The value with no points added.
    public func neutral(_ x: Double) -> Double { isCustom ? x : 0.5 }
}

public enum StudioCurves {
    /// Evaluates a curve at x. Custom curves pin (0,0) and (1,1) unless the user moved them.
    public static func evaluate(_ kind: CurveKind, _ points: [CurvePoint], at x: Double) -> Double {
        guard !points.isEmpty else { return kind.neutral(x) }
        var pts = points.sorted { $0.x < $1.x }
        if kind.isPeriodic {
            // Wrap: copies one period to each side.
            let left = pts.map { CurvePoint($0.x - 1, $0.y) }, right = pts.map { CurvePoint($0.x + 1, $0.y) }
            return pchip(left + pts + right, x)
        }
        if pts.first!.x > 0.0001 { pts.insert(CurvePoint(0, kind.neutral(0)), at: 0) }
        if pts.last!.x < 0.9999 { pts.append(CurvePoint(1, kind.neutral(1))) }
        return pchip(pts, x)
    }

    /// Shape-preserving cubic (Fritsch–Carlson): smooth, and no overshoot between points.
    static func pchip(_ p: [CurvePoint], _ x: Double) -> Double {
        let n = p.count
        if n == 1 { return p[0].y }
        if x <= p[0].x { return p[0].y }
        if x >= p[n - 1].x { return p[n - 1].y }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (p[i + 1].y - p[i].y) / max(p[i + 1].x - p[i].x, 1e-9) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0 }
            else {
                let w1 = 2 * (p[i + 1].x - p[i].x) + (p[i].x - p[i - 1].x)
                let w2 = (p[i + 1].x - p[i].x) + 2 * (p[i].x - p[i - 1].x)
                m[i] = (w1 + w2) / (w1 / d[i - 1] + w2 / d[i])
            }
        }
        var k = 0
        while k < n - 2 && x > p[k + 1].x { k += 1 }
        let h = max(p[k + 1].x - p[k].x, 1e-9), t = (x - p[k].x) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * p[k].y + (t3 - 2 * t2 + t) * h * m[k]
            + (-2 * t3 + 3 * t2) * p[k + 1].y + (t3 - t2) * h * m[k + 1]
    }

    // MARK: - HSV

    public static func toHSV(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let mx = max(c.x, c.y, c.z), mn = min(c.x, c.y, c.z), d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == c.x { h = ((c.y - c.z) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == c.y { h = (c.z - c.x) / d + 2 }
            else { h = (c.x - c.y) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return SIMD3(h, mx > 0 ? d / mx : 0, mx)
    }

    public static func fromHSV(_ hsv: SIMD3<Double>) -> SIMD3<Double> {
        let h = (hsv.x - floor(hsv.x)) * 6, s = min(max(hsv.y, 0), 1), v = hsv.z
        let i = Int(h) % 6, f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}
