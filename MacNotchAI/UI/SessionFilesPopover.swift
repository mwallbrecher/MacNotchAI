import SwiftUI
import AppKit

/// Finder-like overview for the files currently staged in one Dragaway session.
/// Selection here is navigation focus only: Share and drag-out always keep the full
/// session payload. A file leaves the session only through physical Backspace.
struct SessionFilesPopover: View {
    @ObservedObject private var vm = OverlayViewModel.shared
    @Environment(\.uiScale) private var scale
    @State private var layout: Layout = .grid
    @State private var selectedPath: String?
    @State private var metadataByPath: [String: FilePresentationMetadata] = [:]
    @State private var keyboardFocusGeneration = 0

    private enum Layout {
        case grid
        case list
    }

    private var files: [URL] { vm.sessionFileURLs }

    private var fileSetKey: String {
        files.map(FilePresentationMetadataCache.key(for:)).joined(separator: "\u{1F}")
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .overlay(Color.white.opacity(0.10))

            Group {
                if layout == .grid {
                    grid
                } else {
                    list
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 440 * scale, height: 370 * scale, alignment: .top)
        .liquidGlass(cornerRadius: 16 * scale, tintOpacity: 0.78)
        .preferredColorScheme(.dark)
        .background(
            SessionFilesKeyboardResponder(
                focusGeneration: keyboardFocusGeneration,
                onPreview: previewSelection,
                onBackspace: removeSelection
            )
        )
        .onAppear {
            requestKeyboardFocus()
        }
        .task(id: fileSetKey) {
            let loaded = await FilePresentationMetadataCache.shared.metadata(for: files)
            guard !Task.isCancelled else { return }
            metadataByPath = loaded
        }
        .onChange(of: files.map(\.standardizedFileURL.path), initial: false) { _, paths in
            if let selectedPath, !paths.contains(selectedPath) {
                self.selectedPath = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10 * scale) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 15 * scale, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: 28 * scale, height: 28 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )

            Text(summary)
                .font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .monospacedDigit()

            Spacer(minLength: 8 * scale)

            HStack(spacing: 0) {
                layoutButton(.grid, symbol: "square.grid.2x2")
                layoutButton(.list, symbol: "list.bullet")
            }
            .padding(2 * scale)
            .background(
                RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                    .fill(Color.black.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                    )
            )
        }
        .padding(.horizontal, 15 * scale)
        .padding(.vertical, 11 * scale)
    }

    private func layoutButton(_ option: Layout, symbol: String) -> some View {
        Button {
            layout = option
            requestKeyboardFocus()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(layout == option ? .white : .white.opacity(0.48))
                .frame(width: 31 * scale, height: 25 * scale)
                .background(
                    RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
                        .fill(layout == option ? Color.white.opacity(0.17) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option == .grid ? "Grid View" : "List View")
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: 8 * scale),
                    count: 3
                ),
                spacing: 8 * scale
            ) {
                ForEach(files, id: \.standardizedFileURL.path) { file in
                    SessionFileGridItem(
                        fileURL: file,
                        detail: detail(for: file),
                        isSelected: isSelected(file)
                    ) {
                        select(file)
                    }
                }
            }
            .padding(10 * scale)
        }
        .scrollIndicators(.visible)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3 * scale) {
                ForEach(files, id: \.standardizedFileURL.path) { file in
                    SessionFileListItem(
                        fileURL: file,
                        detail: detail(for: file),
                        isSelected: isSelected(file)
                    ) {
                        select(file)
                    }
                }
            }
            .padding(8 * scale)
        }
        .scrollIndicators(.visible)
    }

    private var summary: String {
        let count = files.count
        let item = count == 1 ? "Document" : "Documents"
        return "\(count) \(item) · \(totalSizeLabel)"
    }

    private var totalBytes: Int64 {
        files.reduce(into: 0) { total, url in
            let key = FilePresentationMetadataCache.key(for: url)
            guard let size = metadataByPath[key]?.byteCount else { return }
            total += size
        }
    }

    private var totalSizeLabel: String {
        let snapshots = files.compactMap {
            metadataByPath[FilePresentationMetadataCache.key(for: $0)]
        }
        guard snapshots.count == files.count else { return "…" }
        guard snapshots.allSatisfy({ $0.isDirectory || $0.byteCount != nil }) else { return "—" }
        return Self.formattedSize(totalBytes)
    }

    private func detail(for url: URL) -> String {
        metadataByPath[FilePresentationMetadataCache.key(for: url)]?.detail ?? "—"
    }

    private func isSelected(_ url: URL) -> Bool {
        selectedPath == url.standardizedFileURL.path
    }

    private func select(_ url: URL) {
        selectedPath = url.standardizedFileURL.path
        requestKeyboardFocus()
    }

    private func requestKeyboardFocus() {
        keyboardFocusGeneration &+= 1
    }

    @discardableResult
    private func previewSelection() -> Bool {
        guard let selectedIndex else { return false }
        QuickLookController.shared.present(urls: files, current: selectedIndex)
        return true
    }

    @discardableResult
    private func removeSelection() -> Bool {
        guard !vm.isAITurnActive,
              files.count > 1,
              let selectedIndex else { return false }

        let file = files[selectedIndex]
        let remaining = files.enumerated().compactMap { index, url in
            index == selectedIndex ? nil : url
        }
        let nextIndex = min(selectedIndex, remaining.count - 1)
        selectedPath = remaining[nextIndex].standardizedFileURL.path

        // Stage changes during key handling can re-enter the SwiftUI/AppKit layout pass.
        // One main-queue hop preserves the overlay's established stage-write invariant.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) {
                vm.removeSessionFile(file)
            }
        }
        return true
    }

    private var selectedIndex: Int? {
        guard let selectedPath else { return nil }
        return files.firstIndex { $0.standardizedFileURL.path == selectedPath }
    }

    private static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// SwiftUI's popover focus can report a focused value before AppKit has installed a real first
