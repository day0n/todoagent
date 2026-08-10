import Foundation

protocol AppRepository: Sendable {
    var requiresExecutionConsent: Bool { get }
    func load() async throws -> AppSnapshot
    func sync() async throws -> AppSnapshot
    func events() async -> AsyncStream<EngineEvent>
    func createList(name: String, color: String) async throws -> AppSnapshot
    func renameList(listID: UUID, name: String) async throws -> AppSnapshot
    func deleteList(listID: UUID) async throws -> AppSnapshot
    func createTask(
        title: String,
        note: String,
        listID: UUID?,
        executionDate: LocalDay?,
        dueDate: LocalDay?
    ) async throws -> AppSnapshot
    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot
    func deleteTask(taskID: UUID) async throws -> AppSnapshot
    func createListFromTask(taskID: UUID) async throws -> AppSnapshot
    func addTaskAttachments(
        taskID: UUID,
        sourcePaths: [String],
        clientMutationID: UUID
    ) async throws -> AppSnapshot
    func removeTaskAttachment(
        taskID: UUID,
        attachmentID: UUID,
        clientMutationID: UUID
    ) async throws -> AppSnapshot
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
    func clearGeminiKey() async throws
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult
    func assistantStatus() async throws -> AssistantStatus
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor]
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle
    func sendAssistantMessage(sessionID: String, clientMessageID: UUID, text: String, model: String, attachments: [AssistantTextAttachment]) async throws -> AssistantSessionBundle
    func cancelAssistantTurn(sessionID: String) async throws
    func shutdown() async
}

extension AppRepository {
    var requiresExecutionConsent: Bool { false }
    func renameList(listID _: UUID, name _: String) async throws -> AppSnapshot {
        throw AppRepositoryError.listNotFound
    }
    func deleteList(listID _: UUID) async throws -> AppSnapshot {
        throw AppRepositoryError.listNotFound
    }
}

enum AppRepositoryError: LocalizedError, Equatable, Sendable {
    case listNotFound, taskNotFound, sessionNotFound, assistantSessionNotFound, runtimeUnavailable
    var errorDescription: String? {
        switch self {
        case .listNotFound: "找不到这个清单。"
        case .taskNotFound: "找不到这个任务。"
        case .sessionNotFound: "这个任务还没有本地 Session。"
        case .assistantSessionNotFound: "找不到这个 TodoAgent 会话。"
        case .runtimeUnavailable: "所选 Runtime 尚未安装、登录或验证。"
        }
    }
}

