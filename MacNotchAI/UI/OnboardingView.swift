import SwiftUI

struct OnboardingView: View {
    var onDismiss: () -> Void

    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @State private var apiKey = ""
    @State private var saved  = false

    private var selectedType: AIProviderType {
        AIProviderType(rawValue: selectedProvider) ?? .groq
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Header ──────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(.accentColor)
                Text("Welcome to AI Drop")
                    .font(.title2.bold())
                Text("Drag any file toward the top of your screen.\nDrop it on the pill to get instant AI insights.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 28)

            Divider().padding(.vertical, 20)

            // ── Provider picker ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose your AI provider")
                    .font(.headline)

                ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                    ProviderRow(
                        type: type,
                        isSelected: selectedProvider == type.rawValue
                    ) {
                        selectedProvider = type.rawValue
                        apiKey = KeychainManager.shared.load(service: keychainService(for: type)) ?? ""
                    }
                }
            }
            .padding(.horizontal, 28)

            // ── API key field (hidden for Ollama) ───────────────────
            if selectedType != .ollama {
                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.headline)
                        .padding(.top, 16)

                    SecureField(placeholder(for: selectedType), text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Stored securely in Keychain — never sent anywhere else.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if selectedType == .groq {
                        Link("Get a free Groq key (takes ~60 seconds) →",
                             destination: URL(string: "https://console.groq.com")!)
                            .font(.caption)
                    } else if selectedType == .anthropic {
                        Link("Get an Anthropic API key →",
                             destination: URL(string: "https://console.anthropic.com")!)
                            .font(.caption)
                    } else if selectedType == .openai {
                        Link("Get an OpenAI API key →",
                             destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.caption)
                    }
                }
                .padding(.horizontal, 28)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Make sure Ollama is running on your Mac.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Link("Download Ollama →", destination: URL(string: "https://ollama.ai")!)
                        .font(.caption)
                    Text("Then run: ollama pull llama3.1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
            }

            Spacer(minLength: 24)

            // ── CTA ──────────────────────────────────────────────────
            Button(action: saveAndDismiss) {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
            .disabled(selectedType != .ollama && apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(width: 400)
        .onAppear {
            // Pre-fill if a key already exists (e.g. re-opened from menu).
            apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
        }
    }

    private func saveAndDismiss() {
        if selectedType != .ollama {
            KeychainManager.shared.save(key: apiKey.trimmingCharacters(in: .whitespaces),
                                        service: keychainService(for: selectedType))
        }
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onDismiss()
    }

    private func keychainService(for type: AIProviderType) -> String {
        switch type {
        case .groq:      return "com.aidrop.groq"
        case .anthropic: return "com.aidrop.anthropic"
        case .openai:    return "com.aidrop.openai"
        case .ollama:    return "com.aidrop.ollama"
        }
    }

    private func placeholder(for type: AIProviderType) -> String {
        switch type {
        case .groq:      return "gsk_..."
        case .anthropic: return "sk-ant-..."
        case .openai:    return "sk-..."
        case .ollama:    return ""
        }
    }
}

// MARK: - Provider row

private struct ProviderRow: View {
    let type: AIProviderType
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(type.rawValue)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    if type == .groq {
                        Text("Free tier • recommended for new users")
                            .font(.caption).foregroundColor(.secondary)
                    } else if type == .ollama {
                        Text("100% local • no API key needed")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
