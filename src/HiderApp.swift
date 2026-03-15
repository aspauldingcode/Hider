import SwiftUI
import AppKit
import Combine

// MARK: - PopoverRootView
// Extends the visual-effect background into the NSPopover arrow/chevron region
// by making the private _NSPopoverFrame window non-opaque so the VEV composites
// through the arrow drawing path. Using .popover material matches AppKit's own
// arrow rendering, giving a seamless frosted-glass chevron.

final class PopoverRootView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window,
              let frameView = window.contentView?.superview else { return }

        // Remove any VEVs we previously inserted (prevent duplicates on recycle).
        for sub in frameView.subviews where sub is NSVisualEffectView {
            sub.removeFromSuperview()
        }

        // Making the window non-opaque allows the VEV to render through the
        // arrow region that AppKit draws inside the private _NSPopoverFrame.
        window.isOpaque = false
        window.backgroundColor = .clear
        frameView.wantsLayer = true
        frameView.layer?.backgroundColor = NSColor.clear.cgColor

        let vev = NSVisualEffectView(frame: frameView.bounds)
        vev.autoresizingMask = [.width, .height]
        vev.blendingMode    = .behindWindow
        vev.state           = .active
        vev.material        = .popover
        frameView.addSubview(vev, positioned: .below, relativeTo: frameView.subviews.first)
    }
}

// MARK: - PopoverContentViewController

final class PopoverContentViewController: NSViewController {
    private var sizeObservation: NSKeyValueObservation?

    init(popover: NSPopover) {
        super.init(nibName: nil, bundle: nil)
        view = PopoverRootView()
        view.translatesAutoresizingMaskIntoConstraints = false

        let host = NSHostingController(rootView: ContentView())
        if #available(macOS 13.0, *) {
            host.sizingOptions = .preferredContentSize
        }
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Propagate SwiftUI's ideal height to the popover whenever it changes.
        sizeObservation = host.observe(\.preferredContentSize, options: [.new]) { [weak popover] host, _ in
            let s = host.preferredContentSize
            guard s.height > 60 else { return }
            DispatchQueue.main.async {
                popover?.contentSize = NSSize(width: 350, height: s.height)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { sizeObservation?.invalidate() }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: "Hider")
            btn.image?.isTemplate = true
            btn.action = #selector(togglePopover)
            btn.target  = self
        }

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 350, height: 320)
        pop.behavior    = .transient
        pop.animates    = true
        if #available(macOS 14.0, *) {
            pop.hasFullSizeContent = true
        }
        pop.contentViewController = PopoverContentViewController(popover: pop)
        popover = pop
    }

    @objc private func togglePopover() {
        guard let btn = statusItem?.button, let pop = popover else { return }
        if pop.isShown { pop.performClose(nil) }
        else           { pop.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY) }
    }
}

// MARK: - AppInfo

struct AppInfo: Identifiable, Hashable {
    let id:   String   // bundle identifier
    let name: String
    let icon: NSImage

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: AppInfo, r: AppInfo) -> Bool { l.id == r.id }
}

// MARK: - AppListLoader

final class AppListLoader: ObservableObject {
    @Published private(set) var apps:      [AppInfo] = []
    @Published private(set) var isLoading: Bool      = false
    private var loaded = false

    func load() {
        guard !loaded, !isLoading else { return }
        isLoading = true
        loaded    = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var seen   = Set<String>()
            var result = [AppInfo]()

            let dirs = [
                "/Applications",
                "/Applications/Utilities",
                "/System/Applications",
                "/System/Applications/Utilities",
                "/System/Library/CoreServices",
            ]

            for dir in dirs {
                guard let urls = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ) else { continue }

                for url in urls where url.pathExtension == "app" {
                    guard let bundle = Bundle(url: url),
                          let bid   = bundle.bundleIdentifier,
                          !seen.contains(bid) else { continue }
                    seen.insert(bid)

                    let name = bundle.infoDictionary?["CFBundleDisplayName"] as? String
                        ?? bundle.infoDictionary?["CFBundleName"] as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    let icon = NSWorkspace.shared.icon(forFile: url.path)
                    result.append(AppInfo(id: bid, name: name, icon: icon))
                }
            }

            // Include running regular apps not found in the standard directories.
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular {
                guard let bid = app.bundleIdentifier,
                      !seen.contains(bid),
                      let url = app.bundleURL else { continue }
                seen.insert(bid)
                let name = app.localizedName ?? bid
                let icon = app.icon ?? NSWorkspace.shared.icon(forFile: url.path)
                result.append(AppInfo(id: bid, name: name, icon: icon))
            }

            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self.apps      = result
                self.isLoading = false
            }
        }
    }
}

