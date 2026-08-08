import Foundation

private struct EngineBootstrap: Decodable, Sendable {
    let revision: Int64
    let lists: [EngineList]
    let tasks: [EngineTask]
    let runtimes: [RuntimeInfo]
    let sessions: [TaskSessionDescriptor]
}

private struct EngineList: Decodable, Sendable {
    let id: UUID
    let name: String
    let color: String
    let repositoryPath: String?
}

private struct EngineTask: Decodable, Sendable {
    let id: UUID
    let listID: UUID?
    let title: String
    let note: String
    let status: TaskStatus
    let dueDate: String?
    let completedAt: String?
    let createdAt: String
    let updatedAt: String
}

private struct CreateTaskRequest: Encodable, Sendable {
    let title: String
    let note: String
    let listID: UUID?
    let dueDate: String?
}
private struct TaskIDRequest: Encodable, Sendable { let taskID: UUID }
private struct RuntimeRequest: Encodable, Sendable { let kind: RuntimeKind; let executable: String? }
private struct SessionLookup: Encodable, Sendable { let sessionID: String?; let taskID: UUID? }
private struct CreateSessionRequest: Encodable, Sendable { let taskID: UUID; let runtimeKind: RuntimeKind; let workingDirectory: String; let clientMessageID: UUID }
private struct SendSessionRequest: Encodable, Sendable { let sessionID: String; let clientMessageID: UUID; let text: String }
private struct HistoryRequest: Encodable, Sendable { let sessionID: String; let afterSequence: Int64; let limit: Int }
private struct MarkReadRequest: Encodable, Sendable { let sessionID: String; let throughSequence: Int64 }
private struct SessionIDRequest: Encodable, Sendable { let sessionID: String }
private struct WorkspaceRequest: Encodable, Sendable { let path: String }
private struct WorkspaceResult: Decodable, Sendable { let path: String }
private struct SecretRequest: Encodable, Sendable { let geminiAPIKey: String }
private struct EmptyRepositoryParams: Encodable, Sendable {}
private struct EmptyResult: Decodable, Sendable { let ok: Bool }

actor EngineRepository: AppRepository {
    nonisolated let requiresExecutionConsent = true
    private let client: EngineClient
    private var snapshot = AppSnapshot(revision: 0, lists: [], tasks: [], runtimes: [], sessions: [], messages: [])

    init(client: EngineClient) { self.client = client }

    func load() async throws -> AppSnapshot {
        try await client.start()
        _ = try await client.request(method: "runtime.detect", params: EmptyRepositoryParams(), as: [RuntimeInfo].self)
        for runtime in RuntimeKind.allCases {
            _ = try? await client.request(method: "runtime.verify", params: RuntimeRequest(kind: runtime, executable: nil), as: RuntimeInfo.self)
        }
        return try await refresh(method: "app.bootstrap")
    }

    func sync() async throws -> AppSnapshot { try await refresh(method: "app.sync") }
    func events() async -> AsyncStream<EngineEvent> { await client.events() }

    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        let request = CreateTaskRequest(title: title, note: note, listID: listID, dueDate: dueDate.map(Self.dayFormatter.string))
        _ = try await client.request(method: "task.create", params: request, as: EngineTask.self)
        return try await sync()
    }

    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot {
        let method = completed ? "task.complete" : "task.reopen"
        _ = try await client.request(method: method, params: TaskIDRequest(taskID: taskID), as: EngineTask.self)
        return try await sync()
    }

    func detectRuntimes() async throws -> AppSnapshot {
        _ = try await client.request(method: "runtime.detect", params: EmptyRepositoryParams(), as: [RuntimeInfo].self)
        return try await sync()
    }

    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot {
        _ = try await client.request(method: "runtime.verify", params: RuntimeRequest(kind: kind, executable: nil), as: RuntimeInfo.self)
        return try await sync()
    }

    func session(taskID: UUID) async throws -> SessionBundle? {
        do {
            return try await client.request(method: "session.get", params: SessionLookup(sessionID: nil, taskID: taskID), as: SessionBundle.self)
        } catch let error as EngineClientError {
            if case let .requestFailed(code, _) = error, code == "not_found" { return nil }
            throw error
        }
    }

    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle {
        _ = try await client.request(method: "workspace.authorize", params: WorkspaceRequest(path: workspace), as: WorkspaceResult.self)
        return try await client.request(method: "session.create", params: CreateSessionRequest(taskID: taskID, runtimeKind: runtime, workingDirectory: workspace, clientMessageID: UUID()), as: SessionBundle.self)
    }

    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle {
        try await client.request(method: "session.send", params: SendSessionRequest(sessionID: sessionID, clientMessageID: clientMessageID, text: text), as: SessionBundle.self)
    }

    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle {
        try await client.request(method: "session.history", params: HistoryRequest(sessionID: sessionID, afterSequence: sequence, limit: 500), as: SessionBundle.self)
    }

    func markRead(sessionID: String, through sequence: Int64) async throws {
        _ = try await client.request(method: "session.mark_read", params: MarkReadRequest(sessionID: sessionID, throughSequence: sequence), as: TaskSessionDescriptor.self)
    }

    func cancelTurn(sessionID: String) async throws {
        _ = try await client.request(method: "session.cancel_turn", params: SessionIDRequest(sessionID: sessionID), as: EmptyResult.self)
    }

    func injectGeminiKey(_ key: String) async throws {
        _ = try await client.request(method: "secret.inject", params: SecretRequest(geminiAPIKey: key), as: EmptyResult.self)
    }

    func shutdown() async { await client.stop() }

    private func refresh(method: String) async throws -> AppSnapshot {
        let engine: EngineBootstrap = try await client.request(method: method, params: EmptyRepositoryParams())
        snapshot = AppSnapshot(
            revision: engine.revision,
            lists: engine.lists.map { TodoList(id: $0.id, name: $0.name, colorName: $0.color, repositoryPath: $0.repositoryPath) },
            tasks: engine.tasks.map(Self.mapTask),
            runtimes: engine.runtimes,
            sessions: engine.sessions,
            messages: snapshot.messages
        )
        return snapshot
    }

    private static func mapTask(_ task: EngineTask) -> TaskItem {
        TaskItem(id: task.id, listID: task.listID, title: task.title, note: task.note, status: task.status, dueDate: task.dueDate.flatMap(dayFormatter.date), completedAt: task.completedAt, createdAt: ISO8601DateFormatter().date(from: task.createdAt) ?? .distantPast, updatedAt: task.updatedAt)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
