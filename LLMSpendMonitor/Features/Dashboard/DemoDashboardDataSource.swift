import AppKit

/// Sample data: the real interface over fixed, fictional figures.
///
/// It serves two purposes. Anyone can try the app before handing it an API
/// key — "Try with sample data" relaunches it into this mode — and
/// screenshots can show the interface without real spend. A sample launch
/// never touches the Keychain, the network, or the app's own settings: its
/// preferences live in separate suites that are reseeded on every launch.
/// Switches between the real app and sample data by relaunching.
///
/// Sample data is chosen at launch, for the whole process — the data source,
/// the credential store and the settings suites all follow it — so switching
/// starts a fresh instance rather than swapping those out from under a
/// running one.
///
/// The choice travels in the app's settings, not as a launch argument: a
/// sandboxed app's arguments to its own relaunch were dropped, and the new
/// instance came up as the real app again. Stored, it also survives a quit,
/// so sample data stays until the person chooses Exit.
enum SampleData {
    static let modeKey = "sample-data-mode-v1"

    @MainActor
    static func relaunch(showingSampleData: Bool) {
        UserDefaults.standard.set(showingSampleData, forKey: modeKey)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            // Quit only once the new instance is up; if it failed to start,
            // staying open is better than leaving nothing in the menu bar.
            guard error == nil else { return }
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
    }
}

enum DemoLaunch {
    static let isEnabled = ProcessInfo.processInfo.arguments.contains("--demo-data")
        || UserDefaults.standard.bool(forKey: SampleData.modeKey)

    /// Where a sample launch keeps customization and card state.
    static let sampleSuiteName = "com.bestmark1.Spender.sample"
    /// Where a sample launch keeps its entered balances.
    static let sampleBalanceSuiteName = "com.bestmark1.Spender.sample.balances"

