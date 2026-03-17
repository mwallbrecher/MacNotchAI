import SwiftUI

// MARK: - Root overlay view

struct OverlayView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    let provider: any AIProvider

    // ── Entry animation state ───────────────────────────────────────────────
    // Two-phase liquid-drop entry: phase 1 spreads the pill horizontally (notch
    // mouth opens), phase 2 drops the body with a low-damping spring bounce.
    // Applied OUTSIDE clipShape so neither the scale nor the jelly wobble can
    // be clipped by the SwiftUI shape.
    // The window is 288×96 (vs the 240×68 pill content), providing a 24 pt
    // transparent border horizontally and 28 pt below — the wobble scaleEffect
    // overflows into this transparent canvas without hitting the NSHostingView
    // clip boundary. WaitingPillView is top-aligned so its top edge stays flush
    // with the notch bottom regardless of the extra canvas height.
    // ≈ notch width / pill width — spreads to 1.0 in phase 1
    @State private var dropX: CGFloat = 0.78
    // near-zero → springs to 1.0 in phase 2, anchored at .top so the pill
    // grows downward from the notch edge (not from a centred origin)
    @State private var dropY: CGFloat = 0.02

    // Card corner radius (stage 1 pill owns its own clip inside WaitingPillView)
    private var cornerRadius: CGFloat { 20 }

    var body: some View {
        // ── Stage routing ─────────────────────────────────────────────────────
        // Stage 1 owns its own black background + clipShape so the outer ZStack
        // stays transparent in the 288×96 canvas, giving the wobble scaleEffect
        // room to overflow without hitting the window boundary.
        // Stages 2/3 share a card ZStack that applies background + clip itself.
        Group {
            switch vm.stage {
            case .waitingForDrop:
                // Pin pill to the TOP of the 288×96 canvas so its top edge stays
                // flush with the notch bottom — matching the pre-canvas-expansion
                // position. The 28 pt transparent gap below gives vertical wobble
                // headroom (jellyY 1.09 → +3 pt, well within the extra space).
                WaitingPillView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.identity)

            default:
                ZStack(alignment: .topTrailing) {
                    Group {
                        switch vm.stage {
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
                        default:
                            EmptyView()
                        }
                    }
                    CloseButton()
                        .padding(10)
                        .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .transition(.identity)
            }
        }
        .compositingGroup()
        // No shadow on the pill — it sits in the dark notch area and any shadow
        // bleeds as a visible rectangle. Card stages get a gentle lift shadow.
        .shadow(
            color:  vm.stage.tag == 0 ? .clear : .black.opacity(0.45),
            radius: vm.stage.tag == 0 ? 0      : 18,
            x: 0,
            y:      vm.stage.tag == 0 ? 0      : 8
        )
        // ── Entry: notch-mouth spread (phase 1) then liquid drop (phase 2) ──
        // Pill is pinned to window top (= notch bottom) via .top alignment above,
        // so .anchor: .top here means "grow downward from the notch edge".
        // Both scaleEffects are outside clipShape → no overflow clipping possible.
        .scaleEffect(x: dropX, y: dropY, anchor: .top)
        // ── Jelly wobble (stage 1 only, outside all clips) ─────────────────
        // anchor: .top keeps all Y expansion downward — eliminates the upward
        // overflow that was clipped by the window boundary when jellyY > 1.0.
        .scaleEffect(
            x: vm.stage.tag == 0 ? vm.jellyX : 1.0,
            y: vm.stage.tag == 0 ? vm.jellyY : 1.0,
            anchor: .top
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.60), value: vm.stage.tag)
        // ── Entry sequence ─────────────────────────────────────────────────
        // Phase 1 — notch mouth opens (X spreads, Y barely visible)
        // Phase 2 — liquid drop with low-damping bounce (detach effect)
        .task {
            withAnimation(.spring(response: 0.12, dampingFraction: 0.70)) {
                dropX = 1.06
                dropY = 0.42
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
            withAnimation(.spring(response: 0.32, dampingFraction: 0.56)) {
                dropX = 1.0
                dropY = 1.0
            }
        }
    }
}

