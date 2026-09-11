import AppKit
import Combine
import HiderCore

/// Shared settings façade for the menubar applet and CLI.
final class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let store: HiderConfigStore
    private var isReloading = false

    @Published var hideFinder: Bool {
        didSet {
            guard !isReloading, oldValue != hideFinder else { return }
            try? store.setFinderHidden(hideFinder)
            stageApply()
        }
    }

    @Published var hideTrash: Bool {
        didSet {
            guard !isReloading, oldValue != hideTrash else { return }
            try? store.setTrashHidden(hideTrash)
            stageApply()
        }
    }

    @Published var hideSeparators: Bool {
        didSet {
            guard !isReloading, oldValue != hideSeparators else { return }
            try? store.setSeparatorsHidden(hideSeparators)
            stageApply()
        }
    }

    @Published var hideRunningApps: Bool {
        didSet {
            guard !isReloading, oldValue != hideRunningApps else { return }
            try? store.setRunningAppsHidden(hideRunningApps)
            stageApply()
        }
    }

    @Published var hiddenApps: [String] {
        didSet {
            guard !isReloading, oldValue != hiddenApps else { return }
            try? store.setHiddenApps(hiddenApps)
            stageApply()
        }
    }

    init(store: HiderConfigStore = .shared) {
        self.store = store
        let config = store.currentConfig()
        hideFinder = config.hideFinder
        hideTrash = config.hideTrash
        hideSeparators = config.hideSeparators
        hideRunningApps = config.hideRunningApps
        hiddenApps = config.hiddenApps
        observeExternalChanges()
    }

    deinit {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func addHiddenApp(_ bundleID: String) {
        guard !hiddenApps.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame })
        else { return }
        hiddenApps.append(bundleID)
        if !hideRunningApps { hideRunningApps = true }
    }

    func removeHiddenApp(_ bundleID: String) {
        hiddenApps.removeAll { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    func exportConfig() throws {
        try store.export()
    }

    func restartDock() {
        relaunchRequested = true
        scheduleRelaunchAttempt(after: 0.2)
    }

    private func observeExternalChanges() {
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let manager = Unmanaged<SettingsManager>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { manager.reloadFromStore() }
        }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            callback,
            HiderConfigStore.settingsChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func reloadFromStore() {
        let config = store.currentConfig()
        isReloading = true
        defer { isReloading = false }
        hideFinder = config.hideFinder
        hideTrash = config.hideTrash
        hideSeparators = config.hideSeparators
        hideRunningApps = config.hideRunningApps
        hiddenApps = config.hiddenApps
    }

    // Debounced Dock rebuild — required for refuse-insert to take effect.
    private let autoApplyDebounce: TimeInterval = 1.0
    private var pendingRelaunch: DispatchWorkItem?
    private var relaunchRequested = false
    private var lastRelaunchAt = Date.distantPast
    private let minRelaunchGap: TimeInterval = 5

    private func stageApply() {
        relaunchRequested = true
        scheduleRelaunchAttempt(after: autoApplyDebounce)
    }

    private func scheduleRelaunchAttempt(after delay: TimeInterval) {
        pendingRelaunch?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attemptRelaunch() }
        pendingRelaunch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func attemptRelaunch() {
        guard relaunchRequested else { return }
        let sinceLast = Date().timeIntervalSince(lastRelaunchAt)
        if sinceLast < minRelaunchGap {
            scheduleRelaunchAttempt(after: minRelaunchGap - sinceLast)
            return
        }
        guard NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else {
            scheduleRelaunchAttempt(after: 2)
            return
        }
        relaunchRequested = false
        lastRelaunchAt = Date()
        store.postPrepareRestart()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Dock"]
            try? task.run()
        }
    }
}
