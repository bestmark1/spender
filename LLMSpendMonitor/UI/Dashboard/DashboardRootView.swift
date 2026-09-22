import AppKit
import SwiftUI

struct DashboardRootView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @ObservedObject var settingsRequestRouter: SettingsRequestRouter
    @StateObject private var customizeViewModel = CustomizeViewModel()
    @Environment(\.openSettings) private var openSettings
    let closePanel: () -> Void
    let quitApplication: () -> Void
    var panelRequestDidChange: (MenuPanelRequest) -> Void = { _ in }

    @State private var dashboardHeight: CGFloat?
    @State private var onboardingHeight: CGFloat?

    var body: some View {
        Group {
            switch appState.destination {
            case .onboarding:
                OnboardingView(
                    heightDidChange: { onboardingHeight = $0 },
                    skip: appState.skipOnboarding,
                    connect: appState.showConnections
                )
            case .dashboard:
                DashboardView(
                    heightDidChange: { dashboardHeight = $0 },
                    viewModel: dashboardViewModel,
                    providers: customizeViewModel.items
                        .filter(\.isVisible)
                        .map(\.metadata),
                    moveProvider: { providerID, destinationID in
                        customizeViewModel.move(providerID, to: destinationID)
                    },
                    showConnections: appState.showConnections,
                    showCustomize: appState.showCustomize,
                    closePanel: closePanel,
                    quitApplication: quitApplication
                )
            case .connections:
                ConnectionsView(
                    showDashboard: appState.showDashboard,
                    credentialDidChange: { providerID in
                        Task { await dashboardViewModel.credentialDidChange(providerID) }
                    }
                )
            case .customize:
                CustomizeProvidersView(
                    viewModel: customizeViewModel,
                    showDashboard: appState.showDashboard
                )
            }
        }
        .frame(width: MenuPanelMetrics.width)
        .demoAppStorageIfNeeded()
        .background {
            GlassSurface(cornerRadius: 18, prominence: .panel)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityIdentifier("menu.panel")
        .onChange(of: settingsRequestRouter.requestCount) {
            openSettings()
        }
        .onAppear { panelRequestDidChange(panelRequest) }
        .onChange(of: panelRequest) { _, request in
            panelRequestDidChange(request)
        }
    }

    /// The dashboard and the onboarding screen size themselves; Connections and
    /// Customize are scrolling lists that keep the standing height.
    private var panelRequest: MenuPanelRequest {
        switch appState.destination {
        case .dashboard:
            // Each period is its own screen for sizing. An open panel keeps its
            // height so nothing moves under the pointer, but a period switch is
            // made at the top of the panel, and without this a panel opened on
            // 30 Days left Today a band of empty space.
            MenuPanelRequest(
                screen: "dashboard.\(dashboardViewModel.selectedPeriod.rawValue)",
                height: dashboardHeight ?? MenuPanelMetrics.defaultHeight,
                isMeasured: dashboardHeight != nil
            )
        case .onboarding:
            MenuPanelRequest(
                screen: "onboarding",
                height: onboardingHeight ?? MenuPanelMetrics.defaultHeight,
                isMeasured: onboardingHeight != nil
            )
        case .connections:
            MenuPanelRequest(
                screen: "connections",
                height: MenuPanelMetrics.defaultHeight,
                isMeasured: true
            )
        case .customize:
            MenuPanelRequest(
                screen: "customize",
                height: MenuPanelMetrics.defaultHeight,
                isMeasured: true
            )
        }
    }
}

private struct OnboardingView: View {
    let heightDidChange: (CGFloat) -> Void
    let skip: () -> Void
    let connect: () -> Void

