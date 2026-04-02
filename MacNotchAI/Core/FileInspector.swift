import Foundation

struct FileInspector {
    static func suggestedActions(for url: URL) -> [AIAction] {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return [.summariseBullets, .extractKeyDates, .extractKeyPoints, .translateGerman, .rephraseFormal]
        case "txt", "md", "rtf":
            return [.summariseBullets, .summariseShort, .rephraseFormal, .rephraseCasual, .translateGerman]
        case "docx", "doc", "pages":
            return [.summariseBullets, .extractKeyPoints, .rephraseFormal, .translateGerman]
        case "swift", "py", "js", "ts", "jsx", "tsx", "go", "rs", "rb", "java", "kt", "cpp", "c", "cs":
            return [.explainCode, .findBugs, .addDocstring, .refactor]
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff":
            return [.describeImage, .extractTextFromImage, .generateAltText]
        case "csv":
            return [.summariseBullets, .extractKeyPoints]
        case "json", "xml", "yaml", "yml":
            return [.explainCode, .summariseBullets]
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv", "flv", "webm",
             "zip", "rar", "7z", "tar", "gz",
             "dmg", "pkg", "exe",
             "mp3", "aac", "wav", "flac", "ogg", "m4a":
            return []   // unsupported — caller should show error state
        default:
            return [.summariseBullets, .summariseShort, .extractKeyPoints]
        }
    }

    /// Returns the union of suggested actions for all given URLs, preserving the
    /// order from the first URL and appending actions from subsequent URLs that
    /// aren't already present.
    static func suggestedActions(forAll urls: [URL]) -> [AIAction] {
        guard !urls.isEmpty else { return [] }
        var seen = Set<AIAction>()
        var result: [AIAction] = []
        for url in urls {
            for action in suggestedActions(for: url) {
                if seen.insert(action).inserted {
                    result.append(action)
                }
            }
        }
        return result
    }

    /// Returns true for file types AI Drop cannot process.
    /// Drop handlers use this to route directly to the error stage.
    static func isUnsupportedFileType(_ url: URL) -> Bool {
        suggestedActions(for: url).isEmpty
    }

    static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func requiresVision(_ url: URL) -> Bool {
        return isImageFile(url)
    }
}
