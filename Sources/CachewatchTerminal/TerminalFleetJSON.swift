import Foundation
import CollectorEngine

public enum TerminalFleetJSON {
    public static func encode(_ fleet: FleetSnapshot, now: Date = Date()) throws -> Data {
        let payload = Payload(
            schemaVersion: 1,
            generatedAt: now.timeIntervalSince1970,
            summary: Summary(fleet),
            sessions: fleet.sessions.map { Session($0, now: now) },
            quotas: quotaWindows(provider: .claude, limits: fleet.rateLimits)
                + quotaWindows(provider: .codex, limits: fleet.codexRateLimits)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(payload)
    }

    private static func quotaWindows(
        provider: SessionProvider,
        limits: StatuslinePayload.RateLimits?
    ) -> [Quota] {
        let windows: [(String, StatuslinePayload.RateLimitWindow?)] = [
            ("5h", limits?.fiveHour),
            ("7d", limits?.sevenDay),
        ]
        return windows.compactMap { window, limit in
            guard let usedPercentage = limit?.usedPercentage else { return nil }
            return Quota(
                provider: provider.rawValue,
                window: window,
                usedPercentage: usedPercentage,
                resetsAt: limit?.resetsAt?.timeIntervalSince1970
            )
        }
    }

    private struct Payload: Encodable {
        let schemaVersion: Int
        let generatedAt: TimeInterval
        let summary: Summary
        let sessions: [Session]
        let quotas: [Quota]
    }

    private struct Summary: Encodable {
        let total: Int
        let busy: Int
        let idle: Int
        let waiting: Int

        init(_ fleet: FleetSnapshot) {
            total = fleet.sessions.count
            busy = fleet.sessions.count { $0.status == .busy }
            idle = fleet.sessions.count { $0.status == .idle }
            waiting = fleet.sessions.count { $0.status == .waiting }
        }
    }

    private struct Session: Encodable {
        let id: String
        let provider: String
        let name: String?
        let cwd: String
        let status: String
        let model: String?
        let branch: String?
        let contextTokens: Int?
        let contextUsedPercentage: Double?
        let memoryBytes: UInt64?
        let lastTurnAt: TimeInterval?
        let cacheState: String
        let cacheExpiresAt: TimeInterval?

        init(_ session: SessionSnapshot, now: Date) {
            id = session.sessionId
            provider = session.provider.rawValue
            name = session.name
            cwd = session.cwd
            status = session.status.rawValue
            model = session.model
            branch = session.gitBranch
            contextTokens = session.contextTokens
            contextUsedPercentage = session.contextUsedPercentage
            memoryBytes = session.memoryBytes
            lastTurnAt = session.lastTurnAt?.timeIntervalSince1970

            switch session.cacheState(at: now) {
            case .warm(let expiresAt):
                cacheState = "warm"
                cacheExpiresAt = expiresAt.timeIntervalSince1970
            case .cold:
                cacheState = "cold"
                cacheExpiresAt = nil
            case .unknown:
                cacheState = "unknown"
                cacheExpiresAt = nil
            }
        }
    }

    private struct Quota: Encodable {
        let provider: String
        let window: String
        let usedPercentage: Double
        let resetsAt: TimeInterval?
    }
}