    @AccessibilityFocusState private var headingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)

                Text("Spender")
                    .font(.title2.bold())
                    .accessibilityIdentifier("onboarding.appName")
            }

            Text("Every API bill in one place.")
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
                .accessibilityIdentifier("onboarding.heading")

            // The fear in the room is handing an API key with billing access to an
            // unknown app, so the answer to it leads rather than trailing a sentence
            // about something else. "Private" is an adjective; the Keychain and the
            // absent server are the thing itself.
            Text("Your keys stay in the macOS Keychain. No account, no server — Spender reads your spend straight from the providers, from this Mac.")
                .foregroundStyle(.secondary)
                // Without this the panel and the paragraph argue: a tight height
                // proposal compresses the text to one line, that shorter layout is
                // what gets measured, and the panel settles at a height where the
                // sentence stays truncated. Claiming the full wrapped height ends
                // the argument in the text's favour.
                .fixedSize(horizontal: false, vertical: true)

            Button("Connect Provider", action: connect)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding.connect")

            // For anyone not ready to hand over a billing key yet: the whole
            // interface, over made-up figures, with a way back from inside it.
            Button("Try with sample data") {
                SampleData.relaunch(showingSampleData: true)
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("onboarding.sampleData")

            // One exit, not two. The close button did the same job as Skip and only
            // made the reader choose between them.
            Button("Skip for now", action: skip)
                .buttonStyle(.link)
                .accessibilityIdentifier("onboarding.skip")
        }
        .padding(24)
        // Sized to its own content: the screen is a short pitch and two buttons,
        // and stretching it to the dashboard's height only added empty room.
        .measuringPanelPart("onboarding")
        .onPreferenceChange(PanelPartHeights.self) { heights in
            if let height = heights["onboarding"] { heightDidChange(height) }
        }
        .onAppear { headingFocused = true }
    }
}

