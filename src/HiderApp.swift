import SwiftUI

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
            
            VStack(spacing: 20) {
                // Header
                HStack {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text("Hider")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                }
                .padding(.top, 20)
                
                Divider()
                    .background(Color.white.opacity(0.1))
                
                // Settings List
                VStack(alignment: .leading, spacing: 16) {
                    SettingToggle(title: "Hide Finder", icon: "macwindow", isOn: $settings.hideFinder)
                    SettingToggle(title: "Hide Trash", icon: "trash", isOn: $settings.hideTrash)
                    SettingToggle(title: "Hide Dock Separators", icon: "squares.below.rectangle", isOn: $settings.hideSeparators)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .foregroundColor(.secondary)
                            Text("Separator Mode")
                                .font(.headline)
                        }
                        
                        Picker("", selection: $settings.separatorMode) {
                            ForEach(SeparatorMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .padding(.top, 8)
                }
                .padding(.horizontal, 24)
                
                Spacer()
                
                // Save/Sync Button (though it's reactive, useful for manual sync)
                Button(action: {
                    settings.synchronize()
                }) {
                    Text("Refresh Dock")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue.opacity(0.8))
                        )
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .frame(width: 350, height: 450)
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
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}