// MARK: - Stage 1: Waiting pill

private struct WaitingPillView: View {
    @ObservedObject private var vm = OverlayViewModel.shared

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
        // Explicit 68 pt height so cornerRadius 34 = height/2 → perfect pill/
        // stadium shape. Content (icon + label, ~22 pt) is centred in the 68 pt
        // with 18 pt padding on each side. This also keeps the pill flush with
        // the notch bottom: the 288×96 canvas is top-aligned, so pill top ==
        // window top == notch bottom, with 28 pt transparent space below for
        // the downward jelly wobble (jellyY 1.09 → +6 pt, well within 28 pt).
        .frame(width: 240, height: 68)
        // Background + clip live HERE (inside WaitingPillView), not on the outer
        // canvas in OverlayView. The outer 288×96 canvas stays transparent so the
        // wobble scaleEffect (applied after this clip in OverlayView) can overflow
        // freely without hitting the window clip boundary.
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        // ── Hover jelly — routed through ViewModel, never owned by this view ──
        // The task lives in OverlayViewModel.jellyTask (a single stored Task).
        // Using .task(id:) here would attach one task per WaitingPillView
        // instance. During the 0.14 s dismiss animation both the old and new
        // WaitingPillView are live simultaneously; both would fire their tasks
        // for the same isDragHovering change → two concurrent withAnimation{}
        // blocks on jellyX/Y → SwiftUI invariant violation → crash.
        // With the task owned by the ViewModel, startJellyHover() always cancels
        // the previous task first — only one task runs regardless of view count.
        .onChange(of: vm.isDragHovering, initial: true) { _, hovering in
            if hovering { vm.startJellyHover() } else { vm.stopJellyHover() }
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
        setStage(.loading(url: fileURL, action: action))
        Task {
            do {
                let content: String = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imageURL: URL? = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text = try await provider.complete(action: action, content: content, imageURL: imageURL)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    /// Set stage safely: always deferred one runloop tick so the change
    /// never fires inside an active AppKit or SwiftUI layout pass.
    private func setStage(_ stage: OverlayViewModel.Stage) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                OverlayViewModel.shared.stage = stage
            }
        }
    }
}

// MARK: - Stage 3: Two-column layout (GeometryReader rebuild)
//
// Previous version used fixed pixel widths (219 + 1 + 280 = 500 pt hard-coded).
// Any mismatch between those values and the actual NSHostingView width caused
// NSHostingView's rectangular clip to win over the SwiftUI RoundedRectangle clip
// AND caused NSAnimationContext frame animation to drive the window through
// intermediate sizes where the fixed-width constraints couldn't be satisfied →
// recursive "Update Constraints in Window" crash.
//
// This rebuild uses GeometryReader so the columns are always proportional to
// whatever size the window actually is — no overflow, no fixed-width assumptions.

private struct TwoColumnView: View {
    let fileURL: URL
    let provider: any AIProvider
    @ObservedObject private var vm = OverlayViewModel.shared

    var body: some View {
        GeometryReader { geo in
            let totalW  = geo.size.width
            let divW    = CGFloat(1)
            let leftW   = floor(totalW * 0.42)
            let rightW  = totalW - leftW - divW

            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(width: leftW, alignment: .topLeading)
                    .clipped()

                Color.white.opacity(0.08)
                    .frame(width: divW)

                rightColumn
                    .frame(width: rightW, alignment: .topLeading)
                    .clipped()
            }
            .frame(width: totalW, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // ── Left: file header + chip list ────────────────────────────────────────

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            FileHeaderView(fileURL: fileURL)

            Text("Suggested")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.35))

