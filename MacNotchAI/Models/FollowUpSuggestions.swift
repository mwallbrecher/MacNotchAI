import Foundation

/// Model-suggested follow-up prompts, carried in the SAME completion as the answer.
///
/// The reply ends with a marker line followed by one prompt per line; everything from
/// the marker on is stripped from what the user sees and turned into the follow-up
/// pills. Riding along in the answer is deliberate: a second request would double the
/// Worker's `global_usage` counter, and that circuit-breaker caps INTERACTIONS, so it
/// would halve how far the free tier stretches.
///
/// Nothing here is load-bearing — a model that ignores the instruction (or a BYOK model
/// that never saw it) simply yields no suggestions and the UI keeps its static list.
enum FollowUpSuggestions {
    static let marker = "<<<FOLLOWUPS>>>"

    /// Appended to the system prompt. Phrased so the lines are usable verbatim as the
    /// next user turn, because clicking a pill sends exactly that text.
    static let instruction = """
        After your answer, add a final line containing exactly \(marker) and then 1-6 \
        suggested follow-up prompts, one per line, each at most 6 words, phrased the way \
        the user would type them. Write nothing after that block, and omit the block \
        entirely if no useful follow-up exists.
        """

    /// Longest prompt kept. Longer lines are the model ignoring the word limit and would
    /// wrap badly in a pill, so they are dropped rather than truncated mid-sentence.
    private static let maxPromptLength = 64
    private static let maxPrompts = 6

    /// What may be shown for a reply that is still streaming.
    ///
    /// Holds back any trailing run that could still grow into the marker, so a partially
    /// arrived `<<<FOL…` never flashes in the transcript. Costs at most a one-delta lag
    /// on the few characters that start the marker.
    static func visiblePrefix(of raw: String) -> String {
        if let range = raw.range(of: marker) {
            return String(raw[raw.startIndex..<range.lowerBound])
        }
        var hold = min(marker.count - 1, raw.count)
        while hold > 0 {
            if marker.hasPrefix(raw.suffix(hold)) { return String(raw.dropLast(hold)) }
            hold -= 1
        }
        return raw
    }

    /// Split a COMPLETE reply into the answer and its suggested follow-ups.
    /// A reply without the marker is returned untouched with no suggestions.
    static func parse(_ full: String) -> (answer: String, followUps: [String]) {
        guard let range = full.range(of: marker) else { return (full, []) }

        let answer = String(full[full.startIndex..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A reply that is ONLY a follow-up block is malformed; keep the raw text rather
        // than showing the user an empty bubble.
        guard !answer.isEmpty else { return (full, []) }

        let prompts = String(full[range.upperBound...])
            .split(separator: "\n")
            .map { stripListDecoration(String($0)) }
            .filter { !$0.isEmpty && $0.count <= maxPromptLength }
        return (answer, Array(prompts.prefix(maxPrompts)))
    }

    /// Models bullet or number the list even when told not to. Strip that so the pill
    /// shows the prompt alone — and so the text sent back as the next turn is clean.
    private static func stripListDecoration(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        while let first = s.first, "-*•".contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        // "1." / "2)" prefixes — only when everything before the separator is digits, so
        // a prompt like "Explain 2.5 Flash" is left alone.
        if let sep = s.firstIndex(where: { $0 == "." || $0 == ")" }),
           sep > s.startIndex,
           s[s.startIndex..<sep].allSatisfy(\.isNumber) {
            s = String(s[s.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        }
        return s
    }
}
