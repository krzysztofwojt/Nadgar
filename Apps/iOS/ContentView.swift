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

                PersonalizationSection(viewModel: viewModel)

                Section("Watch") {
                    LabeledContent("Connectivity", value: viewModel.watchStatus)
                    LabeledContent("Keychain", value: viewModel.keychainStatus)

                    if let lastError = viewModel.lastError {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        viewModel.clearConversationHistoryOnWatch()
                    } label: {
                        FullWidthButtonLabel("Clear Conversation History")
                    }
                    .buttonStyle(.borderless)
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

private struct PersonalizationSection: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Section("Personalization") {
            modelPicker(
                title: "Response model",
                selection: responseSelectionBinding,
                options: viewModel.responseModelOptions
            )

            modelPicker(
                title: "Transcription",
                selection: transcriptionSelectionBinding,
                options: viewModel.transcriptionModelOptions
            )

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

            if viewModel.hasUnsavedSettingsChanges {
                Button {
                    viewModel.saveSettings()
                } label: {
                    FullWidthButtonLabel("Save")
                }
                .disabled(!viewModel.canSaveSettings)
                .buttonStyle(.borderless)
            }
        }
        .animation(.default, value: viewModel.isAutoReadEnabled)
    }

    @ViewBuilder
    private func modelPicker(
        title: String,
        selection: Binding<TaskModelSelection?>,
        options: [ProviderModelOption]
    ) -> some View {
        if options.isEmpty {
            LabeledContent(title, value: "Not configured")
                .foregroundStyle(.secondary)
        } else {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.displayName).tag(Optional(option.selection))
                }
            }
        }
    }

    private var responseSelectionBinding: Binding<TaskModelSelection?> {
        Binding {
            viewModel.selectedResponse
        } set: { newValue in
            viewModel.selectedResponse = newValue
        }
    }

    private var transcriptionSelectionBinding: Binding<TaskModelSelection?> {
        Binding {
            viewModel.selectedTranscription
        } set: { newValue in
            viewModel.selectedTranscription = newValue
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

private struct ProviderProfilesView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                if viewModel.providerProfiles.isEmpty {
                    Text("No providers")
                        .foregroundStyle(.secondary)
                }

                ForEach(viewModel.providerProfiles) { profile in
                    NavigationLink {
                        ProviderDetailView(viewModel: viewModel, profileID: profile.id)
                    } label: {
                        ProviderProfileRow(profile: profile)
                    }
                }
                .onDelete(perform: viewModel.deleteProviders)

                NavigationLink {
                    AddProviderTypeView(viewModel: viewModel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .font(.title3)
                            .accessibilityHidden(true)

                        Text("Add Provider")
                    }
                }
            }
        }
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
        }
    }
}

