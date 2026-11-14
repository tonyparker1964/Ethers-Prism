import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Output size for export or enhancement.
public enum StudioSize: Hashable, Sendable {
    case original
    /// 2× or 4× (or any factor).
    case scale(Double)
    /// Exactly 3840×2160: scaled to fill, then centred.
    case uhd4K
    /// Long edge to 3840, keeping the shape (Enhance to 4K).
    case longEdge4K
    /// A width in pixels; the height follows the picture's shape.
    case width(Int)

    public var label: String {
        switch self {
        case .original: return "Original resolution"
        case .scale(let f): return "\(Int(f))× upscale"
        case .uhd4K: return "4K UHD 3840×2160"
        case .longEdge4K: return "4K long edge (3840)"
        case .width(let w): return "Custom width \(w) px"
        }
    }
}

public enum StudioFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, tiff, webp, heic
    public var id: String { rawValue }
    public var label: String { rawValue == "jpeg" ? "JPEG" : rawValue.uppercased() }
    public var type: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .tiff: return .tiff
        case .webp: return .webP
        case .heic: return .heic
        }
    }
    public var ext: String { type.preferredFilenameExtension ?? rawValue }
    public var hasQuality: Bool { self == .jpeg || self == .webp || self == .heic }
    public var keepsTransparency: Bool { self == .png || self == .tiff || self == .webp || self == .heic }

    /// The formats this Mac can write (WebP depends on the macOS version).
    public static var writable: [StudioFormat] {
        let ids = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return allCases.filter { ids.contains($0.type.identifier) }
    }
}

public enum StudioError: LocalizedError {
    case unreadable(String)
    case renderFailed
    case writeFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unreadable(let n): return "Couldn't read \(n) as a picture."
        case .renderFailed: return "Couldn't render the picture."
        case .writeFailed(let n): return "Couldn't write \(n)."
        case .cancelled: return "Cancelled."
        }
    }
}

