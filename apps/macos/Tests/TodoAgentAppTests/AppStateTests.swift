import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Native task and session state")
@MainActor
struct AppStateTests {
    @Test("Gemini secret uses the IPC v2 field spelling")
    func geminiSecretWireName() throws {
        let data = try JSONEncoder().encode(SecretRequest(geminiAPIKey: "test-secret"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["geminiApiKey"] == "test-secret")
        #expect(object["geminiAPIKey"] == nil)
    }

    @Test("TodoAgent starts with its inspector collapsed")
    func assistantStartsCollapsed() {
        let state = AppState(repository: AssistantTestRepository())

        #expect(state.inspectorPresented == false)
    }

    @Test("opening TodoAgent expands the inspector without creating a conversation")
    func openingAssistantDoesNotCreateSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)

        state.openAssistant()

        #expect(state.inspectorPresented)
        #expect(try await repository.assistantSessions(includeArchived: false).isEmpty)
    }

    @Test("an unconfigured TodoAgent opens recovery without creating a conversation")
    func unconfiguredAssistantDoesNotCreateSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)
        #expect(state.assistant.canUseAssistant == false)

        #expect(await state.openNewAssistantConversation() == false)

        #expect(state.inspectorPresented)
        #expect(try await repository.assistantSessions(includeArchived: false).isEmpty)
        #expect(state.assistant.selectedSessionID == nil)
    }

    @Test("a ready TodoAgent creates and selects exactly one conversation")
    func readyAssistantCreatesOneSelectedSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)
        await state.load()
        #expect(state.assistant.canUseAssistant)

        #expect(await state.openNewAssistantConversation())

        let sessions = try await repository.assistantSessions(includeArchived: false)
        let session = try #require(sessions.first)
        #expect(state.inspectorPresented)
        #expect(sessions.count == 1)
        #expect(state.assistant.selectedSessionID == session.id)
    }

    @Test("the total tasks add row presents creation without forcing a list")
    func totalTasksCreationHasNoListContext() async {
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        state.selection = .smart(.tasks)

        state.presentNewTask()

        #expect(state.presentedSheet == .newTask)
        #expect(state.pendingNewTaskListID == nil)
        #expect(await repository.taskCreateCalls().isEmpty)
    }

    @Test("an empty user list still presents creation with that list context")
    func emptyUserListCreationKeepsListContext() async {
        let listID = UUID(uuidString: "00000000-0000-4000-8000-000000000501")!
        let list = TodoList(id: listID, name: "空清单", colorName: "blue", repositoryPath: nil)
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot(lists: [list]))
        let state = AppState(repository: repository)
        await state.load()
        state.selection = .list(listID)

        #expect(state.visibleTasks().isEmpty)
        state.presentNewTask()

        #expect(state.presentedSheet == .newTask)
        #expect(state.pendingNewTaskListID == listID)
        #expect(await repository.taskCreateCalls().isEmpty)
    }

    @Test("repeating the same add entry only keeps one presentation and never creates a task")
    func repeatedTaskPresentationHasNoRepositorySideEffect() async {
        let listID = UUID(uuidString: "00000000-0000-4000-8000-000000000502")!
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        state.selection = .list(listID)

        state.presentNewTask()
        let firstDestination = state.presentedSheet
        state.presentNewTask()

        #expect(firstDestination == .newTask)
        #expect(state.presentedSheet == firstDestination)
        #expect(state.pendingNewTaskListID == listID)
        #expect(await repository.taskCreateCalls().isEmpty)
    }

    @Test("saving uses the list captured at presentation even after navigation changes")
    func taskCreationUsesCapturedListContext() async throws {
        let capturedListID = UUID(uuidString: "00000000-0000-4000-8000-000000000503")!
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        state.selection = .list(capturedListID)
        state.presentNewTask()
        let capturedContext = try #require(state.pendingNewTaskListID)

        state.selection = .smart(.tasks)
        #expect(state.pendingNewTaskListID == capturedListID)
        #expect(await state.createTask(title: "保留原清单", listID: capturedContext, dueDate: nil))

        let calls = await repository.taskCreateCalls()
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.title == "保留原清单")
        #expect(call.listID == capturedListID)
    }

    @Test("opening setup for a task without a Session only presents its sheet")
    func openingTaskSetupDoesNotQueryEngine() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(task: task, session: nil)
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        await Task.yield()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(await repository.sessionLookupCount() == 0)
        #expect(state.errorMessage == nil)
    }

    @Test("opening a task with a Session refreshes it exactly once")
    func openingExistingTaskSessionQueriesEngineOnce() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task)
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        await repository.waitUntilSessionLookup()
        await Task.yield()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(await repository.sessionLookupCount() == 1)
        #expect(state.errorMessage == nil)
    }

    @Test("closing a loading task Session discards a delayed successful lookup")
    func closingSessionDiscardsDelayedSuccess() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        #expect(state.conversation(for: task) == nil)
        await repository.waitUntilSessionLookup()

        state.dismissTaskSession(taskID: task.id)
        #expect(state.presentedSheet == nil)
        #expect(state.isLoadingSession(for: task) == false)
        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.errorMessage == nil)
        #expect(state.conversation(for: task) == nil)
    }

    @Test("closing a loading task Session suppresses a delayed lookup failure")
    func closingSessionSuppressesDelayedFailure() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true,
            lookupFailure: .runtimeUnavailable
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        await repository.waitUntilSessionLookup()

        state.dismissTaskSession(taskID: task.id)
        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.presentedSheet == nil)
        #expect(state.isLoadingSession(for: task) == false)
        #expect(state.errorMessage == nil)
        #expect(state.conversation(for: task) == nil)
    }

    @Test("a successful task Session lookup clears loading and publishes its conversation")
    func completedSessionLookupPublishesConversation() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        #expect(state.conversation(for: task) == nil)
        await repository.waitUntilSessionLookup()

        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(state.isLoadingSession(for: task) == false)
        #expect(state.conversation(for: task)?.sessionID == "task-session")
        #expect(state.errorMessage == nil)
    }

    @Test("Gemini connection test uses the selected model")
    func geminiConnectionTest() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()

        let result = try await state.testGeminiConnection(model: "gemini-3.6-flash")

        #expect(result.ok)
        #expect(result.model == "gemini-3.6-flash")
        #expect(result.displayName == "Gemini Demo")
    }

    @Test("shared AppState starts the Engine only once across windows")
    func loadIsSingleFlight() async {
        let repository = AssistantTestRepository(suspendLoad: true)
        let state = AppState(repository: repository)

        let first = Task { await state.load() }
        await repository.waitUntilLoadStarts()
        let second = Task { await state.load() }
        first.cancel()
        await Task.yield()

        #expect(state.loadState == .loading)
        await repository.releaseLoad()
        await second.value
        await first.value
        await state.load()

        #expect(await repository.loadCount() == 1)
        #expect(state.loadState == .loaded)
    }

    @Test("tasks only transition between open and completed")
    func completionLifecycle() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(task.status == .open)
        #expect(await state.setCompleted(task, completed: true))
        let completed = try #require(state.task(id: task.id))
        #expect(completed.status == .completed)
        #expect(await state.setCompleted(completed, completed: false))
        #expect(state.task(id: task.id)?.status == .open)
    }

    @Test("a task binds one runtime and working directory")
    func sessionConfiguration() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(state.session(for: task) == nil)
        #expect(await state.startSession(task, runtime: .kiro, workspace: "/tmp/project"))
        let session = try #require(state.session(for: task))
        #expect(session.runtimeKind == .kiro)
        #expect(session.workingDirectory == "/tmp/project")
        #expect(session.providerEngine == "v2")
    }

    @Test("composer sends into the bound logical session")
    func sessionMessage() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)
        #expect(await state.startSession(task, runtime: .codex, workspace: "/tmp/project"))
        #expect(await state.sendToSession(task, text: "继续检查测试"))
        let conversation = try #require(state.conversation(for: task))
        #expect(conversation.entries.last?.role == .user)
        #expect(conversation.entries.last?.body == "继续检查测试")
    }

    @Test("same-sequence CLI deltas replace the durable message projection")
    func sameSequenceCLIDeltaStaysLive() {
        let task = taskFixture()
        let session = sessionBundleFixture(for: task).session
        let first = SessionMessage(
            id: "agent-message",
            sessionID: session.id,
            turnID: "turn-1",
            sequence: 2,
            clientMessageID: nil,
            role: .agent,
            kind: "text",
            body: "第一段",
            payloadJSON: nil,
            createdAt: "2026-08-09T00:00:00Z",
            updatedAt: "2026-08-09T00:00:01Z"
        )
        let updated = SessionMessage(
            id: first.id,
            sessionID: first.sessionID,
            turnID: first.turnID,
            sequence: first.sequence,
            clientMessageID: nil,
            role: .agent,
            kind: "text",
            body: "第一段，第二段",
            payloadJSON: nil,
            createdAt: first.createdAt,
            updatedAt: "2026-08-09T00:00:02Z"
        )
        let initial = SessionBundle(session: session, messages: [first], activeTurn: nil)

        let merged = initial.merging(message: updated)

        #expect(merged.messages.count == 1)
        #expect(merged.messages.first?.id == first.id)
        #expect(merged.messages.first?.sequence == 2)
        #expect(merged.messages.first?.body == "第一段，第二段")
    }

    @Test("projection separates completion from active session state")
    func projectionCounts() {
        let now = Date(timeIntervalSince1970: 1_786_080_000)
        let task = TaskItem(id: UUID(), listID: nil, title: "任务", note: "", status: .open, dueDate: now, completedAt: nil, createdAt: now, updatedAt: "")
        let projection = TaskProjection(tasks: [task], now: now)
        let session = TaskSessionDescriptor(id: UUID().uuidString, taskID: task.id, runtimeKind: .claude, workingDirectory: "/tmp", providerSessionID: nil, providerEngine: nil, state: .running, lastAgentSequence: 3, lastReadSequence: 2, lastErrorCode: nil, lastErrorMessage: nil, createdAt: "", updatedAt: "")

        #expect(projection.count(for: .timeline, sessions: [session]) == 1)
        #expect(projection.count(for: .running, sessions: [session]) == 1)
        #expect(projection.count(for: .done, sessions: [session]) == 0)
        #expect(session.hasUnread)
    }

    private func taskFixture() -> TaskItem {
        TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000401")!,
            listID: nil,
            title: "配置本地 Agent",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }

    private func sessionBundleFixture(for task: TaskItem) -> SessionBundle {
        SessionBundle(
            session: TaskSessionDescriptor(
                id: "task-session",
                taskID: task.id,
                runtimeKind: .codex,
                workingDirectory: "/tmp/project",
                providerSessionID: "provider-session",
                providerEngine: nil,
                state: .idle,
                lastAgentSequence: 0,
                lastReadSequence: 0,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: "2026-08-09T00:00:00Z",
                updatedAt: "2026-08-09T00:00:00Z"
            ),
            messages: [],
            activeTurn: nil
        )
    }

    private func emptySnapshot(lists: [TodoList] = []) -> AppSnapshot {
        AppSnapshot(revision: 1, lists: lists, tasks: [], runtimes: [], sessions: [], messages: [])
    }

    private func drainMainActorTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

