import Foundation

public struct RegistryScanResult: Sendable {
    public let entries: [SessionRegistryEntry]
    public let health: SourceHealth

    public var shouldReplaceSnapshot: Bool {
        health.condition != .unavailable
    }
}

public enum RegistryScanner {
    /// Compatibility view for callers that only need live entries.
    public static func scan(
        directory: URL,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [SessionRegistryEntry] {
        scanReport(directory: directory, isAlive: isAlive).entries
    }

    /// Reads every `<pid>.json` in `~/.claude/sessions`. Dead-process files are
    /// expected registry churn; unreadable or malformed records are degradation.
    public static func scanReport(
        directory: URL,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 },
        at attemptedAt: Date = Date()
    ) -> RegistryScanResult {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "json" }
        } catch {
            return RegistryScanResult(
                entries: [],
                health: SourceHealth(
                    id: .registry,
                    condition: .unavailable,
                    lastAttemptAt: attemptedAt,
                    message: "Session registry is unavailable. Verify that ~/.claude/sessions exists and is readable."
                )
            )
        }

        var entries: [SessionRegistryEntry] = []
        var dropped = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? SessionRegistryEntry.decode(from: data)
            else {
                dropped += 1
                continue
            }
            if isAlive(entry.pid) {
                entries.append(entry)
            }
        }
        entries.sort { $0.startedAt < $1.startedAt }

        let condition: SourceCondition = dropped == 0 ? .healthy : .degraded
        return RegistryScanResult(
            entries: entries,
            health: SourceHealth(
                id: .registry,
                condition: condition,
                lastAttemptAt: attemptedAt,
                lastSuccessAt: attemptedAt,
                recordsSeen: files.count,
                recordsAccepted: entries.count,
                recordsDropped: dropped,
                message: dropped == 0 ? nil : "Some session registry records could not be read. Live session data may be incomplete."
            )
        )
    }
}
