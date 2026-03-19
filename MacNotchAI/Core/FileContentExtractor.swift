import Foundation
import PDFKit

struct FileContentExtractor {

    static func extract(from url: URL) async throws -> String {
        // Under Hardened Runtime, URLs received via drag-and-drop from Finder
        // arrive as security-scoped URLs. startAccessingSecurityScopedResource()
        // is required to read them; for plain path URLs it is a harmless no-op.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractPDF(from: url)
        case "txt", "md", "rtf", "swift", "py", "js", "ts", "jsx", "tsx",
             "go", "rs", "rb", "java", "kt", "cpp", "c", "cs", "json",
             "xml", "yaml", "yml", "csv":
            return try String(contentsOf: url, encoding: .utf8)
        case "png", "jpg", "jpeg", "heic", "webp", "tiff":
            return "IMAGE_FILE"
        default:
            // Attempt UTF-8 read as fallback
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private static func extractPDF(from url: URL) throws -> String {
        // Security scope is already active from the caller (extract).
        guard let pdf = PDFDocument(url: url) else {
            throw ExtractionError.cannotOpenPDF
        }
        var text = ""
        let maxPages = min(pdf.pageCount, 20)
        for i in 0..<maxPages {
            if let page = pdf.page(at: i) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtractionError.pdfHasNoText
        }
        // Truncate to ~12,000 chars to stay within typical context limits
        return String(text.prefix(12000))
    }

    enum ExtractionError: LocalizedError {
        case cannotOpenPDF
        case pdfHasNoText
        case unsupportedFileType

        var errorDescription: String? {
            switch self {
            case .cannotOpenPDF:       return "Could not open the PDF file."
            case .pdfHasNoText:        return "This PDF appears to contain only images. Try an image action instead."
            case .unsupportedFileType: return "This file type is not yet supported."
            }
        }
    }
}
