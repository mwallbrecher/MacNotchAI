import AppKit
import QuickLookThumbnailing

/// Resolves the *actual* icon for a file — a real Quick Look content thumbnail
/// (the image itself, a PDF's first page, a video poster frame, …) rather than the
/// generic kind/placeholder icon `NSWorkspace.icon(forFile:)` returns for most
/// document types. This matches what Finder shows in icon view.
enum FileThumbnail {

    /// Small process-local cache: 8 MiB is enough for dozens of Retina thumbnails at
    /// the sizes Dragaway actually displays, while `NSCache` can evict sooner under
    /// memory pressure. Identical requests share one Quick Look generation.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 96
        return cache
    }()
    private static var inFlight: [String: [(NSImage) -> Void]] = [:]

    private struct RenderSpec {
        let pixelSide: Int
        let displayScale: CGFloat

        var pointSide: CGFloat { CGFloat(pixelSide) / displayScale }
    }

    private struct BoundedImage {
        let image: NSImage
        let memoryCost: Int
    }

    /// Load the best image for `url` at `size` points.
    ///
    /// `onImage` is invoked on the main actor, possibly **twice**:
    ///   1. immediately with the Finder type icon (so the pill is never empty), then
    ///   2. with the high-fidelity Quick Look thumbnail once it's generated.
    ///
    /// QuickLook caches internally, so re-requesting the same file is cheap. When a
    /// file has no content preview (plain folder, unknown type) step 2 simply returns
    /// the same icon, so there's no regression versus the old behaviour.
    @MainActor
    static func load(for url: URL, size: CGFloat, onImage: @escaping (NSImage) -> Void) {
        let spec = renderSpec(for: size)
        let key = "\(url.standardizedFileURL.path)#\(spec.pixelSide)"
        let cacheKey = key as NSString

        if let cached = cache.object(forKey: cacheKey) {
            onImage(cached)
            return
        }

        // Contextual source icons are an intentional pill presentation. Do not let a
        // later Quick Look document thumbnail overwrite the Safari / Mail identity.
        if let contextual = FilePresentation.contextualIcon(for: url) {
            let bounded = boundedImage(from: contextual, spec: spec)
            cache.setObject(bounded.image, forKey: cacheKey, cost: bounded.memoryCost)
            onImage(bounded.image)
            return
        }

        // 1 — instant fallback so the slot is filled while QuickLook works.
        let fallback = boundedImage(
            from: NSWorkspace.shared.icon(forFile: url.path),
            spec: spec
        )
        onImage(fallback.image)

        if inFlight[key] != nil {
            inFlight[key]?.append(onImage)
            return
        }
        inFlight[key] = [onImage]

        // 2 — real thumbnail. Requests are quantized to 96 / 192 / 256 physical
        // pixels, which keeps fan + list requests reusable and prevents oversized
        // source artwork (including 4K images) from being retained by the UI.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: spec.pointSide, height: spec.pointSide),
            scale: spec.displayScale,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            Task { @MainActor in
                let callbacks = inFlight.removeValue(forKey: key) ?? []
                guard let rep else {
                    cache.setObject(
                        fallback.image,
                        forKey: key as NSString,
                        cost: fallback.memoryCost
                    )
                    return
                }

                let bounded = boundedImage(from: rep.cgImage, spec: spec)
                cache.setObject(
                    bounded.image,
                    forKey: key as NSString,
                    cost: bounded.memoryCost
                )
                callbacks.forEach { $0(bounded.image) }
            }
        }
    }

    @MainActor
    private static func renderSpec(for requestedPointSide: CGFloat) -> RenderSpec {
        let displayScale = min(2, max(1, NSScreen.main?.backingScaleFactor ?? 2))
        let requestedPixels = Int(ceil(max(1, requestedPointSide) * displayScale))
        let pixelSide: Int
        if requestedPixels <= 96 {
            pixelSide = 96
        } else if requestedPixels <= 192 {
            pixelSide = 192
        } else {
            pixelSide = 256
        }
        return RenderSpec(pixelSide: pixelSide, displayScale: displayScale)
    }

    @MainActor
    private static func boundedImage(from image: NSImage, spec: RenderSpec) -> BoundedImage {
        var proposedRect = NSRect(
            origin: .zero,
            size: NSSize(width: spec.pointSide, height: spec.pointSide)
        )
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return BoundedImage(
                image: image,
                memoryCost: spec.pixelSide * spec.pixelSide * 4
            )
        }
        return boundedImage(from: cgImage, spec: spec)
    }

    @MainActor
    private static func boundedImage(from source: CGImage, spec: RenderSpec) -> BoundedImage {
        let sourceWidth = max(1, source.width)
        let sourceHeight = max(1, source.height)
        let ratio = min(
            1,
            CGFloat(spec.pixelSide) / CGFloat(max(sourceWidth, sourceHeight))
        )
        let width = max(1, Int((CGFloat(sourceWidth) * ratio).rounded()))
        let height = max(1, Int((CGFloat(sourceHeight) * ratio).rounded()))

        let rendered: CGImage
        if width == sourceWidth, height == sourceHeight {
            rendered = source
        } else if let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            rendered = context.makeImage() ?? source
        } else {
            rendered = source
        }

        let pointSize = NSSize(
            width: CGFloat(rendered.width) / spec.displayScale,
            height: CGFloat(rendered.height) / spec.displayScale
        )
        return BoundedImage(
            image: NSImage(cgImage: rendered, size: pointSize),
            memoryCost: rendered.bytesPerRow * rendered.height
        )
    }
}
