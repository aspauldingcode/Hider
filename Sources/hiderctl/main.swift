import AppKit
import Foundation
import HiderCore

enum CLIError: LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message): message
        }
    }
}

struct HiderCLI {
    let store = HiderConfigStore.shared

    func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw CLIError.invalidArguments(usage)
        }
        let operands = Array(arguments.dropFirst())

        switch command {
        case "status":
            try requireCount(operands, maximum: 0)
            printStatus()
        case "list":
            try requireCount(operands, maximum: 0)
            printList()
        case "hide", "show":
            guard operands.count == 1 else {
                throw CLIError.invalidArguments("\(command) requires one bundle ID, finder, or trash.\n\n\(usage)")
            }
            try set(operands[0], hidden: command == "hide")
        case "apply":
            try requireCount(operands, maximum: 1)
            let url = operands.first.map(resolvePath)
            try store.apply(from: url)
            print("Applied \((url ?? HiderConfigStore.defaultConfigURL).path)")
        case "export":
            try requireCount(operands, maximum: 1)
            let url = operands.first.map(resolvePath)
            try store.export(to: url)
            print("Exported \((url ?? HiderConfigStore.defaultConfigURL).path)")
        case "watch":
            try requireCount(operands, maximum: 0)
            watch()
        case "help", "--help", "-h":
            print(usage)
        default:
            throw CLIError.invalidArguments("Unknown command: \(command)\n\n\(usage)")
        }
    }

    private func printStatus() {
        let config = store.currentConfig()
        let fileManager = FileManager.default
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let ppRoot = "/opt/pluginplayground"
        let ppDylib = "\(ppRoot)/tweaks/libHider.dylib"
        let ppOptions = "\(ppRoot)/tweaks/libHider.dylib.options"

        print("Finder: \(config.hideFinder ? "hidden" : "shown")")
        print("Trash: \(config.hideTrash ? "hidden" : "shown")")
        print("Separators: \(config.hideSeparators ? "hidden" : "shown")")
        print("Running-app hiding: \(config.hideRunningApps ? "on" : "off")")
        print("Hidden apps:")
        if config.hiddenApps.isEmpty {
            print("  (none)")
        } else {
            config.hiddenApps.forEach { print("  \($0)") }
        }
        print("macOS: \(major) (requires Sequoia 15+)")
        print("Plugin Playground: \(yesNo(fileManager.fileExists(atPath: ppRoot)))")
        print("Hider tweak: \(yesNo(fileManager.fileExists(atPath: ppDylib))) (\(ppDylib))")
        print("Hider options: \(yesNo(fileManager.fileExists(atPath: ppOptions)))")
        print("Live Dock hiding needs SIP off and Plugin Playground.")
    }

    private func printList() {
        let config = store.currentConfig()
        print("\(config.hideFinder ? "*" : " ") finder\tFinder")
        print("\(config.hideTrash ? "*" : " ") trash\tTrash")
        for app in AppCatalog.installedApplications() {
            let hidden = config.hiddenApps.contains {
                $0.caseInsensitiveCompare(app.bundleID) == .orderedSame
            }
            print("\(hidden ? "*" : " ") \(app.bundleID)\t\(app.displayName)")
        }
    }

    private func set(_ value: String, hidden: Bool) throws {
        var isApp = false
        var isBuiltin = false
        switch value.lowercased() {
        case "finder":
            try store.setFinderHidden(hidden, directNotification: true)
            isBuiltin = true
        case "trash":
            try store.setTrashHidden(hidden, directNotification: true)
            isBuiltin = true
        default:
            try store.setApp(value, hidden: hidden)
            isApp = true
        }
        print("\(hidden ? "Hidden" : "Shown") \(value)")

        // When to rebuild the Dock (which the injected dylib does its work on):
        //  - a running-app change while running-app hiding is on (prevention only
        //    applies on rebuild), and
        //  - ANY built-in (Finder/Trash) change: hiding live leaves the running-dot
        //    orphaned and showing can't recreate the removed tile, so a rebuild is
        //    the only clean result (matches the app's auto-apply).
        // HIDER_NO_RESTART=1 suppresses (used by test harnesses).
        let running = isApp && store.currentConfig().hideRunningApps
        if (running || isBuiltin),
           ProcessInfo.processInfo.environment["HIDER_NO_RESTART"] == nil {
            relaunchDock()
        }
    }

    private func relaunchDock() {
        store.postPrepareRestart()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        do {
            try task.run()
            task.waitUntilExit()
            print("Relaunched Dock to apply running-app hiding.")
        } catch {
            FileHandle.standardError.write(
                Data("hiderctl: could not relaunch Dock: \(error.localizedDescription)\n".utf8))
        }
    }

    private func watch() {
        let watcher = LaunchWatcher(store: store)
        watcher.start()
        print("Watching application launches. Press Control-C to stop.")
        withExtendedLifetime(watcher) {
            RunLoop.main.run()
        }
    }

    private func requireCount(_ operands: [String], maximum: Int) throws {
        guard operands.count <= maximum else {
            throw CLIError.invalidArguments(usage)
        }
    }

    private func resolvePath(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    private var usage: String {
        """
        Usage: hiderctl <command> [arguments]

          status                         Show current settings and installation status
          list                           List installed apps; * means hidden
          hide <bundleID|finder|trash>   Hide one Dock item
          show <bundleID|finder|trash>   Show one Dock item
          apply [path]                   Apply JSON config to the live defaults domain
          export [path]                  Export live defaults to JSON config
          watch                          Re-enforce settings when applications launch
        """
    }
}

do {
    try HiderCLI().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("hiderctl: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
