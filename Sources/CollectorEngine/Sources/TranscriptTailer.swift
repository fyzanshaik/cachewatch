import Foundation

public struct TranscriptPollResult: Sendable {
    public let turns: [AssistantTurn]
    public let filesScanned: Int
    public let completedLinesRead: Int
    public let ignoredLines: Int
    public let rejectedLines: Int
    public let readFailures: Int
    public let health: SourceHealth
}

/// Incremental reader over `~/.claude/projects/<project>/<session>.jsonl` files.
/// Tracks a byte offset per file; each poll reads only appended bytes and yields
/// the assistant turns found in newly completed lines. Partial trailing lines
/// (a write in progress) stay buffered until their newline arrives.
public struct TranscriptTailer {
    private struct FilePoll {
        var turns: [AssistantTurn] = []
        var completedLines = 0
        var ignoredLines = 0
        var rejectedLines = 0
        var readFailures = 0
    }

    private let directory: URL
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: String] = [:]
    private let startAtEnd: Bool
    private var seededFiles: Set<URL> = []
    private var unresolvedRejectedLines = 0
    private var lastSuccessfulPollAt: Date?

    /// `startAtEnd`: skip history present before the first poll (live-monitoring mode).
    public init(directory: URL, startAtEnd: Bool = false) {
        self.directory = directory
        self.startAtEnd = startAtEnd
    }

    /// Compatibility view for callers that only need parsed turns.
    public mutating func poll() -> [AssistantTurn] {
        pollReport().turns
    }

    public mutating func pollReport(at attemptedAt: Date = Date()) -> TranscriptPollResult {
        let discovery = transcriptFiles()
        guard discovery.rootReadable else {
            let health = SourceHealth(
                id: .transcripts,
                condition: .unavailable,
                lastAttemptAt: attemptedAt,
                lastSuccessAt: lastSuccessfulPollAt,
                recordsDropped: discovery.readFailures,
                message: "Transcript storage is unavailable. Verify that ~/.claude/projects exists and is readable."
            )
            return TranscriptPollResult(
                turns: [],
                filesScanned: 0,
                completedLinesRead: 0,
                ignoredLines: 0,
                rejectedLines: 0,
                readFailures: discovery.readFailures,
                health: health
            )
        }

        var aggregate = FilePoll(readFailures: discovery.readFailures)
        for file in discovery.files {
            let poll = pollFile(file)
            aggregate.turns.append(contentsOf: poll.turns)
            aggregate.completedLines += poll.completedLines
            aggregate.ignoredLines += poll.ignoredLines
            aggregate.rejectedLines += poll.rejectedLines
            aggregate.readFailures += poll.readFailures
        }

        if aggregate.rejectedLines > 0 {
            unresolvedRejectedLines += aggregate.rejectedLines
        } else if !aggregate.turns.isEmpty {
            unresolvedRejectedLines = 0
        }
        let degraded = unresolvedRejectedLines > 0 || aggregate.readFailures > 0
        if !aggregate.turns.isEmpty || !degraded {
            lastSuccessfulPollAt = attemptedAt
        }
        let message: String? = degraded
            ? "\(unresolvedRejectedLines) transcript records remain unrecognized; \(aggregate.readFailures) file operations failed. Cache and context data may be incomplete."
            : nil
        let health = SourceHealth(
            id: .transcripts,
            condition: degraded ? .degraded : .healthy,
            lastAttemptAt: attemptedAt,
            lastSuccessAt: lastSuccessfulPollAt,
            recordsSeen: aggregate.completedLines,
            recordsAccepted: aggregate.turns.count + aggregate.ignoredLines,
            recordsDropped: unresolvedRejectedLines + aggregate.readFailures,
            message: message
        )
        return TranscriptPollResult(
            turns: aggregate.turns,
            filesScanned: discovery.files.count,
            completedLinesRead: aggregate.completedLines,
            ignoredLines: aggregate.ignoredLines,
            rejectedLines: aggregate.rejectedLines,
            readFailures: aggregate.readFailures,
            health: health
        )
    }

    private func transcriptFiles() -> (files: [URL], readFailures: Int, rootReadable: Bool) {
        let fm = FileManager.default
        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
        } catch {
            return ([], 1, false)
        }

        var files: [URL] = []
        var readFailures = 0
        for directory in projectDirs {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            do {
                files.append(contentsOf: try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "jsonl" })
            } catch {
                readFailures += 1
            }
        }
        return (files.sorted { $0.path < $1.path }, readFailures, true)
    }

    private mutating func pollFile(_ file: URL) -> FilePoll {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            return FilePoll(readFailures: 1)
        }
        defer { try? handle.close() }

        let size: UInt64
        do {
            size = try handle.seekToEnd()
        } catch {
            return FilePoll(readFailures: 1)
        }

        if startAtEnd, !seededFiles.contains(file) {
            seededFiles.insert(file)
            offsets[file] = size
            return FilePoll()
        }

        var offset = offsets[file] ?? 0
        if size < offset {
            offset = 0
            partialLines[file] = nil
        }
        guard size > offset else { return FilePoll() }

        let data: Data
        do {
            try handle.seek(toOffset: offset)
            data = try handle.readToEnd() ?? Data()
        } catch {
            return FilePoll(readFailures: 1)
        }
        offsets[file] = size

        var text = (partialLines[file] ?? "") + String(decoding: data, as: UTF8.self)
        guard let lastNewline = text.lastIndex(of: "\n") else {
            partialLines[file] = text
            return FilePoll()
        }
        partialLines[file] = String(text[text.index(after: lastNewline)...])
        text = String(text[..<lastNewline])

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var result = FilePoll(completedLines: lines.count)
        for line in lines {
            switch TranscriptParser.classify(line: String(line)) {
            case .assistant(let turn):
                result.turns.append(turn)
            case .ignored:
                result.ignoredLines += 1
            case .rejected:
                result.rejectedLines += 1
            }
        }
        return result
    }
}
