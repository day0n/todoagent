import Darwin
import CFNetwork
import Foundation

enum EngineClientError: LocalizedError, Equatable {
    case executableMissing
    case alreadyStarted
    case notRunning
    case launchFailed(String)
    case protocolMismatch(expected: Int, received: Int)
    case invalidMessage
    case requestFailed(code: String, message: String)
    case timedOut(String)
    case processExited(Int32)

    var errorDescription: String? {
        switch self {
        case .executableMissing: "找不到 TodoAgent Engine。请重新构建或安装应用。"
        case .alreadyStarted: "TodoAgent Engine 已经启动。"
        case .notRunning: "TodoAgent Engine 尚未启动。"
        case let .launchFailed(message): "TodoAgent Engine 启动失败：\(message)"
        case let .protocolMismatch(expected, received):
            "TodoAgent 与 Engine 协议不兼容（需要 \(expected)，收到 \(received)）。"
        case .invalidMessage: "TodoAgent Engine 返回了无法识别的数据。"
        case let .requestFailed(_, message): message
        case let .timedOut(method): "Engine 请求超时：\(method)"
        case let .processExited(status): "TodoAgent Engine 意外退出（状态 \(status)）。"
        }
    }
}

struct EngineEvent: Sendable, Equatable {
    let name: String
    let data: Data
}

/// A decoded line from the versioned NDJSON wire protocol.
///
/// Requests are decoded as well as responses so Swift and Rust can validate the
/// same shared contract fixture even though EngineClient only receives the
/// other three cases from stdout.
enum EngineWireMessage: Sendable, Equatable {
    case event(EngineEvent)
    case request(id: String, method: String, params: Data)
    case response(id: String, result: Data)
    case failure(id: String?, code: String, message: String, details: Data?)

    static func decode(_ line: Data) throws -> Self {
        guard
            let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
        else {
            throw EngineClientError.invalidMessage
        }

        if let event = object["event"] as? String, let value = object["data"] {
            return .event(EngineEvent(name: event, data: try encodeJSON(value)))
        }

        if let id = object["id"] as? String,
           let method = object["method"] as? String,
           let params = object["params"] {
            return .request(id: id, method: method, params: try encodeJSON(params))
        }

        let id = object["id"] as? String
        if let errorObject = object["error"] as? [String: Any],
           let code = errorObject["code"] as? String,
           let message = errorObject["message"] as? String {
            let details = try errorObject["details"].map(encodeJSON)
            return .failure(id: id, code: code, message: message, details: details)
        }

        if let id, let result = object["result"] {
            return .response(id: id, result: try encodeJSON(result))
        }

        throw EngineClientError.invalidMessage
    }

