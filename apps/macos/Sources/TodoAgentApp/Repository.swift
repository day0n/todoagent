import Foundation

protocol AppRepository: Sendable {
    var requiresExecutionConsent: Bool { get }
    func load() async throws -> AppSnapshot
    func sync() async throws -> AppSnapshot
    func events() async -> AsyncStream<EngineEvent>
    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot
    func detectRuntimes() async throws -> AppSnapshot
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot
    func session(taskID: UUID) async throws -> SessionBundle?
    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle
    func markRead(sessionID: String, through sequence: Int64) async throws
    func cancelTurn(sessionID: String) async throws
    func injectGeminiKey(_ key: String) async throws
    func shutdown() async
}

extension AppRepository { var requiresExecutionConsent: Bool { false } }

enum AppRepositoryError: LocalizedError, Equatable, Sendable {
    case taskNotFound, sessionNotFound, runtimeUnavailable
    var errorDescription: String? {
        switch self {
        case .taskNotFound: "找不到这个任务。"
        case .sessionNotFound: "这个任务还没有本地 Session。"
        case .runtimeUnavailable: "所选 Runtime 尚未安装、登录或验证。"
        }
    }
}

actor DemoRepository: AppRepository {
    private var snapshot: AppSnapshot
    private var bundles: [UUID: SessionBundle] = [:]

    init(now: Date = .now) {
        let listID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let taskID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
        snapshot = AppSnapshot(
            revision: 1,
            lists: [TodoList(id: listID, name: "TodoAgent", colorName: "blue", repositoryPath: "~/Desktop/todoagent")],
            tasks: [TaskItem(id: taskID, listID: listID, title: "接通真实本地 Agent", note: "选择 Runtime 与目录后进入完整 Session", status: .open, dueDate: Calendar.current.startOfDay(for: now), completedAt: nil, createdAt: now, updatedAt: ISO8601DateFormatter().string(from: now))],
            runtimes: RuntimeKind.allCases.map { RuntimeInfo(kind: $0, launchPath: nil, resolvedPath: nil, version: "preview", status: .ready, authStatus: "ready", capabilities: [:], providerEngine: $0 == .kiro ? "v2" : nil, detectedAt: nil, verifiedAt: nil, verifyError: nil) },
            sessions: [],
            messages: []
        )
    }

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }

    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        snapshot.tasks.insert(TaskItem(id: UUID(), listID: listID, title: title, note: note, status: .open, dueDate: dueDate, completedAt: nil, createdAt: .now, updatedAt: ISO8601DateFormatter().string(from: .now)), at: 0)
        snapshot.revision += 1
        return snapshot
    }

    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else { throw AppRepositoryError.taskNotFound }
        snapshot.tasks[index].status = completed ? .completed : .open
        snapshot.revision += 1
        return snapshot
    }

    func detectRuntimes() async throws -> AppSnapshot { snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }
    func session(taskID: UUID) async throws -> SessionBundle? { bundles[taskID] }

    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle {
        let id = UUID().uuidString
        let session = TaskSessionDescriptor(id: id, taskID: taskID, runtimeKind: runtime, workingDirectory: workspace, providerSessionID: nil, providerEngine: runtime == .kiro ? "v2" : nil, state: .idle, lastAgentSequence: 0, lastReadSequence: 0, lastErrorCode: nil, lastErrorMessage: nil, createdAt: "", updatedAt: "")
        let bundle = SessionBundle(session: session, messages: [], activeTurn: nil)
        bundles[taskID] = bundle
        snapshot.sessions.append(session)
        return bundle
    }

    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle {
        guard let taskID = bundles.first(where: { $0.value.session.id == sessionID })?.key, var bundle = bundles[taskID] else { throw AppRepositoryError.sessionNotFound }
        let sequence = Int64(bundle.messages.count + 1)
        let message = SessionMessage(id: UUID().uuidString, sessionID: sessionID, turnID: nil, sequence: sequence, clientMessageID: clientMessageID.uuidString, role: .user, kind: "text", body: text, payloadJSON: nil, createdAt: "", updatedAt: "")
        bundle = SessionBundle(session: bundle.session, messages: bundle.messages + [message], activeTurn: nil)
        bundles[taskID] = bundle
        return bundle
    }

    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle {
        guard let bundle = bundles.values.first(where: { $0.session.id == sessionID }) else { throw AppRepositoryError.sessionNotFound }
        return SessionBundle(session: bundle.session, messages: bundle.messages.filter { $0.sequence > sequence }, activeTurn: bundle.activeTurn)
    }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {}
    func shutdown() async {}
}
