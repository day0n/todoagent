import Darwin
import Foundation
import Testing
@testable import TodoAgentApp

@MainActor
struct TerminalExitJournalTests {
    @Test("journal atomically preserves exact records and removes only acknowledged runs")
    func roundTripAndExactReplay() throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = TerminalExitJournalStore(directoryURL: fixture.directory)
        let first = exitRecord(exitCode: 143, reason: .appShutdown)
        let second = exitRecord(exitCode: 0, reason: .processExit)

        try store.store(first)
        try store.store(first)
        try store.store(second)

        #expect(try store.records() == [first, second].sorted { $0.runID < $1.runID })
        #expect(try permissions(of: fixture.directory) == 0o700)
        #expect(try permissions(of: fixture.file) == 0o600)

        try store.remove(runID: first.runID)
        #expect(try store.records() == [second])
        try store.remove(runID: second.runID)
        #expect(try store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test("journal refuses a different result for an existing run")
    func conflictingRecordFailsClosed() throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let store = TerminalExitJournalStore(directoryURL: fixture.directory)
        let record = exitRecord(exitCode: 1, reason: .processExit)
        try store.store(record)
        let conflicting = TerminalExitRecord(
            taskID: record.taskID,
            sessionID: record.sessionID,
            runID: record.runID,
            exitCode: 2,
            reason: record.reason,
            errorCode: record.errorCode,
            errorMessage: record.errorMessage
        )

        #expect(throws: TerminalExitJournalError.conflictingRecord(record.runID)) {
            try store.store(conflicting)
        }
        #expect(try store.records() == [record])
    }

    @Test("journal rejects a symbolic-link destination without touching its target")
    func symbolicLinkFailsClosed() throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("unchanged".utf8).write(to: target)
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        let store = TerminalExitJournalStore(directoryURL: fixture.directory)

        #expect(throws: TerminalExitJournalError.symbolicLink) {
            try store.store(exitRecord())
        }
        #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
    }

    @Test("shutdown deadline releases every caller while an Engine mutation is suspended")
    func shutdownDeadlineDefersStalledEngineWrite() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let journal = TerminalExitJournalStore(directoryURL: fixture.directory)
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let bundle = testExitBundle(
            taskID: taskID,
            sessionID: sessionID,
            activeRun: testExitRun(
                id: runID,
                sessionID: sessionID,
                state: .running,
                startedAt: "2026-08-13T00:00:00Z"
            )
        )
        let repository = StalledExitRepository(bundle: bundle)
        let registry = TerminalSessionRegistry(
            repository: repository,
            exitJournal: journal,
            shutdownExitPersistenceDeadline: .zero
        )
        let controller = try #require(registry.restore(bundle))

        let firstEnd = Task { @MainActor in
            await controller.end(
                reason: .appShutdown,
                persistenceDeadline: .seconds(60)
            )
        }
        await repository.waitUntilStoppingMutationStarts()

        await registry.endAll(reason: .appShutdown)
        await firstEnd.value

        let record = try #require(try await waitForJournalRecord(in: journal))
        #expect(record.taskID == taskID)
        #expect(record.sessionID == sessionID)
        #expect(record.runID == runID)
        #expect(record.reason == .appShutdown)
        #expect(await repository.stoppingRunIDs() == [runID])

        // Let the deliberately non-cancellation-aware fake finish so the
        // abandoned reconciliation task cannot leak beyond this test. Its late
        // success must leave the deferred journal and presentation untouched.
        await repository.releaseStoppingMutation()
        await Task.yield()
        #expect(controller.phase == .ended(exitCode: nil))
        #expect(try journal.records() == [record])
    }

    @Test("an explicit user end remains authoritative when Cmd-Q follows")
    func userEndThenShutdownDoesNotBecomeAutoResume() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let journal = TerminalExitJournalStore(directoryURL: fixture.directory)
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let runID = UUID().uuidString.lowercased()
        let bundle = testExitBundle(
            taskID: taskID,
            sessionID: sessionID,
            activeRun: testExitRun(
                id: runID,
                sessionID: sessionID,
                state: .running,
                startedAt: "2026-08-13T00:00:00Z"
            )
        )
        let repository = StalledExitRepository(bundle: bundle)
        let registry = TerminalSessionRegistry(
            repository: repository,
            exitJournal: journal,
            shutdownExitPersistenceDeadline: .zero
        )
        let controller = try #require(registry.restore(bundle))

        let explicitEnd = Task { @MainActor in
            await controller.end(reason: .userEnded)
        }
        await repository.waitUntilStoppingMutationStarts()

        await registry.endAll(reason: .appShutdown)
        await explicitEnd.value

        let record = try #require(try await waitForJournalRecord(in: journal))
        #expect(record.runID == runID)
        #expect(record.reason == .userEnded)

        await repository.releaseStoppingMutation()
        await Task.yield()
        #expect(controller.phase == .ended(exitCode: nil))
        #expect(try journal.records() == [record])
    }

    @Test("a healthy Engine replay removes the acknowledged journal record")
    func replayAcknowledgesAndRemovesRecord() async throws {
        let fixture = try JournalFixture()
        defer { fixture.remove() }
        let journal = TerminalExitJournalStore(directoryURL: fixture.directory)
        let record = exitRecord(exitCode: 143, reason: .appShutdown)
        try journal.store(record)
        let bundle = testExitBundle(taskID: record.taskID, sessionID: record.sessionID)
        let repository = StalledExitRepository(bundle: bundle, stallExit: false)
        let registry = TerminalSessionRegistry(repository: repository, exitJournal: journal)

        await registry.replayPendingExitReports()

        #expect(try journal.records().isEmpty)
        #expect(await repository.reportedRunIDs() == [record.runID])
    }
}

