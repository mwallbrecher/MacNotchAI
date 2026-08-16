import AppKit
import ApplicationServices
import Combine
import SwiftUI

// THESIS (study instrumentation, M5) — informed consent, at the point of installation.
//
// Shown once, with the researcher present, at the onboarding meeting. It is the
// artefact that makes the deployment lawful and the one the ethics submission has to
// match, so the wording is deliberately plain and deliberately unflattering to the
// project: a participant who only skims must still come away knowing that a record of
// how they work is being kept on their own machine for two weeks.
//
// Two commitments here are stronger than the approved proposal's, and knowingly so.
// The proposal says data will be "anonymised using participant IDs"; the
// implementation refuses that claim, because content-minimised behavioural data with
// partially invertible embeddings and hash prefixes is pseudonymous, not anonymous.
// The honest wording is used here and the discrepancy is recorded for the methodology
// chapter rather than quietly smoothed over.
struct StudyConsentView: View {

    var onAccept: (String, [String]) -> Void
    var onCancel: () -> Void
    var onRequestAccessibility: () -> Void
    var onFixLoginLaunch: () -> Void

    @State private var participantID = ""
    @State private var readIt = false
    @State private var selectedLanguages: Set<String>
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var loginLaunchState = StudyLaunchManager.state

    init(initialLanguages: [String],
         onAccept: @escaping (String, [String]) -> Void,
         onCancel: @escaping () -> Void,
         onRequestAccessibility: @escaping () -> Void,
         onFixLoginLaunch: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onCancel = onCancel
        self.onRequestAccessibility = onRequestAccessibility
        self.onFixLoginLaunch = onFixLoginLaunch
        let initial = Set(initialLanguages).union(["en"])
        _selectedLanguages = State(initialValue: initial)
    }

