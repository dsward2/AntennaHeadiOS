import AntennaHeadAPI
import SwiftUI

/// The server list: saved servers, AntennaHead Macs found on this network,
/// and manual entry — the only option over a VPN, since Bonjour doesn't
/// cross the tunnel.
struct ConnectView: View {
    let store: ServerStore
    @State private var browser = ServerBrowser()
    @State private var editing: EditRequest?
    @State private var resolvingName: String?
    @State private var resolveError: String?

    /// What the editor sheet opens with.
    struct EditRequest: Identifiable {
        let server: SavedServer
        let isNew: Bool
        let requiresLogin: Bool
        var id: UUID { server.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if !store.servers.isEmpty {
                    Section("Saved") {
                        ForEach(store.servers) { server in
                            Button {
                                store.connect(to: server)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(verbatim: server.baseURL?.absoluteString ?? server.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { store.delete(server) }
                                Button("Edit") {
                                    editing = EditRequest(server: server, isNew: false,
                                                          requiresLogin: !server.username.isEmpty)
                                }
                                .tint(.blue)
                            }
                        }
                    }
                }

                Section {
                    ForEach(browser.servers) { found in
                        Button {
                            Task { await add(found) }
                        } label: {
                            HStack {
                                Label(found.name, systemImage: "desktopcomputer")
                                Spacer()
                                if resolvingName == found.name {
                                    ProgressView()
                                } else if let reason = found.unsupportedReason {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(found.unsupportedReason != nil || resolvingName != nil)
                    }
                    if browser.servers.isEmpty {
                        Text(browser.browseError ?? "Looking for AntennaHead on this network…")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("On This Network")
                } footer: {
                    if let resolveError {
                        Text(resolveError).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("Add Server Manually…", systemImage: "plus") {
                        editing = EditRequest(server: SavedServer(name: "", address: ""),
                                              isNew: true, requiresLogin: false)
                    }
                } footer: {
                    Text("Away from home, connect your iPhone's VPN (WireGuard, OpenVPN, …) first, then add the Mac by the address it has on the VPN, e.g. 10.0.0.2:8090. Network discovery doesn't work over a VPN.")
                }
            }
            .navigationTitle("AntennaHead")
            .sheet(item: $editing) { request in
                ServerEditor(store: store, request: request)
            }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    /// A found Mac: reuse its saved entry if the address matches, otherwise
    /// open the editor prefilled so the user can name it and log in.
    private func add(_ found: ServerBrowser.Server) async {
        resolvingName = found.name
        resolveError = nil
        defer { resolvingName = nil }
        do {
            let address = try await browser.resolve(found)
            if let existing = store.servers.first(where: { $0.address == address && !$0.usesHTTPS }) {
                store.connect(to: existing)
                return
            }
            editing = EditRequest(server: SavedServer(name: found.name, address: address),
                                  isNew: true,
                                  requiresLogin: found.advertisement.requiresAuth)
        } catch {
            resolveError = error.localizedDescription
        }
    }
}

/// Adds or edits one saved server.
struct ServerEditor: View {
    let store: ServerStore
    let request: ConnectView.EditRequest

    @Environment(\.dismiss) private var dismiss
    @State private var server: SavedServer
    @State private var password: String
    @State private var usesLogin: Bool

    init(store: ServerStore, request: ConnectView.EditRequest) {
        self.store = store
        self.request = request
        _server = State(initialValue: request.server)
        _password = State(initialValue: store.password(for: request.server) ?? "")
        _usesLogin = State(initialValue: request.requiresLogin)
    }

    private var isValid: Bool {
        !server.name.trimmingCharacters(in: .whitespaces).isEmpty && server.baseURL != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $server.name)
                    TextField("Address (host:port)", text: $server.address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("Use HTTPS", isOn: $server.usesHTTPS)
                } footer: {
                    Text("AntennaHead's web UI port — 8090 for HTTP, or 8094 for HTTPS, unless you changed them in its Configuration. HTTPS needs a certificate your iPhone trusts.")
                }

                Section {
                    Toggle("Web Login", isOn: $usesLogin)
                    if usesLogin {
                        TextField("Username", text: $server.username)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                    }
                } footer: {
                    Text("Turn on if AntennaHead's web login is on. If you leave it off, the app asks when the server wants a login.")
                }
            }
            .navigationTitle(request.isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.isNew ? "Connect" : "Save") {
                        var saved = server
                        saved.name = saved.name.trimmingCharacters(in: .whitespaces)
                        saved.address = saved.address.trimmingCharacters(in: .whitespaces)
                        if !usesLogin { saved.username = "" }
                        store.save(saved, password: usesLogin ? password : "")
                        dismiss()
                        if request.isNew { store.connect(to: saved) }
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
