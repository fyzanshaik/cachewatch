import Foundation

public struct CollectorConfig: Sendable {
    public static var defaultCodexDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
    }

    public var claudeDir: URL
    public var codexDir: URL
    public var socketPath: String
    public var registryInterval: Duration = .seconds(2)
    public var transcriptInterval: Duration = .seconds(2)
    public var memoryInterval: Duration = .seconds(5)

    public init(
        claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude"),
        codexDir: URL = CollectorConfig.defaultCodexDirectory,
        socketPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".cachewatch/statusline.sock")
    ) {
        self.claudeDir = claudeDir
        self.codexDir = codexDir
        self.socketPath = socketPath
    }

    var sessionsDir: URL { claudeDir.appending(path: "sessions") }
    var projectsDir: URL { claudeDir.appending(path: "projects") }
    var codexSessionsDir: URL { codexDir.appending(path: "sessions") }
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
            var codexSource = CodexSessionSource(directory: config.codexSessionsDir)
            while !Task.isCancelled {
                let codexSessions = codexSource.poll()
                let registry = RegistryScanner.scan(directory: config.sessionsDir)
                    + codexSessions.map { pid, snapshot in snapshot.registryEntry(pid: pid) }
                self.apply(.registrySnapshot(registry))
                for (_, snapshot) in codexSessions {
                    self.apply(.codexSession(snapshot))
                }
                try? await Task.sleep(for: config.registryInterval)
            }
        }
        Task {
            // First poll ingests full history so context/TTL state is correct from launch.
            var tailer = TranscriptTailer(directory: config.projectsDir)
            while !Task.isCancelled {
                for turn in tailer.poll() {
                    self.apply(.assistantTurn(turn))
                }
                try? await Task.sleep(for: config.transcriptInterval)
            }
        }
        Task {
            while !Task.isCancelled {
                let table = ProcessTree.sampleAll()
                for session in self.reducer.snapshot.sessions {
                    self.apply(.memorySample(
                        pid: session.pid,
                        residentBytes: ProcessTree.subtreeRSS(of: session.pid, in: table),
                        host: ProcessTree.hostApp(of: session.pid, in: table)
                    ))
                }
                try? await Task.sleep(for: config.memoryInterval)
            }
        }
        Task {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: config.socketPath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            for await payload in StatuslineListener.payloads(socketPath: config.socketPath) {
                self.apply(.statusline(payload, receivedAt: Date()))
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

    /// One-shot snapshot from a single pass over all file-based sources (no socket data).
    public static func dump(config: CollectorConfig = CollectorConfig()) -> FleetSnapshot {
        var reducer = FleetReducer()
        var codexSource = CodexSessionSource(directory: config.codexSessionsDir)
        let codexSessions = codexSource.poll()
        let registry = RegistryScanner.scan(directory: config.sessionsDir)
            + codexSessions.map { pid, snapshot in snapshot.registryEntry(pid: pid) }
        reducer.apply(.registrySnapshot(registry))
        for (_, snapshot) in codexSessions {
            reducer.apply(.codexSession(snapshot))
        }
        var tailer = TranscriptTailer(directory: config.projectsDir)
        for turn in tailer.poll() {
            reducer.apply(.assistantTurn(turn))
        }
        let table = ProcessTree.sampleAll()
        for session in reducer.snapshot.sessions {
            reducer.apply(.memorySample(
                pid: session.pid,
                residentBytes: ProcessTree.subtreeRSS(of: session.pid, in: table),
                host: ProcessTree.hostApp(of: session.pid, in: table)
            ))
        }
        return reducer.snapshot
    }
}
