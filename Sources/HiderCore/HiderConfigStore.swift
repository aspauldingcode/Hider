import Foundation
import NotifyBridge

public final class HiderConfigStore {
    public static let domain = "com.aspauldingcode.hider"
    public static let settingsChangedNotification = "com.aspauldingcode.hider.settingsChanged"
    public static let hiddenAppAddedNotification = "com.aspauldingcode.hider.hiddenAppAdded"
    public static let shared = HiderConfigStore()

    public static var defaultConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Hider/config.json")
    }

    private let defaults: UserDefaults
    private let configURL: URL
    private let notificationPoster: (String) throws -> Void
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public convenience init() {
        // When the app's own bundle identifier equals the domain (the Hider app
        // ships as com.aspauldingcode.hider), UserDefaults(suiteName:) returns
        // nil — its own suite is "nonsensical". In that case .standard already
        // IS that domain, which is exactly what the injected dylib reads.
        let defaults = UserDefaults(suiteName: Self.domain) ?? .standard
        self.init(defaults: defaults, configURL: Self.defaultConfigURL)
    }

    public init(
        defaults: UserDefaults,
        configURL: URL,
        notificationPoster: @escaping (String) throws -> Void = HiderConfigStore.postDarwinNotification
    ) {
        self.defaults = defaults
        self.configURL = configURL
        self.notificationPoster = notificationPoster
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    }

    public func currentConfig() -> HiderConfig {
        HiderConfig(
            hideFinder: defaults.object(forKey: "hideFinder") as? Bool ?? false,
            hideTrash: defaults.object(forKey: "hideTrash") as? Bool ?? false,
            hideSeparators: defaults.object(forKey: "hideSeparators") as? Bool ?? false,
            hideRunningApps: defaults.object(forKey: "hideRunningApps") as? Bool ?? false,
            hiddenApps: defaults.stringArray(forKey: "hiddenApps") ?? []
        )
    }

    public func setFinderHidden(_ hidden: Bool, directNotification: Bool = false) throws {
        var config = currentConfig()
        guard config.hideFinder != hidden else {
            if directNotification {
                post(hidden ? "com.hider.finder.hide" : "com.hider.finder.show")
                postSettingsChanged()
            }
            return
        }
        config.hideFinder = hidden
        try writeLive(config, previous: currentConfig())
        if directNotification {
            post(hidden ? "com.hider.finder.hide" : "com.hider.finder.show")
        }
    }

    public func setTrashHidden(_ hidden: Bool, directNotification: Bool = false) throws {
        var config = currentConfig()
        guard config.hideTrash != hidden else {
            if directNotification {
                post(hidden ? "com.hider.trash.hide" : "com.hider.trash.show")
                postSettingsChanged()
            }
            return
        }
        config.hideTrash = hidden
        try writeLive(config, previous: currentConfig())
        if directNotification {
            post(hidden ? "com.hider.trash.hide" : "com.hider.trash.show")
        }
    }

    public func setSeparatorsHidden(_ hidden: Bool) throws {
        var config = currentConfig()
        guard config.hideSeparators != hidden else { return }
        let previous = config
        config.hideSeparators = hidden
        try writeLive(config, previous: previous)
    }

    public func setRunningAppsHidden(_ hidden: Bool) throws {
        var config = currentConfig()
        guard config.hideRunningApps != hidden else { return }
        let previous = config
        config.hideRunningApps = hidden
        try writeLive(config, previous: previous)
    }

    public func setHiddenApps(_ hiddenApps: [String]) throws {
        var config = currentConfig()
        guard config.hiddenApps != hiddenApps else { return }
        let previous = config
        config.hiddenApps = hiddenApps
        try writeLive(config, previous: previous)
    }

    public func setApp(_ bundleID: String, hidden: Bool) throws {
        let bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else {
            throw HiderStoreError.invalidBundleID
        }

        var apps = currentConfig().hiddenApps
        if hidden {
            guard !contains(bundleID, in: apps) else {
                post(Self.hiddenAppAddedNotification)
                postSettingsChanged()
                return
            }
            apps.append(bundleID)
        } else {
            let filtered = apps.filter { normalize($0) != normalize(bundleID) }
            guard filtered != apps else {
                postSettingsChanged()
                return
            }
            apps = filtered
        }
        try setHiddenApps(apps)
    }

    public func apply(from url: URL? = nil) throws {
        let sourceURL = url ?? configURL
        let data = try Data(contentsOf: sourceURL)
        let config = try decoder.decode(HiderConfig.self, from: data)
        try writeLive(config, previous: currentConfig())
    }

    public func export(to url: URL? = nil) throws {
        try save(currentConfig(), to: url ?? configURL)
    }

    public func load(from url: URL? = nil) throws -> HiderConfig {
        let data = try Data(contentsOf: url ?? configURL)
        return try decoder.decode(HiderConfig.self, from: data)
    }

    public func save(_ config: HiderConfig, to url: URL? = nil) throws {
        let destination = url ?? configURL
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(config).write(to: destination, options: .atomic)
    }

    public func postSettingsChanged() {
        defaults.synchronize()
        post(Self.settingsChangedNotification)
    }

    public func postPrepareRestart() {
        // Drop a marker so the injected dylib's crash-loop guard knows the Dock
        // relaunch that is about to happen is INTENTIONAL (a settings change /
        // toggle), not a crash — even when several relaunches happen in quick
        // succession, faster than the guard's survival window.
        try? Data("1".utf8).write(
            to: URL(fileURLWithPath: "/tmp/hider-intentional-restart"))
        post("com.hider.prepareRestart")
    }

    public func enforceLaunch(bundleID: String) {
        enforceLaunches(bundleIDs: [bundleID])
    }

    public func enforceLaunches(bundleIDs: Set<String>) {
        let config = currentConfig()
        let matchingIDs = bundleIDs.filter { bundleID in
            shouldEnforce(
                bundleID: bundleID,
                hiddenApps: config.hiddenApps,
                hideFinder: config.hideFinder,
                hideTrash: config.hideTrash
            )
        }
        guard !matchingIDs.isEmpty else { return }

        for bundleID in matchingIDs where contains(bundleID, in: config.hiddenApps) {
            post(Self.hiddenAppAddedNotification)
        }
        postSettingsChanged()
    }

    private func writeLive(_ config: HiderConfig, previous: HiderConfig) throws {
        defaults.set(config.hideFinder, forKey: "hideFinder")
        defaults.set(config.hideTrash, forKey: "hideTrash")
        defaults.set(config.hideSeparators, forKey: "hideSeparators")
        defaults.set(config.hideRunningApps, forKey: "hideRunningApps")
        defaults.set(config.hiddenApps, forKey: "hiddenApps")
        defaults.synchronize()

        let previousApps = Set(previous.hiddenApps.map(normalize))
        let addedApps = Set(config.hiddenApps.map(normalize)).subtracting(previousApps)
        for _ in addedApps {
            post(Self.hiddenAppAddedNotification)
        }
        post(Self.settingsChangedNotification)

        try save(config)
    }

    private func post(_ name: String) {
        do {
            try notificationPoster(name)
        } catch {
            NSLog("Hider: failed to post %@: %@", name, error.localizedDescription)
        }
    }

    private func contains(_ bundleID: String, in apps: [String]) -> Bool {
        let bundleID = normalize(bundleID)
        return apps.contains { normalize($0) == bundleID }
    }

    private func normalize(_ bundleID: String) -> String {
        bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func postDarwinNotification(_ name: String) {
        name.withCString { post_notification($0) }
    }
}

public enum HiderStoreError: LocalizedError {
    case invalidBundleID

    public var errorDescription: String? {
        switch self {
        case .invalidBundleID:
            return "Bundle identifier must not be empty."
        }
    }
}