/// The Studio's image processing: Core Image filters on the Mac's GPU (Metal), no network.
/// Every slider maps to real filters here.
public enum StudioRenderer {
    /// Shared GPU context (Core Image uses Metal on Apple silicon).
    public static let context = CIContext(options: [.cacheIntermediates: false,
                                                    .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func load(_ url: URL) throws -> CIImage {
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        return moveToOrigin(img)
    }

    /// A smaller copy for the live preview, and the factor it was shrunk by.
    public static func preview(of image: CIImage, maxPixels: CGFloat) -> (image: CIImage, scale: Double) {
        let longEdge = max(image.extent.width, image.extent.height)
        guard longEdge > maxPixels else { return (image, 1) }
        let s = maxPixels / longEdge
        return (lanczos(image, s), Double(s))
    }

    // MARK: - Geometry

    /// Rotation by quarter turns, then the crop.
    public static func geometry(_ image: CIImage, _ edit: StudioEdit) -> CIImage {
        var img = image
        switch ((edit.quarterTurns % 4) + 4) % 4 {
        case 1: img = img.oriented(.right)
        case 2: img = img.oriented(.down)
        case 3: img = img.oriented(.left)
        default: break
        }
        img = moveToOrigin(img)
        if let c = edit.crop?.clamped, c != .full {
            let w = img.extent.width, h = img.extent.height
            let rect = CGRect(x: c.x * w, y: (1 - c.y - c.height) * h, width: c.width * w, height: c.height * h).integral
            img = moveToOrigin(img.cropped(to: rect.intersection(img.extent)))
        }
        return img
    }

    // MARK: - Adjust and Realism

    /// Colour, tone and realism. `scale` is how much smaller than full size the image is (preview), so
    /// detail filters keep the same look at any size.
    public static func apply(_ image: CIImage, _ edit: StudioEdit, scale: Double = 1) -> CIImage {
        let extent = image.extent
        var img = image.clampedToExtent()
        let v = { (id: String) -> Double in edit[id] }
        let pct = { (id: String) -> Double in edit[id] / 100 }
        let r = { (px: Double) -> Double in max(px * scale, 0.5) }

        // Noise first, so later sharpening doesn't amplify it. Skin Detail Preservation keeps fine texture.
        if v("noiseReduction") > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": pct("noiseReduction") * 0.05,
                "inputSharpness": 0.2 + pct("skinDetail") * 1.8])
        }
        if v("exposure") != 0 {
            img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v("exposure")])
        }

        // Highlights / shadows and their recovery.
        let highlightAmount = min(max(1 - pct("highlightRecovery") * 0.7 - max(-pct("highlights"), 0) * 0.6, 0), 1)
        let shadowAmount = min(max(pct("shadows") * 0.7 + pct("shadowRecovery") * 0.8, -1), 1)
        if highlightAmount < 1 || shadowAmount != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": highlightAmount, "inputShadowAmount": shadowAmount, kCIInputRadiusKey: r(8)])
        }
        if v("highlights") > 0 {
            let lift = min(0.75 + pct("highlights") * 0.15, 0.97)
            img = img.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25),
                "inputPoint2": CIVector(x: 0.5, y: 0.5), "inputPoint3": CIVector(x: 0.75, y: lift),
                "inputPoint4": CIVector(x: 1, y: 1)])
        }

        let photo = pct("photorealism")
        let brightness = pct("brightness") * 0.25
        let contrast = 1 + pct("contrast") * 0.5 + photo * 0.06
        let saturation = 1 + pct("saturation")
        if brightness != 0 || contrast != 1 || saturation != 1 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
        }
        if v("temperature") != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + v("temperature") * 30, y: 0)])
        }
        let vibrance = pct("vibrance") + photo * 0.12
        if vibrance != 0 {
            img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance])
        }

        // Detail at several sizes: local contrast (large), surface (medium), photorealism, microtexture (fine).
        func unsharp(_ radius: Double, _ intensity: Double) {
            guard intensity > 0 else { return }
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: r(radius), kCIInputIntensityKey: intensity])
        }
        unsharp(25, pct("localContrast") * 0.6 + pct("depth") * 0.2)
        unsharp(4, pct("surfaceDetail") * 0.5)
        unsharp(2.5, photo * 0.35)
        unsharp(1, pct("microtexture") * 0.9)
        if v("noiseReduction") == 0 { unsharp(0.8, pct("skinDetail") * 0.25) }

        if v("sharpness") > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: pct("sharpness") * 1.2, kCIInputRadiusKey: r(1.5)])
        }
        if v("edgeRefinement") > 0 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: pct("edgeRefinement") * 0.8, kCIInputRadiusKey: r(0.8)])
        }

        img = img.cropped(to: extent)
        // Depth: a soft falloff toward the edges draws the eye to the subject.
        if v("depth") > 0 {
            let diag = hypot(extent.width, extent.height)
            img = img.applyingFilter("CIVignetteEffect", parameters: [
                kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                kCIInputRadiusKey: diag * 0.42, kCIInputIntensityKey: pct("depth") * 0.7, "inputFalloff": 0.6])
                .cropped(to: extent)
        }
        return img
    }

    // MARK: - Enhance (upscaling)

    /// Makes the picture `factor` times larger: noise reduction, Lanczos resampling, detail recovery and edge refinement.
    public static func upscale(_ image: CIImage, factor: Double, _ edit: StudioEdit) -> CIImage {
        let extent = image.extent
        var img = image.clampedToExtent()
        let texture = edit["enhanceTexture"] / 100
        if edit["enhanceNoise"] > 0 {
            img = img.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": edit["enhanceNoise"] / 100 * 0.04, "inputSharpness": 0.3 + texture * 1.7])
        }
        img = img.cropped(to: extent)
        img = lanczos(img, factor).clampedToExtent()
        let big = CGRect(x: 0, y: 0, width: (extent.width * factor).rounded(), height: (extent.height * factor).rounded())
        if factor > 1 {
            let detail = edit["enhanceDetail"] / 100
            if detail > 0 {
                img = img.applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 1.2 * factor, kCIInputIntensityKey: detail * 0.7])
            }
            if texture > 0 {
                img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.8, kCIInputIntensityKey: texture * 0.3])
            }
            if edit["enhanceEdges"] > 0 {
                img = img.applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: edit["enhanceEdges"] / 100 * 0.6, kCIInputRadiusKey: 1.0])
            }
        }
        return img.cropped(to: big)
    }

    /// The finished picture at a size: geometry → adjust/realism → enhance.
    public static func render(_ source: CIImage, _ edit: StudioEdit, size: StudioSize) -> CIImage {
        let base = apply(geometry(source, edit), edit)
        let w = base.extent.width, h = base.extent.height
        switch size {
        case .original:
            return base
        case .scale(let f):
            return upscale(base, factor: f, edit)
        case .longEdge4K:
            let f = 3840 / max(w, h)
            return f > 1 ? upscale(base, factor: f, edit) : moveToOrigin(lanczos(base, f))
        case .width(let px):
            let f = Double(px) / w
            return f > 1 ? upscale(base, factor: f, edit) : moveToOrigin(lanczos(base, f))
        case .uhd4K:
            let f = max(3840 / w, 2160 / h)
            let big = f > 1 ? upscale(base, factor: f, edit) : moveToOrigin(lanczos(base, f))
            let x = ((big.extent.width - 3840) / 2).rounded(.down), y = ((big.extent.height - 2160) / 2).rounded(.down)
            return moveToOrigin(big.cropped(to: CGRect(x: x, y: y, width: 3840, height: 2160)))
        }
    }

    /// Output pixel size for a size choice without rendering.
    public static func pixelSize(source: CGSize, edit: StudioEdit, size: StudioSize) -> CGSize {
        var w = source.width, h = source.height
        if ((edit.quarterTurns % 4) + 4) % 2 == 1 { swap(&w, &h) }
        if let c = edit.crop?.clamped { w = (w * c.width).rounded(); h = (h * c.height).rounded() }
        switch size {
        case .original: return CGSize(width: w, height: h)
        case .scale(let f): return CGSize(width: (w * f).rounded(), height: (h * f).rounded())
        case .uhd4K: return CGSize(width: 3840, height: 2160)
        case .longEdge4K:
            let f = 3840 / max(w, h); return CGSize(width: (w * f).rounded(), height: (h * f).rounded())
        case .width(let px):
            let f = Double(px) / w; return CGSize(width: Double(px), height: (h * f).rounded())
        }
    }

    // MARK: - Output

    public static func cgImage(_ image: CIImage) throws -> CGImage {
        let rect = image.extent.integral
        guard let cg = context.createCGImage(image, from: rect, format: .RGBA8, colorSpace: sRGB) else { throw StudioError.renderFailed }
        return cg
    }

    /// Writes the picture. JPEG (and any format when `transparency` is off) is flattened onto white.
    public static func write(_ image: CIImage, to url: URL, format: StudioFormat, quality: Double = 0.92,
                             transparency: Bool = true) throws {
        var img = image
        if !(transparency && format.keepsTransparency) {
            img = img.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: img.extent))
        }
        let cg = try cgImage(img)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.type.identifier as CFString, 1, nil) else {
            throw StudioError.writeFailed(url.lastPathComponent)
        }
        var props: [CFString: Any] = [:]
        if format.hasQuality { props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0.05), 1) }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw StudioError.writeFailed(url.lastPathComponent) }
    }

    // MARK: - Helpers

    static func lanczos(_ image: CIImage, _ scale: Double) -> CIImage {
        image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
    }

    static func moveToOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.origin != .zero, e.origin.x.isFinite else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }
}
