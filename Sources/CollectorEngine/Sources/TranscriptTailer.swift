import Foundation

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
        transcriptFiles().flatMap { pollFile($0) }
    }

    private func transcriptFiles() -> [URL] {
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return projectDirs.flatMap { dir in
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
        }
    }

    private mutating func pollFile(_ file: URL) -> [AssistantTurn] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        if startAtEnd, !seededFiles.contains(file) {
            seededFiles.insert(file)
            offsets[file] = size
            return []
        }

        var offset = offsets[file] ?? 0
        if size < offset {  // truncated/rotated: start over
            offset = 0
            partialLines[file] = nil
        }
        guard size > offset else { return [] }

        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }
        offsets[file] = size

        var text = (partialLines[file] ?? "") + String(decoding: data, as: UTF8.self)
        if let lastNewline = text.lastIndex(of: "\n") {
            partialLines[file] = String(text[text.index(after: lastNewline)...])
            text = String(text[..<lastNewline])
        } else {
            partialLines[file] = text
            return []
        }

        return text.split(separator: "\n").compactMap {
            TranscriptParser.assistantTurn(fromLine: String($0))
        }
    }
}
