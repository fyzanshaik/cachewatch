import Foundation
import CollectorEngine

func runSourceTests(_ t: TestKit) {
    // MARK: - Process tree memory

    t.run("subtreeRSSSumsSessionAndDescendants") { t in
        let table: [ProcessSample] = [
            ProcessSample(pid: 100, ppid: 1, rssBytes: 500_000_000),   // session
            ProcessSample(pid: 200, ppid: 100, rssBytes: 120_000_000), // mcp server
            ProcessSample(pid: 300, ppid: 200, rssBytes: 30_000_000),  // mcp child
            ProcessSample(pid: 999, ppid: 1, rssBytes: 999_000_000),   // unrelated
        ]
        t.expectEqual(ProcessTree.subtreeRSS(of: 100, in: table), 650_000_000, "subtree sum")
        t.expectEqual(ProcessTree.subtreeRSS(of: 999, in: table), 999_000_000, "leaf")
        t.expectEqual(ProcessTree.subtreeRSS(of: 777, in: table), 0, "unknown pid")
    }

    t.run("parsesPsOutput") { t in
        let ps = """
          100     1  488281
          200   100  117187
        badline
        """
        let samples = ProcessTree.parsePS(ps)
        t.expectEqual(samples.count, 2, "row count")
        t.expectEqual(samples.first?.rssBytes, 488_281 * 1024, "rss kb to bytes")
    }

    // MARK: - Registry scanning

    t.run("registryScanFiltersDeadPids") { t in
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
        t.expectEqual(entries.count, 1, "only live sessions")
        t.expectEqual(entries.first?.sessionId, "alive", "live session id")
    }

    // MARK: - Transcript tailing

    t.run("tailerEmitsOnlyNewCompleteLines") { t in
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
        t.expectEqual(first.count, 1, "first poll emits one turn")

        t.expectEqual(tailer.poll().count, 0, "no re-emission without new data")

        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((turnLine("2026-07-19T10:01:00.000Z") + "\n" + "{\"partial").utf8))
        try handle.close()
        let second = tailer.poll()
        t.expectEqual(second.count, 1, "only the complete new line")

        let handle2 = try FileHandle(forWritingTo: file)
        handle2.seekToEndOfFile()
        handle2.write(Data("-line\":1}\n".utf8))
        try handle2.close()
        t.expectEqual(tailer.poll().count, 0, "completed partial line is not an assistant turn")
    }
}
