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
        default:
            return [.summariseBullets, .summariseShort, .extractKeyPoints]
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func requiresVision(_ url: URL) -> Bool {
        return isImageFile(url)
    }
}
