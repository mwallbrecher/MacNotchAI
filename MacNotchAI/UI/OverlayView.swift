import SwiftUI

// MARK: - Root overlay view

struct OverlayView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    let provider: any AIProvider

    /// Pill-shaped when waiting; card-shaped once content appears.
    private var cornerRadius: CGFloat {
        switch vm.stage {
        case .waitingForDrop: return 34
        default:              return 20
        }
    }

    var body: some View {
        Group {
            switch vm.stage {
            case .waitingForDrop:
                WaitingPillView()

            case .chips(let url, let actions):
                ChipsColumnView(
                    fileURL: url,
                    actions: actions,
                    provider: provider
                )

            case .loading(let url, _),
                 .result(let url, _, _),
                 .error(let url, _):
                TwoColumnView(fileURL: url, provider: provider)
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
        .animation(.spring(response: 0.30, dampingFraction: 0.75), value: cornerRadius)
    }
}

// MARK: - Stage 1: Waiting pill

private struct WaitingPillView: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .scaleEffect(pulse ? 1.12 : 1.0)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )
            Text("Drop files here!")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 240)
        .onAppear { pulse = true }
    }
}

// MARK: - Stage 2: Chips column only

private struct ChipsColumnView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FileHeaderView(fileURL: fileURL)

            Text("✦ Suggested:")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))

            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions) { action in
                    ActionChip(title: action.rawValue, isLoading: false) {
                        runAction(action)
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 280, alignment: .topLeading)
    }

    private func runAction(_ action: AIAction) {
        let vm = OverlayViewModel.shared
        vm.stage = .loading(url: fileURL, action: action)

        Task {
            do {
                let content: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                await MainActor.run {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                await MainActor.run {
                    vm.stage = .error(url: fileURL, message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Stage 3: Two-column (chips left, result right)

private struct TwoColumnView: View {
    let fileURL: URL
    let provider: any AIProvider
    @ObservedObject private var vm = OverlayViewModel.shared

    private var currentActions: [AIAction] {
        FileInspector.suggestedActions(for: fileURL)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── LEFT COLUMN ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                FileHeaderView(fileURL: fileURL)

                Text("✦ Suggested:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(currentActions) { action in
                        ActionChip(
                            title: action.rawValue,
                            isLoading: {
                                if case .loading(_, let a) = vm.stage { return a == action }
                                return false
                            }()
                        ) {
                            runAction(action)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 220, alignment: .topLeading)

            // ── DIVIDER ──────────────────────────────────────────────
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(width: 1)

            // ── RIGHT COLUMN ─────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {

                // Result / loading / error card
                Group {
                    switch vm.stage {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.65)
                                .tint(.white)
                            Text("Thinking...")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)

                    case .result(_, _, let text):
                        ScrollView {
                            Text(text)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)

                    case .error(_, let msg):
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading)

                    default:
                        EmptyView()
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Custom prompt text field
                TextField("Type in here...", text: $vm.customPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onSubmit { runCustomPrompt() }

                // Follow-up chips
                if case .result = vm.stage {
                    Text("✦ Follow up:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(followUpActions) { action in
                            ActionChip(title: action.rawValue, isLoading: false) {
                                runAction(action)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(width: 280, alignment: .topLeading)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        .frame(minHeight: 280)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: vm.stage.showsRightColumn)
    }

    private var followUpActions: [AIAction] {
        guard case .result(_, let action, _) = vm.stage else { return [] }
        switch action {
        case .summariseBullets: return [.summariseShort, .translateGerman, .extractKeyPoints]
        case .extractKeyDates:  return [.summariseBullets, .translateGerman]
        default:                return [.summariseBullets, .rephraseFormal]
        }
    }

    private func runAction(_ action: AIAction) {
        vm.stage = .loading(url: fileURL, action: action)
        vm.customPrompt = ""

        Task {
            do {
                let content: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                await MainActor.run {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                await MainActor.run {
                    vm.stage = .error(url: fileURL, message: error.localizedDescription)
                }
            }
        }
    }

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }

        // Prepend the user's custom instruction to the extracted file content,
        // then send as a "summarise" request (the system prompt is intentionally
        // generic so the user's own words drive the output).
        let action = AIAction.summariseBullets
        vm.stage = .loading(url: fileURL, action: action)
        vm.customPrompt = ""

        Task {
            do {
                let fileContent: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image as requested: \(prompt)"
                    : "\(prompt)\n\n---\n\(try await FileContentExtractor.extract(from: fileURL))"
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: fileContent, imageURL: imageURL)
                await MainActor.run {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                await MainActor.run {
                    vm.stage = .error(url: fileURL, message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Shared subviews

private struct FileHeaderView: View {
    let fileURL: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 28, height: 28)
            Text(fileURL.lastPathComponent)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Action chip button

struct ActionChip: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(.white)
                        .frame(width: 10, height: 10)
                }
                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.white.opacity(isHovered ? 0.08 : 0.0))
            .clipShape(Capsule())
            .overlay(
                Capsule().strokeBorder(
                    Color.white.opacity(isHovered ? 0.45 : 0.22),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovered }
        }
        .disabled(isLoading)
    }
}
