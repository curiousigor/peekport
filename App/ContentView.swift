import ServiceManagement
import SwiftUI

enum PortSort: String {
    case port, uptime
}

/// Rows sharing a project folder. `folder` is nil for the "Other" group.
struct PortGroup: Identifiable {
    let folder: URL?
    let rows: [ListeningPort]
    var id: String { folder?.path ?? "" }
}

/// Groups rows by project, keeping the incoming order: groups appear in the order of
/// their first row, and rows without a project come last as one group.
func groupByProject(_ rows: [ListeningPort]) -> [PortGroup] {
    let buckets = Dictionary(grouping: rows, by: \.projectFolder)
    var seen = Set<URL?>()
    let folders = rows.map(\.projectFolder).filter { $0 != nil && seen.insert($0).inserted }
    return (folders + (buckets[nil] == nil ? [] : [nil])).map { PortGroup(folder: $0, rows: buckets[$0]!) }
}

private extension ListeningPort {
    var url: URL { URL(string: "http://localhost:\(port)")! }
}

private enum StopStep { case confirm, stopping, force }
private enum StopAction { case ask, cancel, confirm, force, toggleMore }

/// A stop in progress. `job` is the dev command found when the stop was asked for;
/// `siblings` the other containers of a compose project. One checkbox covers either.
private struct StopState {
    var step: StopStep
    let job: DevCommand?
    let siblings: [String]
    var includeMore = true
    var chosenJob: DevCommand? { includeMore ? job : nil }
    var chosenSiblings: [String] { includeMore ? siblings : [] }
}

private let uptimeFormatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .abbreviated
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    return formatter
}()

/// Orange that keeps 4.5:1 text contrast in both appearances; systemOrange does not on light.
private let staleColor = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        ? NSColor(srgbRed: 1, green: 0.70, blue: 0.36, alpha: 1)
        : NSColor(srgbRed: 0.70, green: 0.31, blue: 0, alpha: 1)
})

struct ContentView: View {
    let store: PortStore

    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("sort") private var sort = PortSort.port
    /// "Other" is mostly apps (AirPlay, Raycast, Figma), so it starts collapsed.
    @AppStorage("otherCollapsed") private var otherCollapsed = true
    /// Nil means the first visible row, so a fresh popover or a new filter starts at the top.
    @State private var selection: ListeningPort.ID?
    @State private var stops: [ListeningPort.ID: StopState] = [:]
    @State private var copiedID: ListeningPort.ID?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    /// Scans arrive sorted by port. Uptime puts the longest-running first, which is
    /// where forgotten servers end up.
    private var visiblePorts: [ListeningPort] {
        let filtered = trimmedQuery.isEmpty ? store.ports : store.ports.filter { $0.matches(trimmedQuery) }
        return sort == .uptime ? filtered.sorted { $0.startTime < $1.startTime } : filtered
    }

    private var visibleDownPorts: [Int] {
        store.downWatchedPorts.filter { trimmedQuery.isEmpty || String($0).contains(trimmedQuery) }
    }

