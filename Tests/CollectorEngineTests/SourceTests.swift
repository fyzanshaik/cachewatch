import Foundation
import Testing
import CollectorEngine

@Suite
struct SourceTests {
    // MARK: - Process tree memory

    @Test
    func subtreeRSSSumsSessionAndDescendants() throws {
        let table: [ProcessSample] = [
            ProcessSample(pid: 100, ppid: 1, rssBytes: 500_000_000),   // session
            ProcessSample(pid: 200, ppid: 100, rssBytes: 120_000_000), // mcp server
            ProcessSample(pid: 300, ppid: 200, rssBytes: 30_000_000),  // mcp child
            ProcessSample(pid: 999, ppid: 1, rssBytes: 999_000_000),   // unrelated
        ]
        #expect(ProcessTree.subtreeRSS(of: 100, in: table) == 650_000_000, "subtree sum")
        #expect(ProcessTree.subtreeRSS(of: 999, in: table) == 999_000_000, "leaf")
        #expect(ProcessTree.subtreeRSS(of: 777, in: table) == 0, "unknown pid")
    }

    @Test
    func parsesPsOutput() throws {
        let ps = """
          100     1  488281
          200   100  117187
        badline
        """
        let samples = ProcessTree.parsePS(ps)
        #expect(samples.count == 2, "row count")
        #expect(samples.first?.rssBytes == 488_281 * 1024, "rss kb to bytes")
    }

    // MARK: - Registry scanning

    @Test
    func registryScanFiltersDeadPids() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-reg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (pid, sid) in [(101, "alive"), (102, "dead")] {
            let json = """
            {"pid":\(pid),"sessionId":"\(sid)","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}
            """
            try Data(json.utf8).write(to: dir.appending(path: "\(pid).json"))
        }
        try Data("garbage".utf8).write(to: dir.appending(path: "broken.json"))

        let entries = RegistryScanner.scan(directory: dir, isAlive: { $0 == 101 })
        #expect(entries.count == 1, "only live sessions")
        #expect(entries.first?.sessionId == "alive", "live session id")
    }

    @Test
    func emptyReadableRegistryIsHealthy() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-reg-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = RegistryScanner.scanReport(directory: dir, checkedAt: .now)
        #expect(result.entries.isEmpty)
        #expect(result.health.condition == .healthy)
        #expect(result.health.recordsSeen == 0)
    }

    @Test
    func malformedRegistryIsDegradedButDeadPidIsExpected() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-reg-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(#"{"pid":102,"sessionId":"dead","cwd":"/tmp","status":"idle","startedAt":1784472863002,"updatedAt":1784486708811}"#.utf8)
            .write(to: dir.appending(path: "102.json"))
        var result = RegistryScanner.scanReport(directory: dir, checkedAt: .now, isAlive: { _ in false })
        #expect(result.health.condition == .healthy)
        #expect(result.health.recordsDropped == 0)

        try Data("garbage".utf8).write(to: dir.appending(path: "broken.json"))
        result = RegistryScanner.scanReport(directory: dir, checkedAt: .now, isAlive: { _ in false })
        #expect(result.health.condition == .degraded)
        #expect(result.health.recordsDropped == 1)
    }

    @Test
    func missingRegistryIsUnavailable() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "cw-missing-\(UUID().uuidString)")
        let result = RegistryScanner.scanReport(directory: missing, checkedAt: .now)
        #expect(result.entries.isEmpty)
        #expect(result.health.condition == .unavailable)
    }

    // MARK: - Transcript tailing

    @Test
    func tailerEmitsOnlyNewCompleteLines() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-tail-\(UUID().uuidString)")
        let projectDir = dir.appending(path: "-tmp-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = projectDir.appending(path: "abc.jsonl")
        func turnLine(_ ts: String) -> String {
            """
            {"type":"assistant","sessionId":"abc","timestamp":"\(ts)","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":10,"output_tokens":1}}}
            """
        }

        var tailer = TranscriptTailer(directory: dir)
        try Data((turnLine("2026-07-19T10:00:00.000Z") + "\n").utf8).write(to: file)
        let first = tailer.poll()
        #expect(first.count == 1, "first poll emits one turn")

        #expect(tailer.poll().count == 0, "no re-emission without new data")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((turnLine("2026-07-19T10:01:00.000Z") + "\n" + "{\"partial").utf8))
        try handle.close()
        let second = tailer.poll()
        #expect(second.count == 1, "only the complete new line")

        let handle2 = try FileHandle(forWritingTo: file)
        handle2.seekToEndOfFile()
        handle2.write(Data("-line\":1}\n".utf8))
        try handle2.close()
        #expect(tailer.poll().count == 0, "completed partial line is not an assistant turn")
    }

    @Test
    func transcriptReportCountsMalformedButAcceptsKnownNonAssistantLines() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-tail-health-\(UUID().uuidString)")
        let projectDir = dir.appending(path: "-tmp-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let contents = """
        {"type":"assistant","sessionId":"abc","timestamp":"2026-07-19T10:00:00.000Z","message":{"model":"m"}}
        {"type":"user","sessionId":"abc","timestamp":"2026-07-19T10:00:01.000Z","message":{"content":"private prompt"}}
        {"type":"assistant","message":{"model":"changed-schema"}}
        not-json
        """
        try Data((contents + "\n").utf8).write(to: projectDir.appending(path: "abc.jsonl"))

        var tailer = TranscriptTailer(directory: dir)
        let result = tailer.pollReport(checkedAt: .now)
        #expect(result.turns.count == 1)
        #expect(result.filesScanned == 1)
        #expect(result.completedLinesRead == 4)
        #expect(result.rejectedLines == 2)
        #expect(result.health.condition == .degraded)
        #expect(result.health.recordsSeen == 4)
        #expect(result.health.recordsAccepted == 2)
        #expect(result.health.recordsDropped == 2)
        #expect(result.health.message?.contains("private prompt") == false)
    }

    @Test
    func transcriptSourceRecoversAfterDirectoryAppears() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-tail-recover-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var tailer = TranscriptTailer(directory: dir)

        let unavailable = tailer.pollReport(checkedAt: .now)
        #expect(unavailable.health.condition == .unavailable)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let recovered = tailer.pollReport(checkedAt: .now)
        #expect(recovered.health.condition == .healthy)
        #expect(recovered.health.recordsSeen == 0)
    }

    @Test
    func processSamplingReportsUnavailableExecutable() {
        let result = ProcessTree.sampleReport(
            checkedAt: .now,
            executableURL: URL(fileURLWithPath: "/definitely/missing/ps")
        )
        #expect(result.samples.isEmpty)
        #expect(result.health.condition == .unavailable)
    }
}
