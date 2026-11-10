import Foundation
import UserNotifications

/// The only thing the UI reads. Each scan replaces the list wholesale.
@MainActor @Observable
final class PortStore {
    private(set) var ports: [ListeningPort] = []
    private(set) var watched = Set(UserDefaults.standard.array(forKey: "watchedPorts") as? [Int] ?? [])
    /// Set by the popover while it is open; it then drives scanning itself every 2s.
    var popoverOpen = false

    private let scanner = PortScanner()
    /// Watched ports the user stopped from peekport, so their going down is not news.
    private var stoppedByUser = Set<Int>()

    init() {
        // Limit: fixed 10s while closed (one lsof run is ~50ms of CPU, so ~0.5% of a
        // core); libproc socket enumeration would make this cheap enough to go faster.
        Task { [weak self] in
            // One scan at launch, so the first popover shows ports instead of a misleading empty list.
            await self?.refresh()
            while true {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                if !self.popoverOpen, !self.watched.isEmpty { await self.refresh() }
            }
        }
    }

    var downWatchedPorts: [Int] {
        watched.subtracting(ports.map(\.port)).sorted()
    }

    func refresh() async {
        // A failed scan says nothing about which ports are up; diffing it would alert on every watched port.
        guard let current = await scanner.scan() else { return }
        for row in Self.wentDown(previous: ports, current: current, watched: watched)
        where stoppedByUser.remove(row.port) == nil {
            Self.notifyDown(row)
        }
        stoppedByUser.formIntersection(current.map(\.port))
        ports = current
    }

    func toggleWatch(_ port: Int) {
        if watched.remove(port) == nil {
            watched.insert(port)
            // Asks only the first time; later calls return the stored decision.
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        UserDefaults.standard.set(watched.sorted(), forKey: "watchedPorts")
    }

    /// Sends SIGTERM and waits up to 2s for the process to exit. Returns false if it is
    /// still running, so the caller can offer SIGKILL. With `job`, the whole process group
    /// gets the signal, so the runner cannot restart the server.
    /// A container stops with `docker stop`, together with `siblings` (other container IDs).
    func terminate(_ port: ListeningPort, job: DevCommand? = nil, siblings: [String] = []) async -> Bool {
        if let container = port.container {
            let ids = Set([container.id] + siblings)
            stoppedByUser.formUnion(ports.filter { $0.container.map { ids.contains($0.id) } == true }.map(\.port).filter(watched.contains))
            // Limit: a failed `docker stop` leaves the rows in place and says nothing more.
            _ = await scanner.stopContainers([container.id] + siblings)
            await refresh()
            return true
        }
        if PortScanner.isRunning(port) { signal(port, job, SIGTERM) }
        for _ in 0..<20 where PortScanner.isRunning(port) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let exited = !PortScanner.isRunning(port)
        if exited { await refresh() }
        return exited
    }

    func forceKill(_ port: ListeningPort, job: DevCommand? = nil) async {
        if PortScanner.isRunning(port) { signal(port, job, SIGKILL) }
        try? await Task.sleep(for: .milliseconds(200))
        await refresh()
    }

    /// One signal per process: the group signal already reaches the listener, and a second
    /// SIGTERM makes some servers skip their clean shutdown.
    private func signal(_ port: ListeningPort, _ job: DevCommand?, _ signal: Int32) {
        let job = job.flatMap { PortScanner.isRunning($0) ? $0 : nil }
        // Watched ports of the same process or group go down too, and that is not news.
        let stopping = (ports + [port]).filter {
            $0.pid == port.pid || (job != nil && PortScanner.processGroup(of: $0.pid) == job?.pgid)
        }
        stoppedByUser.formUnion(stopping.map(\.port).filter(watched.contains))
        if let job { killpg(job.pgid, signal) } else { kill(port.pid, signal) }
    }

    /// Watched ports listening in `previous` but not in `current`, one row per port.
    static func wentDown(previous: [ListeningPort], current: [ListeningPort], watched: Set<Int>) -> [ListeningPort] {
        let up = Set(current.map(\.port))
        var seen = Set<Int>()
        return previous.filter { watched.contains($0.port) && !up.contains($0.port) && seen.insert($0.port).inserted }
    }

    private static func notifyDown(_ row: ListeningPort) {
        let content = UNMutableNotificationContent()
        content.title = "Port \(row.port) is down"
        content.body = row.projectLabel.map { "\(row.displayName) in \($0) stopped listening." }
            ?? "\(row.displayName) stopped listening."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