actor DemoRepository: AppRepository {
    private var snapshot: AppSnapshot
    private var bundles: [UUID: SessionBundle] = [:]
    private var assistantBundles: [String: AssistantSessionBundle] = [:]

    init(now: Date = .now) {
        let listID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let taskID = UUID(uuidString: "00000000-0000-4000-8000-000000000101")!
        snapshot = AppSnapshot(
            revision: 1,
            lists: [TodoList(id: listID, name: "TodoAgent", colorName: "blue", repositoryPath: "~/Desktop/todoagent")],
            tasks: [TaskItem(id: taskID, listID: listID, title: "接通真实本地 Agent", note: "选择 Runtime 与目录后进入完整 Session", status: .open, executionDate: LocalDay(now), dueDate: nil, completedAt: nil, createdAt: now, updatedAt: ISO8601DateFormatter().string(from: now))],
            runtimes: RuntimeKind.allCases.map { RuntimeInfo(kind: $0, launchPath: nil, resolvedPath: nil, version: "preview", status: .ready, authStatus: "ready", capabilities: [:], providerEngine: $0 == .kiro ? "v2" : nil, detectedAt: nil, verifiedAt: nil, verifyError: nil) },
            sessions: [],
            messages: []
        )

        let assistantSessionID = "00000000-0000-4000-8000-000000000201"
        let assistantSession = AssistantSessionDescriptor(
            id: assistantSessionID,
            title: "原生助手接入",
            createdAt: ISO8601DateFormatter().string(from: now),
            updatedAt: ISO8601DateFormatter().string(from: now),
            lastSequence: 1,
            lastModel: "gemini-3.6-flash"
        )
        let welcome = AssistantMessage(
            id: "00000000-0000-4000-8000-000000000204",
            sessionID: assistantSessionID,
            sequence: 1,
            role: .todoAgent,
            body: "我可以帮你创建任务、整理清单并查看当前进度。",
            taskReferences: [taskID],
            createdAt: ISO8601DateFormatter().string(from: now),
            updatedAt: ISO8601DateFormatter().string(from: now)
        )
        assistantBundles[assistantSessionID] = AssistantSessionBundle(
            session: assistantSession,
            messages: [welcome]
        )
    }

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }

    func createList(name: String, color: String) async throws -> AppSnapshot {
        snapshot.lists.append(
            TodoList(id: UUID(), name: name, colorName: color, repositoryPath: nil)
        )
        snapshot.revision += 1
        return snapshot
    }

    func renameList(listID: UUID, name: String) async throws -> AppSnapshot {
        guard let index = snapshot.lists.firstIndex(where: { $0.id == listID }) else {
            throw AppRepositoryError.listNotFound
        }
        snapshot.lists[index].name = name
        snapshot.revision += 1
        return snapshot
    }

    func deleteList(listID: UUID) async throws -> AppSnapshot {
        guard snapshot.lists.contains(where: { $0.id == listID }) else {
            throw AppRepositoryError.listNotFound
        }
        snapshot.lists.removeAll(where: { $0.id == listID })
        for index in snapshot.tasks.indices where snapshot.tasks[index].listID == listID {
            snapshot.tasks[index].listID = nil
            snapshot.tasks[index].updatedAt = ISO8601DateFormatter().string(from: .now)
        }
        snapshot.revision += 1
        return snapshot
    }

    func createTask(
        title: String,
        note: String,
        listID: UUID?,
        executionDate: LocalDay?,
        dueDate: LocalDay?
    ) async throws -> AppSnapshot {
        snapshot.tasks.insert(TaskItem(id: UUID(), listID: listID, title: title, note: note, status: .open, executionDate: executionDate, dueDate: dueDate, completedAt: nil, createdAt: .now, updatedAt: ISO8601DateFormatter().string(from: .now)), at: 0)
        snapshot.revision += 1
        return snapshot
    }

    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks[index].apply(patch)
        snapshot.tasks[index].updatedAt = ISO8601DateFormatter().string(from: .now)
        snapshot.revision += 1
        return snapshot
    }

    func deleteTask(taskID: UUID) async throws -> AppSnapshot {
        guard snapshot.tasks.contains(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks.removeAll(where: { $0.id == taskID })
        snapshot.sessions.removeAll(where: { $0.taskID == taskID })
        bundles[taskID] = nil
        snapshot.revision += 1
        return snapshot
    }

    func createListFromTask(taskID: UUID) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        let list = TodoList(
            id: UUID(),
            name: snapshot.tasks[index].title,
            colorName: "blue",
            repositoryPath: nil
        )
        snapshot.lists.append(list)
        snapshot.tasks[index].listID = list.id
        snapshot.tasks[index].updatedAt = ISO8601DateFormatter().string(from: .now)
        snapshot.revision += 1
        return snapshot
    }

    func addTaskAttachments(
        taskID: UUID,
        sourcePaths: [String],
        clientMutationID _: UUID
    ) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        let timestamp = ISO8601DateFormatter().string(from: .now)
        snapshot.tasks[index].attachments.append(contentsOf: sourcePaths.map { sourcePath in
            let url = URL(fileURLWithPath: sourcePath)
            return TaskAttachment(
                id: UUID(),
                taskID: taskID,
                originalName: url.lastPathComponent,
                sizeBytes: 0,
                mimeType: "application/octet-stream",
                relativePath: "Attachments/\(UUID().uuidString)-\(url.lastPathComponent)",
                createdAt: timestamp
            )
        })
        snapshot.revision += 1
        return snapshot
    }

    func removeTaskAttachment(
        taskID: UUID,
        attachmentID: UUID,
        clientMutationID _: UUID
    ) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks[index].attachments.removeAll(where: { $0.id == attachmentID })
        snapshot.revision += 1
        return snapshot
    }

    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot {
        try await updateTask(
            taskID: taskID,
            patch: TaskPatch(status: completed ? .completed : .open)
        )
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
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Gemini Demo", version: "preview")
    }

    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(configured: true, available: true, model: "gemini-3.6-flash", reason: nil)
    }

    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] {
        assistantBundles.values
            .map(\.session)
            .filter { includeArchived || !$0.archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle {
        let id = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let session = AssistantSessionDescriptor(
            id: id,
            title: title ?? "",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let bundle = AssistantSessionBundle(session: session)
        assistantBundles[id] = bundle
        return bundle
    }

    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle {
        guard let existing = assistantBundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        let bundle = AssistantSessionBundle(
            session: existing.session.updating(title: title),
            messages: existing.messages,
            tools: existing.tools,
            activeTurn: existing.activeTurn
        )
        assistantBundles[sessionID] = bundle
        return bundle
    }

    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle {
        guard let existing = assistantBundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        let bundle = AssistantSessionBundle(
            session: existing.session.updating(archived: true),
            messages: existing.messages,
            tools: existing.tools,
            activeTurn: existing.activeTurn
        )
        assistantBundles[sessionID] = bundle
        return bundle
    }

    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle {
        guard let bundle = assistantBundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        return AssistantSessionBundle(
            session: bundle.session,
            messages: bundle.messages.filter { $0.sequence > sequence },
            tools: bundle.tools,
            activeTurn: bundle.activeTurn
        )
    }

    func sendAssistantMessage(
        sessionID: String,
        clientMessageID: UUID,
        text: String,
        model: String,
        attachments: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle {
        guard let existing = assistantBundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        let timestamp = ISO8601DateFormatter().string(from: .now)
        let nextSequence = (existing.messages.map(\.sequence).max() ?? 0) + 1
        let userMessage = AssistantMessage(
            id: UUID().uuidString,
            sessionID: sessionID,
            sequence: nextSequence,
            clientMessageID: clientMessageID.uuidString,
            role: .user,
            body: text,
            payloadJSON: Self.attachmentPayloadJSON(attachments),
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let reply = AssistantMessage(
            id: UUID().uuidString,
            sessionID: sessionID,
            sequence: nextSequence + 1,
            role: .todoAgent,
            body: "这是预览模式回复；真实版本会由 Gemini 流式返回。",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let titleSource = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? attachments.first?.name ?? "新对话"
            : text
        let title = existing.session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(titleSource.prefix(30))
            : existing.session.title
        let session = existing.session.updating(
            title: title,
            lastSequence: nextSequence + 1,
            isRunning: false,
            lastModel: model
        )
        let bundle = AssistantSessionBundle(
            session: session,
            messages: existing.messages + [userMessage, reply],
            tools: existing.tools
        )
        assistantBundles[sessionID] = bundle
        return bundle
    }

    private static func attachmentPayloadJSON(_ attachments: [AssistantTextAttachment]) -> String? {
        guard !attachments.isEmpty else { return nil }
        let summaries = attachments.map {
            AssistantAttachmentSummary(name: $0.name, mediaType: $0.mediaType, byteCount: $0.byteCount)
        }
        guard
            let data = try? JSONEncoder().encode(["attachments": summaries]),
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async {}
}
