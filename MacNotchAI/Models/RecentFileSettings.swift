import Combine
import Foundation

/// User-owned scope for the permission-free "last saved file" watcher.
///
/// Dragaway is not sandboxed, so this follows the project's existing output-directory pattern and
/// stores normalized paths rather than security-scoped bookmarks. macOS may still enforce its normal
/// Files & Folders privacy boundary when a protected location is read.
@MainActor
final class RecentFileSettings: ObservableObject {
    static let shared = RecentFileSettings()

    private struct PersistedConfiguration: Codable {
        let version: Int
        let isEnabled: Bool
        let watchedPaths: [String]
        let excludedPaths: [String]
    }

    private static let persistenceKey = "recentFiles.configuration.v1"
    private static let formatVersion = 1

    @Published private(set) var isEnabled: Bool
    @Published private(set) var watchedPaths: [String]
    @Published private(set) var excludedPaths: [String]

    var watchedFolders: [URL] { watchedPaths.map { URL(fileURLWithPath: $0) } }
    var excludedFolders: [URL] { excludedPaths.map { URL(fileURLWithPath: $0) } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
           let decoded = try? JSONDecoder().decode(PersistedConfiguration.self, from: data),
           decoded.version == Self.formatVersion {
            isEnabled = decoded.isEnabled
            watchedPaths = Self.normalizedRoots(decoded.watchedPaths)
            excludedPaths = Self.normalizedRoots(decoded.excludedPaths)
        } else {
            isEnabled = true
            watchedPaths = Self.defaultWatchedPaths
            excludedPaths = Self.defaultExcludedPaths
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        persistAndNotify()
    }

    func addWatchedFolders(_ urls: [URL]) {
        let updated = Self.normalizedRoots(watchedPaths + urls.map(\.path))
        guard updated != watchedPaths else { return }
        watchedPaths = updated
        persistAndNotify()
    }

    func removeWatchedFolder(_ url: URL) {
        let path = Self.normalizedPath(url.path)
        let updated = watchedPaths.filter { $0 != path }
        guard updated != watchedPaths else { return }
        watchedPaths = updated
        persistAndNotify()
    }

    func addExcludedFolders(_ urls: [URL]) {
        let updated = Self.normalizedRoots(excludedPaths + urls.map(\.path))
        guard updated != excludedPaths else { return }
        excludedPaths = updated
        persistAndNotify()
    }

    func removeExcludedFolder(_ url: URL) {
        let path = Self.normalizedPath(url.path)
        let updated = excludedPaths.filter { $0 != path }
        guard updated != excludedPaths else { return }
        excludedPaths = updated
        persistAndNotify()
    }

    func resetFoldersToDefaults() {
        let defaults = Self.defaultWatchedPaths
        let exclusions = Self.defaultExcludedPaths
        guard watchedPaths != defaults || excludedPaths != exclusions else { return }
        watchedPaths = defaults
        excludedPaths = exclusions
        persistAndNotify()
    }

    /// Exclusions always win. Component-boundary matching avoids treating `/Documents-old` as a
    /// child of `/Documents`; nested watched roots are collapsed before they reach this method.
    func contains(_ path: String) -> Bool {
        let normalized = Self.normalizedPath(path)
        guard watchedPaths.contains(where: { Self.contains(root: $0, path: normalized) }) else {
            return false
        }
        return !excludedPaths.contains(where: { Self.contains(root: $0, path: normalized) })
    }

    private func persistAndNotify() {
        let configuration = PersistedConfiguration(
            version: Self.formatVersion,
            isEnabled: isEnabled,
            watchedPaths: watchedPaths,
            excludedPaths: excludedPaths
        )
        if let data = try? JSONEncoder().encode(configuration) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
        NotificationCenter.default.post(name: .recentFileSettingsChanged, object: nil)
    }

    private static var defaultWatchedPaths: [String] {
        let fm = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .desktopDirectory, .documentDirectory, .downloadsDirectory,
        ]
        return normalizedRoots(directories.compactMap {
            fm.urls(for: $0, in: .userDomainMask).first?.path
        })
    }

    /// These only become relevant if the user adds their whole home folder. Keeping them as
    /// explicit, removable exclusions makes the safe default visible rather than hiding scope.
    private static var defaultExcludedPaths: [String] {
        normalizedRoots([
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true).path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".Trash", isDirectory: true).path,
        ])
    }

    nonisolated static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    nonisolated static func contains(root: String, path: String) -> Bool {
        if root == "/" { return path.hasPrefix("/") }
        return path == root || path.hasPrefix(root + "/")
    }

    /// De-duplicate and collapse nested roots. Watching `/Documents` already covers
    /// `/Documents/Exports`; the latter would only duplicate FSEvents traffic.
    private nonisolated static func normalizedRoots(_ paths: [String]) -> [String] {
        let unique = Set(paths.map(normalizedPath).filter { !$0.isEmpty })
        var roots: [String] = []
        for path in unique.sorted(by: { lhs, rhs in
            let lhsDepth = URL(fileURLWithPath: lhs).pathComponents.count
            let rhsDepth = URL(fileURLWithPath: rhs).pathComponents.count
            return lhsDepth == rhsDepth ? lhs.localizedStandardCompare(rhs) == .orderedAscending
                                        : lhsDepth < rhsDepth
        }) {
            if !roots.contains(where: { contains(root: $0, path: path) }) {
                roots.append(path)
            }
        }
        return roots
    }
}
