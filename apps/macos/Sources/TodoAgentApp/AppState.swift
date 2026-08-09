import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private let repository: any AppRepository
    private var projection = TaskProjection.empty
    private var eventTask: Task<Void, Never>?
    private var eventGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var hasLoaded = false
    private var sessionLoadTask: Task<Void, Never>?
    private var sessionLoadGeneration: UInt64 = 0
    private var bundles: [UUID: SessionBundle] = [:]

    private(set) var lists: [TodoList] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var runtimes: [RuntimeInfo] = []
    private(set) var sessions: [TaskSessionDescriptor] = []
    private(set) var loadingSessionTaskID: UUID?
    private(set) var pendingNewTaskListID: UUID?
    private(set) var taskSessionErrorMessage: String?
    let assistant: AssistantViewState

    var selection: SidebarSelection? = .smart(.timeline)
    var selectedDate = Calendar.current.startOfDay(for: .now)
    var inspectorPresented: Bool
    var presentedSheet: AppSheet?
    var loadState: AppLoadState = .loading
    var errorMessage: String?

    init(repository: any AppRepository, inspectorPresented: Bool = false) {
        self.repository = repository
        self.inspectorPresented = inspectorPresented
        assistant = AssistantViewState(repository: repository)
    }

    func openAssistant() {
        inspectorPresented = true
    }

    func toggleAssistant() {
        inspectorPresented.toggle()
    }

    /// Captures the destination list when the creation surface opens. The
    /// sheet uses this stable value even if navigation changes before save.
    func presentNewTask() {
        pendingNewTaskListID = if case let .list(id) = selection { id } else { nil }
        presentedSheet = .newTask
    }

    /// Opens the native assistant surface first, then creates a session only
    /// when Gemini is ready. This lets unconfigured users reach the recovery
    /// entry without leaving an empty session behind.
    @discardableResult
    func openNewAssistantConversation() async -> Bool {
        inspectorPresented = true
        guard assistant.canUseAssistant else { return false }
        return await assistant.createSession()
    }

    func load() async {
        if hasLoaded {
            startEventsIfNeeded()
            assistant.resumeEventsIfNeeded()
            return
        }

        if let loadTask {
            await loadTask.value
            return
        }

        loadState = .loading
        loadGeneration &+= 1
        let generation = loadGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialLoad(generation: generation)
            guard self.loadGeneration == generation else { return }
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    private func performInitialLoad(generation: UInt64) async {
        do {
            let snapshot = try await repository.load()
            guard loadGeneration == generation else { return }
            apply(snapshot)
            startEventsIfNeeded()
            await assistant.load()
            guard loadGeneration == generation else { return }
            hasLoaded = true
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    func shutdown() async {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        eventGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        loadingSessionTaskID = nil
        assistant.shutdown()
        await repository.shutdown()
        hasLoaded = false
    }

    @discardableResult
    func createTask(title: String, note: String = "", dueDate: Date?) async -> Bool {
        let listID: UUID? = if case let .list(id) = selection { id } else { nil }
        return await createTask(title: title, note: note, listID: listID, dueDate: dueDate)
    }

    @discardableResult
    func createTask(title: String, note: String = "", listID: UUID?, dueDate: Date?) async -> Bool {
        return await update { try await repository.createTask(title: title, note: note, listID: listID, dueDate: dueDate) }
    }

    @discardableResult
    func setCompleted(_ task: TaskItem, completed: Bool) async -> Bool {
        await update { try await repository.setCompleted(taskID: task.id, completed: completed) }
    }

    func openTask(_ task: TaskItem) {
        cancelSessionLoad()
        presentedSheet = .taskSession(task.id)
        // `app.bootstrap` already tells us whether this task owns a Session.
        // A task without one goes straight to setup; querying `session.get`
        // here only creates a deferred error that becomes visible after the
        // modal sheet closes.
        guard bundles[task.id] == nil, session(for: task) != nil else { return }

        sessionLoadGeneration &+= 1
        let generation = sessionLoadGeneration
        loadingSessionTaskID = task.id
        sessionLoadTask = Task { @MainActor [weak self] in
            await self?.loadSessionForPresentation(taskID: task.id, generation: generation)
        }
    }

    func dismissTaskSession(taskID: UUID) {
        if presentedSheet == .taskSession(taskID) {
            presentedSheet = nil
        }
        cancelSessionLoad()
        taskSessionErrorMessage = nil
    }

    func isLoadingSession(for task: TaskItem) -> Bool {
        loadingSessionTaskID == task.id
    }

    func clearTaskSessionError() {
        taskSessionErrorMessage = nil
    }

    private func loadSessionForPresentation(taskID: UUID, generation: UInt64) async {
        defer {
            if sessionLoadGeneration == generation {
                loadingSessionTaskID = nil
                sessionLoadTask = nil
            }
        }

        do {
            let bundle = try await repository.session(taskID: taskID)
            guard
                !Task.isCancelled,
                sessionLoadGeneration == generation,
                presentedSheet == .taskSession(taskID)
            else { return }

            if let bundle {
                merge(bundle, taskID: taskID)
            } else {
                // The persisted lookup is authoritative if the bootstrap
                // descriptor was stale. Fall back to the setup screen.
                sessions.removeAll(where: { $0.taskID == taskID })
            }
        } catch is CancellationError {
            return
        } catch {
            guard
                sessionLoadGeneration == generation,
                presentedSheet == .taskSession(taskID)
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func cancelSessionLoad() {
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        loadingSessionTaskID = nil
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
        taskSessionErrorMessage = nil
        let directory = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { taskSessionErrorMessage = "请选择 Agent 执行目录。"; return false }
        guard runtimes.first(where: { $0.kind == runtime })?.isSelectable == true else {
            taskSessionErrorMessage = "\(runtime.title) 尚未安装、登录或验证。请先在“设置 → 本机 CLI”中完成检测。"
            return false
        }
        if repository.requiresExecutionConsent {
            guard ExecutionSafety.authorize(runtime: runtime) else { return false }
        }
        do {
            let bundle = try await repository.createSession(taskID: task.id, runtime: runtime, workspace: directory)
            merge(bundle, taskID: task.id)
            if let snapshot = try? await repository.sync() {
                apply(snapshot)
            }
            return true
        } catch {
            taskSessionErrorMessage = error.localizedDescription
            return false
        }
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

    @discardableResult
    func detectRuntimes() async -> Bool { await update { try await repository.detectRuntimes() } }

    @discardableResult
    func verifyRuntime(_ kind: RuntimeKind) async -> Bool { await update { try await repository.verifyRuntime(kind) } }
    func injectGeminiKey(_ key: String) async throws {
        try await repository.injectGeminiKey(key)
        await assistant.refresh()
    }
    func clearGeminiKey() async throws {
        try await repository.clearGeminiKey()
        await assistant.refresh()
    }
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        try await repository.testGeminiConnection(model: model)
    }
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
        eventGeneration &+= 1
        let generation = eventGeneration
        let repository = repository
        eventTask = Task { [weak self] in
            let stream = await repository.events()
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.consume(event)
            }
            guard let self, self.eventGeneration == generation else { return }
            self.eventTask = nil
        }
    }

    private func consume(_ event: EngineEvent) async {
        if event.name.hasPrefix("assistant.") || event.name == "engine.ready" {
            return
        } else if event.name.hasPrefix("session.") {
            if let bundle = try? JSONDecoder.engineDecoder.decode(SessionBundle.self, from: event.data) {
                merge(bundle, taskID: bundle.session.taskID)
            } else if let session = try? JSONDecoder.engineDecoder.decode(TaskSessionDescriptor.self, from: event.data), let task = tasks.first(where: { $0.id == session.taskID }) {
                sessions.removeAll(where: { $0.id == session.id }); sessions.append(session)
                await refreshSession(taskID: task.id, after: bundles[task.id]?.messages.last?.sequence ?? 0)
            } else if let message = try? JSONDecoder.engineDecoder.decode(SessionMessage.self, from: event.data), let session = sessions.first(where: { $0.id == message.sessionID }) {
                if let current = bundles[session.taskID] {
                    let latestSequence = current.messages.last?.sequence ?? 0
                    if message.sequence <= latestSequence + 1 {
                        bundles[session.taskID] = current.merging(message: message)
                    } else {
                        await refreshSession(taskID: session.taskID, after: latestSequence)
                    }
                } else {
                    await refreshSession(taskID: session.taskID)
                }
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

extension SessionBundle {
    /// CLI text chunks append to one durable message and therefore keep the same
    /// sequence. Replacing that projection directly keeps the transcript live;
    /// querying history with `afterSequence == sequence` would omit the update.
    func merging(message incoming: SessionMessage) -> SessionBundle {
        guard incoming.sessionID == session.id else { return self }
        var messagesBySequence = Dictionary(uniqueKeysWithValues: messages.map { ($0.sequence, $0) })
        messagesBySequence[incoming.sequence] = incoming
        return SessionBundle(
            session: session,
            messages: messagesBySequence.values.sorted { $0.sequence < $1.sequence },
            activeTurn: activeTurn
        )
    }
}

/// High-frequency Gemini assistant state is deliberately isolated from
/// `AppState` and `AppSnapshot`. Streaming deltas only invalidate the inspector,
/// while task/list changes continue to flow through the normal snapshot path.
@MainActor
@Observable
final class AssistantViewState {
    private struct PendingSend {
        let clientMessageID: UUID
        let text: String
        let model: String
        let attachments: [AssistantTextAttachment]
    }

    @ObservationIgnored private let repository: any AppRepository
    @ObservationIgnored private let keyLoader: @MainActor @Sendable () throws -> String?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var eventGeneration: UInt64 = 0
    @ObservationIgnored private var historyLoadGeneration: UInt64 = 0

    private var bundles: [String: AssistantSessionBundle] = [:]
    private var drafts: [String: AssistantStreamingDraft] = [:]
    private var toolsBySession: [String: [String: AssistantToolActivity]] = [:]
    private var turnErrors: [String: String] = [:]
    private var sendingSessionIDs: Set<String> = []
    private var pendingSends: [String: PendingSend] = [:]

    private(set) var status: AssistantStatus?
    private(set) var sessions: [AssistantSessionDescriptor] = []
    private(set) var loadState: AssistantLoadState = .idle
    private(set) var isLoadingHistory = false
    private(set) var isManagingSession = false
    var selectedSessionID: String?
    var errorMessage: String?

    init(
        repository: any AppRepository,
        keyLoader: @escaping @MainActor @Sendable () throws -> String? = {
            try CredentialStore.loadGeminiKey()
        }
    ) {
        self.repository = repository
        self.keyLoader = keyLoader
    }

    var activeSessions: [AssistantSessionDescriptor] {
        sessions
            .filter { !$0.archived }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt { return lhs.id < rhs.id }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    var selectedSession: AssistantSessionDescriptor? {
        guard let selectedSessionID else { return nil }
        return bundles[selectedSessionID]?.session
            ?? sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedMessages: [AssistantMessage] {
        guard let selectedSessionID else { return [] }
        return bundles[selectedSessionID]?.messages ?? []
    }

    var selectedDraft: AssistantStreamingDraft? {
        guard let selectedSessionID else { return nil }
        return drafts[selectedSessionID]
    }

    var selectedTools: [AssistantToolActivity] {
        guard let selectedSessionID else { return [] }
        guard let tools = toolsBySession[selectedSessionID]?.values else { return [] }
        return tools.sorted { $0.toolCallID < $1.toolCallID }
    }

    /// Test-visible guardrail for the one-detailed-conversation memory policy.
    var detailedSessionCacheCount: Int {
        bundles.filter { sessionID, bundle in
            !bundle.messages.isEmpty
                || !bundle.tools.isEmpty
                || !(toolsBySession[sessionID]?.isEmpty ?? true)
        }.count
    }

    var selectedTurnError: String? {
        guard let selectedSessionID else { return nil }
        return turnErrors[selectedSessionID]
    }

    var isSelectedSessionRunning: Bool {
        guard let selectedSessionID else { return false }
        return sendingSessionIDs.contains(selectedSessionID)
            || bundles[selectedSessionID]?.activeTurn?.status.isRunning == true
            || selectedSession?.isRunning == true
    }

    var canUseAssistant: Bool {
        status?.configured == true && status?.available == true
    }

    func load() async {
        startEventsIfNeeded()
        await restoreCredentialAndReload(
            resetEphemeralState: false,
            showLoadingState: true
        )
    }

    func shutdown() {
        eventGeneration &+= 1
        historyLoadGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
    }

    func resumeEventsIfNeeded() { startEventsIfNeeded() }

    func clearError() { errorMessage = nil }

    func refresh() async { await reloadContent(showLoadingState: false) }

    func selectSession(_ sessionID: String) async {
        guard sessions.contains(where: { $0.id == sessionID && !$0.archived }) else { return }
        selectedSessionID = sessionID
        evictDetailedHistory(except: sessionID)
        await loadHistory(sessionID: sessionID, after: 0, replaceActiveTurn: true)
    }

    @discardableResult
    func createSession() async -> Bool {
        guard !isManagingSession else { return false }
        isManagingSession = true
        defer { isManagingSession = false }

        do {
            let bundle = try await repository.createAssistantSession(title: nil)
            merge(bundle, replaceActiveTurn: true)
            selectedSessionID = bundle.session.id
            evictDetailedHistory(except: bundle.session.id)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameSelectedSession(to title: String) async -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let selectedSessionID, !value.isEmpty, !isManagingSession else { return false }
        isManagingSession = true
        defer { isManagingSession = false }

        do {
            let bundle = try await repository.renameAssistantSession(
                sessionID: selectedSessionID,
                title: value
            )
            merge(bundle, replaceActiveTurn: false)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func archiveSelectedSession() async -> Bool {
        guard let selectedSessionID, !isSelectedSessionRunning, !isManagingSession else { return false }
        isManagingSession = true
        defer { isManagingSession = false }

        do {
            let bundle = try await repository.archiveAssistantSession(sessionID: selectedSessionID)
            merge(bundle, replaceActiveTurn: false)
            sessions.removeAll(where: { $0.id == selectedSessionID })
            bundles.removeValue(forKey: selectedSessionID)
            drafts.removeValue(forKey: selectedSessionID)
            toolsBySession.removeValue(forKey: selectedSessionID)
            turnErrors.removeValue(forKey: selectedSessionID)

            let nextID = activeSessions.first?.id
            self.selectedSessionID = nextID
            if let nextID {
                await loadHistory(sessionID: nextID, after: 0, replaceActiveTurn: true)
            }
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func send(
        text: String,
        model: String,
        attachments: [AssistantTextAttachment] = []
    ) async -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let sessionID = selectedSessionID,
            !value.isEmpty || !attachments.isEmpty,
            !selectedModel.isEmpty,
            canUseAssistant,
            !isSelectedSessionRunning
        else { return false }

        sendingSessionIDs.insert(sessionID)
        turnErrors.removeValue(forKey: sessionID)
        defer { sendingSessionIDs.remove(sessionID) }

        let pending: PendingSend
        if let existing = pendingSends[sessionID],
           existing.text == value,
           existing.model == selectedModel,
           existing.attachments == attachments {
            pending = existing
        } else {
            pending = PendingSend(
                clientMessageID: UUID(),
                text: value,
                model: selectedModel,
                attachments: attachments
            )
            pendingSends[sessionID] = pending
        }

        do {
            let bundle = try await repository.sendAssistantMessage(
                sessionID: sessionID,
                clientMessageID: pending.clientMessageID,
                text: value,
                model: selectedModel,
                attachments: pending.attachments
            )
            merge(bundle, replaceActiveTurn: true)
            pendingSends.removeValue(forKey: sessionID)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            await loadHistory(
                sessionID: sessionID,
                after: latestStableSequence(for: sessionID),
                replaceActiveTurn: true
            )
            if bundle(for: sessionID).messages.contains(where: {
                $0.clientMessageID?.lowercased()
                    == pending.clientMessageID.uuidString.lowercased()
            }) {
                pendingSends.removeValue(forKey: sessionID)
                errorMessage = nil
                return true
            }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelSelectedTurn() async {
        guard let selectedSessionID, isSelectedSessionRunning else { return }
        do {
            try await repository.cancelAssistantTurn(sessionID: selectedSessionID)
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Internal for deterministic reducer tests. Production events arrive from
    /// the stored event task below, so tests never need timing-based sleeps.
    func consumeAssistantEvent(_ event: EngineEvent) async {
        if event.name == "engine.ready" {
            await restoreAfterEngineReady()
            return
        }
        guard event.name.hasPrefix("assistant.") else { return }

        do {
            switch event.name {
            case "assistant.session.changed":
                let payload = try JSONDecoder.engineDecoder.decode(
                    AssistantSessionChangedEvent.self,
                    from: event.data
                )
                let stableSequence = latestStableSequence(for: payload.session.id)
                upsertSession(payload.session)
                if payload.session.id == selectedSessionID,
                   payload.session.lastSequence > stableSequence {
                    await loadHistory(
                        sessionID: payload.session.id,
                        after: stableSequence,
                        replaceActiveTurn: true,
                        targetSequence: payload.session.lastSequence
                    )
                }
                if payload.session.archived, selectedSessionID == payload.session.id {
                    selectedSessionID = activeSessions.first?.id
                    if let selectedSessionID {
                        await loadHistory(
                            sessionID: selectedSessionID,
                            after: 0,
                            replaceActiveTurn: true
                        )
                    }
                }

            case "assistant.turn.started":
                let payload = try JSONDecoder.engineDecoder.decode(AssistantTurnEvent.self, from: event.data)
                applyTurn(payload.turn, sessionID: payload.sessionID, finished: false)

            case "assistant.message.delta":
                let payload = try JSONDecoder.engineDecoder.decode(
                    AssistantMessageDeltaEvent.self,
                    from: event.data
                )
                applyDelta(payload)

            case "assistant.message.appended":
                let payload = try JSONDecoder.engineDecoder.decode(
                    AssistantMessageAppendedEvent.self,
                    from: event.data
                )
                await applyAppended(payload)

            case "assistant.tool.started":
                let payload = try JSONDecoder.engineDecoder.decode(
                    AssistantToolStartedEvent.self,
                    from: event.data
                )
                applyToolStarted(payload)

            case "assistant.tool.finished":
                let payload = try JSONDecoder.engineDecoder.decode(
                    AssistantToolFinishedEvent.self,
                    from: event.data
                )
                applyToolFinished(payload)

            case "assistant.turn.finished":
                let payload = try JSONDecoder.engineDecoder.decode(AssistantTurnEvent.self, from: event.data)
                applyTurn(payload.turn, sessionID: payload.sessionID, finished: true)
                if payload.sessionID == selectedSessionID {
                    await loadHistory(
                        sessionID: payload.sessionID,
                        after: max(0, latestStableSequence(for: payload.sessionID) - 10),
                        replaceActiveTurn: true
                    )
                }

            default:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = "TodoAgent 事件无法处理：\(error.localizedDescription)"
        }
    }

    private func reloadContent(showLoadingState: Bool) async {
        if showLoadingState { loadState = .loading }
        do {
            let nextStatus = try await repository.assistantStatus()
            let nextSessions = try await repository.assistantSessions(includeArchived: false)
            status = nextStatus
            sessions = nextSessions
            errorMessage = nil

            if let selectedSessionID,
               let selected = nextSessions.first(where: { $0.id == selectedSessionID }) {
                upsertSession(selected)
            } else {
                selectedSessionID = nextSessions.first?.id
            }

            for session in nextSessions { upsertSession(session) }
            if let selectedSessionID {
                evictDetailedHistory(except: selectedSessionID)
                await loadHistory(sessionID: selectedSessionID, after: 0, replaceActiveTurn: true)
            }
            loadState = .loaded
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
            errorMessage = nil
        }
    }

    private func loadHistory(
        sessionID: String,
        after sequence: Int64,
        replaceActiveTurn: Bool,
        targetSequence: Int64? = nil
    ) async {
        historyLoadGeneration &+= 1
        let generation = historyLoadGeneration
        isLoadingHistory = true
        defer {
            if historyLoadGeneration == generation {
                isLoadingHistory = false
            }
        }
        do {
            var cursor = sequence
            var desiredSequence = targetSequence ?? 0
            while true {
                let bundle = try await repository.assistantHistory(
                    sessionID: sessionID,
                    after: cursor
                )
                guard
                    historyLoadGeneration == generation,
                    selectedSessionID == sessionID
                else { return }
                desiredSequence = max(desiredSequence, bundle.session.lastSequence)
                merge(bundle, replaceActiveTurn: replaceActiveTurn)

                let nextCursor = latestStableSequence(for: sessionID)
                if nextCursor >= desiredSequence || nextCursor <= cursor || bundle.messages.isEmpty {
                    break
                }
                cursor = nextCursor
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startEventsIfNeeded() {
        guard eventTask == nil else { return }
        eventGeneration &+= 1
        let generation = eventGeneration
        let repository = repository
        eventTask = Task { [weak self] in
            let stream = await repository.events()
            for await event in stream {
                guard Task.isCancelled == false, let self else { break }
                await self.consumeAssistantEvent(event)
            }
            guard let self, self.eventGeneration == generation else { return }
            self.eventTask = nil
        }
    }

    private func restoreAfterEngineReady() async {
        await restoreCredentialAndReload(
            resetEphemeralState: true,
            showLoadingState: false
        )
    }

    private func restoreCredentialAndReload(
        resetEphemeralState: Bool,
        showLoadingState: Bool
    ) async {
        if resetEphemeralState {
            // A restarted sidecar has no in-memory turn state. Drop ephemeral
            // projections before rebuilding them from persisted history.
            drafts.removeAll()
            toolsBySession.removeAll()
            turnErrors.removeAll()
            sendingSessionIDs.removeAll()
        }
        var credentialError: String?

        do {
            if repository.requiresExecutionConsent,
               let key = try keyLoader(), !key.isEmpty {
                try await repository.injectGeminiKey(key)
            }
        } catch is CancellationError {
            return
        } catch {
            credentialError = "TodoAgent 凭据恢复失败：\(error.localizedDescription)"
        }

        errorMessage = nil
        await reloadContent(showLoadingState: showLoadingState)
        if let credentialError {
            if let reloadError = errorMessage, reloadError != credentialError {
                errorMessage = "\(credentialError)\n\(reloadError)"
            } else {
                errorMessage = credentialError
            }
        }
    }

    private func applyTurn(_ turn: AssistantTurn, sessionID: String, finished: Bool) {
        guard turn.sessionID == sessionID else { return }
        var bundle = bundle(for: sessionID)

        if finished {
            if let activeTurn = bundle.activeTurn, activeTurn.id != turn.id { return }
            bundle = AssistantSessionBundle(
                session: bundle.session.updating(isRunning: false, lastModel: turn.model),
                messages: bundle.messages,
                tools: bundle.tools,
                activeTurn: nil
            )
            drafts.removeValue(forKey: sessionID)
            if turn.status == .failed || turn.status == .interrupted,
               let message = turn.errorMessage, !message.isEmpty {
                turnErrors[sessionID] = message
            }
        } else {
            if bundle.activeTurn?.id == turn.id, bundle.activeTurn?.status == turn.status { return }
            turnErrors.removeValue(forKey: sessionID)
            bundle = AssistantSessionBundle(
                session: bundle.session.updating(isRunning: true, lastModel: turn.model),
                messages: bundle.messages,
                tools: bundle.tools,
                activeTurn: turn
            )
        }

        bundles[sessionID] = bundle
        upsertSession(bundle.session)
    }

    private func applyDelta(_ payload: AssistantMessageDeltaEvent) {
        guard !bundle(for: payload.sessionID).messages.contains(where: {
            $0.id == payload.messageID || ($0.turnID == payload.turnID && $0.role == .todoAgent)
        }) else { return }

        let attempt = max(payload.attempt ?? 1, 1)
        if var draft = drafts[payload.sessionID], draft.turnID == payload.turnID {
            guard attempt >= draft.attempt else { return }
            if attempt > draft.attempt {
                draft = AssistantStreamingDraft(
                    sessionID: payload.sessionID,
                    turnID: payload.turnID,
                    messageID: payload.messageID,
                    attempt: attempt,
                    body: ""
                )
            }
            draft.body += payload.delta
            drafts[payload.sessionID] = draft
        } else {
            drafts[payload.sessionID] = AssistantStreamingDraft(
                sessionID: payload.sessionID,
                turnID: payload.turnID,
                messageID: payload.messageID,
                attempt: attempt,
                body: payload.delta
            )
        }
    }

    private func applyAppended(_ payload: AssistantMessageAppendedEvent) async {
        guard payload.message.sessionID == payload.sessionID else { return }
        if payload.sessionID != selectedSessionID {
            let session = bundle(for: payload.sessionID).session.updating(
                lastSequence: max(
                    bundle(for: payload.sessionID).session.lastSequence,
                    payload.message.sequence
                )
            )
            upsertSession(session)
            if payload.message.role == .todoAgent {
                drafts.removeValue(forKey: payload.sessionID)
            }
            return
        }
        let current = latestStableSequence(for: payload.sessionID)

        if payload.message.sequence > current + 1 {
            await loadHistory(
                sessionID: payload.sessionID,
                after: current,
                replaceActiveTurn: false,
                targetSequence: payload.message.sequence - 1
            )
            guard payload.sessionID == selectedSessionID else { return }
        }

        var bundle = bundle(for: payload.sessionID)
        if bundle.messages.contains(where: { $0.id == payload.message.id && $0 == payload.message }) {
            if payload.message.role == .todoAgent { drafts.removeValue(forKey: payload.sessionID) }
            return
        }
        var messages = bundle.messages.filter {
            $0.id != payload.message.id && $0.sequence != payload.message.sequence
        }
        messages.append(payload.message)
        messages.sort { $0.sequence < $1.sequence }
        let latestSequence = max(bundle.session.lastSequence, messages.last?.sequence ?? 0)
        bundle = AssistantSessionBundle(
            session: bundle.session.updating(lastSequence: latestSequence),
            messages: messages,
            tools: bundle.tools,
            activeTurn: bundle.activeTurn
        )
        bundles[payload.sessionID] = bundle
        upsertSession(bundle.session)

        if payload.message.role == .todoAgent {
            drafts.removeValue(forKey: payload.sessionID)
        }
    }

    private func applyToolStarted(_ payload: AssistantToolStartedEvent) {
        guard payload.sessionID == selectedSessionID else { return }
        var tools = toolsBySession[payload.sessionID] ?? [:]
        guard tools[payload.toolCallID]?.state != .running else { return }
        tools[payload.toolCallID] = AssistantToolActivity(
            sessionID: payload.sessionID,
            turnID: payload.turnID,
            toolCallID: payload.toolCallID,
            name: payload.name,
            state: .running,
            taskReferences: []
        )
        toolsBySession[payload.sessionID] = tools
    }

    private func applyToolFinished(_ payload: AssistantToolFinishedEvent) {
        guard payload.sessionID == selectedSessionID else { return }
        var tools = toolsBySession[payload.sessionID] ?? [:]
        tools[payload.toolCallID] = AssistantToolActivity(
            sessionID: payload.sessionID,
            turnID: payload.turnID,
            toolCallID: payload.toolCallID,
            name: payload.name,
            state: payload.isError ? .failed : .completed,
            taskReferences: payload.taskReferences
        )
        toolsBySession[payload.sessionID] = tools
    }

    private func merge(_ incoming: AssistantSessionBundle, replaceActiveTurn: Bool) {
        let existing = bundles[incoming.session.id]
        var bySequence = Dictionary(uniqueKeysWithValues: (existing?.messages ?? []).map { ($0.sequence, $0) })
        for message in incoming.messages { bySequence[message.sequence] = message }
        let messages = bySequence.values.sorted { $0.sequence < $1.sequence }
        var persistedByCallID = Dictionary(
            uniqueKeysWithValues: (existing?.tools ?? []).map { ($0.callID, $0) }
        )
        for tool in incoming.tools {
            persistedByCallID[tool.callID] = tool
            if let activity = tool.activity {
                var activities = toolsBySession[tool.sessionID] ?? [:]
                activities[tool.callID] = activity
                toolsBySession[tool.sessionID] = activities
            }
        }
        let persistedTools = persistedByCallID.values.sorted { $0.callID < $1.callID }
        let activeTurn: AssistantTurn? = if replaceActiveTurn {
            incoming.activeTurn
        } else if incoming.session.isRunning {
            incoming.activeTurn ?? existing?.activeTurn
        } else {
            nil
        }
        let latestSequence = max(
            incoming.session.lastSequence,
            messages.last?.sequence ?? existing?.session.lastSequence ?? 0
        )
        let session = incoming.session.updating(
            lastSequence: latestSequence,
            isRunning: activeTurn?.status.isRunning ?? incoming.session.isRunning,
            lastModel: activeTurn?.model ?? incoming.session.lastModel
        )
        bundles[session.id] = AssistantSessionBundle(
            session: session,
            messages: messages,
            tools: persistedTools,
            activeTurn: activeTurn
        )
        upsertSession(session)
    }

    private func upsertSession(_ session: AssistantSessionDescriptor) {
        sessions.removeAll(where: { $0.id == session.id })
        if !session.archived { sessions.append(session) }
        if !session.isRunning {
            drafts.removeValue(forKey: session.id)
            sendingSessionIDs.remove(session.id)
        }

        if let existing = bundles[session.id] {
            bundles[session.id] = AssistantSessionBundle(
                session: session,
                messages: existing.messages,
                tools: existing.tools,
                activeTurn: session.isRunning ? existing.activeTurn : nil
            )
        } else {
            bundles[session.id] = AssistantSessionBundle(session: session)
        }
    }

    private func bundle(for sessionID: String) -> AssistantSessionBundle {
        if let bundle = bundles[sessionID] { return bundle }
        let session = sessions.first(where: { $0.id == sessionID })
            ?? AssistantSessionDescriptor(id: sessionID, title: "")
        return AssistantSessionBundle(session: session)
    }

    /// Chat transcripts can be large. SQLite remains the source of truth, so
    /// only the selected conversation keeps its full message/tool projection in
    /// memory. Running background sessions retain their tiny active turn/draft.
    private func evictDetailedHistory(except retainedSessionID: String) {
        for sessionID in Array(bundles.keys) where sessionID != retainedSessionID {
            guard let existing = bundles[sessionID] else { continue }
            bundles[sessionID] = AssistantSessionBundle(
                session: existing.session,
                activeTurn: existing.session.isRunning ? existing.activeTurn : nil
            )
            toolsBySession.removeValue(forKey: sessionID)
        }
    }

    private func latestStableSequence(for sessionID: String) -> Int64 {
        var expected: Int64 = 1
        for message in (bundles[sessionID]?.messages ?? []).sorted(by: { $0.sequence < $1.sequence }) {
            if message.sequence < expected { continue }
            guard message.sequence == expected else { break }
            expected += 1
        }
        return expected - 1
    }
}

private extension JSONDecoder {
    static var engineDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
