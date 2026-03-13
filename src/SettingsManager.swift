import SwiftUI
import Combine

enum SeparatorMode: Int, CaseIterable, Identifiable {
    case keep = 0
    case remove = 1
    case auto = 2
    
    var id: Int { self.rawValue }
    
    var title: String {
        switch self {
        case .keep: return "Keep All"
        case .remove: return "Remove All"
        case .auto: return "Automatic"
        }
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    private let defaults = UserDefaults(suiteName: "com.aspauldingcode.hider")!
    
    @Published var hideFinder: Bool {
        didSet { 
            defaults.set(hideFinder, forKey: "hideFinder")
            notifyTweak()
        }
    }
    
    @Published var hideTrash: Bool {
        didSet { 
            defaults.set(hideTrash, forKey: "hideTrash")
            notifyTweak()
        }
    }
    
    @Published var hideSeparators: Bool {
        didSet { 
            defaults.set(hideSeparators, forKey: "hideSeparators")
            notifyTweak()
        }
    }
    
    @Published var separatorMode: SeparatorMode {
        didSet { 
            defaults.set(separatorMode.rawValue, forKey: "separatorMode")
            notifyTweak()
        }
    }
    
    init() {
        self.hideFinder = defaults.object(forKey: "hideFinder") as? Bool ?? false
        self.hideTrash = defaults.object(forKey: "hideTrash") as? Bool ?? false
        self.hideSeparators = defaults.object(forKey: "hideSeparators") as? Bool ?? false
        let modeValue = defaults.integer(forKey: "separatorMode")
        self.separatorMode = SeparatorMode(rawValue: modeValue) ?? .auto
        
        // Register defaults
        defaults.register(defaults: [
            "hideFinder": false,
            "hideTrash": false,
            "hideSeparators": false,
            "separatorMode": SeparatorMode.auto.rawValue
        ])
    }
    
    func synchronize() {
        defaults.synchronize()
        notifyTweak()
    }
    
    private func notifyTweak() {
        let notificationName = "com.aspauldingcode.hider.settingsChanged" as CFString
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                            CFNotificationName(notificationName),
                                            nil,
                                            nil,
                                            true)
    }
}