    private static func encodeJSON(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}

private struct EngineHandshake: Decodable, Sendable {
    let protocolVersion: Int
    let engineVersion: String
    let capabilities: [String]
}

private struct PendingRequest {
    let generation: UUID
    let method: String
    let continuation: CheckedContinuation<Data, Error>
    let timeout: Task<Void, Never>
}

private struct PendingHandshake {
    let generation: UUID
    let continuation: CheckedContinuation<EngineHandshake, Error>
    let timeout: Task<Void, Never>
}

private struct EngineSession {
    let generation: UUID
    let process: Process
    let input: FileHandle
    let output: FileHandle
    let errorOutput: FileHandle
    var outputBuffer = Data()
    var errorBuffer = Data()
    var isReady = false
    var isStopping = false
}

/// The only owner of the Rust sidecar process and its NDJSON streams.
actor EngineClient {
    static let protocolVersion = 4

    private static let eventBufferSize = 512
    private static let gracefulStopDuration: Duration = .seconds(1)
    private static let totalStopDuration: Duration = .seconds(3)

    private let executableURL: URL
    private let executableArguments: [String]
    private let requestTimeout: Duration
    private let handshakeTimeout: Duration
    private var session: EngineSession?
    private var pending: [String: PendingRequest] = [:]
    private var pendingHandshake: PendingHandshake?
    private var eventContinuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var automaticRestartCount = 0
    private(set) var engineVersion: String?
    private(set) var capabilities: Set<String> = []

    init(
        executableURL: URL? = Bundle.main.url(forResource: "todoagent-engine", withExtension: nil),
        executableArguments: [String] = [],
        requestTimeout: Duration = .seconds(15),
        handshakeTimeout: Duration = .seconds(5)
    ) throws {
        guard let executableURL else { throw EngineClientError.executableMissing }
        self.executableURL = executableURL
        self.executableArguments = executableArguments
        self.requestTimeout = requestTimeout
        self.handshakeTimeout = handshakeTimeout
    }

    func start() async throws {
        guard session == nil, pendingHandshake == nil else {
            throw EngineClientError.alreadyStarted
        }
        automaticRestartCount = 0
        try await establishSession()
    }

    func stop() async {
        guard let active = session else {
            failPending(with: EngineClientError.notRunning)
            failHandshake(with: EngineClientError.notRunning)
            finishEventStreams()
            clearEngineMetadata()
            return
        }

        let generation = active.generation
        markSessionStopping(generation)
        failPending(for: generation, with: EngineClientError.notRunning)
        failHandshake(for: generation, with: EngineClientError.notRunning)

        let clock = ContinuousClock()
        let stopDeadline = clock.now.advanced(by: Self.totalStopDuration)
        let gracefulDeadline = clock.now.advanced(by: Self.gracefulStopDuration)

        if active.process.isRunning {
            _ = try? await performRequest(
                method: "engine.shutdown",
                params: EmptyParams(),
                as: ShutdownResult.self,
                timeout: Self.gracefulStopDuration,
                allowWhileStopping: true
            )
            _ = await waitForExit(active.process, until: earlier(gracefulDeadline, stopDeadline))
        }

        if active.process.isRunning {
            active.process.terminate()
            _ = await waitForExit(active.process, until: stopDeadline)
        }

        if active.process.isRunning {
            _ = Darwin.kill(active.process.processIdentifier, SIGKILL)
        }

        tearDownSession(generation: generation, error: EngineClientError.notRunning)
        finishEventStreams()
        clearEngineMetadata()
    }

    func request<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        as resultType: Result.Type = Result.self,
        timeout: Duration? = nil
    ) async throws -> Result {
        try await performRequest(
            method: method,
            params: params,
            as: resultType,
            timeout: timeout ?? requestTimeout,
            allowWhileStopping: false
        )
    }

