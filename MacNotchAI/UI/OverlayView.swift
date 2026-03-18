import SwiftUI

// MARK: - Root overlay view

struct OverlayView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    let provider: any AIProvider

    @AppStorage("uiScale") private var uiScaleRaw = UIScale.small.rawValue
    private var scale: CGFloat { UIScale(rawValue: uiScaleRaw)?.multiplier ?? 1.0 }

    // Entry animation gate. Set to true by onAppear on the first frame.
    // Never reset to false — collapse is driven by vm.isCollapsing instead,
    // so both directions share one scaleEffect without a @State write from outside.
    @State private var appeared = false

    // Shared namespace for the close button matchedGeometryEffect —
    // animates the X from FileHeaderView (stages 1-2) to the result icon bar (stage 3).
    @Namespace private var closeNS

    // True = pill / card is at full visual scale.
    // False = collapsed sliver (either before entry or during/after close animation).
    private var isAtFullScale: Bool { appeared && !vm.isCollapsing }

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
                // No ZStack overlay — CloseButton lives inside FileHeaderView
                // so it is part of the layout flow and can never be obscured
                // by a ScrollView scrollbar or any other sibling view.
                Group {
                    switch vm.stage {
                    case .chips(let url, let actions):
                        ChipsColumnView(fileURL: url, actions: actions, provider: provider, closeNS: closeNS)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.88, anchor: .top)
                                    .combined(with: .opacity),
                                removal: .scale(scale: 0.92, anchor: .top)
                                    .combined(with: .opacity)
                            ))
                    case .loading(let url, _), .result(let url, _, _), .error(let url, _):
                        TwoColumnView(fileURL: url, provider: provider, closeNS: closeNS)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity
                            ))
                    default:
                        EmptyView()
                    }
                }
                .liquidGlass(cornerRadius: cornerRadius, tintOpacity: 0.60)
                .transition(.identity)
            }
        }
        .environment(\.uiScale, scale)
        .compositingGroup()

        // ── Content hide on collapse ──────────────────────────────────────────
        // Snap text/icons to invisible the moment isCollapsing fires so the
        // user never sees content squishing during the Y-scale collapse below.
        // Uses a dedicated fast ease-out that overrides the ambient withAnimation
        // spring coming from AppDelegate.hideOverlay() for just this property.
        .opacity(vm.isCollapsing ? 0 : 1)
        .animation(.easeOut(duration: 0.06), value: vm.isCollapsing)

        // ── Entry / collapse scale ────────────────────────────────────────────
        // Content is already gone; only the bare background shell collapses.
        // Entry  : appeared false→true on onAppear → bouncy pop-in spring.
        // Dismiss: isCollapsing false→true via withAnimation in hideOverlay()
        //          → fast critically-damped spring, no overshoot, no bounce.
        // Reuse  : reset() sets isCollapsing=false while appeared stays true
        //          → isAtFullScale flips true, entry spring re-plays.
        // NOTE: scaleEffect is a purely visual transform — NSView bounds and
        // the drag hitbox are always the full 288×96 canvas.
        .scaleEffect(x: isAtFullScale ? 1.0 : 0.78,
                     y: isAtFullScale ? 1.0 : 0.02,
                     anchor: .top)
        .animation(.spring(response: 0.36, dampingFraction: 0.58), value: appeared)

        // ── Jelly wobble (stage 1 only) ──────────────────────────────────────
        // Driven by direct withAnimation calls in OverlayViewModel. No Tasks here.
        // In stages 2-4 both values are always 1.0, so this is a no-op.
        // Stage-change animation smoothly returns jelly to 1×1 when pill exits.
        .scaleEffect(
            x: vm.stage.tag == 0 ? vm.jellyX : 1.0,
            y: vm.stage.tag == 0 ? vm.jellyY : 1.0,
            anchor: .top
        )
        .animation(.spring(response: 0.30, dampingFraction: 0.70), value: vm.stage.tag)

        // Trigger entry animation. onAppear fires before the first committed frame
        // so SwiftUI batches the state change and the animation together — no Task
        // scheduling, no async race, no multi-phase timing.
        .onAppear { appeared = true }
    }
}

// MARK: - Stage 1: Waiting pill

