import Combine
import Foundation
#if !APP_STORE
import Sparkle
#endif

/// Updates for the copy downloaded from the website, through Sparkle.
///
/// The App Store build compiles this without Sparkle: the App Store updates
/// that copy itself, and forbids apps that replace their own code. There
/// `isAvailable` is false and every entry point to updates is hidden.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let shared = AppUpdater()

    /// Whether this build updates itself at all.
    nonisolated static var isAvailable: Bool {
#if APP_STORE
        false
#else
        true
#endif
    }

    @Published private(set) var canCheckForUpdates = false

    /// A scheduled check found an update that has not been shown yet.
    ///
    /// Spender lives in the menu bar with no Dock icon. An update window that
    /// appears on its own, over whatever the person is doing, is exactly what
    /// Sparkle's "gentle reminders" exist to avoid, so a background find only
    /// raises this flag and the panel offers the update where it is looked at.
    @Published private(set) var hasPendingUpdate = false

#if !APP_STORE
    private var controller: SPUStandardUpdaterController?
#endif

    private override init() {
        super.init()
    }

    /// Starts scheduled checks. Called once, at launch.
    ///
    /// Only a release build checks. Debug builds are what the test runner
    /// launches, and an update check there put Sparkle's windows on the
    /// developer's screen in the middle of a test run.
    func start() {
#if !APP_STORE && !DEBUG
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        self.controller = controller
#endif
    }

    func checkForUpdates() {
#if !APP_STORE
        hasPendingUpdate = false
        controller?.checkForUpdates(nil)
#endif
    }

    var automaticallyChecksForUpdates: Bool {
        get {
#if APP_STORE
            false
#else
            controller?.updater.automaticallyChecksForUpdates ?? false
#endif
        }
        set {
#if !APP_STORE
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
#endif
        }
    }
}

#if !APP_STORE
// Sparkle calls its user-driver delegate on the main thread; the
// preconcurrency conformance keeps that promise checked at runtime.
extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Shows a scheduled update straight away only when Spender already has
    /// the person's attention; otherwise it waits in the panel.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        if !handleShowingUpdate {
            hasPendingUpdate = true
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        hasPendingUpdate = false
    }
}
#endif
