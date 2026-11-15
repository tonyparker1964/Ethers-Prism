import Foundation
import CoreImage
import CoreGraphics

/// Color Studio scopes (after DaVinci Resolve's): Parade, Waveform, Vectorscope, Histogram and CIE chromaticity.
public enum ScopeKind: String, CaseIterable, Identifiable, Sendable {
    case parade, waveform, vectorscope, histogram, cie
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .parade: return "Parade"
        case .waveform: return "Waveform"
        case .vectorscope: return "Vectorscope"
        case .histogram: return "Histogram"
        case .cie: return "CIE"
        }
    }
    /// Square scopes (the others are 2:1).
    public var isSquare: Bool { self == .vectorscope || self == .cie }
}

/// A small RGBA8 copy of a picture for measuring.
public struct ScopeSample: Sendable {
    public let pixels: [UInt8]
    public let width: Int
    public let height: Int

    public init(pixels: [UInt8], width: Int, height: Int) { self.pixels = pixels; self.width = width; self.height = height }

    public static func make(_ image: CIImage, maxWidth: CGFloat = 512, context: CIContext = StudioRenderer.context) -> ScopeSample? {
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return nil }
        let s = min(maxWidth / e.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let rect = small.extent.integral
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: rect, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return ScopeSample(pixels: px, width: w, height: h)
    }

    /// Counts per value (0...255) for red, green, blue and luminance.
    public func histogram() -> [[Int]] {
        var h = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            h[0][r] += 1; h[1][g] += 1; h[2][b] += 1
            h[3][min(255, (2126 * r + 7152 * g + 722 * b) / 10000)] += 1
        }
        return h
    }
}

public enum StudioScopes {
    /// Draws a scope as an image (black background; the app draws the graticule on top).
    public static func render(_ kind: ScopeKind, _ s: ScopeSample) -> CGImage? {
        switch kind {
        case .waveform: return waveform(s, parade: false)
        case .parade: return waveform(s, parade: true)
        case .vectorscope: return vectorscope(s)
        case .histogram: return histogramImage(s)
        case .cie: return cie(s)
        }
    }

    // MARK: Waveform and Parade

    static func waveform(_ s: ScopeSample, parade: Bool) -> CGImage? {
        let W = 512, H = 256
        var acc = [[Float]](repeating: [Float](repeating: 0, count: W * H), count: 3)
        let panel = parade ? W / 3 : W
        for y in 0..<s.height {
            for x in 0..<s.width {
                let i = (y * s.width + x) * 4
                for c in 0..<3 {
                    let v = Int(s.pixels[i + c])
                    let col = (parade ? c * panel : 0) + min(panel - 1, x * panel / s.width)
                    let row = (H - 1) - v * (H - 1) / 255
                    acc[c][row * W + col] += 1
                }
            }
        }
        return image(W, H) { idx in
            // A column holds `height` samples spread over the rows; this keeps typical traces bright but not clipped.
            let k: Float = Float(panel) / Float(max(s.width, 1)) < 1 ? 1 / (Float(s.height) * 0.02 * Float(s.width) / Float(panel))
                                                                    : 1 / (Float(s.height) * 0.02)
            func t(_ a: Float) -> UInt8 { UInt8(min(255, sqrt(a * k) * 255)) }
            if parade {
                // Each panel in its own colour.
                let col = idx % W, c = min(2, col / panel)
                let v = t(acc[c][idx])
                return c == 0 ? (v, v / 5, v / 5) : c == 1 ? (v / 5, v, v / 5) : (v / 4, v / 3, v)
            }
            return (t(acc[0][idx]), t(acc[1][idx]), t(acc[2][idx]))
        }
    }

    // MARK: Vectorscope

    /// BT.709 colour-difference position of a colour: x = Cb, y = Cr (each about −0.5…0.5).
    public static func vectorPosition(r: Double, g: Double, b: Double) -> (x: Double, y: Double) {
        (-0.1146 * r - 0.3854 * g + 0.5 * b, 0.5 * r - 0.4542 * g - 0.0458 * b)
    }

    static func vectorscope(_ s: ScopeSample) -> CGImage? {
        let N = 256
        var count = [Float](repeating: 0, count: N * N)
        var col = [SIMD3<Float>](repeating: .zero, count: N * N)
        for i in stride(from: 0, to: s.pixels.count, by: 4) {
            let r = Double(s.pixels[i]) / 255, g = Double(s.pixels[i + 1]) / 255, b = Double(s.pixels[i + 2]) / 255
            let p = vectorPosition(r: r, g: g, b: b)
            let x = Int((0.5 + p.x * 0.92) * Double(N - 1)), y = Int((0.5 - p.y * 0.92) * Double(N - 1))
            guard x >= 0, x < N, y >= 0, y < N else { continue }
            count[y * N + x] += 1
            col[y * N + x] += SIMD3(Float(r), Float(g), Float(b))
        }
        let k: Float = Float(N * N) / Float(max(s.width * s.height, 1)) * 0.6
        return image(N, N) { idx in
            let n = count[idx]
            guard n > 0 else { return (0, 0, 0) }
            let a = min(1, sqrt(n * k))
            let c = col[idx] / n
            // Brighten the colour itself so hues are easy to read.
            let m = max(c.x, c.y, c.z, 0.2)
            return (UInt8(min(255, c.x / m * 255 * a)), UInt8(min(255, c.y / m * 255 * a)), UInt8(min(255, c.z / m * 255 * a)))
        }
    }

    // MARK: Histogram

