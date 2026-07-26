import Foundation
import Testing
import CollectorEngine

@Suite
struct HealthTests {
    let now = Date(timeIntervalSince1970: 1_784_500_000)

    @Test
    func reducerExposesEverySourceAndRecoveryClearsWarning() {
        var reducer = FleetReducer()
        for id in SourceID.allCases {
            reducer.apply(.sourceHealth(SourceHealth(
                id: id,
                condition: .healthy,
                lastAttemptAt: now,
                lastSuccessAt: now,
                recordsSeen: 1,
                recordsAccepted: 1
            )))
        }

        #expect(reducer.snapshot.sourceHealth.count == SourceID.allCases.count)
        #expect(reducer.snapshot.hasSourceWarning(at: now) == false)

        reducer.apply(.sourceHealth(SourceHealth(
            id: .transcripts,
            condition: .degraded,
            lastAttemptAt: now.addingTimeInterval(2),
            recordsSeen: 4,
            recordsAccepted: 2,
            recordsDropped: 2,
            message: "2 completed lines were unrecognized."
        )))
        #expect(reducer.snapshot.hasSourceWarning(at: now.addingTimeInterval(2)))
        #expect(reducer.snapshot.health(for: .transcripts)?.lastSuccessAt == now)

        let recoveredAt = now.addingTimeInterval(4)
        reducer.apply(.sourceHealth(SourceHealth(
            id: .transcripts,
            condition: .healthy,
            lastAttemptAt: recoveredAt,
            lastSuccessAt: recoveredAt,
            recordsSeen: 3,
            recordsAccepted: 3
        )))
        #expect(reducer.snapshot.hasSourceWarning(at: recoveredAt) == false)
        #expect(reducer.snapshot.health(for: .transcripts)?.recordsDropped == 0)
    }

    @Test
    func postSuccessStatuslineSilenceBecomesStaleButUnconfiguredDoesNot() {
        let statusline = SourceHealth(
            id: .statusline,
            condition: .healthy,
            lastAttemptAt: now,
            lastSuccessAt: now,
            recordsSeen: 1,
            recordsAccepted: 1,
            staleAfter: 180
        )
        #expect(statusline.condition(at: now.addingTimeInterval(179)) == .healthy)
        #expect(statusline.condition(at: now.addingTimeInterval(181)) == .stale)

        let configuredWithoutPayloads = SourceHealth(
            id: .statusline,
            condition: .healthy,
            lastAttemptAt: now,
            staleAfter: 180
        )
        #expect(configuredWithoutPayloads.condition(at: now.addingTimeInterval(181)) == .stale)

        let unconfigured = SourceHealth(
            id: .statusline,
            condition: .notConfigured,
            lastAttemptAt: now,
            message: "Run cachewatch setup to enable quota data."
        )
        #expect(unconfigured.condition(at: now.addingTimeInterval(10_000)) == .notConfigured)
        #expect(unconfigured.isWarning(at: now.addingTimeInterval(10_000)) == false)
    }

    @Test
    func diagnosticsAreCopyableAndContainNoSessionDetails() {
        var fleet = FleetSnapshot()
        fleet.sourceHealth = [
            SourceHealth(
                id: .registry,
                condition: .healthy,
                lastAttemptAt: now,
                lastSuccessAt: now,
                recordsSeen: 2,
                recordsAccepted: 2
            ),
            SourceHealth(
                id: .transcripts,
                condition: .degraded,
                lastAttemptAt: now,
                recordsSeen: 3,
                recordsAccepted: 2,
                recordsDropped: 1,
                message: "1 completed line was unrecognized."
            ),
        ]

        let summary = fleet.diagnosticSummary(at: now)
        #expect(summary.contains("Session registry: healthy"))
        #expect(summary.contains("Transcripts: degraded"))
        #expect(summary.contains("seen=3 | accepted=2 | dropped=1"))
        #expect(summary.contains("/Users/") == false)
        #expect(summary.contains("sessionId") == false)
    }

    @Test
    func dumpReportsAllSourcesForReadableEmptyDirectories() throws {
        let claudeDir = FileManager.default.temporaryDirectory
            .appending(path: "cw-dump-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: claudeDir.appending(path: "sessions"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeDir.appending(path: "projects"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: claudeDir) }

        let snapshot = Collector.dump(config: CollectorConfig(
            claudeDir: claudeDir,
            socketPath: claudeDir.appending(path: "statusline.sock").path
        ))
        #expect(Set(snapshot.sourceHealth.map(\.id)) == Set(SourceID.allCases))
        #expect(snapshot.health(for: .registry)?.condition == .healthy)
        #expect(snapshot.health(for: .transcripts)?.condition == .healthy)
        #expect(snapshot.health(for: .process)?.condition == .healthy)
        #expect(snapshot.health(for: .statusline)?.condition == .notConfigured)
    }
}
