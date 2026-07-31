import Foundation
import Testing
import CollectorEngine

@Suite
struct SourceTests {
    let base = Date(timeIntervalSince1970: 1_784_500_000)

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

    @Test
    func processReportDistinguishesSuccessFromCommandFailure() {
        let healthy = ProcessTree.report(
            psOutput: "  100  1  42 /bin/process\ninvalid\n",
            terminationStatus: 0,
            at: base
        )
        #expect(healthy.samples.count == 1)
        #expect(healthy.health.condition == .degraded)
        #expect(healthy.health.recordsSeen == 2)
        #expect(healthy.health.recordsAccepted == 1)
        #expect(healthy.health.recordsDropped == 1)

        let unavailable = ProcessTree.report(
            psOutput: "",
            terminationStatus: 1,
            at: base
        )
        #expect(unavailable.samples.isEmpty)
        #expect(unavailable.health.condition == .unavailable)
        #expect(unavailable.health.lastSuccessAt == nil)
    }

    @Test
    func unavailableProcessReportProducesNoFabricatedMemoryUpdates() {
        let report = ProcessTree.report(
            psOutput: "",
            terminationStatus: 1,
            at: base
        )

        #expect(report.sessionSamples(for: ["session-1": 42]).isEmpty)
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

        let result = RegistryScanner.scanReport(directory: dir, isAlive: { $0 == 101 }, at: base)
        #expect(result.entries.count == 1, "only live sessions")
        #expect(result.entries.first?.sessionId == "alive", "live session id")
        #expect(result.health.condition == .degraded)
        #expect(result.health.recordsSeen == 3)
        #expect(result.health.recordsAccepted == 1)
        #expect(result.health.recordsDropped == 1)

        try FileManager.default.removeItem(at: dir.appending(path: "broken.json"))
        let recovered = RegistryScanner.scanReport(
            directory: dir,
            isAlive: { $0 == 101 },
            at: base.addingTimeInterval(2)
        )
        #expect(recovered.health.condition == .healthy)
        #expect(recovered.health.recordsAccepted == 1)
    }

    @Test
    func registryEmptyIsHealthyButMissingDirectoryIsUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-reg-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = RegistryScanner.scanReport(directory: dir, at: base)
        #expect(empty.entries.isEmpty)
        #expect(empty.health.condition == .healthy)
        #expect(empty.health.lastSuccessAt == base)

        let missing = RegistryScanner.scanReport(
            directory: dir.appending(path: "missing"),
            at: base
        )
        #expect(missing.entries.isEmpty)
        #expect(missing.health.condition == .unavailable)
        #expect(missing.health.lastSuccessAt == nil)
        #expect(missing.shouldReplaceSnapshot == false)
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
    func transcriptReportCountsMalformedLinesAndRecovers() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-tail-health-\(UUID().uuidString)")
        let projectDir = dir.appending(path: "-tmp-project")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = projectDir.appending(path: "abc.jsonl")
        try Data("""
        {"type":"user","sessionId":"abc","timestamp":"2026-07-19T09:59:00.000Z"}
        private malformed transcript content

        """.utf8).write(to: file)

        var tailer = TranscriptTailer(directory: dir)
        let degraded = tailer.pollReport(at: base)
        #expect(degraded.turns.isEmpty)
        #expect(degraded.filesScanned == 1)
        #expect(degraded.completedLinesRead == 2)
        #expect(degraded.ignoredLines == 1)
        #expect(degraded.rejectedLines == 1)
        #expect(degraded.health.condition == .degraded)
        #expect(degraded.health.lastSuccessAt == nil)
        #expect(degraded.health.message?.contains("private malformed") == false)

        let stillDegraded = tailer.pollReport(at: base.addingTimeInterval(1))
        #expect(stillDegraded.completedLinesRead == 0)
        #expect(stillDegraded.health.condition == .degraded)
        #expect(stillDegraded.health.lastSuccessAt == nil)

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("""
        {"type":"assistant","sessionId":"abc","timestamp":"2026-07-19T10:00:00.000Z","isSidechain":false,"message":{"model":"m","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":10,"output_tokens":1}}}

        """.utf8))
        try handle.close()

        let recovered = tailer.pollReport(at: base.addingTimeInterval(2))
        #expect(recovered.turns.count == 1)
        #expect(recovered.rejectedLines == 0)
        #expect(recovered.health.condition == .healthy)
        #expect(recovered.health.lastSuccessAt == base.addingTimeInterval(2))
    }

    @Test
    func transcriptMissingDirectoryIsUnavailable() {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cw-tail-missing-\(UUID().uuidString)")
        var tailer = TranscriptTailer(directory: dir)
        let report = tailer.pollReport(at: base)

        #expect(report.turns.isEmpty)
        #expect(report.health.condition == .unavailable)
        #expect(report.readFailures == 1)
    }
}
