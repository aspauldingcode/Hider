import SwiftUI
import Combine
import Darwin

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults(suiteName: "com.aspauldingcode.hider")!
    
    @Published var hideFinder: Bool {
        didSet {
            defaults.set(hideFinder, forKey: "hideFinder")
            if oldValue == true && hideFinder == false {
                showRestartDockButton = true
            }
            notifyTweak()
        }
    }
    
    @Published var hideTrash: Bool {
        didSet {
            defaults.set(hideTrash, forKey: "hideTrash")
            if oldValue == true && hideTrash == false {
                showRestartDockButton = true
            }
            notifyTweak()
        }
    }

    @Published var showRestartDockButton: Bool = false
    
    init() {
        self.hideFinder = defaults.object(forKey: "hideFinder") as? Bool ?? false
        self.hideTrash = defaults.object(forKey: "hideTrash") as? Bool ?? false
        
        // Register defaults
        defaults.register(defaults: [
            "hideFinder": false,
            "hideTrash": false
        ])
    }
    
    func synchronize() {
        defaults.synchronize()
        notifyTweak()
    }

    func restartDock() {
        // Tell the injected dylib to write separators back to com.apple.dock
        // prefs before we kill the process, so they appear after the restart.
        post_notification("com.hider.prepareRestart")
        showRestartDockButton = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["Dock"]
            try? process.run()
        }
    }
    
    private func notifyTweak() {
        defaults.synchronize()
        let notificationName = "com.aspauldingcode.hider.settingsChanged"
        post_notification(notificationName)
    }
}
