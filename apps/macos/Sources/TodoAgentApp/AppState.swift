import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let repository: any AppRepository
    private var projection = TaskProjection.empty
    private var mutationGeneration: UInt64 = 0
    private var mutationTail: Task<MutationOutcome, Never>?
    private var loadGeneration: UInt64 = 0
    private var configuredSessions: [UUID: TaskSessionDescriptor] = [:]
    private var sessionEntries: [UUID: [TaskConversationEntry]] = [:]
    private var readAgentMessages: Set<UUID> = []

    private(set) var lists: [TodoList] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var messages: [ChatMessage] = []

    var selection: SidebarSelection? = .smart(.timeline)
    var selectedDate = Calendar.current.startOfDay(for: .now)
    var inspectorPresented = true
    var presentedSheet: AppSheet?
    var loadState: AppLoadState = .loading
    var errorMessage: String?

    init(repository: any AppRepository) {
        self.repository = repository
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadState = .loading

        do {
            let snapshot = try await repository.load()
            guard generation == loadGeneration else { return }
            apply(snapshot)
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func createTask(title: String, dueDate: Date?) async -> Bool {
        let listID: UUID? = if case let .list(id) = selection { id } else { nil }
        return await mutate { repository in
            try await repository.createTask(title: title, listID: listID, dueDate: dueDate)
        }
    }

    func openTask(_ task: TaskItem) {
        readAgentMessages.insert(task.id)
        presentedSheet = .taskSession(task.id)
    }

    func session(for task: TaskItem) -> TaskSessionDescriptor? {
        if let configured = configuredSessions[task.id] { return configured }
        guard let runtime = task.runtime else { return nil }

        let workspace = task.listID
            .flatMap { listID in lists.first(where: { $0.id == listID })?.repositoryPath }
            ?? "~/Desktop"
        return TaskSessionDescriptor(
            runtime: runtime,
            workspace: workspace,
            sessionID: Self.sessionID(runtime: runtime, taskID: task.id)
        )
    }

    func suggestedWorkspace(for task: TaskItem) -> String {
        task.listID
            .flatMap { listID in lists.first(where: { $0.id == listID })?.repositoryPath }
            ?? ""
    }

    func conversation(for task: TaskItem) -> TaskConversationSnapshot? {
        guard let descriptor = session(for: task) else { return nil }
        let base = DemoTaskConversation.snapshot(for: task, session: descriptor)
        return TaskConversationSnapshot(
            sessionID: base.sessionID,
            runtime: base.runtime,
            workspace: base.workspace,
            entries: base.entries + (sessionEntries[task.id] ?? [])
        )
    }

    func hasUnreadAgentMessage(for task: TaskItem) -> Bool {
        task.status == .needsYou && !readAgentMessages.contains(task.id)
    }

    @discardableResult
    func startSession(_ task: TaskItem, runtime: String, workspace: String) async -> Bool {
        let normalizedWorkspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedWorkspace.isEmpty else {
            errorMessage = "请选择 Agent 执行目录。"
            return false
        }

        let started = await transition(task, to: .running)
        guard started else { return false }

        configuredSessions[task.id] = TaskSessionDescriptor(
            runtime: runtime,
            workspace: normalizedWorkspace,
            sessionID: Self.sessionID(runtime: runtime, taskID: task.id)
        )
        sessionEntries[task.id, default: []].append(
            TaskConversationEntry(
                id: UUID().uuidString,
                role: .system,
                title: "本地 Agent 已启动",
                body: "\(runtime) 已在 \(normalizedWorkspace) 启动。"
            )
        )
        return true
    }

    @discardableResult
    func sendToSession(_ task: TaskItem, text: String) async -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, session(for: task) != nil else { return false }

        if task.status == .needsYou {
            return await answer(task, text: value)
        }

        sessionEntries[task.id, default: []].append(
            TaskConversationEntry(id: UUID().uuidString, role: .user, title: nil, body: value)
        )
        sessionEntries[task.id, default: []].append(
            TaskConversationEntry(
                id: UUID().uuidString,
                role: .system,
                title: "已发送到本地 Session",
                body: "预览模式已保留这条消息；接入 Engine 后会在同一 CLI session 中真实续跑。"
            )
        )
        return true
    }

    @discardableResult
    func start(_ task: TaskItem) async -> Bool {
        await transition(task, to: .running)
    }

    @discardableResult
    func confirm(_ task: TaskItem) async -> Bool {
        await transition(task, to: .done)
    }

    @discardableResult
    func reopen(_ task: TaskItem) async -> Bool {
        await transition(task, to: .todo)
    }

    @discardableResult
    func cancel(_ task: TaskItem) async -> Bool {
        do {
            try TaskStateMachine.validate(from: currentStatus(for: task), to: .todo)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        return await mutate { repository in
            try await repository.cancel(taskID: task.id)
        }
    }

    @discardableResult
    func answer(_ task: TaskItem, text: String) async -> Bool {
        do {
            try TaskStateMachine.validate(from: currentStatus(for: task), to: .running)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        return await mutate { repository in
            try await repository.answer(taskID: task.id, text: text)
        }
    }

    @discardableResult
    func sendChat(_ text: String) async -> Bool {
        await mutate { repository in
            try await repository.sendChat(text)
        }
    }

    func count(for view: SmartView) -> Int {
        projection.count(for: view)
    }

    func activeCount(forList id: UUID) -> Int {
        projection.activeCount(forList: id)
    }

    func contextCount(for status: TaskStatus) -> Int {
        projection.count(for: status)
    }

    func task(id: UUID) -> TaskItem? {
        projection.task(id: id)
    }

    func timelineBuckets() -> [BoardBucket: [TaskItem]] {
        projection.timelineBuckets(selectedDate: selectedDate)
    }

    func visibleTasks() -> [TaskItem] {
        guard let selection else { return tasks }
        switch selection {
        case let .smart(view):
            return switch view {
            case .timeline, .tasks: tasks
            case .running: tasks.filter { $0.status == .running }
            case .done: tasks.filter { $0.status == .done }
            }
        case let .list(id):
            return tasks.filter { $0.listID == id }
        }
    }

    func titleForSelection() -> String {
        guard let selection else { return "时间线" }
        switch selection {
        case let .smart(view): return view.title
        case let .list(id): return lists.first(where: { $0.id == id })?.name ?? "清单"
        }
    }

    private func transition(_ task: TaskItem, to status: TaskStatus) async -> Bool {
        do {
            try TaskStateMachine.validate(from: currentStatus(for: task), to: status)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }

        return await mutate { repository in
            try await repository.setStatus(taskID: task.id, status: status)
        }
    }

    private func currentStatus(for task: TaskItem) -> TaskStatus {
        projection.task(id: task.id)?.status ?? task.status
    }

    private func mutate(
        _ operation: @escaping @Sendable (any AppRepository) async throws -> AppSnapshot
    ) async -> Bool {
        mutationGeneration &+= 1
        let generation = mutationGeneration
        let previous = mutationTail
        let repository = repository
        let mutation = Task<MutationOutcome, Never> {
            _ = await previous?.value
            guard !Task.isCancelled else { return .cancelled }

            do {
                return .success(try await operation(repository))
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(error.localizedDescription)
            }
        }
        mutationTail = mutation

        let outcome = await withTaskCancellationHandler {
            await mutation.value
        } onCancel: {
            mutation.cancel()
        }

        if generation == mutationGeneration {
            mutationTail = nil
        }

        switch outcome {
        case let .success(snapshot):
            // A newer queued mutation will return a snapshot that already includes
            // this one, so only the newest result needs to refresh observed state.
            if generation == mutationGeneration {
                apply(snapshot)
                errorMessage = nil
            }
            return true
        case let .failure(message):
            if generation == mutationGeneration { errorMessage = message }
            return false
        case .cancelled:
            return false
        }
    }

    private func apply(_ snapshot: AppSnapshot) {
        if lists != snapshot.lists { lists = snapshot.lists }
        if tasks != snapshot.tasks {
            tasks = snapshot.tasks
            projection = TaskProjection(tasks: snapshot.tasks)
        }
        if messages != snapshot.messages { messages = snapshot.messages }
    }

    private static func sessionID(runtime: String, taskID: UUID) -> String {
        let prefix = runtime.lowercased().replacingOccurrences(of: " ", with: "-")
        return "\(prefix)-\(taskID.uuidString.prefix(8).lowercased())"
    }
}

private enum MutationOutcome: Sendable {
    case success(AppSnapshot)
    case failure(String)
    case cancelled
}