private func exitRecord(
    exitCode: Int32? = nil,
    reason: TerminalRunExitReason = .appShutdown
) -> TerminalExitRecord {
    TerminalExitRecord(
        taskID: UUID(),
        sessionID: UUID().uuidString.lowercased(),
        runID: UUID().uuidString.lowercased(),
        exitCode: exitCode,
        reason: reason,
        errorCode: nil,
        errorMessage: nil
    )
}

private func testExitBundle(
    taskID: UUID,
    sessionID: String,
    activeRun: TerminalRun? = nil
) -> TerminalSessionBundle {
    TerminalSessionBundle(
        session: TerminalSessionDescriptor(
            id: sessionID,
            taskID: taskID,
            runtimeKind: .claude,
            workingDirectory: "/tmp",
            providerSessionID: "provider-session",
            providerBindingState: .bound,
            providerBindingSource: "test",
            agentStatus: activeRun == nil ? .idle : .active,
            hasActiveRun: activeRun != nil,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: "2026-08-13T00:00:00Z",
            updatedAt: "2026-08-13T00:00:00Z"
        ),
        activeRun: activeRun
    )
}

private func testExitRun(
    id: String,
    sessionID: String,
    state: TerminalRunState,
    startedAt: String?
) -> TerminalRun {
    TerminalRun(
        id: id,
        sessionID: sessionID,
        ordinal: 1,
        launchMode: .fresh,
        state: state,
        providerSessionIDAtLaunch: "provider-session",
        exitCode: nil,
        exitReason: nil,
        errorCode: nil,
        errorMessage: nil,
        startedAt: startedAt,
        exitedAt: nil,
        createdAt: "2026-08-13T00:00:00Z"
    )
}

private struct JournalFixture {
    let root: URL
    let directory: URL
    let file: URL

