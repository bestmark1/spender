import XCTest
import SwiftUI
@testable import LLMSpendMonitor

@MainActor
final class MenuBarShellTests: XCTestCase {
    func testCostOnlyProviderCardRendersInBothAppearances() throws {
        let suite = "Spender.RenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "provider.card.openai.expanded")
        let day = Date(timeIntervalSince1970: 1_784_332_800)
        let cost = MoneyMetric(value: try Money(amount: Decimal(string: "4.25")!, currencyCode: "USD"),
                               provenance: .official)
        let snapshot = try ProviderSnapshot(providerID: .openAI,
            capabilities: [.officialCostHistory], fetchedAt: day.addingTimeInterval(3600),
            coverage: ReportingCoverage(start: day, through: day.addingTimeInterval(86_400), completeness: .complete),
            buckets: [PeriodBucket(start: day, end: day.addingTimeInterval(86_400), cost: cost)],
            balances: [], issue: .usageUnavailable)
        for scheme in [ColorScheme.light, .dark] {
            let content = ProviderCard(metadata: try XCTUnwrap(ProviderRegistry.metadata(for: .openAI)),
                                       snapshot: snapshot)
                .defaultAppStorage(defaults)
                .padding(16)
                .frame(width: 420)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let rendered = try XCTUnwrap(renderer.nsImage)
            XCTAssertGreaterThan(rendered.size.height, 100)
            let attachment = XCTAttachment(image: rendered)
            attachment.name = "Cost report without tokens - \(scheme)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testApplicationIsConfiguredAsDocklessAgent() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    func testApplicationUsesSpenderBrandAssets() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Spender")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "Spender")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String, "Spender.icns")
        XCTAssertNotNil(Bundle.main.url(forResource: "Spender", withExtension: "icns"))

        let menuBarIcon = SpenderMenuBarIcon.make()
        XCTAssertTrue(menuBarIcon.isTemplate)
        XCTAssertEqual(menuBarIcon.size, NSSize(width: 18, height: 18))
    }

    func testSkippingOnboardingShowsDashboardAndConnectionsRemainReachable() {
        let state = AppState()

        XCTAssertEqual(state.destination, .onboarding)

        state.skipOnboarding()
        XCTAssertEqual(state.destination, .dashboard)

        state.showConnections()
        XCTAssertEqual(state.destination, .connections)

        state.showCustomize()
        XCTAssertEqual(state.destination, .customize)

        state.showDashboard()
        XCTAssertEqual(state.destination, .dashboard)
    }

    func testMenuBarLabelExposesMetricAndAccessibleDescription() {
        XCTAssertEqual(MenuBarLabelView.metricText, "$0.00")
        XCTAssertEqual(MenuBarLabelView.accessibilityLabel, "LLM API spend today: $0.00")

        let total = try! Money(amount: Decimal(string: "12.34")!, currencyCode: "USD")
        XCTAssertEqual(MenuBarLabelView.metricText(for: total), "$12.34")
        XCTAssertEqual(
            MenuBarLabelView.accessibilityLabel(for: total),
            "LLM API spend today: $12.34"
        )
    }

    func testProviderStatusDistinguishesFreshnessStates() {
        let current = ProviderStatusPresentation(
            availability: .available,
            hasSnapshot: true,
            freshness: .current,
            issue: nil
        )
        XCTAssertEqual(current.title, "Up to date")
        XCTAssertEqual(current.icon, "checkmark.circle.fill")
        XCTAssertEqual(current.tone, .success)
        XCTAssertTrue(current.isQuiet)
        XCTAssertEqual(current.explanation, "The latest provider data is available.")

        let processing = ProviderStatusPresentation(
            availability: .available,
            hasSnapshot: true,
            freshness: .processing,
            issue: nil
        )
        XCTAssertEqual(processing.title, "Processing")
        XCTAssertEqual(processing.icon, "hourglass")
        XCTAssertEqual(processing.tone, .processing)
        XCTAssertFalse(processing.isQuiet)
        XCTAssertEqual(
            processing.explanation,
            "The latest cost report is still processing and may update."
        )

        let stale = ProviderStatusPresentation(
            availability: .available,
            hasSnapshot: true,
            freshness: .stale,
            issue: nil
        )
        XCTAssertEqual(stale.title, "Stale")
        XCTAssertEqual(stale.tone, .warning)
    }

    func testProviderStatusDistinguishesUnavailableUsageFromIncompleteReport() {
        let usageUnavailable = ProviderStatusPresentation(
            availability: .available,
            hasSnapshot: true,
            freshness: .current,
            issue: .usageUnavailable
        )
        XCTAssertEqual(usageUnavailable.title, "Usage unavailable")
        XCTAssertEqual(usageUnavailable.icon, "circle.lefthalf.filled")
        XCTAssertEqual(usageUnavailable.tone, .warning)
        XCTAssertEqual(
            usageUnavailable.explanation,
            "Usage metrics are unavailable; any received cost data is preserved."
        )

        let partialData = ProviderStatusPresentation(
            availability: .available,
            hasSnapshot: true,
            freshness: .current,
            issue: .partialData
        )
        XCTAssertEqual(partialData.title, "Incomplete report")
        XCTAssertEqual(partialData.icon, "circle.lefthalf.filled")
        XCTAssertEqual(partialData.tone, .warning)
        XCTAssertEqual(
            partialData.explanation,
            "The provider returned only part of the requested report."
        )
    }

    func testEveryProviderStatusHasAccessibilityLabelAndHint() {
        let issues: [ProviderIssue?] = [
            nil,
            .authentication,
            .balanceUnavailable,
            .usageUnavailable,
            .insufficientPermissions,
            .rateLimited,
            .offline,
            .keychainLocked,
            .malformedResponse,
            .noSpendingLimit,
            .providerUnavailable,
            .partialData,
            .spendingLimitReached
        ]
        let presentations = issues.map {
            ProviderStatusPresentation(
                availability: .available,
                hasSnapshot: true,
                freshness: .current,
                issue: $0
            )
        } + [
            ProviderStatusPresentation(
                availability: .planned,
                hasSnapshot: false,
                freshness: nil,
                issue: nil
            ),
            ProviderStatusPresentation(
                availability: .unavailable,
                hasSnapshot: false,
                freshness: nil,
                issue: nil
            ),
            ProviderStatusPresentation(
                availability: .available,
                hasSnapshot: false,
                freshness: nil,
                issue: nil
            ),
            ProviderStatusPresentation(
                availability: .available,
                hasSnapshot: true,
                freshness: .current,
                issue: nil,
                requiresUsageSetup: true
            )
        ]

        for presentation in presentations {
            XCTAssertEqual(presentation.accessibilityLabel, "Status: \(presentation.title)")
            XCTAssertEqual(presentation.accessibilityHint, presentation.explanation)
            XCTAssertFalse(presentation.explanation.isEmpty)
        }
    }

    func testStatusItemRoutesLeftAndRightClicksWithoutDoubleTogglingPanel() {
        XCTAssertEqual(StatusItemClick(eventType: .leftMouseUp), .primary)
        XCTAssertEqual(StatusItemClick(eventType: .rightMouseUp), .contextMenu)
        XCTAssertEqual(StatusItemClick(eventType: .rightMouseDown), .contextMenu)

        let panel = MenuPanelPresenterStub()
        let interaction = StatusBarInteractionController(
            appState: AppState(),
            panelPresenter: panel,
            openSettings: {},
            quitApplication: {}
        )
        var contextMenuPresentations = 0

        interaction.handle(.primary) { contextMenuPresentations += 1 }
        XCTAssertEqual(panel.toggleCount, 1)
        XCTAssertEqual(contextMenuPresentations, 0)

        interaction.handle(.contextMenu) { contextMenuPresentations += 1 }
        XCTAssertEqual(panel.toggleCount, 1)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(contextMenuPresentations, 1)
    }

    func testStatusBarContextMenuCompositionAndActions() {
        let appState = AppState()
        let panel = MenuPanelPresenterStub()
        var destinationsWhenShown: [AppState.Destination] = []
        panel.onShow = { destinationsWhenShown.append(appState.destination) }
        var settingsOpenCount = 0
        var quitCount = 0
        let interaction = StatusBarInteractionController(
            appState: appState,
            panelPresenter: panel,
            openSettings: { settingsOpenCount += 1 },
            quitApplication: { quitCount += 1 }
        )
        let menu = interaction.makeContextMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Customize", "Connections", "Settings", "About Spender", "Check for Updates…", "Quit Spender"]
        )
        XCTAssertTrue(menu.items.allSatisfy { !$0.isSeparatorItem && $0.submenu == nil })
        XCTAssertTrue(
            menu.items.allSatisfy { $0.image != nil },
            "Every item carries the same symbol its counterpart in the panel's Options menu uses."
        )
        XCTAssertEqual(menu.items.last?.keyEquivalent, "q")

        interaction.performMenuItem(menu.items[0])
        XCTAssertEqual(appState.destination, .customize)
        XCTAssertEqual(panel.showCount, 1)

        interaction.performMenuItem(menu.items[1])
        XCTAssertEqual(appState.destination, .connections)
        XCTAssertEqual(panel.showCount, 2)
        XCTAssertEqual(destinationsWhenShown, [.customize, .connections])

        interaction.performMenuItem(menu.items[2])
        XCTAssertEqual(settingsOpenCount, 1)
        XCTAssertEqual(panel.showCount, 2)

        // About is asserted but not performed: it activates the app and puts a
        // panel on screen, which a unit test has no business doing.
        XCTAssertEqual(menu.items[3].title, "About Spender")
        // Likewise for updates: a check goes to the network and shows a window.
        XCTAssertEqual(menu.items[4].title, "Check for Updates…")

        interaction.performMenuItem(menu.items[5])
        XCTAssertEqual(quitCount, 1)
    }

    func testRefreshSchedulerStartsOnlyOnePeriodicLoop() async {
        let sleeper = OneShotSleeper()
        let recorder = RefreshTriggerRecorder()
        let scheduler = RefreshScheduler(
            interval: 300,
            sleep: { interval in try await sleeper.sleep(for: interval) },
            refresh: { trigger in await recorder.record(trigger) }
        )

        scheduler.start()
        scheduler.start()

        for _ in 0..<100 where await recorder.values.isEmpty {
            await Task.yield()
        }
        scheduler.stop()

        let sleepCallCount = await sleeper.currentCallCount()
        let triggers = await recorder.currentValues()
        XCTAssertEqual(sleepCallCount, 2)
        XCTAssertEqual(triggers, [.timer])
    }

    func testRefreshSchedulerForwardsLifecycleTriggers() async {
        let recorder = RefreshTriggerRecorder()
        let scheduler = RefreshScheduler(
            refresh: { trigger in await recorder.record(trigger) }
        )

        await scheduler.refreshNow(for: .panelOpen)
        await scheduler.refreshNow(for: .wake)
        await scheduler.refreshNow(for: .unlock)

        let triggers = await recorder.currentValues()
        XCTAssertEqual(triggers, [.panelOpen, .wake, .unlock])
    }

    func testNotificationSettingsReflectStoredAndDeniedPermissionState() async {
        let service = NotificationSettingsServiceStub(enabled: true, grantOnEnable: false)
        let model = NotificationSettingsViewModel(service: service)

        await model.load()
        XCTAssertTrue(model.isEnabled)

        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.permissionDenied)

        await model.setEnabled(false)
        XCTAssertFalse(model.permissionDenied)
    }

    func testLaunchAtLoginSettingsReflectRegistrationAndApprovalState() {
        let service = LaunchAtLoginServiceStub(status: .requiresApproval)
        let model = LaunchAtLoginSettingsViewModel(service: service)

        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.requiresApproval)

        model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.requiresApproval)

        model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(model.requiresApproval)
        XCTAssertEqual(service.requestedStates, [false, true])
    }

    func testMissingLaunchAtLoginServiceStillAttemptsRegistration() {
        XCTAssertTrue(LaunchAtLoginStatus.notRegistered.shouldAttemptRegistration)
        XCTAssertTrue(LaunchAtLoginStatus.notFound.shouldAttemptRegistration)
        XCTAssertFalse(LaunchAtLoginStatus.enabled.shouldAttemptRegistration)
        XCTAssertFalse(LaunchAtLoginStatus.requiresApproval.shouldAttemptRegistration)
    }
}