// MARK: - VisualEffectView (SwiftUI wrapper)

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.blendingMode = .behindWindow
        v.state        = .active
        v.material     = .underWindowBackground
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var settings  = SettingsManager.shared
    @StateObject private var appLoader = AppListLoader()

    var body: some View {
        ZStack {
            VisualEffectView().ignoresSafeArea()

            if settings.showAppPicker {
                AppPickerView(appLoader: appLoader)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .frame(width: 350)
        .animation(.easeInOut(duration: 0.22), value: settings.showAppPicker)
    }

    // MARK: Main content (settings + hidden-apps list)
    private var mainContent: some View {
        VStack(spacing: 0) {

            // ── Header ───────────────────────────────────────────────────────
            VStack(spacing: 3) {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.linearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    Text("Hider")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }
                Text("Manage what appears in your Dock.")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            // ── System toggles ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                SettingToggle(title: "Hide Finder", icon: "macwindow", isOn: $settings.hideFinder)
                SettingToggle(title: "Hide Trash",  icon: "trash",     isOn: $settings.hideTrash)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            // ── Custom hidden apps section ─────────────────────────────────────
            HiddenAppsSection(appLoader: appLoader)

            // ── Restart Dock button (shown when a tile-removal restart is needed) ──
            if settings.showRestartDockButton {
                Divider()
                Button(action: { settings.restartDock() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 13))
                        Text("Restart Dock")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Divider()

            // ── Quit ──────────────────────────────────────────────────────────
            Button("Quit Hider") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .font(.system(size: 12))
                .padding(.vertical, 8)
        }
        .animation(.easeInOut(duration: 0.2), value: settings.showRestartDockButton)
    }
}

// MARK: - SettingToggle

struct SettingToggle: View {
    let title: String
    let icon:  String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.blue)
                .frame(width: 22)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - HiddenAppsSection

struct HiddenAppsSection: View {
    @ObservedObject private var settings = SettingsManager.shared
    let appLoader: AppListLoader

    var body: some View {
        VStack(spacing: 0) {

            // Section header row
            HStack(spacing: 5) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("HIDDEN APPS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    appLoader.load()
                    withAnimation { settings.showAppPicker = true }
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 5)

            if settings.hiddenApps.isEmpty {
                HStack {
                    Text("No hidden apps")
                        .font(.system(size: 12))
                        .foregroundColor(Color.secondary.opacity(0.65))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(settings.hiddenApps, id: \.self) { bid in
                        HiddenAppRow(bundleID: bid)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - HiddenAppRow

struct HiddenAppRow: View {
    let bundleID: String
    @ObservedObject private var settings = SettingsManager.shared
    @State private var appName: String   = ""
    @State private var appIcon: NSImage? = nil

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 22, height: 22)

            Text(appName.isEmpty ? shortID : appName)
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()

            Button(action: { settings.removeHiddenApp(bundleID) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .onAppear { loadInfo() }
    }

    private var shortID: String {
        bundleID.components(separatedBy: ".").last?.capitalized ?? bundleID
    }

    private func loadInfo() {
        guard appName.isEmpty else { return }
        let bid = bundleID
        DispatchQueue.global(qos: .userInitiated).async {
            var name: String
            let icon: NSImage?
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                let bundle = Bundle(url: url)
                name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? bundle?.infoDictionary?["CFBundleName"] as? String
                    ?? url.deletingPathExtension().lastPathComponent
                icon = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                name = bid.components(separatedBy: ".").last?.capitalized ?? bid
                icon = nil
            }
            DispatchQueue.main.async {
                self.appName = name
                self.appIcon = icon
            }
        }
    }
}

// MARK: - AppPickerView
// Spotlight-style picker: search field + scrollable app list with icons.

struct AppPickerView: View {
    @ObservedObject var appLoader: AppListLoader
    @ObservedObject private var settings = SettingsManager.shared
    @State private var searchText = ""

    private var filteredApps: [AppInfo] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return appLoader.apps.filter { app in
            app.id != "com.apple.finder" &&
            app.id != "com.apple.trash"  &&
            !settings.hiddenApps.contains(app.id) &&
            (q.isEmpty || app.name.lowercased().contains(q))
        }
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── Picker header ─────────────────────────────────────────────────
            HStack {
                Text("Choose App to Hide")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") {
                    withAnimation { settings.showAppPicker = false }
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // ── Search field ──────────────────────────────────────────────────
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 12))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            // ── App list ──────────────────────────────────────────────────────
            Group {
                if appLoader.isLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading apps…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)

                } else if filteredApps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundColor(.secondary)
                        Text(searchText.isEmpty ? "All apps already hidden" : "No results")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)

                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredApps) { app in
                                AppPickerRow(app: app)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 220)
                }
            }
        }
        .frame(width: 350)
    }
}

// MARK: - AppPickerRow

struct AppPickerRow: View {
    let app: AppInfo
    @ObservedObject private var settings = SettingsManager.shared
    @State private var isHovered = false

    var body: some View {
        Button {
            settings.addHiddenApp(app.id)
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 28, height: 28)
                    .cornerRadius(5)

                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "plus.circle")
                    .font(.system(size: 14))
                    .foregroundColor(.blue.opacity(isHovered ? 1.0 : 0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.primary.opacity(0.07) : Color.clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - HiderApp Entry Point

@main
struct HiderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
