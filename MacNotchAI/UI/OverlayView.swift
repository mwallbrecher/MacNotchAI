import SwiftUI

// MARK: - Root overlay view

struct OverlayView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    let provider: any AIProvider

    // ── Liquid drop-from-notch entry animation ─────────────────────────────
    // Start compressed (notch-width, near-zero height) anchored at the top.
    // Phase 1 spreads width first (notch opening), phase 2 drops the body
    // with a low-damping spring so it bounces like a liquid drop detaching.
    @State private var dropX: CGFloat = 0.72   // ≈ notch width / pill width
    @State private var dropY: CGFloat = 0.02   // almost invisible (flat at notch)

    // Corner radius: pill-shaped when waiting, card-shaped when content shows.
    private var cornerRadius: CGFloat {
        switch vm.stage {
        case .waitingForDrop: return 34
        default:              return 20
        }
    }

    var body: some View {
        ZStack {
            switch vm.stage {
            case .waitingForDrop:
                WaitingPillView()
                    .transition(.identity)   // entry handled by scaleEffect below

            case .chips(let url, let actions):
                ChipsColumnView(fileURL: url, actions: actions, provider: provider)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.88, anchor: .top)
                            .combined(with: .opacity),
                        removal: .scale(scale: 0.92, anchor: .top)
                            .combined(with: .opacity)
                    ))

            case .loading(let url, _), .result(let url, _, _), .error(let url, _):
                TwoColumnView(fileURL: url, provider: provider)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        // Shadow only here — NSPanel.hasShadow = false prevents chrome ring artifact
        .shadow(color: .black.opacity(0.65), radius: 28, x: 0, y: 10)
        // Liquid entry scale (shrinks to ~0 height at notch, then drops down)
        .scaleEffect(x: dropX, y: dropY, anchor: .top)
        // Drive corner-radius morph and stage content transitions with same spring
        .animation(.spring(response: 0.38, dampingFraction: 0.60), value: cornerRadius)
        .animation(.spring(response: 0.38, dampingFraction: 0.60), value: vm.stage.tag)
        // ── Entry sequence ─────────────────────────────────────────────────
        .task {
            // Phase 1 — 80 ms: horizontal spread (like the notch mouth opening)
            withAnimation(.spring(response: 0.18, dampingFraction: 0.72)) {
                dropX = 1.08     // slightly wider than final → overshoot
                dropY = 0.28
            }
            try? await Task.sleep(nanoseconds: 90_000_000)

            // Phase 2 — liquid drop: low damping gives 2-3 bounces
            withAnimation(.spring(response: 0.46, dampingFraction: 0.50)) {
                dropX = 1.0
                dropY = 1.0
            }
        }
    }
}

// MARK: - Stage 1: Waiting pill

private struct WaitingPillView: View {
    @ObservedObject private var vm = OverlayViewModel.shared

    // Liquid jelly state — driven by isDragHovering via .task(id:)
    @State private var jellyX: CGFloat = 1.0
    @State private var jellyY: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 10) {
            // Icon morphs when file hovers
            Image(systemName: vm.isDragHovering ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(vm.isDragHovering ? .white : .white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))

            Text(vm.isDragHovering ? "Release to analyse" : "Drop file here")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: vm.isDragHovering)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 240)
        // Liquid jelly effect applied to pill content
        .scaleEffect(x: jellyX, y: jellyY)
        // ── Hover jelly sequence ──────────────────────────────────────────
        // Cancelled & restarted automatically when isDragHovering flips.
        .task(id: vm.isDragHovering) {
            if !vm.isDragHovering {
                // Snap back to rest with a little spring
                withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                    jellyX = 1.0; jellyY = 1.0
                }
                return
            }

            // File entered: squash from top (pressure coming down)
            withAnimation(.spring(response: 0.15, dampingFraction: 0.55)) {
                jellyX = 1.12; jellyY = 0.86
            }
            try? await Task.sleep(nanoseconds: 130_000_000)
            guard !Task.isCancelled else { return }

            // Spring back — overshoot vertically (liquid rebound)
            withAnimation(.spring(response: 0.28, dampingFraction: 0.48)) {
                jellyX = 0.94; jellyY = 1.09
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }

            // Slow breath oscillation while file hovers above
            var phase = false
            while !Task.isCancelled {
                phase.toggle()
                withAnimation(.spring(response: 0.60, dampingFraction: 0.68)) {
                    jellyX = phase ? 1.04 : 0.97
                    jellyY = phase ? 0.97 : 1.03
                }
                try? await Task.sleep(nanoseconds: 520_000_000)
            }
        }
    }
}

// MARK: - Stage 2: Chips column only

private struct ChipsColumnView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileHeaderView(fileURL: fileURL)

            Text("Suggested")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.35))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
            vm.stage = .loading(url: fileURL, action: action)
        }
        Task {
            do {
                let content: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
                    vm.stage = .error(url: fileURL, message: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Stage 3: Two-column layout

private struct TwoColumnView: View {
    let fileURL: URL
    let provider: any AIProvider
    @ObservedObject private var vm = OverlayViewModel.shared

    private var currentActions: [AIAction] {
        FileInspector.suggestedActions(for: fileURL)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {

            // ── LEFT COLUMN ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                FileHeaderView(fileURL: fileURL)

                Text("Suggested")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(currentActions) { action in
                        ActionChip(
                            title: action.rawValue,
                            isLoading: {
                                if case .loading(_, let a) = vm.stage { return a == action }
                                return false
                            }()
                        ) { runAction(action) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 220, alignment: .topLeading)

            // ── DIVIDER ──────────────────────────────────────────────────
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            // ── RIGHT COLUMN ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {

                Group {
                    switch vm.stage {
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.62)
                                .tint(.white)
                            Text("Thinking…")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)

                    case .result(_, _, let text):
                        ScrollView {
                            Text(text)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.88))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 220)

                    case .error(_, let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.orange.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)

                    default:
                        EmptyView()
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Custom prompt
                TextField("Ask anything about this file…", text: $vm.customPrompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .onSubmit { runCustomPrompt() }

                // Follow-up chips (only after a result)
                if case .result = vm.stage {
                    Text("Follow up")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))

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
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: vm.stage.showsRightColumn)
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
        vm.customPrompt = ""
        withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
            vm.stage = .loading(url: fileURL, action: action)
        }
        Task {
            do {
                let content: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
                    vm.stage = .error(url: fileURL, message: error.localizedDescription)
                }
            }
        }
    }

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        let action = AIAction.summariseBullets
        vm.customPrompt = ""
        withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
            vm.stage = .loading(url: fileURL, action: action)
        }
        Task {
            do {
                let fileContent: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image as requested: \(prompt)"
                    : "\(prompt)\n\n---\n\(try await FileContentExtractor.extract(from: fileURL))"
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: fileContent, imageURL: imageURL)
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
                    vm.stage = .result(url: fileURL, action: action, text: text)
                }
            } catch {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.60)) {
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
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 26, height: 26)
            Text(fileURL.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Action chip

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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            // Fill-only — no strokeBorder so interface stays clean and artifact-free
            .background(Color.white.opacity(isHovered ? 0.14 : 0.07))
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
        .disabled(isLoading)
    }
}
