import SwiftUI
import UIKit
import WristAssistShared

struct ContentView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isAPIKeyVisible = false
    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        NavigationStack {
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
                                viewModel.clearAPIKey()
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
                    if let lastError = viewModel.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("WristAssist")
            .navigationBarTitleDisplayMode(.inline)
        }
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
}
