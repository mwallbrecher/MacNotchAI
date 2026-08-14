import AppKit

// THESIS (L4) — intent class + evidence → one concrete, truthful action against an
// accept-time-verifiable object.

enum AffordanceChannel: String, Codable, Sendable {
    case passive
    case summon
}

enum SuggestionTarget {
    /// Content currently on the pasteboard, re-verified by hash at accept.
    case pasteboard(hash: String)
    /// Exact AX selection/document snapshot, fully re-read and matched at accept.
    case accessibility(DocumentReader.Snapshot)
    /// Exact recent text-copy set held only in the bounded in-memory vault.
    case clipboardVault(references: [IntentContentVault.Reference])

    var kind: String {
        switch self {
        case .pasteboard: return "pasteboard"
        case .accessibility(let snapshot): return snapshot.scope.rawValue
        case .clipboardVault: return "clipboard_vault"
        }
    }
}

struct IntentSuggestion {
    let interactionID: UUID
    let channel: AffordanceChannel
    /// One-based rank within the surface. Passive whisper is always rank 1.
    let rank: Int
    let intentClass: IntentClass
    let action: AIAction
    let phrase: String
    let target: SuggestionTarget
    let probability: Double
}

enum TaskResolver {

    struct Context {
        let now: TimeInterval
        let translationCandidate: FeatureExtractor.ClipCandidate?
        let latestTextCandidate: FeatureExtractor.ClipCandidate?
        let recentCopies: Int
        let vault: IntentContentVault.Snapshot
        let selection: DocumentReader.Snapshot?
        let document: DocumentReader.Snapshot?
    }

    @MainActor
    static func makeContext(extractor: FeatureExtractor, at t: TimeInterval,
                            ax: DocumentReader.ProbeContext,
                            vault: IntentContentVault.Snapshot? = nil) -> Context {
        Context(now: t,
                translationCandidate: extractor.translationCandidate(at: t),
                latestTextCandidate: extractor.latestTextCandidate(at: t),
                recentCopies: extractor.distinctRecentCopies(at: t),
                vault: vault ?? IntentContentVault.shared.snapshot(at: t),
                selection: ax.selection,
                document: ax.document)
    }

    static func resolve(intentClass: IntentClass, probability: Double,
                        context: Context, interactionID: UUID,
                        channel: AffordanceChannel, rank: Int) -> IntentSuggestion? {
        switch intentClass {
        case .translation:
            return resolveTranslation(candidate: context.translationCandidate,
                                      probability: probability,
                                      interactionID: interactionID,
                                      channel: channel, rank: rank)
        case .comprehension:
            return resolveComprehension(context: context, probability: probability,
                                        interactionID: interactionID,
                                        channel: channel, rank: rank)
        case .discovery:
            return resolveDiscovery(context: context, probability: probability,
                                    interactionID: interactionID,
                                    channel: channel, rank: rank)
        }
    }

    // MARK: Translation

    static func translateAction(avoiding sourceLanguage: String?) -> AIAction {
        let catalog: [String: AIAction] = ["en": .translateEnglish, "de": .translateGerman,
                                           "fr": .translateFrench, "es": .translateSpanish]
        let source = sourceLanguage.map { String($0.prefix(2)) }
        // Study setup records the participant's repertoire explicitly. Targeting the
        // host Mac's locale could offer German to an English/Spanish participant.
        // Prefer English (the study's required language), then their other declared
        // supported languages; only ordinary non-study installs fall back to locale.
        let configured = IntentText.userLanguagesOverride.map { languages in
            languages.sorted { lhs, rhs in
                if lhs == "en" { return true }
                if rhs == "en" { return false }
                return lhs < rhs
            }
        }
        let preferences = configured ?? Locale.preferredLanguages.map { String($0.prefix(2)) }
        for preferred in preferences {
            if preferred == source { continue }
            if let action = catalog[preferred] { return action }
        }
        return .translateEnglish
    }

    static func resolveTranslation(candidate: FeatureExtractor.ClipCandidate?,
                                   probability: Double,
                                   interactionID: UUID = UUID(),
                                   channel: AffordanceChannel = .passive,
                                   rank: Int = 1) -> IntentSuggestion? {
        guard let candidate, pasteboardMatches(candidate.hash) else { return nil }
        let sourceName = candidate.language.flatMap {
            Locale.current.localizedString(forLanguageCode: String($0.prefix(2)))
        }
        let action = translateAction(avoiding: candidate.language)
        return IntentSuggestion(interactionID: interactionID, channel: channel, rank: rank,
                                intentClass: .translation, action: action,
                                phrase: sourceName.map { "Translate this \($0) text" }
                                      ?? "Translate this text",
                                target: .pasteboard(hash: candidate.hash),
                                probability: probability)
    }

