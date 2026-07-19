import Foundation

public struct ProcessSample: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    public let rssBytes: UInt64

    public init(pid: Int32, ppid: Int32, rssBytes: UInt64) {
        self.pid = pid
        self.ppid = ppid
        self.rssBytes = rssBytes
    }
}

public enum ProcessTree {
    /// Parses `ps -axo pid=,ppid=,rss=` output; rss arrives in KiB.
    public static func parsePS(_ output: String) -> [ProcessSample] {
        output.split(separator: "\n").compactMap { line in
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count == 3,
                  let pid = Int32(cols[0]), let ppid = Int32(cols[1]), let rssKiB = UInt64(cols[2])
            else { return nil }
            return ProcessSample(pid: pid, ppid: ppid, rssBytes: rssKiB * 1024)
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePS(String(decoding: data, as: UTF8.self))
    }
}
