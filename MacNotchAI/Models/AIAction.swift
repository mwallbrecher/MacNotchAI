import Foundation

enum AIAction: String, CaseIterable, Identifiable {
    // Document actions
    case summariseBullets   = "Summarise into Bullets"
    case summariseShort     = "Summarise in 1 Sentence"
    case extractKeyDates    = "Extract Key Dates"
    case extractKeyPoints   = "Extract Key Points"
    case translateGerman    = "Translate to German"
    case translateFrench    = "Translate to French"
    case translateSpanish   = "Translate to Spanish"
    case rephraseFormal     = "Rephrase Formally"
    case rephraseCasual     = "Rephrase Casually"

    // Code actions
    case explainCode        = "Explain This Code"
    case findBugs           = "Find Bugs"
    case addDocstring       = "Add Documentation"
    case refactor           = "Suggest Refactoring"

    // Image actions
    case describeImage          = "Describe Image"
    case extractTextFromImage   = "Extract Text (OCR)"
    case generateAltText        = "Generate Alt Text"

    // Free-form follow-up — used when the user types a custom question
    // in the prompt field. System prompt deliberately stays neutral so the
    // AI answers the question instead of applying a fixed transformation.
    case freeform               = "Custom Query"

    var id: String { rawValue }

    var systemPrompt: String {
        switch self {
        case .summariseBullets:
            return "Summarise the following content into concise bullet points. Be brief and extract only the most important information."
        case .summariseShort:
            return "Summarise the following content in exactly one sentence."
        case .extractKeyDates:
            return "Extract all dates, deadlines, and time references from the following content. Present them as a clean list."
        case .extractKeyPoints:
            return "Extract the 5 most important key points from the following content as a numbered list."
        case .translateGerman:
            return "Translate the following text to German. Preserve formatting."
        case .translateFrench:
            return "Translate the following text to French. Preserve formatting."
        case .translateSpanish:
            return "Translate the following text to Spanish. Preserve formatting."
        case .rephraseFormal:
            return "Rephrase the following text in formal, professional English."
        case .rephraseCasual:
            return "Rephrase the following text in casual, friendly English."
        case .explainCode:
            return "Explain what this code does in plain English. Use bullet points for each major component."
        case .findBugs:
            return "Analyse this code and identify any bugs, errors, or potential issues. List each issue with a brief explanation."
        case .addDocstring:
            return "Add clear documentation comments/docstrings to this code. Return the full code with documentation added."
        case .refactor:
            return "Suggest concrete refactoring improvements for this code. Explain each suggestion briefly."
        case .describeImage:
            return "Describe this image in detail."
        case .extractTextFromImage:
            return "Extract and transcribe all text visible in this image."
        case .generateAltText:
            return "Write concise, descriptive alt text for this image suitable for accessibility."
        case .freeform:
            return "You are a helpful document assistant. The user's message contains a question followed by the document content. Answer the question accurately and concisely using the document as context. Do not summarise unless asked."
        }
    }
}