    var body: some View {
        let groups = groupByProject(visiblePorts)
        // Keyboard selection skips collapsed rows, like a collapsed outline in Finder.
        let rows = groups.flatMap { isCollapsed($0) ? [] : $0.rows }
        let selected = rows.first { $0.id == selection } ?? rows.first
        VStack(spacing: 0) {
            header(rows: rows, selected: selected)
            Divider()
            if groups.isEmpty, visibleDownPorts.isEmpty {
                Text(store.ports.isEmpty ? "No listening ports" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                if group.folder == nil, trimmedQuery.isEmpty {
                                    OtherHeader(count: group.rows.count, collapsed: $otherCollapsed)
                                } else {
                                    GroupHeader(folder: group.folder, ports: group.rows)
                                }
                                ForEach(isCollapsed(group) ? [] : group.rows) { port in
                                    PortRow(
                                        port: port,
                                        store: store,
                                        selected: port.id == selected?.id,
                                        copied: port.id == copiedID,
                                        stop: stops[port.id],
                                        onSelect: { selection = port.id },
                                        onCopy: { copy(port) },
                                        onStop: { stop(port, $0) }
                                    )
                                }
                            }
                            if !visibleDownPorts.isEmpty {
                                GroupHeader(folder: nil, title: "Not listening")
                                ForEach(visibleDownPorts, id: \.self) { DownRow(port: $0, store: store) }
                            }
                        }
                        .padding(.top, 2)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: selection) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            footer
        }
        .frame(width: 380)
        .onChange(of: query) { selection = nil }
        // Each opening starts with an empty filter that already has focus, so typing filters.
        .onAppear {
            query = ""
            selection = nil
            searchFocused = true
        }
        // Runs only while the popover is open, so a closed menu costs nothing.
        .task {
            store.popoverOpen = true
            defer { store.popoverOpen = false }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// A filter always shows "Other", so a match is never hidden.
    private func isCollapsed(_ group: PortGroup) -> Bool {
        group.folder == nil && otherCollapsed && trimmedQuery.isEmpty
    }

    private func header(rows: [ListeningPort], selected: ListeningPort?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter ports, processes, projects", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onKeyPress(phases: [.down, .repeat]) { handleKey($0, rows: rows, selected: selected) }
                KeyCap(GlobalHotKey.display)
                    .help("Open peekport from anywhere")
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
            Menu {
                Picker("Sort by", selection: $sort) {
                    Text("Port").tag(PortSort.port)
                    Text("Uptime").tag(PortSort.uptime)
                }
                .pickerStyle(.inline)
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort by \(sort == .port ? "port" : "uptime")")
        }
        .padding(10)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            KeyHint(keys: ["↑", "↓"], label: "select")
            KeyHint(keys: ["↩"], label: "open")
            KeyHint(keys: ["⌘C"], label: "copy")
            KeyHint(keys: ["⌘⌫"], label: "stop")
            Spacer()
            Menu {
                Toggle("Launch at login", isOn: LaunchAtLogin.binding)
                Button("Settings…") { SettingsWindow.show() }
                    .keyboardShortcut(",")
                Divider()
                Link("Support peekport…", destination: URL(string: "https://familiasi.gumroad.com/l/peekport")!)
                Button("About peekport") {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
                Divider()
                Button("Quit peekport") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
    }

    /// Keys go to the filter field, which keeps focus, so typing always filters while the
    /// arrows, Return and the shortcuts act on the selected row.
    private func handleKey(_ press: KeyPress, rows: [ListeningPort], selected: ListeningPort?) -> KeyPress.Result {
        guard let selected, let index = rows.firstIndex(of: selected) else { return .ignored }
        let step = stops[selected.id]?.step
        switch press.key {
        case .downArrow:
            selection = rows[min(index + 1, rows.count - 1)].id
        case .upArrow:
            selection = rows[max(index - 1, 0)].id
        case .return:
            switch step {
            case .confirm: stop(selected, .confirm)
            case .force: stop(selected, .force)
            case .stopping: break
            case nil: NSWorkspace.shared.open(selected.url)
            }
        case .escape:
            if step == .confirm || step == .force {
                stop(selected, .cancel)
            } else if !query.isEmpty {
                query = ""
            } else {
                return .ignored
            }
        // The Delete key sends DEL (U+7F); SwiftUI's .delete is backspace (U+08) and never matches.
        case KeyEquivalent("\u{7F}") where press.modifiers == .command, .delete where press.modifiers == .command:
            if step == nil, selected.canStop { stop(selected, .ask) }
        case "c" where press.modifiers == .command:
            copy(selected)
        case "," where press.modifiers == .command:
            SettingsWindow.show()
        case "o" where press.modifiers == .command:
            guard let folder = selected.projectFolder, let editor = ProjectApps.editor else { return .ignored }
            ProjectApps.open(folder, in: editor)
        case "t" where press.modifiers == .command:
            guard let folder = selected.projectFolder, let terminal = ProjectApps.terminal else { return .ignored }
            ProjectApps.open(folder, in: terminal)
        default:
            return .ignored
        }
        return .handled
    }

    private func copy(_ port: ListeningPort) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(port.url.absoluteString, forType: .string)
        copiedID = port.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == port.id { copiedID = nil }
        }
    }

    private func stop(_ port: ListeningPort, _ action: StopAction) {
        let job = stops[port.id]?.chosenJob
        let siblings = stops[port.id]?.chosenSiblings ?? []
        switch action {
        case .ask:
            stops[port.id] = StopState(step: .confirm, job: PortScanner.devCommand(of: port), siblings: port.container?.siblings ?? [],
                                       includeMore: UserDefaults.standard.object(forKey: "stopWholeCommand") as? Bool ?? true)
        case .cancel:
            stops[port.id] = nil
        case .toggleMore:
            stops[port.id]?.includeMore.toggle()
        case .confirm:
            stops[port.id]?.step = .stopping
            Task {
                if await store.terminate(port, job: job, siblings: siblings) { stops[port.id] = nil } else { stops[port.id]?.step = .force }
            }
        case .force:
            stops[port.id]?.step = .stopping
            Task {
                await store.forceKill(port, job: job)
                stops[port.id] = nil
            }
        }
    }
}

private struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
    }
}

private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { KeyCap($0) }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(keys.joined(separator: " ")) \(label)")
    }
}

