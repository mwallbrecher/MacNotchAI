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

    @State private var participantID = ""
    @State private var readIt = false
    @State private var selectedLanguages: Set<String>

    init(initialLanguages: [String],
         onAccept: @escaping (String, [String]) -> Void,
         onCancel: @escaping () -> Void) {
        self.onAccept = onAccept
        self.onCancel = onCancel
        let initial = Set(initialLanguages).union(["en"])
        _selectedLanguages = State(initialValue: initial)
    }

    private var canAccept: Bool {
        readIt && !participantID.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedLanguages.contains("en")
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
                          + "· which applications are in front\n"
                          + "· measurements of text — its length, language and shape, such as "
                          + "prose or code\n"
                          + "· short one-way fingerprints, used only to tell 'the same thing "
                          + "again' from 'something new'\n"
                          + "· compact numerical language representations, used to measure whether "
                          + "several copied passages concern the same topic\n"
                          + "· every suggestion you were shown or asked for, and what you did "
                          + "with it")

                    section("What is never recorded",
                            "· the study log and export never contain the actual text you read, "
                          + "write, copy or select\n"
                          + "· no screenshots, no keystrokes, no passwords\n"
                          + "· nothing from password managers or fields marked secure\n"
                          + "· no web addresses, file paths or document names")

                    section("When the system does read a document",
                            "When you ask for help, Dragaway briefly checks the current selection "
                          + "or document on this Mac to decide which actions are possible. It keeps "
                          + "only a fingerprint and measurements and immediately discards the text. "
                          + "The actual text is read again and handed to an action only after you "
                          + "choose that action; this never happens in the background.")

                    section("Where it stays",
                            "The recorded study data stays on this machine and is never uploaded "
                          + "automatically. At the end you create a file yourself and send it only "
                          + "if you still want to. It lists everything inside it in plain language "
                          + "before you do. AI actions use the provider configured in Dragaway; "
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
                    onAccept(participantID.trimmingCharacters(in: .whitespaces),
                             selectedLanguages.sorted())
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAccept)
            }
        }
        .padding(22)
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