@MainActor
private final class MenuPanelPresenterStub: MenuPanelPresenting {
    var onShow: (() -> Void)?
    private(set) var isVisible = false
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var toggleCount = 0

    func show() {
        showCount += 1
        isVisible = true
        onShow?()
    }

    func hide() {
        hideCount += 1
        isVisible = false
    }

    func toggle() {
        toggleCount += 1
        isVisible.toggle()
    }
}

private actor OneShotSleeper {
    private(set) var callCount = 0

    func sleep(for interval: TimeInterval) throws {
        callCount += 1
        if callCount > 1 {
            throw CancellationError()
        }
    }

    func currentCallCount() -> Int {
        callCount
    }
}

private actor RefreshTriggerRecorder {
    private(set) var values: [RefreshTrigger] = []

    func record(_ trigger: RefreshTrigger) {
        values.append(trigger)
    }

    func currentValues() -> [RefreshTrigger] {
        values
    }
}

private actor NotificationSettingsServiceStub: BalanceNotificationSettingsHandling {
    private var enabled: Bool
    private let grantOnEnable: Bool

    init(enabled: Bool, grantOnEnable: Bool) {
        self.enabled = enabled
        self.grantOnEnable = grantOnEnable
    }

    func isEnabled() -> Bool {
        enabled
    }

    func setEnabled(_ requested: Bool) -> Bool {
        enabled = requested && grantOnEnable
        return enabled
    }
}

@MainActor
private final class LaunchAtLoginServiceStub: LaunchAtLoginHandling {
    private(set) var status: LaunchAtLoginStatus
    private(set) var requestedStates: [Bool] = []

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func setEnabled(_ enabled: Bool) {
        requestedStates.append(enabled)
        status = enabled ? .enabled : .notRegistered
    }

    func openSystemSettings() {}
}