private struct WaitingPillView: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 10 * scale) {
            // Icon morphs when file hovers
            Image(systemName: vm.isDragHovering ? "arrow.down.circle.fill" : "arrow.down.circle")
                .font(.system(size: 18 * scale, weight: .semibold))
                .foregroundColor(vm.isDragHovering ? .white : .white.opacity(0.75))
                .contentTransition(.symbolEffect(.replace))

            Text(vm.isDragHovering ? "  Release file " : "Drop file here")
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundColor(.white)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: vm.isDragHovering)
        }
        .padding(.horizontal, 22 * scale)
        .padding(.vertical, 18 * scale)
        // Height = 68 × scale so cornerRadius = 34 × scale → perfect stadium shape.
        .frame(width: 240 * scale, height: 68 * scale)
        // Background + clip live HERE (inside WaitingPillView), not on the outer
        // canvas in OverlayView. The outer 288×96 canvas stays transparent so the
        // wobble scaleEffect (applied after this clip in OverlayView) can overflow
        // freely without hitting the window clip boundary.
        //
        // Hover: apple system-blue tint fades in; tintOpacity drops slightly so the
        // blue colour reads through the dark base rather than washing out.
        .liquidGlass(
            cornerRadius: 34 * scale,
            tintOpacity: vm.isDragHovering ? 0.42 : 0.58,
            colorTint: vm.isDragHovering ? Color.accentColor : .clear
        )
        .animation(.easeInOut(duration: 0.18), value: vm.isDragHovering)
        // Jelly: call withAnimation directly in the VM — no Tasks, no sleep timers.
        // initial: false so it doesn't fire on view creation and call stopJellyHover()
        // immediately (which was spawning a wobble Task with jellyX=0.94 before any
        // hover occurred, racing against the entry animation → EXC_BREAKPOINT).
        .onChange(of: vm.isDragHovering, initial: false) { _, hovering in
            if hovering { vm.startJellyHover() } else { vm.stopJellyHover() }
        }
    }
}

// MARK: - Stage 2: Chips column only

private struct ChipsColumnView: View {
    let fileURL: URL
    let actions: [AIAction]
    let provider: any AIProvider
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            FileHeaderView(fileURL: fileURL, closeNS: closeNS)
                .zIndex(100)   // floating name badge must render above chips below it

