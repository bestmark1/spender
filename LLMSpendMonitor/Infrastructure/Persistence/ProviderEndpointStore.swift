import Foundation

protocol ProviderEndpointStoring: Sendable {
    func loadEndpoint(for providerID: ProviderID) -> String?
    func saveEndpoint(_ endpoint: String, for providerID: ProviderID)
}

final class UserDefaultsProviderEndpointStore: ProviderEndpointStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = DemoLaunch.defaults ?? .standard,
        keyPrefix: String = "provider-api-endpoint-v1"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func loadEndpoint(for providerID: ProviderID) -> String? {
        defaults.string(forKey: key(for: providerID))
    }

    func saveEndpoint(_ endpoint: String, for providerID: ProviderID) {
        defaults.set(endpoint, forKey: key(for: providerID))
    }

    private func key(for providerID: ProviderID) -> String {
        "\(keyPrefix).\(providerID.rawValue)"
    }
}