    func events() -> AsyncStream<EngineEvent> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self,
            bufferingPolicy: .bufferingNewest(Self.eventBufferSize)
        )
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeEventContinuation(token) }
        }
        eventContinuations[token] = continuation
        return stream
    }

    private func establishSession() async throws {
        let generation = UUID()

        do {
            let handshake = try await waitForHandshakeAndLaunch(generation: generation)
            guard session?.generation == generation else {
                throw EngineClientError.notRunning
            }
            guard handshake.protocolVersion == Self.protocolVersion else {
                throw EngineClientError.protocolMismatch(
                    expected: Self.protocolVersion,
                    received: handshake.protocolVersion
                )
            }

            session?.isReady = true
            engineVersion = handshake.engineVersion
            capabilities = Set(handshake.capabilities)
        } catch {
            await cleanUpFailedStart(generation: generation)
            throw error
        }
    }

    private func waitForHandshakeAndLaunch(generation: UUID) async throws -> EngineHandshake {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [handshakeTimeout] in
                    do {
                        try await Task.sleep(for: handshakeTimeout)
                    } catch is CancellationError {
                        return
                    } catch {
                        return
                    }
                    guard Task.isCancelled == false else { return }
                    self.failHandshake(
                        for: generation,
                        with: EngineClientError.timedOut("engine.ready")
                    )
                }

                pendingHandshake = PendingHandshake(
                    generation: generation,
                    continuation: continuation,
                    timeout: timeout
                )

                do {
                    try launch(generation: generation)
                } catch {
                    failHandshake(for: generation, with: error)
                }
            }
        } onCancel: {
            Task { await self.cancelHandshake(generation: generation) }
        }
    }

    private func performRequest<Params: Encodable & Sendable, Result: Decodable & Sendable>(
        method: String,
        params: Params,
        as _: Result.Type,
        timeout requestDuration: Duration,
        allowWhileStopping: Bool
    ) async throws -> Result {
        guard let active = session, active.process.isRunning else {
            throw EngineClientError.notRunning
        }
        guard allowWhileStopping || active.isStopping == false else {
            throw EngineClientError.notRunning
        }

        let generation = active.generation
        let id = UUID().uuidString
        let request = RequestEnvelope(id: id, method: method, params: params)
        let encoded = try JSONEncoder.engine().encode(request)
        let payload = encoded + Data([0x0A])

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task {
                    do {
                        try await Task.sleep(for: requestDuration)
                    } catch is CancellationError {
                        return
                    } catch {
                        return
                    }
                    guard Task.isCancelled == false else { return }
                    self.timeoutRequest(id: id, generation: generation)
                }

                pending[id] = PendingRequest(
                    generation: generation,
                    method: method,
                    continuation: continuation,
                    timeout: timeout
                )

                do {
                    try active.input.write(contentsOf: payload)
                } catch {
                    completeRequest(id: id, generation: generation, result: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(id: id, generation: generation) }
        }
        return try JSONDecoder.engine().decode(Result.self, from: response)
    }

    private func launch(generation: UUID) throws {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw EngineClientError.executableMissing
        }
        guard session == nil else { throw EngineClientError.alreadyStarted }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let output = stdoutPipe.fileHandleForReading
        let errorOutput = stderrPipe.fileHandleForReading

        process.executableURL = executableURL
        process.arguments = executableArguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = Self.mergedEnvironment()
        process.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task {
                await self?.processDidExit(generation: generation, status: status)
            }
        }

        do {
            try process.run()
        } catch {
            throw EngineClientError.launchFailed(error.localizedDescription)
        }

        session = EngineSession(
            generation: generation,
            process: process,
            input: stdinPipe.fileHandleForWriting,
            output: output,
            errorOutput: errorOutput
        )

        output.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            Task {
                await self?.receiveOutputChunk(data, generation: generation)
            }
        }

        errorOutput.readabilityHandler = { [weak self] readableHandle in
            let data = readableHandle.availableData
            Task {
                await self?.receiveErrorChunk(data, generation: generation)
            }
        }
    }

    private func receiveOutputChunk(_ data: Data, generation: UUID) {
        guard var active = session, active.generation == generation else { return }
        guard data.isEmpty == false else {
            active.output.readabilityHandler = nil
            session = active
            return
        }

        active.outputBuffer.append(data)
        var lines: [Data] = []
        while let newline = active.outputBuffer.firstIndex(of: 0x0A) {
            var line = Data(active.outputBuffer[..<newline])
            active.outputBuffer.removeSubrange(active.outputBuffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if line.isEmpty == false {
                lines.append(line)
            }
        }
        session = active

        for line in lines {
            receive(line, generation: generation)
        }
    }

    private func receiveErrorChunk(_ data: Data, generation: UUID) {
        guard var active = session, active.generation == generation else { return }
        guard data.isEmpty == false else {
            active.errorOutput.readabilityHandler = nil
            if active.errorBuffer.isEmpty == false {
                Self.logEngineError(String(decoding: active.errorBuffer, as: UTF8.self))
                active.errorBuffer.removeAll(keepingCapacity: false)
            }
            session = active
            return
        }

        active.errorBuffer.append(data)
        var lines: [String] = []
        while let newline = active.errorBuffer.firstIndex(of: 0x0A) {
            var line = Data(active.errorBuffer[..<newline])
            active.errorBuffer.removeSubrange(active.errorBuffer.startIndex...newline)
            if line.last == 0x0D {
                line.removeLast()
            }
            if line.isEmpty == false {
                lines.append(String(decoding: line, as: UTF8.self))
            }
        }
        session = active

        for line in lines {
            Self.logEngineError(line)
        }
    }

    private func receive(_ data: Data, generation: UUID) {
        guard session?.generation == generation else { return }

        do {
            switch try EngineWireMessage.decode(data) {
            case let .event(event):
                if event.name == "engine.ready", pendingHandshake?.generation == generation {
                    do {
                        let handshake = try JSONDecoder.engine().decode(EngineHandshake.self, from: event.data)
                        if handshake.protocolVersion == Self.protocolVersion {
                            engineVersion = handshake.engineVersion
                            capabilities = Set(handshake.capabilities)
                        }
                        completeHandshake(generation: generation, result: .success(handshake))
                    } catch {
                        completeHandshake(generation: generation, result: .failure(error))
                    }
                }
                yield(event)

            case let .response(id, result):
                completeRequest(id: id, generation: generation, result: .success(result))

            case let .failure(id, code, message, _):
                guard let id else {
                    Self.logEngineError("engine error without request id: \(code): \(message)")
                    return
                }
                completeRequest(
                    id: id,
                    generation: generation,
                    result: .failure(EngineClientError.requestFailed(code: code, message: message))
                )

            case .request:
                Self.logEngineError("unexpected request on engine stdout")
            }
        } catch {
            Self.logEngineError("invalid stdout message: \(error.localizedDescription)")
        }
    }

    private func yield(_ event: EngineEvent) {
        var terminatedTokens: [UUID] = []
        for (token, continuation) in eventContinuations {
            if case .terminated = continuation.yield(event) {
                terminatedTokens.append(token)
            }
        }
        for token in terminatedTokens {
            eventContinuations.removeValue(forKey: token)
        }
    }

    private func completeRequest(
        id: String,
        generation: UUID,
        result: Result<Data, Error>
    ) {
        guard let request = pending[id], request.generation == generation else { return }
        pending.removeValue(forKey: id)
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func timeoutRequest(id: String, generation: UUID) {
        guard let request = pending[id], request.generation == generation else { return }
        pending.removeValue(forKey: id)
        request.continuation.resume(throwing: EngineClientError.timedOut(request.method))
    }

    private func cancelRequest(id: String, generation: UUID) {
        completeRequest(
            id: id,
            generation: generation,
            result: .failure(CancellationError())
        )
    }

    private func completeHandshake(
        generation: UUID,
        result: Result<EngineHandshake, Error>
    ) {
        guard let handshake = pendingHandshake, handshake.generation == generation else { return }
        pendingHandshake = nil
        handshake.timeout.cancel()
        handshake.continuation.resume(with: result)
    }

    private func failHandshake(for generation: UUID, with error: Error) {
        completeHandshake(generation: generation, result: .failure(error))
    }

    private func failHandshake(with error: Error) {
        guard let generation = pendingHandshake?.generation else { return }
        failHandshake(for: generation, with: error)
    }

    private func cancelHandshake(generation: UUID) {
        failHandshake(for: generation, with: CancellationError())
    }

    private func processDidExit(generation: UUID, status: Int32) async {
        guard let active = session, active.generation == generation else { return }
        let wasReady = active.isReady
        let wasStopping = active.isStopping

        tearDownSession(
            generation: generation,
            error: EngineClientError.processExited(status)
        )
        clearEngineMetadata()

        guard wasStopping == false, wasReady else { return }
        guard automaticRestartCount == 0 else {
            finishEventStreams()
            return
        }

        automaticRestartCount += 1
        do {
            try await establishSession()
        } catch is CancellationError {
            finishEventStreams()
        } catch {
            Self.logEngineError("automatic restart failed: \(error.localizedDescription)")
            finishEventStreams()
        }
    }

    private func cleanUpFailedStart(generation: UUID) async {
        failHandshake(for: generation, with: EngineClientError.notRunning)
        guard let active = session, active.generation == generation else { return }

        markSessionStopping(generation)
        if active.process.isRunning {
            active.process.terminate()
            let deadline = ContinuousClock().now.advanced(by: Self.totalStopDuration)
            _ = await waitForExit(active.process, until: deadline)
        }
        if active.process.isRunning {
            _ = Darwin.kill(active.process.processIdentifier, SIGKILL)
        }
        tearDownSession(generation: generation, error: EngineClientError.notRunning)
        clearEngineMetadata()
    }

    private func markSessionStopping(_ generation: UUID) {
        guard session?.generation == generation else { return }
        session?.isStopping = true
    }

    private func waitForExit(
        _ process: Process,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        while process.isRunning, clock.now < deadline {
            guard Task.isCancelled == false else { return false }
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return process.isRunning == false
    }

    private func earlier(
        _ lhs: ContinuousClock.Instant,
        _ rhs: ContinuousClock.Instant
    ) -> ContinuousClock.Instant {
        lhs < rhs ? lhs : rhs
    }

    private func tearDownSession(generation: UUID, error: Error) {
        guard let active = session, active.generation == generation else { return }
        session?.isStopping = true

        active.output.readabilityHandler = nil
        active.errorOutput.readabilityHandler = nil
        try? active.input.close()
        try? active.output.close()
        try? active.errorOutput.close()

        failHandshake(for: generation, with: error)
        failPending(for: generation, with: error)
        session = nil
    }

    private func failPending(for generation: UUID, with error: Error) {
        let requestIDs = pending.compactMap { id, request in
            request.generation == generation ? id : nil
        }
        for id in requestIDs {
            guard let request = pending.removeValue(forKey: id) else { continue }
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func failPending(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func finishEventStreams() {
        let continuations = eventContinuations.values
        eventContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeEventContinuation(_ token: UUID) {
        eventContinuations.removeValue(forKey: token)
    }

    private func clearEngineMetadata() {
        engineVersion = nil
        capabilities = []
    }

    private static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/.bun/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let current = environment["PATH", default: ""].split(separator: ":").map(String.init)
        environment["PATH"] = Array(NSOrderedSet(array: additions + current))
            .compactMap { $0 as? String }
            .joined(separator: ":")
        return MacSystemProxyEnvironment.mergingCurrentSystemProxy(into: environment)
    }

    private nonisolated static func logEngineError(_ message: String) {
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/TodoAgent", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let line = "[\(ISO8601DateFormatter().string(from: .now))] \(message)\n"
        let url = logDirectory.appending(path: "engine-stderr.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url, options: .atomic)
        }
    }
}

/// `reqwest` reads proxy settings from its process environment, while a macOS
/// app launched from Finder receives its network proxy from CFNetwork instead.
/// Bridge the explicit macOS HTTP/HTTPS settings into the Engine process so
/// Gemini uses the same route as the rest of the user's desktop apps.
enum MacSystemProxyEnvironment {
    static func mergingCurrentSystemProxy(
        into environment: [String: String]
    ) -> [String: String] {
        guard let dictionary = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
            as? [String: Any]
        else {
            return environment
        }
        return merging(proxySettings: dictionary, into: environment)
    }

    static func merging(
        proxySettings: [String: Any],
        into environment: [String: String]
    ) -> [String: String] {
        var result = environment

        if let proxy = proxyURL(
            enabled: proxySettings["HTTPEnable"],
            host: proxySettings["HTTPProxy"],
            port: proxySettings["HTTPPort"]
        ) {
            set(proxy, lowerKey: "http_proxy", upperKey: "HTTP_PROXY", in: &result)
        }

        if let proxy = proxyURL(
            enabled: proxySettings["HTTPSEnable"],
            host: proxySettings["HTTPSProxy"],
            port: proxySettings["HTTPSPort"]
        ) {
            set(proxy, lowerKey: "https_proxy", upperKey: "HTTPS_PROXY", in: &result)
        }

        if let exceptions = proxySettings["ExceptionsList"] as? [String],
           exceptions.isEmpty == false
        {
            let existing = result["no_proxy"] ?? result["NO_PROXY"] ?? ""
            let combined = (existing.split(separator: ",").map(String.init) + exceptions)
                .reduce(into: [String]()) { values, value in
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty == false, values.contains(trimmed) == false {
                        values.append(trimmed)
                    }
                }
                .joined(separator: ",")
            if combined.isEmpty == false {
                result["no_proxy"] = combined
            }
        }

        return result
    }

    private static func set(
        _ value: String,
        lowerKey: String,
        upperKey: String,
        in environment: inout [String: String]
    ) {
        guard environment[lowerKey] == nil, environment[upperKey] == nil else { return }
        environment[lowerKey] = value
    }

    private static func proxyURL(
        enabled: Any?,
        host: Any?,
        port: Any?
    ) -> String? {
        guard number(enabled)?.boolValue == true,
              let host = host as? String,
              host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let port = number(port)?.intValue,
              (1 ... 65_535).contains(port)
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        return components.url?.absoluteString
    }

    private static func number(_ value: Any?) -> NSNumber? {
        if let number = value as? NSNumber { return number }
        if let integer = value as? Int { return NSNumber(value: integer) }
        if let string = value as? String, let integer = Int(string) {
            return NSNumber(value: integer)
        }
        return nil
    }
}

private struct EmptyParams: Encodable, Sendable {}
private struct ShutdownResult: Decodable, Sendable { let ok: Bool }

private struct RequestEnvelope<Params: Encodable>: Encodable {
    let id: String
    let method: String
    let params: Params
}

private extension JSONEncoder {
    static func engine() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static func engine() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
