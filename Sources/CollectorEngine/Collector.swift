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
    var settingsFile: URL { claudeDir.appending(path: "settings.json") }
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
                let result = RegistryScanner.scanReport(directory: config.sessionsDir, checkedAt: Date())
                self.apply(.registrySnapshot(result.entries))
                self.apply(.sourceHealth(result.health))
                try? await Task.sleep(for: config.registryInterval)
            }
        }
        Task {
            // First poll ingests full history so context/TTL state is correct from launch.
            var tailer = TranscriptTailer(directory: config.projectsDir)
            while !Task.isCancelled {
                let result = tailer.pollReport(checkedAt: Date())
                for turn in result.turns {
                    self.apply(.assistantTurn(turn))
                }
                self.apply(.sourceHealth(result.health))
                try? await Task.sleep(for: config.transcriptInterval)
            }
        }
        Task {
            while !Task.isCancelled {
                let checkedAt = Date()
                let result = ProcessTree.sampleReport(checkedAt: checkedAt)
                let sessions = self.reducer.snapshot.sessions
                let table = result.samples
                for session in sessions {
                    guard table.contains(where: { $0.pid == session.pid }) else { continue }
                    self.apply(.memorySample(
                        pid: session.pid,
                        residentBytes: ProcessTree.subtreeRSS(of: session.pid, in: table),
                        host: ProcessTree.hostApp(of: session.pid, in: table)
                    ))
                }
                self.apply(.sourceHealth(Self.processHealth(
                    result: result,
                    sessions: sessions,
                    checkedAt: checkedAt
                )))
                try? await Task.sleep(for: config.memoryInterval)
            }
        }
        Task {
            var seen = 0
            var accepted = 0
            var dropped = 0
            while !Task.isCancelled {
                let settings = try? Data(contentsOf: config.settingsFile)
                let configured = settings.map(StatuslineSetup.isCachewatchConfigured(in:)) ?? false
                do {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: config.socketPath).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                } catch {
                    if configured {
                        self.apply(.sourceHealth(SourceHealth(
                            id: .statusline,
                            condition: .unavailable,
                            lastAttemptAt: Date(),
                            recordsSeen: seen,
                            recordsAccepted: accepted,
                            recordsDropped: dropped,
                            message: "The statusline socket directory could not be created.",
                            staleAfter: 180
                        )))
                    } else {
                        self.apply(.sourceHealth(Self.statuslineWaitingHealth(configured: false, at: Date())))
                    }
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }

                for await event in StatuslineListener.events(socketPath: config.socketPath) {
                    let now = Date()
                    switch event {
                    case .listening:
                        self.apply(.sourceHealth(Self.statuslineWaitingHealth(
                            configured: configured,
                            at: now
                        )))
                    case .payload(let payload):
                        seen += 1
                        accepted += 1
                        self.apply(.statusline(payload, receivedAt: now))
                        self.apply(.sourceHealth(SourceHealth(
                            id: .statusline,
                            condition: .healthy,
                            lastAttemptAt: now,
                            lastSuccessAt: now,
                            recordsSeen: seen,
                            recordsAccepted: accepted,
                            recordsDropped: dropped,
                            staleAfter: 180
                        )))
                    case .rejectedPayload:
                        seen += 1
                        dropped += 1
                        self.apply(.sourceHealth(SourceHealth(
                            id: .statusline,
                            condition: .degraded,
                            lastAttemptAt: now,
                            recordsSeen: seen,
                            recordsAccepted: accepted,
                            recordsDropped: dropped,
                            message: "\(dropped) statusline \(dropped == 1 ? "payload was" : "payloads were") unrecognized.",
                            staleAfter: 180
                        )))
                    case .unavailable(let message):
                        guard configured else { continue }
                        self.apply(.sourceHealth(SourceHealth(
                            id: .statusline,
                            condition: .unavailable,
                            lastAttemptAt: now,
                            recordsSeen: seen,
                            recordsAccepted: accepted,
                            recordsDropped: dropped,
                            message: message,
                            staleAfter: 180
                        )))
                    }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func apply(_ event: CollectorEvent) {
        reducer.apply(event)
        let snapshot = reducer.snapshot
        guard snapshot != lastPublished else { return }
        lastPublished = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private static func statuslineWaitingHealth(configured: Bool, at now: Date) -> SourceHealth {
        SourceHealth(
            id: .statusline,
            condition: configured ? .healthy : .notConfigured,
            lastAttemptAt: now,
            message: configured
                ? "Waiting for the first statusline payload."
                : "Run cachewatch setup to enable quota data.",
            staleAfter: configured ? 180 : nil
        )
    }

    private static func processHealth(
        result: ProcessSampleResult,
        sessions: [SessionSnapshot],
        checkedAt: Date
    ) -> SourceHealth {
        let sampled = sessions.count { session in
            result.samples.contains { $0.pid == session.pid }
        }
        let missing = sessions.count - sampled
        guard result.health.condition != .unavailable else {
            return SourceHealth(
                id: .process,
                condition: .unavailable,
                lastAttemptAt: checkedAt,
                recordsSeen: sessions.count,
                recordsAccepted: 0,
                recordsDropped: sessions.count,
                message: result.health.message
            )
        }

        let degraded = result.health.condition == .degraded || missing > 0
        var messages: [String] = []
        if let message = result.health.message { messages.append(message) }
        if missing > 0 {
            messages.append("\(missing) live session \(missing == 1 ? "PID was" : "PIDs were") not found.")
        }
        return SourceHealth(
            id: .process,
            condition: degraded ? .degraded : .healthy,
            lastAttemptAt: checkedAt,
            lastSuccessAt: degraded ? nil : checkedAt,
            recordsSeen: sessions.count,
            recordsAccepted: sampled,
            recordsDropped: missing,
            message: messages.isEmpty ? nil : messages.joined(separator: " ")
        )
    }

    /// One-shot snapshot from a single pass over all file-based sources (no socket data).
    public static func dump(config: CollectorConfig = CollectorConfig()) -> FleetSnapshot {
        var reducer = FleetReducer()
        let registry = RegistryScanner.scanReport(directory: config.sessionsDir, checkedAt: Date())
        reducer.apply(.registrySnapshot(registry.entries))
        reducer.apply(.sourceHealth(registry.health))
        var tailer = TranscriptTailer(directory: config.projectsDir)
        let transcripts = tailer.pollReport(checkedAt: Date())
        for turn in transcripts.turns {
            reducer.apply(.assistantTurn(turn))
        }
        reducer.apply(.sourceHealth(transcripts.health))
        let processCheckedAt = Date()
        let processes = ProcessTree.sampleReport(checkedAt: processCheckedAt)
        let table = processes.samples
        let sessions = reducer.snapshot.sessions
        for session in sessions {
            guard table.contains(where: { $0.pid == session.pid }) else { continue }
            reducer.apply(.memorySample(
                pid: session.pid,
                residentBytes: ProcessTree.subtreeRSS(of: session.pid, in: table),
                host: ProcessTree.hostApp(of: session.pid, in: table)
            ))
        }
        reducer.apply(.sourceHealth(processHealth(
            result: processes,
            sessions: sessions,
            checkedAt: processCheckedAt
        )))
        let settings = try? Data(contentsOf: config.settingsFile)
        reducer.apply(.sourceHealth(statuslineWaitingHealth(
            configured: settings.map(StatuslineSetup.isCachewatchConfigured(in:)) ?? false,
            at: Date()
        )))
        return reducer.snapshot
    }
}
