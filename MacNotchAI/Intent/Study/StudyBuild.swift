import Foundation
import ServiceManagement

// THESIS — immutable identity of the manually distributed research artefact.
//
// Study safety must not depend on a UserDefaults flag set after launch. Both Debug
// and Release configurations on `thesis` define THESIS_STUDY_BUILD, and the bundle
// carries a marker that can be inspected before a DMG is handed to a participant.
enum StudyBuild {
    static let bundleMarkerKey = "DragawayStudyBuild"

    static var isInstrument: Bool {
#if THESIS_STUDY_BUILD
        true
#else
        false
#endif
    }

    /// A distributable study artefact has no Sparkle feed/key and explicitly disables
    /// automatic checks. `scripts/release.sh` also rejects it because that script
    /// requires SUPublicEDKey before generating the public appcast.
    static var invariantViolations: [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        var failures: [String] = []

        if !isInstrument {
            failures.append("THESIS_STUDY_BUILD is not compiled in")
        }
        if info[bundleMarkerKey] as? Bool != true {
            failures.append("bundle study marker is missing")
        }
        if info["SUFeedURL"] != nil {
            failures.append("public Sparkle feed is embedded")
        }
        if info["SUPublicEDKey"] != nil {
            failures.append("public Sparkle signing key is embedded")
        }
        if (info["SUEnableAutomaticChecks"] as? Bool) != false {
            failures.append("automatic update checks are not explicitly disabled")
        }
        if let frameworks = Bundle.main.privateFrameworksURL,
           let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path),
           names.contains(where: { $0.localizedCaseInsensitiveContains("sparkle") }) {
            failures.append("a Sparkle framework is embedded")
        }
        return failures
    }

    static var isSafeForStudyDistribution: Bool { invariantViolations.isEmpty }
}

/// Registers the signed main app as a per-user login item. A reboot can only resume
/// the recorder if macOS launches the app again; this makes that dependency explicit
/// and inspectable instead of treating a successful relaunch test as luck.
enum StudyLaunchManager {
    enum State: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case unavailable

        var label: String {
            switch self {
            case .enabled: return "launches at login"
            case .requiresApproval: return "login launch needs approval"
            case .notRegistered: return "login launch is not registered"
            case .unavailable: return "login launch is unavailable"
            }
        }
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Called with the researcher present during study setup. Registration can still
    /// require the participant to approve the item in System Settings; the caller must
    /// surface the returned state and must not claim reboot survival until `.enabled`.
    @discardableResult
    static func ensureRegistered() throws -> State {
        if state == .notRegistered {
            try SMAppService.mainApp.register()
        }
        return state
    }

    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func unregister() throws {
        guard state != .notRegistered else { return }
        try SMAppService.mainApp.unregister()
    }
}
