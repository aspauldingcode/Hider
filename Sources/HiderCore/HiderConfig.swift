import Foundation

public struct HiderConfig: Codable, Equatable, Sendable {
    public var hideFinder: Bool
    public var hideTrash: Bool
    public var hideSeparators: Bool
    public var hideRunningApps: Bool
    public var hiddenApps: [String]

    public init(
        hideFinder: Bool = false,
        hideTrash: Bool = false,
        hideSeparators: Bool = false,
        hideRunningApps: Bool = false,
        hiddenApps: [String] = []
    ) {
        self.hideFinder = hideFinder
        self.hideTrash = hideTrash
        self.hideSeparators = hideSeparators
        self.hideRunningApps = hideRunningApps
        self.hiddenApps = hiddenApps
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideFinder = try container.decode(Bool.self, forKey: .hideFinder)
        hideTrash = try container.decode(Bool.self, forKey: .hideTrash)
        hideSeparators = try container.decodeIfPresent(Bool.self, forKey: .hideSeparators) ?? false
        hideRunningApps = try container.decodeIfPresent(Bool.self, forKey: .hideRunningApps) ?? false
        hiddenApps = try container.decode([String].self, forKey: .hiddenApps)
    }
}

public func shouldEnforce(
    bundleID: String,
    hiddenApps: [String],
    hideFinder: Bool,
    hideTrash: Bool
) -> Bool {
    let normalizedID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return hideFinder
        || hideTrash
        || hiddenApps.contains { appID in
            appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedID
        }
}
