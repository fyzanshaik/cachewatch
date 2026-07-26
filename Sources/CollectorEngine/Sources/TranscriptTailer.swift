import Foundation

public struct TranscriptPollResult: Sendable, Equatable {
    public let turns: [AssistantTurn]
    public let filesScanned: Int
    public let completedLinesRead: Int
    public let rejectedLines: Int
    public let readFailures: Int
    public let health: SourceHealth
}

/// Incremental reader over `~/.claude/projects/<project>/<session>.jsonl` files.
/// Tracks a byte offset per file; each poll reads only appended bytes and yields
/// the assistant turns found in newly completed lines. Partial trailing lines
/// (a write in progress) stay buffered until their newline arrives.
public struct TranscriptTailer {
    private let directory: URL
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: String] = [:]
    private let startAtEnd: Bool
    private var seededFiles: Set<URL> = []

    /// `startAtEnd`: skip history present before the first poll (live-monitoring mode).
    public init(directory: URL, startAtEnd: Bool = false) {
        self.directory = directory
        self.startAtEnd = startAtEnd
    }

    public mutating func poll() -> [AssistantTurn] {
        pollReport(checkedAt: Date()).turns
    }

    public mutating func pollReport(checkedAt: Date) -> TranscriptPollResult {
        let discovery = transcriptFiles()
        guard discovery.rootReadable else {
            return TranscriptPollResult(
                turns: [],
                filesScanned: 0,
                completedLinesRead: 0,
                rejectedLines: 0,
                readFailures: 1,
                health: SourceHealth(
                    id: .transcripts,
                    condition: .unavailable,
                    lastAttemptAt: checkedAt,
                    recordsDropped: 1,
                    message: "The transcript directory could not be read."
                )
            )
        }

        var turns: [AssistantTurn] = []
        var completedLines = 0
        var rejectedLines = 0
        var readFailures = discovery.readFailures
        for file in discovery.files {
            let result = pollFile(file)
            turns.append(contentsOf: result.turns)
            completedLines += result.completedLines
            rejectedLines += result.rejectedLines
            readFailures += result.readFailed ? 1 : 0
        }

        let dropped = rejectedLines + readFailures
        let condition: SourceCondition = dropped == 0 ? .healthy : .degraded
        let message: String?
        if dropped == 0 {
            message = nil
        } else {
            var parts: [String] = []
            if rejectedLines > 0 {
                parts.append("\(rejectedLines) completed \(rejectedLines == 1 ? "line was" : "lines were") unrecognized.")
            }
            if readFailures > 0 {
                parts.append("\(readFailures) transcript \(readFailures == 1 ? "read failed." : "reads failed.")")
            }
            message = parts.joined(separator: " ")
        }
        return TranscriptPollResult(
            turns: turns,
            filesScanned: discovery.files.count,
            completedLinesRead: completedLines,
            rejectedLines: rejectedLines,
            readFailures: readFailures,
            health: SourceHealth(
                id: .transcripts,
                condition: condition,
                lastAttemptAt: checkedAt,
                lastSuccessAt: condition == .healthy ? checkedAt : nil,
                recordsSeen: completedLines,
                recordsAccepted: completedLines - rejectedLines,
                recordsDropped: dropped,
                message: message
            )
        )
    }

    private func transcriptFiles() -> (files: [URL], rootReadable: Bool, readFailures: Int) {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return ([], false, 0)
        }
        var files: [URL] = []
        var failures = 0
        for projectDir in projectDirs {
            do {
                files.append(contentsOf: try fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "jsonl" })
            } catch {
                failures += 1
            }
        }
        return (files, true, failures)
    }

    private mutating func pollFile(
        _ file: URL
    ) -> (turns: [AssistantTurn], completedLines: Int, rejectedLines: Int, readFailed: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ([], 0, 0, true)
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else {
            return ([], 0, 0, true)
        }

        if startAtEnd, !seededFiles.contains(file) {
            seededFiles.insert(file)
            offsets[file] = size
            return ([], 0, 0, false)
        }

        var offset = offsets[file] ?? 0
        if size < offset {  // truncated/rotated: start over
            offset = 0
            partialLines[file] = nil
        }
        guard size > offset else { return ([], 0, 0, false) }

        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd()
        else { return ([], 0, 0, true) }
        offsets[file] = size

        var text = (partialLines[file] ?? "") + String(decoding: data, as: UTF8.self)
        if let lastNewline = text.lastIndex(of: "\n") {
            partialLines[file] = String(text[text.index(after: lastNewline)...])
            text = String(text[..<lastNewline])
        } else {
            partialLines[file] = text
            return ([], 0, 0, false)
        }

        var turns: [AssistantTurn] = []
        var rejected = 0
        let lines = text.split(separator: "\n")
        for line in lines {
            switch TranscriptParser.classify(line: String(line)) {
            case .assistantTurn(let turn): turns.append(turn)
            case .ignored: break
            case .rejected: rejected += 1
            }
        }
        return (turns, lines.count, rejected, false)
    }
}
