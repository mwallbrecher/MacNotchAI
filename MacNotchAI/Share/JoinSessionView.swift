import AppKit
import SwiftUI

/// Recipient flow: one reusable six-digit Session ID, followed by a password only when the sender
/// chose E2EE. The resulting session is a local fork and continues with the recipient's provider.
struct JoinSessionView: View {

    var onImported: (UUID) -> Void
    var onClose: () -> Void

    @State private var sessionIDText = ""
    @State private var password = ""
    @State private var pendingImport: ShareController.PendingImport?
    @State private var busy = false
    @State private var error: String?
    @State private var joinTask: Task<Void, Never>?

    private var parsedSessionID: ShareSessionID? {
        ShareSessionID.parse(sessionIDText)
    }

    private var passwordIsValid: Bool {
        let bytes = password.utf8.count
        return bytes >= ShareCrypto.minimumPasswordBytes
            && bytes <= ShareCrypto.maximumPasswordBytes
    }

    private var needsPassword: Bool { pendingImport != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Join Session").font(.system(size: 16, weight: .semibold))
                    Text("Enter the Session ID your colleague shared")
                        .font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }

            Divider().padding(.vertical, 14)

            TextField("000000", text: $sessionIDText)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
                .onSubmit(join)
                .onChange(of: sessionIDText) { _, newValue in
                    // Pasted spaces and dashes are presentation only; keep one six-digit value.
                    let digits = String(newValue.filter(\.isNumber).prefix(6))
                    if digits != newValue { sessionIDText = digits }
                    pendingImport = nil
                    password = ""
                    error = nil
                }
                .disabled(busy || needsPassword)

            if needsPassword {
                VStack(alignment: .leading, spacing: 5) {
                    Text("This snapshot is end-to-end encrypted.")
                        .font(.system(size: 11.5)).foregroundColor(.secondary)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5))
                        .onSubmit(join)
                        .onChange(of: password) { _, _ in error = nil }
                    Text("Password checks happen locally; retrying does not contact the service again.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                .padding(.top, 12)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Button(action: join) {
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(buttonTitle).frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || parsedSessionID == nil || (needsPassword && !passwordIsValid))
            .padding(.top, 16)
        }
        .padding(22)
        .frame(width: 380)
        .onDisappear {
            joinTask?.cancel()
            joinTask = nil
        }
    }

    private var buttonTitle: String {
        if busy { return needsPassword ? "Decrypting…" : "Fetching…" }
        return needsPassword ? "Decrypt & Open" : "Open Session"
    }

    private func join() {
        guard !busy,
              let sessionID = parsedSessionID,
              !needsPassword || passwordIsValid else { return }
        busy = true
        error = nil

        joinTask?.cancel()
        joinTask = Task {
            let result: ShareController.ImportResult
            if let pendingImport {
                result = await ShareController.shared.finishImport(pendingImport, password: password)
            } else {
                result = await ShareController.shared.beginImport(sessionID: sessionID)
            }

            guard !Task.isCancelled else { return }
            busy = false
            joinTask = nil

            switch result {
            case .success(let localSessionID):
                onImported(localSessionID)
                onClose()

            case .needsPassword(let pending):
                if pendingImport != nil { error = "Wrong password." }
                pendingImport = pending

            case .failure(let message):
                error = message
            }
        }
    }
}
