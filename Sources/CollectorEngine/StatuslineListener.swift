import Foundation

public enum StatuslineListenerEvent: Sendable {
    case listening
    case payload(StatuslinePayload)
    case rejectedPayload
    case unavailable(message: String)
}

/// Unix-domain-socket listener for statusline JSON forwarded by scripts/cachewatch-statusline.sh.
/// One short-lived connection per statusline render; emits as soon as JSON is complete.
public enum StatuslineListener {
    public static func events(socketPath: String) -> AsyncStream<StatuslineListenerEvent> {
        AsyncStream { continuation in
            let thread = Thread {
                run(socketPath: socketPath, continuation: continuation)
            }
            thread.name = "cachewatch.statusline-listener"
            thread.start()
        }
    }

    /// Compatibility convenience for consumers interested only in valid payloads.
    public static func payloads(socketPath: String) -> AsyncStream<StatuslinePayload> {
        AsyncStream { continuation in
            let task = Task {
                for await event in events(socketPath: socketPath) {
                    if case .payload(let payload) = event {
                        continuation.yield(payload)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        socketPath: String,
        continuation: AsyncStream<StatuslineListenerEvent>.Continuation
    ) {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            continuation.yield(.unavailable(message: "The statusline socket could not be created."))
            continuation.finish()
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count - 1)))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            continuation.yield(.unavailable(message: "The statusline socket could not start listening."))
            continuation.finish()
            return
        }
        continuation.yield(.listening)

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else {
                continuation.yield(.unavailable(message: "The statusline socket stopped listening."))
                break
            }
            // Decode as soon as a full JSON document has arrived rather than waiting
            // for EOF: macOS `nc -U` holds its write side open after stdin EOF, so an
            // EOF-gated read deadlocks against the forwarder.
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let maxPayload = 1024 * 1024
            var decoded = false
            while data.count < maxPayload {
                let n = read(client, &buffer, buffer.count)
                guard n > 0 else { break }
                data.append(buffer, count: n)
                if let payload = try? StatuslinePayload.decode(from: data) {
                    continuation.yield(.payload(payload))
                    decoded = true
                    break
                }
            }
            if !decoded, !data.isEmpty {
                continuation.yield(.rejectedPayload)
            }
            close(client)
        }
        close(fd)
        continuation.finish()
    }
}
