import Foundation
import AVFoundation
import Combine
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Executes a batch compression and reports per-file progress to the sheet.
///
/// Ordinary file failures are independent: one corrupt item does not abort the rest of the batch.
/// User cancellation is deliberately transactional, however: everything produced by that run is
/// removed so Cancel never leaves a partial or misleading batch behind.
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
    @Published private(set) var currentFraction = 0.0
    @Published private(set) var isCancelling = false
    @Published private(set) var wasCancelled = false
    @Published private(set) var cleanupFailures: [URL] = []

    private var cancelRequested = false
    private var activeExportSession: AVAssetExportSession?
    /// Hidden, same-volume work directories contain every partial/intermediate file emitted by a
    /// producer. They are removed after each file or on cancellation.
    private var runWorkDirectories: [URL] = []
    /// Only final files that this exact run successfully moved into place are recorded here.
    /// Cancellation may therefore remove them without risking pre-existing user data.
    private var runFinalOutputs: [URL] = []

    var overallProgress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1, (Double(doneCount) + currentFraction) / Double(totalCount))
    }

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
            guard !cancelRequested else { break }
            currentName = url.lastPathComponent
            currentFraction = 0
            do {
                let format = Self.resolvedImageFormat(for: url, requested: options.format)
                let finalURL = imageOutputURL(for: url, options: options, format: format)
                let workDirectory = try makeWorkDirectory(appropriateFor: finalURL)
                let workURL = workDirectory.appendingPathComponent(finalURL.lastPathComponent)

                try await Task.detached(priority: .userInitiated) {
                    try Self.compressImage(url, to: workURL, options: options, format: format)
                }.value

                guard !cancelRequested else { break }
                try moveCompletedOutput(from: workURL, to: finalURL)
                removeWorkDirectory(workDirectory)
                outcomes.append(Outcome(url: url, output: finalURL, error: nil))
            } catch {
                if cancelRequested || error is CancellationError { break }
                outcomes.append(Outcome(url: url, output: nil, error: error.localizedDescription))
            }
            doneCount += 1
        }
        await finishRun()
    }

    // MARK: Videos

    func runVideos(_ urls: [URL], options: VideoCompressOptions) async {
        begin(urls)
        for url in urls {
            guard !cancelRequested else { break }
            currentName = url.lastPathComponent
            currentFraction = 0
            do {
                let finalURL = videoOutputURL(for: url, options: options)
                let workDirectory = try makeWorkDirectory(appropriateFor: finalURL)
                let workURL = workDirectory.appendingPathComponent(finalURL.lastPathComponent)
                try await exportVideo(url, to: workURL, options: options)

                guard !cancelRequested else { break }
                try moveCompletedOutput(from: workURL, to: finalURL)
                removeWorkDirectory(workDirectory)
                outcomes.append(Outcome(url: url, output: finalURL, error: nil))
            } catch {
                if cancelRequested || error is CancellationError { break }
                outcomes.append(Outcome(url: url, output: nil, error: error.localizedDescription))
            }
            doneCount += 1
        }
        await finishRun()
    }

    private func begin(_ urls: [URL]) {
        running = true; doneCount = 0; totalCount = urls.count
        outcomes = []; currentName = ""; currentFraction = 0
        cancelRequested = false; isCancelling = false; wasCancelled = false
        cleanupFailures = []; runWorkDirectories = []; runFinalOutputs = []
        activeExportSession = nil
    }

    /// Requests cancellation without closing the progress UI. AVFoundation is asked to stop
    /// immediately; image encoding cannot be interrupted safely, so it finishes off-main and is
    /// discarded before the run reports cancellation.
    func cancel() {
        guard running, !cancelRequested else { return }
        cancelRequested = true
        isCancelling = true
        activeExportSession?.cancelExport()
    }

    private func finishRun() async {
        activeExportSession = nil
        currentFraction = 0

        if !cancelRequested {
            // Successful/failed producers clean their own work directories. This final sweep is
            // defensive and never includes anything outside Dragaway's per-run temp folders.
            _ = await Self.removeRunArtifacts(workDirectories: runWorkDirectories, finalOutputs: [])
        }

        // Re-check after the awaited normal sweep: the user can still press Cancel during that
        // narrow interval, and a late cancellation must remove already-completed outputs too.
        if cancelRequested {
            cleanupFailures = await Self.removeRunArtifacts(
                workDirectories: runWorkDirectories,
                finalOutputs: runFinalOutputs)
            outcomes = []
            wasCancelled = true
        }

        runWorkDirectories = []
        runFinalOutputs = []
        running = false
        isCancelling = false
    }

    private nonisolated static func removeRunArtifacts(
        workDirectories: [URL],
        finalOutputs: [URL]
    ) async -> [URL] {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            var failures: [URL] = []
            for url in workDirectories + finalOutputs {
                guard fm.fileExists(atPath: url.path) else { continue }
                do { try fm.removeItem(at: url) }
                catch { failures.append(url) }
            }
            return failures
        }.value
    }

    private func makeWorkDirectory(appropriateFor finalURL: URL) throws -> URL {
        // Apple's item-replacement directory is hidden from Finder and lives on the same volume
        // as the destination. That keeps AVFoundation fragments out of the user's folder while
        // preserving an atomic/cheap final move even for external drives.
        let url = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: finalURL.deletingLastPathComponent(),
            create: true)
        runWorkDirectories.append(url)
        return url
    }

    private func removeWorkDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func moveCompletedOutput(from workURL: URL, to finalURL: URL) throws {
        try FileManager.default.moveItem(at: workURL, to: finalURL)
        runFinalOutputs.append(finalURL)
    }

    private func imageOutputURL(
        for url: URL,
        options: ImageCompressOptions,
        format: ImageCompressOptions.Format
    ) -> URL {
        let ext = format == .png ? "png" : "jpg"
        let name = CompressEstimate.outputName(template: options.nameTemplate, original: url)
        return FileTools.uniqueDestination(
            url.deletingLastPathComponent().appendingPathComponent("\(name).\(ext)"))
    }

    private func videoOutputURL(for url: URL, options: VideoCompressOptions) -> URL {
        let name = CompressEstimate.outputName(template: options.nameTemplate, original: url)
        return FileTools.uniqueDestination(
            url.deletingLastPathComponent()
                .appendingPathComponent("\(name).\(options.container.ext)"))
    }

    // MARK: Image encoding

    nonisolated static func resolvedImageFormat(
        for url: URL,
        requested: ImageCompressOptions.Format
    ) -> ImageCompressOptions.Format {
        guard requested == .keep else { return requested }
        return url.pathExtension.lowercased() == "png" ? .png : .jpeg
    }

    nonisolated static func compressImage(
        _ url: URL,
        to target: URL,
        options: ImageCompressOptions,
        format: ImageCompressOptions.Format
    ) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FileToolError.imageUnreadable(url)
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

        let type: UTType = format == .png ? .png : .jpeg

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
    }

    // MARK: Video export

    private func exportVideo(
        _ url: URL,
        to target: URL,
        options: VideoCompressOptions
    ) async throws {
        let asset = AVURLAsset(url: url)

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
        activeExportSession = session

        let progressTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.currentFraction = Double(session.progress)
                switch session.status {
                case .completed, .failed, .cancelled:
                    return
                default:
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        progressTask.cancel()
        currentFraction = Double(session.progress)
        activeExportSession = nil

        if cancelRequested || session.status == .cancelled {
            throw CancellationError()
        }
        guard session.status == .completed else {
            throw MediaToolError.exportFailed(session.error?.localizedDescription ?? "export failed")
        }
    }
}
