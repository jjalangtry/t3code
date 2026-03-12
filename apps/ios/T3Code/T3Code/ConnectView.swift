import SwiftUI

struct ConnectView: View {
    @Environment(SessionStore.self) private var store
    @State private var isAdvancedExpanded = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                if store.phase == .checkingAuth {
                    Section {
                        LabeledContent("Status", value: "Checking sign-in requirements…")
                    }
                } else if store.phase == .awaitingLogin {
                    Section {
                        LabeledContent("Status", value: "Sign-in required")
                    } footer: {
                        Text("Use the same username and password that work in the browser for this host.")
                    }
                }

                Section {
                    TextField("code.jjalangtry.com", text: $store.serverHostInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("server-host-field")
                } header: {
                    Text("Server")
                } footer: {
                    Text("Enter the same T3 Code host you open in the browser. Most hosted setups do not need a port.")
                }

                if store.shouldShowLoginFields {
                    Section {
                        TextField("Username", text: $store.authUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .disabled(store.isBusy)
                            .accessibilityIdentifier("username-field")

                        SecureField("Password", text: $store.authPassword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .disabled(store.isBusy)
                            .accessibilityIdentifier("password-field")
                    } header: {
                        Text("Sign In")
                    } footer: {
                        Text("This server requires the same minimal username and password login as the website.")
                    }
                }

                Section {
                    DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
                        Toggle(
                            "Use token instead",
                            isOn: Binding(
                                get: { store.connectionMode == .token },
                                set: { store.connectionMode = $0 ? .token : .appAuth }
                            )
                        )
                        .disabled(store.isBusy)
                        .accessibilityIdentifier("advanced-token-toggle")

                        TextField("Port Override", text: $store.advancedPortOverride)
                            .keyboardType(.numberPad)
                            .disabled(store.isBusy)
                            .accessibilityIdentifier("port-override-field")

                        if store.shouldShowTokenField {
                            SecureField("Auth Token", text: $store.authToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .disabled(store.isBusy)
                                .accessibilityIdentifier("auth-token-field")
                        }
                    }
                    .accessibilityIdentifier("advanced-disclosure")
                }

                if let error = store.connectionError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: { store.submitConnection() }) {
                        HStack {
                            Spacer()
                            if store.isBusy {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.trailing, 6)
                            }
                            Text(store.connectButtonLabel)
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(!store.canSubmitConnection)
                    .accessibilityIdentifier("connect-button")
                }
            }
            .navigationTitle("T3 Code")
        }
    }
}

#Preview {
    ConnectView()
        .environment(SessionStore())
}