private struct DashboardView: View {
    let heightDidChange: (CGFloat) -> Void
    @ObservedObject var viewModel: DashboardViewModel
    let providers: [ProviderMetadata]
    let moveProvider: (ProviderID, ProviderID) -> Bool
    let showConnections: () -> Void
    let showCustomize: () -> Void
    let closePanel: () -> Void
    let quitApplication: () -> Void

    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: MenuPanelMetrics.headerInset) {
            HStack {
                Text("Spender")
                    .font(.title2.bold())
                    // Centre the buttons on the letters rather than on the
                    // line box, whose descender room sits them visibly low.
                    .alignmentGuide(VerticalAlignment.center) { d in
                        d[.firstTextBaseline] - MenuPanelMetrics.titleCapHeight / 2
                    }
                Spacer()
                // A scheduled check found an update: offered here, where the
                // person is already looking, rather than in a window of its own.
                if updater.hasPendingUpdate {
                    DashboardHeaderButton(
                        title: "Install Update",
                        systemImage: "arrow.down.circle.fill",
                        accessibilityIdentifier: "dashboard.installUpdate"
                    ) {
                        closePanel()
                        updater.checkForUpdates()
                    }
                    .foregroundStyle(Color.accentColor)
                }
                DashboardHeaderButton(
                    title: "Refresh",
                    systemImage: "arrow.clockwise",
                    isDisabled: viewModel.isRefreshing,
                    accessibilityIdentifier: "dashboard.refresh"
                ) {
                    Task { await viewModel.refresh(trigger: .manual) }
                }
                DashboardHeaderButton(
                    title: "Close",
                    systemImage: "xmark",
                    accessibilityIdentifier: "dashboard.close",
                    action: closePanel
                )
            }
            // "Spender" starts where "Tracked spend" starts in the card below:
            // the card's inset plus its own content inset.
            .padding(.horizontal, MenuPanelMetrics.summaryContentInset)
            .measuringPanelPart("header")

            if DemoLaunch.isEnabled {
                SampleDataBanner()
                    .measuringPanelPart("banner")
            }

            PeriodPicker(selection: $viewModel.selectedPeriod)
                .measuringPanelPart("picker")
            }

            VStack(alignment: .leading, spacing: MenuPanelMetrics.optionsGap) {
            // The summary and the provider cards are one stack of cards, so they
            // share the cards' spacing rather than the wider gap between the
            // panel's rows above.
            VStack(alignment: .leading, spacing: MenuPanelMetrics.providerCardSpacing) {
            SummaryCard(
                total: viewModel.trackedUSDTotal,
                breakdown: viewModel.trackedUSDBreakdown,
                dailySpend: viewModel.trackedUSDDailySpend,
                excludedProviderCount: viewModel.excludedOfficialCostProviderCount,
                showsDetails: viewModel.selectedPeriod == .thirtyDays
            )
            .measuringPanelPart("summary")

            ScrollView {
                LazyVStack(spacing: MenuPanelMetrics.providerCardSpacing) {
                    ForEach(providers) { provider in
                        ProviderCard(
                            metadata: provider,
                            snapshot: viewModel.snapshot(for: provider.id),
                            freshness: viewModel.providerFreshness(for: provider.id),
                            platformBalance: viewModel.platformBalance(for: provider.id),
                            synchronizeBalance: viewModel.canSynchronizePlatformBalance(for: provider.id) ? { balance in
                                await viewModel.synchronizePlatformBalance(
                                    providerID: provider.id,
                                    balance: balance
                                )
                            } : nil
                        )
                        .measuringPanelPart("card")
                        .draggable(provider.id.rawValue)
                        .dropDestination(for: String.self) { values, _ in
                            guard
                                let rawValue = values.first,
                                let draggedProviderID = ProviderID(rawValue: rawValue)
                            else { return false }
                            return moveProvider(draggedProviderID, provider.id)
                        }
                    }

                    if providers.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("No providers shown")
                                .font(.headline)
                            Button("Choose Providers", action: showCustomize)
                                .buttonStyle(.link)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .accessibilityIdentifier("dashboard.noProviders")
                    }
                }
                .measuringPanelPart("list")
                // Room for the cards' shadows inside the scroll view's clip, so
                // the last card keeps its rounded corners and its shadow.
                .padding(listShadowRoom)
            }
            // The list is the one row that gives way. It never grows past the
            // cap, and it yields height back when the summary grows on the
            // 30 Days tab, so a frozen panel still fits everything it must.
            .frame(maxHeight: listCap + listShadowRoom.top + listShadowRoom.bottom)
            // The shadow room is drawn over the neighbours, not laid out: the
            // gaps around the list stay what they were.
            .padding(EdgeInsets(
                top: -listShadowRoom.top,
                leading: -listShadowRoom.leading,
                bottom: -listShadowRoom.bottom,
                trailing: -listShadowRoom.trailing
            ))
            }

            Menu {
                Button {
                    showCustomize()
                } label: {
                    Label("Customize", systemImage: StatusBarMenuAction.customize.symbolName)
                }
                .accessibilityIdentifier("options.customize")

                Button {
                    showConnections()
                } label: {
                    Label("Connections", systemImage: StatusBarMenuAction.connections.symbolName)
                }
                .accessibilityIdentifier("options.connections")

                // Settings and About open ordinary windows, which would land
                // behind the panel's pop-up-menu level. The panel closes first.
                Button {
                    closePanel()
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openSettings()
                } label: {
                    Label("Settings", systemImage: StatusBarMenuAction.settings.symbolName)
                }
                .accessibilityIdentifier("options.settings")

                Divider()

                Button {
                    closePanel()
                    AboutPanel.present()
                } label: {
                    Label("About Spender", systemImage: StatusBarMenuAction.about.symbolName)
                }
                .accessibilityIdentifier("options.about")

                if AppUpdater.isAvailable {
                    Button {
                        closePanel()
                        updater.checkForUpdates()
                    } label: {
                        Label(
                            updater.hasPendingUpdate ? "Install Update…" : "Check for Updates…",
                            systemImage: StatusBarMenuAction.checkForUpdates.symbolName
                        )
                    }
                    .disabled(!updater.canCheckForUpdates)
                    .accessibilityIdentifier("options.checkForUpdates")
                }

                Button {
                    quitApplication()
                } label: {
                    Label("Quit Spender", systemImage: StatusBarMenuAction.quit.symbolName)
                }
                .keyboardShortcut("q")
                .accessibilityIdentifier("options.quit")
            } label: {
                // A borderless menu gives no sign it can be pressed until the
                // pointer is already on it. The capsule says so standing still.
                HStack(spacing: 5) {
                    Image(systemName: "ellipsis.circle")
                    Text("Options")
                }
                .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // On the menu itself, not in its label: a borderless menu redraws
            // the label from its image and text alone and drops anything else.
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.8))
            .contentShape(Capsule())
            .accessibilityIdentifier("options.menu")
            .measuringPanelPart("options")
            }
        }
        // One side margin for the cards, the picker and Options; the title
        // alone sits further in, level with the summary's text.
        .padding(.horizontal, MenuPanelMetrics.cardInset)
        .padding(.top, MenuPanelMetrics.headerInset)
        .padding(.bottom, MenuPanelMetrics.bottomInset)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("dashboard.root")
        .task { await viewModel.start() }
        .onPreferenceChange(PanelPartHeights.self) { heights in
            partHeights = heights
        }
        .onChange(of: desiredHeight) { _, height in
            heightDidChange(height)
        }
    }

    @State private var partHeights: [String: CGFloat] = [:]
    /// Shadow room around the cards. While the list scrolls, the room below
    /// stays inside the gap between cards, so the last whole card keeps part
    /// of its shadow and none of the next card shows.
    private var listShadowRoom: EdgeInsets {
        var room = MenuPanelMetrics.cardShadowRoom
        if providers.count > MenuPanelMetrics.visibleProviderCap {
            room.bottom = MenuPanelMetrics.providerCardSpacing - 1
        }
        return room
    }

    /// Three collapsed cards and the gaps between them — or fewer, when fewer
    /// providers are shown.
    private var listCap: CGFloat {
        let count = CGFloat(min(providers.count, MenuPanelMetrics.visibleProviderCap))
        guard count > 0, let card = partHeights["card"], card > 0 else {
            return .infinity
        }
        return card * count + MenuPanelMetrics.providerCardSpacing * (count - 1)
    }

    /// What the panel would have to be for this dashboard to fit exactly.
    ///
    /// Reported rather than measured off the panel itself: measuring the laid-out
    /// root would only ever return the height the panel already has.
    private var desiredHeight: CGFloat {
        let rows = ["header", "picker", "summary", "options"].compactMap { partHeights[$0] }
        guard rows.count == 4, let list = partHeights["list"] else {
            return MenuPanelMetrics.defaultHeight
        }
        // The sample-data banner is a fifth row, present only in that mode.
        let banner = partHeights["banner"].map { $0 + MenuPanelMetrics.headerInset } ?? 0
        return MenuPanelMetrics.chromeHeight + rows.reduce(0, +) + banner + min(list, listCap)
    }
}

