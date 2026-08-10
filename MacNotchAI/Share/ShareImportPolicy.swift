import Darwin
import Foundation

/// Persists a decrypted share while treating every sender-controlled byte as hostile.
///
/// The policy is intentionally independent of `DropMaterializer` and the main actor. Its caller
/// passes the private Drops directory, so validation and file I/O can run in a detached task.
nonisolated enum ShareImportPolicy {

    nonisolated static let maxFileNameBytes = ShareBundle.maxFileNameBytes
    nonisolated static let maxCollisionAttempts = 10_000

    nonisolated enum ImportError: LocalizedError, Equatable {
        case invalidFileName
        case unsafeFileType
        case unsupportedFileType
        case invalidDropsDirectory
        case destinationUnavailable
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .invalidFileName:
                return "The shared file has an unsafe filename."
            case .unsafeFileType:
                return "Executable, installer, and archive files cannot be imported from a share."
            case .unsupportedFileType:
                return "This shared file type is not supported."
            case .invalidDropsDirectory:
                return "Dragaway's private import directory is unavailable."
            case .destinationUnavailable:
                return "A safe destination filename could not be allocated."
            case .writeFailed:
                return "The shared file could not be saved safely."
            }
        }
    }

    nonisolated struct ReservedBatchMember: Sendable {
        let file: ShareBundle.FilePayload
        let destinationAttempt: Int
        let tempIdentifier: UUID
    }

    /// Writes a reserved batch all-or-nothing at the filesystem layer. History ownership is still
    /// committed by the main-actor controller afterward; if that later commit fails, the controller
    /// removes the returned URLs before releasing their retention reservations.
    nonisolated static func persistBatch(
        _ members: [ReservedBatchMember],
        in dropsDir: URL
    ) throws -> [URL] {
        guard (1...ShareBundle.maxFiles).contains(members.count) else {
            throw ShareBundle.BundleError.invalidFileCount
        }
        var created: [URL] = []
        created.reserveCapacity(members.count)
        do {
            for member in members {
                created.append(try persist(
                    member.file,
                    in: dropsDir,
                    reservedDestinationAttempt: member.destinationAttempt,
                    tempIdentifier: member.tempIdentifier
                ))
            }
            return created
        } catch {
            for url in created { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Extensions that the app can safely present without ever treating the imported bytes as an
    /// executable/archive. Unknown formats fail closed rather than reaching a generic text parser.
    private nonisolated static let supportedExtensions: Set<String> = [
        "pdf", "txt", "text", "md", "markdown", "rtf", "doc", "docx", "pages",
        "eml", "emlx",
        "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff",
        "csv", "tsv", "json", "ndjson", "jsonl", "xml", "yaml", "yml", "toml",
        "ini", "conf", "cfg", "properties", "env", "log", "html", "htm", "css",
        "scss", "sass", "less",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "swift", "py", "rb", "go", "rs",
        "java", "kt", "kts", "gradle", "c", "h", "cpp", "cc", "hpp", "hh", "cs",
        "m", "mm", "php", "sh", "bash", "zsh", "fish", "sql", "r", "lua", "pl",
        "pm", "dart", "scala", "clj", "ex", "exs", "vue", "svelte", "tex", "srt",
        "vtt", "gitignore", "b64", "base64",
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm",
        "mp3", "aac", "wav", "flac", "ogg", "m4a", "aiff", "aif"
    ]

    private nonisolated static let dangerousExtensions: Set<String> = [
        // Native/Windows/Linux executables and launchable bundles.
        "app", "application", "action", "workflow", "command", "com", "exe", "msi",
        "dll", "dylib", "so", "bin", "class", "jar", "apk", "appimage", "kext",
        "xpc", "service", "scpt", "scptd",
        // Installers, archives, and disk/container images unsupported by Dragaway.
        "pkg", "mpkg", "dmg", "xip", "zip", "rar", "7z", "tar", "tgz", "gz",
        "bz2", "xz", "lz", "lzma", "zst", "cab", "iso", "deb", "rpm"
    ]

    /// Validates and saves with mode 0600 using an exclusive same-directory temporary file and
    /// `renameatx_np(..., RENAME_EXCL)`. The rename is atomic and cannot overwrite a racing target.
    nonisolated static func persist(
        _ bundle: ShareBundle,
        in dropsDir: URL,
        reservedDestinationAttempt: Int? = nil,
        tempIdentifier: UUID = UUID()
    ) throws -> URL {
        try bundle.validate()
        guard bundle.files.count == 1, let file = bundle.files.first else {
            throw ShareBundle.BundleError.invalidFileCount
        }
        return try persist(
            file,
            in: dropsDir,
            reservedDestinationAttempt: reservedDestinationAttempt,
            tempIdentifier: tempIdentifier
        )
    }

    /// Persists one already-bounded member of a validated share batch. The controller owns batch
    /// atomicity and holds a separate retention reservation for every member until History commits.
    nonisolated static func persist(
        _ file: ShareBundle.FilePayload,
        in dropsDir: URL,
        reservedDestinationAttempt: Int? = nil,
        tempIdentifier: UUID = UUID()
    ) throws -> URL {
        let safeName = try validatedFileName(file.fileName)
        guard file.fileData.count <= ShareBundle.maxFileBytes else {
            throw ShareBundle.BundleError.fileTooLarge
        }
        if let reservedDestinationAttempt {
            guard (0..<maxCollisionAttempts).contains(reservedDestinationAttempt) else {
                throw ImportError.destinationUnavailable
            }
        }
        let root = try validatedDropsDirectory(dropsDir)

        let rootFD = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else { throw ImportError.invalidDropsDirectory }
        defer { Darwin.close(rootFD) }

        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              path(root, stillReferences: rootInfo) else {
            throw ImportError.invalidDropsDirectory
        }

        let tempName = ".dragaway-share-\(tempIdentifier.uuidString).tmp"
        let tempFD = tempName.withCString {
            openat(rootFD, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard tempFD >= 0 else { throw ImportError.writeFailed }

        var tempIsOpen = true
        var tempExists = true
        defer {
            if tempIsOpen { Darwin.close(tempFD) }
            if tempExists { tempName.withCString { _ = unlinkat(rootFD, $0, 0) } }
        }

        do {
            try writeAll(file.fileData, to: tempFD)
            guard fsync(tempFD) == 0 else { throw ImportError.writeFailed }
            let closeResult = Darwin.close(tempFD)
            tempIsOpen = false
            guard closeResult == 0 else { throw ImportError.writeFailed }
        } catch {
            throw error
        }

        let attempts = reservedDestinationAttempt.map { [$0] }
            ?? Array(0..<maxCollisionAttempts)
        for attempt in attempts {
            let candidateName = destinationFileName(for: safeName, attempt: attempt)
            try proveDirectChild(candidateName, of: root)

            let renameResult = tempName.withCString { source in
                candidateName.withCString { destination in
                    renameatx_np(rootFD, source, rootFD, destination, UInt32(RENAME_EXCL))
                }
            }
            if renameResult == 0 {
                guard path(root, stillReferences: rootInfo) else {
                    candidateName.withCString { _ = unlinkat(rootFD, $0, 0) }
                    throw ImportError.invalidDropsDirectory
                }
                tempExists = false
                _ = fsync(rootFD)
                return root.appendingPathComponent(candidateName, isDirectory: false)
            }
            if errno == EEXIST, reservedDestinationAttempt == nil { continue }
            if errno == EEXIST { throw ImportError.destinationUnavailable }
            throw ImportError.writeFailed
        }

        throw ImportError.destinationUnavailable
    }

    /// Exposed separately for deterministic traversal/security tests without touching disk.
    nonisolated static func validatedFileName(_ input: String) throws -> String {
        guard !input.isEmpty,
              input == input.trimmingCharacters(in: .whitespacesAndNewlines),
              input.utf8.count <= maxFileNameBytes,
              input != ".", input != "..",
              !input.hasPrefix("."), !input.hasSuffix("."),
              !input.hasPrefix("~"),
              !input.contains("/"), !input.contains("\\"), !input.contains(":"),
              !input.unicodeScalars.contains(where: { scalar in
                  scalar.value < 0x20 || scalar.value == 0x7F
              }),
              (input as NSString).isAbsolutePath == false,
              (input as NSString).lastPathComponent == input else {
            throw ImportError.invalidFileName
        }

        let ext = (input as NSString).pathExtension.lowercased()
        guard !dangerousExtensions.contains(ext) else { throw ImportError.unsafeFileType }
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedFileType }
        return input
    }

    // MARK: - Directory and atomic-write helpers

    private nonisolated static func validatedDropsDirectory(_ input: URL) throws -> URL {
        guard input.isFileURL else { throw ImportError.invalidDropsDirectory }

        var linkInfo = stat()
        let lstatResult = input.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &linkInfo)
        }
        guard lstatResult == 0,
              (linkInfo.st_mode & S_IFMT) == S_IFDIR else {
            // `lstat` rejects a symlink in the final component even if it targets a directory.
            throw ImportError.invalidDropsDirectory
        }

        let resolved = input.resolvingSymlinksInPath().standardizedFileURL
        var resolvedInfo = stat()
        let statResult = resolved.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &resolvedInfo)
        }
        guard statResult == 0, (resolvedInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw ImportError.invalidDropsDirectory
        }
        return resolved
    }

    private nonisolated static func proveDirectChild(_ name: String, of root: URL) throws {
        let candidate = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == root.path,
              candidate.lastPathComponent == name else {
            throw ImportError.invalidFileName
        }
    }

    /// The directory fd pins writes to one inode. Rechecking the path prevents returning a URL that
    /// an attacker swapped to a different directory while the import was in progress.
    private nonisolated static func path(_ root: URL, stillReferences openedInfo: stat) -> Bool {
        var current = stat()
        let result = root.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &current)
        }
        return result == 0
            && (current.st_mode & S_IFMT) == S_IFDIR
            && current.st_dev == openedInfo.st_dev
            && current.st_ino == openedInfo.st_ino
    }

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw ImportError.writeFailed
                }
                guard written > 0 else { throw ImportError.writeFailed }
                offset += written
            }
        }
    }

    nonisolated static func destinationFileName(for original: String, attempt: Int) -> String {
        guard attempt > 0 else { return original }

        let nsName = original as NSString
        let ext = nsName.pathExtension
        let rawStem = nsName.deletingPathExtension
        let suffix = " \(attempt + 1)"
        let extensionPart = ext.isEmpty ? "" : ".\(ext)"
        let maximumStemBytes = max(1, maxFileNameBytes - suffix.utf8.count - extensionPart.utf8.count)
        let stem = utf8Prefix(rawStem, maximumBytes: maximumStemBytes)
        return "\(stem)\(suffix)\(extensionPart)"
    }

    private nonisolated static func utf8Prefix(_ input: String, maximumBytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(input.count, maximumBytes))
        var used = 0
        for character in input {
            let size = String(character).utf8.count
            guard used + size <= maximumBytes else { break }
            result.append(character)
            used += size
        }
        return result.isEmpty ? "Shared File" : result
    }
}