/// responder. Keep Space/Backspace on one native responder owned by this popover instead of relying
/// on presentation timing or an app-wide key monitor.
private struct SessionFilesKeyboardResponder: NSViewRepresentable {
    let focusGeneration: Int
    let onPreview: () -> Bool
    let onBackspace: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(focusGeneration: focusGeneration)
    }

    func makeNSView(context: Context) -> KeyView {
        let view = KeyView()
        view.onPreview = onPreview
        view.onBackspace = onBackspace
        view.claimFocus()
        return view
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onPreview = onPreview
        nsView.onBackspace = onBackspace
        guard context.coordinator.focusGeneration != focusGeneration else { return }
        context.coordinator.focusGeneration = focusGeneration
        nsView.claimFocus()
    }

    final class Coordinator {
        var focusGeneration: Int

        init(focusGeneration: Int) {
            self.focusGeneration = focusGeneration
        }
    }

    final class KeyView: NSView {
        var onPreview: (() -> Bool)?
        var onBackspace: (() -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        // This native view owns keyboard delivery only. Returning nil keeps every mouse click in
        // SwiftUI's grid/list controls even though the responder spans the popover background.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            claimFocus()
        }

        func claimFocus() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasCommandModifier = !modifiers.isDisjoint(with: [.command, .control, .option])
            guard !hasCommandModifier else {
                super.keyDown(with: event)
                return
            }

            switch event.keyCode {
            case 49 where onPreview?() == true:       // Space
                return
            case 51 where onBackspace?() == true:     // Physical Backspace (⌫)
                return
            default:
                super.keyDown(with: event)
            }
        }
    }
}

private struct SessionFileGridItem: View {
    let fileURL: URL
    let detail: String
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale
    @State private var thumbnail = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()

    var body: some View {
        VStack(spacing: 5 * scale) {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 70 * scale, height: 72 * scale)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 10.5 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            Text(detail)
                .font(.system(size: 9 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, minHeight: 120 * scale)
        .background(selectionBackground(isSelected: isSelected, scale: scale))
        .contentShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onAppear {
            FileThumbnail.load(for: fileURL, size: 78 * scale) { thumbnail = $0 }
        }
    }
}

private struct SessionFileListItem: View {
    let fileURL: URL
    let detail: String
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.uiScale) private var scale
    @State private var thumbnail = NSImage(named: NSImage.multipleDocumentsName) ?? NSImage()

    var body: some View {
        HStack(spacing: 9 * scale) {
            Image(nsImage: thumbnail)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 29 * scale, height: 29 * scale)

            Text(fileURL.lastPathComponent)
                .font(.system(size: 11 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8 * scale)

            Text(detail)
                .font(.system(size: 9.5 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .padding(.horizontal, 9 * scale)
        .frame(maxWidth: .infinity, minHeight: 42 * scale)
        .background(selectionBackground(isSelected: isSelected, scale: scale))
        .contentShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onAppear {
            FileThumbnail.load(for: fileURL, size: 36 * scale) { thumbnail = $0 }
        }
    }
}

private func selectionBackground(isSelected: Bool, scale: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
        .fill(isSelected ? Color(nsColor: .systemBlue).opacity(0.18) : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                .strokeBorder(
                    isSelected ? Color(nsColor: .systemBlue).opacity(0.95) : Color.clear,
                    lineWidth: 1.5 * scale
                )
        )
}
