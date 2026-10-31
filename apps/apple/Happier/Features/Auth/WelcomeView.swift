import HappierKit
import SwiftUI

struct WelcomeView: View {
    @Environment(HappierStore.self) private var store
    @State private var route: Route?
    @State private var serverText = ""
    @State private var showServer = false
    /// What the typed relay allows; nil until it answers (or when it can't be reached).
    @State private var authOptions: AuthOptions?

    enum Route: Identifiable {
        case link, secretKey, create
        var id: Self { self }
    }

    private var signedInRelays: [URL] {
        store.knownServers.filter { RelayList.canonical($0) != RelayList.canonical(store.server) && store.hasCredentials(for: $0) }
    }

    /// nil while the typed address is invalid; never silently replaced by another server.
    private var server: URL? { ServerAddress.normalize(serverText) }

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .foregroundStyle(.primary)
            VStack(spacing: 8) {
                Text("Happier")
                    .font(.largeTitle.bold())
                Text("Your coding agents, in your pocket.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 12) {
                Button {
                    route = .link
                } label: {
                    Label("Link with Another Device", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .glassHover()
                .controlSize(.large)
                .disabled(server == nil)

                Button {
                    route = .secretKey
                } label: {
                    Label("Enter Secret Key", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .glassHover()
                .controlSize(.large)
                .disabled(server == nil)

                if authOptions?.canCreateAccount == true {
                    Button {
                        route = .create
                    } label: {
                        Label("Create New Account", systemImage: "person.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .glassHover()
                    .controlSize(.large)
                    .disabled(server == nil)
                    .accessibilityIdentifier("account-create-new")
                }

                VStack(spacing: 6) {
                    Button {
                        withAnimation(.smooth) { showServer.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "server.rack")
                            Text(server?.host() ?? serverText)
                                .fontWeight(.medium)
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showServer ? 180 : 0))
                        }
                    }
                    .accessibilityIdentifier("account-relay-address")
                    .accessibilityValue(server?.absoluteString ?? serverText)
                    .buttonStyle(.pressable)
                    if showServer {
                        TextField(HappierStore.defaultServer.absoluteString, text: $serverText)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            #endif
                        if server == nil {
                            Text("Enter a server address like happier.example.com")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)

                // Relays this device is still signed in to (after switching to a new one).
                ForEach(signedInRelays, id: \.absoluteString) { url in
                    Button {
                        store.switchServer(to: url)
                    } label: {
                        Label("Back to \(url.host() ?? url.absoluteString)", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .glassHover()
                }
            }
            .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { serverText = store.server.absoluteString }
        .task(id: server) {
            authOptions = nil
            guard let server else { return }
            // Typing an address: wait for a pause before asking that relay.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            authOptions = try? await AuthAPI(server: server).options()
        }
        .onChange(of: store.pendingSessionLink) { _, link in
            if let link, RelayList.canonical(link.server) == RelayList.canonical(store.server), store.sessionLinkConfirmation == nil {
                serverText = store.server.absoluteString
            }
        }
        .sheet(item: $route) { route in
            NavigationStack {
                let server = self.server ?? store.server
                switch route {
                case .link: LinkDeviceView(server: server)
                case .secretKey: SecretKeyView(server: server)
                case .create: CreateAccountView(server: server, publishesContentKey: authOptions?.publishesContentKey ?? false)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 520)
            #endif
        }
    }
}
