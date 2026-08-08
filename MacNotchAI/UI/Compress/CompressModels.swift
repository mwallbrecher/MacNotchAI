import Foundation
import AVFoundation
import CoreGraphics
import ImageIO

/// Shared model for the batch-compression sheets (images and videos).
///
/// Why this exists: `resizeImage` and `compressVideo` used to act on the session's PRIMARY
/// file only. Dropping five images and hitting "Compress" silently processed one of them.
/// These sheets make the file set explicit and selectable.
///
/// Settings are shared across the selection on purpose — someone compressing eight photos
/// wants one quality, not eight sliders. Only the output NAME is templated per file.

// MARK: - Candidate

/// One row in a compression sheet.
struct CompressCandidate: Identifiable, Equatable {
    let url: URL
    /// nil when this tool can handle the file; otherwise why it cannot (shown greyed out).
    let ineligibleReason: String?
    /// Pixel dimensions (images) or the video's natural size — nil if unreadable.
    let pixelSize: CGSize?
    let byteSize: Int64

    var id: URL { url }
    var isEligible: Bool { ineligibleReason == nil }
    var name: String { url.lastPathComponent }

    var dimensionText: String? {
        guard let s = pixelSize, s.width > 0 else { return nil }
        return "\(Int(s.width))×\(Int(s.height))"
    }
    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

// MARK: - Image options

struct ImageCompressOptions: Equatable {
    enum Format: String, CaseIterable, Identifiable {
        case jpeg, png, keep
        var id: String { rawValue }
        var label: String {
            switch self {
            case .jpeg: return "JPEG"
            case .png:  return "PNG"
            case .keep: return "Keep original"
            }
        }
        /// PNG is lossless, so the quality slider does nothing for it.
        var usesQuality: Bool { self == .jpeg }
        /// The transparency question, stated where the user decides — JPEG has no alpha,
        /// so a PNG logo silently gains a background. That surprise is worth one line.
        var losesTransparency: Bool { self == .jpeg }
    }

    var maxDimension: CGFloat?      // nil = original size
    var quality: CGFloat = 0.7
    var format: Format = .jpeg
    var nameTemplate: String = "{name}-compressed"

    static let sizeChoices: [(label: String, value: CGFloat?)] = [
        ("Original size", nil), ("2048 px", 2048), ("1024 px", 1024), ("512 px", 512),
    ]
}

// MARK: - Video options

struct VideoCompressOptions: Equatable {
    /// Explicit resolution choice. The old behaviour was AVAssetExportPreset1280x720
    /// HARD-CODED — a 4K clip was silently downscaled to 720p with no way to say otherwise.
    enum Quality: String, CaseIterable, Identifiable {
        case keepResolution, uhd4K, hd1080, hd720, medium
        var id: String { rawValue }

        var label: String {
            switch self {
            case .keepResolution: return "Keep resolution"
            case .uhd4K:          return "Up to 4K (2160p)"
            case .hd1080:         return "Up to 1080p"
            case .hd720:          return "Up to 720p"
            case .medium:         return "Small (medium quality)"
            }
        }
        var detail: String {
            switch self {
            case .keepResolution: return "Re-encodes at the original size"
            case .uhd4K:          return "Downscales only above 4K"
            case .hd1080:         return "Good default for sharing"
            case .hd720:          return "Smallest that still reads well"
            case .medium:         return "Device-chosen size, strongest saving"
            }
        }
        var preset: String {
            switch self {
            case .keepResolution: return AVAssetExportPresetHighestQuality
            case .uhd4K:          return AVAssetExportPreset3840x2160
            case .hd1080:         return AVAssetExportPreset1920x1080
            case .hd720:          return AVAssetExportPreset1280x720
            case .medium:         return AVAssetExportPresetMediumQuality
            }
        }
    }

    enum Container: String, CaseIterable, Identifiable {
        case mp4, mov
        var id: String { rawValue }
        var label: String { self == .mp4 ? "MP4" : "MOV" }
        var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
        var ext: String { rawValue }
    }

    var quality: Quality = .hd1080
    var container: Container = .mp4
    var nameTemplate: String = "{name}-compressed"
}

// MARK: - Candidate discovery

enum CompressScan {

