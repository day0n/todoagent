import AppKit
import Darwin
import Foundation
import Testing
@testable import TodoAgentApp

@MainActor
struct TerminalSessionControllerTests {
    @Test(
        "a lost prepare response reconciles and durably fails the committed run",
        .timeLimit(.minutes(1))
    )
    func lostPrepareResponseReconcilesCommittedRun() async {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let repository = TerminalControllerTestRepository(
            bundle: terminalBundle(taskID: taskID, sessionID: sessionID),
            prepareResponseIsLost: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let controller = TerminalSessionController(
            bundle: terminalBundle(taskID: taskID, sessionID: sessionID),
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        controller.launch(taskTitle: "Response loss")

        let report = await repository.waitForExitReport()
        let lookupCount = await repository.terminalLookupCount()
        let prepareCount = await repository.prepareCallCount()
        let makeSurfaceCount = surfaceFactory.makeSurfaceCount

        #expect(report.sessionID == sessionID)
        #expect(UUID(uuidString: report.runID) != nil)
        #expect(report.exitCode == nil)
        #expect(report.reason == .launchFailed)
        #expect(report.errorCode == "terminal_surface_launch_failed")
        #expect(report.errorMessage.contains("response was lost"))
        #expect(prepareCount == 1, "controller phase: \(controller.phase)")
        #expect(lookupCount == 1)
        #expect(makeSurfaceCount == 0)
    }

    @Test(
        "a lost started response is reconciled with the same run before exit",
        .timeLimit(.minutes(1))
    )
    func lostStartedResponseIsRecoveredBeforeExit() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(
            bundle: initialBundle,
            startedResponseIsLost: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        controller.launch(taskTitle: "Started response loss")
        let launch = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()

        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "started",
            extra: #""pid":4242,"pgid":4242"#,
            to: launch.socketPath
        )
        await repository.waitUntilFirstStartedAttempt()
        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "exited",
            extra: #""exitCode":0"#,
            to: launch.socketPath
        )

        let report = await repository.waitForExitReport()
        let startedRunIDs = await repository.markStartedRunIDs()
        let recoveredRunIDs = await repository.recoveredStartedIDs()

        #expect(startedRunIDs.isEmpty == false)
        #expect(startedRunIDs.allSatisfy { $0 == launch.runID })
        #expect(recoveredRunIDs == [launch.runID])
        #expect(
            report.startedWasRecoveredBeforeExit,
            "The lost started response must be retried or reconciled before reporting exit."
        )
        #expect(report.runID == launch.runID)
        #expect(report.reason == .processExit)
        #expect(report.startedAt == terminalControllerStartedAt)
        #expect(controller.activeRun?.startedAt == terminalControllerStartedAt)
        #expect(surfaceFactory.makeSurfaceCount == 1)
    }

    @Test(
        "an uncommitted exit failure retries the same payload and keeps end waiting",
        .timeLimit(.minutes(1))
    )
    func uncommittedExitFailureRetriesBeforeEndReturns() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(
            bundle: initialBundle,
            exitFailuresBeforeCommit: 1,
            suspendSuccessfulExitCommit: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        controller.launch(taskTitle: "Exit response loss")
        let launch = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()
        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "started",
            extra: #""pid":4343,"pgid":4343"#,
            to: launch.socketPath
        )
        await repository.waitUntilFirstStartedAttempt()

        // Queue the duplicate before the first failing handler can tear down
        // its run-scoped socket. A durable state machine must accept it as a
        // retry because the first report did not commit anything.
        let exitExtra = #""exitCode":7,"signal":15"#
        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "exited",
            extra: exitExtra,
            to: launch.socketPath
        )
        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "exited",
            extra: exitExtra,
            to: launch.socketPath
        )

        let didReachRetry = await repository.waitUntilExitAttemptCount(2)
        #expect(didReachRetry, "A failed, uncommitted exit report must remain retryable.")
        guard didReachRetry else { return }

        let endCompletion = TerminalControllerCompletionFlag()
        let endTask = Task { @MainActor in
            await controller.end(reason: .processExit)
            await endCompletion.markCompleted()
        }
        for _ in 0..<10 { await Task.yield() }

        #expect(
            await endCompletion.isCompleted() == false,
            "end() cannot return while the durable exit retry is still uncommitted."
        )

        await repository.releaseSuccessfulExitCommit()
        await endTask.value
        let report = await repository.waitForExitReport()
        let attempts = await repository.exitAttemptPayloads()

        #expect(attempts.count >= 2)
        #expect(attempts.allSatisfy { $0 == attempts[0] })
        #expect(attempts[0].runID == launch.runID)
        #expect(attempts[0].exitCode == 7)
        #expect(attempts[0].reason == .processExit)
        #expect(attempts[0].errorCode == nil)
        #expect(attempts[0].errorMessage == nil)
        #expect(report.runID == launch.runID)
        #expect(report.exitCode == 7)
        #expect(report.reason == .processExit)
        #expect(controller.activeRun?.state == .exited)
        #expect(controller.activeRun?.exitCode == 7)
        #expect(await endCompletion.isCompleted())
    }

    @Test("shutdown rejects a terminal bundle returned by an in-flight load")
    func shutdownRejectsDelayedLoadAndFurtherLaunchEntryPoints() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let bundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(
            bundle: bundle,
            suspendTerminalLookup: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let delayedLoad = Task { @MainActor in
            try await registry.load(taskID: taskID)
        }
        await repository.waitUntilTerminalLookupStarts()
        registry.beginShutdown()
        await repository.releaseTerminalLookup()

        let loadedController = try await delayedLoad.value
        #expect(loadedController == nil)
        #expect(registry.controller(for: taskID) == nil)

        // These explicit entry points must also stay inert once shutdown starts,
        // even if a caller retained a controller independently of the registry.
        let retainedController = TerminalSessionController(
            bundle: bundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        await registry.resumeOrLaunch(retainedController, taskTitle: "Too late")
        await registry.bindAndResume(
            TerminalResumeCandidate(
                providerSessionID: "provider-too-late",
                source: "manual",
                createdAt: nil
            ),
            controller: retainedController,
            taskTitle: "Too late"
        )

        let prepareCount = await repository.prepareCallCount()
        let bindCount = await repository.bindCallCount()
        #expect(surfaceFactory.makeSurfaceCount == 0)
        #expect(prepareCount == 0)
        #expect(bindCount == 0)
    }

    @Test(
        "engine restart tears down live terminals, applies interruption, and requires explicit resume",
        .timeLimit(.minutes(1))
    )
    func engineRestartReconcilesLiveControllerBeforeExplicitResume() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: initialBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let controller = try #require(registry.restore(initialBundle))

        await registry.resumeOrLaunch(controller, taskTitle: "Before restart")
        let firstLaunch = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()
        let firstSurface = try #require(surfaceFactory.latestSurface)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase.isActive)

        let interruptedBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                hasActiveRun: false
            ),
            activeRun: terminalRun(
                id: firstLaunch.runID,
                sessionID: sessionID,
                state: .interrupted,
                exitReason: .appShutdown
            )
        )
        await repository.replaceBundle(interruptedBundle)

        let reconciliation = Task { @MainActor in
            await registry.reconcileEngineRestart()
        }
        await firstSurface.waitUntilTerminated()
        #expect(registry.isRecoveringEngine)

        // A controller retained outside the registry must not be able to race
        // a fresh prepare request into the Engine generation being reconciled.
        let retainedController = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        await registry.resumeOrLaunch(retainedController, taskTitle: "During restart")
        for _ in 0..<20 { await Task.yield() }
        #expect(await repository.prepareCallCount() == 1)
        #expect(retainedController.phase.isActive == false)

        await reconciliation.value

        #expect(registry.isRecoveringEngine == false)
        #expect(controller.hasLiveSurface == false)
        #expect(controller.phase.isActive == false)
        #expect(controller.activeRun?.id == firstLaunch.runID)
        #expect(controller.activeRun?.state == .interrupted)
        #expect(firstSurface.terminateCount == 1)
        #expect(firstSurface.closeCount == 1)
        #expect(await repository.terminalLookupCount() == 1)

        // Restart recovery only reconciles state. A new PTY starts after an
        // explicit user/product entry point calls resumeOrLaunch again.
        await registry.resumeOrLaunch(controller, taskTitle: "After restart")
        let didPrepareResume = await repository.waitUntilPrepareCallCount(2)
        let didCreateResumeSurface = await surfaceFactory.waitUntilSurfaceCount(2)
        #expect(didPrepareResume)
        #expect(didCreateResumeSurface)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase.isActive)

        let resumedLaunch = await repository.latestPreparedLaunch()
        #expect(resumedLaunch?.runID != firstLaunch.runID)
        let resumedSurface = try #require(surfaceFactory.latestSurface)
        resumedSurface.emitProcessExit()
    }

    @Test("an inactive session can rebind its missing workspace and preserve the provider")
    func inactiveSessionRebindsWorkspaceBeforeResume() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let providerID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: "/missing/original",
            providerSessionID: providerID
        )
        let repository = TerminalControllerTestRepository(bundle: initialBundle)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: TerminalControllerTestSurfaceFactory()
        )

        try await controller.rebindWorkspace("/tmp/rebound-project")

        #expect(controller.session.workingDirectory == "/tmp/rebound-project")
        #expect(controller.workingDirectory == "/tmp/rebound-project")
        #expect(controller.session.providerSessionID == providerID)
        #expect(await repository.reboundWorkspaces() == ["/tmp/rebound-project"])
    }

    @Test("controller exposes a stored symlink workspace as unavailable")
    func controllerRejectsSymlinkWorkspaceBeforeResume() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("todoagent-controller-symlink-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let bundle = terminalBundle(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: link.path
        )
        let controller = TerminalSessionController(
            bundle: bundle,
            repository: TerminalControllerTestRepository(bundle: bundle),
            surfaceFactory: TerminalControllerTestSurfaceFactory()
        )

        #expect(controller.workingDirectoryIsAvailable == false)
    }

    @Test("older task snapshots cannot roll back a rebound workspace")
    func staleDescriptorCannotOverwriteReboundWorkspace() {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initial = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                workingDirectory: "/replacement/project",
                updatedAt: "2026-08-13T01:00:01Z"
            ),
            activeRun: nil
        )
        let controller = TerminalSessionController(
            bundle: initial,
            repository: TerminalControllerTestRepository(bundle: initial),
            surfaceFactory: TerminalControllerTestSurfaceFactory()
        )

        controller.applyAuthoritativeSessionDescriptor(testTerminalSession(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: "/missing/original",
            updatedAt: "2026-08-13T01:00:00Z"
        ))

        #expect(controller.session.workingDirectory == "/replacement/project")
    }

}

