import Foundation

enum DashboardPeriod: Int, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case thirtyDays

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .thirtyDays: "30 Days"
        }
    }

    func interval(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.startOfDay(for: date)

        switch self {
        case .today:
            return DateInterval(
                start: today,
                end: calendar.date(byAdding: .day, value: 1, to: today)!
            )
        case .yesterday:
            let start = calendar.date(byAdding: .day, value: -1, to: today)!
            return DateInterval(start: start, end: today)
        case .thirtyDays:
            let start = calendar.date(byAdding: .day, value: -29, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: today)!
            return DateInterval(start: start, end: end)
        }
    }
}

struct ProviderSpendSummary: Identifiable, Equatable, Sendable {
    let providerID: ProviderID
    let amount: Money
    let provenance: MetricProvenance

    var id: ProviderID { providerID }
}

struct DailySpendPoint: Identifiable, Equatable, Sendable {
    let date: Date
    let amount: Money
    /// What each provider contributed to `amount`, for the stacked chart.
    /// Empty where only the total was aggregated.
    var byProvider: [ProviderID: Decimal] = [:]

    var id: Date { date }
}

struct PlatformBalanceStatus: Equatable, Sendable {
    let calibratedBalance: Money
    let remaining: Money
    let deductedSpend: Money
    let synchronizedAt: Date
    let automaticallyDeductsSpend: Bool
}

enum ProviderFreshness: Equatable, Sendable {
    case current
    case processing
    case stale
}

private struct PlatformBalanceAnchorKey: Hashable {
    let start: Date
    let end: Date
    let currencyCode: String
}

protocol DashboardDataRefreshing: Sendable {
    func loadCachedSnapshots() async -> [ProviderID: ProviderSnapshot]
    func refresh(
        trigger: RefreshTrigger,
        targets: [ProviderRefreshTarget]
    ) async -> [ProviderID: ProviderSnapshot]
    func purge(_ providerID: ProviderID) async
}

