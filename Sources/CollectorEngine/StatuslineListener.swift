import Foundation

private final class SocketLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var serverFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func registerServer(_ fd: Int32) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            closeDescriptor(fd)
            return false
        }
        serverFD = fd
        lock.unlock()
        return true
    }

    func registerClient(_ fd: Int32) -> Bool {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            closeDescriptor(fd)
            return false
        }
        clientFD = fd
        lock.unlock()
        return true
    }

    func closeServer(_ fd: Int32) {
        lock.lock()
        let shouldClose = serverFD == fd
        if shouldClose { serverFD = -1 }
        lock.unlock()
        if shouldClose { closeDescriptor(fd) }
    }

    func closeClient(_ fd: Int32) {
        lock.lock()
        let shouldClose = clientFD == fd
        if shouldClose { clientFD = -1 }
        lock.unlock()
        if shouldClose { closeDescriptor(fd) }
    }

    /// The listener thread polls cancellation between bounded socket waits and
    /// retains exclusive ownership of all shutdown/close operations.
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func closeDescriptor(_ fd: Int32) {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

/// Unix-domain-socket listener for statusline JSON forwarded by scripts/cachewatch-statusline.sh.
/// One short-lived connection per statusline render: decode as soon as a complete
/// document arrives because macOS `nc -U` does not half-close on stdin EOF.
public enum StatuslineListener {
    public enum Failure: String, Sendable, Equatable {
        case pathTooLong
        case pathOccupied
        case socketCreation
        case bind
        case listen
        case accept

        public var isRetryable: Bool {
            self != .pathTooLong
        }

        public var guidance: String {
            switch self {
            case .pathTooLong:
                "The statusline socket path is too long. Configure a shorter socket path and restart Cachewatch."
            case .pathOccupied:
                "The statusline socket path is already occupied. Close the other listener or remove a stale socket file; Cachewatch will retry."
            case .socketCreation, .bind, .listen, .accept:
                "The statusline socket listener failed and will retry. Verify socket-directory permissions."
            }
        }
    }

    public enum Event: Sendable {
        case listening
        case payload(StatuslinePayload)
        case rejectedPayload
        case failed(Failure)
    }

    public static func recoveringEvents(
        socketPath: String,
        retryDelay: Duration = .seconds(1)
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task.detached {
                while !Task.isCancelled {
                    var shouldRetry = false
                    for await event in events(socketPath: socketPath) {
                        continuation.yield(event)
                        if case .failed(let failure) = event {
                            if !failure.isRetryable {
                                continuation.finish()
                                return
                            }
                            shouldRetry = true
                        }
                    }
                    guard shouldRetry else { break }
                    do {
                        try await Task.sleep(for: retryDelay)
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public static func events(socketPath: String) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let lifetime = SocketLifetime()
            continuation.onTermination = { _ in lifetime.cancel() }
            let thread = Thread {
                run(socketPath: socketPath, continuation: continuation, lifetime: lifetime)
            }
            thread.name = "cachewatch.statusline-listener"
            thread.start()
        }
    }

    /// Compatibility view for callers that only consume valid payloads.
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
        continuation: AsyncStream<Event>.Continuation,
        lifetime: SocketLifetime
    ) {
        var addr = sockaddr_un()
        let pathCapacity = withUnsafeBytes(of: &addr.sun_path) { $0.count }
        guard socketPath.utf8CString.count <= pathCapacity else {
            continuation.yield(.failed(.pathTooLong))
            continuation.finish()
            return
        }

        var existingInfo = stat()
        guard lstat(socketPath, &existingInfo) != 0, errno == ENOENT else {
            continuation.yield(.failed(.pathOccupied))
            continuation.finish()
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            continuation.yield(.failed(.socketCreation))
            continuation.finish()
            return
        }
        guard lifetime.registerServer(fd) else {
            continuation.finish()
            return
        }
        var ownedIdentity: (device: dev_t, inode: ino_t)?
        defer {
            lifetime.closeServer(fd)
            if let ownedIdentity {
                var currentInfo = stat()
                if lstat(socketPath, &currentInfo) == 0,
                   currentInfo.st_dev == ownedIdentity.device,
                   currentInfo.st_ino == ownedIdentity.inode {
                    unlink(socketPath)
                }
            }
            continuation.finish()
        }

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            socketPath.utf8CString.withUnsafeBytes { src in
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(raw.count)))
            }
        }
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            continuation.yield(.failed(.bind))
            return
        }
        var ownedInfo = stat()
        guard lstat(socketPath, &ownedInfo) == 0 else {
            continuation.yield(.failed(.bind))
            return
        }
        ownedIdentity = (ownedInfo.st_dev, ownedInfo.st_ino)
        guard listen(fd, 16) == 0 else {
            continuation.yield(.failed(.listen))
            return
        }
        continuation.yield(.listening)

        while true {
            guard waitUntilReadable(fd, lifetime: lifetime) else { break }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if lifetime.isCancelled { break }
                if errno == EINTR { continue }
                continuation.yield(.failed(.accept))
                break
            }
            guard lifetime.registerClient(client) else { break }

            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            let maxPayload = 1024 * 1024
            var acceptedPayload = false
            while data.count < maxPayload {
                guard waitUntilReadable(client, lifetime: lifetime) else { break }
                let n = read(client, &buffer, buffer.count)
                guard n > 0 else { break }
                data.append(buffer, count: n)
                if let payload = try? StatuslinePayload.decode(from: data) {
                    continuation.yield(.payload(payload))
                    acceptedPayload = true
                    break
                }
            }
            if !acceptedPayload, !lifetime.isCancelled {
                continuation.yield(.rejectedPayload)
            }
            lifetime.closeClient(client)
            if lifetime.isCancelled { break }
        }
    }

    private static func waitUntilReadable(_ fd: Int32, lifetime: SocketLifetime) -> Bool {
        while !lifetime.isCancelled {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result > 0 { return true }
            if result < 0, errno != EINTR { return true }
        }
        return false
    }
}