    /// Images in the session, with a reason attached to everything else so the sheet can
    /// show the full drop and explain the exclusions instead of hiding files.
    static func imageCandidates(_ urls: [URL]) -> [CompressCandidate] {
        urls.map { url in
            let bytes = fileSize(url)
            if FileInspector.isDirectory(url) {
                return CompressCandidate(url: url, ineligibleReason: "Folder", pixelSize: nil, byteSize: bytes)
            }
            guard isImage(url) else {
                return CompressCandidate(url: url, ineligibleReason: reasonForNonImage(url),
                                         pixelSize: nil, byteSize: bytes)
            }
            return CompressCandidate(url: url, ineligibleReason: nil,
                                     pixelSize: imagePixelSize(url), byteSize: bytes)
        }
    }

    static func videoCandidates(_ urls: [URL]) -> [CompressCandidate] {
        urls.map { url in
            let bytes = fileSize(url)
            if FileInspector.isDirectory(url) {
                return CompressCandidate(url: url, ineligibleReason: "Folder", pixelSize: nil, byteSize: bytes)
            }
            guard isVideo(url) else {
                return CompressCandidate(url: url,
                                         ineligibleReason: isImage(url) ? "Image — use Compress images" : "Not a video",
                                         pixelSize: nil, byteSize: bytes)
            }
            return CompressCandidate(url: url, ineligibleReason: nil, pixelSize: nil, byteSize: bytes)
        }
    }

    private static let imageExts: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp",
    ]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm"]

    static func isImage(_ url: URL) -> Bool { imageExts.contains(url.pathExtension.lowercased()) }
    static func isVideo(_ url: URL) -> Bool { videoExts.contains(url.pathExtension.lowercased()) }

    private static func reasonForNonImage(_ url: URL) -> String {
        isVideo(url) ? "Video — use Compress videos" : "Not an image"
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    /// Reads only the header — no full decode, so a sheet with 20 photos still opens instantly.
    static func imagePixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat
        else { return nil }
        return CGSize(width: w, height: h)
    }
}

// MARK: - Size estimation
//
// The estimate is the whole reason to open this sheet: "8.2 MB → ~1.1 MB" answers the
// question without a trial run. It is explicitly approximate and labelled "~" in the UI.

enum CompressEstimate {

    /// Rough output size for an image, from pixel count × bits-per-pixel heuristics.
    /// Deliberately simple: encoders vary, and a wrong-by-30% estimate still tells the
    /// user what they need to know (order of magnitude).
    static func image(_ c: CompressCandidate, _ opts: ImageCompressOptions) -> Int64? {
        guard let size = c.pixelSize, size.width > 0, size.height > 0 else { return nil }

        var w = size.width, h = size.height
        if let maxDim = opts.maxDimension, max(w, h) > maxDim {
            let scale = maxDim / max(w, h)
            w *= scale; h *= scale
        }
        let pixels = w * h

        let format: ImageCompressOptions.Format =
            opts.format == .keep ? (c.url.pathExtension.lowercased() == "png" ? .png : .jpeg)
                                 : opts.format
        switch format {
        case .png, .keep:
            // Lossless: strongly content-dependent. ~2 bits/px is a fair middle for photos
            // and generous for flat graphics.
            return Int64(pixels * 0.25)
        case .jpeg:
            // JPEG bits-per-pixel rises steeply with quality; these anchors are empirical.
            let bpp: CGFloat
            switch opts.quality {
            case ..<0.4:  bpp = 0.15
            case ..<0.6:  bpp = 0.25
            case ..<0.75: bpp = 0.40
            case ..<0.9:  bpp = 0.65
            default:      bpp = 1.20
            }
            return max(Int64(pixels * bpp / 8), 4096)
        }
    }

    static func text(for bytes: Int64?) -> String {
        guard let bytes else { return "—" }
        return "~" + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Applies the `{name}` template. Extension is added by the caller.
    static func outputName(template: String, original: URL) -> String {
        let stem = original.deletingPathExtension().lastPathComponent
        let applied = template.replacingOccurrences(of: "{name}", with: stem)
        return applied.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stem : applied
    }
}
