import Foundation

public struct ProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let rssBytes: UInt64
    public let command: String

    public init(pid: Int32, ppid: Int32, rssBytes: UInt64, command: String = "") {
        self.pid = pid
        self.ppid = ppid
        self.rssBytes = rssBytes
        self.command = command
    }
}

public struct ProcessSampleResult: Sendable {
    public let samples: [ProcessSample]
    public let health: SourceHealth

    public func sessionSamples(for sessionPIDs: [String: Int32]) -> [SessionProcessSample] {
        guard health.condition != .unavailable else { return [] }
        let availablePIDs = Set(samples.map(\.pid))
        return sessionPIDs.keys.sorted().compactMap { sessionID in
            guard let pid = sessionPIDs[sessionID], availablePIDs.contains(pid) else { return nil }
            return SessionProcessSample(
                sessionID: sessionID,
                pid: pid,
                residentBytes: ProcessTree.subtreeRSS(of: pid, in: samples),
                host: ProcessTree.hostApp(of: pid, in: samples)
            )
        }
    }
}

public struct SessionProcessSample: Sendable, Equatable {
    public let sessionID: String
    public let pid: Int32
    public let residentBytes: UInt64
    public let host: ProcessTree.Host?
}

public enum ProcessTree {
    /// Parses `ps -axo pid=,ppid=,rss=,comm=` output; rss arrives in KiB.
    /// comm is the executable path and may contain spaces — only the first
    /// three columns are numeric, the remainder is the command.
    public static func parsePS(_ output: String) -> [ProcessSample] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = Int32(cols[0]), let ppid = Int32(cols[1]), let rssKiB = UInt64(cols[2])
            else { return nil }
            let command = cols.count == 4 ? String(cols[3]) : ""
            return ProcessSample(pid: pid, ppid: ppid, rssBytes: rssKiB * 1024, command: command)
        }
    }

    public struct Host: Sendable, Equatable {
        public let pid: Int32
        public let name: String
    }

    /// Nearest ancestor that is a macOS app bundle — the terminal/editor hosting
    /// the session (cmux, iTerm2, Terminal, VS Code, Zed, ...).
    public static func hostApp(of pid: Int32, in table: [ProcessSample]) -> Host? {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var current = byPid[pid]
        var hops = 0
        while let process = current, process.pid > 1, hops < 32 {
            if let appName = appBundleName(from: process.command) {
                return Host(pid: process.pid, name: appName)
            }
            current = byPid[process.ppid]
            hops += 1
        }
        return nil
    }

    private static func appBundleName(from command: String) -> String? {
        command.split(separator: "/")
            .first { $0.hasSuffix(".app") }
            .map { String($0.dropLast(4)) }
    }

    /// Total RSS of a session process plus all its descendants (MCP servers, helpers).
    public static func subtreeRSS(of root: Int32, in table: [ProcessSample]) -> UInt64 {
        guard table.contains(where: { $0.pid == root }) else { return 0 }
        var childrenByParent: [Int32: [ProcessSample]] = [:]
        for sample in table {
            childrenByParent[sample.ppid, default: []].append(sample)
        }
        var total: UInt64 = 0
        var queue: [Int32] = [root]
        while let pid = queue.popLast() {
            if let own = table.first(where: { $0.pid == pid }) {
                total += own.rssBytes
            }
            queue.append(contentsOf: (childrenByParent[pid] ?? []).map(\.pid))
        }
        return total
    }

    /// Live sample of the full process table via `ps`.
    public static func sampleAll() -> [ProcessSample] {
        sampleAllReport().samples
    }

    public static func sampleAllReport(at attemptedAt: Date = Date()) -> ProcessSampleResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else {
            return report(psOutput: "", terminationStatus: 127, at: attemptedAt)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return report(
            psOutput: String(decoding: data, as: UTF8.self),
            terminationStatus: process.terminationStatus,
            at: attemptedAt
        )
    }

    public static func report(
        psOutput: String,
        terminationStatus: Int32,
        at attemptedAt: Date
    ) -> ProcessSampleResult {
        guard terminationStatus == 0 else {
            return ProcessSampleResult(
                samples: [],
                health: SourceHealth(
                    id: .process,
                    condition: .unavailable,
                    lastAttemptAt: attemptedAt,
                    message: "Process sampling failed. Only memory and host-app data are affected."
                )
            )
        }

        let recordsSeen = psOutput.split(separator: "\n", omittingEmptySubsequences: true).count
        let samples = parsePS(psOutput)
        let dropped = recordsSeen - samples.count
        let degraded = dropped > 0 || samples.isEmpty
        return ProcessSampleResult(
            samples: samples,
            health: SourceHealth(
                id: .process,
                condition: degraded ? .degraded : .healthy,
                lastAttemptAt: attemptedAt,
                lastSuccessAt: attemptedAt,
                recordsSeen: recordsSeen,
                recordsAccepted: samples.count,
                recordsDropped: dropped,
                message: degraded
                    ? "Some process records were unavailable. Only memory and host-app data may be incomplete."
                    : nil
            )
        )
    }
}
