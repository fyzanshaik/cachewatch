import Foundation

public struct CollectorConfig: Sendable {
    public var claudeDir: URL
    public var socketPath: String
    public var registryInterval: Duration = .seconds(2)
    public var transcriptInterval: Duration = .seconds(2)
    public var memoryInterval: Duration = .seconds(5)

    public init(
        claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
        socketPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".cachewatch/statusline.sock")
    ) {
        self.claudeDir = claudeDir
        self.socketPath = socketPath
    }

    var sessionsDir: URL { claudeDir.appending(path: "sessions") }
    var projectsDir: URL { claudeDir.appending(path: "projects") }
}

/// Owns the reducer and all sources; publishes a FleetSnapshot stream for any UI to render.
public actor Collector {
    private let config: CollectorConfig
    private var reducer = FleetReducer()
    private var continuations: [UUID: AsyncStream<FleetSnapshot>.Continuation] = [:]
    private var lastPublished: FleetSnapshot?
    private var started = false

    public init(
        config: CollectorConfig = CollectorConfig(),
        calibration: QuotaCalibrator = QuotaCalibrator(),
        rateLimits: StatuslinePayload.RateLimits? = nil,
        rateLimitsAsOf: Date? = nil
    ) {
        self.config = config
        self.reducer = FleetReducer(calibration: calibration, rateLimits: rateLimits, rateLimitsAsOf: rateLimitsAsOf)
    }

    public var snapshots: AsyncStream<FleetSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            if let last = lastPublished {
                continuation.yield(last)
            }
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }

    public func start() {
        guard !started else { return }
        started = true
        let config = config

        Task {
            while !Task.isCancelled {
                let report = RegistryScanner.scanReport(directory: config.sessionsDir)
                var events: [CollectorEvent] = [.sourceHealth(report.health)]
                if report.shouldReplaceSnapshot {
                    events.insert(.registrySnapshot(report.entries), at: 0)
                }
                self.apply(events)
                try? await Task.sleep(for: config.registryInterval)
            }
        }
        Task {
            // First poll ingests full history so context/TTL state is correct from launch.
            var tailer = TranscriptTailer(directory: config.projectsDir)
            while !Task.isCancelled {
                let report = tailer.pollReport()
                self.apply(
                    report.turns.map(CollectorEvent.assistantTurn)
                        + [.sourceHealth(report.health)]
                )
                try? await Task.sleep(for: config.transcriptInterval)
            }
        }
        Task {
            while !Task.isCancelled {
                let report = ProcessTree.sampleAllReport()
                var events: [CollectorEvent] = []
                let sessionPIDs = Dictionary(
                    uniqueKeysWithValues: self.reducer.snapshot.sessions.map { ($0.id, $0.pid) }
                )
                for sample in report.sessionSamples(for: sessionPIDs) {
                    events.append(.memorySample(
                        pid: sample.pid,
                        residentBytes: sample.residentBytes,
                        host: sample.host
                    ))
                }
                events.append(.sourceHealth(report.health))
                self.apply(events)
                try? await Task.sleep(for: config.memoryInterval)
            }
        }
        Task {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: config.socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for await event in StatuslineListener.recoveringEvents(socketPath: config.socketPath) {
                let now = Date()
                switch event {
                case .listening:
                    self.apply(.sourceHealth(Self.statuslineConfigurationHealth(config: config, at: now)))
                case .payload(let payload):
                    self.apply([
                        .statusline(payload, receivedAt: now),
                        .sourceHealth(SourceHealth(
                            id: .statusline,
                            condition: .healthy,
                            lastAttemptAt: now,
                            lastSuccessAt: now,
                            recordsSeen: 1,
                            recordsAccepted: 1
                        )),
                    ])
                case .rejectedPayload:
                    self.apply(.sourceHealth(SourceHealth(
                        id: .statusline,
                        condition: .degraded,
                        lastAttemptAt: now,
                        lastSuccessAt: self.lastStatuslineSuccess,
                        recordsSeen: 1,
                        recordsDropped: 1,
                        message: "A statusline payload was not recognized. Quota data may be incomplete."
                    )))
                case .failed(let failure):
                    self.apply(.sourceHealth(SourceHealth(
                        id: .statusline,
                        condition: .unavailable,
                        lastAttemptAt: now,
                        lastSuccessAt: self.lastStatuslineSuccess,
                        message: failure.guidance
                    )))
                }
            }
        }
    }

    private func apply(_ event: CollectorEvent) {
        apply([event])
    }

    private func apply(_ events: [CollectorEvent]) {
        for event in events {
            reducer.apply(event)
        }
        let snapshot = reducer.snapshot
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private var lastStatuslineSuccess: Date? {
        reducer.snapshot.sourceHealth(for: .statusline)?.lastSuccessAt
    }

    private static func statuslineConfigurationHealth(
        config: CollectorConfig,
        at attemptedAt: Date
    ) -> SourceHealth {
        let settings = config.claudeDir.appending(path: "settings.json")
        guard FileManager.default.fileExists(atPath: settings.path) else {
            return SourceHealth(
                id: .statusline,
                condition: .notConfigured,
                lastAttemptAt: attemptedAt,
                message: "Run cachewatch setup to enable quota data."
            )
        }
        guard let data = try? Data(contentsOf: settings) else {
            return SourceHealth(
                id: .statusline,
                condition: .unavailable,
                lastAttemptAt: attemptedAt,
                message: "Claude settings could not be read, so statusline configuration is unknown."
            )
        }
        switch StatuslineSetup.configurationState(in: data) {
        case .configured:
            return SourceHealth(
                id: .statusline,
                condition: .healthy,
                lastAttemptAt: attemptedAt
            )
        case .notConfigured:
            return SourceHealth(
                id: .statusline,
                condition: .notConfigured,
                lastAttemptAt: attemptedAt,
                message: "Run cachewatch setup to enable quota data."
            )
        case .unreadable:
            return SourceHealth(
                id: .statusline,
                condition: .unavailable,
                lastAttemptAt: attemptedAt,
                message: "Claude settings are malformed, so statusline configuration is unknown."
            )
        }
    }

    /// One-shot snapshot from a single pass over all file-based sources (no socket data).
    public static func dump(config: CollectorConfig = CollectorConfig()) -> FleetSnapshot {
        var reducer = FleetReducer()
        let registry = RegistryScanner.scanReport(directory: config.sessionsDir)
        reducer.apply(.registrySnapshot(registry.entries))
        reducer.apply(.sourceHealth(registry.health))
        var tailer = TranscriptTailer(directory: config.projectsDir)
        let transcripts = tailer.pollReport()
        for turn in transcripts.turns {
            reducer.apply(.assistantTurn(turn))
        }
        reducer.apply(.sourceHealth(transcripts.health))
        let process = ProcessTree.sampleAllReport()
        let sessionPIDs = Dictionary(
            uniqueKeysWithValues: reducer.snapshot.sessions.map { ($0.id, $0.pid) }
        )
        for sample in process.sessionSamples(for: sessionPIDs) {
            reducer.apply(.memorySample(
                pid: sample.pid,
                residentBytes: sample.residentBytes,
                host: sample.host
            ))
        }
        reducer.apply(.sourceHealth(process.health))
        reducer.apply(.sourceHealth(statuslineConfigurationHealth(config: config, at: Date())))
        return reducer.snapshot
    }
}
