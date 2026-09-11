import Foundation
import Testing
@testable import HiderCore

@Test func configJSONRoundTrip() throws {
    let config = HiderConfig(
        hideFinder: true,
        hideTrash: false,
        hideSeparators: true,
        hideRunningApps: true,
        hiddenApps: ["com.apple.Safari", "com.example.Editor"]
    )

    let data = try JSONEncoder().encode(config)
    #expect(try JSONDecoder().decode(HiderConfig.self, from: data) == config)
}

@Test func olderConfigDefaultsToVisibleSeparators() throws {
    let data = Data(
        #"{"hideFinder":true,"hideTrash":false,"hiddenApps":[]}"#.utf8
    )

    let config = try JSONDecoder().decode(HiderConfig.self, from: data)

    #expect(!config.hideSeparators)
    #expect(!config.hideRunningApps)
}

@Test func defaultsAndConfigMapping() throws {
    let suiteName = "com.aspauldingcode.hider.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configURL = directory.appendingPathComponent("config.json")
    var notifications = [String]()
    let store = HiderConfigStore(
        defaults: defaults,
        configURL: configURL,
        notificationPoster: { notifications.append($0) }
    )
    let expected = HiderConfig(
        hideFinder: true,
        hideTrash: true,
        hideSeparators: true,
        hideRunningApps: true,
        hiddenApps: ["com.apple.Safari"]
    )

    try store.save(expected)
    try store.apply()

    #expect(store.currentConfig() == expected)
    #expect(defaults.bool(forKey: "hideFinder"))
    #expect(defaults.bool(forKey: "hideTrash"))
    #expect(defaults.bool(forKey: "hideSeparators"))
    #expect(defaults.bool(forKey: "hideRunningApps"))
    #expect(defaults.stringArray(forKey: "hiddenApps") == expected.hiddenApps)
    #expect(try store.load() == expected)
    #expect(notifications == [
        HiderConfigStore.hiddenAppAddedNotification,
        HiderConfigStore.settingsChangedNotification,
    ])
}

@Test func separatorSettingWritesPreferenceAndPostsSettingsChanged() throws {
    let suiteName = "com.aspauldingcode.hider.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
    var notifications = [String]()
    let store = HiderConfigStore(
        defaults: defaults,
        configURL: configURL,
        notificationPoster: { notifications.append($0) }
    )

    try store.setSeparatorsHidden(true)

    #expect(defaults.bool(forKey: "hideSeparators"))
    #expect(store.currentConfig().hideSeparators)
    #expect(notifications == [HiderConfigStore.settingsChangedNotification])
}

@Test func runningAppsSettingWritesPreferenceAndPostsSettingsChanged() throws {
    let suiteName = "com.aspauldingcode.hider.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let configURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("config.json")
    defer { try? FileManager.default.removeItem(at: configURL.deletingLastPathComponent()) }
    var notifications = [String]()
    let store = HiderConfigStore(
        defaults: defaults,
        configURL: configURL,
        notificationPoster: { notifications.append($0) }
    )

    try store.setRunningAppsHidden(true)

    #expect(defaults.bool(forKey: "hideRunningApps"))
    #expect(store.currentConfig().hideRunningApps)
    #expect(notifications == [HiderConfigStore.settingsChangedNotification])
}

@Test func shouldEnforceHiddenAppAndSystemPreferences() {
    #expect(shouldEnforce(
        bundleID: "COM.APPLE.SAFARI",
        hiddenApps: ["com.apple.Safari"],
        hideFinder: false,
        hideTrash: false
    ))
    #expect(shouldEnforce(
        bundleID: "com.example.AnyApp",
        hiddenApps: [],
        hideFinder: true,
        hideTrash: false
    ))
    #expect(shouldEnforce(
        bundleID: "com.example.AnyApp",
        hiddenApps: [],
        hideFinder: false,
        hideTrash: true
    ))
    #expect(!shouldEnforce(
        bundleID: "com.example.Visible",
        hiddenApps: ["com.example.Hidden"],
        hideFinder: false,
        hideTrash: false
    ))
}
