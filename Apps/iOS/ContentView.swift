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
                            Button("Clear") {
                                isAPIKeyVisible = false
                                isAPIKeyFieldFocused = false
                                viewModel.clearAPIKeyDraft()
                            }

                            Spacer()

                            Button(isAPIKeyVisible ? "Hide" : "Show") {
                                isAPIKeyFieldFocused = false
                                isAPIKeyVisible.toggle()
                            }
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button("Paste") {
                            isAPIKeyVisible = false
                            isAPIKeyFieldFocused = false
                            viewModel.updateAPIKeyDraft(UIPasteboard.general.string ?? "")
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

                Section("Realtime") {
                    TextField("Model", text: $viewModel.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Voice", text: $viewModel.voice)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Instructions", text: $viewModel.instructions, axis: .vertical)
                        .lineLimit(3...6)

                    Button("Send Settings to Watch") {
                        viewModel.sendSettingsToWatch()
                    }
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
            .onChange(of: viewModel.model) { _, _ in
                viewModel.persistSettings()
            }
            .onChange(of: viewModel.voice) { _, _ in
                viewModel.persistSettings()
            }
            .onChange(of: viewModel.instructions) { _, _ in
                viewModel.persistSettings()
            }
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

    @ViewBuilder
    private var saveAPIKeyButton: some View {
        if viewModel.hasUnsavedAPIKeyChanges {
            HStack {
                Button("Save") {
                    isAPIKeyFieldFocused = false
                    Task {
                        await viewModel.saveAPIKeyDraft()
                    }
                }
                .disabled(!viewModel.canSaveAPIKey)

                Spacer()
            }
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
