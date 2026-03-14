import SwiftUI
import AppKit
import Combine

// MARK: - Popover Frame Background (covers arrow/chevron)

final class PopoverRootView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let frameView = window?.contentView?.superview else { return }
        guard frameView.subviews.contains(where: { $0 is NSVisualEffectView }) == false else { return }
        
        let effectView = NSVisualEffectView(frame: frameView.bounds)
        effectView.autoresizingMask = [.width, .height]
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.material = .underWindowBackground
        frameView.addSubview(effectView, positioned: .below, relativeTo: frameView.subviews.first)
    }
}

final class PopoverContentViewController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        view = PopoverRootView()
        view.translatesAutoresizingMaskIntoConstraints = false
        
        let hosting = NSHostingController(rootView: ContentView())
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - App Delegate (Menubar + Popover)

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var cancellables = Set<AnyCancellable>()

    private static let popoverBaseHeight: CGFloat = 260
    private static let popoverExpandedHeight: CGFloat = 320
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: "Hider")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
        
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 350, height: Self.popoverBaseHeight)
        popover?.behavior = .transient
        popover?.animates = true
        popover?.contentViewController = PopoverContentViewController()

        SettingsManager.shared.$showRestartDockButton
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                guard let self, let popover = self.popover else { return }
                let newHeight = show ? Self.popoverExpandedHeight : Self.popoverBaseHeight
                popover.contentSize = NSSize(width: 350, height: newHeight)
            }
            .store(in: &cancellables)
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

// MARK: - Views

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .underWindowBackground
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var settings = SettingsManager.shared
    
    var body: some View {
        ZStack {
            VisualEffectView()
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Hider")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }
                .padding(.vertical, 16)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Settings List
                VStack(alignment: .leading, spacing: 12) {
                    SettingToggle(title: "Hide Finder", icon: "macwindow", isOn: $settings.hideFinder)
                    SettingToggle(title: "Hide Trash", icon: "trash", isOn: $settings.hideTrash)
                }
                .padding(20)
                
                if settings.showRestartDockButton {
                    Divider()
                        .background(Color.white.opacity(0.1))

                    Button(action: { settings.restartDock() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 15))
                            Text("Restart Dock")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Color.blue.opacity(0.85))
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.top, settings.showRestartDockButton ? 14 : 0)
                
                Button("Quit Hider") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .padding(.bottom, 12)
            }
            .frame(width: 350)
            .animation(.easeInOut(duration: 0.2), value: settings.showRestartDockButton)
        }
    }
}

struct SettingToggle: View {
    let title: String
    let icon: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundColor(.blue)
                .frame(width: 24)
            Text(title)
                .font(.body)
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
        }
    }
}

@main
struct HiderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
