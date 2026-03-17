import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlayWindow: OverlayWindow?
    private var cancellables = Set<AnyCancellable>()
    private var escapeMonitor: Any?
    private var outsideClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        DragMonitor.shared.startMonitoring()

        DragMonitor.shared.$draggedFileURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                if let url = url {
                    self?.showOverlay(for: url)
                } else {
                    self?.hideOverlay()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay Management

    private func showOverlay(for url: URL) {
        let provider = resolveProvider()
        let actions = FileInspector.suggestedActions(for: url)

        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }

        let hostingView = NSHostingView(
            rootView: OverlayView(fileURL: url, actions: actions, provider: provider)
        )
        overlayWindow?.contentView = hostingView
        overlayWindow?.showAtTopCenter()

        startDismissMonitors()
    }

    private func hideOverlay() {
        stopDismissMonitors()
        overlayWindow?.dismissAnimated()
    }

    private func startDismissMonitors() {
        stopDismissMonitors()

        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor [weak self] in
                    self?.dismissOverlay()
                }
            }
        }

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let window = self.overlayWindow else { return }
                let loc = NSEvent.mouseLocation
                if !NSPointInRect(loc, window.frame) {
                    self.dismissOverlay()
                }
            }
        }
    }

    private func stopDismissMonitors() {
        if let m = escapeMonitor { NSEvent.removeMonitor(m); escapeMonitor = nil }
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
    }

    func dismissOverlay() {
        DragMonitor.shared.draggedFileURL = nil
    }

    // MARK: - Accessibility Permission

    func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        )
        if !trusted {
            showAccessibilityOnboarding()
        }
    }

    private func showAccessibilityOnboarding() {
        let alert = NSAlert()
        alert.messageText = "One permission needed"
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

// MARK: - Provider Resolution

func resolveProvider() -> any AIProvider {
    let raw = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    let type = AIProviderType(rawValue: raw) ?? .groq

    switch type {
    case .groq:
        let key = KeychainManager.shared.load(service: "com.aidrop.groq") ?? ""
        return GroqProvider(apiKey: key)
    case .anthropic:
        let key = KeychainManager.shared.load(service: "com.aidrop.anthropic") ?? ""
        return AnthropicProvider(apiKey: key)
    case .openai:
        let key = KeychainManager.shared.load(service: "com.aidrop.openai") ?? ""
        return OpenAIProvider(apiKey: key)
    case .ollama:
        return OllamaProvider()
    }
}