            if vm.isChipsExpanded {
                Text("Suggested")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .foregroundColor(.white.opacity(0.35))
                    .transition(.asymmetric(
                        // Delay insertion so the window finishes resizing before
                        // text pops in — prevents content appearing in a too-small frame.
                        insertion: .opacity.animation(.easeOut(duration: 0.14).delay(0.18)),
                        removal:   .opacity.animation(.easeIn(duration: 0.08))
                    ))

                VStack(alignment: .leading, spacing: 6 * scale) {
                    ForEach(actions) { action in
                        ActionChip(title: action.rawValue, isLoading: false) {
                            runAction(action)
                        }
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top))
                                       .animation(.spring(response: 0.28, dampingFraction: 0.75).delay(0.20)),
                    removal:   .opacity.animation(.easeIn(duration: 0.08))
                ))
            }

            PromptField(text: $vm.customPrompt, onSubmit: runCustomPrompt)
        }
        .padding(18 * scale)
        .frame(width: 280 * scale, alignment: .topLeading)
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

    private func runCustomPrompt() {
        let prompt = vm.customPrompt.trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else { return }
        vm.customPrompt = ""
        vm.cachedResult = nil   // new query replaces any saved result
        // Use .freeform so the system prompt asks the AI to *answer the question*
        // rather than blindly summarising. The user's prompt leads the content
        // so the AI sees it before the document text.
        let action = AIAction.freeform
        setStage(.loading(url: fileURL, action: action))
        Task {
            do {
                let body = FileInspector.isImageFile(fileURL)
                    ? "Question: \(prompt)"
                    : "Question: \(prompt)\n\n--- Document ---\n\(try await FileContentExtractor.extract(from: fileURL))"
                let imgURL = FileInspector.isImageFile(fileURL) ? fileURL : nil
                let text   = try await provider.complete(action: action, content: body, imageURL: imgURL)
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
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale

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
        VStack(alignment: .leading, spacing: 10 * scale) {
            FileHeaderView(fileURL: fileURL, closeNS: closeNS)
                .zIndex(100)   // floating name badge must render above chips below it

            Text("Suggested")
                .font(.system(size: 11 * scale, weight: .medium))
                .foregroundColor(.white.opacity(0.35))

            VStack(alignment: .leading, spacing: 6 * scale) {
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
        .padding(15 * scale)
    }

    // ── Right: icon bar (result only) + result card + prompt field + follow-ups ─

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            // Icon bar — only in result state; close button animates here from header
            if case .result(_, let action, let text) = vm.stage {
                resultIconBar(action: action, text: text)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top))
                                           .animation(.spring(response: 0.30, dampingFraction: 0.70).delay(0.06)),
                        removal:   .opacity.animation(.easeIn(duration: 0.08))
                    ))
            }

            resultCard

            PromptField(text: $vm.customPrompt, onSubmit: runCustomPrompt)

            if case .result = vm.stage {
                // ── Follow-up header + collapse toggle ───────────────────────
                HStack {
                    Text("Follow up")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.35))
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                            vm.isFollowupsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: vm.isFollowupsExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 7 * scale, weight: .bold))
                            .foregroundColor(.white.opacity(0.45))
                            .frame(width: 18 * scale, height: 18 * scale)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(vm.isFollowupsExpanded ? "Hide follow-ups" : "Show follow-ups")
                }

                if vm.isFollowupsExpanded {
                    VStack(alignment: .leading, spacing: 6 * scale) {
                        ForEach(followUpActions) { action in
                            ActionChip(title: action.rawValue, isLoading: false) {
                                runAction(action)
                            }
                        }
                    }
                    .transition(.asymmetric(
                        // Delay so chips pop in after the ScrollView has shrunk
                        // to its capped height and the layout has stabilised.
                        insertion: .opacity.combined(with: .move(edge: .top))
                                           .animation(.spring(response: 0.26, dampingFraction: 0.75).delay(0.18)),
                        removal:   .opacity.animation(.easeIn(duration: 0.08))
                    ))
                }
            }

            Spacer(minLength: 0)

            // Handoff button — visible once we have a result
            if case .result(let url, let act, let text) = vm.stage {
                HandoffButton(fileURL: url, action: act, result: text)
                    .padding(.top, 4 * scale)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            }
        }
        .padding(14 * scale)
    }

    // ── Stage-3 icon bar ──────────────────────────────────────────────────────
    // Sits above the ScrollView in result state.
    // Buttons: ← back | copy | repeat | [spacer] | ✕ close (matchedGeometryEffect)

    @ViewBuilder
    private func resultIconBar(action: AIAction, text: String) -> some View {
        HStack(spacing: 6 * scale) {
            // Back to stage 2 (chips) — saves result so → can restore it
            ResultIconButton(systemName: "arrow.left", tooltip: "Back to prompts") {
                let snapshot = vm.stage   // capture .result(...) before navigation
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                    OverlayViewModel.shared.navigateBackToChips(savingResult: snapshot, url: fileURL)
                }
            }

            // Copy AI reply to clipboard
            ResultIconButton(systemName: "doc.on.doc", tooltip: "Copy reply") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

            // Re-run the last action
            ResultIconButton(systemName: "arrow.clockwise", tooltip: "Repeat prompt") {
                runAction(action)
            }

            Spacer(minLength: 0)

            // Close — matched so it animates from FileHeaderView's position
            CloseButton()
                .matchedGeometryEffect(id: "closeBtn", in: closeNS)
        }
    }

    // ── Result / loading / error card ─────────────────────────────────────────

    @ViewBuilder
    private var resultCard: some View {
        switch vm.stage {
        case .loading:
            HStack(spacing: 8 * scale) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.62 * scale)
                    .tint(.white)
                Text("Thinking…")
                    .font(.system(size: 13 * scale))
                    .foregroundColor(.white.opacity(0.45))
            }
            .padding(12 * scale)
            .frame(maxWidth: .infinity, minHeight: 56 * scale, alignment: .leading)
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.15)

        case .result(_, _, let text):
            ScrollView(.vertical, showsIndicators: true) {
                MarkdownText(source: text)
                    .padding(12 * scale)
            }
            // When follow-ups are hidden the chips' vertical space is freed.
            // .infinity lets the ScrollView grow to fill it; layoutPriority(1)
            // ensures it wins space over the Spacer below it.
            // When follow-ups are visible it's capped so chips stay on screen.
            .frame(maxHeight: vm.isFollowupsExpanded ? 200 * scale : .infinity)
            .layoutPriority(1)
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: vm.isFollowupsExpanded)
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.60)

        case .error(_, let msg):
            HStack(alignment: .top, spacing: 8 * scale) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                    .font(.system(size: 13 * scale))
                Text(msg)
                    .font(.system(size: 12 * scale))
                    .foregroundColor(.white.opacity(0.80))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12 * scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.20))
            .liquidGlass(cornerRadius: 10 * scale, tintOpacity: 0.08)

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
        vm.cachedResult = nil   // new action replaces any saved result
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
        vm.customPrompt = ""
        vm.cachedResult = nil   // new query replaces any saved result
        // Use .freeform so the system prompt asks the AI to *answer the question*
        // rather than blindly summarising. The user's prompt leads the content
        // so the AI sees it before the document text.
        let action = AIAction.freeform
        setStage(.loading(url: fileURL, action: action))
        Task {
            do {
                let body = FileInspector.isImageFile(fileURL)
                    ? "Question: \(prompt)"
                    : "Question: \(prompt)\n\n--- Document ---\n\(try await FileContentExtractor.extract(from: fileURL))"
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
            // Collapse follow-ups whenever a fresh result arrives so the section
            // starts closed and the user can expand it on demand.
            if case .result = stage { OverlayViewModel.shared.isFollowupsExpanded = false }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                OverlayViewModel.shared.stage = stage
            }
        }
    }
}