    /// Providers shown in the demo, in panel order.
    ///
    /// `SPENDER_DEMO_PROVIDERS` overrides the set, so a screenshot can show two
    /// cards without the panel clipping the last one. The panel is a fixed
    /// 420x640, and an expanded card takes most of it.
    static let providerIDs: [ProviderID] = {
        let fallback: [ProviderID] = [.openAI, .deepSeek, .anthropic, .xAI]
#if !DEBUG
        return fallback
#else
        guard
            let raw = ProcessInfo.processInfo.environment["SPENDER_DEMO_PROVIDERS"],
            !raw.isEmpty
        else { return fallback }

        let requested = raw
            .split(separator: ",")
            .compactMap { ProviderID(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        return requested.isEmpty ? fallback : requested
#endif
    }()

    /// Cards to show expanded. The prominent "Estimated period spend" label and
    /// its explanation only render in an expanded card, so a screenshot of the
    /// estimate has to open DeepSeek.
    /// `SPENDER_DEMO_ISSUE=deepseek:partialData` gives one provider a status
    /// problem, so a capture can show the longest badges ("Incomplete report",
    /// "Balance unavailable") instead of only "Up to date".
    static func issue(for providerID: ProviderID) -> ProviderIssue? {
#if !DEBUG
        return nil
#else
        guard let raw = ProcessInfo.processInfo.environment["SPENDER_DEMO_ISSUE"] else {
            return nil
        }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == providerID.rawValue else { return nil }
        return ProviderIssue(rawValue: parts[1])
#endif
    }

    static func seedCardExpansion() {
#if DEBUG
        guard let defaults else { return }
        // Only an explicit request overrides stored state. Resetting unconditionally on
        // every launch would wipe expansion a test (or a person) had just set.
        guard let raw = ProcessInfo.processInfo.environment["SPENDER_DEMO_EXPANDED"] else {
            return
        }
        let expanded = Set(
            raw.split(separator: ",").compactMap {
                ProviderID(rawValue: $0.trimmingCharacters(in: .whitespaces))
            }
        )

        for providerID in ProviderID.allCases {
            defaults.set(
                expanded.contains(providerID),
                forKey: "provider.card.\(providerID.rawValue).expanded"
            )
        }
#endif
    }

    /// Shared for the process: the connections screen rebuilds its view models
    /// on every render, and a fresh store each time would drop what was typed.
    static let credentialStore = DemoCredentialStore()

    /// Customization and card state for a sample launch; nil otherwise.
    static var defaults: UserDefaults? {
        guard isEnabled else { return nil }
        return UserDefaults(suiteName: suiteName(
            environment: "SPENDER_CUSTOMIZATION_SUITE",
            fallback: sampleSuiteName
        ))
    }

    /// Entered balances for a sample launch; nil otherwise.
    static var balanceDefaults: UserDefaults? {
        guard isEnabled else { return nil }
        return UserDefaults(suiteName: suiteName(
            environment: "SPENDER_PLATFORM_BALANCE_SUITE",
            fallback: sampleBalanceSuiteName
        ))
    }

    /// Tests and screenshot runs name a fresh suite per launch; everyone else
    /// gets the fixed sample suite.
    private static func suiteName(environment key: String, fallback: String) -> String {
#if DEBUG
        if let name = ProcessInfo.processInfo.environment[key], !name.isEmpty {
            return name
        }
#endif
        return fallback
    }

    /// Makes the four demo providers visible and ordered. xAI is hidden by
    /// default in the registry, so the demo suite has to be seeded explicitly.
    static func seedCustomizationPreferences() {
        guard let defaults else { return }
        let shown = Set(providerIDs)
        let preferences = ProviderCustomizationPreferences(
            order: providerIDs + ProviderRegistry.userFacing.map(\.id).filter { !shown.contains($0) },
            hidden: Set(ProviderRegistry.userFacing.map(\.id)).subtracting(shown)
        )
        UserDefaultsProviderCustomizationStore(defaults: defaults).save(preferences)
    }

    /// Calibrates a remaining balance for each demo provider.
    ///
    /// "Remaining balance" comes from a user-entered checkpoint, not from the
    /// provider snapshot, so an unseeded demo suite shows "Not set" on every
    /// card. Entered amounts sit well above each provider's 30-day total so the
    /// automatic deduction still leaves a sensible remainder.
    static func seedPlatformBalances() {
        guard let balanceDefaults else { return }

        let enteredBalances: [ProviderID: String] = [
            .openAI: "42.50",
            .anthropic: "31.00",
            .deepSeek: "24.80",
            .xAI: "37.00"
        ]
        let synchronizedAt = Date().addingTimeInterval(-3 * 3600)
        let zero = DemoSnapshotFactory.demoMoney("0.00")

        let checkpoints = enteredBalances.reduce(into: [ProviderID: PlatformBalanceCheckpoint]()) {
            result, entry in
            result[entry.key] = PlatformBalanceCheckpoint(
                providerID: entry.key,
                enteredBalance: DemoSnapshotFactory.demoMoney(entry.value),
                synchronizedAt: synchronizedAt,
                deductedSpend: zero,
                costAnchors: []
            )
        }

        UserDefaultsPlatformBalanceStore(defaults: balanceDefaults).save(checkpoints)
    }
}

/// Serves fixed, fictional snapshots instead of contacting provider APIs.
struct DemoDashboardDataSource: DashboardDataRefreshing {
    func loadCachedSnapshots() async -> [ProviderID: ProviderSnapshot] {
        DemoSnapshotFactory.snapshots()
    }

    func refresh(
        trigger: RefreshTrigger,
        targets: [ProviderRefreshTarget]
    ) async -> [ProviderID: ProviderSnapshot] {
        DemoSnapshotFactory.snapshots()
    }

    func purge(_ providerID: ProviderID) async {}
}

/// Keeps credentials in memory for the duration of a demo launch.
///
/// `ConnectionViewModel` reads the credential store synchronously on the main
/// thread while the connections screen is built. A freshly built binary carries
/// a different code signature from the installed app, so that read makes macOS
/// raise a Keychain access prompt, which blocks the main thread — a UI test
/// then times out waiting for the app to respond. A demo launch never needs a
/// real secret, so it never asks for one.
final class DemoCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [CredentialIdentity: String] = [:]

    func save(_ secret: String, for identity: CredentialIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[identity] = secret
    }

    func read(for identity: CredentialIdentity) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let secret = secrets[identity] else { throw KeychainStoreError.itemNotFound }
        return secret
    }

    func delete(for identity: CredentialIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: identity)
    }
}

/// Swallows balance alerts so a demo launch never posts a notification.
struct DemoBalanceNotifier: BalanceNotificationHandling {
    func evaluate(_ balances: [ProviderID: PlatformBalanceStatus]) async {}
}

/// Builds the fictional snapshots.
///
/// The numbers are chosen to show all four provenance states side by side:
/// official cost with tokens (OpenAI, Anthropic), official balance plus
/// estimated cost (DeepSeek), and official balance with official cost but no
/// token reporting (xAI).
enum DemoSnapshotFactory {
    private static let dayCount = 30

    static func snapshots() -> [ProviderID: ProviderSnapshot] {
        let today = utcStartOfToday()
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today)!
        let through = calendar.date(byAdding: .day, value: 1, to: today)!
        let coverage = ReportingCoverage(start: start, through: through, completeness: .complete)

