import Foundation
import Darwin

struct ListeningPort: Identifiable, Equatable, Sendable {
    let port: Int
    let pid: Int32
    let processName: String
    /// Nearest ancestor of the cwd holding a project marker, nil when none was found.
    let projectFolder: URL?
    /// Raw working directory, the fallback label when no project marker was found.
    let cwd: String?
    let startTime: Date
    /// The container publishing this port, when a Docker helper owns it.
    var container: DockerContainer? = nil
    /// How it was started (`vite --port 5173`), so several servers in one project tell apart.
    var command: String? = nil

    var id: String { "\(pid):\(port)" }

    var isDocker: Bool { PortScanner.dockerHelpers.contains(processName) }

    /// A Docker port without its container would mean stopping Docker itself.
    var canStop: Bool { !isDocker || container != nil }

    var projectLabel: String? {
        if let projectFolder { return projectFolder.lastPathComponent }
        guard let cwd, cwd != "/" else { return nil }
        return (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// Docker's helper process names mean nothing to users; the app they know is Docker.
    var displayName: String {
        container?.name ?? command ?? (isDocker ? "Docker" : processName)
    }

    func matches(_ query: String) -> Bool {
        [String(port), processName, displayName, projectLabel ?? "", container?.image ?? "", isDocker ? "Docker" : ""]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct DockerContainer: Equatable, Sendable {
    let id: String
    /// The compose service name, or the container name without its compose project.
    let name: String
    let image: String
    /// Published host ports.
    let ports: [Int]
    let composeProject: String?
    /// The compose project's working directory, from its label.
    let composeFolder: String?
    /// Bind mount sources and volume names.
    let mounts: [String]
    /// From `docker inspect`. Creation time would be wrong: tools like the Supabase CLI
    /// restart the same containers for weeks.
    var started: Date? = nil
    /// The other running containers of the same compose project, ports or not.
    var siblings: [String] = []

    /// `public.ecr.aws/supabase/studio:2026.04` reads as `studio:2026.04`.
    var shortImage: String { image.split(separator: "/").last.map(String.init) ?? image }
}

/// The command a dev server was started through, such as `npm run dev`. Stopping only the
/// server would leave it running, or restarting the server on the same port.
struct DevCommand: Equatable, Sendable {
    /// The group leader's PID, which is also the process group ID.
    let pgid: pid_t
    let startTime: UInt64
    let command: String
}

/// An actor so scans run off the main thread and never overlap.
actor PortScanner {
    static let projectMarkers = [".git", "package.json", "Package.swift", "Cargo.toml", "go.mod", "pyproject.toml", "docker-compose.yml"]
    /// Docker-published ports belong to these helpers; their cwd says nothing about the project.
    static let dockerHelpers: Set<String> = ["com.docker.backend", "vpnkit", "OrbStack Helper"]

    /// Nil when lsof could not run, which is different from "nothing is listening".
    func scan() -> [ListeningPort]? {
        guard let output = Self.runLsof() else { return nil }
        let uid = getuid()
        let rows: [ListeningPort] = Self.parseLsof(output).compactMap { entry in
            // Only the user's own processes: anything else cannot be killed or inspected.
            guard let bsd = Self.bsdInfo(of: entry.pid), bsd.pbi_uid == uid else { return nil }
            let cwd = Self.dockerHelpers.contains(entry.name) ? nil : Self.cwd(of: entry.pid)
            return ListeningPort(
                port: entry.port,
                pid: entry.pid,
                processName: entry.name,
                projectFolder: cwd.flatMap(Self.projectRoot),
                cwd: cwd,
                startTime: Date(timeIntervalSince1970: TimeInterval(bsd.pbi_start_tvsec)),
                command: Self.dockerHelpers.contains(entry.name) ? nil : Self.arguments(of: entry.pid).flatMap(Self.displayCommand)
            )
        }
        // Only asks Docker when it owns a port, so a stopped daemon costs nothing.
        guard rows.contains(where: \.isDocker) else { return rows }
        let containers = Self.dockerContainers()
        let folders = Self.containerFolders(containers)
        let byPort = Dictionary(containers.flatMap { c in c.ports.map { ($0, c) } }, uniquingKeysWith: { first, _ in first })
        return rows.map { row in
            guard row.isDocker, let container = byPort[row.port] else { return row }
            let folder = folders[container.id]
            return ListeningPort(port: row.port, pid: row.pid, processName: row.processName, projectFolder: folder,
                                 cwd: folder?.path, startTime: container.started ?? row.startTime, container: container)
        }
    }

    /// The project each container belongs to: the compose working directory, else the
    /// project around a bind mount from the user's home (the Supabase CLI sets no working
    /// directory, but mounts `supabase/functions`). Containers with neither, such as a
    /// database, join the folder of another container in the same compose project.
    static func containerFolders(_ containers: [DockerContainer], home: String = NSHomeDirectory()) -> [String: URL] {
        let home = home.hasSuffix("/") ? home : home + "/"
        var folders: [String: URL] = [:]
        var projects: [String: URL] = [:]
        for container in containers {
            let folder = container.composeFolder.map { projectRoot(for: $0) ?? URL(fileURLWithPath: $0) }
                ?? container.mounts.lazy.filter { $0.hasPrefix(home) }.compactMap(projectRoot).first
            folders[container.id] = folder
            if let folder, let project = container.composeProject, projects[project] == nil { projects[project] = folder }
        }
        for container in containers where folders[container.id] == nil {
            folders[container.id] = container.composeProject.flatMap { projects[$0] }
        }
        return folders
    }

    /// Parses `lsof -F pcn` output into one entry per (pid, port), keeping loopback and
    /// all-interface listeners only. IPv4 and IPv6 sockets on the same port collapse.
    static func parseLsof(_ output: String) -> [(pid: Int32, name: String, port: Int)] {
        var result: [(pid: Int32, name: String, port: Int)] = []
        var seen = Set<String>()
        var pid: Int32 = 0
        var name = ""
        for line in output.split(separator: "\n") {
            let value = line.dropFirst()
            switch line.first {
            case "p": pid = Int32(value) ?? 0
            case "c": name = String(value)
            case "n":
                guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = value[..<colon]
                guard host == "*" || host == "[::1]" || host.hasPrefix("127.") else { continue }
                if seen.insert("\(pid):\(port)").inserted { result.append((pid, name, port)) }
            default: break
            }
        }
        return result.sorted { $0.port < $1.port }
    }

    /// Walks up from `cwd` to the nearest directory containing a project marker.
    static func projectRoot(for cwd: String) -> URL? {
        var dir = URL(fileURLWithPath: cwd, isDirectory: true)
        while dir.path != "/" {
            if projectMarkers.contains(where: { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// True while the PID still belongs to the process the row was built from. A matching
    /// start time rules out PID reuse; a zombie has already released its ports.
    static func isRunning(_ port: ListeningPort) -> Bool {
        isRunning(pid: port.pid, startTime: UInt64(port.startTime.timeIntervalSince1970))
    }

    static func isRunning(_ job: DevCommand) -> Bool {
        isRunning(pid: job.pgid, startTime: job.startTime)
    }

    private static func isRunning(pid: pid_t, startTime: UInt64) -> Bool {
        guard let info = bsdInfo(of: pid) else { return false }
        return info.pbi_start_tvsec == startTime && info.pbi_status != SZOMB
    }

    /// Commands that start dev servers and either restart them or keep running without them.
    // Limit: a fixed list; an editor or terminal app can also lead a process group, and
    // stopping it would be a disaster, so unknown leaders fall back to stopping the server alone.
    static let devRunners: Set<String> = ["npm", "npx", "pnpm", "yarn", "bun", "deno", "turbo", "nx", "nodemon",
                                          "concurrently", "make", "foreman", "overmind", "honcho", "watchexec", "cargo", "air"]
    private static let interpreters: Set<String> = ["node", "python", "python3", "ruby", "perl"]
    private static let scriptExtensions: Set<String> = ["js", "cjs", "mjs", "ts", "py", "rb", "pl"]

    /// The dev runner leading the listener's process group (the shell job), if any.
    static func devCommand(of port: ListeningPort) -> DevCommand? {
        guard !port.isDocker, let pgid = processGroup(of: port.pid), pgid != port.pid,
              let leader = bsdInfo(of: pgid), leader.pbi_uid == getuid(),
              let command = arguments(of: pgid).flatMap(displayCommand),
              devRunners.contains(String(command.prefix { $0 != " " })) else { return nil }
        return DevCommand(pgid: pgid, startTime: leader.pbi_start_tvsec, command: command)
    }

    static func processGroup(of pid: pid_t) -> pid_t? {
        bsdInfo(of: pid).map { pid_t(bitPattern: $0.pbi_pgid) }
    }

    /// `node /path/node_modules/.bin/nodemon server.js` reads as `nodemon server.js`.
    /// Nil for an app's own processes: Electron and other helpers carry long internal flags,
    /// and the process name says more. Interpreters inside a bundle (Python.app) still count.
    static func displayCommand(_ arguments: [String]) -> String? {
        var arguments = arguments
        guard !arguments.isEmpty else { return nil }
        // Only script extensions go: `yarn.js` reads as `yarn`, `next-server (v15.5.4)` stays.
        func name(_ path: String) -> String {
            let file = (path as NSString).lastPathComponent as NSString
            return Self.scriptExtensions.contains(file.pathExtension) ? file.deletingPathExtension : file as String
        }
        let interpreter = interpreters.contains(name(arguments[0]).lowercased())
        if arguments[0].contains(".app/Contents/"), !interpreter { return nil }
        if interpreter, arguments.count > 1, !arguments[1].hasPrefix("-") {
            arguments.removeFirst()
        }
        arguments[0] = name(arguments[0])
        // Full paths make rows unreadable; the project group already says where.
        return arguments.map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }.joined(separator: " ")
    }

    /// The process's argv, for display only. Layout of KERN_PROCARGS2: argc, the executable
    /// path, NUL padding, then the NUL-terminated arguments.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        return parseProcArgs(Array(buffer[..<size]))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var start = 4
        while start < buffer.count, buffer[start] != 0 { start += 1 }
        while start < buffer.count, buffer[start] == 0 { start += 1 }
        // Empty arguments still count toward argc: a process that retitles itself (npm
        // does) blanks the rest, and skipping them would run on into the environment.
        return buffer[start...].split(separator: 0, omittingEmptySubsequences: false)
            .prefix(argc)
            .map { String(decoding: $0, as: UTF8.self) }
            .filter { !$0.isEmpty }
    }

    static func bsdInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    // Limit: blocks one cooperative thread for the lsof run (tens of ms); switch to
    // libproc socket enumeration if profiling shows lsof is the bottleneck.
    private static func runLsof() -> String? {
        // -n/-P skip DNS and service-name lookups; +c 0 keeps full command names.
        run("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP", "+c", "0", "-F", "pcn"])
    }

    /// Standard output, or nil when the tool could not start or ran past the timeout
    /// (a stuck Docker daemon must not stall every scan).
    private static func run(_ path: String, _ arguments: [String], timeout: Double = 3) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        return process.terminationReason == .exit ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: Docker

    /// GUI apps get a minimal PATH, so the CLI is looked up where Docker Desktop, OrbStack
    /// and Homebrew install it.
    private static let dockerCLI = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                                    NSHomeDirectory() + "/.orbstack/bin/docker",
                                    "/Applications/Docker.app/Contents/Resources/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Running containers by published host port, from the local daemon (no network).
    private static func dockerContainers() -> [DockerContainer] {
        guard let dockerCLI else { return [] }
        let format = [".ID", ".Names", ".Image", ".Ports", #".Label "com.docker.compose.project""#,
                      #".Label "com.docker.compose.project.working_dir""#, #".Label "com.docker.compose.service""#, ".Mounts"]
            .map { "{{\($0)}}" }.joined(separator: "\t")
        // --no-trunc keeps mount paths whole, and IDs full so they match inspect's.
        guard let output = run(dockerCLI, ["ps", "--no-trunc", "--format", format]) else { return [] }
        var containers = parseDockerPs(output)
        guard !containers.isEmpty,
              let inspect = run(dockerCLI, ["inspect", "--format", "{{.Id}} {{.State.StartedAt}}"] + containers.map(\.id))
        else { return containers }
        let started = parseStartTimes(inspect)
        for index in containers.indices { containers[index].started = started[containers[index].id] }
        return containers
    }

    /// `<id> 2026-11-09T16:20:57.449849725Z` lines. The nanoseconds are dropped, since
    /// ISO8601DateFormatter reads at most milliseconds.
    static func parseStartTimes(_ output: String) -> [String: Date] {
        let formatter = ISO8601DateFormatter()
        var result: [String: Date] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let date = formatter.date(from: parts[1].prefix(19) + "Z") else { continue }
            result[String(parts[0])] = date
        }
        return result
    }

    /// Parses the tab-separated `docker ps` lines from `dockerContainers`.
    static func parseDockerPs(_ output: String) -> [DockerContainer] {
        var containers: [DockerContainer] = output.split(separator: "\n").compactMap { line in
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard field.count == 8 else { return nil }
            let project = field[4].isEmpty ? nil : field[4]
            // "0.0.0.0:5433->5432/tcp, [::]:5433->5432/tcp"; port ranges are skipped.
            var ports: [Int] = []
            for mapping in field[3].split(separator: ",") {
                guard let arrow = mapping.range(of: "->"), let colon = mapping[..<arrow.lowerBound].lastIndex(of: ":"),
                      let port = Int(mapping[mapping.index(after: colon)..<arrow.lowerBound]), !ports.contains(port) else { continue }
                ports.append(port)
            }
            return DockerContainer(
                id: field[0],
                name: field[6].isEmpty ? shortName(field[1], project: project) : field[6],
                image: field[2],
                ports: ports,
                composeProject: project,
                composeFolder: field[5].isEmpty ? nil : field[5],
                mounts: field[7].split(separator: ",").map(String.init)
            )
        }
        for index in containers.indices {
            let container = containers[index]
            containers[index].siblings = container.composeProject.map { project in
                containers.filter { $0.composeProject == project && $0.id != container.id }.map(\.id)
            } ?? []
        }
        return containers
    }

    /// The group header already names the project, so `supabase_db_agent-media-app` reads
    /// as `supabase_db`.
    static func shortName(_ name: String, project: String?) -> String {
        guard let project, let range = name.range(of: project) else { return name }
        let short = name.replacingCharacters(in: range, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
        return short.isEmpty ? name : short
    }

    /// `docker stop` sends SIGTERM and kills after 10s itself, so there is no force step.
    /// Several containers stop in parallel, so the deadline does not grow with the count.
    func stopContainers(_ ids: [String]) -> Bool {
        guard let dockerCLI = Self.dockerCLI, !ids.isEmpty else { return false }
        return Self.run(dockerCLI, ["stop"] + ids, timeout: 15)?.isEmpty == false
    }
}
