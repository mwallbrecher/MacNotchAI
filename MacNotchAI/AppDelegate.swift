import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: OverlayWindow?
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        DragMonitor.shared.startMonitoring()
        observeDragState()
        observeStageChanges()
    }

    // MARK: - Observations

    private func observeDragState() {
        Publishers.CombineLatest(
            DragMonitor.shared.$isDraggingFile,
            DragMonitor.shared.$draggedFileURL
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] isDragging, fileURL in
            guard let self else { return }
            let vm = OverlayViewModel.shared

            if let url = fileURL {
                // Stage 2: file dropped in the trigger zone
                vm.setChips(url: url)
                self.ensureOverlayVisible()
            } else if isDragging {
                // Stage 1: file being dragged somewhere on screen
                if case .waitingForDrop = vm.stage { } else { vm.reset() }
                self.ensureOverlayVisible()
            } else {
                // Drag ended without a drop on our zone — dismiss
                self.hideOverlay()
            }
        }
        .store(in: &cancellables)
    }

    private func observeStageChanges() {
        OverlayViewModel.shared.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                // Give SwiftUI one layout pass before measuring the hosting view.
                DispatchQueue.main.async { self?.resizeOverlay(for: stage) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay lifecycle

    private func ensureOverlayVisible() {
        if overlayWindow == nil {
            let window = OverlayWindow()
            let hostingView = NSHostingView(
                rootView: OverlayView(provider: resolveProvider())
            )
            window.contentView = hostingView
            overlayWindow = window
        }

        overlayWindow?.show()
        resizeOverlay(for: OverlayViewModel.shared.stage)
        startDismissMonitors()
    }

    private func hideOverlay() {
        stopDismissMonitors()
        overlayWindow?.dismissAnimated()
        OverlayViewModel.shared.reset()
    }

    // MARK: - Window sizing

    /// Computes the target size for each stage and animates the window.
    private func resizeOverlay(for stage: OverlayViewModel.Stage) {
        guard let window = overlayWindow, window.isVisible else { return }

        let size: CGSize
        let anchorAtNotchCenter: Bool

        switch stage {
        case .waitingForDrop:
            size = CGSize(width: 240, height: 68)
            anchorAtNotchCenter = false

        case .chips(_, let actions):
            let chipCount = min(actions.count, 6)
            let height = 44 + 24 + CGFloat(chipCount) * 38 + 36   // header + label + chips + padding
            size = CGSize(width: 280, height: max(height, 180))
            anchorAtNotchCenter = true

        case .loading:
            // Right column shows a spinner — use a comfortable fixed size.
            size = CGSize(width: 500, height: 280)
            anchorAtNotchCenter = true

        case .result(_, _, let text):
            // Estimate result height: each ~55-char line ≈ 20pt.
            let lines = max(text.components(separatedBy: "\n").count,
                            text.count / 55)
            let resultHeight = min(CGFloat(lines) * 20, 220)
            let height = 44 + resultHeight + 52 + 28 + 3 * 38 + 32   // header + result + input + follow-up
            size = CGSize(width: 500, height: min(max(height, 320), 520))
            anchorAtNotchCenter = true

        case .error:
            size = CGSize(width: 500, height: 240)
            anchorAtNotchCenter = true
        }

        window.animateTo(size: size, anchorAtNotchCenter: anchorAtNotchCenter)
    }

    // MARK: - Dismiss monitors (Escape + outside click)

    private func startDismissMonitors() {
        stopDismissMonitors()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.hideOverlay() }
            }
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let window = self.overlayWindow else { return }
                if !NSPointInRect(NSEvent.mouseLocation, window.frame) {
                    self.hideOverlay()
                }
            }
        }
    }

    private func stopDismissMonitors() {
        if let m = escapeMonitor      { NSEvent.removeMonitor(m); escapeMonitor      = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    // MARK: - Accessibility permission

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted { showAccessibilityOnboarding() }
    }

    private func showAccessibilityOnboarding() {
        let alert = NSAlert()
        alert.messageText    = "One permission needed"
        alert.informativeText = "AI Drop needs Accessibility access to detect when you drag files.\n\nOpen System Settings → Privacy & Security → Accessibility and enable AI Drop."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
    }
}

// MARK: - Provider resolution

func resolveProvider() -> any AIProvider {
    let raw  = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    let type = AIProviderType(rawValue: raw) ?? .groq

    switch type {
    case .groq:
        return GroqProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.groq") ?? "")
    case .anthropic:
        return AnthropicProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.anthropic") ?? "")
    case .openai:
        return OpenAIProvider(apiKey: KeychainManager.shared.load(service: "com.aidrop.openai") ?? "")
    case .ollama:
        return OllamaProvider()
    }
}
