import Darwin
import Dispatch
import Foundation

/// Authenticated, run-scoped messages accepted from the bundled terminal
/// runner and optional provider hooks. The server never interprets terminal
/// output; it only accepts explicit lifecycle and status datagrams.
enum TerminalStatusServerEvent: Equatable, Sendable {
    case started(pid: UInt32, processGroupID: Int32)
    case providerBound(providerSessionID: String, source: String)
    case status(TerminalAgentStatus, eventID: String)
    case exited(exitCode: Int32?, signal: Int32?)
}

struct TerminalStatusServerCredentials: Sendable {
    let socketPath: String
    /// Used only by the bundled runner for process lifecycle messages. This
    /// value is persisted in the mode-0600 launch descriptor and must never be
    /// exposed to the Agent child environment.
    let lifecycleToken: String
    /// Exposed to provider hooks in the Agent environment. The server limits
    /// this credential to provider binding and attention-status events.
    let hookToken: String
}

enum TerminalStatusServerError: LocalizedError, Equatable {
    case createDirectory(Int32)
    case createSocket(Int32)
    case socketPathTooLong
    case bind(Int32)
    case configureSocket(Int32)

    var errorDescription: String? {
        switch self {
        case let .createDirectory(code):
            "无法创建终端状态目录（errno \(code)）。"
        case let .createSocket(code):
            "无法创建终端状态 Socket（errno \(code)）。"
        case .socketPathTooLong:
            "终端状态 Socket 路径过长。"
        case let .bind(code):
            "无法绑定终端状态 Socket（errno \(code)）。"
        case let .configureSocket(code):
            "无法保护终端状态 Socket（errno \(code)）。"
        }
    }
}

/// A Unix datagram server is used instead of a stream so each runner event has
/// an atomic boundary. The receive buffer is deliberately small: status hooks
/// may report identifiers and enum values, never transcript content.
final class TerminalStatusServer: @unchecked Sendable {
    static let maximumDatagramBytes = 16 * 1_024
    /// Serializes the host-directory empty -> bound transition with the final
    /// socket unlink -> rmdir transition. Without this lock, one Session can
    /// remove the shared directory after another Session has prepared it but
    /// before that Session binds its socket.
    private static let hostDirectoryLock = NSLock()

    let credentials: TerminalStatusServerCredentials
    let events: AsyncStream<TerminalStatusServerEvent>

    private let directoryPath: String
    private let fileDescriptor: Int32
    private let source: any DispatchSourceRead
    private let continuation: AsyncStream<TerminalStatusServerEvent>.Continuation
    private let lifecycleLock = NSLock()
    private var isStopped = false

    init(sessionID: String, runID: String) throws {
        let hostPID = ProcessInfo.processInfo.processIdentifier
        let directoryURL = URL(fileURLWithPath: "/tmp/todoagent-\(hostPID)", isDirectory: true)
        let directoryPath = directoryURL.path
        self.directoryPath = directoryPath

        let shortSession = sessionID.replacingOccurrences(of: "-", with: "").prefix(8)
        let shortRun = runID.replacingOccurrences(of: "-", with: "").prefix(8)
        let socketPath = directoryURL
            .appendingPathComponent("status-\(shortSession)-\(shortRun).sock")
            .path
        let lifecycleToken = Self.randomToken()
        var hookToken = Self.randomToken()
        while hookToken == lifecycleToken { hookToken = Self.randomToken() }
        credentials = TerminalStatusServerCredentials(
            socketPath: socketPath,
            lifecycleToken: lifecycleToken,
            hookToken: hookToken
        )

        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            let code = errno
            throw TerminalStatusServerError.createSocket(code)
        }
        fileDescriptor = descriptor

        Self.hostDirectoryLock.lock()
        do {
            try Self.prepareSecureDirectory(at: directoryURL.path)
            try Self.bind(descriptor: descriptor, path: socketPath)
            guard chmod(socketPath, mode_t(0o600)) == 0 else {
                throw TerminalStatusServerError.configureSocket(errno)
            }
            let currentFlags = fcntl(descriptor, F_GETFL)
            guard currentFlags >= 0, fcntl(descriptor, F_SETFL, currentFlags | O_NONBLOCK) == 0 else {
                throw TerminalStatusServerError.configureSocket(errno)
            }
            Self.hostDirectoryLock.unlock()
        } catch {
            Darwin.close(descriptor)
            unlink(socketPath)
            rmdir(directoryPath)
            Self.hostDirectoryLock.unlock()
            throw error
        }

        let stream = AsyncStream<TerminalStatusServerEvent>.makeStream(
            // The kernel datagram buffer is already bounded. Bound the Swift
            // handoff as well so an authenticated but malfunctioning hook can
            // never grow App memory while Engine IPC applies earlier events.
            bufferingPolicy: .bufferingNewest(512)
        )
        events = stream.stream
        continuation = stream.continuation