private struct GroupHeader: View {
    let folder: URL?
    var title = "Other"
    /// The group's rows, for "Open All in Browser".
    var ports: [ListeningPort] = []

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let folder {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 13)
                    .accessibilityHidden(true)
                Text(folder.lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                // Opacity rather than removal, so the buttons stay reachable by VoiceOver.
                HStack(spacing: 1) {
                    headerButton("Reveal in Finder", image: Image(systemName: "folder")) { reveal(folder) }
                    if let editor = ProjectApps.editor {
                        headerButton("Open in \(editor.name) (⌘O)", image: Image(nsImage: editor.icon())) { ProjectApps.open(folder, in: editor) }
                    }
                    if let terminal = ProjectApps.terminal {
                        headerButton("Open in \(terminal.name) (⌘T)", image: Image(nsImage: terminal.icon())) { ProjectApps.open(folder, in: terminal) }
                    }
                }
                .opacity(hovering ? 1 : 0)
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // Fixed height, so the buttons appearing on hover do not move the rows below.
        .frame(height: 22)
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .background(hovering && folder != nil ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .onHover { hovering = $0 }
        .contextMenu {
            if let folder {
                Button("Reveal in Finder") { reveal(folder) }
                if let editor = ProjectApps.editor {
                    Button("Open in \(editor.name)") { ProjectApps.open(folder, in: editor) }
                }
                if let terminal = ProjectApps.terminal {
                    Button("Open in \(terminal.name)") { ProjectApps.open(folder, in: terminal) }
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(folder.path, forType: .string)
                }
                Divider()
                Button(ports.count == 1 ? "Open in Browser" : "Open All \(ports.count) in Browser") {
                    ports.forEach { NSWorkspace.shared.open($0.url) }
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func reveal(_ folder: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    private func headerButton(_ title: String, image: Image, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The "Other" header, which folds its rows away.
private struct OtherHeader: View {
    let count: Int
    @Binding var collapsed: Bool

    var body: some View {
        Button { collapsed.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: 13)
                Text("Other")
                    .font(.system(size: 12, weight: .semibold))
                if collapsed {
                    Text(String(count))
                        .font(.system(size: 11).monospacedDigit())
                }
                Spacer()
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityLabel("Other, \(count) ports")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct PortRow: View {
    let port: ListeningPort
    let store: PortStore
    let selected: Bool
    let copied: Bool
    let stop: StopState?
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onStop: (StopAction) -> Void

    @State private var hovering = false

    /// On the accent-colored selection, secondary text and the stale orange turn white.
    private var secondary: Color { selected ? .white.opacity(0.85) : Color(nsColor: .secondaryLabelColor) }

    var body: some View {
        Group {
            if let stop { stopPanel(stop) } else { idleRow }
        }
        .padding(.leading, 29)
        .padding(.trailing, 10)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if stop != nil { return Color.red.opacity(0.1) }
        if selected { return .accentColor }
        return hovering ? Color.primary.opacity(0.055) : .clear
    }

    private var idleRow: some View {
        HStack(spacing: 10) {
            PortNumber(port: port.port)
            // A container's image goes on a second line, so long names get the full width.
            if let container = port.container {
                VStack(alignment: .leading, spacing: 1) {
                    Text(port.displayName)
                        .font(.system(size: 13))
                    Label(container.shortImage, systemImage: "shippingbox")
                        .labelStyle(ImageLabel())
                        .font(.system(size: 11))
                        .foregroundStyle(secondary)
                        .help(container.image)
                        .accessibilityLabel("Docker, \(container.image)")
                }
                .lineLimit(1)
            } else {
                processName
            }
            Spacer(minLength: 8)
            // Actions take the uptime's place on hover. Hidden, they keep zero width, so the
            // name gets that space, and opacity keeps them in the accessibility tree.
            ZStack(alignment: .trailing) {
                HStack(spacing: 6) {
                    if store.watched.contains(port.port) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(secondary)
                            .accessibilityLabel("Watched")
                    }
                    if copied {
                        Label("Copied", systemImage: "checkmark")
                            .font(.system(size: 12))
                            .foregroundStyle(secondary)
                    } else {
                        TimelineView(.everyMinute) { context in
                            let stale = context.date.timeIntervalSince(port.startTime) >= 86_400
                            Text(uptimeFormatter.string(from: port.startTime, to: context.date) ?? "")
                                .font(.system(size: 12, weight: stale ? .medium : .regular).monospacedDigit())
                                .foregroundStyle(stale && !selected ? staleColor : secondary)
                        }
                    }
                }
                .opacity(hovering ? 0 : 1)
                HStack(spacing: 1) {
                    iconButton("Open in browser", "arrow.up.forward.square") { NSWorkspace.shared.open(port.url) }
                    iconButton(copied ? "Copied" : "Copy URL", copied ? "checkmark" : "doc.on.doc", action: onCopy)
                    WatchButton(port: port.port, store: store)
                    if port.canStop {
                        iconButton(port.container == nil ? "Stop process" : "Stop container", "xmark.circle") { onStop(.ask) }
                    }
                }
                .fixedSize()
                .frame(width: hovering ? nil : 0, alignment: .trailing)
                .opacity(hovering ? 1 : 0)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(height: port.container == nil ? 34 : 42)
    }

    private var processName: some View {
        HStack(spacing: 6) {
            Text(port.displayName)
            // Without a project group, the fallback cwd is the only location hint.
            if port.projectFolder == nil, let label = port.projectLabel {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(secondary)
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
    }

    /// Replaces the row while stopping, so the question sits next to what it is about.
    private func stopPanel(_ stop: StopState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            stopQuestion(stop.step)
            if let more = alsoStop(stop), stop.step == .confirm {
                Toggle(isOn: Binding(get: { stop.includeMore }, set: { _ in onStop(.toggleMore) })) {
                    Text(more.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .padding(.leading, 54)
                .padding(.bottom, 7)
                .help(more.help)
            }
        }
    }

    private func alsoStop(_ stop: StopState) -> (label: String, help: String)? {
        if let job = stop.job {
            return ("Also stop \(job.command)",
                    "It started \(port.displayName) and would keep running, or restart it. Stops process group \(job.pgid).")
        }
        guard !stop.siblings.isEmpty, let project = port.container?.composeProject else { return nil }
        let others = stop.siblings.count == 1 ? "the other container" : "the other \(stop.siblings.count) containers"
        return ("Also stop \(others) in \(project)",
                "Stops the whole compose project, including containers without a published port.")
    }

    private func stopQuestion(_ step: StopStep) -> some View {
        HStack(spacing: 10) {
            PortNumber(port: port.port)
            VStack(alignment: .leading, spacing: 1) {
                Text(step == .force ? "\(port.displayName) is still running" : "Stop \(port.displayName)?")
                    .font(.system(size: 13, weight: .medium))
                Text(step == .force ? "It ignored the request to quit." : stopCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if step == .stopping {
                ProgressView().controlSize(.small)
            } else {
                Button("Cancel") { onStop(.cancel) }
                    .controlSize(.small)
                Button(step == .force ? "Force quit" : "Stop", role: .destructive) {
                    onStop(step == .force ? .force : .confirm)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
    }

    private var stopCaption: String {
        let uptime = uptimeFormatter.string(from: port.startTime, to: .now) ?? ""
        return port.projectFolder.map { "\($0.lastPathComponent), running \(uptime)" } ?? "Running \(uptime)"
    }

    private func iconButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

/// Icon and title 4 pt apart; the default label spacing is wide for an 11 pt line.
private struct ImageLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 10))
            configuration.title
        }
    }
}

private struct PortNumber: View {
    let port: Int
    var dimmed = false

    var body: some View {
        Text(String(port))
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            // Inherits the row's color unless dimmed, so it turns white on a selected row.
            .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.foreground))
            .frame(width: 44, alignment: .leading)
    }
}

private struct WatchButton: View {
    let port: Int
    let store: PortStore

    var body: some View {
        let watched = store.watched.contains(port)
        let title = watched ? "Stop watching" : "Notify when this port goes down"
        Button { store.toggleWatch(port) } label: {
            Label(title, systemImage: watched ? "bell.slash" : "bell")
                .labelStyle(.iconOnly)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(title)
    }
}

/// A watched port with nothing listening on it, kept visible so it can be unwatched.
private struct DownRow: View {
    let port: Int
    let store: PortStore

    var body: some View {
        HStack(spacing: 10) {
            PortNumber(port: port, dimmed: true)
            Text("Watched, not listening")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            WatchButton(port: port, store: store)
        }
        .frame(height: 34)
        .padding(.leading, 29)
        .padding(.trailing, 10)
        .padding(.horizontal, 6)
    }
}

/// Registers the app itself as a login item; there is no helper process.
enum LaunchAtLogin {
    /// Read fresh each time. Pending approval counts as on: the user asked for it and
    /// macOS is waiting on them.
    static var isOn: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }

    static var binding: Binding<Bool> {
        Binding(get: { isOn }, set: { set($0) })
    }

    static func set(_ on: Bool) {
        // A failure leaves the status unchanged, so the menu shows the truth next time.
        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}

#Preview {
    ContentView(store: PortStore())
}
