import Foundation
import Testing
import CollectorEngine

@Suite
struct SourceHealthTests {
    let base = Date(timeIntervalSince1970: 1_784_500_000)

    @Test
    func healthyEmptySourceIsNotACollectionFailure() {
        let health = SourceHealth(
            id: .registry,
            condition: .healthy,
            lastAttemptAt: base,
            lastSuccessAt: base,
            recordsSeen: 0,
            recordsAccepted: 0,
            recordsDropped: 0
        )

        #expect(health.currentCondition(at: base.addingTimeInterval(5)) == .healthy)
        #expect(health.recordsSeen == 0)
    }

    @Test
    func healthySourcesBecomeStaleAtSourceSpecificBoundaries() {
        let registry = SourceHealth(
            id: .registry,
            condition: .healthy,
            lastAttemptAt: base,
            lastSuccessAt: base
        )
        let statusline = SourceHealth(
            id: .statusline,
            condition: .healthy,
            lastAttemptAt: base,
            lastSuccessAt: nil
        )

        #expect(registry.currentCondition(at: base.addingTimeInterval(9)) == .healthy)
        #expect(registry.currentCondition(at: base.addingTimeInterval(11)) == .stale)
        #expect(statusline.currentCondition(at: base.addingTimeInterval(14 * 60)) == .healthy)
        #expect(statusline.currentCondition(at: base.addingTimeInterval(16 * 60)) == .stale)
    }

    @Test
    func optionalStatuslineNotConfiguredNeverBecomesRuntimeFailure() {
        let health = SourceHealth(
            id: .statusline,
            condition: .notConfigured,
            lastAttemptAt: base,
            message: "Run cachewatch setup to enable quota data."
        )

        #expect(health.currentCondition(at: base.addingTimeInterval(24 * 60 * 60)) == .notConfigured)
        #expect(health.isWarning(at: base.addingTimeInterval(24 * 60 * 60)) == false)
    }

    @Test
    func reducerPublishesDegradationAndRecovery() {
        var reducer = FleetReducer()
        reducer.apply(.sourceHealth(SourceHealth(
            id: .transcripts,
            condition: .degraded,
            lastAttemptAt: base,
            lastSuccessAt: base.addingTimeInterval(-60),
            recordsSeen: 12,
            recordsAccepted: 0,
            recordsDropped: 12,
            message: "New transcript records were not recognized."
        )))

        #expect(reducer.snapshot.sourceHealth(for: .transcripts)?.condition == .degraded)
        #expect(reducer.snapshot.warningSources(at: base).map(\.id) == [.transcripts])

        reducer.apply(.sourceHealth(SourceHealth(
            id: .transcripts,
            condition: .healthy,
            lastAttemptAt: base.addingTimeInterval(2),
            lastSuccessAt: base.addingTimeInterval(2),
            recordsSeen: 1,
            recordsAccepted: 1
        )))

        #expect(reducer.snapshot.sourceHealth(for: .transcripts)?.condition == .healthy)
        #expect(reducer.snapshot.warningSources(at: base.addingTimeInterval(2)).isEmpty)
    }

    @Test
    func reducerPreservesLastSuccessWhenASourceBecomesUnavailable() {
        var reducer = FleetReducer()
        reducer.apply(.sourceHealth(SourceHealth(
            id: .registry,
            condition: .healthy,
            lastAttemptAt: base,
            lastSuccessAt: base
        )))
        reducer.apply(.sourceHealth(SourceHealth(
            id: .registry,
            condition: .unavailable,
            lastAttemptAt: base.addingTimeInterval(2)
        )))

        #expect(reducer.snapshot.sourceHealth(for: .registry)?.lastSuccessAt == base)
    }

    @Test
    func diagnosticsAreStableAndExcludeFreeFormMessages() {
        var reducer = FleetReducer()
        reducer.apply(.sourceHealth(SourceHealth(
            id: .transcripts,
            condition: .degraded,
            lastAttemptAt: base,
            recordsSeen: 12,
            recordsAccepted: 0,
            recordsDropped: 12,
            message: "private-path-or-content-must-not-be-copied"
        )))
        reducer.apply(.sourceHealth(SourceHealth(
            id: .registry,
            condition: .healthy,
            lastAttemptAt: base,
            lastSuccessAt: base,
            recordsSeen: 0
        )))

        let summary = reducer.snapshot.diagnosticsSummary(at: base)
        #expect(summary.contains("registry: healthy; seen=0; accepted=0; dropped=0"))
        #expect(summary.contains("transcripts: degraded; seen=12; accepted=0; dropped=12"))
        #expect(summary.contains("private-path-or-content-must-not-be-copied") == false)
        #expect(summary.range(of: "registry")!.lowerBound < summary.range(of: "transcripts")!.lowerBound)
    }

    @Test
    func metricQualifiersReflectEffectiveCondition() {
        var snapshot = FleetSnapshot()
        snapshot.sourceHealth = [
            SourceHealth(
                id: .transcripts,
                condition: .degraded,
                lastAttemptAt: base,
                lastSuccessAt: base
            ),
            SourceHealth(
                id: .process,
                condition: .healthy,
                lastAttemptAt: base,
                lastSuccessAt: base
            ),
            SourceHealth(
                id: .statusline,
                condition: .notConfigured,
                lastAttemptAt: base
            ),
        ]

        #expect(snapshot.metricQualifier(for: .transcripts, at: base) == "incomplete")
        #expect(snapshot.metricQualifier(for: .process, at: base) == nil)
        #expect(snapshot.metricQualifier(for: .process, at: base.addingTimeInterval(21)) == "stale")
        #expect(snapshot.metricQualifier(for: .statusline, at: base) == "unavailable")
    }

    @Test
    func sessionMetricProvenanceMapsCostToStatusline() {
        #expect(SessionMetric.context.source == .transcripts)
        #expect(SessionMetric.cache.source == .transcripts)
        #expect(SessionMetric.cost.source == .statusline)
        #expect(SessionMetric.memory.source == .process)
    }
}
