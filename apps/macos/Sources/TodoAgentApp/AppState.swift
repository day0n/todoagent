import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class AppState {
    private struct ActiveTaskFlush {
        let token: UUID
        let task: Task<Bool, Never>
    }

    private enum TaskAttachmentMutation: Sendable {
        case add(sourcePaths: [String], clientMutationID: UUID)
        case remove(attachmentID: UUID, clientMutationID: UUID)
    }

    private enum FailedTaskCommand {
        case createList(previousListIDs: Set<UUID>, recoveryOnly: Bool)
        case delete(recoveryOnly: Bool)

        var recoveryOnly: Bool {
            switch self {
            case let .createList(_, recoveryOnly), let .delete(recoveryOnly):
                recoveryOnly
            }
        }
    }

    private struct ActiveEngineRecovery {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let repository: any AppRepository
    private let calendar: Calendar
    private var projection = TaskProjection.empty
    private var hasAppliedSnapshot = false
    private var eventTask: Task<Void, Never>?
    private var eventGeneration: UInt64 = 0
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var hasLoaded = false
    private var sessionLoadTask: Task<Void, Never>?
    private var sessionLoadGeneration: UInt64 = 0
    private var bundles: [UUID: SessionBundle] = [:]
    private var pendingTaskPatches: [UUID: TaskPatch] = [:]
    private var inFlightTaskPatches: [UUID: TaskPatch] = [:]
    private var pendingTaskAttachmentMutations: [UUID: [TaskAttachmentMutation]] = [:]
    private var taskDebounceTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskFlushes: [UUID: ActiveTaskFlush] = [:]
    private var activeTaskCommands: Set<UUID> = []
    private var activeTaskCommandWaiters: [CheckedContinuation<Void, Never>] = []
    private var failedTaskCommands: [UUID: FailedTaskCommand] = [:]
    private var activeEngineRecovery: ActiveEngineRecovery?
    private var localDayRefreshTask: Task<Void, Never>?
    private var calendarObservers: [NSObjectProtocol] = []
    private var workspaceCalendarObserver: NSObjectProtocol?

    private(set) var revision: Int64 = 0
    private(set) var lists: [TodoList] = []
    private(set) var tasks: [TaskItem] = []
    private(set) var messages: [ChatMessage] = []
    private(set) var runtimes: [RuntimeInfo] = []
    private(set) var sessions: [TaskSessionDescriptor] = []
    private(set) var loadingSessionTaskID: UUID?
    private(set) var taskSessionErrorMessage: String?
    private(set) var taskSaveStates: [UUID: TaskSaveState] = [:]
    let assistant: AssistantViewState

    var selection: SidebarSelection? = .smart(.timeline)
    var selectedDay: LocalDay
    private(set) var currentDay: LocalDay
    var selectedDate: Date {
        get { selectedDay.date(in: calendar) ?? .now }
        set { selectedDay = LocalDay(newValue, calendar: calendar) }
    }
    var inspectorPresented: Bool
    var presentedSheet: AppSheet?
    var loadState: AppLoadState = .loading
    var errorMessage: String?
    private(set) var isPreparingToTerminate = false

    init(
        repository: any AppRepository,
        inspectorPresented: Bool = false,
        now: Date = .now,
        calendar: Calendar = .todoAgentLocal
    ) {
        self.repository = repository
        self.calendar = calendar
        self.inspectorPresented = inspectorPresented
        let today = LocalDay(now, calendar: calendar)
        selectedDay = today
        currentDay = today
        assistant = AssistantViewState(repository: repository)
        installCalendarObservers()
    }

    @discardableResult
    func openAssistant() async -> Bool {
        inspectorPresented = true
        return await assistant.ensureDefaultSession()
    }

    func toggleAssistant() async {
        if inspectorPresented {
            inspectorPresented = false
        } else {
            await openAssistant()
        }
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
            scheduleLocalDayRefresh()
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
            scheduleLocalDayRefresh()
            await assistant.load()
            guard loadGeneration == generation else { return }
            hasLoaded = true
            loadState = .loaded
            if inspectorPresented {
                _ = await assistant.ensureDefaultSession()
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation else { return }
            loadState = .failed(error.localizedDescription)
        }
    }

    /// Flushes every pending task draft before stopping the Engine. Returning
    /// `false` tells AppKit to cancel termination; pending patches and their
    /// visible failure state remain intact so the user can retry.
    @discardableResult
    func shutdown() async -> Bool {
        isPreparingToTerminate = true
        guard await flushAllTaskEditsForShutdown() else {
            isPreparingToTerminate = false
            errorMessage = "还有任务修改未能保存。已取消退出，修改仍保留在当前界面，请重试保存。"
            return false
        }
        await waitForActiveTaskCommands()

        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        eventGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
        activeEngineRecovery?.task.cancel()
        activeEngineRecovery = nil
        sessionLoadGeneration &+= 1
        sessionLoadTask?.cancel()
        sessionLoadTask = nil
        loadingSessionTaskID = nil
        localDayRefreshTask?.cancel()
        localDayRefreshTask = nil
        for task in taskDebounceTasks.values { task.cancel() }
        taskDebounceTasks.removeAll()
        // All active task flushes were awaited above. Do not cancel an Engine
        // mutation after it may already have reached durable storage.
        activeTaskFlushes.removeAll()
        inFlightTaskPatches.removeAll()
        pendingTaskAttachmentMutations.removeAll()
        assistant.shutdown()
        await repository.shutdown()
        hasLoaded = false
        return true
    }

    private func flushAllTaskEditsForShutdown() async -> Bool {
        while true {
            let taskIDs = Set(pendingTaskPatches.keys)
                .union(pendingTaskAttachmentMutations.keys)
                .union(activeTaskFlushes.keys)
            guard !taskIDs.isEmpty else { return inFlightTaskPatches.isEmpty }

            for taskID in taskIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard await flushTaskEdits(taskID: taskID) else { return false }
            }

            // A newer edit may have arrived while an earlier Engine mutation
            // was in flight. Loop until the MainActor has no pending draft.
            if pendingTaskPatches.isEmpty,
               pendingTaskAttachmentMutations.isEmpty,
               activeTaskFlushes.isEmpty,
               inFlightTaskPatches.isEmpty {
                return true
            }
        }
    }

    @discardableResult
    func createList(name: String, color: String = "blue") async -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName.isEmpty == false else { return false }

        let previousIDs = Set(lists.map(\.id))
        let created = await update {
            try await repository.createList(name: normalizedName, color: color)
        }
        guard created else { return false }
        if let newList = lists.first(where: { previousIDs.contains($0.id) == false }) {
            selection = .list(newList.id)
        }
        return true
    }

    /// Creates a list named after the task and moves that task into it as one
    /// atomic Engine mutation. If the Engine committed but its response was
    /// lost, the authoritative snapshot identifies the newly created list.
    @discardableResult
    func createListFromTask(taskID: UUID) async -> Bool {
        guard
            !isPreparingToTerminate,
            task(id: taskID) != nil,
            failedTaskCommands[taskID]?.recoveryOnly != true,
            activeTaskCommands.insert(taskID).inserted
        else {
            return false
        }
        defer { finishTaskCommand(taskID: taskID) }
        clearRetriableTaskCommandFailure(taskID: taskID)

        guard await flushTaskEdits(taskID: taskID) else { return false }
        guard task(id: taskID) != nil else {
            errorMessage = nil
            return false
        }
        let previousListIDs = Set(lists.map(\.id))
        taskSaveStates[taskID] = .saving

        do {
            let snapshot = try await repository.createListFromTask(taskID: taskID)
            apply(snapshot, acceptingEqualMutationRevision: true)
        } catch {
            let isAmbiguous = isAmbiguousTaskCommandError(error)
            if isAmbiguous,
               await recoverCreatedListFromTask(
                    taskID: taskID,
                    previousListIDs: previousListIDs
               ) {
                // The Engine committed before its response was lost.
            } else {
                // A concurrent Agent deletion supersedes this task-scoped
                // command. Do not recreate failure state for the removed ID.
                guard task(id: taskID) != nil else {
                    errorMessage = nil
                    return false
                }
                failedTaskCommands[taskID] = .createList(
                    previousListIDs: previousListIDs,
                    recoveryOnly: isAmbiguous
                )
                taskSaveStates[taskID] = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
                return false
            }
        }

        guard task(id: taskID) != nil else {
            errorMessage = nil
            return false
        }
        failedTaskCommands[taskID] = nil
        taskSaveStates[taskID] = .idle
        errorMessage = nil
        if let listID = task(id: taskID)?.listID,
           previousListIDs.contains(listID) == false,
           lists.contains(where: { $0.id == listID }) {
            selection = .list(listID)
        }
        return true
    }

    /// Deletes only after explicit UI confirmation. No optimistic removal is
    /// performed: the card stays visible until an authoritative snapshot says
    /// the task is gone. Active task Sessions may be rejected by the Engine.
    @discardableResult
    func deleteTask(taskID: UUID) async -> Bool {
        guard
            !isPreparingToTerminate,
            task(id: taskID) != nil,
            failedTaskCommands[taskID]?.recoveryOnly != true,
            activeTaskCommands.insert(taskID).inserted
        else {
            return false
        }
        defer { finishTaskCommand(taskID: taskID) }
        clearRetriableTaskCommandFailure(taskID: taskID)

        guard await flushTaskEdits(taskID: taskID) else { return false }
        // A task.changed snapshot may have removed this task while its local
        // edits were draining. Treat that authoritative deletion as success
        // instead of issuing a second delete for an ID that no longer exists.
        guard task(id: taskID) != nil else {
            errorMessage = nil
            return true
        }
        taskSaveStates[taskID] = .saving

        do {
            let snapshot = try await repository.deleteTask(taskID: taskID)
            apply(snapshot, acceptingEqualMutationRevision: true)
        } catch {
            // The Agent may have deleted the same task while this request was
            // in flight. apply(_:) already removed every task-scoped draft and
            // failure in that case, so do not recreate a failed delete command.
            guard task(id: taskID) != nil else {
                errorMessage = nil
                return true
            }
            let isAmbiguous = isAmbiguousTaskCommandError(error)
            if isAmbiguous, await recoverDeletedTask(taskID: taskID) {
                // The Engine committed before its response was lost.
            } else {
                let message = deleteTaskErrorMessage(error)
                failedTaskCommands[taskID] = .delete(recoveryOnly: isAmbiguous)
                taskSaveStates[taskID] = .failed(message)
                errorMessage = message
                return false
            }
        }

        guard task(id: taskID) == nil else {
            let message = "删除任务后返回的数据仍包含该任务，请重试。"
            taskSaveStates[taskID] = .failed(message)
            errorMessage = message
            return false
        }
        errorMessage = nil
        return true
    }

    func isTaskCommandInFlight(taskID: UUID) -> Bool {
        activeTaskCommands.contains(taskID)
            || failedTaskCommands[taskID]?.recoveryOnly == true
    }

    private func waitForActiveTaskCommands() async {
        guard activeTaskCommands.isEmpty == false else { return }
        await withCheckedContinuation { continuation in
            if activeTaskCommands.isEmpty {
                continuation.resume()
            } else {
                activeTaskCommandWaiters.append(continuation)
            }
        }
    }

    private func finishTaskCommand(taskID: UUID) {
        activeTaskCommands.remove(taskID)
        guard activeTaskCommands.isEmpty else { return }
        let waiters = activeTaskCommandWaiters
        activeTaskCommandWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    @discardableResult
    func createTask(
        title: String,
        note: String = "",
        executionDate: LocalDay? = nil,
        dueDate: LocalDay? = nil
    ) async -> Bool {
        let listID: UUID? = if case let .list(id) = selection { id } else { nil }
        return await createTask(
            title: title,
            note: note,
            listID: listID,
            executionDate: executionDate,
            dueDate: dueDate
        )
    }

    @discardableResult
    func createTask(
        title: String,
        note: String = "",
        listID: UUID?,
        executionDate: LocalDay? = nil,
        dueDate: LocalDay? = nil
    ) async -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.count <= 500, note.count <= 4_000 else {
            errorMessage = normalizedTitle.isEmpty
                ? "任务标题不能为空。"
                : normalizedTitle.count > 500 ? "任务标题不能超过 500 个字符。" : "任务备注不能超过 4000 个字符。"
            return false
        }
        return await update {
            try await repository.createTask(
                title: normalizedTitle,
                note: note,
                listID: listID,
                executionDate: executionDate,
                dueDate: dueDate
            )
        }
    }

    @discardableResult
    func setCompleted(_ task: TaskItem, completed: Bool) async -> Bool {
        await updateTask(
            taskID: task.id,
            patch: TaskPatch(status: completed ? .completed : .open)
        )
    }

    /// Preserves event order for immediate detail edits. The patch is merged
    /// and projected synchronously on MainActor before one per-task drain is
    /// registered, so consecutive DatePicker/Toggle callbacks cannot race as
    /// independent fire-and-forget tasks.
    func enqueueImmediateTaskUpdate(taskID: UUID, patch: TaskPatch) {
        guard isTaskCommandInFlight(taskID: taskID) == false else { return }
        guard let patch = changedTaskPatch(taskID: taskID, patch: patch) else { return }
        queueTaskPatch(taskID: taskID, patch: patch)
        beginImmediateTaskFlush(taskID: taskID)
    }

    /// Queues a title/note patch for the 400 ms autosave window. The draft is
    /// projected immediately and remains visible if persistence fails.
    func scheduleTaskUpdate(taskID: UUID, patch: TaskPatch) {
        guard isTaskCommandInFlight(taskID: taskID) == false else { return }
        guard let patch = changedTaskPatch(taskID: taskID, patch: patch) else { return }
        queueTaskPatch(taskID: taskID, patch: patch)
        taskSaveStates[taskID] = activeTaskFlushes[taskID] == nil ? .debouncing : .saving
        taskDebounceTasks[taskID]?.cancel()
        taskDebounceTasks[taskID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch { return }
            guard !Task.isCancelled else { return }
            _ = await self?.flushTaskEdits(taskID: taskID)
        }
    }

    /// Applies a patch immediately or enters the title/note debounce window.
    /// Date/status UI should pass the default `debounce: false`.
    @discardableResult
    func updateTask(
        taskID: UUID,
        patch: TaskPatch,
        debounce: Bool = false
    ) async -> Bool {
        guard isTaskCommandInFlight(taskID: taskID) == false else { return false }
        guard task(id: taskID) != nil else {
            taskSaveStates[taskID] = .failed("找不到这个任务。")
            return false
        }
        guard let patch = changedTaskPatch(taskID: taskID, patch: patch) else { return true }
        if debounce {
            scheduleTaskUpdate(taskID: taskID, patch: patch)
            return true
        }
        queueTaskPatch(taskID: taskID, patch: patch)
        return await flushTaskEdits(taskID: taskID)
    }

    @discardableResult
    func flushTaskEdits(taskID: UUID) async -> Bool {
        taskDebounceTasks[taskID]?.cancel()
        taskDebounceTasks[taskID] = nil

        while true {
            if let active = activeTaskFlushes[taskID] {
                guard await active.task.value else {
                    guard task(id: taskID) != nil else {
                        cleanUpDeletedTask(taskID: taskID)
                        return true
                    }
                    return false
                }
                continue
            }

            guard task(id: taskID) != nil else {
                cleanUpDeletedTask(taskID: taskID)
                return true
            }

            if let flush = startTaskFlushIfNeeded(taskID: taskID) {
                guard await flush.value else {
                    guard task(id: taskID) != nil else {
                        cleanUpDeletedTask(taskID: taskID)
                        return true
                    }
                    return false
                }
                continue
            }

            if case .failed = taskSaveStates[taskID] { return false }
            taskSaveStates[taskID] = .idle
            return true
        }
    }

    @discardableResult
    func retryTaskEdits(taskID: UUID) async -> Bool {
        guard task(id: taskID) != nil else {
            cleanUpDeletedTask(taskID: taskID)
            return true
        }
        if let command = failedTaskCommands.removeValue(forKey: taskID) {
            taskSaveStates[taskID] = .idle
            return await retryTaskCommand(command, taskID: taskID)
        }
        guard hasPendingTaskMutations(taskID: taskID) else {
            taskSaveStates[taskID] = .idle
            return true
        }
        return await flushTaskEdits(taskID: taskID)
    }

    func taskSaveState(taskID: UUID) -> TaskSaveState {
        taskSaveStates[taskID, default: .idle]
    }

    func enqueueTaskAttachmentAdd(taskID: UUID, sourcePaths: [String]) {
        guard sourcePaths.isEmpty == false else { return }
        enqueueTaskAttachmentMutation(
            taskID: taskID,
            mutation: .add(
                sourcePaths: sourcePaths,
                clientMutationID: UUID()
            )
        )
    }

    func enqueueTaskAttachmentRemoval(taskID: UUID, attachmentID: UUID) {
        enqueueTaskAttachmentMutation(
            taskID: taskID,
            mutation: .remove(
                attachmentID: attachmentID,
                clientMutationID: UUID()
            )
        )
    }

    @discardableResult
    func addTaskAttachments(taskID: UUID, sourcePaths: [String]) async -> Bool {
        guard sourcePaths.isEmpty == false else { return false }
        enqueueTaskAttachmentAdd(taskID: taskID, sourcePaths: sourcePaths)
        return await flushTaskEdits(taskID: taskID)
    }

    @discardableResult
    func removeTaskAttachment(taskID: UUID, attachmentID: UUID) async -> Bool {
        enqueueTaskAttachmentRemoval(taskID: taskID, attachmentID: attachmentID)
        return await flushTaskEdits(taskID: taskID)
    }

    func taskAttachments(taskID: UUID) -> [TaskAttachment] {
        task(id: taskID)?.attachments ?? []
    }

    func attachmentURL(_ attachment: TaskAttachment) -> URL? {
        attachment.managedURL()
    }

    func openTask(_ task: TaskItem) {
        guard self.task(id: task.id) != nil else { return }
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
        if hasPendingTaskMutations(taskID: taskID) == false,
           activeTaskFlushes[taskID] == nil {
            finishDismissingTaskSession(taskID: taskID)
            return
        }
        Task { @MainActor [weak self] in
            _ = await self?.flushAndDismissTaskSession(taskID: taskID)
        }
    }

    @discardableResult
    func flushAndDismissTaskSession(taskID: UUID) async -> Bool {
        guard await flushTaskEdits(taskID: taskID) else { return false }
        finishDismissingTaskSession(taskID: taskID)
        return true
    }

    private func finishDismissingTaskSession(taskID: UUID) {
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
                presentedSheet == .taskSession(taskID),
                task(id: taskID) != nil
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
                presentedSheet == .taskSession(taskID),
                task(id: taskID) != nil
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
        guard self.task(id: task.id) != nil else { return false }
        guard await flushTaskEdits(taskID: task.id) else {
            guard self.task(id: task.id) != nil else {
                taskSessionErrorMessage = nil
                return false
            }
            taskSessionErrorMessage = "任务修改尚未保存，请重试后再启动 Session。"
            return false
        }
        guard self.task(id: task.id) != nil else {
            taskSessionErrorMessage = nil
            return false
        }
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
            guard self.task(id: task.id) != nil else {
                taskSessionErrorMessage = nil
                return false
            }
            merge(bundle, taskID: task.id)
            if let snapshot = try? await repository.sync() {
                apply(snapshot)
            }
            guard self.task(id: task.id) != nil else {
                taskSessionErrorMessage = nil
                return false
            }
            return true
        } catch {
            guard self.task(id: task.id) != nil else {
                taskSessionErrorMessage = nil
                return false
            }
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
    func tasks(executingOn day: LocalDay) -> [TaskItem] { projection.tasks(executingOn: day) }
    func todayTasks() -> [TaskItem] { projection.todayTasks() }
    func timelineDays() -> [TimelineDay] {
        projection.timelineDays(startingAt: selectedDay, calendar: calendar)
    }
    func shiftSelectedDay(by days: Int) {
        if let day = selectedDay.advanced(by: days, calendar: calendar) {
            selectedDay = day
        }
    }
    func selectToday() { selectedDay = currentDay }
    func timelineBuckets() -> [BoardBucket: [TaskItem]] {
        projection.timelineBuckets(selectedDay: selectedDay, calendar: calendar)
    }
    func isOverdue(_ task: TaskItem) -> Bool { projection.isOverdue(task) }
    var readyRuntimeCount: Int { runtimes.count(where: \.isSelectable) }
    func visibleTasks() -> [TaskItem] {
        projection.visibleTasks(for: selection, sessions: sessions)
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

    func consume(_ event: EngineEvent) async {
        if event.name.hasPrefix("assistant.") {
            return
        } else if event.name == "engine.ready" {
            recoverSnapshotAfterEngineReadyIfNeeded()
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
        } else if event.name == "task.changed" {
            if let payload = try? JSONDecoder.engineDecoder.decode(
                EngineBootstrap.self,
                from: event.data
            ) {
                apply(EngineRepository.mapSnapshot(payload, messages: messages))
            }
        } else if event.name == "runtime.changed" {
            _ = await update { try await repository.sync() }
        }
    }

    /// `load()` subscribes after the startup handshake, so every ready observed
    /// on this stream represents a restarted sidecar. One coalesced sync repairs
    /// any mutation whose durable response/event was lost with that process.
    private func recoverSnapshotAfterEngineReadyIfNeeded() {
        guard hasAppliedSnapshot, activeEngineRecovery == nil else { return }

        let token = UUID()
        let recovery = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.repository.sync()
                self.apply(snapshot)
            } catch is CancellationError {
                // App shutdown or a superseding lifecycle ends recovery.
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.finishEngineRecovery(token: token)
        }
        activeEngineRecovery = ActiveEngineRecovery(token: token, task: recovery)
    }

    private func finishEngineRecovery(token: UUID) {
        guard activeEngineRecovery?.token == token else { return }
        activeEngineRecovery = nil
    }

    private func merge(_ incoming: SessionBundle, taskID: UUID) {
        // A late session event must not recreate UI state for a task already
        // removed by a newer authoritative task snapshot.
        guard task(id: taskID) != nil else { return }
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

    private func recoverCreatedListFromTask(
        taskID: UUID,
        previousListIDs: Set<UUID>
    ) async -> Bool {
        do {
            apply(try await repository.sync())
            guard
                let listID = task(id: taskID)?.listID,
                previousListIDs.contains(listID) == false,
                lists.contains(where: { $0.id == listID })
            else { return false }
            selection = .list(listID)
            return true
        } catch {
            return false
        }
    }

    private func recoverDeletedTask(taskID: UUID) async -> Bool {
        do {
            apply(try await repository.sync())
            return task(id: taskID) == nil
        } catch {
            return false
        }
    }

    private func isAmbiguousTaskCommandError(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? EngineClientError else { return false }
        return switch error {
        case .notRunning, .invalidMessage, .timedOut, .processExited:
            true
        case .executableMissing, .alreadyStarted, .launchFailed, .protocolMismatch,
             .requestFailed:
            false
        }
    }

    private func deleteTaskErrorMessage(_ error: any Error) -> String {
        if let engineError = error as? EngineClientError,
           case let .requestFailed(code, _) = engineError,
           code == "task_session_active" {
            return "任务的本地 Session 正在运行，请先停止本轮再删除。"
        }
        return error.localizedDescription
    }

    private func cleanUpDeletedTask(taskID: UUID) {
        taskDebounceTasks[taskID]?.cancel()
        taskDebounceTasks[taskID] = nil
        pendingTaskPatches[taskID] = nil
        inFlightTaskPatches[taskID] = nil
        pendingTaskAttachmentMutations[taskID] = nil
        taskSaveStates[taskID] = nil
        failedTaskCommands[taskID] = nil
        bundles[taskID] = nil
        sessions.removeAll(where: { $0.taskID == taskID })
        if presentedSheet == .taskSession(taskID) || loadingSessionTaskID == taskID {
            finishDismissingTaskSession(taskID: taskID)
        }
    }

    private func clearRetriableTaskCommandFailure(taskID: UUID) {
        guard failedTaskCommands[taskID]?.recoveryOnly == false else { return }
        failedTaskCommands[taskID] = nil
        if hasPendingTaskMutations(taskID: taskID) == false {
            taskSaveStates[taskID] = .idle
        }
    }

    private func retryTaskCommand(
        _ command: FailedTaskCommand,
        taskID: UUID
    ) async -> Bool {
        guard command.recoveryOnly else {
            switch command {
            case .createList:
                return await createListFromTask(taskID: taskID)
            case .delete:
                return await deleteTask(taskID: taskID)
            }
        }

        guard activeTaskCommands.insert(taskID).inserted else { return false }
        defer { finishTaskCommand(taskID: taskID) }
        taskSaveStates[taskID] = .saving

        let recovered: Bool
        switch command {
        case let .createList(previousListIDs, _):
            recovered = await recoverCreatedListFromTask(
                taskID: taskID,
                previousListIDs: previousListIDs
            )
        case .delete:
            recovered = await recoverDeletedTask(taskID: taskID)
        }

        guard recovered else {
            guard task(id: taskID) != nil else {
                errorMessage = nil
                return false
            }
            let message = "任务操作结果尚未确认。请恢复 Engine 后重试确认，系统不会重复执行。"
            failedTaskCommands[taskID] = command
            taskSaveStates[taskID] = .failed(message)
            errorMessage = message
            return false
        }

        switch command {
        case .createList:
            taskSaveStates[taskID] = .idle
        case .delete:
            break
        }
        errorMessage = nil
        return true
    }

    private func apply(
        _ snapshot: AppSnapshot,
        acceptingEqualMutationRevision: Bool = false
    ) {
        guard
            !hasAppliedSnapshot
                || snapshot.revision > revision
                || (acceptingEqualMutationRevision && snapshot.revision == revision)
        else { return }
        let removedTaskIDs = Set(tasks.map(\.id)).subtracting(
            Set(snapshot.tasks.map(\.id))
        )
        hasAppliedSnapshot = true
        revision = snapshot.revision
        lists = snapshot.lists
        tasks = snapshot.tasks
        runtimes = snapshot.runtimes
        sessions = snapshot.sessions
        messages = snapshot.messages
        for taskID in removedTaskIDs {
            cleanUpDeletedTask(taskID: taskID)
        }
        reapplyTaskDrafts()
        rebuildProjection()
    }

    private func queueTaskPatch(taskID: UUID, patch: TaskPatch) {
        guard tasks.contains(where: { $0.id == taskID }) else {
            taskSaveStates[taskID] = .failed("找不到这个任务。")
            return
        }
        pendingTaskPatches[taskID] = pendingTaskPatches[taskID]?.merging(patch) ?? patch
        applyDraft(patch, to: taskID)
    }

    private func changedTaskPatch(taskID: UUID, patch: TaskPatch) -> TaskPatch? {
        guard let task = task(id: taskID) else {
            taskSaveStates[taskID] = .failed("找不到这个任务。")
            return nil
        }

        var changed = patch
        if changed.title == task.title { changed.title = nil }
        if changed.note == task.note { changed.note = nil }
        if changed.status == task.status { changed.status = nil }
        changed.listID = changedField(changed.listID, current: task.listID)
        changed.executionDate = changedField(
            changed.executionDate,
            current: task.executionDate
        )
        changed.dueDate = changedField(changed.dueDate, current: task.dueDate)
        return changed.isEmpty ? nil : changed
    }

    private func changedField<Value: Equatable & Sendable>(
        _ field: TaskPatchField<Value>,
        current: Value?
    ) -> TaskPatchField<Value> {
        switch field {
        case .unchanged:
            .unchanged
        case let .set(value):
            current == value ? .unchanged : .set(value)
        case .clear:
            current == nil ? .unchanged : .clear
        }
    }

    private func beginImmediateTaskFlush(taskID: UUID) {
        taskDebounceTasks[taskID]?.cancel()
        taskDebounceTasks[taskID] = nil
        taskSaveStates[taskID] = .saving
        _ = startTaskFlushIfNeeded(taskID: taskID)
    }

    private func enqueueTaskAttachmentMutation(
        taskID: UUID,
        mutation: TaskAttachmentMutation
    ) {
        guard task(id: taskID) != nil else {
            taskSaveStates[taskID] = .failed("找不到这个任务。")
            return
        }
        pendingTaskAttachmentMutations[taskID, default: []].append(mutation)
        beginImmediateTaskFlush(taskID: taskID)
    }

    private func hasPendingTaskMutations(taskID: UUID) -> Bool {
        pendingTaskPatches[taskID] != nil
            || pendingTaskAttachmentMutations[taskID]?.isEmpty == false
    }

    private func startTaskFlushIfNeeded(taskID: UUID) -> Task<Bool, Never>? {
        if let active = activeTaskFlushes[taskID] { return active.task }
        guard hasPendingTaskMutations(taskID: taskID) else { return nil }

        let token = UUID()
        let flush = Task { @MainActor [weak self] in
            guard let self else { return false }
            let succeeded = await self.drainTaskMutations(taskID: taskID)
            self.finishTaskFlush(taskID: taskID, token: token)
            return succeeded
        }
        // This method is synchronous on MainActor, so the handle is registered
        // before the new task can begin and a second UI callback can enqueue.
        activeTaskFlushes[taskID] = ActiveTaskFlush(token: token, task: flush)
        return flush
    }

    /// One task owns one drain loop for patches and attachment mutations. New
    /// work queued while the Engine is suspended is consumed by that same loop
    /// before close, Session start, or app termination is allowed to continue.
    private func drainTaskMutations(taskID: UUID) async -> Bool {
        while true {
            guard task(id: taskID) != nil else {
                cleanUpDeletedTask(taskID: taskID)
                return true
            }

            if let patch = pendingTaskPatches.removeValue(forKey: taskID) {
                taskSaveStates[taskID] = .saving
                inFlightTaskPatches[taskID] = patch
                do {
                    let snapshot = try await repository.updateTask(taskID: taskID, patch: patch)
                    // The response is authoritative for normalization. A
                    // matching task.changed may have arrived first, so accept
                    // this response at the same (never lower) revision once.
                    inFlightTaskPatches[taskID] = nil
                    apply(snapshot, acceptingEqualMutationRevision: true)
                } catch is CancellationError {
                    inFlightTaskPatches[taskID] = nil
                    guard task(id: taskID) != nil else { return true }
                    restoreFailedTaskPatch(patch, taskID: taskID)
                    taskSaveStates[taskID] = .failed("任务保存已取消，请重试。")
                    return false
                } catch {
                    inFlightTaskPatches[taskID] = nil
                    guard task(id: taskID) != nil else { return true }
                    restoreFailedTaskPatch(patch, taskID: taskID)
                    taskSaveStates[taskID] = .failed(error.localizedDescription)
                    return false
                }
                continue
            }

            guard let attachmentMutation = takeNextAttachmentMutation(taskID: taskID) else {
                taskSaveStates[taskID] = .idle
                return true
            }

            taskSaveStates[taskID] = .saving
            do {
                let snapshot = try await performAttachmentMutation(
                    attachmentMutation,
                    taskID: taskID
                )
                apply(snapshot, acceptingEqualMutationRevision: true)
            } catch {
                guard task(id: taskID) != nil else { return true }
                if await recoverAmbiguousAttachmentMutation(
                    attachmentMutation,
                    taskID: taskID,
                    error: error
                ) {
                    continue
                }
                // Recovery performs a sync and can discover that an Agent
                // deleted the task. Never put the attachment mutation back on
                // a queue whose owner no longer exists.
                guard task(id: taskID) != nil else { return true }
                restoreFailedAttachmentMutation(attachmentMutation, taskID: taskID)
                taskSaveStates[taskID] = .failed(
                    isAmbiguousAttachmentMutationError(error)
                        ? "附件操作结果尚未确认：\(error.localizedDescription)；请重试，系统会避免重复执行。"
                        : error.localizedDescription
                )
                return false
            }
        }
    }

    private func performAttachmentMutation(
        _ mutation: TaskAttachmentMutation,
        taskID: UUID
    ) async throws -> AppSnapshot {
        switch mutation {
        case let .add(sourcePaths, clientMutationID):
            try await repository.addTaskAttachments(
                taskID: taskID,
                sourcePaths: sourcePaths,
                clientMutationID: clientMutationID
            )
        case let .remove(attachmentID, clientMutationID):
            try await repository.removeTaskAttachment(
                taskID: taskID,
                attachmentID: attachmentID,
                clientMutationID: clientMutationID
            )
        }
    }

    private func recoverAmbiguousAttachmentMutation(
        _ mutation: TaskAttachmentMutation,
        taskID: UUID,
        error: any Error
    ) async -> Bool {
        guard isAmbiguousAttachmentMutationError(error) else { return false }

        do {
            let recovered = try await repository.sync()
            apply(recovered)

            if case let .remove(attachmentID, _) = mutation,
               task(id: taskID)?.attachments.contains(where: { $0.id == attachmentID }) != true {
                return true
            }

            // Add cannot be correlated from attachment names alone. Replaying
            // the exact durable mutation ID asks the Engine to resolve the
            // outcome without copying a second file. It also safely completes
            // an operation that was definitely not committed before restart.
            let resolved = try await performAttachmentMutation(mutation, taskID: taskID)
            apply(resolved, acceptingEqualMutationRevision: true)
            return true
        } catch {
            return false
        }
    }

    private func isAmbiguousAttachmentMutationError(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        guard let error = error as? EngineClientError else { return false }
        return switch error {
        case .notRunning, .invalidMessage, .timedOut, .processExited:
            true
        case .executableMissing, .alreadyStarted, .launchFailed, .protocolMismatch,
             .requestFailed:
            false
        }
    }

    private func restoreFailedTaskPatch(_ patch: TaskPatch, taskID: UUID) {
        // Restore the failed write before any newer draft so newer fields win.
        let restored = patch.merging(pendingTaskPatches[taskID] ?? TaskPatch())
        pendingTaskPatches[taskID] = restored
        applyDraft(restored, to: taskID)
    }

    private func takeNextAttachmentMutation(taskID: UUID) -> TaskAttachmentMutation? {
        guard var queued = pendingTaskAttachmentMutations[taskID], queued.isEmpty == false else {
            pendingTaskAttachmentMutations[taskID] = nil
            return nil
        }
        let mutation = queued.removeFirst()
        pendingTaskAttachmentMutations[taskID] = queued.isEmpty ? nil : queued
        return mutation
    }

    private func restoreFailedAttachmentMutation(
        _ mutation: TaskAttachmentMutation,
        taskID: UUID
    ) {
        pendingTaskAttachmentMutations[taskID, default: []].insert(mutation, at: 0)
    }

    private func finishTaskFlush(taskID: UUID, token: UUID) {
        guard activeTaskFlushes[taskID]?.token == token else { return }
        activeTaskFlushes[taskID] = nil
    }

    private func applyDraft(_ patch: TaskPatch, to taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].apply(patch)
        rebuildProjection()
    }

    private func reapplyTaskDrafts() {
        for (taskID, patch) in inFlightTaskPatches {
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { continue }
            tasks[index].apply(patch)
        }
        for (taskID, patch) in pendingTaskPatches {
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { continue }
            tasks[index].apply(patch)
        }
    }

    private func rebuildProjection() {
        projection = TaskProjection(tasks: tasks, today: currentDay)
    }

    private func installCalendarObservers() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSCalendarDayChanged,
            .NSSystemClockDidChange,
            .NSSystemTimeZoneDidChange,
            NSApplication.didBecomeActiveNotification,
        ]
        calendarObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshLocalDay()
                }
            }
        }

        workspaceCalendarObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshLocalDay()
            }
        }
    }

    func refreshLocalDay(now: Date = .now) {
        let newDay = LocalDay(now, calendar: calendar)
        if newDay != currentDay {
            let wasFollowingToday = selectedDay == currentDay
            currentDay = newDay
            if wasFollowingToday {
                selectedDay = newDay
            }
            rebuildProjection()
        }
        scheduleLocalDayRefresh(now: now)
    }

    private func scheduleLocalDayRefresh(now: Date = .now) {
        localDayRefreshTask?.cancel()
        let start = calendar.startOfDay(for: now)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return }
        let delay = max(nextDay.timeIntervalSince(now) + 0.25, 0.25)
        localDayRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            guard !Task.isCancelled else { return }
            self?.refreshLocalDay()
        }
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
    @ObservationIgnored private var shouldEnsureDefaultSession = false

    private var bundles: [String: AssistantSessionBundle] = [:]
    private var drafts: [String: AssistantStreamingDraft] = [:]
    private var toolsBySession: [String: [String: AssistantToolActivity]] = [:]
    private var toolOrderBySession: [String: [String]] = [:]
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
        let orderedIDs = toolOrderBySession[selectedSessionID] ?? []
        let order = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($0.element, $0.offset) })
        return tools.sorted { lhs, rhs in
            let left = order[lhs.toolCallID] ?? .max
            let right = order[rhs.toolCallID] ?? .max
            return left == right ? lhs.toolCallID < rhs.toolCallID : left < right
        }
    }

    var selectedTimelineItems: [AssistantConversationTimelineItem] {
        Self.conversationTimeline(messages: selectedMessages, tools: selectedTools)
    }

    static func conversationTimeline(
        messages: [AssistantMessage],
        tools: [AssistantToolActivity]
    ) -> [AssistantConversationTimelineItem] {
        var toolsByTurn: [String: [AssistantToolActivity]] = [:]
        for tool in tools {
            if !tool.turnID.isEmpty {
                toolsByTurn[tool.turnID, default: []].append(tool)
            }
        }

        var insertedToolIDs = Set<String>()
        var timeline: [AssistantConversationTimelineItem] = []

        func appendTools(for turnID: String?) {
            guard let turnID, let turnTools = toolsByTurn[turnID] else { return }
            let uninserted = turnTools.filter {
                insertedToolIDs.insert($0.toolCallID).inserted
            }
            if !uninserted.isEmpty {
                timeline.append(
                    .toolGroup(AssistantToolGroup(turnID: turnID, tools: uninserted))
                )
            }
        }

        for message in messages.sorted(by: { $0.sequence < $1.sequence }) {
            // A recovered history can contain the final assistant message even
            // if its user message fell outside the current page. Insert the
            // turn's tools before that final response in this case.
            if message.role == .todoAgent {
                appendTools(for: message.turnID)
            }

            timeline.append(.message(message))

            // During a live turn, tools become visible immediately after the
            // user's request and before streaming/final assistant text.
            if message.role == .user {
                appendTools(for: message.turnID)
            }
        }

        let remaining = tools.filter {
            insertedToolIDs.insert($0.toolCallID).inserted
        }
        var remainingByTurn: [String: [AssistantToolActivity]] = [:]
        var remainingTurnIDs: [String] = []
        for tool in remaining {
            if remainingByTurn[tool.turnID] == nil {
                remainingTurnIDs.append(tool.turnID)
            }
            remainingByTurn[tool.turnID, default: []].append(tool)
        }
        for turnID in remainingTurnIDs {
            guard let group = remainingByTurn[turnID] else { continue }
            timeline.append(.toolGroup(AssistantToolGroup(turnID: turnID, tools: group)))
        }
        return timeline
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

    /// Makes the first TodoAgent open land in a usable conversation instead
    /// of an intermediate "create session" screen. If opening happens while
    /// credentials or Engine state are still loading, the intent is retained
    /// and fulfilled by the next successful content reload.
    @discardableResult
    func ensureDefaultSession() async -> Bool {
        shouldEnsureDefaultSession = true
        return await provisionDefaultSessionIfPossible()
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
            toolOrderBySession.removeValue(forKey: selectedSessionID)
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
            if shouldEnsureDefaultSession {
                _ = await provisionDefaultSessionIfPossible()
            }
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
            errorMessage = nil
        }
    }

    private func provisionDefaultSessionIfPossible() async -> Bool {
        if selectedSession != nil {
            shouldEnsureDefaultSession = false
            return true
        }
        if let existing = activeSessions.first {
            await selectSession(existing.id)
            let selected = selectedSessionID == existing.id
            if selected { shouldEnsureDefaultSession = false }
            return selected
        }
        guard loadState == .loaded, canUseAssistant else { return false }

        let created = await createSession()
        if created { shouldEnsureDefaultSession = false }
        return created
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
            toolOrderBySession.removeAll()
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
        rememberToolOrder(sessionID: payload.sessionID, callID: payload.toolCallID)
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
        rememberToolOrder(sessionID: payload.sessionID, callID: payload.toolCallID)
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
                rememberToolOrder(sessionID: tool.sessionID, callID: tool.callID)
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
            toolOrderBySession.removeValue(forKey: sessionID)
        }
    }

    private func rememberToolOrder(sessionID: String, callID: String) {
        var ordered = toolOrderBySession[sessionID] ?? []
        guard ordered.contains(callID) == false else { return }
        ordered.append(callID)
        toolOrderBySession[sessionID] = ordered
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
