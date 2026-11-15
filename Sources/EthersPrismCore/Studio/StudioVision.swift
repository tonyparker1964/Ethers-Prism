import Foundation
import CoreImage
import Vision

/// Apple Vision on the Mac (no network): the subject's mask for Background Defocus / Depth, and where the
/// interesting part of a picture is for Smart Reframe.
public enum StudioVision {
    /// A soft white-on-black mask of the foreground subject(s), the same size as `image`; nil when Vision finds none.
    public static func subjectMask(for image: CIImage) -> CIImage? {
        guard let cg = try? StudioRenderer.cgImage(image) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
            guard let obs = request.results?.first, !obs.allInstances.isEmpty else { return nil }
            let buffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            let mask = CIImage(cvPixelBuffer: buffer)
            let sx = image.extent.width / mask.extent.width, sy = image.extent.height / mask.extent.height
            return mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                .applyingGaussianBlur(sigma: 2).cropped(to: image.extent)
        } catch {
            return nil
        }
    }

    /// The part of the picture people look at first, in unit coordinates with the origin top-left.
    public static func focus(for image: CIImage) -> UnitRect? {
        guard let cg = try? StudioRenderer.cgImage(image) else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNGenerateAttentionBasedSaliencyImageRequest()
        guard (try? handler.perform([request])) != nil,
              let objects = request.results?.first?.salientObjects, !objects.isEmpty else { return nil }
        var box = objects[0].boundingBox
        for o in objects.dropFirst() { box = box.union(o.boundingBox) }
        // Vision's origin is bottom-left.
        return UnitRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
    }

    /// A centre-weighted stand-in for the subject when Vision finds none (bright centre, dark edges).
    public static func centreMask(for extent: CGRect) -> CIImage {
        let r = min(extent.width, extent.height)
        return CIFilter(name: "CIRadialGradient", parameters: [
            kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
            "inputRadius0": r * 0.22, "inputRadius1": r * 0.62,
            "inputColor0": CIColor.white, "inputColor1": CIColor.black])!.outputImage!.cropped(to: extent)
    }
}

/// Smart Reframe: the largest crop of a given shape that keeps the subject in frame.
public enum StudioReframe: String, CaseIterable, Identifiable, Sendable {
    case original, vertical, square, portrait, wide
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .original: return "Original"
        case .vertical: return "9:16"
        case .square: return "1:1"
        case .portrait: return "4:5"
        case .wide: return "16:9"
        }
    }
    /// Width ÷ height.
    public var aspect: Double? {
        switch self {
        case .original: return nil
        case .vertical: return 9.0 / 16
        case .square: return 1
        case .portrait: return 4.0 / 5
        case .wide: return 16.0 / 9
        }
    }

    /// The crop (unit coordinates of a `size` picture) for `aspect`, centred on `focus` (or the middle).
    public static func crop(size: CGSize, aspect: Double, focus: UnitRect?) -> UnitRect {
        let w = Double(size.width), h = Double(size.height)
        guard w > 0, h > 0 else { return .full }
        var cw = w, ch = w / aspect
        if ch > h { ch = h; cw = h * aspect }
        let f = focus ?? UnitRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        // Centre on the subject, a little above its middle for tall crops (heads stay in frame).
        let cx = (f.x + f.width / 2) * w
        let cy = (f.y + f.height * (aspect < 1 ? 0.4 : 0.5)) * h
        let x = min(max(cx - cw / 2, 0), w - cw)
        let y = min(max(cy - ch / 2, 0), h - ch)
        return UnitRect(x: x / w, y: y / h, width: cw / w, height: ch / h)
    }
}
