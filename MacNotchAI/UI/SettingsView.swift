import SwiftUI

struct SettingsView: View {
    @AppStorage("selectedProvider") private var selectedProvider = AIProviderType.groq.rawValue
    @State private var groqKey = ""
    @State private var anthropicKey = ""
    @State private var openAIKey = ""
    @State private var ollamaAvailable = false

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(AIProviderType.allCases, id: \.rawValue) { type in
                        Text(type.rawValue).tag(type.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("API Keys (stored securely in Keychain)") {
                if selectedProvider == AIProviderType.groq.rawValue {
                    LabeledContent("Groq API Key") {
                        SecureField("gsk_...", text: $groqKey)
                            .onSubmit {
                                KeychainManager.shared.save(key: groqKey, service: "com.aidrop.groq")
                            }
                    }
                    Link("Get a free Groq key →", destination: URL(string: "https://console.groq.com")!)
                        .font(.caption)
                }

                if selectedProvider == AIProviderType.anthropic.rawValue {
                    LabeledContent("Anthropic API Key") {
                        SecureField("sk-ant-...", text: $anthropicKey)
                            .onSubmit {
                                KeychainManager.shared.save(key: anthropicKey, service: "com.aidrop.anthropic")
                            }
                    }
                    Link("Get an Anthropic key →", destination: URL(string: "https://console.anthropic.com")!)
                        .font(.caption)
                }

                if selectedProvider == AIProviderType.openai.rawValue {
                    LabeledContent("OpenAI API Key") {
                        SecureField("sk-...", text: $openAIKey)
                            .onSubmit {
                                KeychainManager.shared.save(key: openAIKey, service: "com.aidrop.openai")
                            }
                    }
                    Link("Get an OpenAI key →", destination: URL(string: "https://platform.openai.com")!)
                        .font(.caption)
                }
            }

            if selectedProvider == AIProviderType.ollama.rawValue {
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
        .frame(width: 450)
        .padding()
        .onAppear(perform: loadSavedKeys)
    }

    private func loadSavedKeys() {
        groqKey      = KeychainManager.shared.load(service: "com.aidrop.groq") ?? ""
        anthropicKey = KeychainManager.shared.load(service: "com.aidrop.anthropic") ?? ""
        openAIKey    = KeychainManager.shared.load(service: "com.aidrop.openai") ?? ""
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