private struct TaskCreateCall: Equatable, Sendable {
    let title: String
    let listID: UUID?
}

private actor TaskOpenSpyRepository: AppRepository {
    private let snapshot: AppSnapshot
    private let sessionBundle: SessionBundle?
    private let delaysSessionLookup: Bool
    private let lookupFailure: AppRepositoryError?
    private var sessionLookups = 0
    private var taskCreations: [TaskCreateCall] = []
    private var sessionLookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var delayedSessionLookup: CheckedContinuation<SessionBundle?, any Error>?

    init(
        task: TaskItem,
        session: SessionBundle?,
        delaysSessionLookup: Bool = false,
        lookupFailure: AppRepositoryError? = nil
    ) {
        sessionBundle = session
        self.delaysSessionLookup = delaysSessionLookup
        self.lookupFailure = lookupFailure
        snapshot = AppSnapshot(
            revision: 1,
            lists: [],
            tasks: [task],
            runtimes: [],
            sessions: session.map { [$0.session] } ?? [],
            messages: []
        )
    }

    init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
        sessionBundle = nil
        delaysSessionLookup = false
        lookupFailure = nil
    }

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        taskCreations.append(TaskCreateCall(title: title, listID: listID))
        return snapshot
    }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot { snapshot }
    func detectRuntimes() async throws -> AppSnapshot { snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }

    func session(taskID: UUID) async throws -> SessionBundle? {
        sessionLookups += 1
        let waiters = sessionLookupWaiters
        sessionLookupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if delaysSessionLookup {
            return try await withCheckedThrowingContinuation { continuation in
                delayedSessionLookup = continuation
            }
        }
        if let lookupFailure { throw lookupFailure }
        return sessionBundle
    }

    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {}
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Gemini Test", version: "test")
    }
    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(configured: false, available: false, model: nil, reason: "未配置")
    }
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] { [] }
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func sendAssistantMessage(
        sessionID: String,
        clientMessageID: UUID,
        text: String,
        model: String,
        attachments: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async {}

    func sessionLookupCount() -> Int { sessionLookups }
    func taskCreateCalls() -> [TaskCreateCall] { taskCreations }

    func completeDelayedSessionLookup() {
        guard let delayedSessionLookup else { return }
        self.delayedSessionLookup = nil
        if let lookupFailure {
            delayedSessionLookup.resume(throwing: lookupFailure)
        } else {
            delayedSessionLookup.resume(returning: sessionBundle)
        }
    }

    func waitUntilSessionLookup() async {
        guard sessionLookups == 0 else { return }
        await withCheckedContinuation { continuation in
            sessionLookupWaiters.append(continuation)
        }
    }
}