        let all: [ProviderID: ProviderSnapshot] = [
            .openAI: openAI(coverage: coverage, start: start),
            .anthropic: anthropic(coverage: coverage, start: start),
            .deepSeek: deepSeek(coverage: coverage, start: start),
            .xAI: xAI(coverage: coverage, start: start)
        ]
        return all.filter { DemoLaunch.providerIDs.contains($0.key) }
    }

    // MARK: - Providers

    private static func openAI(coverage: ReportingCoverage, start: Date) -> ProviderSnapshot {
        let dailyCosts = [
            "1.18", "1.60", "0.94", "2.01", "1.35", "0.61", "0.30",
            "2.26", "1.80", "1.48", "1.12", "2.03", "1.68", "0.78",
            "0.45", "2.36", "1.90", "1.43", "1.78", "1.30", "0.87",
            "0.40", "2.52", "2.12", "1.63", "1.32", "1.96", "1.51",
            "1.04", "2.14"
        ]
        let tokens = TokenUsage(
            inputTokens: 180_000,
            outputTokens: 52_000,
            cachedInputTokens: 96_000,
            provenance: .official
        )

        return snapshot(
            providerID: .openAI,
            capabilities: [.officialCostHistory, .tokenUsage, .modelBreakdown],
            coverage: coverage,
            buckets: buckets(
                from: start,
                costs: dailyCosts,
                provenance: .official,
                todayTokens: tokens,
                todayModels: [
                    model("gpt-5.2", cost: "1.32", input: 105_400, output: 32_100, cached: 58_200),
                    model("gpt-5-mini", cost: "0.57", input: 54_600, output: 14_900, cached: 28_400),
                    model("o4-mini", cost: "0.25", input: 20_000, output: 5_000, cached: 9_400)
                ]
            ),
            balances: []
        )
    }

    private static func anthropic(coverage: ReportingCoverage, start: Date) -> ProviderSnapshot {
        let dailyCosts = [
            "0.72", "1.08", "0.56", "1.34", "0.91", "0.43", "0.20",
            "1.48", "1.13", "0.95", "0.70", "1.30", "1.01", "0.53",
            "0.31", "1.51", "1.19", "0.87", "1.11", "0.81", "0.57",
            "0.26", "1.59", "1.27", "1.02", "0.83", "1.22", "0.96",
            "0.63", "1.28"
        ]
        let tokens = TokenUsage(
            inputTokens: 112_000,
            outputTokens: 29_000,
            cachedInputTokens: 70_000,
            provenance: .official
        )

        return snapshot(
            providerID: .anthropic,
            capabilities: [.officialCostHistory, .tokenUsage, .modelBreakdown],
            coverage: coverage,
            buckets: buckets(
                from: start,
                costs: dailyCosts,
                provenance: .official,
                todayTokens: tokens,
                todayModels: [
                    model("claude-opus-5", cost: "0.84", input: 62_000, output: 17_200, cached: 40_100),
                    model("claude-sonnet-5", cost: "0.44", input: 50_000, output: 11_800, cached: 29_900)
                ]
            ),
            balances: []
        )
    }

    private static func deepSeek(coverage: ReportingCoverage, start: Date) -> ProviderSnapshot {
        let dailyCosts = [
            "0.23", "0.14", "0.33", "0.19", "0.12", "0.05", "0.02",
            "0.39", "0.30", "0.20", "0.15", "0.35", "0.25", "0.10",
            "0.05", "0.42", "0.31", "0.22", "0.28", "0.17", "0.10",
            "0.03", "0.44", "0.33", "0.24", "0.18", "0.30", "0.22",
            "0.12", "0.34"
        ]

        return snapshot(
            providerID: .deepSeek,
            capabilities: [.balance, .estimatedCostHistory],
            coverage: coverage,
            buckets: buckets(
                from: start,
                costs: dailyCosts,
                provenance: .estimated,
                todayTokens: nil,
                todayModels: []
            ),
            balances: [
                ProviderBalance(
                    total: MoneyMetric(value: money("24.80"), provenance: .official),
                    granted: nil,
                    toppedUp: nil
                )
            ]
        )
    }

    private static func xAI(coverage: ReportingCoverage, start: Date) -> ProviderSnapshot {
        let dailyCosts = [
            "0.58", "0.84", "0.39", "1.06", "0.70", "0.33", "0.14",
            "1.22", "0.95", "0.66", "0.49", "1.08", "0.82", "0.37",
            "0.19", "1.27", "0.98", "0.71", "0.86", "0.62", "0.43",
            "0.17", "1.30", "1.04", "0.79", "0.65", "0.93", "0.76",
            "0.46", "0.86"
        ]

        return snapshot(
            providerID: .xAI,
            capabilities: [.balance, .officialCostHistory, .modelBreakdown],
            coverage: coverage,
            buckets: buckets(
                from: start,
                costs: dailyCosts,
                provenance: .official,
                todayTokens: nil,
                todayModels: [
                    model("grok-4", cost: "0.61", input: nil, output: nil, cached: nil),
                    model("grok-4-fast", cost: "0.25", input: nil, output: nil, cached: nil)
                ]
            ),
            balances: [
                ProviderBalance(
                    total: MoneyMetric(value: money("37.00"), provenance: .official),
                    granted: nil,
                    toppedUp: nil
                )
            ]
        )
    }

    // MARK: - Building blocks

    private static func snapshot(
        providerID: ProviderID,
        capabilities: Set<ProviderCapability>,
        coverage: ReportingCoverage,
        buckets: [PeriodBucket],
        balances: [ProviderBalance]
    ) -> ProviderSnapshot {
        try! ProviderSnapshot(
            providerID: providerID,
            capabilities: capabilities,
            fetchedAt: Date(),
            coverage: coverage,
            buckets: buckets,
            balances: balances,
            issue: DemoLaunch.issue(for: providerID)
        )
    }

    /// Spreads the day's cost, tokens, and model split across every bucket.
    ///
    /// Tokens and model rows are scaled from the final bucket by cost ratio, so
    /// a 30-day total stays proportional to a single day. Putting them on the
    /// last bucket only produced a 30-day view with a month of spend against a
    /// single day of tokens.
    private static func buckets(
        from start: Date,
        costs: [String],
        provenance: MetricProvenance,
        todayTokens: TokenUsage?,
        todayModels: [ModelUsage]
    ) -> [PeriodBucket] {
        let referenceCost = decimal(costs[costs.count - 1])

        return costs.enumerated().map { index, amount in
            let dayStart = calendar.date(byAdding: .day, value: index, to: start)!
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
            let bucketCost = money(amount)
            let ratio = share(of: bucketCost.amount, in: referenceCost)

            return PeriodBucket(
                start: dayStart,
                end: dayEnd,
                cost: MoneyMetric(value: bucketCost, provenance: provenance),
                tokenUsage: todayTokens.map { scaled($0, by: ratio) },
                modelBreakdown: scaled(
                    todayModels,
                    by: ratio,
                    totalling: bucketCost.amount
                )
            )
        }
    }

    private static func scaled(_ usage: TokenUsage, by ratio: Double) -> TokenUsage {
        TokenUsage(
            inputTokens: Int64((Double(usage.inputTokens) * ratio).rounded()),
            outputTokens: Int64((Double(usage.outputTokens) * ratio).rounded()),
            cachedInputTokens: Int64((Double(usage.cachedInputTokens) * ratio).rounded()),
            provenance: usage.provenance
        )
    }

    /// Scales each model by `ratio`, giving the last model whatever remains so
    /// the rows always add up to the bucket's cost exactly.
    private static func scaled(
        _ models: [ModelUsage],
        by ratio: Double,
        totalling total: Decimal
    ) -> [ModelUsage] {
        guard !models.isEmpty else { return [] }

        var remaining = total
        var result: [ModelUsage] = []

        for (index, model) in models.enumerated() {
            let isLast = index == models.count - 1
            var cost = rounded((model.cost.map { $0.value.amount } ?? .zero) * Decimal(ratio))
            if isLast {
                cost = max(.zero, remaining)
            } else {
                remaining -= cost
            }

            result.append(
                ModelUsage(
                    modelID: model.modelID,
                    cost: MoneyMetric(value: usd(cost), provenance: .official),
                    tokenUsage: model.tokenUsage.map { scaled($0, by: ratio) }
                )
            )
        }

        return result
    }

    private static func share(of amount: Decimal, in reference: Decimal) -> Double {
        guard reference > .zero else { return 0 }
        return (amount as NSDecimalNumber).doubleValue
            / (reference as NSDecimalNumber).doubleValue
    }

    private static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal.zero
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    private static func usd(_ amount: Decimal) -> Money {
        try! Money(amount: amount, currencyCode: "USD")
    }

    private static func decimal(_ amount: String) -> Decimal {
        Decimal(string: amount, locale: posixLocale)!
    }

    private static func model(
        _ modelID: String,
        cost: String,
        input: Int64?,
        output: Int64?,
        cached: Int64?
    ) -> ModelUsage {
        let tokenUsage: TokenUsage? = if let input, let output, let cached {
            TokenUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cached,
                provenance: .official
            )
        } else {
            nil
        }

        return ModelUsage(
            modelID: modelID,
            cost: MoneyMetric(value: money(cost), provenance: .official),
            tokenUsage: tokenUsage
        )
    }

    static func demoMoney(_ amount: String) -> Money { money(amount) }

    private static func money(_ amount: String) -> Money {
        try! Money(amount: Decimal(string: amount, locale: posixLocale)!, currencyCode: "USD")
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func utcStartOfToday() -> Date {
        calendar.startOfDay(for: Date())
    }
}
