import HappierKit
import SwiftUI

struct WelcomeView: View {
    @Environment(HappierStore.self) private var store
    @State private var route: Route?
    @State private var serverText = ""
    @State private var showServer = false

    enum Route: Identifiable {
        case link, secretKey
        var id: Self { self }
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
                .controlSize(.large)
                .disabled(server == nil)

                Button {
                    route = .secretKey
                } label: {
                    Label("Enter Secret Key", systemImage: "key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(server == nil)

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
                    .buttonStyle(.plain)
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
            }
            .frame(maxWidth: 380)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { serverText = store.server.absoluteString }
        .sheet(item: $route) { route in
            NavigationStack {
                let server = self.server ?? store.server
                switch route {
                case .link: LinkDeviceView(server: server)
                case .secretKey: SecretKeyView(server: server)
                }
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 520)
            #endif
        }
    }
}
