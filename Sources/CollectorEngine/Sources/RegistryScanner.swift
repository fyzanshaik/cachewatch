import Foundation

public enum RegistryScanner {
    /// Reads every `<pid>.json` in `~/.claude/sessions`, dropping unparseable files and
    /// entries whose process is gone (registry files are known to linger after exit).
    public static func scan(
        directory: URL,
        isAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [SessionRegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let entry = try? SessionRegistryEntry.decode(from: data),
                      isAlive(entry.pid)
                else { return nil }
                return entry
            }
            .sorted { $0.startedAt < $1.startedAt }
    }
}
