import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Unix-domain-socket listener for statusline JSON forwarded by scripts/cachewatch-statusline.sh.
/// One short-lived connection per statusline render: read until EOF, decode, emit.
public enum StatuslineListener {
    public static func payloads(socketPath: String) -> AsyncStream<StatuslinePayload> {
        AsyncStream { continuation in
            let thread = Thread {
                run(socketPath: socketPath, continuation: continuation)
            }
            thread.name = "cachewatch.statusline-listener"
            thread.start()
        }
    }

    private static func run(socketPath: String, continuation: AsyncStream<StatuslinePayload>.Continuation) {
        unlink(socketPath)
        #if os(Linux)
        let streamSocketType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamSocketType = SOCK_STREAM
        #endif
        let fd = socket(AF_UNIX, streamSocketType, 0)
        guard fd >= 0 else { return }

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
            return
        }

        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { break }
            // Decode as soon as a full JSON document has arrived rather than waiting
            // for EOF: macOS `nc -U` holds its write side open after stdin EOF, so an
            // EOF-gated read deadlocks against the forwarder.
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let maxPayload = 1024 * 1024
            while data.count < maxPayload {
                let n = read(client, &buffer, buffer.count)
                guard n > 0 else { break }
                data.append(buffer, count: n)
                if let payload = try? StatuslinePayload.decode(from: data) {
                    continuation.yield(payload)
                    break
                }
            }
            close(client)
        }
        close(fd)
        continuation.finish()
    }
}
