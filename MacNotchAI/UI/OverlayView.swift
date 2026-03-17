import SwiftUI

struct OverlayView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider

    @State private var isProcessing = false
    @State private var result: String? = nil
    @State private var errorMessage: String? = nil
    @State private var selectedAction: AIAction? = nil
    @State private var hasAppeared = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // LEFT COLUMN — always visible: file + action chips
            VStack(alignment: .leading, spacing: 12) {

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

                Text("✦ Suggested:")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(result == nil ? actions : followUpActions) { action in
                        ActionChip(
                            title: action.rawValue,
                            isLoading: isProcessing && selectedAction == action
                        ) {
                            runAction(action)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 220, alignment: .topLeading)

            // RIGHT COLUMN — appears after an action is run
            if result != nil || isProcessing || errorMessage != nil {
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1)

                VStack(alignment: .leading, spacing: 8) {
                    if let result {
                        ScrollView {
                            Text(result)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.9))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 260)
                    } else if isProcessing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.6)
                                .tint(.white)
                            Text("Thinking...")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .padding(.top, 4)
                    } else if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                    }

                    Spacer(minLength: 0)
                }
                .padding(18)
                .frame(width: 260, alignment: .topLeading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // ─── CORE VISUAL: solid black panel ───
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
        // Expand width when the result column slides in
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: result != nil || isProcessing)
        // Unfold-from-notch entrance animation
        .scaleEffect(hasAppeared ? 1.0 : 0.65, anchor: .top)
        .opacity(hasAppeared ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.75)) {
                hasAppeared = true
            }
        }
    }

    private var followUpActions: [AIAction] {
        guard let selected = selectedAction else { return [] }
        switch selected {
        case .summariseBullets: return [.summariseShort, .translateGerman, .extractKeyPoints]
        case .extractKeyDates:  return [.summariseBullets, .translateGerman]
        default:                return [.summariseBullets, .rephraseFormal]
        }
    }

    private func runAction(_ action: AIAction) {
        selectedAction = action
        isProcessing = true
        result = nil
        errorMessage = nil

        Task {
            do {
                let content: String
                if FileInspector.isImageFile(fileURL) {
                    content = "Analyse the attached image."
                } else {
                    content = try await FileContentExtractor.extract(from: fileURL)
                }

                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let response = try await provider.complete(
                    action: action,
                    content: content,
                    imageURL: imageURL
                )
                await MainActor.run {
                    self.result = response
                    self.isProcessing = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isProcessing = false
                }
            }
        }
    }
}

// MARK: - Action Chip

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
                Capsule()
                    .strokeBorder(
                        Color.white.opacity(isHovered ? 0.45 : 0.22),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = hovered
            }
        }
        .disabled(isLoading)
    }
}