// MARK: - Shared subviews

/// File header: unified file-info pill on the left, collapse toggle + close on the right.
/// The entire pill (icon + name + share) is drag-source for moving the file out.
/// In stage 3 (result) the close button is hidden here — it lives in the icon bar
/// above the ScrollView instead, and animates there via matchedGeometryEffect.
private struct FileHeaderView: View {
    let fileURL: URL
    let closeNS: Namespace.ID
    @ObservedObject private var vm = OverlayViewModel.shared
    @State private var isHoveringGroup    = false
    @State private var isHoveringCollapse = false
    @Environment(\.uiScale) private var scale

    // Async icon — placeholder avoids main-thread stall on first render.
    @State private var fileIcon: NSImage = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()

    var body: some View {
        HStack(spacing: 8 * scale) {

            // ── File info pill ───────────────────────────────────────────────
            // Icon + name + share in a rounded rect that reads as one "file object".
            // The pill size NEVER changes — full name is shown in a floating badge
            // overlaid below so layout is not disturbed.
            HStack(spacing: 8 * scale) {
                // File icon (async load)
                Image(nsImage: fileIcon)
                    .resizable()
                    .frame(width: 24 * scale, height: 24 * scale)
                    .onAppear {
                        Task { @MainActor in
                            fileIcon = NSWorkspace.shared.icon(forFile: fileURL.path)
                        }
                    }

                // Name + "Drag to move" — always truncated, never grows the pill.
                VStack(alignment: .leading, spacing: 1 * scale) {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 12 * scale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Drag to move")
                        .font(.system(size: 9 * scale, weight: .regular))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)

                ShareButton(fileURL: fileURL)
            }
            .padding(.horizontal, 9 * scale)
            .padding(.vertical, 7 * scale)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(Color.white.opacity(isHoveringGroup ? 0.08 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5)
                    )
            )
            .onDrag {
                vm.isDraggingOut = true
                return NSItemProvider(object: fileURL as NSURL)
            }
            .onHover { isHoveringGroup = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHoveringGroup)
            .help("Drag to move file elsewhere")
            // ── Floating full-name badge ─────────────────────────────────────
            // Pure overlay — zero effect on the pill's own frame or the card layout.
            // Appears below the pill, floats over whatever content is beneath it.
            .overlay(alignment: .bottomLeading) {
                if isHoveringGroup {
                    Text(fileURL.lastPathComponent)
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 9 * scale)
                        .padding(.vertical, 6 * scale)
                        .frame(maxWidth: 220 * scale, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                .fill(Color(white: 0.10).opacity(0.96))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                                )
                                .shadow(color: .black.opacity(0.40), radius: 8, x: 0, y: 3)
                        )
                        .offset(y: 38 * scale)   // float below the pill row
                        .zIndex(200)
                        .transition(
                            .scale(scale: 0.90, anchor: .topLeading)
                             .combined(with: .opacity)
                             .animation(.spring(response: 0.22, dampingFraction: 0.72))
                        )
                }
            }

            Spacer(minLength: 0)

            // ── Collapse suggestions toggle (chips stage only) ───────────────
            if vm.stage.tag == 1 {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.65)) {
                        vm.isChipsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: vm.isChipsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(isHoveringCollapse ? 1.0 : 0.60))
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(isHoveringCollapse ? 0.12 : 0.06))
                                .overlay(Circle().strokeBorder(
                                    Color.white.opacity(isHoveringCollapse ? 0.22 : 0.12),
                                    lineWidth: 0.5
                                ))
                        )
                }
                .buttonStyle(.plain)
                .onHover { isHoveringCollapse = $0 }
                .animation(.easeInOut(duration: 0.12), value: isHoveringCollapse)
                .help(vm.isChipsExpanded ? "Hide suggestions" : "Show suggestions")
            }

            // ── Forward to cached result (chips stage only) ──────────────────
            // Shown after the user navigated back with ← so they can restore
            // the previous AI answer without re-running the request.
            if vm.stage.tag == 1, let cached = vm.cachedResult {
                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                        OverlayViewModel.shared.stage = cached
                        OverlayViewModel.shared.cachedResult = nil
                    }
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8 * scale, weight: .bold))
                        .foregroundColor(.white.opacity(0.70))
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                        )
                }
                .buttonStyle(.plain)
                .help("Back to AI reply")
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.7).combined(with: .opacity)
                                               .animation(.spring(response: 0.26, dampingFraction: 0.68)),
                    removal:   .scale(scale: 0.7).combined(with: .opacity)
                                               .animation(.easeIn(duration: 0.10))
                ))
            }

            // ── Close ────────────────────────────────────────────────────────
            // Hidden in result stage — the button lives in the icon bar above
            // the ScrollView there, animating to its new position via
            // matchedGeometryEffect. In all other stages it stays here.
            if vm.stage.tag != 3 {
                CloseButton()
                    .matchedGeometryEffect(id: "closeBtn", in: closeNS)
            }
        }
    }
}

