import Foundation

struct EngineBootstrap: Decodable, Sendable {
    let revision: Int64
    let lists: [EngineList]
    let tasks: [EngineTask]
    let taskAttachments: [TaskAttachment]
    let runtimes: [RuntimeInfo]
    let sessions: [TaskSessionDescriptor]
}

struct EngineList: Decodable, Sendable {
    let id: UUID
    let name: String
    let color: String
    let repositoryPath: String?
}

struct EngineTask: Decodable, Sendable {
    let id: UUID
    let listID: UUID?
    let title: String
    let note: String
    let status: TaskStatus
    let executionDate: LocalDay?
    let dueDate: LocalDay?
    let completedAt: String?
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case listID = "listId"
        case title, note, status, executionDate, dueDate, completedAt, createdAt, updatedAt
    }
}

struct CreateTaskRequest: Encodable, Sendable {
    let title: String
    let note: String
    let listID: UUID?
    let executionDate: LocalDay?
    let dueDate: LocalDay?

    private enum CodingKeys: String, CodingKey {
        case title, note
        case listID = "listId"
        case executionDate, dueDate
    }
}
struct UpdateTaskRequest: Encodable, Sendable {
    let taskID: UUID
    let patch: TaskPatch

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
        case patch
    }
}
struct DeleteTaskRequest: Encodable, Sendable {
    let taskID: UUID

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
    }
}
struct CreateListFromTaskRequest: Encodable, Sendable {
    let taskID: UUID

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
    }
}
struct AddTaskAttachmentsRequest: Encodable, Sendable {
    let taskID: UUID
    let sourcePaths: [String]
    let clientMutationID: UUID

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
        case sourcePaths
        case clientMutationID = "clientMutationId"
    }
}
struct RemoveTaskAttachmentRequest: Encodable, Sendable {
    let taskID: UUID
    let attachmentID: UUID
    let clientMutationID: UUID

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
        case attachmentID = "attachmentId"
        case clientMutationID = "clientMutationId"
    }
}
struct CreateListRequest: Encodable, Sendable {
    let name: String
    let color: String
    let repositoryPath: String?
}
struct TaskIDRequest: Encodable, Sendable {
    let taskID: UUID
    private enum CodingKeys: String, CodingKey { case taskID = "taskId" }
}
private struct RuntimeRequest: Encodable, Sendable { let kind: RuntimeKind; let executable: String? }
struct SessionLookup: Encodable, Sendable {
    let sessionID: String?
    let taskID: UUID?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case taskID = "taskId"
    }
}
struct CreateSessionRequest: Encodable, Sendable {
    let taskID: UUID
    let runtimeKind: RuntimeKind
    let workingDirectory: String

    private enum CodingKeys: String, CodingKey {
        case taskID = "taskId"
        case runtimeKind, workingDirectory
    }
}
struct SendSessionRequest: Encodable, Sendable {
    let sessionID: String
    let clientMessageID: UUID
    let text: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case clientMessageID = "clientMessageId"
        case text
    }
}
struct HistoryRequest: Encodable, Sendable {
    let sessionID: String
    let afterSequence: Int64
    let limit: Int

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case afterSequence, limit
    }
}
struct MarkReadRequest: Encodable, Sendable {
    let sessionID: String
    let throughSequence: Int64

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case throughSequence
    }
}
struct SessionIDRequest: Encodable, Sendable {
    let sessionID: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
}
private struct WorkspaceRequest: Encodable, Sendable { let path: String }
private struct WorkspaceResult: Decodable, Sendable { let path: String }
struct SecretRequest: Encodable, Sendable {
    let geminiAPIKey: String

    enum CodingKeys: String, CodingKey {
        case geminiAPIKey = "geminiApiKey"
    }
}
struct GeminiTestRequest: Encodable, Sendable { let model: String }
private struct EmptyRepositoryParams: Encodable, Sendable {}
private struct EmptyResult: Decodable, Sendable { let ok: Bool }