/// Says, on every screen of a sample launch, that the figures are made up,
/// and offers the way back to the person's own data.
private struct SampleDataBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sample data")
                    .font(.callout.weight(.semibold))
                Text("Made-up figures. Nothing is read from your accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Exit") {
                SampleData.relaunch(showingSampleData: false)
            }
            .controlSize(.small)
            .accessibilityLabel("Exit sample data")
            .accessibilityIdentifier("sampleData.exit")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sampleData.banner")
    }
}

private struct DashboardHeaderButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let accessibilityIdentifier: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
            .background(
                Color.primary.opacity(isHovered && !isDisabled ? 0.08 : 0),
                in: Circle()
            )
            .disabled(isDisabled)
            .onHover { hovering in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
            .help(title)
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private extension View {
    /// Keeps the screenshot demo build from writing card-expansion state into
    /// the installed app's preferences.
    @ViewBuilder
    func demoAppStorageIfNeeded() -> some View {
        if let defaults = DemoLaunch.defaults {
            defaultAppStorage(defaults)
        } else {
            self
        }
    }
}

/// Size of the menu bar panel.
///
/// The width is fixed. The height follows what the dashboard actually has to
/// show — a person tracking two providers should not get a panel sized for
/// four — and stops at `visibleProviderCap` cards so the panel never grows into
/// a window. Past that the provider list scrolls.
enum MenuPanelMetrics {
    /// 340 in every shipping build. The demo build may be told otherwise via
    /// `SPENDER_DEMO_PANEL_WIDTH`, so width can be judged from captures side by
    /// side rather than argued about.
    static var width: CGFloat {
#if DEBUG
        if
            DemoLaunch.isEnabled,
            let raw = ProcessInfo.processInfo.environment["SPENDER_DEMO_PANEL_WIDTH"],
            let requested = Double(raw),
            requested >= 320,
            requested <= 600
        {
            return CGFloat(requested)
        }
#endif
        return 340
    }

    /// Used before the dashboard has measured itself, and by every other screen.
    static let defaultHeight: CGFloat = 640

    /// Distance from the bottom of the menu bar to the top of the panel. Flush:
    /// the panel draws its own shadow, which reads as separation on its own, and
    /// any gap on top of that detaches the panel from the icon it belongs to.
    static let menuBarGap: CGFloat = 0

    /// The tallest the provider list is allowed to get, in whole cards. A fourth
    /// card is not shown half-cut at the panel edge: it is scrolled to.
    static let visibleProviderCap = 3

    /// Everything the dashboard spends on itself rather than on content:
    /// `headerInset` above the title and under it, `bottomInset` below
    /// Options, the 16pt gap under the period picker, one card gap between the summary and the
    /// provider list, and `optionsGap` above Options.
    /// Keep this in step with `DashboardView.body`.
    static var chromeHeight: CGFloat {
        headerInset * 2 + bottomInset + 16 + providerCardSpacing + optionsGap
    }

    /// Above the title row and between it and the period picker — the same
    /// both ways, so the title sits centred in its band.
    static let headerInset: CGFloat = 14

    /// Cap height of the title's font, for centring the header buttons on
    /// the word "Spender" rather than on its line box.
    static let titleCapHeight: CGFloat = {
        let font = NSFont.preferredFont(forTextStyle: .title2)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        return bold.capHeight
    }()

    /// Below the Options button, to the panel's bottom edge.
    static let bottomInset: CGFloat = 10

    /// Between the last card and the Options button.
    static let optionsGap: CGFloat = 10

    /// Side margin of the stack of cards — summary and providers — and of the
    /// period picker and Options, which line up with the cards' edges.
    static let cardInset: CGFloat = 10

    /// The summary card's own horizontal content inset. The title above uses
    /// it too, so "Spender" and "Tracked spend" start at the same x.
    static let summaryContentInset: CGFloat = 15

    /// Spacing between provider cards, and between the summary and the first.
    static let providerCardSpacing: CGFloat = 5

    /// How far a provider card's shadow reaches past its edges.
    static let cardShadowRoom = EdgeInsets(top: 4, leading: 8, bottom: 10, trailing: 8)

    private static let minHeight: CGFloat = 320
    private static let maxHeight: CGFloat = 900

    static func clamped(_ height: CGFloat) -> CGFloat {
        min(max(height, minHeight), maxHeight)
    }

    /// A height the demo build is told to use regardless of content, so a
    /// screenshot can be framed deliberately. Never set in a shipping build.
    static var forcedHeight: CGFloat? {
#if DEBUG
        if
            DemoLaunch.isEnabled,
            let raw = ProcessInfo.processInfo.environment["SPENDER_DEMO_PANEL_HEIGHT"],
            let requested = Double(raw),
            requested >= 320,
            requested <= 1200
        {
            return CGFloat(requested)
        }
#endif
        return nil
    }
}

/// The panel size one screen is asking for.
///
/// `screen` is the identity of what is on display, not a label: the controller
/// resizes when the screen changes and holds still otherwise, so the panel never
/// jumps under the pointer while someone is reading it.
struct MenuPanelRequest: Equatable {
    var screen: String
    var height: CGFloat
    /// False while the screen is still a placeholder — the panel opens before
    /// SwiftUI has laid anything out, and the first height it offers is a guess.
    var isMeasured: Bool
}

/// Heights of the dashboard's individual rows, keyed by name.
///
/// Every part measured here is intrinsically sized, so a reading never depends on
/// how tall the panel currently is — which is what keeps resizing from feeding
/// back into itself. Duplicate keys reduce to the smallest, so the per-card key
/// yields a collapsed card even when one card is expanded.
private struct PanelPartHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { min($0, $1) }
    }
}

private extension View {
    func measuringPanelPart(_ name: String) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PanelPartHeights.self,
                    value: [name: proxy.size.height]
                )
            }
        }
    }
}
