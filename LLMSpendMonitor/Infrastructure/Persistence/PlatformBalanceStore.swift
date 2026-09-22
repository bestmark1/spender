import Foundation

struct PlatformBalanceCostAnchor: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    let cost: Money
}

struct PlatformBalanceCheckpoint: Codable, Equatable, Sendable {
    let providerID: ProviderID
    let enteredBalance: Money
    let synchronizedAt: Date
    let deductedSpend: Money
    let costAnchors: [PlatformBalanceCostAnchor]
}

protocol PlatformBalanceStoring: AnyObject {
    func load() -> [ProviderID: PlatformBalanceCheckpoint]
    func save(_ checkpoints: [ProviderID: PlatformBalanceCheckpoint])
}

final class UserDefaultsPlatformBalanceStore: PlatformBalanceStoring {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults? = nil,
        key: String = "platform-balances-v1"
    ) {
        self.defaults = defaults ?? Self.defaultDefaults()
        self.key = key
    }

    private static func defaultDefaults() -> UserDefaults {
        // A sample launch must never write its fictional balances over yours.
        if let sample = DemoLaunch.balanceDefaults {
            return sample
        }
        #if DEBUG
        if
            let suiteName = ProcessInfo.processInfo.environment["SPENDER_PLATFORM_BALANCE_SUITE"],
            !suiteName.isEmpty,
            let defaults = UserDefaults(suiteName: suiteName)
        {
            return defaults
        }
        #endif
        return .standard
    }

    func load() -> [ProviderID: PlatformBalanceCheckpoint] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([ProviderID: PlatformBalanceCheckpoint].self, from: data)) ?? [:]
    }

    func save(_ checkpoints: [ProviderID: PlatformBalanceCheckpoint]) {
        guard let data = try? JSONEncoder().encode(checkpoints) else { return }
        defaults.set(data, forKey: key)
    }
}
