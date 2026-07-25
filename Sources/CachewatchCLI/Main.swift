import Foundation
import CollectorEngine
import CachewatchTerminal
#if canImport(Glibc)
import Glibc
#endif

@main
enum Main {
    static func main() async {
        let command = CommandLine.arguments.dropFirst().first
        switch command {
        case nil, "watch":
            await watch()
        case "dump":
            print(TerminalFleetRenderer.render(Collector.dump()))
        case "setup":
            runSetup()
        case "--version", "version":
            print(ProcessInfo.processInfo.environment["CACHEWATCH_VERSION"] ?? "development")
        case "--help", "-h", "help":
            printHelp()
        default:
            if let command {
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
            }
            printHelp()
            exit(64)
        }
    }

    private static func watch() async {
        let collector = Collector()
        await collector.start()
        let interactive = isatty(STDOUT_FILENO) == 1
        for await fleet in await collector.snapshots {
            var output = ""
            if interactive {
                output += "\u{001B}[2J\u{001B}[H"
            }
            output += TerminalFleetRenderer.render(
                fleet,
                style: interactive ? .ansi : .plain,
                live: true
            )
            output += "\n"
            if !interactive {
                output += "\n"
            }
            FileHandle.standardOutput.write(Data(output.utf8))
        }
    }

    private static func runSetup() {
        do {
            let result = try StatuslineInstaller.install()
            print("installed \(result.scriptURL.path)")
            if !result.configurationChanged {
                print("statusline already configured, nothing to do")
                return
            }
            if let backup = result.backupURL {
                print("backed up settings to \(backup.path)")
            }
            print("statusline configured in ~/.claude/settings.json")
            if let previous = result.chainedPrevious {
                print("your previous statusline (\(previous)) is chained and keeps rendering")
            }
            print("new Claude Code sessions pick this up on start; run `cachewatch watch` to monitor them")
        } catch {
            FileHandle.standardError.write(Data("setup failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printHelp() {
        print("""
        Usage: cachewatch [command]

        Commands:
          watch       Live terminal fleet view (default)
          dump        Print one fleet snapshot and exit
          setup       Install and configure the Claude Code statusline forwarder
          version     Print the Cachewatch version
          help        Show this help
        """)
    }
}