extension RefreshCoordinator: DashboardDataRefreshing {}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private var platformBalanceCheckpoints: [ProviderID: PlatformBalanceCheckpoint]
    @Published private(set) var isRefreshing = false
    @Published var selectedPeriod: DashboardPeriod = .today

    private let dataSource: any DashboardDataRefreshing
    private let fixedTargets: [ProviderRefreshTarget]?
    private let targetFactory: ProviderTargetFactory
    private let platformBalanceStore: any PlatformBalanceStoring
    private let balanceNotifier: any BalanceNotificationHandling
    private let now: @Sendable () -> Date
    private var hasStarted = false
    private var pendingCredentialValidations: Set<ProviderID> = []

    init(
        dataSource: any DashboardDataRefreshing = RefreshCoordinator(),
        targets: [ProviderRefreshTarget]? = nil,
        targetFactory: ProviderTargetFactory = ProviderTargetFactory(),
        platformBalanceStore: any PlatformBalanceStoring = UserDefaultsPlatformBalanceStore(),
        balanceNotifier: any BalanceNotificationHandling = BalanceNotificationService.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.dataSource = dataSource
        fixedTargets = targets
        self.targetFactory = targetFactory
        self.platformBalanceStore = platformBalanceStore
        self.balanceNotifier = balanceNotifier
        platformBalanceCheckpoints = platformBalanceStore.load()
        self.now = now
    }

    /// Builds the view model the app launches with.
    ///
    /// A normal launch gets the real refresh coordinator. The screenshot demo
    /// build gets fixed fictional snapshots instead, so the interface can be
    /// photographed without real spend, balances, or credentials.
    static func launchConfigured() -> DashboardViewModel {
        if DemoLaunch.isEnabled {
            DemoLaunch.seedCustomizationPreferences()
            DemoLaunch.seedPlatformBalances()
            DemoLaunch.seedCardExpansion()
            return DashboardViewModel(
                dataSource: DemoDashboardDataSource(),
                targets: [],
                balanceNotifier: DemoBalanceNotifier()
            )
        }
        return DashboardViewModel()
    }

    var officialUSDTotal: Money {
        let total = officialUSDBreakdown.reduce(into: Decimal.zero) { result, summary in
            result += summary.amount.amount
        }
        return try! Money(amount: total, currencyCode: "USD")
    }

    var trackedUSDTotal: Money {
        let total = trackedUSDBreakdown.reduce(into: Decimal.zero) { result, summary in
            result += summary.amount.amount
        }
        return try! Money(amount: total, currencyCode: "USD")
    }

    var menuBarUSDTotal: Money {
        let interval = DashboardPeriod.today.interval(containing: now())
        let total = snapshots.values.reduce(into: Decimal.zero) { result, snapshot in
            guard
                Self.acceptsOfficialCost(snapshot.issue),
                snapshot.capabilities.contains(.officialCostHistory)
                    || snapshot.capabilities.contains(.estimatedCostHistory),
                let coverage = snapshot.coverage,
                (coverage.completeness == .complete
                    || snapshot.capabilities.contains(.estimatedCostHistory)),
                coverage.start <= interval.start,
                coverage.through >= interval.end
            else { return }

            for bucket in snapshot.buckets where
                bucket.start >= interval.start && bucket.end <= interval.end {
                result += trackedUSDCostMetric(in: bucket)?.value.amount ?? 0
            }
        }
        return try! Money(amount: total, currencyCode: "USD")
    }

    var officialUSDBreakdown: [ProviderSpendSummary] {
        snapshots.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { providerID in
            guard let snapshot = completeOfficialCostSnapshot(for: providerID) else { return nil }
            let total = officialUSDCosts(in: snapshot).reduce(into: Decimal.zero) { result, cost in
                result += cost.amount
            }
            guard total > 0 else { return nil }
            return ProviderSpendSummary(
                providerID: providerID,
                amount: try! Money(amount: total, currencyCode: "USD"),
                provenance: .official
            )
        }
    }

    var trackedUSDBreakdown: [ProviderSpendSummary] {
        snapshots.keys.sorted(by: { $0.rawValue < $1.rawValue }).compactMap { providerID in
            guard let snapshot = completeTrackedCostSnapshot(for: providerID) else { return nil }
            let costs = trackedUSDCostMetrics(in: snapshot)
            let total = costs.reduce(into: Decimal.zero) { $0 += $1.value.amount }
            guard total > 0 else { return nil }
            let provenance: MetricProvenance = costs.contains { $0.provenance == .estimated }
                ? .estimated
                : .official
            return ProviderSpendSummary(
                providerID: providerID,
                amount: try! Money(amount: total, currencyCode: "USD"),
                provenance: provenance
            )
        }
    }

    var officialUSDDailySpend: [DailySpendPoint] {
        var totals: [Date: Decimal] = [:]
        for providerID in snapshots.keys {
            guard let snapshot = completeOfficialCostSnapshot(for: providerID) else { continue }
            for bucket in snapshot.buckets {
                guard let cost = officialUSDCost(in: bucket) else { continue }
                totals[utcStartOfDay(for: bucket.start), default: 0] += cost.amount
            }
        }
        return totals.keys.sorted().map { date in
            DailySpendPoint(
                date: date,
                amount: try! Money(amount: totals[date, default: 0], currencyCode: "USD")
            )
        }
    }

    var trackedUSDDailySpend: [DailySpendPoint] {
        var totals: [Date: Decimal] = [:]
        var byProvider: [Date: [ProviderID: Decimal]] = [:]
        for providerID in snapshots.keys {
            guard let snapshot = completeTrackedCostSnapshot(for: providerID) else { continue }
            for bucket in snapshot.buckets {
                guard let cost = trackedUSDCostMetric(in: bucket),
                      bucket.end <= utcStartOfDay(for: bucket.start).addingTimeInterval(86_400)
                else { continue }
                let day = utcStartOfDay(for: bucket.start)
                totals[day, default: 0] += cost.value.amount
                byProvider[day, default: [:]][providerID, default: 0] += cost.value.amount
            }
        }
        return totals.keys.sorted().map { date in
            DailySpendPoint(
                date: date,
                amount: try! Money(amount: totals[date, default: 0], currencyCode: "USD"),
                byProvider: byProvider[date, default: [:]]
            )
        }
    }

    var excludedOfficialCostProviderCount: Int {
        snapshots.keys.reduce(into: 0) { result, providerID in
            guard snapshots[providerID]?.capabilities.contains(.officialCostHistory) == true else { return }
            if completeOfficialCostSnapshot(for: providerID) == nil {
                result += 1
            }
        }
    }

    var isOfficialCostPartial: Bool {
        excludedOfficialCostProviderCount > 0
    }

    func snapshot(for providerID: ProviderID) -> ProviderSnapshot? {
        guard let source = snapshots[providerID], let sourceCoverage = source.coverage else {
            return snapshots[providerID]
        }

        let interval = selectedPeriod.interval(containing: now())
        let fullyCovered = sourceCoverage.start <= interval.start
            && sourceCoverage.through >= interval.end
            && sourceCoverage.completeness == .complete
        let completeness: ReportingCoverage.Completeness = fullyCovered ? .complete : .partial
        let issue = source.issue ?? (fullyCovered ? nil : .partialData)

        return try? ProviderSnapshot(
            providerID: source.providerID,
            capabilities: source.capabilities,
            fetchedAt: source.fetchedAt,
            coverage: ReportingCoverage(
                start: interval.start,
                through: interval.end,
                completeness: completeness
            ),
            buckets: source.buckets.filter {
                $0.start >= interval.start && $0.end <= interval.end
            },
            balances: source.balances,
            issue: issue,
            retryAfterSeconds: source.retryAfterSeconds
        )
    }

    func providerFreshness(for providerID: ProviderID) -> ProviderFreshness? {
        guard let snapshot = snapshots[providerID], snapshot.issue == nil else { return nil }

        if now().timeIntervalSince(snapshot.fetchedAt) > staleInterval(for: providerID) {
            return .stale
        }

        let latestUsageBucket = snapshot.buckets
            .filter { $0.tokenUsage != nil }
            .max { $0.end < $1.end }
        if snapshot.capabilities.contains(.officialCostHistory),
           let latestUsageBucket,
           latestUsageBucket.cost == nil {
            return .processing
        }

        return .current
    }

    @discardableResult
    func synchronizePlatformBalance(
        providerID: ProviderID,
        balance: Money
    ) async -> Bool {
        guard canSynchronizePlatformBalance(for: providerID) else { return false }

        if ProviderRegistry.metadata(for: providerID)?.capabilities.contains(.officialCostHistory) == true {
            guard !isRefreshing else { return false }
            await refresh(
                trigger: .manual,
                providerID: providerID,
                publishesBalanceAlerts: false
            )
            guard hasCompleteCurrentCostCoverage(for: providerID) else { return false }
        }

        let synchronizedAt = now()
        let anchors = synchronizationAnchors(
            in: snapshots[providerID],
            currencyCode: balance.currencyCode,
            synchronizedAt: synchronizedAt
        )
        platformBalanceCheckpoints[providerID] = PlatformBalanceCheckpoint(
            providerID: providerID,
            enteredBalance: balance,
            synchronizedAt: synchronizedAt,
            deductedSpend: try! Money(amount: 0, currencyCode: balance.currencyCode),
            costAnchors: anchors
        )
        persistPlatformBalances()
        await publishBalancesForNotifications()
        return true
    }

    func canSynchronizePlatformBalance(for providerID: ProviderID) -> Bool {
        guard let capabilities = ProviderRegistry.metadata(for: providerID)?.capabilities else {
            return false
        }
        return capabilities.contains(.officialCostHistory) && !capabilities.contains(.balance)
    }

    func platformBalance(for providerID: ProviderID) -> PlatformBalanceStatus? {
        guard let checkpoint = platformBalanceCheckpoints[providerID] else { return nil }
        let remainingAmount = max(
            Decimal.zero,
            checkpoint.enteredBalance.amount - checkpoint.deductedSpend.amount
        )
        return PlatformBalanceStatus(
            calibratedBalance: checkpoint.enteredBalance,
            remaining: try! Money(
                amount: remainingAmount,
                currencyCode: checkpoint.enteredBalance.currencyCode
            ),
            deductedSpend: checkpoint.deductedSpend,
            synchronizedAt: checkpoint.synchronizedAt,
            automaticallyDeductsSpend: ProviderRegistry.metadata(for: providerID)?
                .capabilities.contains(.officialCostHistory) == true
        )
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await loadCache()
        await refresh(trigger: .launch)
    }

    func loadCache() async {
        snapshots = await dataSource.loadCachedSnapshots()
        reconcilePlatformBalances()
        await publishBalancesForNotifications()
    }

    func refresh(
        trigger: RefreshTrigger,
        providerID: ProviderID? = nil,
        publishesBalanceAlerts: Bool = true
    ) async {
        guard !isRefreshing else {
            if trigger == .credentialValidation, let providerID {
                pendingCredentialValidations.insert(providerID)
            }
            return
        }
        isRefreshing = true
        let targets = fixedTargets ?? targetFactory.makeTargets()
        let selectedTargets = providerID.map { requestedProviderID in
            targets.filter { $0.providerID == requestedProviderID }
        } ?? targets
        snapshots = await dataSource.refresh(
            trigger: trigger,
            targets: selectedTargets
        )
        reconcilePlatformBalances()
        if publishesBalanceAlerts {
            await publishBalancesForNotifications()
        }
        isRefreshing = false
        await runPendingCredentialValidations()
    }

    func credentialDidChange(_ providerID: ProviderID) async {
        snapshots.removeValue(forKey: providerID)
        if let checkpoint = platformBalanceCheckpoints[providerID] {
            let remainingAmount = max(
                Decimal.zero,
                checkpoint.enteredBalance.amount - checkpoint.deductedSpend.amount
            )
            platformBalanceCheckpoints[providerID] = PlatformBalanceCheckpoint(
                providerID: providerID,
                enteredBalance: try! Money(
                    amount: remainingAmount,
                    currencyCode: checkpoint.enteredBalance.currencyCode
                ),
                synchronizedAt: now(),
                deductedSpend: try! Money(
                    amount: 0,
                    currencyCode: checkpoint.enteredBalance.currencyCode
                ),
                costAnchors: []
            )
            persistPlatformBalances()
        }
        await dataSource.purge(providerID)
        await publishBalancesForNotifications()
        await refresh(trigger: .credentialValidation, providerID: providerID)
    }

    private func runPendingCredentialValidations() async {
        let providers = pendingCredentialValidations.sorted { $0.rawValue < $1.rawValue }
        pendingCredentialValidations.removeAll()
        for providerID in providers {
            await refresh(trigger: .credentialValidation, providerID: providerID)
        }
    }

    private func completeOfficialCostSnapshot(for providerID: ProviderID) -> ProviderSnapshot? {
        guard
            let snapshot = snapshot(for: providerID),
            Self.acceptsOfficialCost(snapshot.issue),
            snapshot.capabilities.contains(.officialCostHistory),
            snapshot.coverage?.completeness == .complete
        else { return nil }
        return snapshot
    }

    private func completeTrackedCostSnapshot(for providerID: ProviderID) -> ProviderSnapshot? {
        guard let snapshot = snapshot(for: providerID) else { return nil }
        if snapshot.capabilities.contains(.estimatedCostHistory),
           !snapshot.capabilities.contains(.officialCostHistory) {
            // Include observed intervals even though they are not a complete cost report.
            // The selected-period filter has already excluded boundary-crossing intervals.
            return snapshots[providerID]?.issue == nil ? snapshot : nil
        }
        guard Self.acceptsOfficialCost(snapshot.issue),
              snapshot.coverage?.completeness == .complete,
              snapshot.capabilities.contains(.officialCostHistory)
        else { return nil }
        return snapshot
    }

    private static func acceptsOfficialCost(_ issue: ProviderIssue?) -> Bool {
        issue == nil || issue == .balanceUnavailable || issue == .usageUnavailable
    }

    private func hasCompleteCurrentCostCoverage(for providerID: ProviderID) -> Bool {
        guard
            let snapshot = snapshots[providerID],
            Self.acceptsOfficialCost(snapshot.issue),
            snapshot.capabilities.contains(.officialCostHistory),
            let coverage = snapshot.coverage,
            coverage.completeness == .complete
        else { return false }

        let currentDay = utcDayInterval(containing: now())
        return coverage.start <= currentDay.start && coverage.through >= currentDay.end
    }

    private func reconcilePlatformBalances() {
        var reconciledCheckpoints = platformBalanceCheckpoints
        var changed = false

        for (providerID, checkpoint) in platformBalanceCheckpoints {
            guard let snapshot = snapshots[providerID] else { continue }
            let reconciled = reconcile(checkpoint, with: snapshot)
            guard reconciled != checkpoint else { continue }
            reconciledCheckpoints[providerID] = reconciled
            changed = true
        }

        if changed {
            platformBalanceCheckpoints = reconciledCheckpoints
            persistPlatformBalances()
        }
    }

    private func reconcile(
        _ checkpoint: PlatformBalanceCheckpoint,
        with snapshot: ProviderSnapshot
    ) -> PlatformBalanceCheckpoint {
        guard
            snapshot.providerID == checkpoint.providerID,
            Self.acceptsOfficialCost(snapshot.issue),
            snapshot.coverage?.completeness == .complete,
            snapshot.capabilities.contains(.officialCostHistory)
        else { return checkpoint }

        let currentAnchors = preservingMissingAnchorsAsZero(
            officialCostAnchors(
                in: snapshot,
                currencyCode: checkpoint.enteredBalance.currencyCode
            ),
            from: checkpoint.costAnchors,
            coverage: snapshot.coverage
        )
        let previousCosts = checkpoint.costAnchors.reduce(into: [PlatformBalanceAnchorKey: Decimal]()) {
            $0[anchorKey(for: $1)] = $1.cost.amount
        }
        let delta = currentAnchors.reduce(into: Decimal.zero) { result, anchor in
            if let previous = previousCosts[anchorKey(for: anchor)] {
                result += anchor.cost.amount - previous
            } else if anchor.start >= checkpoint.synchronizedAt {
                result += anchor.cost.amount
            }
        }
        let deductedAmount = checkpoint.deductedSpend.amount + delta

        return PlatformBalanceCheckpoint(
            providerID: checkpoint.providerID,
            enteredBalance: checkpoint.enteredBalance,
            synchronizedAt: checkpoint.synchronizedAt,
            deductedSpend: try! Money(
                amount: deductedAmount,
                currencyCode: checkpoint.enteredBalance.currencyCode
            ),
            costAnchors: currentAnchors
        )
    }

    private func officialCostAnchors(
        in snapshot: ProviderSnapshot?,
        currencyCode: String
    ) -> [PlatformBalanceCostAnchor] {
        guard
            let snapshot,
            Self.acceptsOfficialCost(snapshot.issue),
            snapshot.coverage?.completeness == .complete
        else { return [] }

        return snapshot.buckets.compactMap { bucket in
            guard
                let cost = bucket.cost,
                cost.provenance == .official,
                cost.value.currencyCode == currencyCode
            else { return nil }
            return PlatformBalanceCostAnchor(
                start: bucket.start,
                end: bucket.end,
                cost: cost.value
            )
        }
    }

    private func synchronizationAnchors(
        in snapshot: ProviderSnapshot?,
        currencyCode: String,
        synchronizedAt: Date
    ) -> [PlatformBalanceCostAnchor] {
        var anchors = officialCostAnchors(in: snapshot, currencyCode: currencyCode)
        guard
            let snapshot,
            Self.acceptsOfficialCost(snapshot.issue),
            snapshot.capabilities.contains(.officialCostHistory),
            let coverage = snapshot.coverage,
            coverage.completeness == .complete
        else { return anchors }

        let interval = utcDayInterval(containing: synchronizedAt)
        let currentDayKey = PlatformBalanceAnchorKey(
            start: interval.start,
            end: interval.end,
            currencyCode: currencyCode
        )
        guard
            coverage.start <= interval.start,
            coverage.through >= interval.end,
            !anchors.contains(where: { anchorKey(for: $0) == currentDayKey })
        else { return anchors }

        anchors.append(
            PlatformBalanceCostAnchor(
                start: interval.start,
                end: interval.end,
                cost: try! Money(amount: 0, currencyCode: currencyCode)
            )
        )
        return anchors.sorted { $0.start < $1.start }
    }

    private func preservingMissingAnchorsAsZero(
        _ currentAnchors: [PlatformBalanceCostAnchor],
        from previousAnchors: [PlatformBalanceCostAnchor],
        coverage: ReportingCoverage?
    ) -> [PlatformBalanceCostAnchor] {
        guard let coverage else { return currentAnchors }
        var anchorsByKey = Dictionary(uniqueKeysWithValues: currentAnchors.map {
            (anchorKey(for: $0), $0)
        })

        for previous in previousAnchors {
            let key = anchorKey(for: previous)
            guard anchorsByKey[key] == nil else { continue }
            let isInsideCoverage = previous.start >= coverage.start && previous.end <= coverage.through
            anchorsByKey[key] = PlatformBalanceCostAnchor(
                start: previous.start,
                end: previous.end,
                cost: try! Money(
                    amount: isInsideCoverage ? 0 : previous.cost.amount,
                    currencyCode: previous.cost.currencyCode
                )
            )
        }

        return anchorsByKey.values.sorted { $0.start < $1.start }
    }

    private func anchorKey(for anchor: PlatformBalanceCostAnchor) -> PlatformBalanceAnchorKey {
        PlatformBalanceAnchorKey(
            start: anchor.start,
            end: anchor.end,
            currencyCode: anchor.cost.currencyCode
        )
    }

    private func utcDayInterval(containing date: Date) -> DateInterval {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: date)
        return DateInterval(
            start: start,
            end: calendar.date(byAdding: .day, value: 1, to: start)!
        )
    }

    private func persistPlatformBalances() {
        platformBalanceStore.save(platformBalanceCheckpoints)
    }

    private func publishBalancesForNotifications() async {
        let balances = platformBalanceCheckpoints.keys.reduce(
            into: [ProviderID: PlatformBalanceStatus]()
        ) { result, providerID in
            result[providerID] = platformBalance(for: providerID)
        }
        await balanceNotifier.evaluate(balances)
    }

    private func officialUSDCosts(in snapshot: ProviderSnapshot) -> [Money] {
        snapshot.buckets.compactMap(officialUSDCost(in:))
    }

    private func officialUSDCost(in bucket: PeriodBucket) -> Money? {
        guard
            let cost = bucket.cost,
            cost.provenance == .official,
            cost.value.currencyCode == "USD"
        else { return nil }
        return cost.value
    }

    private func trackedUSDCostMetrics(in snapshot: ProviderSnapshot) -> [MoneyMetric] {
        snapshot.buckets.compactMap(trackedUSDCostMetric(in:))
    }

    private func trackedUSDCostMetric(in bucket: PeriodBucket) -> MoneyMetric? {
        guard
            let cost = bucket.cost,
            cost.value.currencyCode == "USD",
            cost.provenance == .official || cost.provenance == .estimated
        else { return nil }
        return cost
    }

    private func utcStartOfDay(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.startOfDay(for: date)
    }

    private func staleInterval(for providerID: ProviderID) -> TimeInterval {
        switch providerID {
        case .openAI, .anthropic: 30 * 60
        case .deepSeek: 15 * 60
        case .qwen: 12 * 60 * 60
        case .gemini, .kimi, .xAI, .mistral, .openRouter, .perplexity:
            24 * 60 * 60
        }
    }
}