    static func histogramImage(_ s: ScopeSample) -> CGImage? {
        let W = 512, H = 256
        let h = s.histogram()
        let peak = Float(max(h[0...2].flatMap { $0.dropFirst().dropLast() }.max() ?? 1, 1))
        return image(W, H) { idx in
            let x = idx % W, y = H - 1 - idx / W
            let bin = x * 255 / (W - 1)
            func on(_ c: Int) -> UInt8 { Float(h[c][bin]) / peak * Float(H) > Float(y) ? 200 : 0 }
            return (on(0), on(1), on(2))
        }
    }

    // MARK: CIE 1931

    /// The chromaticity (x, y) of an sRGB colour.
    public static func chromaticity(r: Double, g: Double, b: Double) -> (x: Double, y: Double)? {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        let X = 0.4124 * R + 0.3576 * G + 0.1805 * B
        let Y = 0.2126 * R + 0.7152 * G + 0.0722 * B
        let Z = 0.0193 * R + 0.1192 * G + 0.9505 * B
        let sum = X + Y + Z
        guard sum > 0.002 else { return nil }
        return (X / sum, Y / sum)
    }

    /// The spectral locus (380–700 nm) for drawing the CIE horseshoe.
    public static let spectralLocus: [(Double, Double)] = [
        (0.1741, 0.0050), (0.1440, 0.0297), (0.1241, 0.0578), (0.0913, 0.1327), (0.0454, 0.2950),
        (0.0082, 0.5384), (0.0139, 0.7502), (0.0743, 0.8338), (0.1547, 0.8059), (0.2296, 0.7543),
        (0.3016, 0.6923), (0.3731, 0.6245), (0.4441, 0.5547), (0.5125, 0.4866), (0.5752, 0.4242),
        (0.6270, 0.3725), (0.6915, 0.3083), (0.7347, 0.2653)]

    static func cie(_ s: ScopeSample) -> CGImage? {
        let N = 256
        var count = [Float](repeating: 0, count: N * N)
        var col = [SIMD3<Float>](repeating: .zero, count: N * N)
        for i in stride(from: 0, to: s.pixels.count, by: 4) {
            let r = Double(s.pixels[i]) / 255, g = Double(s.pixels[i + 1]) / 255, b = Double(s.pixels[i + 2]) / 255
            guard let c = chromaticity(r: r, g: g, b: b) else { continue }
            // x 0…0.8 across, y 0…0.9 up.
            let px = Int(c.x / 0.8 * Double(N - 1)), py = Int((1 - c.y / 0.9) * Double(N - 1))
            guard px >= 0, px < N, py >= 0, py < N else { continue }
            count[py * N + px] += 1
            col[py * N + px] += SIMD3(Float(r), Float(g), Float(b))
        }
        let k: Float = Float(N * N) / Float(max(s.width * s.height, 1)) * 2
        return image(N, N) { idx in
            let n = count[idx]
            guard n > 0 else { return (0, 0, 0) }
            let a = min(1, 0.35 + sqrt(n * k))
            let c = col[idx] / n
            let m = max(c.x, c.y, c.z, 0.2)
            return (UInt8(c.x / m * 255 * a), UInt8(c.y / m * 255 * a), UInt8(c.z / m * 255 * a))
        }
    }

    // MARK: Helpers

    static func image(_ w: Int, _ h: Int, _ pixel: (Int) -> (UInt8, UInt8, UInt8)) -> CGImage? {
        var buf = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let p = pixel(i)
            buf[i * 4] = p.0; buf[i * 4 + 1] = p.1; buf[i * 4 + 2] = p.2; buf[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(buf) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

extension StudioColor {
    /// Auto balance (Resolve's "A" button): sets Lift and Gain so the darkest and brightest 0.5% reach black
    /// and white, and pushes the Gain wheel against any overall colour cast.
    public static func autoBalance(_ s: ScopeSample, into e: inout StudioEdit) {
        let h = s.histogram()
        let total = max(h[3].reduce(0, +), 1)
        func percentile(_ p: Double) -> Double {
            var acc = 0
            for (i, n) in h[3].enumerated() {
                acc += n
                if Double(acc) >= p * Double(total) { return Double(i) / 255 }
            }
            return 1
        }
        let black = percentile(0.005), white = max(percentile(0.995), black + 0.1)
        // Lift: v + l·0.25·(1 − v) = 0 at the black point. Gain: v·(1 + g·0.5) = 1 at the white point.
        let lift = black > 0.01 ? -black / (0.25 * (1 - black)) : 0
        let gain = (1 / white - 1) / 0.5
        e[Wheel.lift.levelKey] = min(max(lift * 100, -100), 100)
        e[Wheel.gain.levelKey] = min(max(gain * 100, -100), 100)

        // Grey world: the average colour should be neutral.
        var sum = SIMD3<Double>(0, 0, 0), n = 0.0
        for i in stride(from: 0, to: s.pixels.count, by: 4) {
            sum += SIMD3(Double(s.pixels[i]), Double(s.pixels[i + 1]), Double(s.pixels[i + 2])) / 255
            n += 1
        }
        guard n > 0 else { return }
        let mean = sum / n
        let cast = mean - SIMD3(repeating: (mean.x + mean.y + mean.z) / 3)
        // The Gain wheel's push is 0.3 × its position (see `wheels`); counter the cast with the opposite push.
        let push = -cast / 0.3 * 0.8
        var x = push.x, y = (push.y - push.z) / 3.0.squareRoot()
        let mag = hypot(x, y)
        if mag > 1 { x /= mag; y /= mag }
        e[Wheel.gain.xKey] = x
        e[Wheel.gain.yKey] = y
    }
}
