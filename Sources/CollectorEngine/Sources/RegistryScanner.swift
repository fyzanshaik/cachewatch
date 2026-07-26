import Foundation

public struct RegistryScanResult: Sendable {
    public let entries: [SessionRegistryEntry]
    public let health: SourceHealth
}

public enum RegistryScanner {
    /// Reads every `<pid>.json` in `~/.claude/sessions`, dropping unparseable files and
    /// entries whose process is gone (registry files are known to linger after exit).
    public static func scan(
        directory: URL,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [SessionRegistryEntry] {
        scanReport(directory: directory, checkedAt: Date(), isAlive: isAlive).entries
    }

    public static func scanReport(
        directory: URL,
        checkedAt: Date,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
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
                    lastAttemptAt: checkedAt,
                    message: "The session registry directory could not be read."
                )
            )
        }

        var entries: [SessionRegistryEntry] = []
        var malformed = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? SessionRegistryEntry.decode(from: data)
            else {
                malformed += 1
                continue
            }
            // Dead PIDs are expected: Claude's registry files linger after exit.
            guard isAlive(entry.pid) else { continue }
            entries.append(entry)
        }
        entries.sort { $0.startedAt < $1.startedAt }
        let condition: SourceCondition = malformed == 0 ? .healthy : .degraded
        return RegistryScanResult(
            entries: entries,
            health: SourceHealth(
                id: .registry,
                condition: condition,
                lastAttemptAt: checkedAt,
                lastSuccessAt: condition == .healthy ? checkedAt : nil,
                recordsSeen: files.count,
                recordsAccepted: entries.count,
                recordsDropped: malformed,
                message: malformed == 0
                    ? nil
                    : "\(malformed) registry \(malformed == 1 ? "record was" : "records were") unreadable."
            )
        )
    }
}
