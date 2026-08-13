import Darwin
import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Terminal status socket")
@MainActor
struct TerminalStatusServerTests {
    @Test("accepts only authenticated messages for its exact run")
    func authenticationAndRunScope() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }

        try send(
            json: message(
                token: "wrong-token",
                sessionID: sessionID,
                runID: runID,
                event: "started",
                extra: #"","pid":100,"pgid":100"#
            ),
            to: server.credentials.socketPath
        )
        try send(
            json: message(
                token: server.credentials.lifecycleToken,
                sessionID: sessionID,
                runID: UUID().uuidString.lowercased(),
                event: "started",
                extra: #"","pid":101,"pgid":101"#
            ),
            to: server.credentials.socketPath
        )
        try send(
            json: message(
                token: server.credentials.lifecycleToken,
                sessionID: sessionID,
                runID: runID,
                event: "started",
                extra: #"","pid":102,"pgid":102"#
            ),
            to: server.credentials.socketPath
        )

        try await recorder.waitForCount(1)
        #expect(await recorder.snapshot() == [.started(pid: 102, processGroupID: 102)])
    }

    @Test("drops oversized datagrams without poisoning later lifecycle events")
    func oversizedDatagram() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }

        try sendLargestSupportedDatagram(
            desiredSize: TerminalStatusServer.maximumDatagramBytes + 1,
            to: server.credentials.socketPath
        )
        try send(
            json: message(
                token: server.credentials.lifecycleToken,
                sessionID: sessionID,
                runID: runID,
                event: "exited",
                extra: #"","exitCode":0"#
            ),
            to: server.credentials.socketPath
        )

        try await recorder.waitForCount(1)
        #expect(await recorder.snapshot() == [.exited(exitCode: 0, signal: nil)])
    }

    @Test("preserves duplicate datagram boundaries for controller idempotency")
    func duplicateEvents() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }
        let payload = message(
            token: server.credentials.lifecycleToken,
            sessionID: sessionID,
            runID: runID,
            event: "exited",
            extra: #"","exitCode":7,"signal":15"#
        )

        try send(json: payload, to: server.credentials.socketPath)
        try send(json: payload, to: server.credentials.socketPath)

        try await recorder.waitForCount(2)
        #expect(await recorder.snapshot() == [
            .exited(exitCode: 7, signal: 15),
            .exited(exitCode: 7, signal: 15),
        ])
    }

    @Test("keeps lifecycle and provider-hook credentials in separate event domains")
    func credentialCapabilities() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let eventID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }

        let lifecycleEvents = [
            ("started", #"","pid":310,"pgid":310"#),
            ("exited", #"","exitCode":0"#),
        ]
        for (event, extra) in lifecycleEvents {
            try send(
                json: message(
                    token: server.credentials.hookToken,
                    sessionID: sessionID,
                    runID: runID,
                    event: event,
                    extra: extra
                ),
                to: server.credentials.socketPath
            )
        }
        try send(
            json: message(
                token: server.credentials.lifecycleToken,
                sessionID: sessionID,
                runID: runID,
                event: "status",
                extra: #"","status":"completed","eventId":"\#(eventID)""#
            ),
            to: server.credentials.socketPath
        )
        try send(
            json: message(
                token: server.credentials.hookToken,
                sessionID: sessionID,
                runID: runID,
                event: "status",
                extra: #"","status":"completed","eventId":"\#(eventID)""#
            ),
            to: server.credentials.socketPath
        )

        try await recorder.waitForCount(1)
        #expect(await recorder.snapshot() == [.status(.completed, eventID: eventID)])
    }

    @Test("accepts exactly one valid runner started event")
    func startedValidationAndOneShot() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }

        for extra in [
            #"","pid":0,"pgid":0"#,
            #"","pid":320,"pgid":321"#,
            #"","pid":322,"pgid":322"#,
            #"","pid":323,"pgid":323"#,
        ] {
            try send(
                json: message(
                    token: server.credentials.lifecycleToken,
                    sessionID: sessionID,
                    runID: runID,
                    event: "started",
                    extra: extra
                ),
                to: server.credentials.socketPath
            )
        }

        try await recorder.waitForCount(1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.snapshot() == [.started(pid: 322, processGroupID: 322)])
    }

    @Test("preserves the hook status event id for durable deduplication")
    func statusEventIdentity() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let eventID = UUID().uuidString.lowercased()
        let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        defer {
            server.stop()
            recorder.stop()
        }

        try send(
            json: message(
                token: server.credentials.hookToken,
                sessionID: sessionID,
                runID: runID,
                event: "status",
                extra: #"","status":"completed","eventId":"\#(eventID)""#
            ),
            to: server.credentials.socketPath
        )

        try await recorder.waitForCount(1)
        #expect(await recorder.snapshot() == [.status(.completed, eventID: eventID)])
    }

    @Test("stop finishes the stream and removes the protected socket")
    func stopCleansUp() async throws {
        let server = try TerminalStatusServer(
            sessionID: UUID().uuidString.lowercased(),
            runID: UUID().uuidString.lowercased()
        )
        let recorder = StatusEventRecorder()
        await recorder.start(stream: server.events)
        let socketPath = server.credentials.socketPath
        #expect(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        try await recorder.waitUntilFinished()
        try await waitUntil { !FileManager.default.fileExists(atPath: socketPath) }
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        recorder.stop()
    }

    private func message(
        token: String,
        sessionID: String,
        runID: String,
        event: String,
        extra: String = ""
    ) -> String {
        #"{"token":"\#(token)","sessionId":"\#(sessionID)","runId":"\#(runID)","event":"\#(event)\#(extra)}"#
    }

    private func send(json: String, to path: String) throws {
        try send(data: Data(json.utf8), to: path)
    }

    private func send(data: Data, to path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw SocketTestError.systemCall(errno) }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        let bytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else { throw SocketTestError.pathTooLong }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                bytes.withUnsafeBufferPointer { source in
                    guard let sourceAddress = source.baseAddress else { return }
                    destination.initialize(from: sourceAddress, count: source.count)
                }
            }
        }
        let sent = try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                let result = data.withUnsafeBytes { payload in
                    Darwin.sendto(
                        descriptor,
                        payload.baseAddress,
                        payload.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
                guard result == data.count else { throw SocketTestError.systemCall(errno) }
                return result
            }
        }
        #expect(sent == data.count)
    }

    private func sendLargestSupportedDatagram(desiredSize: Int, to path: String) throws {
        var size = desiredSize
        while size > 1_024 {
            do {
                try send(data: Data(repeating: 0x61, count: size), to: path)
                return
            } catch let SocketTestError.systemCall(code) where code == EMSGSIZE {
                size /= 2
            }
        }
        throw SocketTestError.systemCall(EMSGSIZE)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw SocketTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor StatusEventRecorder {
    private var events: [TerminalStatusServerEvent] = []
    private var finished = false
    private var task: Task<Void, Never>?

    func start(stream: AsyncStream<TerminalStatusServerEvent>) {
        guard task == nil else { return }
        task = Task { [weak self] in
            for await event in stream { await self?.append(event) }
            await self?.markFinished()
        }
    }

    func snapshot() -> [TerminalStatusServerEvent] { events }

    func waitForCount(_ count: Int, timeout: Duration = .seconds(1)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while events.count < count {
            guard clock.now < deadline else { throw SocketTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitUntilFinished(timeout: Duration = .seconds(1)) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !finished {
            guard clock.now < deadline else { throw SocketTestError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    nonisolated func stop() {
        Task { await cancel() }
    }

    private func append(_ event: TerminalStatusServerEvent) { events.append(event) }
    private func markFinished() { finished = true }
    private func cancel() { task?.cancel(); task = nil }
}

private enum SocketTestError: Error {
    case pathTooLong
    case systemCall(Int32)
    case timedOut
}