actor EngineRepository: AppRepository {
    nonisolated let requiresExecutionConsent = true
    private static let runtimeVerificationTimeout: Duration = .seconds(30)
    private static let attachmentMutationTimeout: Duration = .seconds(300)
    private let client: EngineClient
    private var snapshot = AppSnapshot(revision: 0, lists: [], tasks: [], runtimes: [], sessions: [], messages: [])

    init(client: EngineClient) { self.client = client }

    func load() async throws -> AppSnapshot {
        try await client.start()
        return try await refresh(method: "app.bootstrap")
    }

    func sync() async throws -> AppSnapshot { try await refresh(method: "app.sync") }
    func events() async -> AsyncStream<EngineEvent> { await client.events() }

    func createList(name: String, color: String) async throws -> AppSnapshot {
        let request = CreateListRequest(name: name, color: color, repositoryPath: nil)
        _ = try await client.request(method: "list.create", params: request, as: EngineList.self)
        return try await sync()
    }

    func createTask(
        title: String,
        note: String,
        listID: UUID?,
        executionDate: LocalDay?,
        dueDate: LocalDay?
    ) async throws -> AppSnapshot {
        try await mutate(
            method: "task.create",
            params: CreateTaskRequest(
                title: title,
                note: note,
                listID: listID,
                executionDate: executionDate,
                dueDate: dueDate
            )
        )
    }

    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot {
        try await mutate(
            method: "task.update",
            params: UpdateTaskRequest(taskID: taskID, patch: patch)
        )
    }

    func deleteTask(taskID: UUID) async throws -> AppSnapshot {
        try await mutate(
            method: "task.delete",
            params: DeleteTaskRequest(taskID: taskID)
        )
    }

    func createListFromTask(taskID: UUID) async throws -> AppSnapshot {
        try await mutate(
            method: "task.create_list",
            params: CreateListFromTaskRequest(taskID: taskID)
        )
    }

    func addTaskAttachments(
        taskID: UUID,
        sourcePaths: [String],
        clientMutationID: UUID
    ) async throws -> AppSnapshot {
        try await mutate(
            method: "task.attachment.add",
            params: AddTaskAttachmentsRequest(
                taskID: taskID,
                sourcePaths: sourcePaths,
                clientMutationID: clientMutationID
            ),
            timeout: Self.attachmentMutationTimeout
        )
    }

    func removeTaskAttachment(
        taskID: UUID,
        attachmentID: UUID,
        clientMutationID: UUID
    ) async throws -> AppSnapshot {
        try await mutate(
            method: "task.attachment.remove",
            params: RemoveTaskAttachmentRequest(
                taskID: taskID,
                attachmentID: attachmentID,
                clientMutationID: clientMutationID
            )
        )
    }

    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot {
        let method = completed ? "task.complete" : "task.reopen"
        return try await mutate(method: method, params: TaskIDRequest(taskID: taskID))
    }

    func detectRuntimes() async throws -> AppSnapshot {
        _ = try await client.request(method: "runtime.detect", params: EmptyRepositoryParams(), as: [RuntimeInfo].self)
        return try await sync()
    }

    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot {
        _ = try await client.request(
            method: "runtime.verify",
            params: RuntimeRequest(kind: kind, executable: nil),
            as: RuntimeInfo.self,
            timeout: Self.runtimeVerificationTimeout
        )
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
        return try await client.request(
            method: "session.create",
            params: CreateSessionRequest(
                taskID: taskID,
                runtimeKind: runtime,
                workingDirectory: workspace
            ),
            as: SessionBundle.self
        )
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

    func clearGeminiKey() async throws {
        _ = try await client.request(method: "secret.clear", params: EmptyRepositoryParams(), as: EmptyResult.self)
    }

    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        try await client.request(method: "gemini.test", params: GeminiTestRequest(model: model), as: GeminiConnectionResult.self)
    }

    func assistantStatus() async throws -> AssistantStatus {
        try await client.request(
            method: "assistant.status",
            params: AssistantEmptyRequest(),
            as: AssistantStatus.self
        )
    }

    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] {
        let response: AssistantSessionListResponse = try await client.request(
            method: "assistant.session.list",
            params: AssistantSessionListRequest(includeArchived: includeArchived)
        )
        return response.sessions
    }

    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle {
        let response: AssistantSessionResponse = try await client.request(
            method: "assistant.session.create",
            params: AssistantSessionCreateRequest(title: title)
        )
        return response.bundle
    }

    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle {
        let response: AssistantSessionResponse = try await client.request(
            method: "assistant.session.rename",
            params: AssistantSessionRenameRequest(sessionID: sessionID, title: title)
        )
        return response.bundle
    }

    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle {
        let response: AssistantSessionResponse = try await client.request(
            method: "assistant.session.archive",
            params: AssistantSessionArchiveRequest(sessionID: sessionID)
        )
        return response.bundle
    }

    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle {
        try await client.request(
            method: "assistant.history",
            params: AssistantHistoryRequest(sessionID: sessionID, afterSequence: sequence, limit: 500),
            as: AssistantSessionBundle.self
        )
    }

    func sendAssistantMessage(
        sessionID: String,
        clientMessageID: UUID,
        text: String,
        model: String,
        attachments: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle {
        try await client.request(
            method: "assistant.send",
            params: AssistantSendRequest(
                sessionID: sessionID,
                clientMessageID: clientMessageID,
                text: text,
                model: model,
                attachments: attachments
            ),
            as: AssistantSessionBundle.self
        )
    }

    func cancelAssistantTurn(sessionID: String) async throws {
        _ = try await client.request(
            method: "assistant.cancel_turn",
            params: AssistantCancelTurnRequest(sessionID: sessionID),
            as: EmptyResult.self
        )
    }

    func shutdown() async { await client.stop() }

    private func refresh(method: String) async throws -> AppSnapshot {
        let engine: EngineBootstrap = try await client.request(method: method, params: EmptyRepositoryParams())
        let incoming = Self.mapSnapshot(engine, messages: snapshot.messages)
        if incoming.revision >= snapshot.revision { snapshot = incoming }
        return incoming
    }

    private func mutate<Params: Encodable & Sendable>(
        method: String,
        params: Params,
        timeout: Duration? = nil
    ) async throws -> AppSnapshot {
        let engine: EngineBootstrap = try await client.request(
            method: method,
            params: params,
            timeout: timeout
        )
        let incoming = Self.mapSnapshot(engine, messages: snapshot.messages)
        if incoming.revision >= snapshot.revision { snapshot = incoming }
        return incoming
    }

    nonisolated static func mapSnapshot(
        _ engine: EngineBootstrap,
        messages: [ChatMessage]
    ) -> AppSnapshot {
        let attachmentsByTask = Dictionary(grouping: engine.taskAttachments, by: \.taskID)
        return AppSnapshot(
            revision: engine.revision,
            lists: engine.lists.map { TodoList(id: $0.id, name: $0.name, colorName: $0.color, repositoryPath: $0.repositoryPath) },
            tasks: engine.tasks.map { task in
                Self.mapTask(task, attachments: attachmentsByTask[task.id, default: []])
            },
            runtimes: engine.runtimes,
            sessions: engine.sessions,
            messages: messages
        )
    }

    private nonisolated static func mapTask(
        _ task: EngineTask,
        attachments: [TaskAttachment]
    ) -> TaskItem {
        TaskItem(
            id: task.id,
            listID: task.listID,
            title: task.title,
            note: task.note,
            status: task.status,
            executionDate: task.executionDate,
            dueDate: task.dueDate,
            attachments: attachments,
            completedAt: task.completedAt,
            createdAt: ISO8601DateFormatter().date(from: task.createdAt) ?? .distantPast,
            updatedAt: task.updatedAt
        )
    }
}
