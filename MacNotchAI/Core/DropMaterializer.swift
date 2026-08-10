import AppKit
import UniformTypeIdentifiers

/// "Drag anything": turns non-file drags — a text selection, a web link, an image
/// dragged straight out of a browser — into small local files, so the entire existing
/// file pipeline (chips, AI actions, utilities, session history, drag-out) just works.
///
/// Capture happens at `draggingEntered` (the drag pasteboard is fully open and fast
/// while the drag is in flight); the file is only WRITTEN at drop time. Files land in
/// Application Support/<bundle>/Drops. Retention is shared with imported snapshots: at most 50
/// entries / 512 MiB, removing only old files that no saved or live session still references.
@MainActor
enum DropMaterializer {

    /// Private materialisations are bounded by both count and bytes. Persisted/reopened session
    /// files are never silently deleted to satisfy the quota; a large incoming share is refused
    /// instead when only referenced files remain.
    static let maximumDropFiles = 50
    static let maximumDropBytes: Int64 = 512 * 1_024 * 1_024

    /// Main-actor lease held from quota preflight through atomic write and History commit. The
    /// reserved destination and its predictable private temp name stay protected from every normal
    /// Drops prune while detached file I/O yields the main actor.
    struct ShareImportReservation: Sendable, Equatable {
        let id: UUID
        let destinationAttempt: Int
        fileprivate let destinationFileName: String
        fileprivate let byteCount: Int64

        fileprivate var temporaryFileName: String {
            ".dragaway-share-\(id.uuidString).tmp"
        }
    }

    private static var shareImportReservations: [UUID: ShareImportReservation] = [:]

    /// External file promises write into Drops outside our actor. While any lease is active,
    /// retention may measure but must not delete unknown new paths. Once a callback identifies a
    /// path, a handoff ref-count protects it until the ViewModel owns it.
    struct PromisedFileDeliveryLease: Sendable, Hashable {
        fileprivate let id: UUID
    }

    private static var activePromisedFileDeliveries: Set<UUID> = []
    private static var promisedHandoffPathRefCounts: [String: Int] = [:]

    /// A non-file drag payload captured mid-drag.
    enum Payload {
        case text(String)
        case webURL(URL)
        case image(Data)          // PNG data

        var isImage: Bool {
            if case .image = self { return true }
            return false
        }

        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    private nonisolated static var jpegType: NSPasteboard.PasteboardType {
        NSPasteboard.PasteboardType("public.jpeg")
    }

    /// True when the drag pasteboard carries something we can materialize (used by the
    /// DragMonitor gate to wake the pill for non-file drags).
    nonisolated static func hasPayload(on pb: NSPasteboard) -> Bool {
        if declaresImage(on: pb) { return true }
        if let s = pb.string(forType: .string),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        if webURL(on: pb) != nil { return true }
        return false
    }

    /// Capture the best payload from the drag pasteboard. Preference order:
    /// image (the visual thing being dragged) → web link → plain text.
    nonisolated static func capture(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }

        let text = pb.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // A dragged link (URL flavour, or the text itself IS a bare link).
        if let url = webURL(on: pb) {
            // Prefer the text when the user dragged a real selection that merely
            // CONTAINS a link; prefer the URL when the text is just the link/title.
            if text.isEmpty || text == url.absoluteString || !text.contains(" ") {
                return .webURL(url)
            }
        }
        if !text.isEmpty { return .text(text) }
        return nil
    }

