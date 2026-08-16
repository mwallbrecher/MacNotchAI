import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var overlayWindow: OverlayWindow?
    private var onboardingWindow: NSWindow?
    private var hotkeyPickerWindow: NSWindow?
    private var sessionSearchWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var exposeWindow: NSWindow?
    private var joinWindow: NSWindow?
    private var tutorialWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var startupToastWindow: NSPanel?
    private var statusItem: NSStatusItem?         // menu-bar icon (replaces MenuBarExtra)
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    /// Local keyDown monitor for the favorite-tool launch hotkeys (`Option+1…9`).
    /// Active only while a file is staged on the chips stage (Pillar 1).
    private var toolHotkeyMonitor: Any?
    private var dragOutEndTimer: Timer?          // polls mouse state after a drag-out gesture
    // Eased window growth while a reply streams — see growStreamHeight().
    private var streamGrowthTimer: Timer?
    private var streamGrowthTarget: CGFloat = 0
    private var streamGrowthCurrent: CGFloat = 0
    /// System-wide ⌃⌘V hotkey (Carbon) that opens the clipboard-history picker. Consumes
    /// the keystroke so the combo never leaks into the frontmost app. Live only while
    /// clipboard tracking is enabled.
    private let clipboardHotkey = GlobalHotkey()
    /// ⌃⌘E / ⌃⌘J — session sharing. Registered ONLY when a share service is configured:
    /// a Carbon hotkey swallows the combination system-wide, so claiming it while the
    /// feature cannot work would silently break those keys in every other app.
    private let exposeHotkey = GlobalHotkey()
    private let joinHotkey   = GlobalHotkey()
    /// ⌃⌘N — open a new session from the current clipboard (text / image / files).
    private let sessionHotkey = GlobalHotkey()
    /// ⌃⌘L — open the newest stable supported file from the user's watched folders.
    /// Registered only while the feature is enabled so disabling it releases the chord globally.
    private let recentFileHotkey = GlobalHotkey()
    /// At most one latest-file resolution may run at a time. The generation prevents a cancelled
    /// task's deferred cleanup from clearing a newer task installed after a settings change.
    private var recentFileOpenTask: Task<Void, Never>?
    private var recentFileOpenGeneration: UInt64 = 0

    // ── Dismiss-race protection ───────────────────────────────────────────────
    // When hideOverlay() fires, dismissAnimated() starts a 0.14 s alpha fade.
    // If a new drag begins during that window, the fading window is still alive
    // and its DroppableHostingView still observes OverlayViewModel.  A freshly
    // created second window produces two WaitingPillViews both calling jelly
    // animation methods → two concurrent withAnimation{} on the same bindings
    // → SwiftUI invariant violation → EXC_BREAKPOINT.
    //
    // Fix: DON'T nil overlayWindow in hideOverlay().  Instead issue a UUID token
    // that travels with the dismissAnimated completion closure.  ensureOverlayVisible()
    // can safely reuse the fading window by invalidating the token — the completion
    // closure's token-guard then skips orderOut/nil so the window stays alive.
    //
    // isWindowDismissing gates resizeOverlay() so a stage-change resize triggered
    // by reset() (e.g. chips→waitingForDrop) doesn't visually resize a fading window.
    private var dismissToken      = UUID()
    private var isWindowDismissing = false

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run the one-time hard-coded-model migration before onboarding can flip its
        // completion flag. That lets fresh installs use a current starting model while
        // existing installations keep their exact previous route.
        _ = AIModelCatalogStore.shared

        // Core Dragaway behavior requests no permissions. Drag detection, hotkeys,
        // the radial launcher, and Esc all use ungated APIs. The sole exception is
        // the default-off Enhanced Access setting: after explicit user intent it can
        // request event-posting access for Clipboard History paste-on-pick. Never
        // make any core path depend on that optional permission.
        DragMonitor.shared.startMonitoring()
        observeDragState()
        observeDragOutState()
        observeStageChanges()
        observeChipsExpanded()
        observeChipsTab()
        observeUserDragOffset()
        prewarmSwiftUI()
        setupStatusItem()

        // Create the overlay window ONCE and keep it parked (invisible, inside the
        // notch housing). Drag sources snapshot eligible destinations when their drag
        // BEGINS — only a window that already existed can receive Safari-tab drops.
        createParkedOverlay()

        // Auto-update (Sparkle). Instantiating starts the scheduled background check.
        _ = UpdaterController.shared

        // Clipboard history: poll the pasteboard + arm the ⌃⌘V picker hotkey (both gated
        // on the "Track Clipboard" toggle, default on).
        if ClipboardHistoryStore.isEnabled {
            ClipboardHistoryStore.shared.startMonitoring()
            registerClipboardHotkey()
        }

        // First-run tour: once onboarding is done, show the interactive tutorial once.
        // Restartable anytime from Settings → Help (fresh installs get it right after
        // onboarding via the .showTutorial post in OnboardingView).
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowTutorial),
            name: .showTutorial, object: nil
        )
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
           !UserDefaults.standard.bool(forKey: "tutorialShown") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showTutorial()
            }
        }

        // Capture features: ⌃⌘N clipboard→session hotkey + screenshot→session watcher.
        armCaptureFeatures()
        armRecentFileFeature()

        // Session sharing: ⌃⌘E expose / ⌃⌘J join.
        armSharingHotkeys()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleCaptureSettingsChanged),
            name: .captureSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRecentFileSettingsChanged),
            name: .recentFileSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShareServiceConfigurationChanged),
            name: .shareServiceConfigurationChanged, object: nil
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOnboarding),
            name: .showOnboarding, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleHideOverlay),
            name: .hideOverlay, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMinimizeOverlay),
            name: .minimizeOverlay, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowHotkeyPicker),
            name: .showHotkeyPicker, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowCustomDisable),
            name: .showCustomDisable, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowFavoriteTools),
            name: .showFavoriteTools, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowOutputDirectory),
            name: .showOutputDirectory, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowScripts),
            name: .showScripts, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleShowAIProvider),
            name: .showAIProvider, object: nil
        )

        // Finder "Add to Dragaway" Quick Action → opens Stage 2 with the selected files.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAddFilesFromShare),
            name: .addFilesFromShare, object: nil
        )
        registerShareInboxObserver()

        // Radial launcher "Dragaway" slot / pill-approach handoff → open the chips card.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRadialOpenSession(_:)),
            name: .radialOpenSession, object: nil
        )

        // Space switches cancel any active system drag and leave DragMonitor in a
        // stale state — pressTimeChangeCount and lastDragChangeCount diverge, making
        // the next drag on the new space fail the pasteboard guard silently.
        // Reset drag state on every space change so the pill can appear fresh.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleActiveSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        // If the user's key screen changes (external display connected/disconnected,
        // lid closed, etc.) reposition the overlay window to the new notch location.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Show onboarding on very first launch.
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showOnboarding()
            }
        }

        // Brief startup toast — let the user know Dragaway is alive and ready.
        // Skip on the very first launch (onboarding already greets them).
        if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                self.showStartupToast()
            }
        }
    }

    @objc private func handleShowOnboarding()    { showOnboarding()    }
    @objc private func handleHideOverlay()       { hideOverlay()       }
    @objc private func handleMinimizeOverlay()   { minimizeOverlay()   }
    @objc private func handleShowHotkeyPicker()  { showHotkeyPicker()  }
    @objc private func handleShowCustomDisable() { showCustomDisable() }
    @objc private func handleShowFavoriteTools() { showSettings(section: .favoriteTools) }
    @objc private func handleShowOutputDirectory() { showSettings(section: .outputDirectory) }
    @objc private func handleShowScripts() { showSettings(section: .scripts) }
    @objc private func handleShowAIProvider() { showSettings(section: .aiProvider) }

    // MARK: - Finder "Add to Dragaway" Quick Action

    /// Subscribe to the Darwin notification the (sandboxed) extension posts after it
    /// writes the selected paths into the shared App Group inbox. Darwin notifications
    /// are the one IPC channel that crosses the sandbox boundary. The C callback can't
    /// capture, so it just re-posts a normal Notification the @MainActor handler observes.
    private func registerShareInboxObserver() {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                NotificationCenter.default.post(name: .addFilesFromShare, object: nil)
            },
            ShareInbox.darwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    @objc private func handleAddFilesFromShare() {
        // The Darwin callback may fire off the main thread — bounce onto the main actor.
        Task { @MainActor in
            let urls = ShareInbox.drain()
            guard !urls.isEmpty else { return }
            self.openSessionWithFiles(urls)
        }
    }

    /// Open Stage 2 (chips) for files handed over by the Finder Quick Action. Mirrors
    /// restoreMinimizedSession()'s window bring-up: cancel any pending dismiss, reuse or
    /// build the overlay window, populate the session, size/place, and bring forward.
    @MainActor
    func openSessionWithFiles(_ urls: [URL]) {
        let supported = urls.filter { !FileInspector.isUnsupportedFileType($0) }
        guard !supported.isEmpty else { return }

        // Cancel any pending dismiss so a fading window isn't torn down under us.
        dismissToken       = UUID()
        isWindowDismissing = false

        // A promised file can arrive after dragCompleted() scheduled the Stage-1
        // dismissal. Revive the shared view model explicitly so an early handoff
        // cannot inherit `isCollapsing == true` and open an invisible chips card.
        let vm = OverlayViewModel.shared
        vm.isCollapsing = false

        if overlayWindow == nil {
            let window = OverlayWindow()
            window.contentView = DroppableHostingView(
                rootView: OverlayView(provider: resolveProvider())
            )
            overlayWindow = window
        }

        vm.setChips(urls: supported)
        if supported.allSatisfy(FileInspector.isEmailFile) {
            let charLimit = EntitlementStore.shared.isPremiumUnlocked
                ? FileContentExtractor.maxCharsPro : FileContentExtractor.maxChars
            vm.prepareBaseContext(for: supported, charLimit: charLimit)
        }
        let (size, anchorLeft) = sizeForStage(vm.stage)
        overlayWindow?.alphaValue = 1
        vm.windowShown = true
        overlayWindow?.place(size: size, anchorAtNotchCenter: anchorLeft)
        // Grab key + activate so the card opens FOCUSED (type right away). Losing focus
        // later is fine — the overlay stays vivid via the forced controlActiveState.
        overlayWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startDismissMonitors()
    }

    /// Called by macOS whenever the user switches Mission Control spaces.
    /// Resets DragMonitor so stale pasteboard change-counts from the previous
    /// space don't block the pill from appearing on the new space.
    ///
    /// The notification arrives up to ~200 ms after the visual space transition.
    /// If the user starts a new drag on the target space within that window the
    /// Task below fires while a live drag is already in progress — calling
    /// hideOverlay() here would tear down the pill while a file is mid-air
    /// (miscatch) or while AppKit is delivering drag callbacks to the now-
    /// deallocated DroppableHostingView (crash). Guard against both by skipping
    /// the dismiss whenever a drag is already in flight.
    @objc private func handleActiveSpaceChanged() {
        Task { @MainActor in
            DragMonitor.shared.resetAfterSpaceChange()
            // Only dismiss the Stage-1 pill if no drag is currently active.
            if case .waitingForDrop = OverlayViewModel.shared.stage,
               !DragMonitor.shared.isDraggingFile {
                hideOverlay()
            }
        }
    }

    /// Called when screens are added, removed, or change resolution.
    /// Re-positions the overlay window so it stays centred on the correct notch.
    @objc private func handleScreenParametersChanged() {
        Task { @MainActor in
            guard let window = overlayWindow, window.isVisible else { return }
            let anchorLeft = OverlayViewModel.shared.stage.tag > 0
            window.place(
                size: window.frame.size,
                anchorAtNotchCenter: anchorLeft
            )
        }
    }

    // MARK: - Menu-bar status item
    //
    // Replaces SwiftUI's MenuBarExtra so the icon click can be intercepted: a
    // LEFT-click restores a parked (minimized) session when one exists; otherwise it
    // opens the menu. A RIGHT-click (or control-click) always opens the menu, so
    // Settings / Quit stay reachable even while a session is minimized.

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            // Menu-bar artwork is deliberately separate from AppIcon: macOS may apply
            // Liquid Glass treatment to app icons, whereas this template keeps its
            // transparent D cutout and outer corners as actual menu-bar transparency.
            if let icon = NSImage(named: "MenuBarIcon")?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                icon.isTemplate = true
                button.image = icon
            }
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isMenuClick = event?.type == .rightMouseUp
                       || event?.modifierFlags.contains(.control) == true
        if !isMenuClick, OverlayViewModel.shared.hasMinimizedSession {
            restoreMinimizedSession()
        } else {
            showStatusMenu()
        }
    }

    /// Pop the native AppKit menu under the status item. We attach the menu only for
    /// this one click (then detach in `menuDidClose`) so a plain left-click can still
    /// reach `statusItemClicked` to RESTORE a minimized session.
    private func showStatusMenu() {
        guard let item = statusItem, let button = item.button else { return }
        item.menu = buildStatusMenu()    // rebuilt per open → fresh dynamic labels
        button.performClick(nil)
    }

    /// Build the menu fresh each open so dynamic labels (tier, usage, paused state,
    /// hotkey) are current — mirrors MenuBarExtra's per-open render. Authored as a
    /// real NSMenu so it has native macOS styling (the previous NSPopover rendered
    /// SwiftUI buttons as a card, which looked wrong).
    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let now           = Date().timeIntervalSince1970
        let disabledUntil = UserDefaults.standard.double(forKey: "disabledUntil")
        let isDisabled    = disabledUntil > now

        // ── Hosted free-tier usage (daily token budget, or trial count) ──────────
        // Only for the hosted tier — BYOK has no metered limit. Kick a background
        // refresh so the NEXT open reflects server-truth; this open shows the last
        // mirrored snapshot. The bar is hidden during the interactions trial.
        if EntitlementStore.shared.tier != .byok {
            Task { await UsageStore.shared.refresh() }
            if let usage = usageMenuItem() {
                menu.addItem(usage)
                menu.addItem(.separator())
            }
        }

        // ── Provider + settings (each setting opens the window scoped to itself) ─
        // (The Upgrade/Pro line stays hidden until payments are wired.)
        addItem(to: menu, title: "AI Provider",   action: #selector(menuChangeModel))
        addItem(to: menu, title: "Window Size",   action: #selector(menuWindowSize))
        let customizeItem = NSMenuItem(title: "Customize", action: nil, keyEquivalent: "")
        let customizeMenu = NSMenu()
        addItem(to: customizeMenu, title: "Custom Prompts", action: #selector(menuCustomPrompts))
        addItem(to: customizeMenu, title: "Favorite Tools", action: #selector(menuFavoriteTools))
        customizeItem.submenu = customizeMenu
        menu.addItem(customizeItem)
        addItem(to: menu, title: "Capture Settings", action: #selector(menuCaptureSettings))
        addItem(to: menu, title: "Enhanced Access", action: #selector(menuEnhancedAccess))
        addItem(to: menu, title: "Session Sharing", action: #selector(menuSessionSharing))

        // ── Recent sessions (file + AI conversation, last 10) ───────────────────
        let historyItem = NSMenuItem(title: "Recent Sessions", action: nil, keyEquivalent: "")
        historyItem.submenu = buildHistorySubmenu()
        menu.addItem(historyItem)

        // ── Clipboard history (last 20; ⌃⌘V opens the 10-item picker) ───────────
        let clipItem = NSMenuItem(title: "Clipboard History", action: nil, keyEquivalent: "")
        clipItem.submenu = buildClipboardSubmenu()
        menu.addItem(clipItem)

        menu.addItem(.separator())

        // ── Disable / re-enable ──────────────────────────────────────────────────
        if isDisabled {
            addItem(to: menu, title: "Re-enable Now", action: #selector(menuReEnable))
        } else {
            let disableItem = NSMenuItem(title: "Disable for…", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            addItem(to: sub, title: "5 minutes",  action: #selector(menuDisableUntil(_:)), represented: now + 5  * 60)
            addItem(to: sub, title: "15 minutes", action: #selector(menuDisableUntil(_:)), represented: now + 15 * 60)
            addItem(to: sub, title: "30 minutes", action: #selector(menuDisableUntil(_:)), represented: now + 30 * 60)
            addItem(to: sub, title: "1 hour",     action: #selector(menuDisableUntil(_:)), represented: now + 60 * 60)
            sub.addItem(.separator())
            let midnight = (Calendar.current.date(byAdding: .day, value: 1,
                              to: Calendar.current.startOfDay(for: Date()))
                            ?? Date().addingTimeInterval(24 * 3600)).timeIntervalSince1970
            addItem(to: sub, title: "For today",         action: #selector(menuDisableUntil(_:)), represented: midnight)
            addItem(to: sub, title: "Until Re-Enabled",  action: #selector(menuDisableUntil(_:)),
                    represented: Date().addingTimeInterval(10 * 365 * 24 * 3600).timeIntervalSince1970)
            sub.addItem(.separator())
            addItem(to: sub, title: "Custom…", action: #selector(menuDisableCustom))
            disableItem.submenu = sub
            menu.addItem(disableItem)
        }

        // Hotkey — morphs to show the active key when configured
        let hotkeyTitle = HotkeyManager.shared.isEnabled
            ? "Hotkey: \(HotkeyManager.shared.displayString)…"
            : "Add Hotkey…"
        addItem(to: menu, title: hotkeyTitle, action: #selector(menuHotkey))

        let updateItem = addItem(to: menu, title: "Check for Updates…", action: #selector(menuCheckUpdates))
        updateItem.isEnabled = UpdaterController.shared.canCheckForUpdates

        // ── Session sharing ────────────────────────────────────────────────────
        // Active sender-owned shares remain manageable even if the user changes (or temporarily
        // breaks) the endpoint setting; each record retains its original service URL.
        ActiveShareStore.shared.pruneExpired()
        let ownedShares = ActiveShareStore.shared.ownedShares
        if BackendConfig.isSharingAvailable || !ownedShares.isEmpty {
            menu.addItem(.separator())
            if BackendConfig.isSharingAvailable {
                let expose = addItem(to: menu, title: "Expose Session…  ⌃⌘E",
                                     action: #selector(menuExposeSession))
                // Keep invalid folder/6+ sessions actionable so selecting the item can explain the
                // supported boundary instead of silently disabling the command.
                expose.isEnabled = !OverlayViewModel.shared.sessionFileURLs.isEmpty
                addItem(to: menu, title: "Join Session…  ⌃⌘J", action: #selector(menuJoinSession))
            }
            if !ownedShares.isEmpty {
                let active = NSMenuItem(title: "Active Exposed Sessions", action: nil,
                                        keyEquivalent: "")
                active.submenu = buildActiveSharesSubmenu(ownedShares)
                menu.addItem(active)
            }
        }

        menu.addItem(.separator())

        addItem(to: menu, title: "Help & Tutorial…", action: #selector(menuHelp))
        addItem(to: menu, title: "Send Feedback…", action: #selector(menuFeedback))

        menu.addItem(.separator())

        addItem(to: menu, title: "Quit Dragaway", action: #selector(menuQuit), key: "q")
        return menu
    }

    // MARK: Recent-sessions submenu

    /// Last 10 sessions as file rows (icon + name + date), styled like a native
    /// "recents" menu. Each row reopens the session; its ⌥-alternate removes it.
    private func buildHistorySubmenu() -> NSMenu {
        let menu = NSMenu()
        let sessions = SessionHistoryStore.shared.sessions

        guard !sessions.isEmpty else {
            addInfoItem(to: menu, title: "No recent sessions")
            return menu
        }

        // Full-text search across all stored sessions (filenames, prompts, answers).
        addItem(to: menu, title: "Search Sessions…", action: #selector(menuSearchSessions))
        menu.addItem(.separator())

        let df = DateFormatter()
        df.dateFormat = "dd.MM.yy, HH:mm"

        for rec in sessions {
            let dateStr = df.string(from: rec.updatedAt)
            let icon = historyIcon(forPath: rec.primaryPath)

            // Normal row — open the session.
            let open = NSMenuItem(title: rec.fileName,
                                  action: #selector(menuOpenHistorySession(_:)), keyEquivalent: "")
            open.target = self
            open.representedObject = rec.id.uuidString
            open.keyEquivalentModifierMask = []
            open.attributedTitle = historyTitle(name: rec.fileName, date: dateStr, destructive: false)
            open.image = icon
            menu.addItem(open)

            // ⌥-alternate row — remove just this session.
            let remove = NSMenuItem(title: rec.fileName,
                                    action: #selector(menuRemoveHistorySession(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = rec.id.uuidString
            remove.isAlternate = true
            remove.keyEquivalentModifierMask = [.option]
            remove.attributedTitle = historyTitle(name: "Remove “\(rec.fileName)”",
                                                   date: dateStr, destructive: true)
            remove.image = icon
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: "Clear History", action: #selector(menuClearHistory))
        addInfoItem(to: menu, title: "Hold ⌥ to remove a single session")
        return menu
    }

    /// Sender-side management uses the owner capability stored in Keychain. The visible menu only
    /// carries the public Session ID and the internal local record identifier; no owner token is
    /// ever attached to an NSMenuItem or copied to the pasteboard.
    private func buildActiveSharesSubmenu(_ records: [ActiveShareRecord]) -> NSMenu {
        let menu = NSMenu()
        for record in records {
            let detail: String
            if let rawID = record.sessionID,
               let sessionID = ShareSessionID(rawValue: rawID) {
                detail = sessionID.formatted
            } else {
                detail = "Unconfirmed — cleanup retained"
            }
            let parent = NSMenuItem(title: "\(record.fileName) · \(detail)",
                                    action: nil, keyEquivalent: "")
            parent.image = NSWorkspace.shared.icon(forFile: record.fileName)
            parent.image?.size = NSSize(width: 16, height: 16)

            let actions = NSMenu()
            let status = record.state == .active ? "Available" : "Cleanup retained"
            addInfoItem(to: actions, title: "\(status) until \(record.expiresAt.formatted(date: .abbreviated, time: .shortened))")
            actions.addItem(.separator())
            if record.sessionID != nil {
                addItem(to: actions, title: "Copy Session ID",
                        action: #selector(menuCopyActiveShareID(_:)), represented: record.id)
            }
            addItem(to: actions, title: "Revoke Share…",
                    action: #selector(menuRevokeActiveShare(_:)), represented: record.id)
            parent.submenu = actions
            menu.addItem(parent)
        }
        return menu
    }

    /// 32-pt file-type icon for a menu row (generic if the file no longer exists).
    private func historyIcon(forPath path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    /// Two-line menu title: file name over a dimmer date. Colours use semantic
    /// label colours so the rows read correctly in both light and dark menus.
    private func historyTitle(name: String, date: String, destructive: Bool) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: destructive ? NSColor.systemRed : NSColor.labelColor,
            .paragraphStyle: para,
        ]))
        s.append(NSAttributedString(string: "\n" + date, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para,
        ]))
        return s
    }

    // MARK: Clipboard-history submenu

    /// Last 20 captures as icon + preview + time rows (newest first). A row copies the
    /// entry back to the pasteboard; its ⌥-alternate removes it. Top of the submenu holds
    /// the "Track Clipboard" toggle; the ⌃⌘V picker surfaces the most recent 10.
    private func buildClipboardSubmenu() -> NSMenu {
        let menu = NSMenu()

        // Capture on/off — flips the poll AND the ⌃⌘V hotkey together.
        let track = NSMenuItem(title: "Track Clipboard",
                               action: #selector(menuToggleClipboard), keyEquivalent: "")
        track.target = self
        track.state = ClipboardHistoryStore.isEnabled ? .on : .off
        menu.addItem(track)

        let items = ClipboardHistoryStore.shared.items
        guard !items.isEmpty else {
            addInfoItem(to: menu, title: ClipboardHistoryStore.isEnabled
                        ? "No clipboard history yet" : "Clipboard tracking is off")
            addInfoItem(to: menu, title: "⌃⌘V opens the clipboard picker")
            return menu
        }

        let df = DateFormatter()
        df.dateFormat = "dd.MM.yy, HH:mm"

        for item in items {
            let dateStr = df.string(from: item.date)
            let icon = ClipboardHistoryStore.shared.icon(for: item, size: 32)
            let label = clipRowLabel(item)

            // Normal row — copy back to the pasteboard.
            let copy = NSMenuItem(title: label,
                                  action: #selector(menuCopyClipItem(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = item.id.uuidString
            copy.keyEquivalentModifierMask = []
            copy.attributedTitle = historyTitle(name: label, date: dateStr, destructive: false)
            copy.image = icon
            menu.addItem(copy)

            // ⌥-alternate row — remove just this entry.
            let remove = NSMenuItem(title: label,
                                    action: #selector(menuRemoveClipItem(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = item.id.uuidString
            remove.isAlternate = true
            remove.keyEquivalentModifierMask = [.option]
            remove.attributedTitle = historyTitle(name: "Remove “\(label)”",
                                                   date: dateStr, destructive: true)
            remove.image = icon
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        addItem(to: menu, title: "Clear Clipboard History", action: #selector(menuClearClipboard))
        addInfoItem(to: menu, title: "Hold ⌥ to remove · ⌃⌘V opens the picker")
        return menu
    }

    /// Single-line, length-capped menu label for a clipboard entry.
    private func clipRowLabel(_ item: ClipItem) -> String {
        let p = item.preview
        return p.count > 50 ? String(p.prefix(50)) + "…" : p
    }

    // MARK: Menu builders / labels

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, action: Selector,
                         key: String = "", represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.representedObject = represented
        menu.addItem(item)
        return item
    }

    private func addInfoItem(to menu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func tierLabel() -> String {
        switch EntitlementStore.shared.tier {
        case .byok:       return "Your own key"
        case .freeHosted: return "Dragaway Free"
        case .pro:        return "Dragaway Pro"
        }
    }

    // MARK: Usage header (hosted free tier)

    /// A non-interactive header showing the hosted free-tier allowance. During the
    /// one-time interactions trial it's a plain "N free interactions left" line (NO
    /// bar). After the trial it's a small progress bar of the daily TOKEN budget plus
    /// a token overview. Returns nil for BYOK or before any usage snapshot exists.
    private func usageMenuItem() -> NSMenuItem? {
        let u = UsageStore.shared
        let title: String
        let subtitle: String
        let progress: Double?   // nil ⇒ no bar (trial state)

        if u.inTrial {
            guard let left = u.trialRemaining else { return nil }
            title = "Dragaway Free · Trial"
            subtitle = "\(max(0, left)) free interactions left"
            progress = nil
        } else {
            guard let rem = u.dailyTokensRemaining,
                  let budget = u.dailyTokenBudget, budget > 0 else { return nil }
            let pctFree = max(0, min(100, Int((Double(rem) / Double(budget) * 100).rounded())))
            title = "Dragaway Free · Today"
            subtitle = "\(pctFree)% left · \(Self.tokenFmt(rem)) / \(Self.tokenFmt(budget)) tokens"
            progress = min(1, max(0, Double(budget - rem) / Double(budget)))
        }

        let item = NSMenuItem()
        item.isEnabled = false
        item.view = makeUsageView(title: title, subtitle: subtitle, progress: progress)
        return item
    }

    /// Group-separated token count, e.g. `21,900`.
    private static func tokenFmt(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Custom NSView for the usage menu item: a small caption, an optional determinate
    /// progress bar (daily token budget used), and a detail line. Frame-based layout —
    /// fixed width sets the menu's minimum width.
    private func makeUsageView(title: String, subtitle: String, progress: Double?) -> NSView {
        let width: CGFloat = 230
        let x: CGFloat = 14
        let innerW = width - 2 * x
        let height: CGFloat = progress == nil ? 38 : 52
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.frame = NSRect(x: x, y: height - 18, width: innerW, height: 14)
        container.addSubview(titleField)

        if let progress {
            let bar = NSProgressIndicator(frame: NSRect(x: x, y: 22, width: innerW, height: 8))
            bar.style = .bar
            bar.isIndeterminate = false
            bar.controlSize = .small
            bar.minValue = 0
            bar.maxValue = 1
            bar.doubleValue = progress
            container.addSubview(bar)

            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .labelColor
            detail.frame = NSRect(x: x, y: 4, width: innerW, height: 14)
            container.addSubview(detail)
        } else {
            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .labelColor
            detail.frame = NSRect(x: x, y: 6, width: innerW, height: 16)
            container.addSubview(detail)
        }
        return container
    }

    private func pausedLabel(secs: TimeInterval) -> String {
        if secs > 365 * 24 * 3600 { return "Paused · until re-enabled" }
        if secs > 3600            { return "Paused · \(Int(secs / 3600))h left" }
        return "Paused · \(max(1, Int(ceil(secs / 60)))) min left"
    }

    // MARK: Menu actions

    @objc private func menuUpgrade()     { EntitlementStore.shared.startUpgrade() }
    @objc private func menuChangeModel()  { showSettings(section: .aiProvider) }
    @objc private func menuOpenSettings() { showSettings() }
    @objc private func menuWindowSize()    { showSettings(section: .windowSize) }
    @objc private func menuCustomPrompts() { showSettings(section: .customPrompt) }
    @objc private func menuFavoriteTools() { showSettings(section: .favoriteTools) }
    @objc private func menuEnhancedAccess() { showSettings(section: .enhancedAccess) }
    @objc private func menuSessionSharing() { showSettings(section: .sessionSharing) }
    @objc private func menuReEnable()     { UserDefaults.standard.set(0, forKey: "disabledUntil") }
    @objc private func menuDisableUntil(_ sender: NSMenuItem) {
        guard let ts = sender.representedObject as? TimeInterval else { return }
        UserDefaults.standard.set(ts, forKey: "disabledUntil")
    }
    @objc private func menuDisableCustom() { NotificationCenter.default.post(name: .showCustomDisable, object: nil) }
    @objc private func menuHotkey()        { NotificationCenter.default.post(name: .showHotkeyPicker, object: nil) }
    @objc private func menuCheckUpdates()  { UpdaterController.shared.checkForUpdates() }
    @objc private func menuQuit()          { NSApp.terminate(nil) }

    // MARK: Recent-sessions actions

    /// Reopen a stored session: rebuild a MinimizedSnapshot showing the latest
    /// result (prior turn cached for the back-arrow) and reuse the restore path.
    @objc private func menuOpenHistorySession(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        openHistorySession(id: id)
    }

    /// Reopen a stored session (menu row + the Search Sessions window both land here).
    func openHistorySession(id: UUID) {
        guard let rec = SessionHistoryStore.shared.record(for: id) else { return }

        // An exposed snapshot may legitimately contain no AI turn yet. It is still a real imported
        // session and must retain its imported history identity for the recipient's first action.
        guard let last = rec.lastTurn else {
            let urls = [rec.fileURL] + rec.additionalPaths.map { URL(fileURLWithPath: $0) }
            openSessionWithFiles(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
            SessionHistoryStore.shared.resumeSession(id: id)
            return
        }

        let primary = rec.fileURL
        let lastAction = AIAction(rawValue: last.actionRaw) ?? .freeform
        let stage: OverlayViewModel.Stage = .result(url: primary, action: lastAction, text: last.resultText)

        var cached: OverlayViewModel.Stage? = nil
        if let prev = rec.previousTurn {
            let prevAction = AIAction(rawValue: prev.actionRaw) ?? .freeform
            cached = .result(url: primary, action: prevAction, text: prev.resultText)
        }

        let additional = rec.additionalPaths
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        // Rebuild the full chat transcript from the stored turns: each turn becomes a
        // user bubble (its prompt) + an assistant bubble (its result). baseContext is
        // left nil so the first follow-up re-extracts the file once.
        let conversation: [OverlayViewModel.ChatMessage] = rec.turns.flatMap { turn -> [OverlayViewModel.ChatMessage] in
            let action = AIAction(rawValue: turn.actionRaw) ?? .freeform
            let userModelText = (action == .freeform) ? turn.promptTitle : action.systemPrompt
            return [
                .init(role: .user, display: turn.promptTitle, modelText: userModelText),
                .init(role: .assistant, display: turn.resultText, modelText: turn.resultText),
            ]
        }

        let vm = OverlayViewModel.shared
        let snap = OverlayViewModel.MinimizedSnapshot(
            stage: stage,
            chipsTab: .suggested,
            isChipsExpanded: vm.isChipsExpanded,
            isFollowupsExpanded: vm.isFollowupsExpanded,
            userDragOffset: .zero,
            cachedResult: cached,
            additionalFileURLs: additional,
            contentTruncated: false,
            customPrompt: "",
            conversation: conversation,
            baseContext: nil)
        vm.stageMinimized(snap)
        restoreMinimizedSession()
        // Continue this record so further actions append rather than duplicate.
        SessionHistoryStore.shared.resumeSession(id: id)
    }

    @objc private func menuRemoveHistorySession(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        SessionHistoryStore.shared.remove(id: id)
    }

    @objc private func menuClearHistory() {
        guard confirmDestructive(title: "Clear Session History?") else { return }
        SessionHistoryStore.shared.clear()
    }

    @objc private func menuSearchSessions() { showSessionSearch() }
    @objc private func menuFeedback()       { showFeedback() }

    /// Open (or re-focus) the Feedback window. Same managed-NSWindow pattern as the
    /// hotkey picker / session search.
    // MARK: - Session sharing (docs/SHARE_ARCHITECTURE.md)

    @objc private func menuExposeSession() { showExposeSession() }
    @objc private func menuJoinSession()   { showJoinSession() }

    @objc private func menuCopyActiveShareID(_ sender: NSMenuItem) {
        guard let localID = sender.representedObject as? String,
              let record = ActiveShareStore.shared.ownedShares
                .first(where: { $0.id == localID }),
              let sessionID = record.sessionID else { return }
        copySessionID(sessionID)
    }

    @objc private func menuRevokeActiveShare(_ sender: NSMenuItem) {
        guard let localID = sender.representedObject as? String,
              let record = ActiveShareStore.shared.ownedShares
                .first(where: { $0.id == localID }) else { return }

        let alert = NSAlert()
        alert.messageText = "Revoke this exposed session?"
        if let rawID = record.sessionID,
           let sessionID = ShareSessionID(rawValue: rawID) {
            alert.informativeText = "The Session ID \(sessionID.formatted) will stop working for every colleague. Copies already imported onto their Macs are unaffected."
        } else {
            alert.informativeText = "Dragaway did not receive a definitive create response, but retained the owner capability. Revoke confirms cleanup when the service can be reached."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Revoke Share")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { @MainActor [weak self] in
            do {
                try await ShareController.shared.revoke(record)
            } catch {
                self?.showShareError(error.localizedDescription)
            }
        }
    }

    /// Marks the public ID as transient so Dragaway's own Clipboard History and compatible
    /// clipboard managers do not persist a bearer credential, while keeping ordinary paste intact.
    private func copySessionID(_ sessionID: String) {
        let item = NSPasteboardItem()
        item.setString(sessionID, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }

    private func showShareError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Session Sharing"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Claim ⌃⌘E / ⌃⌘J only while sharing is actually available. Both are Carbon
    /// hotkeys: they consume the keystroke system-wide, so an unusable registration
    /// would break those combinations everywhere else on the Mac.
    private func armSharingHotkeys() {
        guard BackendConfig.isSharingAvailable else {
            exposeHotkey.unregister()
            joinHotkey.unregister()
            return
        }
        exposeHotkey.register(keyCode: UInt32(kVK_ANSI_E),
                              modifiers: UInt32(cmdKey | controlKey)) { [weak self] in
            self?.showExposeSession()
        }
        joinHotkey.register(keyCode: UInt32(kVK_ANSI_J),
                            modifiers: UInt32(cmdKey | controlKey)) { [weak self] in
            self?.showJoinSession()
        }
    }

    /// Turns of the session on screen, so the recipient inherits the AI history.
    private func currentSessionTurns() -> [SessionTurn] {
        SessionHistoryStore.shared.activeSessionRecord?.turns ?? []
    }

    /// Capture the exact ordered files represented by the visible session. The immutable array is
    /// passed through disclosure and packing so files added later cannot silently join the share.
    private func exposableCurrentFileURLs() -> [URL]? {
        let urls = OverlayViewModel.shared.sessionFileURLs
        guard (1...ShareBundle.maxFiles).contains(urls.count) else { return nil }
        for url in urls {
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  !FileInspector.isDirectory(url),
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
        }
        return urls
    }

    func showExposeSession() {
        guard let fileURLs = exposableCurrentFileURLs() else {
            let alert = NSAlert()
            alert.messageText = "This session cannot be exposed yet"
            alert.informativeText = "Session Sharing supports up to five regular files. Folders, symbolic links, and sessions with more than five files stay local so Dragaway never presents an incomplete shared snapshot."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        let turns = currentSessionTurns()

        // Re-root on every presentation. Even if another session opened while this window was
        // already retained, no stale file URL, transcript or password state may be reused.
        exposeWindow?.close()
        ShareController.shared.reset()
        let hosting = NSHostingController(rootView: ExposeSessionView(
            fileURLs: fileURLs, turns: turns) { [weak self] in self?.exposeWindow?.close() })
        let win = NSWindow(contentViewController: hosting)
        win.title = "Expose Session"
        win.styleMask = [.titled, .closable]
        win.level = .floating + 1
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        exposeWindow = win
        exposeWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .tutorialEvent, object: "expose")
    }

    func showJoinSession() {
        joinWindow?.close()
        let hosting = NSHostingController(rootView: JoinSessionView(
            onImported: { [weak self] sessionID in self?.openHistorySession(id: sessionID) },
            onClose: { [weak self] in self?.joinWindow?.close() }))
        let win = NSWindow(contentViewController: hosting)
        win.title = "Join Session"
        win.styleMask = [.titled, .closable]
        win.level = .floating + 1
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        joinWindow = win
        joinWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .tutorialEvent, object: "joinSession")
    }

    func showFeedback() {
        if feedbackWindow == nil {
            let hosting = NSHostingController(rootView: FeedbackView { [weak self] in
                self?.feedbackWindow?.close()
                self?.feedbackWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Send Feedback"
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false
            win.center()
            feedbackWindow = win
        }
        feedbackWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or re-focus) the Search Sessions window. Same managed-NSWindow pattern
    /// as showHotkeyPicker. Picking a row closes the window and restores the session.
    func showSessionSearch() {
        if sessionSearchWindow == nil {
            let hosting = NSHostingController(rootView: SessionSearchView { [weak self] id in
                self?.sessionSearchWindow?.close()
                self?.sessionSearchWindow = nil
                self?.openHistorySession(id: id)
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Search Sessions"
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false
            win.center()
            sessionSearchWindow = win
        }
        sessionSearchWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Clipboard-history actions

    /// Copy a stored entry back to the system pasteboard (the user pastes it with ⌘V).
    @objc private func menuCopyClipItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr),
              let item = ClipboardHistoryStore.shared.items.first(where: { $0.id == id }) else { return }
        ClipboardHistoryStore.shared.copyToPasteboard(item)
    }

    @objc private func menuRemoveClipItem(_ sender: NSMenuItem) {
        guard let idStr = sender.representedObject as? String,
              let id = UUID(uuidString: idStr) else { return }
        ClipboardHistoryStore.shared.remove(id: id)
    }

    @objc private func menuClearClipboard() {
        guard confirmDestructive(title: "Clear Clipboard History?") else { return }
        ClipboardHistoryStore.shared.clear()
    }

    /// Flip clipboard capture on/off — keeps the poll timer and the ⌃⌘V hotkey in lockstep.
    @objc private func menuToggleClipboard() {
        let enabled = !ClipboardHistoryStore.isEnabled
        ClipboardHistoryStore.isEnabled = enabled
        if enabled {
            ClipboardHistoryStore.shared.startMonitoring()
            registerClipboardHotkey()
        } else {
            ClipboardHistoryStore.shared.stopMonitoring()
            unregisterClipboardHotkey()
        }
    }

    /// Detach the menu once it closes so the next plain left-click reaches
    /// `statusItemClicked` (and can restore a minimized session). Deferred because
    /// the menu is still tearing down when this fires.
    func menuDidClose(_ menu: NSMenu) {
        DispatchQueue.main.async { [weak self] in self?.statusItem?.menu = nil }
    }

    // MARK: - Minimize / restore

    /// Park the live session and squish the overlay into the notch. Reuses
    /// hideOverlay()'s collapse animation + teardown; reset() there does NOT clear
    /// the snapshot, so the parked session survives for restore.
    @MainActor
    func minimizeOverlay() {
        guard OverlayViewModel.shared.minimizeCurrentSession() else { return }
        hideOverlay()
    }

    /// Bring a parked session back: rebuild/reuse the window, re-apply the snapshot,
    /// and size/position to the restored stage.
    @MainActor
    func restoreMinimizedSession() {
        let vm = OverlayViewModel.shared
        guard let snap = vm.consumeMinimizedSnapshot() else { return }

        // Cancel any pending dismiss so a fading window isn't torn down under us.
        dismissToken       = UUID()
        isWindowDismissing = false

        // Reuse an existing window (e.g. a Stage-1 pill from a new drag) or build one.
        if overlayWindow == nil {
            let window = OverlayWindow()
            window.contentView = DroppableHostingView(
                rootView: OverlayView(provider: resolveProvider())
            )
            overlayWindow = window
        }

        // Apply parked state (sets `stage` last) then size/position to that stage.
        vm.applySnapshot(snap)
        let (size, anchorLeft) = sizeForStage(snap.stage)
        overlayWindow?.alphaValue = 1
        OverlayViewModel.shared.windowShown = true
        overlayWindow?.place(size: size, anchorAtNotchCenter: anchorLeft)
        overlayWindow?.makeKeyAndOrderFront(nil)   // reopen a session focused
        NSApp.activate(ignoringOtherApps: true)
        startDismissMonitors()
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
                    // This also prevents re-triggering during a drag-OUT gesture.
                    if case .waitingForDrop = vm.stage {
                        // Respect the "Disable for X minutes" setting.
                        guard !self.isPillDisabled else { return }
                        self.ensureOverlayVisible()
                    }
                } else {
                    if case .waitingForDrop = vm.stage {
                        // ── Poll-timer race guard ────────────────────────────────
                        // isDraggingFile=false can arrive from two sources:
                        //   a) dragCompleted() — drop WAS caught (stage already .chips → not reached)
                        //   b) poll timer or handleMouseUp() — drag ended without a catch
                        //
                        // The poll timer fires in .common runloop mode (fires even inside
                        // AppKit's .eventTracking drag loop) and can see an empty drag
                        // pasteboard milliseconds BEFORE AppKit delivers performDragOperation
                        // — the source app starts tearing down its session the instant the
                        // mouse is released, racing the poll interval.
                        //
                        // Calling hideOverlay() immediately here would dismiss the window
                        // before performDragOperation arrives, losing the cached URL and
                        // causing a silent drop failure. Fix: defer by 150 ms and re-check.
                        // By then any in-flight performDragOperation has advanced the stage
                        // to .chips (or .error), making the second guard a safe no-op.
                        guard !DragMonitor.shared.isDraggingFile else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            guard let self else { return }
                            guard !DragMonitor.shared.isDraggingFile,
                                  case .waitingForDrop = OverlayViewModel.shared.stage else { return }
                            self.hideOverlay()
                        }
                    }
                    // Shelf stays open until the user explicitly closes it.
                    // Drag-out roll-back is handled separately by observeDragOutState().
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Drag-out detection
    //
    // SwiftUI's .onDrag uses an internal AppKit NSDraggingSession that does NOT
    // write to NSPasteboard(name: .drag), so DragMonitor never sees it and
    // isDraggingFile never changes.  Global leftMouseUp monitors are also silenced
    // inside AppKit's .eventTracking runloop mode.
    //
    // Solution: the moment isDraggingOut becomes true, start a 50 ms timer in
    // .common runloop mode (fires in ALL modes, including .eventTracking) that
    // polls NSEvent.pressedMouseButtons.  When the left button is released the
    // drag has ended — apply the stage roll-back and stop the timer.

    private func observeDragOutState() {
        OverlayViewModel.shared.$isDraggingOut
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] draggingOut in
                if draggingOut {
                    self?.startDragOutEndDetector()
                } else {
                    self?.stopDragOutEndDetector()
                }
            }
            .store(in: &cancellables)
    }

    private func startDragOutEndDetector() {
        stopDragOutEndDetector()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // Left mouse button no longer held — drag session has ended.
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    self?.handleDragOutEnded()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        dragOutEndTimer = t
    }

    private func stopDragOutEndDetector() {
        dragOutEndTimer?.invalidate()
        dragOutEndTimer = nil
    }

    @MainActor
    private func handleDragOutEnded() {
        stopDragOutEndDetector()
        let vm = OverlayViewModel.shared
        guard vm.isDraggingOut else { return }
        vm.isDraggingOut = false

        if case .result(let url, _, _) = vm.stage {
            // Stage 3 → stage 2. Keep the AI reply cached so → can restore it.
            // Also collapse chips so the shelf lands in its compact resting state.
            withAnimation(.spring(response: 0.42, dampingFraction: 0.58)) {
                vm.navigateBackToChips(savingResult: vm.stage, url: url)
                vm.isChipsExpanded = false
            }
        } else if case .chips = vm.stage, vm.isChipsExpanded {
            // Stage 2 with chips shown → collapse them.
            withAnimation(.spring(response: 0.18, dampingFraction: 1.0)) {
                vm.isChipsExpanded = false
            }
        }
    }

    private func observeStageChanges() {
        OverlayViewModel.shared.$stage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] stage in
                // Defer to the NEXT runloop cycle.
                // The sink can fire while SwiftUI is mid-layout (the @Published change
                // and the Combine delivery both happen on the main thread).
                // Calling NSAnimationContext/animator().setFrame() from inside an active
                // AppKit layout pass triggers the recursive "Update Constraints in Window"
                // assertion → abort(). One async hop breaks that synchronous chain.
                DispatchQueue.main.async { self?.resizeOverlay(for: stage) }
                // Tool launch hotkeys (Option+1…9) live while a file is staged — the
                // "Open in" row is shown in BOTH the chips and result stages, so the
                // numbered badges must be functional in both.
                switch stage {
                case .chips, .result: self?.startToolHotkeys()
                default:              self?.stopToolHotkeys()
                }
            }
            .store(in: &cancellables)

        // A streaming reply publishes `stage` exactly ONCE (the first delta flips to
        // .result with an empty text); every token after that only mutates
        // `conversation`. So the observer above fired while the transcript was still
        // empty, the window kept its 410 pt floor for the whole stream, and only the
        // definitive .result at the end unfolded it — the reply appeared to arrive in
        // a window that resized after the fact. sizeForStage(.result) already derives
        // its height from the transcript, so re-running it as the transcript grows is
        // the whole fix.
        OverlayViewModel.shared.$conversation
            .sink { [weak self] _ in
                // Same deferral rationale as the stage observer: never call setFrame
                // from inside an active AppKit/SwiftUI layout pass.
                DispatchQueue.main.async {
                    // Only the result stage is transcript-sized; every other stage has
                    // a fixed height that the stage observer already applied.
                    guard case .result = OverlayViewModel.shared.stage else { return }
                    // Note this only raises the target — the 60 fps animator does the
                    // actual resizing, so token rate no longer drives frame changes and
                    // no throttle is needed here.
                    self?.growStreamHeight()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Tool launch hotkeys (Pillar 1)

    /// Install the `Option+1…9` local monitor that opens staged files in a favorite
    /// app. Local (not global) → it only sees our own app's key events, so it needs
    /// no Accessibility permission and can't clash with system/other-app shortcuts.
    private func startToolHotkeys() {
        guard toolHotkeyMonitor == nil else { return }
        toolHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // NSEvent local monitors are delivered on the main thread/runloop, so it
            // is safe to run the @MainActor handler synchronously and return its result.
            MainActor.assumeIsolated { AppDelegate.handleToolHotkey(event) }
        }
    }

    private func stopToolHotkeys() {
        if let m = toolHotkeyMonitor { NSEvent.removeMonitor(m); toolHotkeyMonitor = nil }
    }

    /// Returns `nil` to swallow a matched `Option+N` (so the digit never reaches the
    /// prompt field); otherwise returns the event unchanged for normal handling.
    @MainActor
    private static func handleToolHotkey(_ event: NSEvent) -> NSEvent? {
        // Tab / Shift+Tab cycles the first-stage (chips) tabs. Only while the chips
        // stage is up and the user is NOT editing a text field (then Tab belongs to
        // the field editor for normal text/focus traversal). keyCode 48 = Tab.
        if event.keyCode == 48, OverlayViewModel.shared.stage.tag == 1 {
            let chord = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let editing = NSApp.keyWindow?.firstResponder is NSText
            if !editing, chord.isSubset(of: .shift) {       // bare Tab or Shift+Tab only
                OverlayViewModel.shared.cycleChipsTab(reverse: chord.contains(.shift))
                return nil                                  // swallow — don't move focus
            }
        }

        // Bare Option only — ignore Option+Cmd / Option+Ctrl / Option+Shift chords.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let urls = OverlayViewModel.shared.sessionFileURLs
        // The "Open in" row is live in both the chips and result stages.
        let inToolStage: Bool = {
            switch OverlayViewModel.shared.stage {
            case .chips, .result: return true
            default:              return false
            }
        }()
        guard flags == .option,
              inToolStage,
              let chars = event.charactersIgnoringModifiers, chars.count == 1,
              let n = Int(chars), (1...9).contains(n),
              let tool = FavoriteToolsStore.shared.tool(forNumber: n, for: urls)
        else { return event }
        FavoriteToolsStore.shared.launch(tool, with: urls)
        return nil
    }

    // MARK: - Clipboard history hotkey (⌃⌘V)

    /// Arm the global ⌃⌘V hotkey → toggle the clipboard picker. Carbon `RegisterEventHotKey`
    /// consumes the keystroke (no leak to the frontmost app) and needs no Accessibility.
    // MARK: - Capture features (⌃⌘N + screenshot watcher)

    /// Whether the ⌃⌘N clipboard→session hotkey is armed (Settings toggle, default on).
    static var clipboardSessionHotkeyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardSessionHotkeyEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "clipboardSessionHotkeyEnabled") }
    }

    @objc private func handleCaptureSettingsChanged() { armCaptureFeatures() }

    @objc private func handleRecentFileSettingsChanged() { armRecentFileFeature() }

    @objc private func handleShareServiceConfigurationChanged() { armSharingHotkeys() }

    /// (Re)arm both capture features from their persisted toggles. Idempotent.
    private func armCaptureFeatures() {
        if Self.clipboardSessionHotkeyEnabled {
            sessionHotkey.register(keyCode: UInt32(kVK_ANSI_N),
                                   modifiers: UInt32(cmdKey | controlKey)) { [weak self] in
                self?.openSessionFromClipboard()
            }
        } else {
            sessionHotkey.unregister()
        }

        if ScreenshotWatcher.isEnabled {
            ScreenshotWatcher.shared.start()
        } else {
            ScreenshotWatcher.shared.stop()
        }
    }

    /// Keep the low-idle FSEvents stream and its Carbon hotkey in exact lockstep. When disabled,
    /// Dragaway neither observes paths nor consumes ⌃⌘L in other applications.
    private func armRecentFileFeature() {
        cancelRecentFileOpen()

        guard RecentFileSettings.shared.isEnabled else {
            recentFileHotkey.unregister()
            RecentFileWatcher.shared.setShortcutAvailable(false)
            RecentFileWatcher.shared.stop()
            return
        }

        let registered = recentFileHotkey.register(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | controlKey)
        ) { [weak self] in
            self?.openMostRecentFile()
        }
        RecentFileWatcher.shared.setShortcutAvailable(registered)

        guard registered else {
            RecentFileWatcher.shared.stop()
            return
        }
        RecentFileWatcher.shared.reconfigure()
    }

    /// ⌃⌘L: resolve the newest stable candidate and reuse the canonical external-file launch path.
    /// No copy or eager content extraction happens in the watcher itself.
    private func openMostRecentFile() {
        guard recentFileOpenTask == nil else { return }
        recentFileOpenGeneration &+= 1
        let generation = recentFileOpenGeneration

        recentFileOpenTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.recentFileOpenGeneration == generation {
                    self.recentFileOpenTask = nil
                }
            }
            guard let url = await RecentFileWatcher.shared.resolveLatestFile() else {
                if !Task.isCancelled { NSSound.beep() }
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.recentFileOpenGeneration == generation,
                  RecentFileSettings.shared.isEnabled else { return }
            self.openSessionWithFiles([url])
        }
    }

    private func cancelRecentFileOpen() {
        recentFileOpenGeneration &+= 1
        recentFileOpenTask?.cancel()
        recentFileOpenTask = nil
    }

    /// ⌃⌘N: open a session from whatever the clipboard holds — copied files directly,
    /// anything else (text / link / image) through the same materializer the
    /// drag-anything pipeline uses. Beeps when the clipboard has nothing usable.
    private func openSessionFromClipboard() {
        let pb = NSPasteboard.general
        var urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if urls.isEmpty,
           let payload = DropMaterializer.capture(from: pb),
           let materialized = DropMaterializer.materialize(payload) {
            urls = [materialized]
        }
        guard !urls.isEmpty else { NSSound.beep(); return }
        NotificationCenter.default.post(name: .tutorialEvent, object: "clipboard")
        openSessionWithFiles(urls)
    }

    @objc private func menuCaptureSettings() { showSettings(section: .capture) }
    @objc private func menuHelp()            { showSettings(section: .help) }
    @objc private func handleShowTutorial()  { showTutorial() }

    /// Open (or re-focus) the interactive tutorial. Floating so it stays visible while
    /// the user tries the real actions (drops, hotkeys, the radial) beside it.
    func showTutorial() {
        if tutorialWindow == nil {
            let controller = TutorialController()
            controller.onExit = { [weak self] in
                self?.tutorialWindow?.close()
                self?.tutorialWindow = nil
            }
            let win = NSWindow(contentViewController:
                NSHostingController(rootView: TutorialView(controller: controller)))
            win.title = "Welcome to Dragaway"
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.center()
            controller.window = win
            tutorialWindow = win
        }
        tutorialWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func registerClipboardHotkey() {
        clipboardHotkey.register(keyCode: UInt32(kVK_ANSI_V),
                                 modifiers: UInt32(cmdKey | controlKey)) {
            NotificationCenter.default.post(name: .tutorialEvent, object: "clipboard")
            ClipboardPicker.shared.toggle()
        }
    }

    private func unregisterClipboardHotkey() { clipboardHotkey.unregister() }

    /// Reposition (not resize) the window as the user drags the grabber handle.
    /// The grabber's DragGesture writes userDragOffset; we apply it to the window
    /// origin here. No deferral needed — setFrameOrigin doesn't run a layout pass.
    private func observeUserDragOffset() {
        // NO .receive(on:) — that schedules an async runloop hop even on the main
        // thread, so the window trailed the cursor by a frame (visible lag). The
        // gesture writes the offset on the main thread, so deliver synchronously and
        // move the window in the same tick. setFrameOrigin runs no layout pass, so
        // this is safe inside the @Published willSet. We use the value the publisher
        // hands us (the property isn't committed yet during willSet).
        OverlayViewModel.shared.$userDragOffset
            .sink { [weak self] offset in
                guard let window = self?.overlayWindow, window.isVisible else { return }
                window.reapplyUserOffset(offset)
            }
            .store(in: &cancellables)
    }

    private func observeChipsExpanded() {
        OverlayViewModel.shared.$isChipsExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeOverlay(for: OverlayViewModel.shared.stage)
                }
            }
            .store(in: &cancellables)
    }

    /// Stage-2 chips window must follow the active prompt tab AND the row count of
    /// the History / Custom lists (both can change while the chips card is up, e.g.
    /// adding a custom prompt via the "+" row). All three feed the same resize.
    private func observeChipsTab() {
        let resize: (Any) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                self?.resizeOverlay(for: OverlayViewModel.shared.stage)
            }
        }
        OverlayViewModel.shared.$chipsTab
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
        PromptStore.shared.$customPrompts
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
        PromptStore.shared.$history
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
        // Adding/removing a favorite app (in any list) changes the tool-row height —
        // keep the chips window in sync if the user edits favorites while a session is
        // on screen. objectWillChange covers every @Published list/flag; the resize is
        // dispatched async so it reads the committed value.
        FavoriteToolsStore.shared.objectWillChange
            .receive(on: DispatchQueue.main).sink(receiveValue: resize)
            .store(in: &cancellables)
    }

    private func observeFollowupsExpanded() {
        OverlayViewModel.shared.$isFollowupsExpanded
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.resizeOverlay(for: OverlayViewModel.shared.stage)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Overlay lifecycle

    /// Warms up SwiftUI's hosting infrastructure at launch.
    ///
    /// Creating an NSHostingView causes Metal/CoreAnimation initialisation and the
    /// first SwiftUI layout pass. If this happens on the drag-detection hot path
    /// (first ever file drag) the combined overhead introduces a visible cold-start
    /// delay or, in rare cases, a crash when a layout pass races the first stage
    /// transition. A minimal hidden view created eagerly at launch eliminates both.
    private func prewarmSwiftUI() {
        // Host the ACTUAL chips leaf views (OverlayPrewarmView), not a 1×1 Color.
        // The first real chips render otherwise pays SwiftUI's one-time costs —
        // generic specialisation, Core Text glyph caches, the LiquidGlass/Metal
        // pipeline, NSWorkspace icon service — on the drop hot path, which reads as
        // a hitch between drop and the card appearing (worst right after launch).
        // Rendering it here off-screen pays those costs up front. Sized to the real
        // chips frame so layout warms at the right dimensions; positioned far
        // off-screen with zero alpha so it never paints anything the user can see.
        let hosting = NSHostingView(rootView: OverlayPrewarmView())
        let win = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 280, height: 320),
                           styleMask: .borderless,
                           backing: .buffered, defer: false)
        win.alphaValue   = 0
        win.contentView  = hosting
        win.orderBack(nil)               // force a real layout/display pass while hidden
        // Retain for 2 s then release — SwiftUI/Metal are warmed up by then.
        var retained: NSWindow? = win
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            retained?.orderOut(nil)
            retained = nil
        }
    }

    // MARK: - Startup toast

    /// Shows a compact "Dragaway is ready" banner just below the notch for 5 s,
    /// then spring-fades it out. Called on every launch after onboarding is done.
    private func showStartupToast() {
        guard startupToastWindow == nil else { return }

        let toastW: CGFloat = 390
        let toastH: CGFloat = 56     // matches StartupToastView intrinsic height

        // ── Build the floating panel ────────────────────────────────────────
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: toastW, height: toastH),
            styleMask:   [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing:     .buffered,
            defer:       false
        )
        panel.isFloatingPanel             = true
        panel.level                       = .floating
        panel.backgroundColor             = .clear
        panel.isOpaque                    = false
        panel.hasShadow                   = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // ── Observable state that drives the SwiftUI spring animation ───────
        let toastState = StartupToastState()
        let hosting = NSHostingView(rootView: StartupToastView(state: toastState))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = CGColor.clear
        panel.contentView = hosting

        // ── Position: centred on screen, just below the notch ──────────────
        if let screen = NSScreen.main {
            let x = (screen.frame.width - toastW) / 2
            // notchBottomY=37 + 10 pt gap = top edge of the toast window
            let y = screen.frame.height - 37 - toastH - 10
            panel.setFrame(NSRect(x: x, y: y, width: toastW, height: toastH),
                           display: false)
        }

        panel.orderFront(nil)
        startupToastWindow = panel

        // Trigger the spring pop-in one run-loop cycle after orderFront so
        // the window is fully composited before the animation starts.
        DispatchQueue.main.async {
            toastState.show()
        }

        // ── Auto-dismiss after 5 s ──────────────────────────────────────────
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            toastState.dismiss {
                self?.startupToastWindow?.orderOut(nil)
                self?.startupToastWindow = nil
            }
        }
    }

    /// Build the overlay window once at launch and park it invisibly in the notch
    /// housing. From then on show/hide only toggles alpha + frame — the window itself
    /// is immortal, so every drag source's destination snapshot includes it.
    private func createParkedOverlay() {
        guard overlayWindow == nil else { return }
        let window = OverlayWindow()
        window.contentView = DroppableHostingView(
            rootView: OverlayView(provider: resolveProvider())
        )
        window.park()
        window.orderFrontRegardless()   // ordered-in (invisible at alpha 0)
        overlayWindow = window
    }

    private func ensureOverlayVisible() {
        let s = UIScale.current.multiplier
        let pillSize = CGSize(width: 288 * s, height: 96 * s)

        if let win = overlayWindow {
            // ── Reuse path ───────────────────────────────────────────────────
            // A window exists — it is either already visible (no-op) or mid-dismiss
            // (alpha fading to 0).  In the latter case: invalidate the pending
            // dismiss token so its completion closure no-ops, then snap alpha back
            // to 1 and reset the view model.
            // Full reset is safe here: we're about to show WaitingPillView again,
            // and cancelling the token means the deferred reset in the completion
            // will never fire (token mismatch guard), so there's no double-reset.
            dismissToken       = UUID()    // ← cancels any pending dismiss completion
            isWindowDismissing = false     // ← unblocks resizeOverlay()
            win.alphaValue     = 1
            OverlayViewModel.shared.reset()   // ← stage → .waitingForDrop before orderFront
            OverlayViewModel.shared.windowShown = true   // replay the pill pop-in
            win.place(size: pillSize, anchorAtNotchCenter: false)
            win.orderFront(nil)
#if DEBUG
            dragDiag("UNPARK frame=\(win.frame) alpha=\(win.alphaValue) visible=\(win.isVisible) key=\(win.isKeyWindow)")
#endif
            startDismissMonitors()
            return
        }

        // ── Create path ──────────────────────────────────────────────────────
        // No window at all — build one fresh.
        let window = OverlayWindow()
        let hostingView = DroppableHostingView(
            rootView: OverlayView(provider: resolveProvider())
        )
        window.contentView = hostingView
        overlayWindow = window

        // Guarantee clean ViewModel state before the window is ever visible.
        // The deferred reset() inside hideOverlay() covers most cases, but on the
        // very first launch (or if a space-change hide raced with a new drag) the
        // deferred closure may not have fired yet — calling reset() here is safe
        // because stage is already .waitingForDrop and SwiftUI hasn't painted yet.
        OverlayViewModel.shared.reset()

        // Pre-position at the notch synchronously BEFORE ordering front.
        // Without this the window flashes at screen origin (0, 0) for one frame.
        overlayWindow?.place(size: pillSize, anchorAtNotchCenter: false)
        overlayWindow?.show()
        startDismissMonitors()
    }

    /// Radial launcher "Dragaway" slot / pill-approach handoff → open the chips card for
    /// the dragged file(s). Reuses the same proven path as the Finder Quick Action.
    @objc private func handleRadialOpenSession(_ note: Notification) {
        guard let urls = note.object as? [URL], !urls.isEmpty else { return }
        Task { @MainActor in
            self.openSessionWithFiles(urls)
            // No-op for ordinary radial/screenshot launches. Promise deliveries register these
            // paths before posting and release them only after `setChips` has made them live.
            DropMaterializer.promisedFilesDidEnterSession(urls)
        }
    }

    func hideOverlay() {
        // The window is immortal now (parked, never nil), so the old `!= nil` guard
        // stopped blocking repeat dismissals — every stray mouse-up re-ran the full
        // dismiss (visible as PARK spam in the diag). windowShown restores the old
        // "only while actually shown" semantics exactly.
        guard overlayWindow != nil, OverlayViewModel.shared.windowShown else { return }
        DragMonitor.shared.cancelBrowserFallback()
        stopDismissMonitors()

        // ── Partial reset (flags only, stage intact) ──────────────────────────
        // Clears hover/jelly flags but leaves stage unchanged so the SwiftUI
        // content keeps showing whatever was on screen when the user pressed ×.
        OverlayViewModel.shared.partialReset()

        // ── Trigger SwiftUI collapse animation ────────────────────────────────
        // Explicit withAnimation so the collapse uses a DIFFERENT spring than
        // the entry. Entry (in OverlayView.onAppear) uses dampingFraction 0.58
        // (underdamped → bouncy pop-in). Collapse uses dampingFraction 1.0
        // (critically damped → Y goes monotonically 1.0 → 0.02, never overshoots
        // into negative values, never "pops" back into view).
        // anchor: .top = the overlay squishes straight up into the notch.
        // Only Y collapses now (X holds at 1.0 in OverlayView), so this is a clean
        // vertical shrink — no diagonal corner-pull that read as overshoot before.
        // response: 0.24 → calm, unhurried settle into the notch.
        // dampingFraction: 1.0 → critically damped, Y travels straight to its target,
        // no overshoot, no bounce back into view.
        withAnimation(.spring(response: 0.24, dampingFraction: 1.0)) {
            OverlayViewModel.shared.isCollapsing = true
        }

        // ── Token-guarded deferred teardown ──────────────────────────────────
        // 0.34 s gives the calmer collapse spring room to reach Y≈0.02 and settle
        // before the window is ordered out. If ensureOverlayVisible() fires first it
        // writes a new token → this closure becomes a no-op and the window is reused.
        let token = UUID()
        dismissToken       = token
        isWindowDismissing = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.dismissToken == token else { return }
            self.isWindowDismissing = false
            // PARK instead of orderOut+destroy: the window must stay ordered-in so
            // drag sources that snapshot their destinations at drag-start (Safari
            // tabs) can still deliver future drops. See OverlayWindow.park().
            self.overlayWindow?.park()
            // Full reset now: window is invisible so the stage flip is silent.
            OverlayViewModel.shared.reset()   // also sets isCollapsing = false
        }
        // NOTE: overlayWindow is NEVER nilled — it lives (parked) for the whole app
        // lifetime; ensureOverlayVisible()'s reuse path revives it.
    }

    // MARK: - Window sizing

    private func resizeOverlay(for stage: OverlayViewModel.Stage) {
        // Skip resize while a dismiss animation is in flight.  reset() triggers a
        // .waitingForDrop stage change that would otherwise instantly shrink a
        // chips/result-sized window while it's fading out — visible and wrong.
        guard let window = overlayWindow, window.isVisible, !isWindowDismissing else { return }
        // Leaving the result stage ends any in-flight growth — the new stage's fixed
        // height wins immediately.
        if stage.tag != 3 { stopStreamGrowth() }
        // While the transcript is growing, the eased animator below owns the height.
        // Letting this path through would snap the frame to the target and undo it.
        if streamGrowthTimer != nil, case .result = stage { return }
        let (size, anchorLeft) = sizeForStage(stage)
        window.animateTo(size: size, anchorAtNotchCenter: anchorLeft)
    }

    // MARK: - Eased growth while a reply streams
    //
    // animateTo() sets the frame INSTANTLY by design (see OverlayWindow: the animator
    // proxy re-enters the constraint solver and aborts). The window is transparent, but
    // the transcript card fills it via .frame(maxHeight: .infinity), so every frame step
    // is visible on the black shape. Applying each new target directly therefore made a
    // fast model tick the shelf open in ~20 pt jerks (the height quantum of
    // sizeForStage's line estimate).
    //
    // So: keep the instant setFrame, but walk toward the target at display rate. Steps
    // of a point or two read as one continuous motion instead of a stutter.

    private func growStreamHeight() {
        guard let window = overlayWindow, window.isVisible, !isWindowDismissing else { return }
        let stage = OverlayViewModel.shared.stage
        guard case .result = stage else { return }

        // Monotonic: the transcript only ever grows during a turn, and a mid-answer
        // shrink (a shorter re-render, a late clamp) would read as a glitch.
        streamGrowthTarget = max(streamGrowthTarget, sizeForStage(stage).0.height)
        if streamGrowthCurrent <= 0 { streamGrowthCurrent = window.frame.height }
        guard streamGrowthTimer == nil else { return }

        // .common mode so the growth keeps running while the user is dragging or a
        // menu is tracking, exactly like the drag-out detector above.
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepStreamGrowth() }
        }
        RunLoop.main.add(t, forMode: .common)
        streamGrowthTimer = t
    }

    @MainActor
    private func stepStreamGrowth() {
        let stage = OverlayViewModel.shared.stage
        guard let window = overlayWindow, window.isVisible, !isWindowDismissing,
              case .result = stage else {
            stopStreamGrowth()
            return
        }

        let (size, anchorLeft) = sizeForStage(stage)
        streamGrowthTarget = max(streamGrowthTarget, size.height)

        let remaining = streamGrowthTarget - streamGrowthCurrent
        // Exponential ease-out: quick while far from the target, gentle as it lands.
        if abs(remaining) < 0.5 {
            streamGrowthCurrent = streamGrowthTarget
            window.animateTo(size: CGSize(width: size.width, height: streamGrowthCurrent),
                             anchorAtNotchCenter: anchorLeft)
            stopStreamGrowth()
            return
        }
        // Clamp the per-frame travel. Token-by-token growth never reaches it (those
        // steps measure 1–6 pt), but a target that jumps all at once — a follow-up turn
        // appending a whole prompt bubble, or finalizeStreamedReply swapping in the full
        // text — would otherwise open with a single 40 pt lurch, i.e. worse than the
        // stutter this replaced. 6 pt/frame ≈ 360 pt/s: the full 410→600 range in ~0.5 s.
        let step = min(abs(remaining) * 0.22, 6)
        streamGrowthCurrent += remaining < 0 ? -step : step
        window.animateTo(size: CGSize(width: size.width, height: streamGrowthCurrent.rounded()),
                         anchorAtNotchCenter: anchorLeft)
    }

    private func stopStreamGrowth() {
        streamGrowthTimer?.invalidate()
        streamGrowthTimer = nil
        streamGrowthTarget = 0
        streamGrowthCurrent = 0
    }

    /// Fixed window size + notch anchor for a stage. Single source of truth shared by
    /// the live resize observer and the minimize→restore path.
    /// `anchorLeft` = true pins the left column under the notch centre.
    private func sizeForStage(_ stage: OverlayViewModel.Stage) -> (CGSize, Bool) {
        let s = UIScale.current.multiplier
        switch stage {
        case .waitingForDrop:
            return (CGSize(width: 288 * s, height: 96 * s), false)   // canvas for wobble overflow

        case .chips(let url, let actions):
            if FileInspector.isMediaFile(url) {
                // AI-free media stage: Utilities + "Open in" only, always expanded, NO
                // prompt field. Mirrors ChipsColumnView's media layout so height fits exactly.
                let utilCount = FileToolActions.utilityTools(
                    for: url, sessionFiles: OverlayViewModel.shared.sessionFileURLs).count
                let contentH = ChipsLayout.contentHeight(rows: max(utilCount, 1))
                let toolH = FavoriteToolsStore.shared
                    .resolvedTools(for: OverlayViewModel.shared.sessionFileURLs).isEmpty
                    ? ChipsLayout.toolHintHeight : ChipsLayout.toolRowHeight
                // header + spacing(10) + tabBar + spacing(10) + content + spacing(10)
                // + toolRow + padding(36)  — no prompt field, no collapsed branch.
                let h = (ChipsLayout.fileHeaderHeight + 10 + ChipsLayout.tabBarHeight + 10
                         + contentH + 10 + toolH + 36) * s
                return (CGSize(width: 280 * s, height: max(h, 200 * s)), true)
            }
            if OverlayViewModel.shared.isChipsExpanded {
                // Height follows the ACTIVE prompt tab's row count (capped), using
                // the same ChipsLayout numbers the SwiftUI content region uses so
                // the window always fits exactly. See ChipsLayout.
                let store = PromptStore.shared
                let utilCount = FileToolActions.utilityTools(
                    for: url, sessionFiles: OverlayViewModel.shared.sessionFileURLs).count
                let rows = ChipsLayout.rows(for: OverlayViewModel.shared.chipsTab,
                                            suggested: actions.count,
                                            history: store.history.count,
                                            custom: store.customPrompts.count,
                                            utilities: utilCount,
                                            scripts: ScriptsStore.shared.scripts.count)
                let contentH = ChipsLayout.contentHeight(rows: rows)
                // Tool launch row ("Open in"): full height when the resolved list has
                // favorites, a single muted hint line when empty (matches ToolRow).
                let toolH = FavoriteToolsStore.shared
                    .resolvedTools(for: OverlayViewModel.shared.sessionFileURLs).isEmpty
                    ? ChipsLayout.toolHintHeight : ChipsLayout.toolRowHeight
                // header + spacing(10) + tabBar + spacing(10) + content + spacing(10)
                // + toolRow + spacing(10) + prompt(42) + padding(36)
                let h = (ChipsLayout.fileHeaderHeight + 10 + ChipsLayout.tabBarHeight + 10
                         + contentH + 10 + toolH + 10 + 42 + 36) * s
                return (CGSize(width: 280 * s, height: max(h, 220 * s)), true)
            } else {
                // Collapsed: header + spacing + prompt field + padding only
                let h = (ChipsLayout.fileHeaderHeight + 10 + 42 + 36) * s
                return (CGSize(width: 280 * s, height: max(h, 168 * s)), true)
            }

        case .loading:
            return (CGSize(width: 500 * s, height: 330 * s), true)

        case .result:
            // Window is always sized to fit the full expanded layout (transcript card +
            // prompt + follow-up chips). The follow-up toggle only controls content
            // visibility inside the window — the ScrollView grows into the freed space
            // without the window frame changing at all. Height grows with the whole
            // transcript (all turns), clamped 410…600; the card scrolls beyond that.
            let convo = OverlayViewModel.shared.conversation
            let totalChars = convo.reduce(0) { $0 + $1.display.count }
            let lines = max(convo.count * 2, totalChars / 55)
            let resultH = min(CGFloat(lines) * 20, 260)
            let h = (18 + 64 + resultH + 44 + 20 + 3 * 40 + 44 + 18) * s
            return (CGSize(width: 500 * s, height: min(max(h, 410 * s), 600 * s)), true)

        case .error:
            return (CGSize(width: 500 * s, height: 270 * s), true)

        case .fileResult:
            // Utility "second result stage": single column with two stacked file-detail
            // cards (output + original) and an action row. Fixed height; the bottom
            // Spacer in FileResultView absorbs any slack from short detail grids.
            return (CGSize(width: 500 * s, height: 430 * s), true)
        }
    }

    // MARK: - Dismiss monitors

    private func startDismissMonitors() {
        stopDismissMonitors()

        // Esc is handled by OverlayWindow.cancelOperation (responder chain, no
        // permission). A global keyDown monitor could ALSO catch Esc while another
        // app is frontmost, but global keyboard monitors require Accessibility —
        // the only such requirement in the app — and the shelf is deliberately
        // click-to-dismiss in that state, so the permission isn't worth it.

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, let window = self.overlayWindow else { return }
                guard !NSPointInRect(NSEvent.mouseLocation, window.frame) else { return }
                // Shelf behaviour: outside clicks only dismiss the Stage-1 pill.
                // Once a file is placed (stages 2/3) the window acts as a desk —
                // it stays open until the user clicks ×, drags the file out, or presses Esc.
                if case .waitingForDrop = OverlayViewModel.shared.stage {
                    self.hideOverlay()
                }
            }
        }
    }

    private func stopDismissMonitors() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        stopToolHotkeys()   // never leave the Option+N monitor live past a dismiss
    }

    // MARK: - Disable helper

    /// True when the user has temporarily paused the pill via "Disable for X minutes".
    private var isPillDisabled: Bool {
        UserDefaults.standard.double(forKey: "disabledUntil") > Date().timeIntervalSince1970
    }

    // MARK: - Settings

    /// Open (or re-focus) the Settings window. We manage a real NSWindow ourselves
    /// instead of relying on SwiftUI's `showSettingsWindow:` selector: for an
    /// accessory (menu-bar) app invoked from an NSMenu action, that selector silently
    /// no-ops because the responder chain doesn't reach the SwiftUI Settings scene.
    /// This path is deterministic — same pattern as showHotkeyPicker / showOnboarding.
    func showSettings(section: SettingsSection = .all) {
        // A grouped Form is vertically greedy → its auto-measured fitting height
        // collapses to ~0 in a hosting controller. Pin an explicit content size so
        // the Form gets a bounded height to lay out (and scroll) within.
        // SettingsView is .frame(width: 420) + default .padding() ≈ 460 wide.
        let size = settingsSize(for: section)
        let hosting = NSHostingController(rootView: SettingsView(section: section))
        hosting.preferredContentSize = size

        if settingsWindow == nil {
            let win = NSWindow(contentViewController: hosting)
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false   // reuse the instance on reopen
            settingsWindow = win
        } else {
            // Reuse the window but re-root it so reopening to a different section
            // swaps both the content and the chrome (title/size).
            settingsWindow?.contentViewController = hosting
        }

        settingsWindow?.title = section.windowTitle
        settingsWindow?.setContentSize(size)
        if let win = settingsWindow { positionSettingsWindow(win) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Place the Settings window so it never hides behind the (horizontally-centred)
    /// overlay panel: sit it just to the RIGHT of the panel, top-aligned. Falls back to
    /// the panel's left side, then a plain centre, when the screen can't fit it on the
    /// right. Centres normally when no overlay is on screen.
    private func positionSettingsWindow(_ win: NSWindow) {
        let screen = overlayWindow?.screen ?? win.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { win.center(); return }

        let s = win.frame.size
        let margin: CGFloat = 8
        var origin: NSPoint

        if let overlay = overlayWindow, overlay.isVisible {
            let gap: CGFloat = 16
            let of = overlay.frame
            let top = of.maxY - s.height          // align tops
            let rightX = of.maxX + gap
            let leftX  = of.minX - gap - s.width
            if rightX + s.width <= vf.maxX - margin {
                origin = NSPoint(x: rightX, y: top)                       // fits to the right
            } else if leftX >= vf.minX + margin {
                origin = NSPoint(x: leftX, y: top)                        // else to the left
            } else {
                origin = NSPoint(x: vf.midX - s.width / 2, y: top)        // neither — centre x
            }
        } else {
            origin = NSPoint(x: vf.midX - s.width / 2, y: vf.midY - s.height / 2)
        }

        // Keep the whole window on-screen.
        origin.x = min(max(origin.x, vf.minX + margin), vf.maxX - s.width  - margin)
        origin.y = min(max(origin.y, vf.minY + margin), vf.maxY - s.height - margin)
        win.setFrameOrigin(origin)
    }

    /// Per-section window height. The scoped sections are short; `.all` is the full
    /// stack used by the system ⌘, scene.
    private func settingsSize(for section: SettingsSection) -> NSSize {
        let h: CGFloat
        switch section {
        case .all:             h = 640
        case .windowSize:      h = 240
        case .customPrompt:    h = 360
        case .favoriteTools:   h = 520
        case .outputDirectory: h = 360
        case .scripts:         h = 560
        case .aiProvider:      h = 640
        case .capture:         h = 640
        case .enhancedAccess:  h = 360
        case .sessionSharing:  h = 360
        case .help:            h = 520
        }
        return NSSize(width: 460, height: h)
    }

    // MARK: - Hotkey picker

    func showHotkeyPicker() {
        if hotkeyPickerWindow == nil {
            let hosting = NSHostingController(rootView: HotkeyPickerView {
                self.hotkeyPickerWindow?.close()
                self.hotkeyPickerWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Drag Hotkeys"
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false
            win.center()
            hotkeyPickerWindow = win
        }
        hotkeyPickerWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Custom disable duration

    func showCustomDisable() {
        let alert = NSAlert()
        alert.messageText     = "Disable Dragaway for…"
        alert.informativeText = "Enter a duration in minutes (e.g. 45)."
        alert.addButton(withTitle: "Disable")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "Minutes"
        field.font = .systemFont(ofSize: 13)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let minutes = Int(text), minutes > 0 else { return }
        let until = Date().addingTimeInterval(Double(minutes) * 60).timeIntervalSince1970
        UserDefaults.standard.set(until, forKey: "disabledUntil")
    }

    // MARK: - Onboarding

    func showOnboarding() {
        if onboardingWindow == nil {
            let hosting = NSHostingController(rootView: OnboardingView {
                self.onboardingWindow?.close()
                self.onboardingWindow = nil
            })
            let win = NSWindow(contentViewController: hosting)
            win.title = "Welcome to Dragaway"
            win.styleMask = [.titled, .closable]
            // Above the notch overlay: OverlayWindow is .floating, so a .normal window of our
            // own app would open BEHIND it. Utility windows must sit on top when opened.
            win.level = .floating + 1
            win.isReleasedWhenClosed = false
            win.center()
            onboardingWindow = win
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === exposeWindow {
            ShareController.shared.reset()
            exposeWindow = nil
        } else if window === joinWindow {
            joinWindow = nil
        }
    }

}

// MARK: - Notification names

extension Notification.Name {
    static let showOnboarding   = Notification.Name("com.aidrop.showOnboarding")
    static let hideOverlay      = Notification.Name("com.aidrop.hideOverlay")
    static let minimizeOverlay  = Notification.Name("com.aidrop.minimizeOverlay")
    static let showHotkeyPicker = Notification.Name("com.aidrop.showHotkeyPicker")
    static let showCustomDisable = Notification.Name("com.aidrop.showCustomDisable")
    static let showFavoriteTools = Notification.Name("com.aidrop.showFavoriteTools")
    static let showOutputDirectory = Notification.Name("com.aidrop.showOutputDirectory")
    static let showScripts          = Notification.Name("com.aidrop.showScripts")
    static let showAIProvider       = Notification.Name("com.aidrop.showAIProvider")
    static let aiProviderConfigurationChanged = Notification.Name(
        "com.aidrop.aiProviderConfigurationChanged"
    )
    static let addFilesFromShare = Notification.Name("com.aidrop.addFilesFromShare")
    static let radialOpenSession = Notification.Name("com.aidrop.radialOpenSession")
    static let captureSettingsChanged = Notification.Name("com.aidrop.captureSettingsChanged")
    static let recentFileSettingsChanged = Notification.Name(
        "com.aidrop.recentFileSettingsChanged"
    )
    static let shareServiceConfigurationChanged = Notification.Name(
        "com.aidrop.shareServiceConfigurationChanged"
    )
    static let showTutorial  = Notification.Name("com.aidrop.showTutorial")
    /// Feature-usage pings for the interactive tutorial (object = TutorialStep.Trigger raw).
    static let tutorialEvent = Notification.Name("com.aidrop.tutorialEvent")
}

// MARK: - Provider resolution

func resolveProvider() -> any AIProvider {
    // Free / Pro tiers route through the hosted Worker (host key lives server-side).
    // Falls back to BYOK until the Worker URL is pasted into BackendConfig.
    if EntitlementStore.shared.tier != .byok, BackendConfig.proxyBaseURL != nil {
        return HostedProvider()
    }

    let raw  = UserDefaults.standard.string(forKey: "selectedProvider") ?? ""
    guard let type = AIProviderType(rawValue: raw) else {
        return InvalidConfigurationProvider(
            message: "The selected AI provider is no longer recognised. Open Provider Settings and choose a provider again."
        )
    }
    let catalog = AIModelCatalogStore.shared
    let modelID = catalog.selectedModelID(for: type)

    guard !catalog.selectedModelIsUnavailable(for: type) else {
        return UnavailableModelProvider(providerName: type.displayName, modelID: modelID)
    }

    let descriptor = catalog.selectedDescriptor(for: type)
    let supportsVision = descriptor.supportsVision ?? {
        switch type {
        case .gemini, .anthropic: return true
        case .openai, .groq, .ollama: return false
        }
    }()

    switch type {
    case .groq:
        return GroqProvider(
            apiKey: KeychainManager.shared.load(service: type.keychainService) ?? "",
            modelID: modelID,
            supportsVision: supportsVision,
            supportsThinking: descriptor.supportsThinking ?? false
        )
    case .gemini:
        return GeminiProvider(
            apiKey: KeychainManager.shared.load(service: type.keychainService) ?? "",
            modelID: modelID,
            supportsVision: supportsVision,
            supportsThinking: descriptor.supportsThinking ?? false
        )
    case .anthropic:
        return AnthropicProvider(
            apiKey: KeychainManager.shared.load(service: type.keychainService) ?? "",
            modelID: modelID,
            supportsVision: supportsVision
        )
    case .openai:
        return OpenAIProvider(
            apiKey: KeychainManager.shared.load(service: type.keychainService) ?? "",
            modelID: modelID,
            supportsVision: supportsVision,
            supportsThinking: descriptor.supportsThinking ?? false
        )
    case .ollama:
        return OllamaProvider(modelID: modelID, supportsVision: supportsVision)
    }
}
