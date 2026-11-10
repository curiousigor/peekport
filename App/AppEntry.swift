import SwiftUI

/// Fixed name on purpose: a project name can contain spaces and punctuation, which
/// would not be a valid Swift identifier. The name users see comes from the bundle.
@main
struct AppEntry: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    /// The menu bar item lives in MenuBarController; a SwiftUI app still needs one scene.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The store lives as long as the app, so the last scan is on screen the instant the panel opens.
        let controller = MenuBarController(store: PortStore())
        menuBar = controller
        GlobalHotKey.register { controller.toggle() }
    }
}