    // MARK: Comprehension

    private static func resolveComprehension(context: Context, probability: Double,
                                             interactionID: UUID,
                                             channel: AffordanceChannel,
                                             rank: Int) -> IntentSuggestion? {
        // The current explicit selection is the narrowest statement of what the user
        // means, so it outranks even a fresh clipboard object.
        if let selection = context.selection {
            let shouldExplain = selection.charCount < 400
            let action: AIAction = shouldExplain ? .explainSimply : .summariseBullets
            let verb = shouldExplain ? "Explain" : "Summarise"
            return suggestion(.comprehension, action, "\(verb) the selected text",
                              .accessibility(selection), probability,
                              interactionID, channel, rank)
        }

        if let candidate = context.latestTextCandidate,
           pasteboardMatches(candidate.hash) {
            let explain = candidate.charCount < 400
                || ["question", "fragment", "code"].contains(candidate.shape)
            let action: AIAction = explain ? .explainSimply : .summariseBullets
            return suggestion(.comprehension, action,
                              explain ? "Explain the copied text" : "Summarise the copied text",
                              .pasteboard(hash: candidate.hash), probability,
                              interactionID, channel, rank)
        }

        guard let document = context.document else { return nil }
        let suffix = document.appName.map { " in \($0)" } ?? ""
        return suggestion(.comprehension, .summariseBullets,
                          "Summarise what you're reading\(suffix)",
                          .accessibility(document), probability,
                          interactionID, channel, rank)
    }

    // MARK: Discovery

    private static func resolveDiscovery(context: Context, probability: Double,
                                         interactionID: UUID,
                                         channel: AffordanceChannel,
                                         rank: Int) -> IntentSuggestion? {
        // This is a genuine multi-object action: every source is retained only in the
        // bounded RAM vault and materialised together after accept. `turnIntoBrief`
        // provides the existing synthesis prompt without adding a new product action.
        if context.vault.count >= 2 {
            return suggestion(.discovery, .turnIntoBrief,
                              "Synthesise \(context.vault.count) recent copied sources",
                              .clipboardVault(references: context.vault.references),
                              probability, interactionID, channel, rank)
        }

        if let candidate = context.latestTextCandidate,
           pasteboardMatches(candidate.hash) {
            return suggestion(.discovery, .extractKeyPoints,
                              "Extract key points from the copied text",
                              .pasteboard(hash: candidate.hash), probability,
                              interactionID, channel, rank)
        }

        guard let document = context.document else { return nil }
        return suggestion(.discovery, .extractKeyPoints,
                          "Extract key points from this document",
                          .accessibility(document), probability,
                          interactionID, channel, rank)
    }

    private static func suggestion(_ intentClass: IntentClass, _ action: AIAction,
                                   _ phrase: String, _ target: SuggestionTarget,
                                   _ probability: Double, _ interactionID: UUID,
                                   _ channel: AffordanceChannel, _ rank: Int) -> IntentSuggestion {
        IntentSuggestion(interactionID: interactionID, channel: channel, rank: rank,
                         intentClass: intentClass, action: action, phrase: phrase,
                         target: target, probability: probability)
    }

    // MARK: Accept-time content

    @MainActor
    static func materializedText(for target: SuggestionTarget,
                                 at t: TimeInterval) async -> String? {
        switch target {
        case .pasteboard:
            return nil
        case .accessibility(let snapshot):
            return await DocumentReader.read(matching: snapshot)
        case .clipboardVault(let references):
            guard let texts = IntentContentVault.shared.texts(matching: references, at: t),
                  texts.count == references.count, texts.count >= 2 else { return nil }
            return texts.enumerated().map { index, text in
                "SOURCE \(index + 1)\n\(text)"
            }.joined(separator: "\n\n---\n\n")
        }
    }

    static func pasteboardMatches(_ hash: String) -> Bool {
        let pb = NSPasteboard.general
        guard !PasteboardPrivacy.isSensitive(pb.types ?? []),
              let text = pb.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return false }
        return IntentText.hashPrefix(text) == hash
    }
}
