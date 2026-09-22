import AppKit
import Combine
import SwiftUI

enum SpenderMenuBarIcon {
    static let size = NSSize(width: 18, height: 18)

    static func make() -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()

            NSBezierPath(
                roundedRect: NSRect(x: 6.2, y: 2, width: 5.6, height: 5.2),
                xRadius: 1.2,
                yRadius: 1.2
            ).fill()

            let pocket = NSBezierPath()
            pocket.move(to: NSPoint(x: 2.5, y: 6.4))
            pocket.curve(
                to: NSPoint(x: 9, y: 8.4),
                controlPoint1: NSPoint(x: 4.1, y: 6.4),
                controlPoint2: NSPoint(x: 5.5, y: 8.4)
            )
            pocket.curve(
                to: NSPoint(x: 15.5, y: 6.4),
                controlPoint1: NSPoint(x: 12.5, y: 8.4),
                controlPoint2: NSPoint(x: 13.9, y: 6.4)
            )
            pocket.line(to: NSPoint(x: 15.5, y: 14.4))
            pocket.curve(
                to: NSPoint(x: 14.1, y: 15.8),
                controlPoint1: NSPoint(x: 15.5, y: 15.2),
                controlPoint2: NSPoint(x: 14.9, y: 15.8)
            )
            pocket.line(to: NSPoint(x: 3.9, y: 15.8))
            pocket.curve(
                to: NSPoint(x: 2.5, y: 14.4),
                controlPoint1: NSPoint(x: 3.1, y: 15.8),
                controlPoint2: NSPoint(x: 2.5, y: 15.2)
            )
            pocket.close()
            pocket.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class RefreshScheduler {
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void
    typealias Refresh = @MainActor @Sendable (RefreshTrigger) async -> Void

    private let interval: TimeInterval
    private let sleep: Sleep
    private let refresh: Refresh
    private var periodicTask: Task<Void, Never>?

    init(
        interval: TimeInterval = 60,
        sleep: @escaping Sleep = { interval in
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        },
        refresh: @escaping Refresh
    ) {
        self.interval = interval
        self.sleep = sleep
        self.refresh = refresh
    }

    deinit {
        periodicTask?.cancel()
    }

    func start() {
        guard periodicTask == nil else { return }
        let interval = interval
        let sleep = sleep
        let refresh = refresh

        periodicTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleep(interval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await refresh(.timer)
            }
        }
    }

    func stop() {
        periodicTask?.cancel()
        periodicTask = nil
    }

    func refreshNow(for trigger: RefreshTrigger) async {
        await refresh(trigger)
    }
}

@MainActor
protocol MenuPanelPresenting: AnyObject {
    var isVisible: Bool { get }
    func show()
    func hide()
    func toggle()
}

enum StatusItemClick: Equatable {
    case primary
    case contextMenu

    init(eventType: NSEvent.EventType?) {
        self = eventType == .rightMouseDown || eventType == .rightMouseUp
            ? .contextMenu
            : .primary
    }
}

@MainActor
final class SettingsRequestRouter: ObservableObject {
    @Published private(set) var requestCount = 0

    func openSettings() {
        requestCount += 1
    }
}

enum StatusBarMenuAction: Int, CaseIterable, Equatable {
    case customize
    case connections
    case settings
    case about
    case quit

    var title: String {
        switch self {
        case .customize: "Customize"
        case .connections: "Connections"
        case .settings: "Settings"
        case .about: "About Spender"
        case .quit: "Quit Spender"
        }
    }

    /// The same symbol the panel's own Options menu uses, so the two menus read
    /// as one menu reached two ways rather than as two similar lists.
    var symbolName: String {
        switch self {
        case .customize: "slider.horizontal.3"
        case .connections: "key"
        case .settings: "gearshape"
        case .about: "info.circle"
        case .quit: "power"
        }
    }

    var keyEquivalent: String {
        self == .quit ? "q" : ""
    }
}

/// The standard macOS About panel, told the truth about this project.
///
/// A hand-built window would repeat what AppKit already draws from Info.plist —
/// icon, name, version, build, copyright — so only the part AppKit cannot know
/// is supplied: that the source is public and under which licence.
enum AboutPanel {
    static let websiteURL = URL(string: "https://usespender.com")
    static let repositoryURL = URL(string: "https://github.com/bestmark1/spender")
    static let authorOnXURL = URL(string: "https://x.com/thesignalnow")

