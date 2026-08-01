import Foundation
import Testing
import CollectorEngine

/// End-to-end: statusline JSON piped through the real forwarder script over the
/// real unix socket into StatuslineListener. Guards against nc/EOF deadlocks.
@Suite(.serialized)
struct IntegrationTests {
    @Test
    func forwarderScriptDeliversPayloadToListener() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = repoRoot.appending(path: "scripts/cachewatch-statusline.sh").path
        let fixturePath = fixtureURL("statusline-plan.json").path
        let sock = FileManager.default.temporaryDirectory.appending(path: "cw-\(UUID().uuidString.prefix(8)).sock").path

        let listening = DispatchSemaphore(value: 0)
        let received = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var payload: StatuslinePayload?
        Task.detached {
            eventLoop: for await event in StatuslineListener.events(socketPath: sock) {
                switch event {
                case .listening:
                    listening.signal()
                case .payload(let value):
                    payload = value
                    received.signal()
                    break eventLoop
                case .rejectedPayload, .failed:
                    break
                }
            }
            exited.signal()
        }
        #expect(listening.wait(timeout: .now() + 5) == .success)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "cat '\(fixturePath)' | '\(script)' > /dev/null"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CACHEWATCH_SOCK": sock]) { _, new in new }
        try process.run()
        process.waitUntilExit()

        let outcome = received.wait(timeout: .now() + 5)
        #expect(outcome == .success, "payload arrived within 5s")
        #expect(payload?.rateLimits?.fiveHour?.usedPercentage == 43.0, "5h quota decoded")
        #expect(exited.wait(timeout: .now() + 5) == .success)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: sock) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: sock) == false)
    }

    @Test
    func statuslineListenerReportsReadinessAndRejectedPayload() throws {
        let sock = FileManager.default.temporaryDirectory
            .appending(path: "cw-health-\(UUID().uuidString.prefix(8)).sock").path
        let listening = DispatchSemaphore(value: 0)
        let rejected = DispatchSemaphore(value: 0)

        Task.detached {
            for await event in StatuslineListener.events(socketPath: sock) {
                switch event {
                case .listening:
                    listening.signal()
                case .rejectedPayload:
                    rejected.signal()
                    return
                case .payload, .failed:
                    break
                }
            }
        }

        #expect(listening.wait(timeout: .now() + 5) == .success)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf 'not-json' | nc -U -w 1 '\(sock)' >/dev/null 2>&1"]
        try process.run()
        process.waitUntilExit()

        #expect(rejected.wait(timeout: .now() + 5) == .success)
        unlink(sock)
    }

    @Test
    func statuslineListenerReportsInvalidSocketPath() {
        let failed = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: StatuslineListener.Failure?
        let path = "/tmp/" + String(repeating: "x", count: 200)

        Task.detached {
            for await event in StatuslineListener.events(socketPath: path) {
                if case .failed(let reason) = event {
                    failure = reason
                    failed.signal()
                    return
                }
            }
        }

        #expect(failed.wait(timeout: .now() + 5) == .success)
        #expect(failure == .pathTooLong)
    }

    @Test
    func statuslineListenerRecoversAfterTransientBindFailure() throws {
        let parent = URL(fileURLWithPath: "/tmp")
            .appending(path: "cw-r-\(UUID().uuidString.prefix(8))")
        let sock = parent.appending(path: "status.sock").path
        defer { try? FileManager.default.removeItem(at: parent) }
        let failed = DispatchSemaphore(value: 0)
        let listening = DispatchSemaphore(value: 0)

        Task.detached {
            for await event in StatuslineListener.recoveringEvents(
                socketPath: sock,
                retryDelay: .milliseconds(10)
            ) {
                switch event {
                case .failed(.bind):
                    failed.signal()
                case .listening:
                    listening.signal()
                    return
                case .payload, .rejectedPayload, .failed:
                    break
                }
            }
        }

        #expect(failed.wait(timeout: .now() + 5) == .success)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        #expect(listening.wait(timeout: .now() + 5) == .success)
    }

    @Test
    func statuslineFailurePolicyDistinguishesTerminalPathErrors() {
        #expect(StatuslineListener.Failure.pathTooLong.isRetryable == false)
        #expect(StatuslineListener.Failure.pathTooLong.guidance.contains("shorter"))
        #expect(StatuslineListener.Failure.bind.isRetryable)
        #expect(StatuslineListener.Failure.bind.guidance.contains("retry"))
    }

    @Test
    func statuslineListenerClosesSocketWhenConsumerCancels() {
        let sock = "/tmp/cw-c-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(sock) }
        let listening = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)

        let consumer = Task.detached {
            for await event in StatuslineListener.events(socketPath: sock) {
                if case .listening = event {
                    listening.signal()
                }
            }
            exited.signal()
        }

        #expect(listening.wait(timeout: .now() + 5) == .success)
        consumer.cancel()
        #expect(exited.wait(timeout: .now() + 5) == .success)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: sock) {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(FileManager.default.fileExists(atPath: sock) == false)
    }

    @Test
    func statuslineListenerPreservesRegularFileAtSocketPath() throws {
        let path = "/tmp/cw-f-\(UUID().uuidString.prefix(8)).sock"
        let marker = Data("do not delete".utf8)
        try marker.write(to: URL(fileURLWithPath: path))
        defer { unlink(path) }
        let failed = DispatchSemaphore(value: 0)

        Task.detached {
            for await event in StatuslineListener.events(socketPath: path) {
                if case .failed(.pathOccupied) = event {
                    failed.signal()
                    return
                }
            }
        }

        #expect(failed.wait(timeout: .now() + 5) == .success)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == marker)
    }

    @Test
    func oldListenerCleanupPreservesReplacementPathEntry() throws {
        let path = "/tmp/cw-o-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(path) }
        let listening = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let consumer = Task.detached {
            for await event in StatuslineListener.events(socketPath: path) {
                if case .listening = event { listening.signal() }
            }
            exited.signal()
        }

        #expect(listening.wait(timeout: .now() + 5) == .success)
        unlink(path)
        let replacement = Data("replacement".utf8)
        try replacement.write(to: URL(fileURLWithPath: path))
        consumer.cancel()
        #expect(exited.wait(timeout: .now() + 5) == .success)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == replacement)
    }
}
