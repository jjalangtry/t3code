import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var store
    @State private var draftModel = ""

    var body: some View {
        Form {
            Section("Defaults") {
                TextField("Default model", text: $draftModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        store.updatePreferredModel(draftModel)
                    }

                Picker("Theme", selection: Binding(
                    get: { store.themePreference },
                    set: { store.updateThemePreference($0) }
                )) {
                    ForEach(AppThemePreference.allCases, id: \.self) { preference in
                        Text(themeLabel(preference)).tag(preference)
                    }
                }
            }

            Section("Server") {
                LabeledContent("Host", value: store.serverHostInput.isEmpty ? "Not set" : store.serverHostInput)
                LabeledContent("Connection", value: store.phase.rawValue.capitalized)
                if let cwd = store.welcome?.cwd, !cwd.isEmpty {
                    LabeledContent("Server cwd", value: cwd)
                }
            }

            Section("Providers") {
                if store.providers.isEmpty {
                    Text("Provider status will appear after connecting.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.providers) { provider in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.provider)
                                .font(.subheadline.weight(.semibold))
                            Text(provider.message ?? provider.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftModel = store.preferredDefaultModel
        }
    }

    private func themeLabel(_ preference: AppThemePreference) -> String {
        switch preference {
        case .system:
            return "System"
        case .light:
            return "Light"
        case .dark:
            return "Dark"
        }
    }
}
