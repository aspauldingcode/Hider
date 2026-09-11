import AppKit
import Foundation

public struct InstalledApplication: Hashable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let bundleURL: URL

    public init(bundleID: String, displayName: String, bundleURL: URL) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.bundleURL = bundleURL
    }
}

public enum AppCatalog {
    public static let searchDirectories = [
        "/Applications",
        "/Applications/Utilities",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/System/Library/CoreServices",
    ]

    public static func installedApplications(
        includeRunningApplications: Bool = true
    ) -> [InstalledApplication] {
        var seen = Set<String>()
        var result = [InstalledApplication]()

        for directory in searchDirectories {
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: directory),
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else { continue }

            for url in urls where url.pathExtension.lowercased() == "app" {
                appendApplication(at: url, seen: &seen, result: &result)
            }
        }

        if includeRunningApplications {
            for application in NSWorkspace.shared.runningApplications
            where application.activationPolicy == .regular {
                guard let bundleID = application.bundleIdentifier,
                      let url = application.bundleURL,
                      seen.insert(bundleID.lowercased()).inserted else { continue }
                result.append(InstalledApplication(
                    bundleID: bundleID,
                    displayName: application.localizedName ?? bundleID,
                    bundleURL: url
                ))
            }
        }

        return result.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func appendApplication(
        at url: URL,
        seen: inout Set<String>,
        result: inout [InstalledApplication]
    ) {
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier,
              seen.insert(bundleID.lowercased()).inserted else { return }

        let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        result.append(InstalledApplication(
            bundleID: bundleID,
            displayName: name,
            bundleURL: url
        ))
    }
}
