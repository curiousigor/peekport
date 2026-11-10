import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

/// An AppKit window rather than SwiftUI's Settings scene: peekport is never the active
/// app, and the scene's window then opens behind the user's apps.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let new = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            new.title = "peekport Settings"
            new.styleMask = [.titled, .closable]
            new.isReleasedWhenClosed = false
            new.center()
            window = new
        }
        NSApp.activate()
        // Activation is a request macOS can decline; this still brings the window to the front.
        window?.orderFrontRegardless()
        window?.makeKey()
    }
}

struct SettingsView: View {
    @AppStorage("stopWholeCommand") private var stopWholeCommand = true
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var editor = ProjectApps.editor
    @State private var terminal = ProjectApps.terminal

    var body: some View {
        Form {
            Section("General") {
                LabeledContent("Open peekport") { ShortcutRecorder() }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LaunchAtLogin.set(on)
                        launchAtLogin = LaunchAtLogin.isOn
                    }
            }
            Section("Open projects in") {
                AppPicker(title: "Editor", key: "editorApp", known: ProjectApps.editors, selection: $editor)
                AppPicker(title: "Terminal", key: "terminalApp", known: ProjectApps.terminals, selection: $terminal)
            }
            Section("Stopping") {
                Toggle(isOn: $stopWholeCommand) {
                    Text("Also stop the dev command or compose project")
                    Text("Ticks the checkbox when stopping, so npm run dev or nodemon cannot restart the server.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Installed apps from the known list, plus the current choice if it came from "Other…".
private struct AppPicker: View {
    let title: String
    let key: String
    let known: [String]
    @Binding var selection: ProjectApps.App?

    private static let other = "other"

    var body: some View {
        let apps = ProjectApps.installed(known)
        let options = apps + [selection].compactMap { $0 }.filter { !apps.contains($0) }
        Picker(title, selection: Binding(get: { selection?.bundleID ?? "" }, set: pick)) {
            ForEach(options, id: \.bundleID) { app in
                Label { Text(app.name) } icon: { Image(nsImage: app.icon(size: 16)) }
                    .tag(app.bundleID)
            }
            Divider()
            Text("Other…").tag(Self.other)
        }
    }

    private func pick(_ id: String) {
        if id == Self.other {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            ProjectApps.choose(ProjectApps.App(url: url), for: key)
        } else {
            ProjectApps.choose(ProjectApps.installed([id]).first, for: key)
        }
        selection = key == "editorApp" ? ProjectApps.editor : ProjectApps.terminal
    }
}

/// Click, then press the new shortcut. Escape cancels.
private struct ShortcutRecorder: View {
    @State private var display = GlobalHotKey.display
    @State private var recording = false
    @State private var monitor: Any?
    @State private var taken = false

    var body: some View {
        HStack(spacing: 8) {
            if taken {
                Text("Already in use")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if !recording, display != GlobalHotKey.Shortcut.standard.display {
                Button("Reset") { apply(.standard) }
                    .buttonStyle(.link)
            }
            Button(recording ? "Type a shortcut…" : display) {
                recording ? cancel() : start()
            }
            .frame(minWidth: 110)
        }
        .onDisappear(perform: cancel)
    }

    private func start() {
        taken = false
        recording = true
        // The old shortcut must not open the panel while the new one is typed.
        GlobalHotKey.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                cancel()
            } else if let shortcut = GlobalHotKey.shortcut(from: event) {
                apply(shortcut)
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func apply(_ shortcut: GlobalHotKey.Shortcut) {
        removeMonitor()
        taken = !GlobalHotKey.change(to: shortcut)
        display = GlobalHotKey.display
        recording = false
    }

    private func cancel() {
        removeMonitor()
        recording = false
        GlobalHotKey.resume()
    }

    private func removeMonitor() {
        monitor.map(NSEvent.removeMonitor)
        monitor = nil
    }
}
