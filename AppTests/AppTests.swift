import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import App

/// Swift Testing rather than XCTest: it ships with Xcode 16 and later.
@MainActor
struct AppTests {
    @Test("the root view can be built")
    func contentViewExists() {
        _ = ContentView(store: PortStore())
    }

    @Test("lsof output is deduped and filtered to localhost listeners")
    func parsesLsof() {
        let output = """
        p100
        cnode
        f20
        n*:3000
        f21
        n*:3000
        p200
        cpostgres
        f5
        n127.0.0.1:5432
        f6
        n[::1]:5432
        p300
        clan-only
        f1
        n192.168.1.5:8080
        """
        let rows = PortScanner.parseLsof(output)
        #expect(rows.map(\.port) == [3000, 5432])
        #expect(rows.map(\.name) == ["node", "postgres"])
    }

    @Test("filter matches port, process and project, ignoring case")
    func filterMatches() {
        let row = ListeningPort(port: 5173, pid: 1, processName: "node", projectFolder: URL(fileURLWithPath: "/code/Shop-Web"),
                                cwd: "/code/Shop-Web/src", startTime: .now)
        #expect(row.matches("517"))
        #expect(row.matches("NODE"))
        #expect(row.matches("shop"))
        #expect(!row.matches("postgres"))
    }

    @Test("a watched port alerts once per going down, not while it stays down")
    func watchedPortDiff() {
        func row(_ port: Int, pid: Int32 = 1) -> ListeningPort {
            ListeningPort(port: port, pid: pid, processName: "node", projectFolder: nil, cwd: nil, startTime: .now)
        }
        let watched: Set<Int> = [3000]
        let up = [row(3000), row(3000, pid: 2), row(5432)]
        let down = [row(5432)]

        #expect(PortStore.wentDown(previous: up, current: down, watched: watched).map(\.port) == [3000])
        #expect(PortStore.wentDown(previous: down, current: down, watched: watched).isEmpty)
        #expect(PortStore.wentDown(previous: up, current: up, watched: watched).isEmpty)
        #expect(PortStore.wentDown(previous: up, current: [], watched: []).isEmpty)
    }

    @Test("rows group by project in incoming order, rows without a project last")
    func groupsByProject() {
        let shop = URL(fileURLWithPath: "/code/shop")
        let blog = URL(fileURLWithPath: "/code/blog")
        func row(_ port: Int, _ folder: URL?) -> ListeningPort {
            ListeningPort(port: port, pid: Int32(port), processName: "node", projectFolder: folder, cwd: nil, startTime: .now)
        }
        let groups = groupByProject([row(3000, shop), row(4000, nil), row(5000, blog), row(6000, shop)])
        #expect(groups.map(\.folder) == [shop, blog, nil])
        #expect(groups.map { $0.rows.map(\.port) } == [[3000, 6000], [5000], [4000]])
    }

    @Test("Docker helper processes display as Docker")
    func dockerDisplayName() {
        let row = ListeningPort(port: 8080, pid: 1, processName: "com.docker.backend", projectFolder: nil, cwd: nil, startTime: .now)
        #expect(row.displayName == "Docker")
        #expect(row.matches("docker"))
    }

    @Test("docker ps lines map published host ports to containers")
    func parsesDockerPs() throws {
        // Fields: ID, name, image, ports, compose project, working dir, service, mounts.
        let output = [
            "a1\tshop-db-1\tpostgres:16\t0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp\tshop\t/code/shop\tdb\tshop_data",
            "b2\tadminer\tadminer:latest\t0.0.0.0:8081->8080/tcp, 9000/tcp\t\t\t\t",
            "c3\tsupabase_studio_my-app\tpublic.ecr.aws/supabase/studio:2026.04\t0.0.0.0:7000-7001->80-81/tcp\tmy-app\t\t\tvol,/Users/me/my-app/supabase/functions",
        ].joined(separator: "\n")
        let containers = PortScanner.parseDockerPs(output)
        #expect(containers.map(\.ports) == [[5433], [8081], []])
        let db = containers[0]
        #expect(db.name == "db")
        #expect(db.image == "postgres:16")
        #expect(db.composeFolder == "/code/shop")
        #expect(PortScanner.parseStartTimes("a1 2026-11-09T16:20:57.449849725Z")["a1"] == Date(timeIntervalSince1970: 1_794_241_257))
        #expect(containers[1].name == "adminer")
        #expect(containers[1].composeFolder == nil)
        #expect(containers[2].name == "supabase_studio")
        #expect(containers[2].shortImage == "studio:2026.04")
        #expect(containers[2].mounts == ["vol", "/Users/me/my-app/supabase/functions"])
        #expect(containers.map(\.siblings) == [[], [], []])
        let pair = PortScanner.parseDockerPs("a\tx\ti\t\tp\t\t\t\nb\ty\ti\t\tp\t\t\t\nc\tz\ti\t\t\t\t\t")
        #expect(pair.map(\.siblings) == [["b"], ["a"], []])

        let row = ListeningPort(port: 5433, pid: 1, processName: "OrbStack Helper", projectFolder: nil, cwd: nil,
                                startTime: .now, container: db)
        #expect(row.displayName == "db")
        #expect(row.matches("postgres") && row.matches("docker"))
        #expect(row.canStop)
        #expect(!ListeningPort(port: 1, pid: 1, processName: "vpnkit", projectFolder: nil, cwd: nil, startTime: .now).canStop)
    }