    @MainActor
    static func present() {
        // Spender is an accessory app and is usually not frontmost; without this
        // the panel opens behind whatever the person was working in.
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        // The copyright line below already carries the year and the author, so this
        // says the part AppKit has no key for: who made it, and that the source is
        // open. "MIT" is stated once, here, rather than in both places.
        let credits = NSMutableAttributedString(
            string: "by bestmark1\nOpen source under the MIT licence.\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        // Where to find the app and the person behind it, on one line.
        let links: [(title: String, url: URL?)] = [
            ("usespender.com", websiteURL),
            ("GitHub", repositoryURL),
            ("X", authorOnXURL)
        ]
        let available = links.compactMap { link in link.url.map { (link.title, $0) } }
        for (index, link) in available.enumerated() {
            if index > 0 {
                credits.append(NSAttributedString(
                    string: MetricFormatting.separator,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            credits.append(NSAttributedString(
                string: link.0,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .link: link.1]
            ))
        }

        credits.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: credits.length)
        )
        return credits
    }
}

@MainActor
final class StatusBarInteractionController: NSObject {
    private let appState: AppState
    private let panelPresenter: any MenuPanelPresenting
    private let openSettings: () -> Void
    private let quitApplication: () -> Void

    init(
        appState: AppState,
        panelPresenter: any MenuPanelPresenting,
        openSettings: @escaping () -> Void,
        quitApplication: @escaping () -> Void
    ) {
        self.appState = appState
        self.panelPresenter = panelPresenter
        self.openSettings = openSettings
        self.quitApplication = quitApplication
    }

    func handle(_ click: StatusItemClick, showContextMenu: () -> Void) {
        switch click {
        case .primary:
            panelPresenter.toggle()
        case .contextMenu:
            showContextMenu()
        }
    }

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in StatusBarMenuAction.allCases {
            let item = NSMenuItem(
                title: action.title,
                action: #selector(performMenuItem(_:)),
                keyEquivalent: action.keyEquivalent
            )
            item.image = NSImage(
                systemSymbolName: action.symbolName,
                accessibilityDescription: nil
            )
            item.target = self
            item.tag = action.rawValue
            item.isEnabled = true
            menu.addItem(item)
        }
        return menu
    }

