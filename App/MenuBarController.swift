import AppKit
import SwiftUI

/// The menu bar item and its panel. SwiftUI's MenuBarExtra cannot be opened from code,
/// which the global hotkey needs, so this is a little AppKit around the SwiftUI content.
@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let store: PortStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = MenuBarPanel()
    private var sizeObservation: NSKeyValueObservation?
    private var outsideClick: Any?
    private var appSwitch: NSObjectProtocol?
    /// Clicking the menu bar icon while open first closes the panel (it loses key), then
    /// runs toggle(); without this the second step would reopen it.
    private var closedAt = Date.distantPast
    /// The display the panel opens on: under the pointer for a click, the focused one for the hotkey.
    private var targetScreen: NSScreen?

    init(store: PortStore) {
        self.store = store
        super.init()
        statusItem.button?.image = Self.socketIcon
        statusItem.button?.target = self
        statusItem.button?.action = #selector(iconClicked)
        panel.delegate = self
    }

    /// A wall socket: a port in the plain sense. Drawn in code from the same 16 pt shapes as
    /// the design, as a template image so macOS tints it for light, dark and highlighted.
    static let socketIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: true) { _ in
            NSColor.black.set()
            let frame = NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 12, height: 12), xRadius: 3.5, yRadius: 3.5)
            frame.lineWidth = 1.4
            frame.stroke()
            let slots = NSBezierPath()
            slots.move(to: NSPoint(x: 6, y: 5.4)); slots.line(to: NSPoint(x: 6, y: 8.2))
            slots.move(to: NSPoint(x: 10, y: 5.4)); slots.line(to: NSPoint(x: 10, y: 8.2))
            slots.lineWidth = 1.7
            slots.lineCapStyle = .round
            slots.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7, y: 10, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "peekport"
        return image
    }()

    /// With a menu bar on every display, the icon clicked can be on any of them.
    @objc private func iconClicked() {
        toggle(on: NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
    }

    /// The hotkey opens the panel on the display with the focused window, where the user is working.
    func toggle(on screen: NSScreen? = nil) {
        if panel.isVisible {
            panel.close()
        } else if Date.now.timeIntervalSince(closedAt) > 0.3 {
            targetScreen = screen ?? NSScreen.main
            open()
        }
    }

    private func open() {
        // A fresh view per opening, so its onAppear and refresh task start and stop with the panel.
        let host = NSHostingController(rootView:
            ContentView(store: store)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        )
        host.sizingOptions = .preferredContentSize
        panel.contentViewController = host
        sizeObservation = host.observe(\.preferredContentSize, options: [.initial, .new]) { [weak self] host, _ in
            MainActor.assumeIsolated { self?.place(size: host.preferredContentSize) }
        }
        panel.makeKeyAndOrderFront(nil)
        // peekport never becomes the active app, so a click or switch elsewhere does not take
        // key from the panel. Close on both, the way a menu does. Needs no Accessibility permission.
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.close() }
        }
        appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.close() }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        panel.close()
    }

    func windowWillClose(_ notification: Notification) {
        closedAt = .now
        sizeObservation = nil
        panel.contentViewController = nil
        outsideClick.map(NSEvent.removeMonitor)
        appSwitch.map(NSWorkspace.shared.notificationCenter.removeObserver)
        outsideClick = nil
        appSwitch = nil
    }

    /// Top edge just under the menu bar, left edge under the icon, kept on screen. A hidden
    /// icon (behind the notch or a menu bar manager) has no usable position, so the panel
    /// then sits centered, where a hotkey user expects it.
    private func place(size: NSSize) {
        guard size.width > 0, let target = targetScreen ?? NSScreen.main else { return }
        let frame = Self.panelFrame(size: size, icon: statusItem.button?.window?.frame,
                                    screens: NSScreen.screens.map(\.frame), target: (target.frame, target.visibleFrame))
        panel.setFrame(frame, display: true)
    }

    /// Under the icon, on `target`. The icon's own window can sit on another display's menu
    /// bar, but menu bar icons keep the same distance from the right edge on every display,
    /// so that distance carries over. An icon on no display is hidden (notch, menu bar
    /// manager), and the panel then centers.
    // Limit: assumes the same icons on every menu bar; a notch hiding some on the laptop
    // shifts the guess there, by at most the hidden icons' width.
    static func panelFrame(size: NSSize, icon: NSRect?, screens: [NSRect], target: (frame: NSRect, visible: NSRect)) -> NSRect {
        let visible = target.visible
        var x = visible.midX - size.width / 2
        if let icon, let iconScreen = screens.first(where: { $0.intersects(icon) }) {
            x = target.frame.maxX - (iconScreen.maxX - icon.minX)
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSRect(x: x, y: visible.maxY - 6 - size.height, width: size.width, height: size.height)
    }
}

/// Borderless, so it can match the system menu look, and non-activating, so opening it
/// does not pull the user out of the app they are in.
private final class MenuBarPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    /// Escape closes, unless the content used it first (cancelling a stop or clearing the filter).
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