private struct AddProviderTypeView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var createdProviderRoute: ProviderRoute?

    var body: some View {
        Form {
            Section {
                Button {
                    select(.openAI)
                } label: {
                    ProviderTypeRow(title: "OpenAI API", subtitle: "OpenAI API")
                }
                .buttonStyle(.plain)

                Button {
                    select(.custom)
                } label: {
                    ProviderTypeRow(title: "Custom", subtitle: "Not configurable yet")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("Add Provider")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $createdProviderRoute) { route in
            ProviderDetailView(viewModel: viewModel, profileID: route.profileID)
        }
    }

    private func select(_ type: ProviderType) {
        let profileID = viewModel.addProvider(type: type)
        createdProviderRoute = ProviderRoute(profileID: profileID)
    }
}

private struct ProviderTypeRow: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct ProviderRoute: Hashable, Identifiable {
    var profileID: String

    var id: String {
        profileID
    }
}

private struct ProviderProfileRow: View {
    var profile: ProviderProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(profile.name)
                .font(.body)
                .foregroundStyle(.primary)

            Text(profile.type.displayName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct ProviderDetailView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var profileID: String

    var body: some View {
        if let profile = viewModel.settings.profile(id: profileID) {
            switch profile.type {
            case .openAI:
                OpenAIProviderSettingsView(viewModel: viewModel, profileID: profileID)
            case .custom:
                CustomProviderSettingsView(viewModel: viewModel, profileID: profileID)
            }
        } else {
            Text("Provider was deleted.")
                .foregroundStyle(.secondary)
                .navigationTitle("Provider")
        }
    }
}

private struct OpenAIProviderSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var profileID: String
    @State private var isAPIKeyVisible = false
    @FocusState private var isAPIKeyFieldFocused: Bool

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: providerNameBinding)
            }

            Section("OpenAI API Key") {
                apiKeyField
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                if hasAPIKeyText {
                    HStack {
                        Button(role: .destructive) {
                            isAPIKeyVisible = false
                            isAPIKeyFieldFocused = false
                            viewModel.clearAPIKeyButtonTapped(for: profileID)
                        } label: {
                            Text("Clear")
                                .foregroundStyle(.red)
                        }
                        .disabled(!viewModel.canClearAPIKey(for: profileID))

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
                        viewModel.updateAPIKeyDraft(UIPasteboard.general.string ?? "", for: profileID)
                    } label: {
                        FullWidthButtonLabel("Paste")
                    }
                    .buttonStyle(.borderless)
                }

                saveAPIKeyButton

                if viewModel.isSavingAPIKey(for: profileID) {
                    ProgressView("Validating...")
                }

                if let apiKeyValidationError = viewModel.apiKeyValidationError(for: profileID) {
                    Text(apiKeyValidationError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                apiKeyHelp
            }
        }
        .navigationTitle(viewModel.settings.profile(id: profileID)?.name ?? "OpenAI API")
        .navigationBarTitleDisplayMode(.inline)
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
        .disabled(viewModel.isSavingAPIKey(for: profileID))
    }

    @ViewBuilder
    private var saveAPIKeyButton: some View {
        if viewModel.hasUnsavedAPIKeyChanges(for: profileID) {
            Button {
                isAPIKeyFieldFocused = false
                Task {
                    await viewModel.saveAPIKeyDraft(for: profileID)
                }
            } label: {
                FullWidthButtonLabel("Save")
            }
            .disabled(!viewModel.canSaveAPIKey(for: profileID))
            .buttonStyle(.borderless)
        }
    }

    private var apiKeyHelp: some View {
        Text("Get an API key from [OpenAI](https://platform.openai.com/login?next=/api-keys). Billing must be enabled on your OpenAI account.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var hasAPIKeyText: Bool {
        viewModel.hasAPIKeyText(for: profileID)
    }

    private var apiKeyDraftBinding: Binding<String> {
        Binding {
            viewModel.apiKeyDraft(for: profileID)
        } set: { newValue in
            viewModel.updateAPIKeyDraft(newValue, for: profileID)
        }
    }

    private var providerNameBinding: Binding<String> {
        Binding {
            viewModel.settings.profile(id: profileID)?.name ?? ""
        } set: { newValue in
            viewModel.updateProviderName(profileID: profileID, name: newValue)
        }
    }
}

private struct CustomProviderSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    var profileID: String

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: providerNameBinding)
            }

            Section {
                Text("Not configurable yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(viewModel.settings.profile(id: profileID)?.name ?? "Custom")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var providerNameBinding: Binding<String> {
        Binding {
            viewModel.settings.profile(id: profileID)?.name ?? ""
        } set: { newValue in
            viewModel.updateProviderName(profileID: profileID, name: newValue)
        }
    }
}

private struct FullWidthButtonLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
        }
        .contentShape(Rectangle())
    }
}

private enum NadgarLinks {
    static let privacyPolicy = URL(string: "https://nadgar.app/#privacy")!
    static let faq = URL(string: "https://nadgar.app/#faq")!
}