    @objc func performMenuItem(_ sender: NSMenuItem) {
        guard let action = StatusBarMenuAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func perform(_ action: StatusBarMenuAction) {
        switch action {
        case .customize:
            appState.showCustomize()
            panelPresenter.show()
        case .connections:
            appState.showConnections()
            panelPresenter.show()
        // The panel floats at pop-up-menu level, above ordinary windows, so a
        // window opened while it is showing lands behind it. Like a menu, the
        // panel gets out of the way once one of its commands is chosen.
        case .settings:
            panelPresenter.hide()
            openSettings()
        case .about:
            panelPresenter.hide()
            AboutPanel.present()
        case .quit:
            quitApplication()
        }
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let appState: AppState
    private let dashboardViewModel: DashboardViewModel
    private let statusItem: NSStatusItem
    private let panelPresenter: MenuPanelPresenter
    private let refreshScheduler: RefreshScheduler
    private let settingsRequestRouter: SettingsRequestRouter
    private let interactionController: StatusBarInteractionController
    private lazy var contextMenu = interactionController.makeContextMenu()
    private var cancellables: Set<AnyCancellable> = []

    init(
        appState: AppState = AppState(),
        dashboardViewModel: DashboardViewModel = .launchConfigured(),
        statusItem: NSStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    ) {
#if DEBUG
        if DebugLaunchOptions.resetProviderCardExpansion {
            for providerID in ProviderID.allCases {
                UserDefaults.standard.removeObject(
                    forKey: "provider.card.\(providerID.rawValue).expanded"
                )
            }
        }
#endif
        let quitApplication = { NSApplication.shared.terminate(nil) }
        let settingsRequestRouter = SettingsRequestRouter()
        let panelPresenter = MenuPanelPresenter(
            appState: appState,
            dashboardViewModel: dashboardViewModel,
            settingsRequestRouter: settingsRequestRouter,
            quitApplication: quitApplication
        )

        self.appState = appState
        self.dashboardViewModel = dashboardViewModel
        self.statusItem = statusItem
        self.panelPresenter = panelPresenter
        self.settingsRequestRouter = settingsRequestRouter
        refreshScheduler = RefreshScheduler { [weak dashboardViewModel] trigger in
            await dashboardViewModel?.refresh(trigger: trigger)
        }
        interactionController = StatusBarInteractionController(
            appState: appState,
            panelPresenter: panelPresenter,
            openSettings: {
                NSApplication.shared.activate(ignoringOtherApps: true)
                settingsRequestRouter.openSettings()
            },
            quitApplication: quitApplication
        )
        super.init()

        configureStatusItem()
        observeDashboardMetric()
        panelPresenter.anchorProvider = { [weak statusItem] in
            statusItem?.button
        }
        panelPresenter.didShow = { [weak self] in
            self?.requestRefresh(for: .panelOpen)
        }
        observeWorkspaceLifecycle()
        refreshScheduler.start()
        Task { await dashboardViewModel.start() }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func showOnboardingIfNeeded() {
#if DEBUG
        if DebugLaunchOptions.dashboardPreview {
            appState.skipOnboarding()
            panelPresenter.show()
            return
        }
#endif
        guard appState.destination == .onboarding else { return }
        panelPresenter.show()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        interactionController.handle(
            StatusItemClick(eventType: NSApplication.shared.currentEvent?.type)
        ) { [weak self, weak sender] in
            guard let self, let sender else { return }
            contextMenu.popUp(
                positioning: contextMenu.items.first,
                at: NSPoint(x: sender.bounds.midX, y: sender.bounds.minY),
                in: sender
            )
        }
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        requestRefresh(for: .wake)
    }

    @objc private func workspaceSessionDidBecomeActive(_ notification: Notification) {
        requestRefresh(for: .unlock)
    }

    private func requestRefresh(for trigger: RefreshTrigger) {
        Task { [weak self] in
            await self?.refreshScheduler.refreshNow(for: trigger)
        }
    }

    private func observeWorkspaceLifecycle() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        notificationCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = SpenderMenuBarIcon.make()
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(handleStatusItemClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateDashboardMetric()
    }

    private func observeDashboardMetric() {
        dashboardViewModel.$snapshots
            .sink { [weak self] _ in self?.updateDashboardMetric() }
            .store(in: &cancellables)
    }

    private func updateDashboardMetric() {
        guard let button = statusItem.button else { return }
        let total = dashboardViewModel.menuBarUSDTotal
        button.title = MenuBarLabelView.metricText(for: total)
        button.setAccessibilityLabel(MenuBarLabelView.accessibilityLabel(for: total))
    }
}

@MainActor
final class MenuPanelPresenter: NSObject, MenuPanelPresenting {
    var anchorProvider: (() -> NSStatusBarButton?)?
    var didShow: (() -> Void)?

    private let panel: MenuBarPanel
    private var outsideClickMonitor: GlobalMouseMonitor?
    private var requestedPanel = MenuPanelRequest(
        screen: "onboarding",
        height: MenuPanelMetrics.defaultHeight,
        isMeasured: false
    )
    /// True from the moment the panel opens until the person first touches it.
    ///
    /// The panel opens before the refresh has returned, so the height it can
    /// measure at that instant is of an empty summary card. Content keeps
    /// arriving for a few hundred milliseconds, and the panel follows it. The
    /// first click or keypress ends that: from then on the height is whatever it
    /// was, so nothing shifts under the pointer while it is being read.
    private var isSettlingToContent = true

    var isVisible: Bool { panel.isVisible }

    init(
        appState: AppState,
        dashboardViewModel: DashboardViewModel,
        settingsRequestRouter: SettingsRequestRouter,
        quitApplication: @escaping () -> Void
    ) {
        panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: MenuPanelMetrics.width,
                height: MenuPanelMetrics.forcedHeight ?? MenuPanelMetrics.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(
            rootView: DashboardRootView(
                appState: appState,
                dashboardViewModel: dashboardViewModel,
                settingsRequestRouter: settingsRequestRouter,
                closePanel: { [weak self] in self?.hide() },
                quitApplication: quitApplication,
                panelRequestDidChange: { [weak self] request in
                    self?.panelRequestChanged(request)
                }
            )
        )
        panel.userDidInteract = { [weak self] in
            self?.isSettlingToContent = false
        }
        outsideClickMonitor = GlobalMouseMonitor(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self?.isVisible == true else { return }
                self?.hide()
            }
        }
    }

    func show() {
        isSettlingToContent = true
        applyPanelHeight()
        positionPanel()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        didShow?()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    /// Records what the current screen wants to be.
    ///
    /// An open panel keeps its height: growing or shrinking under the pointer
    /// while someone reads it moves the Options button out from under them. Two
    /// things are still allowed through — a different screen, which is a
    /// different panel, and the first measured height after the panel opened on
    /// a placeholder. Without the second, the panel would keep the guess until
    /// the next time it was opened.
    private func panelRequestChanged(_ request: MenuPanelRequest) {
        let previousScreen = requestedPanel.screen
        requestedPanel = request

        guard panel.isVisible else { return }

        if request.screen != previousScreen {
            // A different screen is a different panel, and it settles afresh.
            isSettlingToContent = true
            applyPanelHeight()
            return
        }

        guard isSettlingToContent, request.isMeasured else { return }
        applyPanelHeight()
    }

    private func applyPanelHeight() {
        let height = MenuPanelMetrics.forcedHeight
            ?? MenuPanelMetrics.clamped(requestedPanel.height)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        // AppKit keeps the bottom-left corner, so a panel that grew would push its
        // own top up through the menu bar. Pin the top edge instead and let it
        // grow downwards, the direction a panel hanging off the menu bar grows.
        // Recomputing the position from the status item is not an option here:
        // mid-resize that arithmetic can put the panel off-screen entirely.
        let top = panel.frame.maxY
        let left = panel.frame.minX
        panel.setContentSize(NSSize(width: MenuPanelMetrics.width, height: height))
        if panel.isVisible {
            panel.setFrameTopLeftPoint(NSPoint(x: left, y: top))
        }
    }

    private func positionPanel() {
        // First run opens this panel by itself rather than from a click, so there is
        // no status item to point at and nothing to point away from. Centre it.
        guard requestedPanel.screen != "onboarding" else {
            centerBelowMenuBar()
            return
        }

        guard
            let button = anchorProvider?(),
            let buttonWindow = button.window,
            // The status item takes its place in the menu bar a moment after launch.
            // Until it does, its window sits at the origin with zero height, and
            // anchoring to it asks for an origin off the bottom-left of the screen —
            // which the clamp below then pins flush into the corner.
            buttonWindow.frame.height > 0
        else {
            centerBelowMenuBar()
            return
        }

        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: buttonRectOnScreen.midX - panelSize.width / 2,
            y: buttonRectOnScreen.minY - panelSize.height - MenuPanelMetrics.menuBarGap
        )
        panel.setFrameOrigin(constrainedOrigin(origin, size: panelSize, screen: buttonWindow.screen))
    }

    private func centerBelowMenuBar() {
        guard let screen = NSScreen.main else { return }
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: screen.visibleFrame.midX - panelSize.width / 2,
            y: screen.visibleFrame.maxY - panelSize.height - MenuPanelMetrics.menuBarGap
        )
        panel.setFrameOrigin(origin)
    }

    private func constrainedOrigin(_ origin: NSPoint, size: NSSize, screen: NSScreen?) -> NSPoint {
        guard let visibleFrame = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), visibleFrame.maxX - size.width),
            y: max(origin.y, visibleFrame.minY)
        )
    }
}

private final class GlobalMouseMonitor: @unchecked Sendable {
    private let token: Any?

    init(matching mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> Void) {
        token = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    deinit {
        if let token {
            NSEvent.removeMonitor(token)
        }
    }
}

#if DEBUG
private enum DebugLaunchOptions {
    static let dashboardPreview = ProcessInfo.processInfo.arguments.contains("--dashboard-preview")
    static let resetProviderCardExpansion = ProcessInfo.processInfo.arguments.contains(
        "--reset-provider-card-expansion"
    )
}
#endif

final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Called the first time the person clicks or types into the open panel.
    /// The presenter uses it to stop following the content's height.
    var userDidInteract: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .keyDown:
            userDidInteract?()
        default:
            break
        }
        super.sendEvent(event)
    }
}
