import SwiftUI
import Combine
import Darwin

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    private let defaults = UserDefaults(suiteName: "com.aspauldingcode.hider")!
    
    private static func normalizeBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    @Published var hideFinder: Bool {
        didSet {
            defaults.set(hideFinder, forKey: "hideFinder")
            if oldValue && !hideFinder { showRestartDockButton = true }
            notifyTweak()
        }
    }

    @Published var hideTrash: Bool {
        didSet {
            defaults.set(hideTrash, forKey: "hideTrash")
            if oldValue && !hideTrash { showRestartDockButton = true }
            notifyTweak()
        }
    }

    @Published var hiddenApps: [String] {
        didSet {
            defaults.set(hiddenApps, forKey: "hiddenApps")
            let previous = Set(oldValue.map(Self.normalizeBundleID))
            let current = Set(hiddenApps.map(Self.normalizeBundleID))
            let added = current.subtracting(previous)
            // Post explicit "added" events so Dock can do non-debounced refreshes.
            for _ in added {
                post_notification("com.aspauldingcode.hider.hiddenAppAdded")
            }
            // Hidden app list changes are hotloaded by the tweak; no restart needed.
            showRestartDockButton = false
            notifyTweak()
        }
    }

    @Published var showRestartDockButton: Bool = false
    @Published var showAppPicker: Bool = false

    init() {
        hideFinder = defaults.object(forKey: "hideFinder") as? Bool ?? false
        hideTrash  = defaults.object(forKey: "hideTrash")  as? Bool ?? false
        hiddenApps = defaults.object(forKey: "hiddenApps") as? [String] ?? []
        defaults.register(defaults: [
            "hideFinder": false,
            "hideTrash":  false,
            "hiddenApps": [String]()
        ])
    }

    func addHiddenApp(_ bundleID: String) {
        guard !hiddenApps.contains(bundleID) else { return }
        hiddenApps.append(bundleID)
    }

    func removeHiddenApp(_ bundleID: String) {
        hiddenApps.removeAll { $0 == bundleID }
    }

    func synchronize() {
        defaults.synchronize()
        notifyTweak()
    }

    func restartDock() {
        post_notification("com.hider.prepareRestart")
        showRestartDockButton = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            task.arguments = ["Dock"]
            try? task.run()
        }
    }

    private func notifyTweak() {
        defaults.synchronize()
        post_notification("com.aspauldingcode.hider.settingsChanged")
    }
}
