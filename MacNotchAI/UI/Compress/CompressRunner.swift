import Foundation
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Executes a batch compression and reports per-file progress to the sheet.
///
/// Every file is independent: one failure does not abort the run, it is recorded and the
/// batch continues. A partial success is far more useful than an all-or-nothing abort when
/// someone selected twelve photos and one of them is corrupt.
@MainActor
final class CompressRunner: ObservableObject {

    struct Outcome: Identifiable {
        let url: URL
        let output: URL?
        let error: String?
        var id: URL { url }
        var ok: Bool { output != nil }
    }

    @Published private(set) var running = false
    @Published private(set) var doneCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var currentName = ""
    @Published private(set) var outcomes: [Outcome] = []

    var savedBytes: Int64 {
        outcomes.reduce(0) { acc, o in
            guard let out = o.output else { return acc }
            let before = (try? o.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let after  = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(max(0, before - after))
        }
    }

    // MARK: Images

    func runImages(_ urls: [URL], options: ImageCompressOptions) async {
        begin(urls)
        for url in urls {
            currentName = url.lastPathComponent
            do {
                let out = try Self.compressImage(url, options: options)
                outcomes.append(Outcome(url: url, output: out, error: nil))
            } catch {
                outcomes.append(Outcome(url: url, output: nil, error: error.localizedDescription))
            }
            doneCount += 1
        }
        running = false
    }

    // MARK: Videos

    func runVideos(_ urls: [URL], options: VideoCompressOptions) async {
        begin(urls)
        for url in urls {
            currentName = url.lastPathComponent
            do {
                let out = try await Self.compressVideo(url, options: options)
                outcomes.append(Outcome(url: url, output: out, error: nil))
            } catch {
                outcomes.append(Outcome(url: url, output: nil, error: error.localizedDescription))
            }
            doneCount += 1
        }
        running = false
    }

    private func begin(_ urls: [URL]) {
        running = true; doneCount = 0; totalCount = urls.count
        outcomes = []; currentName = ""
    }

    // MARK: Image encoding

    nonisolated static func compressImage(_ url: URL, options: ImageCompressOptions) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FileToolError.imageUnreadable(url)
        }

        // Resolve "keep original" against the actual file, so a PNG stays a PNG (and keeps
        // its alpha) while everything else becomes JPEG.
        var format = options.format
        if format == .keep {
            format = url.pathExtension.lowercased() == "png" ? .png : .jpeg
        }

        let image: CGImage
        if let maxDim = options.maxDimension {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceThumbnailMaxPixelSize:          Int(maxDim),
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw FileToolError.imageUnreadable(url)
            }
            image = thumb
        } else {
            // Still go through the thumbnail path so EXIF orientation is applied —
            // otherwise a rotated phone photo comes out sideways. The cap is far above any
            // realistic photo, so "original size" stays original.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform:   true,
                kCGImageSourceThumbnailMaxPixelSize:          30000,
            ]
            guard let full = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
                throw FileToolError.imageUnreadable(url)
            }
            image = full
        }

        let ext = format == .png ? "png" : "jpg"
        let type: UTType = format == .png ? .png : .jpeg
        let dir = url.deletingLastPathComponent()
        let name = CompressEstimate.outputName(template: options.nameTemplate, original: url)
        let target = FileTools.uniqueDestination(dir.appendingPathComponent("\(name).\(ext)"))

        guard let dest = CGImageDestinationCreateWithURL(target as CFURL,
                                                         type.identifier as CFString, 1, nil) else {
            throw FileToolError.writeFailed("could not create the image encoder")
        }
        // PNG is lossless — passing a quality would be meaningless, so it is omitted.
        let props: [CFString: Any] = format == .png ? [:]
            : [kCGImageDestinationLossyCompressionQuality: options.quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw FileToolError.writeFailed("the image could not be written")
        }
        return target
    }

    // MARK: Video export

    nonisolated static func compressVideo(_ url: URL, options: VideoCompressOptions) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let dir = url.deletingLastPathComponent()
        let name = CompressEstimate.outputName(template: options.nameTemplate, original: url)
        let target = FileTools.uniqueDestination(
            dir.appendingPathComponent("\(name).\(options.container.ext)"))

        // A preset the asset cannot satisfy yields a nil session; fall back to the highest
        // quality the device does offer rather than failing the file outright.
        let available = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = available.contains(options.quality.preset)
            ? options.quality.preset
            : (available.contains(AVAssetExportPresetHighestQuality)
               ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough)

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MediaToolError.unsupportedMedia(url)
        }
        session.outputURL = target
        session.outputFileType = options.container.fileType
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: target)
            throw MediaToolError.exportFailed(session.error?.localizedDescription ?? "export failed")
        }
        return target
    }
}
