import SwiftUI
import UIKit
import NadgarShared

struct ContentView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProviderProfilesView(viewModel: viewModel)
                    } label: {
                        ConfigureProvidersRow()
                    }
                }

                Section("About") {
                    Link("Privacy Policy", destination: NadgarLinks.privacyPolicy)
                    Link("FAQ", destination: NadgarLinks.faq)
                }
            }
            .navigationTitle("Nadgar")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ConfigureProvidersRow: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 42, height: 42)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Configure Providers")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Enable and configure transcription and response providers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ProviderProfilesView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                NavigationLink("OpenAI API") {
                    OpenAIProviderSettingsView(viewModel: viewModel)
                }
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OpenAIProviderSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isAPIKeyVisible = false
    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        Form {
            Section("OpenAI API Key") {
                apiKeyField
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if hasAPIKeyText {
                    HStack {
                        Button(role: .destructive) {
                            isAPIKeyVisible = false
                            isAPIKeyFieldFocused = false
                            viewModel.clearAPIKeyButtonTapped()
                        } label: {
                            Text("Clear")
                                .foregroundStyle(.red)
                        }
                        .disabled(!viewModel.canClearAPIKey)

                        Spacer()

                        Button(isAPIKeyVisible ? "Hide" : "Show") {
                            isAPIKeyFieldFocused = false
                            isAPIKeyVisible.toggle()
                        }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button {
                        isAPIKeyVisible = false
                        isAPIKeyFieldFocused = false
                        viewModel.updateAPIKeyDraft(UIPasteboard.general.string ?? "")
                    } label: {
                        fullWidthButtonLabel("Paste")
                    }
                    .buttonStyle(.borderless)
                }

                saveAPIKeyButton

                if viewModel.isSavingAPIKey {
                    ProgressView("Validating...")
                }

                if let apiKeyValidationError = viewModel.apiKeyValidationError {
                    Text(apiKeyValidationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                apiKeyHelp
            }

            Section("Personalization") {
                Picker("Response model", selection: $viewModel.assistantModel) {
                    ForEach(ProviderSettings.supportedAssistantModels) { model in
                        Text(model.displayName).tag(model.apiValue)
                    }
                }

                Picker("Transcription", selection: $viewModel.transcriptionModel) {
                    ForEach(ProviderSettings.supportedTranscriptionModels) { model in
                        Text(model.displayName).tag(model.apiValue)
                    }
                }

                Toggle("Read responses aloud", isOn: autoReadBinding)

                if viewModel.isAutoReadEnabled {
                    Toggle("Ignore Silent Mode", isOn: ignoreSilentModeBinding)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Picker("Voice", selection: $viewModel.voice) {
                    ForEach(ProviderSettings.supportedVoices) { voice in
                        Text(voice.displayName).tag(voice.apiValue)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("Prompt", text: $viewModel.instructions, axis: .vertical)
                        .lineLimit(3...6)
                }

                savePersonalizationButton
            }

            Section("Watch") {
                LabeledContent("Connectivity", value: viewModel.watchStatus)
                Button(role: .destructive) {
                    viewModel.clearConversationHistoryOnWatch()
                } label: {
                    fullWidthButtonLabel("Clear Conversation History")
                }
                .buttonStyle(.borderless)

                if let lastError = viewModel.lastError {
                    Text(lastError)
                        .foregroundStyle(.red)
                }
            }

        }
        .navigationTitle("OpenAI API")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.default, value: viewModel.isAutoReadEnabled)
    }

    private var apiKeyField: some View {
        Group {
            if isAPIKeyVisible {
                TextField("sk-...", text: apiKeyDraftBinding)
                    .focused($isAPIKeyFieldFocused)
                    .textContentType(.password)
            } else {
                SecureField("sk-...", text: apiKeyDraftBinding)
                    .focused($isAPIKeyFieldFocused)
                    .textContentType(.password)
            }
        }
        .frame(minHeight: 36)
        .disabled(viewModel.isSavingAPIKey)
    }

    private func fullWidthButtonLabel(_ title: String) -> some View {
        HStack {
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var saveAPIKeyButton: some View {
        if viewModel.hasUnsavedAPIKeyChanges {
            Button {
                isAPIKeyFieldFocused = false
                Task {
                    await viewModel.saveAPIKeyDraft()
                }
            } label: {
                fullWidthButtonLabel("Save")
            }
            .disabled(!viewModel.canSaveAPIKey)
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var savePersonalizationButton: some View {
        if viewModel.hasUnsavedSettingsChanges {
            Button {
                viewModel.saveSettings()
            } label: {
                HStack {
                    Text("Save")
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .disabled(!viewModel.canSaveSettings)
            .buttonStyle(.borderless)
        }
    }

    private var apiKeyHelp: some View {
        Text("Get an API key from [OpenAI](https://platform.openai.com/login?next=/api-keys). Billing must be enabled on your OpenAI account.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var hasAPIKeyText: Bool {
        viewModel.hasAPIKeyText
    }

    private var apiKeyDraftBinding: Binding<String> {
        Binding {
            viewModel.apiKeyDraft
        } set: { newValue in
            viewModel.updateAPIKeyDraft(newValue)
        }
    }

    private var autoReadBinding: Binding<Bool> {
        Binding {
            viewModel.isAutoReadEnabled
        } set: { newValue in
            viewModel.setAutoReadEnabled(newValue)
        }
    }

    private var ignoreSilentModeBinding: Binding<Bool> {
        Binding {
            viewModel.shouldIgnoreSilentModeForAutoRead
        } set: { newValue in
            viewModel.setShouldIgnoreSilentModeForAutoRead(newValue)
        }
    }
}

private enum NadgarLinks {
    static let privacyPolicy = URL(string: "https://nadgar.app/#privacy")!
    static let faq = URL(string: "https://nadgar.app/#faq")!
}
