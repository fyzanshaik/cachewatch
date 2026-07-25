import Foundation

public struct CodexOpenRollout: Sendable, Equatable {
    public let pid: Int32
    public let file: URL

    public init(pid: Int32, file: URL) {
        self.pid = pid
        self.file = file
    }
}

/// Finds rollout files held open by live Codex processes, then incrementally
/// consumes only bytes appended since the previous poll.
public struct CodexSessionSource {
    private struct FileState {
        var offset: UInt64 = 0
        var partialLine = ""
        var accumulator = CodexRolloutAccumulator()
    }

    private let sessionsDirectory: URL
    private var states: [URL: FileState] = [:]

    public init(directory: URL) {
        sessionsDirectory = directory.standardizedFileURL
    }

    public mutating func poll(openRollouts: [CodexOpenRollout]? = nil) -> [(Int32, CodexRolloutSnapshot)] {
        let open = openRollouts ?? Self.discoverOpenRollouts(sessionsDirectory: sessionsDirectory)
        var result: [(Int32, CodexRolloutSnapshot)] = []
        for rollout in open {
            var state = states[rollout.file] ?? FileState()
            consumeNewBytes(from: rollout.file, state: &state)
            states[rollout.file] = state
            if let snapshot = state.accumulator.snapshot, snapshot.isUserFacing {
                result.append((rollout.pid, snapshot))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.1.startedAt == rhs.1.startedAt { return lhs.1.sessionId < rhs.1.sessionId }
            return lhs.1.startedAt < rhs.1.startedAt
        }
    }

    public static func parseLsof(_ output: String, sessionsDirectory: URL) -> [CodexOpenRollout] {
        let prefix = sessionsDirectory.standardizedFileURL.path + "/"
        var pid: Int32?
        var result: [CodexOpenRollout] = []
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value)
            case "n":
                guard let pid else { continue }
                let file = URL(fileURLWithPath: value).standardizedFileURL
                guard file.path.hasPrefix(prefix), file.pathExtension == "jsonl" else { continue }
                result.append(CodexOpenRollout(pid: pid, file: file))
            default:
                continue
            }
        }
        return result
    }

    private static func discoverOpenRollouts(sessionsDirectory: URL) -> [CodexOpenRollout] {
        let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return []
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-n", "-P", "-F", "pcn", "-c", "codex"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLsof(String(decoding: data, as: UTF8.self), sessionsDirectory: sessionsDirectory)
    }

    private mutating func consumeNewBytes(from file: URL, state: inout FileState) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < state.offset {
            state = FileState()
        }
        guard size > state.offset else { return }
        try? handle.seek(toOffset: state.offset)
        guard let data = try? handle.readToEnd() else { return }
        state.offset = size

        var text = state.partialLine + String(decoding: data, as: UTF8.self)
        if let newline = text.lastIndex(of: "\n") {
            state.partialLine = String(text[text.index(after: newline)...])
            text = String(text[..<newline])
        } else {
            state.partialLine = text
            return
        }
        for line in text.split(separator: "\n") {
            state.accumulator.consume(line: String(line))
        }
    }
}
