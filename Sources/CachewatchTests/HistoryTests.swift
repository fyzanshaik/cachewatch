import Foundation
import CollectorEngine

func runHistoryTests(_ t: TestKit) {
    let base = Date(timeIntervalSince1970: 1_785_100_000)

    func tempStore() -> QuotaHistoryStore {
        QuotaHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appending(path: "cw-hist-\(UUID().uuidString).jsonl"))
    }

    func sample(at date: Date, used: Double) -> QuotaSample {
        QuotaSample(
            recordedAt: date,
            fiveHourUsedPercentage: used,
            fiveHourResetsAt: date.addingTimeInterval(3600),
            sevenDayUsedPercentage: 50,
            sevenDayResetsAt: date.addingTimeInterval(200_000),
            cumulativeTurnCostUSD: 12.5
        )
    }

    t.run("appendsAndLoadsSamples") { t in
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        store.append(sample(at: base, used: 10))
        store.append(sample(at: base.addingTimeInterval(60), used: 12))
        let loaded = store.load()
        t.expectEqual(loaded.count, 2, "two samples")
        t.expectEqual(loaded.first?.fiveHourUsedPercentage, 10, "first sample")
        t.expectEqual(loaded.last?.recordedAt, base.addingTimeInterval(60), "ordering")
    }

    t.run("pruneDropsOldEntriesAndSurvivesGarbageLines") { t in
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL) }
        store.append(sample(at: base.addingTimeInterval(-40 * 86_400), used: 5))
        store.append(sample(at: base.addingTimeInterval(-5 * 86_400), used: 7))
        try "not json\n".appendLine(to: store.fileURL)
        store.append(sample(at: base, used: 9))
        store.prune(olderThan: 30 * 86_400, now: base)
        let kept = store.load()
        t.expectEqual(kept.count, 2, "old and garbage dropped")
        t.expectEqual(kept.first?.fiveHourUsedPercentage, 7, "recent kept")
    }
}

private extension String {
    func appendLine(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(Data(utf8))
    }
}
