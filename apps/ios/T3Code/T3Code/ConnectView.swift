import SwiftUI

struct ConnectView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    TextField("Server URL", text: $store.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    SecureField("Auth Token (optional)", text: $store.authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server Connection")
                } footer: {
                    Text("Enter your T3 Code server URL (e.g. https://your-machine.tail1234.ts.net:3000)")
                }

                if let error = store.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: { store.connect() }) {
                        HStack {
                            Spacer()
                            Label("Connect", systemImage: "link")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(store.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("T3 Code")
        }
        .onAppear {
            store.loadSavedConnection()
        }
    }
}
