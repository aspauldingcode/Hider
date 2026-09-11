import AppKit
import Combine
import Darwin
import HiderCore

/// Classic menubar applet: `NSStatusItem` + `NSMenu` (not NSPopover).
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let settings = SettingsManager.shared
    private let launchWatcher = LaunchWatcher()
    private var menu: NSMenu?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        launchWatcher.start()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "eye.slash.fill",
                accessibilityDescription: "Hider"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.menu = menu
        self.statusItem = item

        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu else { return }
        menu.removeAllItems()

        menu.addItem(header("Dock Items"))
        menu.addItem(toggle(
            "Hide Finder",
            isOn: settings.hideFinder,
            action: #selector(toggleFinder)
        ))
        menu.addItem(toggle(
            "Hide Trash",
            isOn: settings.hideTrash,
            action: #selector(toggleTrash)
        ))
        menu.addItem(toggle(
            "Hide Separators",
            isOn: settings.hideSeparators,
            action: #selector(toggleSeparators)
        ))
        menu.addItem(toggle(
            "Hide Running Apps",
            isOn: settings.hideRunningApps,
            action: #selector(toggleRunningApps)
        ))

        menu.addItem(.separator())
        menu.addItem(header("Hidden Apps"))

        if settings.hiddenApps.isEmpty {
            let empty = NSMenuItem(title: "None — pick from Running…", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for bid in settings.hiddenApps.sorted() {
                let title = displayName(for: bid)
                let item = NSMenuItem(
                    title: "Show \(title)",
                    action: #selector(unhideApp(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = bid
                item.target = self
                item.image = icon(for: bid)
                item.image?.size = NSSize(width: 16, height: 16)
                menu.addItem(item)
            }
        }

        let running = NSMenuItem(title: "Hide Running App", action: nil, keyEquivalent: "")
        let runningMenu = NSMenu()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bid = app.bundleIdentifier else { return nil }
                if bid == "com.apple.finder" || bid == Bundle.main.bundleIdentifier { return nil }
                let name = app.localizedName ?? bid
                return (bid, name, app.icon)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        if apps.isEmpty {
            let none = NSMenuItem(title: "No regular apps running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            runningMenu.addItem(none)
        } else {
            for (bid, name, image) in apps {
                let hidden = settings.hiddenApps.contains {
                    $0.caseInsensitiveCompare(bid) == .orderedSame
                }
                let item = NSMenuItem(
                    title: name,
                    action: #selector(toggleRunningApp(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = bid
                item.target = self
                item.state = hidden ? .on : .off
                item.image = image
                item.image?.size = NSSize(width: 16, height: 16)
                runningMenu.addItem(item)
            }
        }
        running.submenu = runningMenu
        menu.addItem(running)

        menu.addItem(.separator())
        let restart = NSMenuItem(
            title: "Restart Dock",
            action: #selector(restartDock),
            keyEquivalent: "r"
        )
        restart.target = self
        menu.addItem(restart)

        let configItem = NSMenuItem(
            title: "Open Config…",
            action: #selector(openConfig),
            keyEquivalent: ""
        )
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit Hider",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
    }

    // MARK: - Actions

    @objc private func toggleFinder() {
        settings.hideFinder.toggle()
    }

    @objc private func toggleTrash() {
        settings.hideTrash.toggle()
    }

    @objc private func toggleSeparators() {
        settings.hideSeparators.toggle()
    }

    @objc private func toggleRunningApps() {
        settings.hideRunningApps.toggle()
    }

    @objc private func unhideApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        settings.removeHiddenApp(bid)
    }

    @objc private func toggleRunningApp(_ sender: NSMenuItem) {
        guard let bid = sender.representedObject as? String else { return }
        if settings.hiddenApps.contains(where: { $0.caseInsensitiveCompare(bid) == .orderedSame }) {
            settings.removeHiddenApp(bid)
        } else {
            settings.addHiddenApp(bid)
        }
    }

    @objc private func restartDock() {
        settings.restartDock()
    }

    @objc private func openConfig() {
        let url = HiderConfigStore.defaultConfigURL
        try? settings.exportConfig()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Helpers

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func toggle(_ title: String, isOn: Bool, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        return item
    }

    private func displayName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let name = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String {
            return name
        }
        return bundleID
    }

    private func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

@main
enum HiderMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
