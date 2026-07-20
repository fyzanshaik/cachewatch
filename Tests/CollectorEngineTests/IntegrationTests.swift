import Foundation
import Testing
import CollectorEngine

/// End-to-end: statusline JSON piped through the real forwarder script over the
/// real unix socket into StatuslineListener. Guards against nc/EOF deadlocks.
@Suite
struct IntegrationTests {
    @Test
    func forwarderScriptDeliversPayloadToListener() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appending(path: "scripts/cachewatch-statusline.sh").path
        let fixturePath = fixtureURL("statusline-plan.json").path
        let sock = FileManager.default.temporaryDirectory.appending(path: "cw-\(UUID().uuidString.prefix(8)).sock").path

        let received = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var payload: StatuslinePayload?
        Task.detached {
            for await p in StatuslineListener.payloads(socketPath: sock) {
                payload = p
                received.signal()
                break
            }
        }
        // Give the listener thread a moment to bind before forwarding.
        Thread.sleep(forTimeInterval: 0.3)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cat '\(fixturePath)' | '\(script)' > /dev/null"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CACHEWATCH_SOCK": sock]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        let outcome = received.wait(timeout: .now() + 5)
        #expect(outcome == .success, "payload arrived within 5s")
        #expect(payload?.rateLimits?.fiveHour?.usedPercentage == 43.0, "5h quota decoded")
        unlink(sock)
    }
}
