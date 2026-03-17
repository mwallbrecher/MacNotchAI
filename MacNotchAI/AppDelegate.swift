import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: OverlayWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        DragMonitor.shared.startMonitoring()
        observeDragState()
        observeStageChanges()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOnboarding),
            name: .showOnboarding, object: nil
        )

        // Show onboarding on very first launch.
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showOnboarding()
            }
        }
    }

    @objc private func handleShowOnboarding() {
        showOnboarding()
    }

    // MARK: - Drag observation
    // Stage 1 → pill visible while any file is being dragged.
    // Stage 2 → triggered by a physical DROP on the pill (DroppableHostingView).

    private func observeDragState() {
        DragMonitor.shared.$isDraggingFile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                guard let self else { return }
                let vm = OverlayViewModel.shared
                if isDragging {
                    // Only show the pill if we're not already in a later stage.
                    if case .waitingForDrop = vm.stage {
                        self.ensureOverlayVisible()
                    }
                } else {
                    // Drag ended without dropping on our pill → dismiss.
                    if case .waitingForDrop = vm.stage {
                        self.hideOverlay()
                    }
                    // Stage 2/3: keep the overlay visible.
                }
            }
            .store(in: &cancellables)
    }

    private func observeStageChanges() {
        OverlayViewModel.shared.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                DispatchQueue.main.async { self?.resizeOverlay(for: stage) }
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay lifecycle

    private func ensureOverlayVisible() {
        if overlayWindow == nil {
            let window = OverlayWindow()
            // Use DroppableHostingView so the pill accepts real file drops.
            let hostingView = DroppableHostingView(
                rootView: OverlayView(provider: resolveProvider())
            )
            window.contentView = hostingView
            overlayWindow = window
        }
        overlayWindow?.show()
        resizeOverlay(for: OverlayViewModel.shared.stage)
        startDismissMonitors()
    }

    func hideOverlay() {
        stopDismissMonitors()
        overlayWindow?.dismissAnimated()
        overlayWindow = nil   // recreate next drag so provider is always fresh
        OverlayViewModel.shared.reset()
    }

    // MARK: - Window sizing

    private func resizeOverlay(for stage: OverlayViewModel.Stage) {
        guard let window = overlayWindow, window.isVisible else { return }

        let size: CGSize
        let anchorLeft: Bool   // true = pin left column under notch centre

        switch stage {
        case .waitingForDrop:
            size = CGSize(width: 240, height: 68)
            anchorLeft = false

        case .chips(_, let actions):
            let n = min(actions.count, 6)
            let h = 18 + 44 + 20 + CGFloat(n) * 40 + 18
            size = CGSize(width: 280, height: max(h, 180))
            anchorLeft = true

        case .loading:
            size = CGSize(width: 500, height: 260)
            anchorLeft = true

        case .result(_, _, let text):
            let lines = max(text.components(separatedBy: "\n").count, text.count / 55)
            let resultH = min(CGFloat(lines) * 20, 200)
            let h = 18 + 44 + resultH + 44 + 24 + 3 * 40 + 18
            size = CGSize(width: 500, height: min(max(h, 320), 500))
            anchorLeft = true

        case .error:
            size = CGSize(width: 500, height: 220)
            anchorLeft = true
        }

        window.animateTo(size: size, anchorAtNotchCenter: anchorLeft)
    }

    // MARK: - Dismiss monitors

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
        if let m = escapeMonitor       { NSEvent.removeMonitor(m); escapeMonitor       = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView {
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Welcome to AI Drop"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.center()
            onboardingWindow = win
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted { showAccessibilityOnboarding() }
    }

    private func showAccessibilityOnboarding() {
        let alert = NSAlert()
        alert.messageText     = "One permission needed"
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

// MARK: - Notification names

extension Notification.Name {
    static let showOnboarding = Notification.Name("com.aidrop.showOnboarding")
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