// MARK: - Share button

/// Circular share button in the file header.
/// Opens a native macOS Menu with AirDrop, Messages, Mail and Copy to Clipboard.
/// Uses NSSharingService so the OS handles service availability, accounts and sheets.
private struct ShareButton: View {
    let fileURL: URL
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Menu {
            // ── Sharing services ────────────────────────────────────────────
            Button {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [fileURL])
            } label: {
                Label("AirDrop", systemImage: "wifi")
            }
            .disabled(NSSharingService(named: .sendViaAirDrop) == nil)

            Button {
                NSSharingService(named: .composeMessage)?.perform(withItems: [fileURL])
            } label: {
                Label("Messages", systemImage: "message.fill")
            }
            .disabled(NSSharingService(named: .composeMessage) == nil)

            Button {
                NSSharingService(named: .composeEmail)?.perform(withItems: [fileURL])
            } label: {
                Label("Mail", systemImage: "envelope.fill")
            }
            .disabled(NSSharingService(named: .composeEmail) == nil)

            Divider()

            // ── Local action ─────────────────────────────────────────────────
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([fileURL as NSURL])
            } label: {
                Label("Copy to Clipboard", systemImage: "doc.on.doc.fill")
            }

        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                .frame(width: 22 * scale, height: 22 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(isHovered ? 0.22 : 0.12),
                                lineWidth: 0.5
                            )
                        )
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Share file")
    }
}

// MARK: - Result icon button

