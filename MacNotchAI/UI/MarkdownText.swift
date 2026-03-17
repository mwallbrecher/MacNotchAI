import SwiftUI

// MARK: - MarkdownText

/// Lightweight Markdown renderer for AI response text.
///
/// Supported patterns (covers ~95 % of real AI output):
///   # / ## / ###    headings
///   **bold**         via AttributedString inline parsing
///   *italic*         via AttributedString inline parsing
///   `code`           via AttributedString inline parsing
///   ```lang … ```   fenced code blocks
///   - / * / + item  bullet lists
///   1. item          numbered lists
///   ---              horizontal rule
///   blank lines      vertical spacing
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(parse(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MBlock) -> some View {
        switch block {

        case .h1(let text):
            inline(text, size: 15, weight: .bold)
                .padding(.top, 7).padding(.bottom, 1)

        case .h2(let text):
            inline(text, size: 13, weight: .bold)
                .padding(.top, 5).padding(.bottom, 1)

        case .h3(let text):
            inline(text, size: 12, weight: .semibold)
                .padding(.top, 4)

        case .paragraph(let text):
            inline(text, size: 12.5, weight: .regular)

        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: 10, alignment: .center)
                inline(text, size: 12.5, weight: .regular)
            }

        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor(.white.opacity(0.40))
                    .frame(minWidth: 18, alignment: .trailing)
                inline(text, size: 12.5, weight: .regular)
            }

        case .code(let lang, let body):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    Text(lang.lowercased())
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.30))
                        .padding(.horizontal, 11)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                }
                Text(body)
                    .font(.system(size: 11.5).monospaced())
                    .foregroundColor(.white.opacity(0.80))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, lang.isEmpty ? 9 : 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.vertical, 3)

        case .rule:
            Color.white.opacity(0.10)
                .frame(height: 1)
                .padding(.vertical, 5)

        case .gap:
            Color.clear.frame(height: 5)
        }
    }

    // MARK: - Inline Markdown (bold / italic / code / links)

    /// Uses `AttributedString(markdown:)` for inline formatting.
    /// Falls back to plain `Text` if parsing fails.
    @ViewBuilder
    private func inline(_ raw: String, size: CGFloat, weight: Font.Weight) -> some View {
        if let attr = try? AttributedString(
            markdown: raw,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attr)
                .font(.system(size: size, weight: weight))
                .foregroundColor(.white.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(raw)
                .font(.system(size: size, weight: weight))
                .foregroundColor(.white.opacity(0.88))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Block model

private enum MBlock {
    case h1(String)
    case h2(String)
    case h3(String)
    case paragraph(String)
    case bullet(String)
    case numbered(Int, String)
    case code(lang: String, body: String)
    case rule
    case gap           // blank line → a small vertical spacer
}

// MARK: - Parser

private func parse(_ source: String) -> [MBlock] {
    let lines  = source.components(separatedBy: "\n")
    var result = [MBlock]()
    var i      = 0
    var lastWasGap = false

    while i < lines.count {
        let raw = lines[i]
        let t   = raw.trimmingCharacters(in: .whitespaces)

        // ── Fenced code block ─────────────────────────────────────────────
        if t.hasPrefix("```") {
            let lang = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines = [String]()
            i += 1
            while i < lines.count {
                let cl = lines[i]
                if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                codeLines.append(cl)
                i += 1
            }
            result.append(.code(lang: lang, body: codeLines.joined(separator: "\n")))
            lastWasGap = false
            continue
        }

        // ── Headings ──────────────────────────────────────────────────────
        if t.hasPrefix("### ") {
            result.append(.h3(String(t.dropFirst(4))))
        } else if t.hasPrefix("## ") {
            result.append(.h2(String(t.dropFirst(3))))
        } else if t.hasPrefix("# ") {
            result.append(.h1(String(t.dropFirst(2))))
        }

        // ── Horizontal rule ───────────────────────────────────────────────
        else if t == "---" || t == "***" || t == "___" {
            result.append(.rule)
        }

        // ── Bullet list ───────────────────────────────────────────────────
        else if let rest = bulletContent(t) {
            result.append(.bullet(rest))
        }

        // ── Numbered list ─────────────────────────────────────────────────
        else if let (n, rest) = numberedContent(t) {
            result.append(.numbered(n, rest))
        }

        // ── Blank line → single gap (consecutive blanks collapsed) ────────
        else if t.isEmpty {
            if !lastWasGap && !result.isEmpty {
                result.append(.gap)
                lastWasGap = true
            }
            i += 1
            continue
        }

        // ── Regular paragraph ─────────────────────────────────────────────
        else {
            result.append(.paragraph(t))
        }

        lastWasGap = false
        i += 1
    }

    return result
}

// MARK: - Parsing helpers

private func bulletContent(_ line: String) -> String? {
    for prefix in ["- ", "* ", "+ "] {
        if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
    }
    return nil
}

private func numberedContent(_ line: String) -> (Int, String)? {
    guard let dotIdx = line.firstIndex(of: ".") else { return nil }
    let numStr = String(line[line.startIndex ..< dotIdx])
    guard let n = Int(numStr) else { return nil }
    let afterDot = line.index(after: dotIdx)
    guard afterDot < line.endIndex else { return nil }
    let rest = line[afterDot...].trimmingCharacters(in: .whitespaces)
    return rest.isEmpty ? nil : (n, rest)
}
