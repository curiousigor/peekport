import AppKit
import UniformTypeIdentifiers

/// The editor and terminal a project folder opens in. Opening goes through NSWorkspace,
/// so there is no scripting, no Automation permission prompt and no shelling out.
enum ProjectApps {
    struct App: Hashable {
        let url: URL
        var bundleID: String { Bundle(url: url)?.bundleIdentifier ?? url.path }
        var name: String { FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "") }
        func icon(size: CGFloat = 32) -> NSImage {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: size, height: size)
            return icon
        }
    }

    /// Bundle IDs in order of preference.
    static let editors = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.exafunction.windsurf",
                          "com.sublimetext.4", "com.panic.Nova", "com.jetbrains.WebStorm", "com.jetbrains.intellij"]
    static let terminals = ["dev.warp.Warp-Stable", "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal"]

    /// The user's choice from Settings while it is installed, else the automatic pick.
    static var editor: App? { chosen("editorApp") ?? automaticEditor }
    static var terminal: App? { chosen("terminalApp") ?? automaticTerminal }

    /// The default app for source files when it is a known editor (it is often Xcode,
    /// which suits a Swift package but not a web project), else the first one installed.
    static let automaticEditor: App? = {
        if let url = NSWorkspace.shared.urlForApplication(toOpen: .sourceCode),
           let id = Bundle(url: url)?.bundleIdentifier, editors.contains(id) {
            return App(url: url)
        }
        return firstInstalled(editors)
    }()

    /// A third-party terminal someone installed is the one they use; Terminal otherwise.
    static let automaticTerminal: App? = firstInstalled(terminals)

    /// Saves the choice; nil goes back to the automatic pick.
    static func choose(_ app: App?, for key: String) {
        UserDefaults.standard.set(app?.bundleID, forKey: key)
    }

    static func installed(_ ids: [String]) -> [App] {
        ids.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.map(App.init)
    }

    private static func chosen(_ key: String) -> App? {
        UserDefaults.standard.string(forKey: key)
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map(App.init)
    }

    static func open(_ folder: URL, in app: App) {
        NSWorkspace.shared.open([folder], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func firstInstalled(_ ids: [String]) -> App? {
        ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first.map(App.init)
    }
}
