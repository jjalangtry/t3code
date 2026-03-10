import SwiftUI

struct ConnectView: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                Section {
                    TextField("code.jjalangtry.com", text: $store.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)

                    SecureField("Auth Token", text: $store.authToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server Connection")
                } footer: {
                    Text("Enter your T3 Code server hostname or URL")
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
                            if store.isConnecting {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 6)
                                Text("Connecting...")
                                    .font(.headline)
                            } else {
                                Label("Connect", systemImage: "link")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(
                        store.serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || store.isConnecting
                    )
                }
            }
            .navigationTitle("T3 Code")
        }
        .onAppear {
            store.loadSavedConnection()
        }
    }
}
