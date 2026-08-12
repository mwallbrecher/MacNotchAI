import SwiftUI
import AppKit

/// The "Expose Session" panel. `docs/SHARE_ARCHITECTURE.md` §5.
///
/// The disclosure text is the point of this screen, not decoration: it names every file that
/// will leave the Mac, how it is encrypted, WHO CAN READ IT, and when it disappears — and it
/// changes live when a password is set, because that genuinely changes the answer.
struct ExposeSessionView: View {

    let fileURLs: [URL]
    let turns: [SessionTurn]
    var onClose: () -> Void

    @ObservedObject private var controller = ShareController.shared
    @State private var password = ""
    @State private var usePassword = false
    @State private var copied = false

    private var passwordByteCount: Int { password.utf8.count }
    private var hasValidPassword: Bool {
        usePassword
            && passwordByteCount >= ShareCrypto.minimumPasswordBytes
            && passwordByteCount <= ShareCrypto.maximumPasswordBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.vertical, 14)

            switch controller.phase {
            case .idle:                        idleState
            case .packing, .uploading:         busyState
            case .exposed(let record, let pw): exposedState(record: record, hadPassword: pw)
            case .revoking:                   revokingState
            case .failed(let message):         failedState(message)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear { controller.prepare(fileURLs: fileURLs) }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Expose Session").font(.system(size: 16, weight: .semibold))
                Text("Share it with a colleague").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Before exposing

    private var idleState: some View {
        VStack(alignment: .leading, spacing: 16) {
            if controller.pendingFileNames.count > 1 {
                multiFileWarning
            }
            disclosure

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $usePassword) {
                    Text("Protect with a password").font(.system(size: 12.5))
                }
                .toggleStyle(.checkbox)

                if usePassword {
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .onSubmit(expose)
                    Text("12–256 UTF-8 bytes. Send it through a different channel than the Session ID.")
                        .font(.caption2)
                        .foregroundColor(password.isEmpty || hasValidPassword ? .secondary : .orange)
                }
            }

            Button(action: expose) {
                Text("Expose Session").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(usePassword && !hasValidPassword)
        }
    }

    /// The honest disclosure. Two variants, because the security guarantee genuinely differs
    /// (§2) — claiming end-to-end encryption without a password would be false.
    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("doc.fill", "What leaves your Mac",
                disclosureFileSummary + " and this session's AI results. Nothing else.")

            if usePassword {
                row("lock.fill", "End-to-end encrypted",
                    "The key is derived on this Mac. The password and key are never uploaded, so the service cannot read the snapshot.")
            } else {
                row("person.2", "Session ID is the access key",
                    "Anyone with the 6-digit ID can open this snapshot while it is active. The service holds the decryption key, so use this tier only for non-confidential files.")
            }

            row("clock.arrow.circlepath", "Reusable for 24 hours",
                "Multiple colleagues can open their own local copy until you revoke the share or it expires. Their later work is never synced back.")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private var disclosureFileSummary: String {
        let names = controller.pendingFileNames
        let subject = names.count == 1 ? (names.first ?? "1 file") : "\(names.count) files"
        return subject + (controller.pendingSize.isEmpty ? "" : " · \(controller.pendingSize)")
    }

    /// Multi-file sharing has no hidden selection state: the exact staged snapshot is listed here,
    /// and the user returns to the session browser to remove anything they did not intend to send.
    private var multiFileWarning: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Multiple files will be shared", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(.orange)
            Text("All \(controller.pendingFileNames.count) files currently staged in this session will be encrypted and shared. Make sure every file below is intended before you continue.")
                .font(.system(size: 11.5))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(controller.pendingFileNames.enumerated()), id: \.offset) { entry in
                    Text("• \(entry.element)")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.element)
                }
            }
            Text("Remove unintended files from the session, then open Expose Session again.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func row(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(usePassword && icon == "lock.fill" ? .green : .secondary)
                .frame(width: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(body).font(.system(size: 11.5)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Busy

    private var busyState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(controller.phase == .packing ? "Encrypting…" : "Uploading…")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    private var revokingState: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Revoking…")
                .font(.system(size: 12.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 24)
    }

    // MARK: Exposed — the code

    private func exposedState(record: ActiveShareRecord, hadPassword: Bool) -> some View {
        let rawSessionID = record.sessionID ?? ""
        let formattedSessionID = ShareSessionID(rawValue: rawSessionID)?.formatted ?? rawSessionID
        return VStack(alignment: .leading, spacing: 15) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Share this Session ID").font(.system(size: 12)).foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Text(formattedSessionID)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        let item = NSPasteboardItem()
                        item.setString(rawSessionID, forType: .string)
                        item.setString("", forType: NSPasteboard.PasteboardType(
                            "org.nspasteboard.TransientType"))
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([item])
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11.5))
                    }
                    .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Colleagues open Dragaway → Join Session → enter this ID. Each receives the same snapshot as a separate local session.")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hadPassword {
                    Label("They will also need the password.", systemImage: "lock.fill")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                }
                Label("Reusable until \(record.expiresAt.formatted(date: .abbreviated, time: .shortened)), unless revoked",
                      systemImage: "clock")
                    .font(.system(size: 11.5)).foregroundColor(.secondary)
            }

            HStack {
                Button("Revoke now") { controller.revoke() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { controller.reset(); onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Failure

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Try again") { controller.reset() }.buttonStyle(.bordered)
                Button("Close") { controller.reset(); onClose() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func expose() {
        guard controller.phase == .idle,
              !usePassword || hasValidPassword else { return }
        controller.expose(
            fileURLs: fileURLs,
            turns: turns,
            password: hasValidPassword ? password : nil
        )
    }
}
