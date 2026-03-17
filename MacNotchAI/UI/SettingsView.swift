import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @State private var apiKey = ""
    @State private var ollamaAvailable = false
    @State private var saved = false

    private var selectedType: AIProviderType {
        AIProviderType(rawValue: selectedProvider) ?? .groq
    }

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: selectedProvider) { _ in
                    apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
                    saved = false
                }
            }

            if selectedType != .ollama {
                Section("API Key (stored securely in Keychain)") {
                    SecureField(placeholder(for: selectedType), text: $apiKey)

                    HStack {
                        Button("Save Key") {
                            KeychainManager.shared.save(
                                key: apiKey.trimmingCharacters(in: .whitespaces),
                                service: keychainService(for: selectedType)
                            )
                            saved = true
                        }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                        if saved {
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }

                        Spacer()

                        switch selectedType {
                        case .groq:
                            Link("Get a free Groq key →", destination: URL(string: "https://console.groq.com")!)
                                .font(.caption)
                        case .anthropic:
                            Link("Get an Anthropic key →", destination: URL(string: "https://console.anthropic.com")!)
                                .font(.caption)
                        case .openai:
                            Link("Get an OpenAI key →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                                .font(.caption)
                        case .ollama:
                            EmptyView()
                        }
                    }
                }
            } else {
                Section("Ollama (Local)") {
                    HStack {
                        Circle()
                            .fill(ollamaAvailable ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(ollamaAvailable ? "Ollama is running" : "Ollama not detected")
                            .font(.caption)
                    }
                    Link("Download Ollama →", destination: URL(string: "https://ollama.ai")!)
                        .font(.caption)
                    Text("After installing, run: ollama pull llama3.1")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
                .task { ollamaAvailable = await isOllamaRunning() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
        .onAppear {
            apiKey = KeychainManager.shared.load(service: keychainService(for: selectedType)) ?? ""
        }
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

/// Checks whether Ollama is running by pinging its health endpoint.
/// Uses proper async/await instead of a blocking semaphore.
private func isOllamaRunning() async -> Bool {
    guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
    var request = URLRequest(url: url, timeoutInterval: 1.5)
    request.httpMethod = "GET"
    do {
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
        return false
    }
}