    /// Browser drags frequently expose several representations of the same visual
    /// object. The thing being dragged wins: bitmap bytes first, then its URL, then
    /// ordinary text. In particular, Google Images offers BOTH JPEG/TIFF bytes and an
    /// `imgres` page URL — treating URL as authoritative silently turned images into TXT.
    nonisolated static func preferredBrowserPayload(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }
        if let url = webURL(on: pb) { return .webURL(url) }
        return capture(from: pb)
    }

    /// The late-window fallback deliberately stays narrow: it may claim an image or
    /// HTTP(S) URL, but never broad text selections that should use AppKit normally.
    nonisolated static func browserFallbackPayload(from pb: NSPasteboard) -> Payload? {
        if let image = captureImage(from: pb) { return image }
        if let url = webURL(on: pb) { return .webURL(url) }
        return nil
    }

    /// True from declared flavours alone — safe for deciding whether a failed bitmap
    /// read should defer to an NSFilePromiseReceiver instead of degrading to the URL.
    nonisolated static func declaresImage(on pb: NSPasteboard) -> Bool {
        let types = Set((pb.types ?? []).map(\.rawValue))
        return types.contains(NSPasteboard.PasteboardType.png.rawValue)
            || types.contains(NSPasteboard.PasteboardType.tiff.rawValue)
            || types.contains(jpegType.rawValue)
    }

    /// Read browser bitmap flavours in compressed-first order and normalize to PNG so
    /// the existing image/vision pipeline receives one stable representation.
    private nonisolated static func captureImage(from pb: NSPasteboard) -> Payload? {
        if let png = pb.data(forType: .png) { return .image(png) }
        if let jpeg = pb.data(forType: jpegType),
           let rep = NSBitmapImageRep(data: jpeg),
           let png = rep.representation(using: .png, properties: [:]) { return .image(png) }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) { return .image(png) }
        return nil
    }

    /// Write the payload to the Drops folder; returns the file URL to session on.
    static func materialize(_ payload: Payload) -> URL? {
        let dir = dropsDir()
        let stamp = Self.stamp()
        do {
            switch payload {
            case .image(let png):
                let url = uniqueDropURL(
                    dir.appendingPathComponent("Dropped Image \(stamp).png")
                )
                try png.write(to: url)
                _ = prune(dir, preserving: [url])
                return url
            case .webURL(let link):
                let name = (link.host ?? "Link").replacingOccurrences(of: "www.", with: "")
                let url = uniqueDropURL(
                    dir.appendingPathComponent("\(sanitize(name)) \(stamp).txt")
                )
                try link.absoluteString.data(using: .utf8)?.write(to: url)
                FilePresentation.markAsWebDrop(url)
                _ = prune(dir, preserving: [url])
                // The drop stays instant. The file-scoped task upgrades this URL-only
                // placeholder in the background; a fast AI action awaits that exact
                // task at the shared content-builder choke point.
                WebDropPreparation.start(file: url, link: link)
                return url
            case .text(let text):
                let url = uniqueDropURL(
                    dir.appendingPathComponent("\(titleWords(text)) \(stamp).txt")
                )
                try text.data(using: .utf8)?.write(to: url)
                _ = prune(dir, preserving: [url])
                return url
            }
        } catch {
            return nil
        }
    }

    // MARK: - Internals

    /// Best HTTP(S) URL offered by a browser-style drag. Internal so the global
    /// drag fallback can cache the URL before a late-created AppKit destination
    /// has had a chance to enter the drag session.
    nonisolated static func webURL(on pb: NSPasteboard) -> URL? {
        // Non-file URL flavour (public.url) — readObjects without fileURLsOnly.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [:]) as? [URL],
           let first = urls.first(where: { $0.scheme == "http" || $0.scheme == "https" }) {
            return first
        }
        // Raw public.url string — Safari link/tab drags often vend ONLY this flavour,
        // which readObjects doesn't always surface.
        if let s = pb.string(forType: NSPasteboard.PasteboardType("public.url"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        // Safari's legacy WebURLsWithTitles plist: [[url, …], [title, …]].
        if let plist = pb.propertyList(
               forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")) as? [[String]],
           let s = plist.first?.first,
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        // Or the dragged text itself is a bare http(s) link.
        if let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.contains(" "), !s.contains("\n"),
           let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
            return u
        }
        return nil
    }

    /// Destination for received file PROMISES (Safari tabs, Photos, Mail) — the
    /// promising app writes the real file here on drop.
    static func dropsDirectory() -> URL { dropsDir() }

    /// Reserve count, bytes, final path, and temp path before detached import I/O begins. Selecting
    /// the collision suffix here lets retention protect a concrete destination throughout the await;
    /// an external writer racing that filename makes the exclusive rename fail safely.
    static func reserveShareImport(fileName: String, byteCount: Int) -> ShareImportReservation? {
        guard byteCount >= 0, Int64(byteCount) <= maximumDropBytes,
              let safeName = try? ShareImportPolicy.validatedFileName(fileName) else { return nil }

        let dir = dropsDir()
        let fm = FileManager.default
        let reservedNames = Set(shareImportReservations.values.map(\.destinationFileName))
        guard let allocation = (0..<ShareImportPolicy.maxCollisionAttempts).lazy.compactMap({ attempt in
            let name = ShareImportPolicy.destinationFileName(for: safeName, attempt: attempt)
            let url = dir.appendingPathComponent(name, isDirectory: false)
            return !reservedNames.contains(name) && !fm.fileExists(atPath: url.path)
                ? (attempt, name) : nil
        }).first else { return nil }

        let reservation = ShareImportReservation(
            id: UUID(), destinationAttempt: allocation.0,
            destinationFileName: allocation.1, byteCount: Int64(byteCount)
        )
        shareImportReservations[reservation.id] = reservation
        guard prune(dir) else {
            shareImportReservations.removeValue(forKey: reservation.id)
            return nil
        }
        return reservation
    }

    /// End an import lease only after the new History record exists (or after persistence failed).
    /// `preserving` is used on success as an additional same-pass guard while the lease is removed.
    static func releaseShareImport(_ reservation: ShareImportReservation,
                                   preserving: [URL] = []) {
        guard shareImportReservations[reservation.id] == reservation else { return }
        shareImportReservations.removeValue(forKey: reservation.id)
        _ = prune(dropsDir(), preserving: preserving)
    }

    static func beginPromisedFileDelivery() -> PromisedFileDeliveryLease {
        let lease = PromisedFileDeliveryLease(id: UUID())
        activePromisedFileDeliveries.insert(lease.id)
        return lease
    }

    /// Bridge the gap between an external writer finishing and the receiving URLs becoming live
    /// `sessionFileURLs` / `pendingDroppedURLs`. Calls are balanced per delivered batch.
    static func protectPromisedFilesForHandoff(_ urls: [URL]) {
        for path in Set(urls.map { $0.standardizedFileURL.path }) {
            promisedHandoffPathRefCounts[path, default: 0] += 1
        }
    }

    static func promisedFilesDidEnterSession(_ urls: [URL]) {
        var releasedAnyPath = false
        for path in Set(urls.map { $0.standardizedFileURL.path }) {
            guard let count = promisedHandoffPathRefCounts[path] else { continue }
            releasedAnyPath = true
            if count <= 1 {
                promisedHandoffPathRefCounts.removeValue(forKey: path)
            } else {
                promisedHandoffPathRefCounts[path] = count - 1
            }
        }
        if releasedAnyPath {
            _ = prune(dropsDir(), preserving: urls)
        }
    }

    static func finishPromisedFileDelivery(_ lease: PromisedFileDeliveryLease) {
        guard activePromisedFileDeliveries.remove(lease.id) != nil else { return }
        _ = prune(dropsDir())
    }

    /// Best-effort pass after an abandoned receiver eventually stops writing. Current, pending,
    /// saved, imported, and other promised paths remain protected by the normal retention rules.
    static func sweepRetention() {
        _ = prune(dropsDir())
    }

    /// Post-process a promised file: Safari tabs deliver a `.webloc` — unwrap it to
    /// the link and route through the normal web path (materialize + page fetch), so
    /// a tab drop behaves exactly like a URL drop. Anything else passes through.
    static func normalizeReceived(_ url: URL) -> URL {
        guard url.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let s = (plist as? [String: Any])?["URL"] as? String,
              let link = URL(string: s), link.scheme == "http" || link.scheme == "https",
              let materialized = materialize(.webURL(link))
        else { return url }
        try? FileManager.default.removeItem(at: url)   // keep only the enriched .txt
        return materialized
    }

    private static func dropsDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let bundle = Bundle.main.bundleIdentifier ?? "com.wallbrecher.MacNotchAI"
        let d = base.appendingPathComponent(bundle, isDirectory: true)
                    .appendingPathComponent("Drops", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// First few words of the text as a readable filename ("Quarterly results were…").
    private static func titleWords(_ text: String) -> String {
        let words = text.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        let head = words.prefix(4).joined(separator: " ")
        let cleaned = sanitize(String(head.prefix(32)))
        return cleaned.isEmpty ? "Dropped Text" : cleaned
    }

    private static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\t"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyMMdd-HHmmss"
        return f.string(from: Date())
    }

    /// A multi-item browser drag can materialize several payloads within the same
    /// timestamp second. Never let one placeholder overwrite another before its
    /// file-scoped web preparation has even started.
    private static func uniqueDropURL(_ candidate: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let directory = candidate.deletingLastPathComponent()
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let filename = ext.isEmpty
                ? "\(stem) \(suffix)"
                : "\(stem) \(suffix).\(ext)"
            let proposed = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: proposed.path) { return proposed }
            suffix += 1
        }
    }

    /// Delete oldest unreferenced entries until both quotas (plus any proposed incoming file) fit.
    /// Returning false means satisfying the quota would require deleting a saved/live session file.
    @discardableResult
    private static func prune(_ dir: URL,
                              preserving: [URL] = []) -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey,
                                          .isRegularFileKey]) else { return false }

        struct Entry {
            let url: URL
            let date: Date
            let bytes: Int64
        }
        var entries: [Entry] = []
        entries.reserveCapacity(files.count)
        for url in files {
            let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
            // Unknown regular-file sizes fail closed: retain a quota-sized weight unless the entry
            // can be safely removed. Directories count as entries but not as guessed file bytes.
            let bytes: Int64
            if values?.isRegularFile == true {
                bytes = Int64(values?.fileSize ?? Int(maximumDropBytes))
            } else {
                bytes = 0
            }
            entries.append(Entry(url: url,
                                 date: values?.contentModificationDate ?? .distantPast,
                                 bytes: max(0, bytes)))
        }

        var protected = Set(preserving.map { $0.standardizedFileURL.path })
        protected.formUnion(promisedHandoffPathRefCounts.keys)
        let entriesByPath = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.url.standardizedFileURL.path, $0)
        })
        var reservedIncomingCount = 0
        var reservedIncomingBytes: Int64 = 0
        for reservation in shareImportReservations.values {
            let finalPath = dir.appendingPathComponent(
                reservation.destinationFileName, isDirectory: false
            ).standardizedFileURL.path
            let temporaryPath = dir.appendingPathComponent(
                reservation.temporaryFileName, isDirectory: false
            ).standardizedFileURL.path
            protected.insert(finalPath)
            protected.insert(temporaryPath)

            // Before the temp exists, project the full reserved file. While it is being written,
            // count the entry already on disk plus the remaining bytes up to its declared size.
            let present = [entriesByPath[finalPath], entriesByPath[temporaryPath]].compactMap { $0 }
            if present.isEmpty {
                reservedIncomingCount += 1
                reservedIncomingBytes = saturatingAdd(reservedIncomingBytes, reservation.byteCount)
            } else {
                let observedBytes = present.reduce(Int64(0)) {
                    saturatingAdd($0, $1.bytes)
                }
                reservedIncomingBytes = saturatingAdd(
                    reservedIncomingBytes,
                    max(0, reservation.byteCount - observedBytes)
                )
            }
        }
        protected.formUnion(OverlayViewModel.shared.sessionFileURLs.map {
            $0.standardizedFileURL.path
        })
        protected.formUnion(OverlayViewModel.shared.pendingDroppedURLs.map {
            $0.standardizedFileURL.path
        })
        for session in SessionHistoryStore.shared.sessions {
            protected.insert(URL(fileURLWithPath: session.primaryPath).standardizedFileURL.path)
            protected.formUnion(session.additionalPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL.path
            })
        }

        var count = entries.count + reservedIncomingCount
        var bytes = entries.reduce(reservedIncomingBytes) { partial, entry in
            saturatingAdd(partial, entry.bytes)
        }

        for entry in entries.sorted(by: { $0.date < $1.date }) {
            guard count > maximumDropFiles || bytes > maximumDropBytes else { break }
            // Promise filenames are source-controlled and may not be known until the callback.
            // Deleting anything during that interval could remove a just-written file before its
            // URL reaches the ViewModel; defer all destructive retention until the final callback.
            guard activePromisedFileDeliveries.isEmpty else { break }
            guard !protected.contains(entry.url.standardizedFileURL.path) else { continue }
            do {
                try fm.removeItem(at: entry.url)
                count -= 1
                bytes = max(0, bytes - entry.bytes)
            } catch {
                continue
            }
        }
        return count <= maximumDropFiles && bytes <= maximumDropBytes
    }

    private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int64.max : sum
    }
}
