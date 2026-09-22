import Foundation

struct ProviderCustomizationPreferences: Codable, Equatable {
    let order: [ProviderID]
    let hidden: Set<ProviderID>
}

protocol ProviderCustomizationStoring: AnyObject {
    func load() -> ProviderCustomizationPreferences?
    func save(_ preferences: ProviderCustomizationPreferences)
}

final class UserDefaultsProviderCustomizationStore: ProviderCustomizationStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = UserDefaultsProviderCustomizationStore.defaultDefaults,
        key: String = "provider-customization-v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    private static var defaultDefaults: UserDefaults {
        if let sample = DemoLaunch.defaults {
            return sample
        }
#if DEBUG
        if let suiteName = ProcessInfo.processInfo.environment["SPENDER_CUSTOMIZATION_SUITE"],
           let defaults = UserDefaults(suiteName: suiteName) {
            return defaults
        }
#endif
        return .standard
    }

    func load() -> ProviderCustomizationPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ProviderCustomizationPreferences.self, from: data)
    }

    func save(_ preferences: ProviderCustomizationPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
