import SwiftUI

struct ConnectionsView: View {
    let showDashboard: () -> Void
    private let connectionModels: [ConnectionViewModel]

    @MainActor
    init(
        showDashboard: @escaping () -> Void,
        credentialStore: CredentialStoring = ConnectionsView.launchConfiguredCredentialStore(),
        endpointStore: any ProviderEndpointStoring = UserDefaultsProviderEndpointStore(),
        credentialDidChange: @escaping (ProviderID) -> Void = { _ in }
    ) {
        self.showDashboard = showDashboard
        connectionModels = ProviderRegistry.userFacing
            .filter { $0.integrationAvailability == .available }
            .map {
                ConnectionViewModel(
                    metadata: $0,
                    credentialStore: credentialStore,
                    endpointStore: endpointStore,
                    credentialDidChange: credentialDidChange
                )
            }
    }

    /// The real Keychain, except on a screenshot demo launch.
    static func launchConfiguredCredentialStore() -> CredentialStoring {
        if DemoLaunch.isEnabled {
            return DemoLaunch.credentialStore
        }
        return KeychainStore()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Back", systemImage: "chevron.left", action: showDashboard)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("connections.back")
                Text("Connections")
                    .font(.title2.bold())
            }

            Text("Keys stay in this Mac’s Keychain and are never shown again after saving.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(connectionModels) { model in
                        ProviderConnectionView(viewModel: model)
                    }
                }
            }
        }
        .padding(20)
        .accessibilityIdentifier("connections.root")
    }
}
