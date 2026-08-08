import Foundation

private struct EngineSnapshot: Decodable, Sendable {
    let lists: [EngineList]
    let tasks: [EngineTask]
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
    let needsKind: NeedsKind?
    let needsText: String?
    let runtimeKind: String?
    let createdAt: Date
}

private struct CreateTaskRequest: Encodable, Sendable {
    let title: String
    let listID: UUID?
    let dueDate: String?
}

private struct SetStatusRequest: Encodable, Sendable {
    let taskID: UUID
    let status: TaskStatus
}

/// Production repository adapter. DemoRepository remains the default until the
/// preview UI is accepted and the Engine feature set is complete.
actor EngineRepository: AppRepository {
    private let client: EngineClient
    private var snapshot = AppSnapshot(lists: [], tasks: [], messages: [])

    init(client: EngineClient) {
        self.client = client
    }

    func load() async throws -> AppSnapshot {
        try await client.start()
        return try await refresh()
    }

    func createTask(title: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        let value = CreateTaskRequest(
            title: title,
            listID: listID,
            dueDate: dueDate.map(Self.dayFormatter.string)
        )
        _ = try await client.request(method: "task.create", params: value, as: EngineTask.self)
        return try await refresh()
    }

    func setStatus(taskID: UUID, status: TaskStatus) async throws -> AppSnapshot {
        guard let task = snapshot.tasks.first(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        try TaskStateMachine.validate(from: task.status, to: status)
        let value = SetStatusRequest(taskID: taskID, status: status)
        _ = try await client.request(method: "task.set_status", params: value, as: EngineTask.self)
        return try await refresh()
    }

    func answer(taskID: UUID, text: String) async throws -> AppSnapshot {
        // The Engine will expose task.answer with real Codex/Claude resume in the execution milestone.
        return try await setStatus(taskID: taskID, status: .running)
    }

    func cancel(taskID: UUID) async throws -> AppSnapshot {
        // The Engine will expose run.cancel once process-group management lands.
        return try await setStatus(taskID: taskID, status: .todo)
    }

    func sendChat(_ text: String) async throws -> AppSnapshot {
        // Gemini stays disabled until a Keychain-backed key is explicitly configured.
        snapshot
    }

    private func refresh() async throws -> AppSnapshot {
        let engine: EngineSnapshot = try await client.request(
            method: "app.snapshot",
            params: EmptyRepositoryParams()
        )
        snapshot = AppSnapshot(
            lists: engine.lists.map {
                TodoList(id: $0.id, name: $0.name, colorName: $0.color, repositoryPath: $0.repositoryPath)
            },
            tasks: engine.tasks.map(Self.mapTask),
            messages: snapshot.messages
        )
        return snapshot
    }

    private static func mapTask(_ task: EngineTask) -> TaskItem {
        TaskItem(
            id: task.id,
            listID: task.listID,
            title: task.title,
            note: task.note,
            status: task.status,
            dueDate: task.dueDate.flatMap(dayFormatter.date),
            needsKind: task.needsKind,
            needsText: task.needsText,
            runtime: task.runtimeKind?.capitalized,
            elapsed: nil,
            resultText: nil,
            diffPreview: nil,
            createdAt: task.createdAt
        )
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct EmptyRepositoryParams: Encodable, Sendable {}