@MainActor
private final class TerminalControllerTestSurfaceFactory: TerminalSurfaceFactory {
    private let createsSurface: Bool
    private(set) var makeSurfaceCount = 0
    private(set) var surfaces: [TerminalControllerTestSurface] = []
    private var surfaceWaiters: [CheckedContinuation<Void, Never>] = []

    init(createsSurface: Bool = false) {
        self.createsSurface = createsSurface
    }

    func makeSurface(configuration _: TerminalLaunchPlan) throws -> any TerminalSurfaceSession {
        makeSurfaceCount += 1
        let waiters = surfaceWaiters
        surfaceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if createsSurface {
            let surface = TerminalControllerTestSurface()
            surfaces.append(surface)
            return surface
        }
        throw TerminalControllerTestError.unexpectedSurfaceCreation
    }

    var latestSurface: TerminalControllerTestSurface? { surfaces.last }

    func waitUntilSurfaceCreated() async {
        guard makeSurfaceCount == 0 else { return }
        await withCheckedContinuation { continuation in
            surfaceWaiters.append(continuation)
        }
    }

    func waitUntilSurfaceCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if makeSurfaceCount >= expectedCount { return true }
            await Task.yield()
        }
        return makeSurfaceCount >= expectedCount
    }
}

@MainActor
private final class TerminalControllerTestSurface: TerminalSurfaceSession {
    let view = NSView()
    var onEvent: (@MainActor (TerminalSurfaceEvent) -> Void)?
    private(set) var terminateCount = 0
    private(set) var closeCount = 0
    private var terminateWaiters: [CheckedContinuation<Void, Never>] = []

