import AppKit
import Foundation

public final class LaunchWatcher {
    private let store: HiderConfigStore
    private let debounceInterval: TimeInterval
    private var observer: NSObjectProtocol?
    private var pendingWork: DispatchWorkItem?
    private var pendingBundleIDs = Set<String>()

    public init(store: HiderConfigStore = .shared, debounceInterval: TimeInterval = 0.35) {
        self.store = store
        self.debounceInterval = debounceInterval
    }

    public func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.applicationDidLaunch(notification)
        }
    }

    public func stop() {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            self.observer = nil
        }
        pendingWork?.cancel()
        pendingWork = nil
        pendingBundleIDs.removeAll()
    }

    deinit {
        stop()
    }

    private func applicationDidLaunch(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              let bundleID = application.bundleIdentifier else { return }

        pendingBundleIDs.insert(bundleID)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let bundleIDs = self.pendingBundleIDs
            self.pendingBundleIDs.removeAll()
            self.pendingWork = nil
            self.store.enforceLaunches(bundleIDs: bundleIDs)
        }
        pendingWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }
}
