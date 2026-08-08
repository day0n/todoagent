import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let repository: any AppRepository
    private var projection = TaskProjection.empty
    private var eventTask: Task<Void, Never>?
    private var bundles: [UUID: SessionBundle] = [:]

    private(set) var lists: [TodoList] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var runtimes: [RuntimeInfo] = []
    private(set) var sessions: [TaskSessionDescriptor] = []

    var selection: SidebarSelection? = .smart(.timeline)
    var selectedDate = Calendar.current.startOfDay(for: .now)
    var inspectorPresented = true
    var presentedSheet: AppSheet?
    var loadState: AppLoadState = .loading
    var errorMessage: String?

    init(repository: any AppRepository) { self.repository = repository }

    func load() async {
        loadState = .loading
        do {
            apply(try await repository.load())
            if let key = try? KeychainStore.loadGeminiKey(), !key.isEmpty {
                try await repository.injectGeminiKey(key)
            }
            loadState = .loaded
            startEventsIfNeeded()
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func shutdown() async { await repository.shutdown() }

    @discardableResult
    func createTask(title: String, note: String = "", dueDate: Date?) async -> Bool {
        let listID: UUID? = if case let .list(id) = selection { id } else { nil }
        return await update { try await repository.createTask(title: title, note: note, listID: listID, dueDate: dueDate) }
    }

    @discardableResult
    func setCompleted(_ task: TaskItem, completed: Bool) async -> Bool {
        await update { try await repository.setCompleted(taskID: task.id, completed: completed) }
    }

    func openTask(_ task: TaskItem) {
        presentedSheet = .taskSession(task.id)
        Task { await loadSession(for: task) }
    }

    func loadSession(for task: TaskItem) async {
        do {
            if let bundle = try await repository.session(taskID: task.id) {
                merge(bundle, taskID: task.id)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func session(for task: TaskItem) -> TaskSessionDescriptor? {
        bundles[task.id]?.session ?? sessions.first(where: { $0.taskID == task.id })
    }

    func conversation(for task: TaskItem) -> TaskConversationSnapshot? {
        guard let bundle = bundles[task.id] else { return nil }
        return TaskConversationSnapshot(bundle: bundle)
    }

    func suggestedWorkspace(for task: TaskItem) -> String {
        task.listID.flatMap { id in lists.first(where: { $0.id == id })?.repositoryPath } ?? ""
    }

    func hasUnreadAgentMessage(for task: TaskItem) -> Bool { session(for: task)?.hasUnread == true }

    @discardableResult
    func startSession(_ task: TaskItem, runtime: RuntimeKind, workspace: String) async -> Bool {
        let directory = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { errorMessage = "请选择 Agent 执行目录。"; return false }
        guard runtimes.first(where: { $0.kind == runtime })?.isSelectable == true else {
            errorMessage = "\(runtime.title) 尚未安装、登录或验证。"
            return false
        }
        if repository.requiresExecutionConsent {
            guard await ExecutionSafety.authorize(runtime: runtime, workspace: directory) else { return false }
        }
        do {
            let bundle = try await repository.createSession(taskID: task.id, runtime: runtime, workspace: directory)
            merge(bundle, taskID: task.id)
            apply(try await repository.sync())
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult
    func sendToSession(_ task: TaskItem, text: String) async -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let session = session(for: task), !session.state.isBusy else { return false }
        do {
            let bundle = try await repository.send(sessionID: session.id, text: value, clientMessageID: UUID())
            merge(bundle, taskID: task.id)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func cancelTurn(for task: TaskItem) async {
        guard let session = session(for: task), session.state.isBusy else { return }
        do { try await repository.cancelTurn(sessionID: session.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func markReadIfCurrent(_ task: TaskItem) async {
        guard NSApp.isActive, presentedSheet == .taskSession(task.id), let bundle = bundles[task.id], let sequence = bundle.messages.last?.sequence, sequence >= bundle.session.lastAgentSequence else { return }
        do {
            try await repository.markRead(sessionID: bundle.session.id, through: sequence)
            await refreshSession(taskID: task.id, after: sequence)
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshSession(taskID: UUID, after sequence: Int64 = 0) async {
        guard let session = sessions.first(where: { $0.taskID == taskID }) ?? bundles[taskID]?.session else { return }
        do {
            let incoming = try await repository.history(sessionID: session.id, after: sequence)
            merge(incoming, taskID: taskID)
        } catch { errorMessage = error.localizedDescription }
    }

    func detectRuntimes() async { _ = await update { try await repository.detectRuntimes() } }
    func verifyRuntime(_ kind: RuntimeKind) async { _ = await update { try await repository.verifyRuntime(kind) } }
    func injectGeminiKey(_ key: String) async throws { try await repository.injectGeminiKey(key) }
    func runtime(_ kind: RuntimeKind) -> RuntimeInfo? { runtimes.first(where: { $0.kind == kind }) }

    func count(for view: SmartView) -> Int { projection.count(for: view, sessions: sessions) }
    func activeCount(forList id: UUID) -> Int { projection.activeCount(forList: id) }
    func task(id: UUID) -> TaskItem? { projection.task(id: id) }
    func timelineBuckets() -> [BoardBucket: [TaskItem]] { projection.timelineBuckets(selectedDate: selectedDate) }
    func visibleTasks() -> [TaskItem] {
        guard let selection else { return tasks }
        switch selection {
        case let .smart(view):
            switch view {
            case .timeline, .tasks: return tasks
            case .running: return tasks.filter { task in session(for: task)?.state.isBusy == true }
            case .done: return tasks.filter { $0.status == .completed }
            }
        case let .list(id): return tasks.filter { $0.listID == id }
        }
    }
    func titleForSelection() -> String {
        guard let selection else { return "时间线" }
        return switch selection {
        case let .smart(view): view.title
        case let .list(id): lists.first(where: { $0.id == id })?.name ?? "清单"
        }
    }

    private func startEventsIfNeeded() {
        guard eventTask == nil else { return }
        let repository = repository
        eventTask = Task { [weak self] in
            let stream = await repository.events()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(event)
            }
        }
    }

    private func consume(_ event: EngineEvent) async {
        if event.name.hasPrefix("session.") {
            if let bundle = try? JSONDecoder.engineDecoder.decode(SessionBundle.self, from: event.data) {
                merge(bundle, taskID: bundle.session.taskID)
            } else if let session = try? JSONDecoder.engineDecoder.decode(TaskSessionDescriptor.self, from: event.data), let task = tasks.first(where: { $0.id == session.taskID }) {
                sessions.removeAll(where: { $0.id == session.id }); sessions.append(session)
                await refreshSession(taskID: task.id, after: bundles[task.id]?.messages.last?.sequence ?? 0)
            } else if let message = try? JSONDecoder.engineDecoder.decode(SessionMessage.self, from: event.data), let session = sessions.first(where: { $0.id == message.sessionID }) {
                await refreshSession(taskID: session.taskID, after: bundles[session.taskID]?.messages.last?.sequence ?? 0)
            }
        } else if event.name == "task.changed" || event.name == "runtime.changed" {
            _ = await update { try await repository.sync() }
        }
    }

    private func merge(_ incoming: SessionBundle, taskID: UUID) {
        let existing = bundles[taskID]
        var bySequence = Dictionary(uniqueKeysWithValues: (existing?.messages ?? []).map { ($0.sequence, $0) })
        for message in incoming.messages { bySequence[message.sequence] = message }
        let messages = bySequence.values.sorted { $0.sequence < $1.sequence }
        bundles[taskID] = SessionBundle(session: incoming.session, messages: messages, activeTurn: incoming.activeTurn)
        sessions.removeAll(where: { $0.id == incoming.session.id })
        sessions.append(incoming.session)
    }

    private func update(_ operation: () async throws -> AppSnapshot) async -> Bool {
        do { apply(try await operation()); errorMessage = nil; return true }
        catch is CancellationError { return false }
        catch { errorMessage = error.localizedDescription; return false }
    }

    private func apply(_ snapshot: AppSnapshot) {
        lists = snapshot.lists
        tasks = snapshot.tasks
        runtimes = snapshot.runtimes
        sessions = snapshot.sessions
        messages = snapshot.messages
        projection = TaskProjection(tasks: snapshot.tasks)
    }
}

private extension JSONDecoder {
    static var engineDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
