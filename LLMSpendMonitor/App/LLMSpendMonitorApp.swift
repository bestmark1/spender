import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

@main
struct LLMSpendMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsRootView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        AppUpdater.shared.start()
        statusBarController = StatusBarController()
        statusBarController?.showOnboardingIfNeeded()
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

@MainActor
final class NotificationSettingsViewModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isWorking = false
    @Published private(set) var permissionDenied = false

    private let service: any BalanceNotificationSettingsHandling

    init(
        service: any BalanceNotificationSettingsHandling = BalanceNotificationService.shared
    ) {
        self.service = service
    }

    func load() async {
        isEnabled = await service.isEnabled()
    }

    func setEnabled(_ requested: Bool) async {
        isWorking = true
        let resultingState = await service.setEnabled(requested)
        isEnabled = resultingState
        permissionDenied = requested && !resultingState
        isWorking = false
    }
}

enum LaunchAtLoginStatus: Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var shouldAttemptRegistration: Bool {
        self == .notRegistered || self == .notFound
    }

    var isRegistered: Bool {
        self == .enabled || self == .requiresApproval
    }
}

@MainActor
protocol LaunchAtLoginHandling {
    var status: LaunchAtLoginStatus { get }

    func setEnabled(_ enabled: Bool) throws
    func openSystemSettings()
}

@MainActor
struct LaunchAtLoginService: LaunchAtLoginHandling {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered:
            .notRegistered
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .notFound
        @unknown default:
            .notFound
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard status.shouldAttemptRegistration else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status.isRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginSettingsViewModel: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginHandling

    init(service: any LaunchAtLoginHandling = LaunchAtLoginService()) {
        self.service = service
        load()
    }

    func load() {
        apply(service.status)
    }

    func setEnabled(_ requested: Bool) {
        errorMessage = nil

        do {
            try service.setEnabled(requested)
            apply(service.status)
        } catch {
            apply(service.status)
            errorMessage = "Couldn’t update Launch at Login. \(error.localizedDescription)"
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }

    private func apply(_ status: LaunchAtLoginStatus) {
        isEnabled = status.isRegistered
        requiresApproval = status == .requiresApproval
    }
}

private struct SettingsRootView: View {
    @StateObject private var notifications = NotificationSettingsViewModel()
    @StateObject private var launchAtLogin = LaunchAtLoginSettingsViewModel()
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Menu bar metric") {
                    Text("Today’s spend")
                }

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    )
                )
                .accessibilityIdentifier("settings.launchAtLogin")

                Text("Keep Spender available in the menu bar after you sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if launchAtLogin.requiresApproval {
                    LabeledContent {
                        Button("Open Login Items") {
                            launchAtLogin.openSystemSettings()
                        }
                    } label: {
                        Text("Approval required")
                            .foregroundStyle(.orange)
                    }
                    .accessibilityIdentifier("settings.launchAtLoginApproval")
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.launchAtLoginError")
                }
            }

            if AppUpdater.isAvailable {
                Section("Updates") {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { updater.automaticallyChecksForUpdates },
                            set: { updater.automaticallyChecksForUpdates = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.automaticUpdates")

                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    } label: {
                        Text("Once a day, from usespender.com.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Notifications") {
                Toggle(
                    "Low balance alerts",
                    isOn: Binding(
                        get: { notifications.isEnabled },
                        set: { requested in
                            Task { await notifications.setEnabled(requested) }
                        }
                    )
                )
                .disabled(notifications.isWorking)
                .accessibilityIdentifier("settings.balanceNotifications")

                Text("Warns at 20% and at 5% of the balance you last entered. Enter a new balance to start the warnings over.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if notifications.permissionDenied {
                    Text("Notifications are disabled in macOS System Settings.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("settings.notificationPermissionDenied")
                }
            }
        }
        .formStyle(.grouped)
        // Width is fixed; height follows the form. A fixed height left a third of
        // the window empty, which reads as something that failed to load.
        .frame(width: 440)
        .frame(minHeight: 220)
        .navigationTitle("Settings")
        .accessibilityIdentifier("settings.root")
        .task {
            launchAtLogin.load()
            await notifications.load()
        }
    }
}