            VStack(alignment: .leading, spacing: 6) {
                ForEach(FileInspector.suggestedActions(for: fileURL)) { action in
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
        .padding(15)
    }

    // ── Right: result card + prompt field + follow-ups ────────────────────────

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            resultCard

            TextField("Ask anything…", text: $vm.customPrompt)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .onSubmit { runCustomPrompt() }

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

            // Handoff button — visible once we have a result
            if case .result(let url, let act, let text) = vm.stage {
                HandoffButton(fileURL: url, action: act, result: text)
                    .padding(.top, 4)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .padding(14)
    }

    // ── Result / loading / error card ─────────────────────────────────────────

    @ViewBuilder
    private var resultCard: some View {
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
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .result(_, _, let text):
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownText(source: text)
                    .padding(12)
            }
            .frame(maxHeight: 200)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .error(_, let msg):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13))
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

        default:
            EmptyView()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

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
        setStage(.loading(url: fileURL, action: action))
        Task {
            do {
                let content = FileInspector.isImageFile(fileURL)
                    ? "Analyse the attached image."
                    : (try await FileContentExtractor.extract(from: fileURL))
                let imgURL = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text   = try await provider.complete(action: action, content: content, imageURL: imgURL)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        let action = AIAction.summariseBullets
        vm.customPrompt = ""
        setStage(.loading(url: fileURL, action: action))
        Task {
            do {
                let body = FileInspector.isImageFile(fileURL)
                    ? "Analyse as requested: \(prompt)"
                    : "\(prompt)\n\n---\n\(try await FileContentExtractor.extract(from: fileURL))"
                let imgURL = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text   = try await provider.complete(action: action, content: body, imageURL: imgURL)
                setStage(.result(url: fileURL, action: action, text: text))
            } catch {
                setStage(.error(url: fileURL, message: error.localizedDescription))
            }
        }
    }

    /// Always deferred one runloop tick — never called during an active layout pass.
    private func setStage(_ stage: OverlayViewModel.Stage) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                OverlayViewModel.shared.stage = stage
            }
        }
    }
}

// MARK: - Shared subviews

/// File header that doubles as a drag-source.
/// Drag the icon or filename to move/copy the file out of the shelf.
private struct FileHeaderView: View {
    let fileURL: URL
    @State private var isHoveringIcon = false

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 26, height: 26)
                // Drag-out: set flag so AppDelegate can close the session when drag ends
                .onDrag {
                    OverlayViewModel.shared.isDraggingOut = true
                    return NSItemProvider(object: fileURL as NSURL)
                }
                .onHover { hovering in
                    isHoveringIcon = hovering
                    if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .overlay(alignment: .bottomTrailing) {
                    // Tiny grab-dot indicator — appears on hover
                    if isHoveringIcon {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 6, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(2)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .offset(x: 3, y: 3)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: isHoveringIcon)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
            Spacer()
        }
    }
}

// MARK: - Close button

/// Small × button — closes the current shelf session.
/// Posts a notification so AppDelegate can coordinate teardown.
private struct CloseButton: View {
    @State private var isHovered = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .hideOverlay, object: nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .heavy))
                .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.45))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(isHovered ? 0.16 : 0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Handoff button

/// "Continue in [Provider]" — copies context + opens the AI app.
/// Morphs into a ✓ confirmation pill for 2 seconds after tapping.
private struct HandoffButton: View {
    let fileURL: URL
    let action: AIAction
    let result: String

    @State private var didTap = false

    var body: some View {
        Button {
            guard !didTap else { return }
            HandoffManager.handOff(fileURL: fileURL, action: action, result: result)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) { didTap = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { didTap = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: didTap ? "checkmark" : HandoffManager.providerIcon())
                    .font(.system(size: 9, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))

                Text(didTap
                     ? "Copied · check clipboard"
                     : "Continue in \(HandoffManager.providerName())")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)

                if !didTap {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundColor(.white.opacity(didTap ? 1.0 : 0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(
                didTap
                    ? Color.green.opacity(0.18)
                    : Color.white.opacity(0.05)
            )
            .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: didTap)
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