/// A small circular icon button used in the stage-3 icon bar above the ScrollView.
/// Matches the 22×22 pt size of CloseButton. Shows a tooltip label on hover.
private struct ResultIconButton: View {
    let systemName: String
    let tooltip: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8 * scale, weight: .semibold))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.60))
                .frame(width: 22 * scale, height: 22 * scale)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isHovered ? 0.12 : 0.06))
                        .overlay(
                            Circle().strokeBorder(
                                Color.white.opacity(isHovered ? 0.22 : 0.12),
                                lineWidth: 0.5
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help(tooltip)
    }
}

// MARK: - Close button

/// Small × button — closes the current shelf session.
/// Posts a notification so AppDelegate can coordinate teardown.
private struct CloseButton: View {
    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .hideOverlay, object: nil)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8 * scale, weight: .heavy))
                .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.80))
                .frame(width: 22 * scale, height: 22 * scale)
                // Red-tinted liquid glass circle — keeps the glassy depth
                // while clearly signalling a destructive/close action.
                .liquidGlassCircle(
                    tintOpacity: isHovered ? 0.30 : 0.45,
                    colorTint: Color(red: 1.0, green: 0.22, blue: 0.20)
                )
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
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button {
            guard !didTap else { return }
            HandoffManager.handOff(fileURL: fileURL, action: action, result: result)
            withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) { didTap = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { didTap = false }
            }
        } label: {
            HStack(spacing: 5 * scale) {
                Image(systemName: didTap ? "checkmark" : HandoffManager.providerIcon())
                    .font(.system(size: 9 * scale, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))

                Text(didTap
                     ? "Copied · check clipboard"
                     : "Continue in \(HandoffManager.providerName())")
                    .font(.system(size: 11 * scale, weight: .medium))
                    .lineLimit(1)

                if !didTap {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9 * scale, weight: .semibold))
                }
            }
            .foregroundColor(.white.opacity(didTap ? 1.0 : 0.45))
            .padding(.horizontal, 10 * scale)
            .padding(.vertical, 6 * scale)
            .frame(maxWidth: .infinity)
            .background(didTap ? Color.green.opacity(0.25) : Color.clear)
            .liquidGlassCapsule(tintOpacity: didTap ? 0.10 : 0.18)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.72), value: didTap)
    }
}

// MARK: - Prompt field with mic

/// Shared text-input bar used in both stage 2 (chips) and stage 3 (result right column).
/// The trailing mic button toggles native on-device speech recognition — no API tokens.
/// When the field has content a blue Send button springs out from behind the mic icon.
private struct PromptField: View {
    @Binding var text: String
    let onSubmit: () -> Void

    @ObservedObject private var speech = SpeechRecognizer.shared
    @Environment(\.uiScale) private var scale
    private var hasContent: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            TextField("Ask anything…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12 * scale))
                .foregroundColor(.white.opacity(0.75))
                .padding(.leading, 11 * scale)
                .padding(.vertical, 8 * scale)
                .onSubmit(onSubmit)

            // Send button — slides out from the trailing edge (from behind the mic)
            // when the field is non-empty, retreats back when cleared.
            if hasContent {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 24 * scale, height: 24 * scale)
                        .background(Color.blue)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 5 * scale)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    )
                )
                .help("Send prompt")
            }

            // Mic button
            Button {
                speech.toggle { recognised in text = recognised }
            } label: {
                Image(systemName: speech.isRecording ? "waveform" : "mic")
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(speech.isRecording ? .red : .white.opacity(0.40))
                    .frame(width: 34 * scale, height: 34 * scale)
                    .symbolEffect(.pulse, isActive: speech.isRecording)
            }
            .buttonStyle(.plain)
            .help(speech.isRecording ? "Stop recording" : "Dictate prompt")
        }
        // Flat background — no blur, no specular.  The card itself already
        // provides the glass context; the field sits inside it as a plain inset.
        .background(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        // Drive both the insertion/removal transition and any geometry changes
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: hasContent)
    }
}

// MARK: - Action chip

struct ActionChip: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .tint(.white)
                        .frame(width: 10 * scale, height: 10 * scale)
                }
                Text(title)
                    .font(.system(size: 12 * scale, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 8 * scale)
            // Flat capsule — no blur, no specular.  Simple stroke ring
            // differentiates the chip without competing with the card glass.
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.10 : 0.05))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0.10),
                                          lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
        .disabled(isLoading)
    }
}