    @Test("containers without a working directory find their project through mounts and compose siblings")
    func resolvesContainerFolders() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = home.appendingPathComponent("my-app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("supabase/functions"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: app.appendingPathComponent("package.json").path, contents: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        func container(_ id: String, project: String?, mounts: [String]) -> DockerContainer {
            DockerContainer(id: id, name: id, image: "x", ports: [], composeProject: project, composeFolder: nil, mounts: mounts)
        }
        let folders = PortScanner.containerFolders([
            container("db", project: "my-app", mounts: ["db_data"]),
            container("functions", project: "my-app", mounts: ["/etc/x", app.path + "/supabase/functions"]),
            container("other", project: "other", mounts: []),
        ], home: home.path)
        #expect(folders["functions"]?.path == app.path)
        #expect(folders["db"]?.path == app.path)
        #expect(folders["other"] == nil)
    }

    @Test("the panel opens under the icon on the display the user is on, and centers when the icon is hidden")
    func placesPanel() {
        // The layout this was found on: a 3008 pt monitor, the laptop display to its right.
        let monitor = (frame: NSRect(x: 0, y: 0, width: 3008, height: 1692), visible: NSRect(x: 0, y: 0, width: 3008, height: 1662))
        let laptop = (frame: NSRect(x: 3008, y: 65, width: 1512, height: 982), visible: NSRect(x: 3008, y: 65, width: 1512, height: 950))
        let size = NSSize(width: 380, height: 400)
        func place(_ icon: NSRect?, on target: (frame: NSRect, visible: NSRect)) -> NSRect {
            MenuBarController.panelFrame(size: size, icon: icon, screens: [monitor.frame, laptop.frame], target: target)
        }
        // The icon's window is on the laptop's menu bar, 620 pt from its right edge.
        let icon = NSRect(x: 3900, y: 1015, width: 30, height: 32)

        let onLaptop = place(icon, on: laptop)
        #expect(onLaptop.minX == 3900)
        #expect(onLaptop.maxY == laptop.visible.maxY - 6)

        // Clicked on the monitor's menu bar: the same icon sits 620 pt from that display's right edge.
        let onMonitor = place(icon, on: monitor)
        let mirrored: CGFloat = 3008 - 620
        #expect(onMonitor.minX == mirrored)
        #expect(onMonitor.maxY == monitor.visible.maxY - 6)

        // Near the right edge it shifts left to stay on the display.
        let atEdge = place(NSRect(x: 4500, y: 1015, width: 20, height: 32), on: laptop)
        #expect(atEdge.maxX <= laptop.visible.maxX - 8)
        #expect(atEdge.minX < 4500)

        let hidden = place(NSRect(x: -5000, y: 5000, width: 30, height: 30), on: monitor)
        #expect(hidden.midX == monitor.visible.midX)
        #expect(place(nil, on: laptop).midX == laptop.visible.midX)
    }

    @Test("a recorded key press becomes a shortcut only with ⌘, ⌃ or ⌥")
    func recordsShortcut() throws {
        func press(_ flags: NSEvent.ModifierFlags, _ key: String, _ code: Int) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: UInt16(code))!
        }
        let shortcut = try #require(GlobalHotKey.shortcut(from: press([.control, .option], "p", kVK_ANSI_P)))
        #expect(shortcut == .standard)
        #expect(GlobalHotKey.shortcut(from: press([.command, .shift], " ", kVK_Space))?.display == "⇧⌘Space")
        #expect(GlobalHotKey.shortcut(from: press([.shift], "p", kVK_ANSI_P)) == nil)
        #expect(GlobalHotKey.shortcut(from: press([], "p", kVK_ANSI_P)) == nil)
    }

    @Test("a terminal is always found, since Terminal ships with macOS")
    func findsTerminal() throws {
        let terminal = try #require(ProjectApps.terminal)
        #expect(!terminal.name.isEmpty && !terminal.name.hasSuffix(".app"))
        if let editor = ProjectApps.automaticEditor, let id = Bundle(url: editor.url)?.bundleIdentifier {
            #expect(ProjectApps.editors.contains(id))
        }
    }

    @Test("project root is the nearest ancestor with a marker")
    func findsProjectRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("src/server")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(PortScanner.projectRoot(for: sub.path) == nil)
        FileManager.default.createFile(atPath: root.appendingPathComponent("package.json").path, contents: nil)
        #expect(PortScanner.projectRoot(for: sub.path)?.path == root.path)
    }

    /// Starts `/bin/sh -c script` and returns a row describing it, as a scan would.
    private func spawn(_ script: String) throws -> ListeningPort {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()
        let info = try #require(PortScanner.bsdInfo(of: process.processIdentifier))
        return ListeningPort(port: 0, pid: process.processIdentifier, processName: "sh", projectFolder: nil, cwd: nil,
                             startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
    }

    @Test("terminate stops a process that honours SIGTERM")
    func terminateStopsProcess() async throws {
        let row = try spawn("exec sleep 30")
        #expect(PortScanner.isRunning(row))
        #expect(await PortStore().terminate(row))
        #expect(!PortScanner.isRunning(row))
    }

    @Test("a process ignoring SIGTERM survives terminate and dies on force kill")
    func forceKillsStubbornProcess() async throws {
        let row = try spawn("trap '' TERM; exec sleep 30")
        try await Task.sleep(for: .milliseconds(300)) // let the trap install
        let store = PortStore()
        #expect(await store.terminate(row) == false)
        await store.forceKill(row)
        #expect(!PortScanner.isRunning(row))
    }

    @Test("a reused PID with a different start time is not treated as the same process")
    func rejectsReusedPid() async throws {
        let row = try spawn("exec sleep 30")
        let stale = ListeningPort(port: 0, pid: row.pid, processName: "sh", projectFolder: nil, cwd: nil,
                                  startTime: row.startTime.addingTimeInterval(-60))
        #expect(!PortScanner.isRunning(stale))
        await PortStore().forceKill(stale)
        #expect(PortScanner.isRunning(row))
        await PortStore().forceKill(row)
    }

    @Test("commands read the way they were typed")
    func displaysCommands() {
        #expect(PortScanner.displayCommand(["npm run dev"]) == "npm run dev")
        #expect(PortScanner.displayCommand(["/usr/local/bin/node", "/x/node_modules/.bin/nodemon", "server.js"]) == "nodemon server.js")
        #expect(PortScanner.displayCommand(["/usr/local/bin/node", "/x/yarn/bin/yarn.js", "dev"]) == "yarn dev")
        #expect(PortScanner.displayCommand(["/opt/Python.app/Contents/MacOS/Python", "-m", "http.server"]) == "Python -m http.server")
        #expect(PortScanner.displayCommand([]) == nil)
        #expect(PortScanner.displayCommand(["next-server (v15.5.4)"]) == "next-server (v15.5.4)")
        #expect(PortScanner.displayCommand(["/usr/local/bin/node", "/x/server.js", "--config", "/x/app.json"]) == "server --config app.json")
        #expect(PortScanner.displayCommand(["/Applications/Raycast.app/Contents/MacOS/Raycast"]) == nil)
        #expect(PortScanner.displayCommand(["/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", "--type=renderer"]) == nil)
        #expect(PortScanner.arguments(of: getpid())?.isEmpty == false)

        // npm retitles itself: argc stays 4, the argument area holds one string and NULs.
        var procArgs: [UInt8] = [4, 0, 0, 0]
        procArgs += Array("/usr/local/bin/node\0\0\0npm run dev\0\0\0\0SECRET=1\0".utf8)
        #expect(PortScanner.parseProcArgs(procArgs) == ["npm run dev"])
    }

    @Test("stopping with the dev command signals its whole process group")
    func terminatesProcessGroup() async throws {
        // A new process group, as a shell job gets: a leader and a child, like npm and the server.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv = (["/bin/sh", "-c", "sleep 30 & exec sleep 31"] as [String]).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pgid: pid_t = 0
        #expect(posix_spawn(&pgid, "/bin/sh", nil, &attr, argv, environ) == 0)
        try await Task.sleep(for: .milliseconds(300)) // let the child fork
        let info = try #require(PortScanner.bsdInfo(of: pgid))
        let row = ListeningPort(port: 0, pid: pgid, processName: "sleep", projectFolder: nil, cwd: nil,
                                startTime: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
        let job = DevCommand(pgid: pgid, startTime: info.pbi_start_tvsec, command: "sleep 31")

        #expect(await PortStore().terminate(row, job: job))
        waitpid(pgid, nil, 0)
        // The orphaned child is gone once launchd reaps it.
        var groupGone = false
        for _ in 0..<20 where !groupGone {
            groupGone = killpg(pgid, 0) == -1
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(groupGone)
    }

    @Test("a real scan finds a socket this process is listening on")
    func scanFindsOwnListener() async {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, len)
                _ = listen(fd, 1)
                _ = getsockname(fd, $0, &len)
            }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let rows = await PortScanner().scan() ?? []
        let row = rows.first { $0.port == port }
        #expect(row?.pid == getpid())
        #expect(row?.cwd != nil)
    }
}