    func focus() {}
    func commitComposition() {}
    func performAction(_: String) {}
    func terminate() {
        terminateCount += 1
        let waiters = terminateWaiters
        terminateWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func close() {
        closeCount += 1
    }

    func waitUntilTerminated() async {
        guard terminateCount == 0 else { return }
        await withCheckedContinuation { continuation in
            terminateWaiters.append(continuation)
        }
    }

    func emitProcessExit() {
        onEvent?(.processExited(exitCode: 0, reason: .processExit))
    }
}

private enum TerminalControllerTestError: LocalizedError {
    case prepareResponseLost
    case startedResponseLost
    case exitResponseLostBeforeCommit
    case unexpectedSurfaceCreation

    var errorDescription: String? {
        switch self {
        case .prepareResponseLost:
            "The Engine committed the run, but its response was lost."
        case .startedResponseLost:
            "The Engine committed startedAt, but its response was lost."
        case .exitResponseLostBeforeCommit:
            "The Engine lost the exit response before committing it."
        case .unexpectedSurfaceCreation:
            "The test did not expect a terminal surface to be created."
        }
    }
}

private struct TerminalControllerExitReport: Equatable, Sendable {
    let sessionID: String
    let runID: String
    let exitCode: Int32?
    let reason: TerminalRunExitReason
    let errorCode: String?
    let errorMessage: String
    let startedWasRecoveredBeforeExit: Bool
    let startedAt: String?
}

private struct TerminalControllerPreparedLaunch: Equatable, Sendable {
    let runID: String
    let socketPath: String
    let lifecycleToken: String
    let hookToken: String
}

private struct TerminalControllerExitPayload: Equatable, Sendable {
    let sessionID: String
    let runID: String
    let exitCode: Int32?
    let reason: TerminalRunExitReason
    let errorCode: String?
    let errorMessage: String?
}

private actor TerminalControllerCompletionFlag {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor TerminalControllerTestRepository: AppRepository {
    private var bundle: TerminalSessionBundle
    private let prepareResponseIsLost: Bool
    private let startedResponseIsLost: Bool
    private var exitFailuresBeforeCommit: Int
    private var suspendsSuccessfulExitCommit: Bool
    private var suspendsTerminalLookup: Bool
    private var terminalLookups = 0
    private var prepareCalls = 0
    private var bindCalls = 0
    private var workspaceRebinds: [String] = []
    private var preparedLaunch: TerminalControllerPreparedLaunch?
    private var preparedLaunchWaiters: [CheckedContinuation<TerminalControllerPreparedLaunch, Never>] = []
    private var startedRunIDs: [String] = []
    private var didLoseStartedResponse = false
    private var recoveredStartedRunIDs: [String] = []
    private var firstStartedAttemptWaiters: [CheckedContinuation<Void, Never>] = []
    private var lookupStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var lookupReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitReports: [TerminalControllerExitReport] = []
    private var exitReportWaiters: [CheckedContinuation<TerminalControllerExitReport, Never>] = []
    private var exitAttempts: [TerminalControllerExitPayload] = []
    private var successfulExitCommitWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        bundle: TerminalSessionBundle,
        prepareResponseIsLost: Bool = false,
        startedResponseIsLost: Bool = false,
        exitFailuresBeforeCommit: Int = 0,
        suspendSuccessfulExitCommit: Bool = false,
        suspendTerminalLookup: Bool = false
    ) {
        self.bundle = bundle
        self.prepareResponseIsLost = prepareResponseIsLost
        self.startedResponseIsLost = startedResponseIsLost
        self.exitFailuresBeforeCommit = exitFailuresBeforeCommit
        suspendsSuccessfulExitCommit = suspendSuccessfulExitCommit
        suspendsTerminalLookup = suspendTerminalLookup
    }

    func terminalSession(taskID: UUID) async throws -> TerminalSessionBundle? {
        guard taskID == bundle.session.taskID else { return nil }
        terminalLookups += 1
        let waiters = lookupStartWaiters
        lookupStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendsTerminalLookup {
            await withCheckedContinuation { continuation in
                lookupReleaseWaiters.append(continuation)
            }
        }
        if didLoseStartedResponse,
           let activeRun = bundle.activeRun,
           activeRun.startedAt != nil,
           !recoveredStartedRunIDs.contains(activeRun.id) {
            recoveredStartedRunIDs.append(activeRun.id)
        }
        return bundle
    }

    func prepareTerminalLaunch(
        sessionID: String,
        runID: String,
        taskTitle _: String?,
        statusSocket: String,
        lifecycleToken: String,
        hookToken: String,
        providerHooksEnabled _: Bool,
        hostPID _: Int32
    ) async throws -> TerminalLaunchPlan {
        prepareCalls += 1
        let launch = TerminalControllerPreparedLaunch(
            runID: runID,
            socketPath: statusSocket,
            lifecycleToken: lifecycleToken,
            hookToken: hookToken
        )
        preparedLaunch = launch
        let launchWaiters = preparedLaunchWaiters
        preparedLaunchWaiters.removeAll()
        for waiter in launchWaiters { waiter.resume(returning: launch) }
        let startingRun = terminalRun(
            id: runID,
            sessionID: sessionID,
            state: .starting
        )
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: bundle.session.taskID,
                sessionID: sessionID,
                hasActiveRun: true
            ),
            activeRun: startingRun
        )
        if prepareResponseIsLost {
            throw TerminalControllerTestError.prepareResponseLost
        }
        return TerminalLaunchPlan(
            session: bundle.session,
            run: startingRun,
            executable: "/usr/bin/false",
            arguments: [],
            workingDirectory: bundle.session.workingDirectory,
            environment: [:],
            captureStrategy: .preallocated
        )
    }

    func rebindTerminalWorkspace(
        sessionID: String,
        workspace: String
    ) async throws -> TerminalSessionBundle {
        #expect(sessionID == bundle.session.id)
        workspaceRebinds.append(workspace)
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: bundle.session.taskID,
                sessionID: bundle.session.id,
                workingDirectory: workspace,
                providerSessionID: bundle.session.providerSessionID ?? "provider-session",
                hasActiveRun: false
            ),
            activeRun: bundle.activeRun
        )
        return bundle
    }

    func markTerminalRunStarted(
        sessionID: String,
        runID: String
    ) async throws -> TerminalSessionBundle {
        startedRunIDs.append(runID)
        let runningRun = terminalRun(
            id: runID,
            sessionID: sessionID,
            state: .running,
            startedAt: terminalControllerStartedAt
        )
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: bundle.session.taskID,
                sessionID: sessionID,
                hasActiveRun: true
            ),
            activeRun: runningRun
        )
        let attemptWaiters = firstStartedAttemptWaiters
        firstStartedAttemptWaiters.removeAll()
        for waiter in attemptWaiters { waiter.resume() }

        if startedResponseIsLost, !didLoseStartedResponse {
            didLoseStartedResponse = true
            throw TerminalControllerTestError.startedResponseLost
        }
        if didLoseStartedResponse, !recoveredStartedRunIDs.contains(runID) {
            recoveredStartedRunIDs.append(runID)
        }
        return bundle
    }

    func bindTerminalProvider(
        sessionID _: String,
        runID _: String,
        providerSessionID _: String,
        source _: String
    ) async throws -> TerminalSessionBundle {
        bindCalls += 1
        return bundle
    }

    func reportTerminalRunExited(
        sessionID: String,
        runID: String,
        exitCode: Int32?,
        reason: TerminalRunExitReason,
        errorCode: String?,
        errorMessage: String?
    ) async throws -> TerminalSessionBundle {
        let payload = TerminalControllerExitPayload(
            sessionID: sessionID,
            runID: runID,
            exitCode: exitCode,
            reason: reason,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
        exitAttempts.append(payload)
        if exitFailuresBeforeCommit > 0 {
            exitFailuresBeforeCommit -= 1
            throw TerminalControllerTestError.exitResponseLostBeforeCommit
        }
        if suspendsSuccessfulExitCommit {
            await withCheckedContinuation { continuation in
                successfulExitCommitWaiters.append(continuation)
            }
        }
        let report = TerminalControllerExitReport(
            sessionID: sessionID,
            runID: runID,
            exitCode: exitCode,
            reason: reason,
            errorCode: errorCode,
            errorMessage: errorMessage ?? "",
            startedWasRecoveredBeforeExit: recoveredStartedRunIDs.contains(runID),
            startedAt: bundle.activeRun?.startedAt
        )
        exitReports.append(report)
        let waiters = exitReportWaiters
        exitReportWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: report) }

        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: bundle.session.taskID,
                sessionID: sessionID,
                hasActiveRun: false,
                lastErrorCode: errorCode,
                lastErrorMessage: errorMessage
            ),
            activeRun: terminalRun(
                id: runID,
                sessionID: sessionID,
                state: reason == .launchFailed ? .failed : .exited,
                exitCode: exitCode,
                exitReason: reason,
                errorCode: errorCode,
                errorMessage: errorMessage,
                startedAt: bundle.activeRun?.startedAt
            )
        )
        return bundle
    }

    func waitUntilTerminalLookupStarts() async {
        guard terminalLookups == 0 else { return }
        await withCheckedContinuation { continuation in
            lookupStartWaiters.append(continuation)
        }
    }

    func waitForPreparedLaunch() async -> TerminalControllerPreparedLaunch {
        if let preparedLaunch { return preparedLaunch }
        return await withCheckedContinuation { continuation in
            preparedLaunchWaiters.append(continuation)
        }
    }

    func waitUntilFirstStartedAttempt() async {
        guard startedRunIDs.isEmpty else { return }
        await withCheckedContinuation { continuation in
            firstStartedAttemptWaiters.append(continuation)
        }
    }

    func releaseTerminalLookup() {
        suspendsTerminalLookup = false
        let waiters = lookupReleaseWaiters
        lookupReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForExitReport() async -> TerminalControllerExitReport {
        if let report = exitReports.first { return report }
        return await withCheckedContinuation { continuation in
            exitReportWaiters.append(continuation)
        }
    }

    func waitUntilExitAttemptCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<100 {
            if exitAttempts.count >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return exitAttempts.count >= expectedCount
    }

    func releaseSuccessfulExitCommit() {
        suspendsSuccessfulExitCommit = false
        let waiters = successfulExitCommitWaiters
        successfulExitCommitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func terminalLookupCount() -> Int { terminalLookups }
    func prepareCallCount() -> Int { prepareCalls }
    func bindCallCount() -> Int { bindCalls }
    func reboundWorkspaces() -> [String] { workspaceRebinds }
    func markStartedRunIDs() -> [String] { startedRunIDs }
    func recoveredStartedIDs() -> [String] { recoveredStartedRunIDs }
    func exitAttemptPayloads() -> [TerminalControllerExitPayload] { exitAttempts }

    func replaceBundle(_ incoming: TerminalSessionBundle) {
        bundle = incoming
    }

    func latestPreparedLaunch() -> TerminalControllerPreparedLaunch? { preparedLaunch }

    func waitUntilPrepareCallCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<100 {
            if prepareCalls >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return prepareCalls >= expectedCount
    }

    private let emptySnapshot = AppSnapshot(
        revision: 0,
        lists: [],
        tasks: [],
        runtimes: [],
        sessions: [],
        messages: []
    )

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

private func terminalBundle(
    taskID: UUID,
    sessionID: String,
    workingDirectory: String = "/tmp/todoagent-terminal-controller-tests",
    providerSessionID: String = "provider-session"
) -> TerminalSessionBundle {
    TerminalSessionBundle(
        session: testTerminalSession(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            providerSessionID: providerSessionID
        ),
        activeRun: nil
    )
}

private func testTerminalSession(
    taskID: UUID,
    sessionID: String,
    workingDirectory: String = "/tmp/todoagent-terminal-controller-tests",
    providerSessionID: String = "provider-session",
    hasActiveRun: Bool = false,
    lastErrorCode: String? = nil,
    lastErrorMessage: String? = nil,
    updatedAt: String = "2026-08-12T00:00:00Z"
) -> TerminalSessionDescriptor {
    TerminalSessionDescriptor(
        id: sessionID,
        taskID: taskID,
        runtimeKind: .claude,
        workingDirectory: workingDirectory,
        providerSessionID: providerSessionID,
        providerBindingState: .bound,
        providerBindingSource: "test",
        agentStatus: hasActiveRun ? .active : .idle,
        hasActiveRun: hasActiveRun,
        lastErrorCode: lastErrorCode,
        lastErrorMessage: lastErrorMessage,
        createdAt: "2026-08-12T00:00:00Z",
        updatedAt: updatedAt
    )
}

private func terminalRun(
    id: String,
    sessionID: String,
    state: TerminalRunState,
    exitCode: Int32? = nil,
    exitReason: TerminalRunExitReason? = nil,
    errorCode: String? = nil,
    errorMessage: String? = nil,
    startedAt: String? = nil
) -> TerminalRun {
    TerminalRun(
        id: id,
        sessionID: sessionID,
        ordinal: 1,
        launchMode: .fresh,
        state: state,
        providerSessionIDAtLaunch: "provider-session",
        exitCode: exitCode,
        exitReason: exitReason,
        errorCode: errorCode,
        errorMessage: errorMessage,
        startedAt: startedAt,
        exitedAt: state.isActive ? nil : "2026-08-12T00:00:01Z",
        createdAt: "2026-08-12T00:00:00Z"
    )
}

private let terminalControllerStartedAt = "2026-08-12T00:00:00.500Z"

private func sendTerminalStatusMessage(
    token: String,
    sessionID: String,
    runID: String,
    event: String,
    extra: String,
    to path: String
) throws {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { throw TerminalControllerSocketError.systemCall(errno) }
    defer { Darwin.close(descriptor) }

    var address = sockaddr_un()
    let pathBytes = path.utf8CString
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else { throw TerminalControllerSocketError.pathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            pathBytes.withUnsafeBufferPointer { source in
                guard let sourceAddress = source.baseAddress else { return }
                destination.initialize(from: sourceAddress, count: source.count)
            }
        }
    }
    let message = #"{"token":"\#(token)","sessionId":"\#(sessionID)","runId":"\#(runID)","event":"\#(event)",\#(extra)}"#
    let payload = Data(message.utf8)
    let sent = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            payload.withUnsafeBytes { bytes in
                Darwin.sendto(
                    descriptor,
                    bytes.baseAddress,
                    bytes.count,
                    0,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
    }
    guard sent == payload.count else { throw TerminalControllerSocketError.systemCall(errno) }
}

private enum TerminalControllerSocketError: Error {
    case systemCall(Int32)
    case pathTooLong
}
