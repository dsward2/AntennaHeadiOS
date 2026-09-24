import SwiftUI

/// Pick the server, and see how the Watch is connected. Servers from the
/// iPhone are managed there; ones added here can be edited or deleted.
struct ServersView: View {
    let model: WatchModel
    @State private var network = NetworkPathMonitor()
    @Environment(\.dismiss) private var dismiss
    /// The Watch-added server being edited.
    @State private var editing: WatchLink.Server?

    private var store: WatchServerStore { model.store }

    var body: some View {
        List {
            Section {
                ForEach(store.allServers) { server in
                    HStack {
                        Button {
                            store.select(server)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(server.name)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    Text(store.isFromPhone(server) ? "From iPhone" : server.address)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                }
                                Spacer()
                                if server.id == store.current?.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if !store.isFromPhone(server) {
                            // Visible, since swipe actions are easy to miss.
                            // (The swipe below still works too.)
                            Button {
                                editing = server
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit \(server.name)")
                        }
                    }
                    .swipeActions {
                        if !store.isFromPhone(server) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                store.deleteWatchServer(server)
                            }
                            Button("Edit", systemImage: "pencil") {
                                editing = server
                            }
                        }
                    }
                }
                NavigationLink {
                    ServerEditView(store: store, server: nil)
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
            } footer: {
                Text("Servers saved in AntennaHead on your iPhone appear here automatically.")
            }

            Section("Connection") {
                LabeledContent("Network", value: network.summary)
                LabeledContent("iPhone", value: model.link.isReachable ? "Reachable" : "Not reachable")
                if let route = model.route {
                    LabeledContent("API", value: route.rawValue)
                }
            }
        }
        .navigationTitle("Servers")
        .navigationDestination(item: $editing) { server in
            ServerEditView(store: store, server: server)
        }
    }
}

/// Add or edit a server on the Watch, for use without the iPhone app.
struct ServerEditView: View {
    let store: WatchServerStore
    let server: WatchLink.Server?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var usesHTTPS = false
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            TextField("host:port", text: $address)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("HTTPS", isOn: $usesHTTPS)
            Section("Web login (optional)") {
                // No autocorrect: it turned "dsward" into "Edward".
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button("Save") {
                let saved = WatchLink.Server(
                    id: server?.id ?? UUID(),
                    name: name.isEmpty ? address : name,
                    address: address.trimmingCharacters(in: .whitespaces),
                    usesHTTPS: usesHTTPS,
                    username: username,
                    password: password
                )
                store.saveWatchServer(saved)
                store.select(saved)
                dismiss()
            }
            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .navigationTitle(server == nil ? "Add Server" : "Edit Server")
        .onAppear {
            guard let server else { return }
            name = server.name
            address = server.address
            usesHTTPS = server.usesHTTPS
            username = server.username
            password = server.password
        }
    }
}