    private var canAccept: Bool {
        readIt && !participantID.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedLanguages.contains("en")
            && accessibilityGranted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("What this study is",
                            "You are helping test whether a computer can offer the right kind of "
                          + "help at the moment you need it — without you having to stop, open a "
                          + "separate tool, and describe your situation. For about two weeks, "
                          + "Dragaway records how you work so that the parts you found useful can "
                          + "be told apart from the parts that got in the way.")

                    section("What is recorded",
                            "· when you copy, scroll, pause, switch apps, or step away\n"
                          + "· when clipboard ownership changes; if the new item is marked "
                          + "sensitive or cannot be safely classified, only a content-free "
                          + "replacement marker is kept so old evidence and suggestions can be "
                          + "cancelled\n"
                          + "· which applications are in front\n"
                          + "· measurements of text — its length, language and shape, such as "
                          + "prose or code\n"
                          + "· short one-way fingerprints, used only to tell 'the same thing "
                          + "again' from 'something new'\n"
                          + "· compact numerical language representations, used to measure whether "
                          + "several copied passages concern the same topic\n"
                          + "· derived Accessibility context: focused-field category and "
                          + "editability, document type, target language, read method, and rounded "
                          + "caret or visible-range progress\n"
                          + "· every suggestion you were shown or asked for, and what you did "
                          + "with it")

                    section("What is never recorded",
                            "· the study log and export never contain the actual text you read, "
                          + "write, copy or select\n"
                          + "· no screenshots, no keystrokes, no passwords\n"
                          + "· no content, item type, source application or fingerprint from "
                          + "password managers or other clipboard items marked sensitive; only "
                          + "the content-free replacement marker described above\n"
                          + "· nothing is read from fields marked secure\n"
                          + "· no web addresses, file paths or document names")

                    section("When the system does read a document",
                            "While study recording is active and not paused, Dragaway uses macOS "
                          + "Accessibility to inspect the focused field's role, selected text, the "
                          + "path or window title of the open document, and a bounded text range. "
                          + "For an eligible local Word file, a size-limited .docx archive may be "
                          + "temporarily imported so that only a bounded sample can be classified. "
                          + "These local reads derive language, context and approximate reading or "
                          + "caret progress. Raw text, paths, document names and window titles are "
                          + "not written to the study log or export and are discarded after those "
                          + "measurements are derived. If you accept an AI action, Dragaway reads the "
                          + "exact copied, selected or document source again and sends it to the AI "
                          + "provider configured in Dragaway.")

                    section("Where it stays",
                            "The recorded study data stays on this machine and is never uploaded "
                          + "automatically. At the end you create a file yourself and send it only "
                          + "if you still want to. The archive contains a plain-language manifest "
                          + "that you can inspect before sending it. AI actions use the provider configured in Dragaway; "
                          + "their normal provider traffic is not part of the study recording or "
                          + "the exported study file.")

                    section("This data is not anonymous",
                            "It is stripped of content, but it is a detailed record of how one "
                          + "person worked over several days, and patterns of work can identify "
                          + "someone. It is treated as personal data: used only for this "
                          + "dissertation, and deleted no later than twelve months after "
                          + "submission.")

                    section("You stay in control",
                            "Pause recording at any time from the menu. Withdraw whenever you "
                          + "like, without giving a reason — if you never send the file, none of "
                          + "your data is used. Once sent, you can ask for it to be deleted up to "
                          + "two weeks afterwards.")

                    section("Auto-update is switched off",
                            "This is a research build. It will not update itself during the study, "
                          + "so what you agree to today is what runs for the whole two weeks.")
                }
                .padding(22)
            }

            Divider()
            footer
        }
        .frame(width: 590, height: 700)
        .onAppear(perform: refreshReadiness)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            // macOS exposes no dedicated "permission changed" notification. Returning
            // from System Settings is the reliable, non-polling reconciliation point.
            refreshReadiness()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Research participation")
                .font(.title2.weight(.semibold))
            Text("MSc User Experience Design · Kingston University · CI7801")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            readiness

            HStack(spacing: 10) {
                Text("Participant ID")
                    .font(.callout.weight(.medium))
                TextField("e.g. P03", text: $participantID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
                Text("assigned by the researcher — not your name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Languages the participant reads")
                    .font(.callout.weight(.medium))
                Text("English is required for the study tasks. Select every additional language so translation evidence is judged against the participant, not this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                         count: 4), alignment: .leading, spacing: 6) {
                    languageToggle("English", code: "en", locked: true)
                    ForEach(Self.languageOptions, id: \.code) { option in
                        languageToggle(option.name, code: option.code)
                    }
                }
            }

            Toggle(isOn: $readIt) {
                Text("I have read the above, had the chance to ask questions, and agree to take part.")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)

            HStack {
                Button("Not now", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start recording") {
                    // The displayed state can become stale if permission is revoked
                    // while this window is open, so enforce trust again at the click.
                    guard AXIsProcessTrusted() else {
                        refreshReadiness()
                        onRequestAccessibility()
                        return
                    }
                    onAccept(participantID.trimmingCharacters(in: .whitespaces),
                             selectedLanguages.sorted())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAccept)
            }
        }
        .padding(22)
    }

    private var readiness: some View {
        GroupBox("Study readiness") {
            VStack(alignment: .leading, spacing: 10) {
                readinessRow(
                    title: "Accessibility",
                    detail: "Required for the disclosed focused-selection and document-context reads.",
                    ready: accessibilityGranted,
                    status: accessibilityGranted ? "Granted" : "Required",
                    actionTitle: accessibilityGranted ? nil : "Grant…",
                    action: {
                        onRequestAccessibility()
                        refreshReadiness()
                    })

                Divider()

                readinessRow(
                    title: "Launch at Login",
                    detail: "Keeps a 24-hour recording available after a restart.",
                    ready: loginLaunchState == .enabled,
                    status: loginLaunchStatus,
                    actionTitle: loginLaunchState == .enabled ? nil : loginLaunchActionTitle,
                    action: {
                        onFixLoginLaunch()
                        refreshReadiness()
                    })
            }
            .padding(.vertical, 4)
        }
    }

    private var loginLaunchStatus: String {
        switch loginLaunchState {
        case .enabled: return "Enabled"
        case .requiresApproval: return "Approval required"
        case .notRegistered: return "Not registered"
        case .unavailable: return "Unavailable"
        }
    }

    private var loginLaunchActionTitle: String {
        switch loginLaunchState {
        case .enabled: return ""
        case .requiresApproval: return "Open Settings…"
        case .notRegistered: return "Register…"
        case .unavailable: return "Check…"
        }
    }

    private func readinessRow(title: String,
                              detail: String,
                              ready: Bool,
                              status: String,
                              actionTitle: String?,
                              action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ready ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.callout.weight(.medium))
                    Text(status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ready ? Color.green : Color.orange)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let actionTitle {
                Button(actionTitle, action: action)
            }
        }
    }

    private func refreshReadiness() {
        accessibilityGranted = AXIsProcessTrusted()
        loginLaunchState = StudyLaunchManager.state
    }

    private func languageToggle(_ name: String, code: String,
                                locked: Bool = false) -> some View {
        Toggle(name, isOn: Binding(
            get: { selectedLanguages.contains(code) },
            set: { enabled in
                guard !locked else { return }
                if enabled { selectedLanguages.insert(code) }
                else { selectedLanguages.remove(code) }
            }))
        .toggleStyle(.checkbox)
        .disabled(locked)
        .font(.caption)
    }

    private static let languageOptions: [(code: String, name: String)] = [
        ("de", "German"), ("es", "Spanish"), ("fr", "French"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("pl", "Polish"), ("tr", "Turkish"), ("ru", "Russian"),
        ("ar", "Arabic"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("hi", "Hindi"), ("bn", "Bengali"),
        ("ta", "Tamil"), ("te", "Telugu"), ("mr", "Marathi"),
        ("gu", "Gujarati"), ("kn", "Kannada"), ("ml", "Malayalam"),
        ("pa", "Punjabi"), ("ur", "Urdu"),
    ]

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