    init() throws {
        let temporaryRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let lexicalTemporaryRoot = temporaryRoot.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private" + temporaryRoot.path, isDirectory: true)
            : temporaryRoot
        root = lexicalTemporaryRoot
            .appendingPathComponent("todoagent-exit-journal-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("nested/TodoAgent", isDirectory: true)
        file = directory.appendingPathComponent(TerminalExitJournalStore.fileName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private func permissions(of url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return UInt16((attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0)
}

private func waitForJournalRecord(
    in journal: TerminalExitJournalStore
) async throws -> TerminalExitRecord? {
    for _ in 0..<1_000 {
        if let record = try journal.records().only { return record }
        await Task.yield()
    }
    return try journal.records().only
}

private actor StalledExitRepository: AppRepository {
    nonisolated let requiresExecutionConsent = false
    private var bundle: TerminalSessionBundle
    private let stallExit: Bool
    private var stoppingMutationWaiters: [CheckedContinuation<Void, Never>] = []
    private var stoppingStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var stoppingRuns: [String] = []
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var reported: [String] = []

    init(bundle: TerminalSessionBundle, stallExit: Bool = true) {
        self.bundle = bundle
        self.stallExit = stallExit
    }

    private var emptySnapshot: AppSnapshot {
        AppSnapshot(revision: 0, lists: [], tasks: [], runtimes: [], sessions: [], messages: [])
    }

    func load() async throws -> AppSnapshot { emptySnapshot }
    func sync() async throws -> AppSnapshot { emptySnapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createList(name _: String, color _: String) async throws -> AppSnapshot { emptySnapshot }
    func createTask(
        title _: String,
        note _: String,
        listID _: UUID?,
        executionDate _: LocalDay?,
        dueDate _: LocalDay?
    ) async throws -> AppSnapshot { emptySnapshot }
    func updateTask(taskID _: UUID, patch _: TaskPatch) async throws -> AppSnapshot { emptySnapshot }
    func deleteTask(taskID _: UUID) async throws -> AppSnapshot { emptySnapshot }
    func createListFromTask(taskID _: UUID) async throws -> AppSnapshot { emptySnapshot }
    func addTaskAttachments(
        taskID _: UUID,
        sourcePaths _: [String],
        clientMutationID _: UUID
    ) async throws -> AppSnapshot { emptySnapshot }
    func removeTaskAttachment(
        taskID _: UUID,
        attachmentID _: UUID,
        clientMutationID _: UUID
    ) async throws -> AppSnapshot { emptySnapshot }
    func setCompleted(taskID _: UUID, completed _: Bool) async throws -> AppSnapshot { emptySnapshot }
    func detectRuntimes() async throws -> AppSnapshot { emptySnapshot }
    func verifyRuntime(_: RuntimeKind) async throws -> AppSnapshot { emptySnapshot }

    func terminalSession(taskID: UUID) async throws -> TerminalSessionBundle? {
        taskID == bundle.session.taskID ? bundle : nil
    }

    func markTerminalRunStopping(
        sessionID _: String,
        runID: String
    ) async throws -> TerminalSessionBundle {
        stoppingRuns.append(runID)
        let startedWaiters = stoppingStartedWaiters
        stoppingStartedWaiters.removeAll()
        for waiter in startedWaiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            stoppingMutationWaiters.append(continuation)
        }
        return bundle
    }

    func waitUntilStoppingMutationStarts() async {
        if !stoppingRuns.isEmpty { return }
        await withCheckedContinuation { continuation in
            stoppingStartedWaiters.append(continuation)
        }
    }

    func releaseStoppingMutation() {
        let waiters = stoppingMutationWaiters
        stoppingMutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func stoppingRunIDs() -> [String] { stoppingRuns }

    func reportTerminalRunExited(
        sessionID _: String,
        runID: String,
        exitCode _: Int32?,
        reason _: TerminalRunExitReason,
        errorCode _: String?,
        errorMessage _: String?
    ) async throws -> TerminalSessionBundle {
        reported.append(runID)
        if stallExit {
            await withCheckedContinuation { continuation in
                exitWaiters.append(continuation)
            }
        }
        return bundle
    }

    func reportedRunIDs() -> [String] { reported }

    func session(taskID _: UUID) async throws -> SessionBundle? { nil }
    func createSession(
        taskID _: UUID,
        runtime _: RuntimeKind,
        workspace _: String
    ) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func send(
        sessionID _: String,
        text _: String,
        clientMessageID _: UUID
    ) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func history(sessionID _: String, after _: Int64) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func markRead(sessionID _: String, through _: Int64) async throws {}
    func cancelTurn(sessionID _: String) async throws {}
    func injectGeminiKey(_: String) async throws {}
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Test", version: "test")
    }
    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(configured: false, available: false, model: nil, reason: "test")
    }
    func assistantSessions(includeArchived _: Bool) async throws -> [AssistantSessionDescriptor] { [] }
    func createAssistantSession(title _: String?) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func renameAssistantSession(
        sessionID _: String,
        title _: String
    ) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func archiveAssistantSession(sessionID _: String) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func assistantHistory(
        sessionID _: String,
        after _: Int64
    ) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func sendAssistantMessage(
        sessionID _: String,
        clientMessageID _: UUID,
        text _: String,
        model _: String,
        attachments _: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func cancelAssistantTurn(sessionID _: String) async throws {}
    func shutdown() async {}
}

private extension Collection {
    var only: Element? { count == 1 ? first : nil }
}