        let queue = DispatchQueue(
            label: "com.todoagent.terminal-status.\(runID)",
            qos: .userInitiated
        )
        let readSource = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source = readSource
        let gate = MessageGate(
            expected: ExpectedMessage(
                lifecycleToken: lifecycleToken,
                hookToken: hookToken,
                sessionID: sessionID,
                runID: runID
            )
        )
        let continuation = stream.continuation
        let cleanupDirectoryPath = directoryPath
        let cleanupSocketPath = socketPath
        readSource.setEventHandler {
            Self.receiveAvailable(
                descriptor: descriptor,
                gate: gate,
                continuation: continuation
            )
        }
        readSource.setCancelHandler {
            Darwin.close(descriptor)
            Self.hostDirectoryLock.lock()
            unlink(cleanupSocketPath)
            // Multiple sessions may share the host-scoped directory. rmdir
            // only succeeds after the final socket has gone.
            rmdir(cleanupDirectoryPath)
            Self.hostDirectoryLock.unlock()
        }
        readSource.resume()
    }

    deinit {
        stop()
    }

    func stop() {
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            return
        }
        isStopped = true
        lifecycleLock.unlock()

        continuation.finish()
        source.cancel()
    }

    private struct ExpectedMessage: Sendable {
        let lifecycleToken: String
        let hookToken: String
        let sessionID: String
        let runID: String
    }

    /// The Dispatch read source is serial, but keeping the one-shot lifecycle
    /// transition behind a lock makes that invariant explicit and safe if the
    /// receive plumbing is changed later.
    private final class MessageGate: @unchecked Sendable {
        private let expected: ExpectedMessage
        private let lock = NSLock()
        private var acceptedStarted = false

        init(expected: ExpectedMessage) {
            self.expected = expected
        }

        func event(from message: WireMessage) -> TerminalStatusServerEvent? {
            guard message.sessionID == expected.sessionID,
                  message.runID == expected.runID
            else {
                return nil
            }

            let hasLifecycleCredential = TerminalStatusServer.securelyEqual(
                message.token,
                expected.lifecycleToken
            )
            let hasHookCredential = TerminalStatusServer.securelyEqual(
                message.token,
                expected.hookToken
            )

            switch message.event {
            case "started":
                guard hasLifecycleCredential,
                      let pid = message.pid,
                      pid > 0,
                      let processGroupID = message.pgid,
                      processGroupID > 0,
                      UInt32(processGroupID) == pid
                else {
                    return nil
                }
                lock.lock()
                defer { lock.unlock() }
                guard acceptedStarted == false else { return nil }
                acceptedStarted = true
                return .started(pid: pid, processGroupID: processGroupID)
            case "exited":
                guard hasLifecycleCredential else { return nil }
                return .exited(exitCode: message.exitCode, signal: message.signal)
            case "provider_bound", "bind_provider":
                guard hasHookCredential,
                      let providerSessionID = message.providerSessionID,
                      !providerSessionID.isEmpty,
                      let source = message.source,
                      !source.isEmpty
                else {
                    return nil
                }
                return .providerBound(providerSessionID: providerSessionID, source: source)
            case "status", "agent_status":
                guard hasHookCredential,
                      let status = message.status,
                      let eventID = message.eventID,
                      UUID(uuidString: eventID)?.uuidString.lowercased() == eventID.lowercased()
                else {
                    return nil
                }
                return .status(status, eventID: eventID.lowercased())
            default:
                return nil
            }
        }
    }

    private struct WireMessage: Decodable {
        let token: String
        let sessionID: String
        let runID: String
        let event: String
        let eventID: String?
        let pid: UInt32?
        let pgid: Int32?
        let exitCode: Int32?
        let signal: Int32?
        let providerSessionID: String?
        let source: String?
        let status: TerminalAgentStatus?

        private enum CodingKeys: String, CodingKey {
            case token, sessionID = "sessionId", runID = "runId", event
            case eventID = "eventId"
            case pid, pgid, exitCode, signal
            case providerSessionID = "providerSessionId"
            case source, status
        }
    }

    private static func bind(descriptor: Int32, path: String) throws {
        let pathBytes = path.utf8CString
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            throw TerminalStatusServerError.socketPathTooLong
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                pathBytes.withUnsafeBufferPointer { source in
                    guard let sourceAddress = source.baseAddress else { return }
                    destination.initialize(from: sourceAddress, count: source.count)
                }
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else { throw TerminalStatusServerError.bind(errno) }
    }

    private static func prepareSecureDirectory(at path: String) throws {
        if mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
            throw TerminalStatusServerError.createDirectory(errno)
        }
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(0o077)) == 0
        else {
            throw TerminalStatusServerError.createDirectory(errno == 0 ? EPERM : errno)
        }
    }

    private static func receiveAvailable(
        descriptor: Int32,
        gate: MessageGate,
        continuation: AsyncStream<TerminalStatusServerEvent>.Continuation
    ) {
        var buffer = [UInt8](repeating: 0, count: maximumDatagramBytes + 1)
        while true {
            let received = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
            }
            if received < 0 {
                if errno == EINTR { continue }
                return
            }
            guard received > 0, received <= maximumDatagramBytes else { continue }
            let payload = Data(buffer.prefix(received))
            for line in payload.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard line.count <= maximumDatagramBytes,
                      let message = try? JSONDecoder().decode(WireMessage.self, from: Data(line)),
                      let event = gate.event(from: message)
                else {
                    continue
                }
                continuation.yield(event)
            }
        }
    }

    private static func randomToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// A simple constant-time comparison avoids making the per-run bearer token
    /// observable through a local timing oracle.
    private static func securelyEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}
