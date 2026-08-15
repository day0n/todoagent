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
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
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
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
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
        #expect(surfaceFactory.makeHostSurfaceCount == 0)
        #expect(prepareCount == 0)
        #expect(bindCount == 0)
    }

    @Test(
        "a delayed task lookup cannot roll back a newer in-memory launch",
        .timeLimit(.minutes(1))
    )
    func delayedLookupDoesNotOverwriteLaunchingController() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let previousRunID = UUID().uuidString.lowercased()
        let providerSessionID = UUID().uuidString.lowercased()
        let staleBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: providerSessionID,
                lastStartedAt: terminalControllerStartedAt,
                lastExitedAt: "2026-08-14T00:00:01Z",
                lastExitReason: TerminalRunExitReason.appShutdown.rawValue,
                autoResume: true
            ),
            activeRun: terminalRun(
                id: previousRunID,
                sessionID: sessionID,
                state: .interrupted,
                providerSessionIDAtLaunch: providerSessionID,
                exitReason: .appShutdown,
                startedAt: terminalControllerStartedAt
            )
        )
        let repository = TerminalControllerTestRepository(
            bundle: staleBundle,
            suspendTerminalLookup: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let task = testTask(id: taskID, title: "Overlapping open")

        let delayedOpen = Task { @MainActor in
            try await registry.openTask(task)
        }
        await repository.waitUntilTerminalLookupStarts()

        let controller = try #require(registry.restore(staleBundle))
        await registry.resumeIfNeeded(taskID: taskID, taskTitle: task.title)
        let launch = await repository.waitForPreparedLaunch()
        for _ in 0..<100 {
            if controller.activeRun?.id == launch.runID, controller.phase == .launching { break }
            await Task.yield()
        }
        let phaseAfterLaunch = controller.phase
        let activeRunIDAfterLaunch = controller.activeRun?.id

        await repository.releaseTerminalLookup()
        let opened = try await delayedOpen.value

        #expect(opened === controller)
        #expect(registry.controller(for: taskID) === controller)
        #expect(controller.phase == phaseAfterLaunch)
        #expect(controller.phase == .launching)
        #expect(controller.activeRun?.id == activeRunIDAfterLaunch)
        #expect(controller.activeRun?.id == launch.runID)
        #expect(await repository.prepareCallCount() == 1)
    }

    @Test(
        "a missing delayed lookup returns the Controller installed while it was suspended",
        .timeLimit(.minutes(1))
    )
    func missingLookupReturnsNewerController() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let bundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(
            bundle: bundle,
            suspendTerminalLookup: true
        )
        await repository.removeStoredSession()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: TerminalControllerTestSurfaceFactory()
        )
        let delayedLoad = Task { @MainActor in
            try await registry.load(taskID: taskID)
        }

        await repository.waitUntilTerminalLookupStarts()
        let controller = try #require(registry.restore(bundle))
        await repository.releaseTerminalLookup()
        let loaded = try await delayedLoad.value

        #expect(loaded === controller)
        #expect(registry.controller(for: taskID) === controller)
        #expect(await repository.prepareCallCount() == 0)
    }

    @Test(
        "a canceled task lookup cannot restore or auto-resume its stale result",
        .timeLimit(.minutes(1))
    )
    func canceledLookupDoesNotRestoreOrLaunch() async {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let staleBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: UUID().uuidString.lowercased(),
                lastStartedAt: terminalControllerStartedAt,
                lastExitedAt: "2026-08-14T00:00:01Z",
                lastExitReason: TerminalRunExitReason.appShutdown.rawValue,
                autoResume: true
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(
            bundle: staleBundle,
            suspendTerminalLookup: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let delayedOpen = Task { @MainActor in
            try await registry.openTask(testTask(id: taskID, title: "Canceled open"))
        }

        await repository.waitUntilTerminalLookupStarts()
        delayedOpen.cancel()
        await repository.releaseTerminalLookup()
        do {
            _ = try await delayedOpen.value
            Issue.record("The canceled open unexpectedly returned a Controller.")
        } catch is CancellationError {
            // Expected: cancellation wins before the stale lookup can mutate the Registry.
        } catch {
            Issue.record("The canceled open failed with an unexpected error: \(error)")
        }

        #expect(registry.controller(for: taskID) == nil)
        #expect(await repository.prepareCallCount() == 0)
        #expect(surfaceFactory.makeHostSurfaceCount == 0)
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

        await registry.launchAgent(controller, taskTitle: "Before restart", intent: .fresh)
        let firstLaunch = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()
        let firstSurface = try #require(surfaceFactory.latestSurface)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase.isActive)

        let interruptedBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                hasActiveRun: false,
                autoResume: true
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

    @Test("an idle live host can rebind its workspace")
    func idleLiveHostRebindsWorkspace() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appendingPathComponent("todoagent-rebind-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }

        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: initialBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        try controller.ensureHostSurface()
        #expect(controller.hasLiveSurface)
        try await controller.rebindWorkspace(replacement.path)
        #expect(controller.session.workingDirectory == replacement.path)
        #expect(controller.hasLiveSurface == false)
        #expect(await repository.reboundWorkspaces() == [replacement.path])
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

    @Test("official launch cds into the bound workspace before injecting the runner")
    func officialLaunchChangesDirectoryBeforeRunner() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: initialBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        controller.launch(taskTitle: "Enter workspace")
        _ = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()
        let surface = try #require(surfaceFactory.latestSurface)
        for _ in 0..<100 {
            if !surface.sentTexts.isEmpty { break }
            await Task.yield()
        }
        #expect(surface.sentTexts == [
            "cd -- '\(terminalControllerTestWorkspace)' && '/tmp/todoagent-terminal-runner' '--descriptor' '/tmp/todoagent-descriptor.json'"
        ])
    }

    @Test("agent process exit leaves the host shell idle")
    func agentProcessExitLeavesHostShellIdle() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let initialBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: initialBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: initialBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        controller.launch(taskTitle: "Leave host")
        let launch = await repository.waitForPreparedLaunch()
        await surfaceFactory.waitUntilSurfaceCreated()
        try sendTerminalStatusMessage(
            token: launch.lifecycleToken,
            sessionID: sessionID,
            runID: launch.runID,
            event: "started",
            extra: #""pid":4545,"pgid":4545"#,
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
        for _ in 0..<100 {
            if controller.phase == .shellIdle { break }
            await Task.yield()
        }
        let surface = try #require(surfaceFactory.latestSurface)
        #expect(report.reason == .processExit)
        #expect(controller.phase == .shellIdle)
        #expect(controller.hasLiveSurface)
        #expect(controller.isActive == false)
        #expect(surface.terminateCount == 0)
        #expect(surface.closeCount == 0)
        #expect(await repository.deletedSessionIDs().isEmpty)
    }

    @Test("opening a task terminal resumes its durable app-shutdown session")
    func openingTaskLaunchesDurableAutoResumeSession() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let providerID = UUID().uuidString.lowercased()
        let autoResumeBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: providerID,
                lastStartedAt: terminalControllerStartedAt,
                autoResume: true
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(
            bundle: autoResumeBundle,
            suspendTerminalPrepare: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let controller = try await registry.openTask(testTask(id: taskID))
        let didPrepareResume = await repository.waitUntilPrepareCallCount(1)
        let surface = try #require(surfaceFactory.latestSurface)
        #expect(
            didPrepareResume,
            "phase: \(controller.phase), autoResume: \(controller.session.autoResume)"
        )
        guard didPrepareResume else { return }
        #expect(controller.phase == .preparing)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: controller.hasLiveSurface,
            phase: controller.phase
        ) == .launching)
        #expect(surface.sentTexts.isEmpty)

        await repository.releaseTerminalPrepare()
        let launch = await repository.waitForPreparedLaunch()
        for _ in 0..<1_000 {
            if surface.sentTexts.count == 1 { break }
            await Task.yield()
        }

        #expect(controller.hasLiveSurface)
        #expect(controller.phase.isActive)
        #expect(controller.isActive)
        #expect(launch.intent == .resume)
        #expect(launch.launchMode == .resume)
        #expect(launch.providerSessionIDAtLaunch == providerID)
        #expect(await repository.prepareCallCount() == 1)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
        #expect(surface.sentTexts.count == 1)
    }

    @Test(
        "Cmd-Q then a new app process resumes the same Claude provider session exactly once",
        .timeLimit(.minutes(1))
    )
    func appRelaunchRestoresSameClaudeProviderSessionExactlyOnce() async throws {
        let taskID = UUID()
        let seedBundle = terminalBundle(
            taskID: UUID(),
            sessionID: UUID().uuidString.lowercased()
        )
        let repository = TerminalControllerTestRepository(bundle: seedBundle)
        let firstSurfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let firstRegistry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: firstSurfaceFactory
        )
        let task = testTask(id: taskID, title: "Before Cmd-Q")
        let firstController = try await firstRegistry.create(
            task: task,
            runtime: .claude,
            workspace: terminalControllerTestWorkspace
        )
        #expect(
            await repository.waitUntilPrepareCallCount(1),
            "controller phase: \(firstController.phase)"
        )
        let firstLaunch = try #require(await repository.latestPreparedLaunch())
        let sessionID = firstController.session.id
        let providerID = try #require(firstLaunch.providerSessionIDAtLaunch)
        #expect(firstLaunch.intent == .fresh)
        #expect(firstLaunch.launchMode == .fresh)
        #expect(await firstSurfaceFactory.waitUntilSurfaceCount(1))
        try sendTerminalStatusMessage(
            token: firstLaunch.lifecycleToken,
            sessionID: sessionID,
            runID: firstLaunch.runID,
            event: "started",
            extra: #""pid":4646,"pgid":4646"#,
            to: firstLaunch.socketPath
        )
        await repository.waitUntilFirstStartedAttempt()

        let shutdown = Task { @MainActor in
            await firstRegistry.endAll(reason: .appShutdown)
        }
        let firstSurface = try #require(firstSurfaceFactory.latestSurface)
        #expect(await firstSurface.waitUntilTerminateCount(1))
        try sendTerminalStatusMessage(
            token: firstLaunch.lifecycleToken,
            sessionID: sessionID,
            runID: firstLaunch.runID,
            event: "exited",
            extra: #""exitCode":143,"signal":15"#,
            to: firstLaunch.socketPath
        )
        let exitReport = await repository.waitForExitReport()
        #expect(exitReport.reason == .appShutdown)
        await shutdown.value

        let persistedAfterQuit = await repository.currentBundle()
        #expect(persistedAfterQuit.session.id == sessionID)
        #expect(persistedAfterQuit.session.providerSessionID == providerID)
        #expect(persistedAfterQuit.session.autoResume)
        #expect(persistedAfterQuit.activeRun?.exitReason == .appShutdown)

        let secondSurfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let secondRegistry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: secondSurfaceFactory
        )
        let reopenedTask = testTask(id: taskID, title: "After relaunch")
        let secondController = try await secondRegistry.openTask(reopenedTask)
        let didPrepareResume = await repository.waitUntilPrepareCallCount(2)
        #expect(didPrepareResume)
        let secondLaunch = try #require(await repository.latestPreparedLaunch())

        #expect(firstController !== secondController)
        #expect(secondController.taskID == taskID)
        #expect(secondController.session.id == sessionID)
        #expect(secondLaunch.runID != firstLaunch.runID)
        #expect(secondLaunch.intent == .resume)
        #expect(secondLaunch.launchMode == .resume)
        #expect(secondLaunch.providerSessionIDAtLaunch == providerID)

        _ = try await secondRegistry.openTask(reopenedTask)
        for _ in 0..<20 { await Task.yield() }
        #expect(await repository.prepareCallCount() == 2)
    }

    @Test("an explicit resume launches the exact bound provider session")
    func explicitResumeLaunchesBoundProviderSession() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let providerID = UUID().uuidString.lowercased()
        let resumableBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: providerID,
                lastStartedAt: terminalControllerStartedAt
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(bundle: resumableBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let controller = try #require(registry.restore(resumableBundle))

        await registry.resumeOrLaunch(controller, taskTitle: "Idle host")
        let launch = await repository.waitForPreparedLaunch()

        #expect(await repository.prepareCallCount() == 1)
        #expect(launch.intent == .resume)
        #expect(launch.launchMode == .resume)
        #expect(launch.providerSessionIDAtLaunch == providerID)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase.isActive)
        #expect(controller.isActive)
    }

    @Test("a manually selected provider candidate is resumed instead of replaced")
    func selectedResumeCandidateUsesExplicitResumeIntent() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let previousRunID = UUID().uuidString.lowercased()
        let candidateID = UUID().uuidString.lowercased()
        let candidateBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                runtimeKind: .codex,
                providerSessionID: nil,
                lastStartedAt: terminalControllerStartedAt
            ),
            activeRun: terminalRun(
                id: previousRunID,
                sessionID: sessionID,
                state: .interrupted,
                providerSessionIDAtLaunch: nil,
                startedAt: terminalControllerStartedAt
            )
        )
        let repository = TerminalControllerTestRepository(bundle: candidateBundle)
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: TerminalControllerTestSurfaceFactory(createsSurface: true)
        )
        let controller = try #require(registry.restore(candidateBundle))

        await registry.bindAndResume(
            TerminalResumeCandidate(
                providerSessionID: candidateID,
                source: "manual",
                createdAt: nil
            ),
            controller: controller,
            taskTitle: "Selected candidate"
        )
        let launch = await repository.waitForPreparedLaunch()

        #expect(await repository.bindCallCount() == 1)
        #expect(launch.intent == .resume)
        #expect(launch.launchMode == .resume)
        #expect(launch.providerSessionIDAtLaunch == candidateID)
    }

    @Test("an official run can explicitly start fresh when its transcript cannot resume")
    func officialRunCanStartFreshAfterResumeFailure() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let staleProviderID = UUID().uuidString.lowercased()
        let staleBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: staleProviderID,
                lastStartedAt: terminalControllerStartedAt
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(bundle: staleBundle)
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: TerminalControllerTestSurfaceFactory(createsSurface: true)
        )
        let controller = try #require(registry.restore(staleBundle))

        await registry.launchAgent(
            controller,
            taskTitle: "Start over",
            intent: .fresh,
            runtimeKind: .claude
        )
        let launch = await repository.waitForPreparedLaunch()

        #expect(launch.intent == .fresh)
        #expect(launch.launchMode == .fresh)
        #expect(launch.providerSessionIDAtLaunch != staleProviderID)
    }

    @Test("a provider preallocated before any Agent start retries as fresh")
    func neverStartedProviderRetriesFreshInsteadOfInvalidResume() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let abandonedProviderID = UUID().uuidString.lowercased()
        let neverStartedBundle = terminalBundle(
            taskID: taskID,
            sessionID: sessionID,
            providerSessionID: abandonedProviderID
        )
        let repository = TerminalControllerTestRepository(bundle: neverStartedBundle)
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: TerminalControllerTestSurfaceFactory(createsSurface: true)
        )
        let controller = try #require(registry.restore(neverStartedBundle))

        await registry.resumeOrLaunch(controller, taskTitle: "Retry fresh")
        let launch = await repository.waitForPreparedLaunch()

        #expect(launch.intent == .fresh)
        #expect(launch.launchMode == .fresh)
        #expect(launch.providerSessionIDAtLaunch != abandonedProviderID)
    }

    @Test("opening an idle task restores its terminal without launching an agent")
    func openTaskRestoresExistingHostWithoutLaunch() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let idleBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: idleBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let controller = try await registry.openTask(testTask(id: taskID))
        let reopened = try await registry.openTask(testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(reopened === controller)
        #expect(controller.taskID == taskID)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase == .shellIdle)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
        #expect(await repository.prepareCallCount() == 0)
        #expect(await repository.createTerminalSessionCount() == 0)
    }

    @Test("ensureHost does not launch even when auto-resume is set")
    func ensureHostDoesNotLaunchAutoResumeSession() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let autoResumeBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                autoResume: true
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(bundle: autoResumeBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let controller = try await registry.ensureHost(task: testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.hasLiveSurface)
        #expect(controller.phase == .shellIdle)
        #expect(controller.isActive == false)
        #expect(await repository.prepareCallCount() == 0)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
    }

    @Test("an auto-resume marker without an exact provider keeps the host shell idle")
    func openTaskRejectsAutoResumeWithoutProviderIdentity() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let malformedBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: nil,
                autoResume: true
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(bundle: malformedBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let controller = try await registry.openTask(testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.session.providerSessionID == nil)
        #expect(controller.phase == .shellIdle)
        #expect(controller.hasLiveSurface)
        #expect(await repository.prepareCallCount() == 0)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
    }

    @Test("opening a new task creates its home-directory terminal without launching an agent")
    func openTaskCreatesHomeSessionWithoutLaunch() async throws {
        let existingTaskID = UUID()
        let taskID = UUID()
        let repository = TerminalControllerTestRepository(
            bundle: terminalBundle(
                taskID: existingTaskID,
                sessionID: UUID().uuidString.lowercased()
            )
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let controller = try await registry.openTask(testTask(id: taskID))
        let reopened = try await registry.openTask(testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(reopened === controller)
        #expect(controller.taskID == taskID)
        #expect(controller.session.workingDirectory == TerminalHostDefaults.workingDirectory)
        #expect(controller.hasLiveSurface)
        #expect(controller.phase == .shellIdle)
        #expect(await repository.prepareCallCount() == 0)
        #expect(await repository.createTerminalSessionCount() == 1)
        #expect(await repository.createdWorkspaces() == [TerminalHostDefaults.workingDirectory])
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
    }

    @Test("opening a terminal after an ordinary Agent exit keeps the shell idle")
    func openTaskDoesNotResumeOrdinaryExit() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let providerID = UUID().uuidString.lowercased()
        let exitedBundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                providerSessionID: providerID,
                lastStartedAt: terminalControllerStartedAt,
                lastExitedAt: "2026-08-15T00:00:01Z",
                lastExitReason: TerminalRunExitReason.processExit.rawValue,
                autoResume: false
            ),
            activeRun: nil
        )
        let repository = TerminalControllerTestRepository(bundle: exitedBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        let controller = try await registry.openTask(testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(controller.session.providerSessionID == providerID)
        #expect(controller.phase == .shellIdle)
        #expect(controller.hasLiveSurface)
        #expect(await repository.prepareCallCount() == 0)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
    }

    @Test("ensureHost opens a new host after the previous shell exits")
    func ensureHostRecreatesHostAfterExit() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let idleBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: idleBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let first = try await registry.ensureHost(task: testTask(id: taskID))
        let surface = try #require(surfaceFactory.latestSurface)
        surface.emitProcessExit()
        let didDelete = await repository.waitUntilDeletedSessionCount(1)
        #expect(didDelete)
        for _ in 0..<100 {
            if first.phase == .hostExited { break }
            await Task.yield()
        }
        #expect(first.phase == .hostExited)
        await repository.removeStoredSession()

        let second = try await registry.ensureHost(task: testTask(id: taskID))
        for _ in 0..<20 { await Task.yield() }

        #expect(second.phase == .shellIdle)
        #expect(second.hasLiveSurface)
        #expect(second.session.id != sessionID)
        #expect(await repository.prepareCallCount() == 0)
        #expect(await repository.createTerminalSessionCount() == 1)
        #expect(surfaceFactory.makeHostSurfaceCount == 2)
    }

    @Test("a deleted-session event does not drop a newer host for the same task")
    func deletedSessionEventDoesNotForgetReplacementHost() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let idleBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(
            bundle: idleBundle,
            suspendTerminalDelete: true
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let registry = TerminalSessionRegistry(
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        let first = try await registry.ensureHost(task: testTask(id: taskID))
        let surface = try #require(surfaceFactory.latestSurface)
        surface.emitProcessExit()
        let didDelete = await repository.waitUntilDeletedSessionCount(1)
        #expect(didDelete)

        // The Engine deletion event can remove the old registry entry before
        // the old Controller's async delete call returns. Recreate the host in
        // that window, then release the old callback.
        registry.forget(sessionID: sessionID, taskID: taskID)
        await repository.removeStoredSession()
        let second = try await registry.ensureHost(task: testTask(id: taskID))
        await repository.releaseTerminalDelete()
        for _ in 0..<100 {
            if first.phase == .hostExited { break }
            await Task.yield()
        }

        #expect(first.phase == .hostExited)
        #expect(registry.controller(for: taskID) === second)
        #expect(second.hasLiveSurface)
        #expect(await repository.prepareCallCount() == 0)
    }

    @Test("live host keeps the OSC 7 directory when a stored session snapshot arrives")
    func liveHostPreservesWorkingDirectoryAcrossSessionMerge() throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let bundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let controller = TerminalSessionController(
            bundle: bundle,
            repository: TerminalControllerTestRepository(bundle: bundle),
            surfaceFactory: TerminalControllerTestSurfaceFactory()
        )

        try controller.ensureHostSurface()
        controller.applyAuthoritativeSessionDescriptor(testTerminalSession(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: "/stored/home",
            updatedAt: "2026-08-14T01:00:01Z"
        ))

        #expect(controller.workingDirectory == TerminalHostDefaults.workingDirectory)
        #expect(controller.session.workingDirectory == "/stored/home")
    }

    @Test("host surface does not require the stored session workspace")
    func hostSurfaceIgnoresMissingStoredWorkspace() throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let bundle = terminalBundle(
            taskID: taskID,
            sessionID: sessionID,
            workingDirectory: "/missing/original"
        )
        let surfaceFactory = TerminalControllerTestSurfaceFactory()
        let controller = TerminalSessionController(
            bundle: bundle,
            repository: TerminalControllerTestRepository(bundle: bundle),
            surfaceFactory: surfaceFactory
        )

        try controller.ensureHostSurface()
        #expect(controller.hasLiveSurface)
        #expect(controller.phase == .shellIdle)
        #expect(controller.workingDirectory == TerminalHostDefaults.workingDirectory)
        #expect(surfaceFactory.makeHostSurfaceCount == 1)
    }

    @Test("host process exit deletes the idle terminal")
    func hostProcessExitDeletesIdleTerminal() async throws {
        let taskID = UUID()
        let sessionID = UUID().uuidString.lowercased()
        let idleBundle = terminalBundle(taskID: taskID, sessionID: sessionID)
        let repository = TerminalControllerTestRepository(bundle: idleBundle)
        let surfaceFactory = TerminalControllerTestSurfaceFactory(createsSurface: true)
        let controller = TerminalSessionController(
            bundle: idleBundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )

        try controller.ensureHostSurface()
        let surface = try #require(surfaceFactory.latestSurface)
        surface.emitProcessExit()

        let didDelete = await repository.waitUntilDeletedSessionCount(1)
        #expect(didDelete)
        #expect(controller.phase == .hostExited)
        #expect(controller.hasLiveSurface == false)
        #expect(await repository.deletedSessionIDs() == [sessionID])
    }

}

@MainActor
private final class TerminalControllerTestSurfaceFactory: TerminalSurfaceFactory {
    private let createsSurface: Bool
    private(set) var makeSurfaceCount = 0
    private(set) var makeHostSurfaceCount = 0
    private(set) var surfaces: [TerminalControllerTestSurface] = []
    private var surfaceWaiters: [CheckedContinuation<Void, Never>] = []

    init(createsSurface: Bool = false) {
        self.createsSurface = createsSurface
    }

    func makeSurface(configuration _: TerminalLaunchPlan) throws -> any TerminalSurfaceSession {
        makeSurfaceCount += 1
        return try makeCreatedSurface()
    }

    func makeHostSurface(
        workingDirectory _: String,
        environment _: [String: String]
    ) throws -> any TerminalSurfaceSession {
        makeHostSurfaceCount += 1
        let waiters = surfaceWaiters
        surfaceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        let surface = TerminalControllerTestSurface()
        surfaces.append(surface)
        return surface
    }

    private func makeCreatedSurface() throws -> any TerminalSurfaceSession {
        if createsSurface {
            let surface = TerminalControllerTestSurface()
            surfaces.append(surface)
            return surface
        }
        throw TerminalControllerTestError.unexpectedSurfaceCreation
    }

    var latestSurface: TerminalControllerTestSurface? { surfaces.last }

    func waitUntilSurfaceCreated() async {
        guard makeHostSurfaceCount == 0 else { return }
        await withCheckedContinuation { continuation in
            surfaceWaiters.append(continuation)
        }
    }

    func waitUntilSurfaceCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if makeHostSurfaceCount >= expectedCount { return true }
            await Task.yield()
        }
        return makeHostSurfaceCount >= expectedCount
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
    private(set) var sentTexts: [String] = []

    func sendText(_ text: String) {
        sentTexts.append(text)
    }
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

    func waitUntilTerminateCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<1_000 {
            if terminateCount >= expectedCount { return true }
            await Task.yield()
        }
        return terminateCount >= expectedCount
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
    let sessionID: String
    let runID: String
    let socketPath: String
    let lifecycleToken: String
    let hookToken: String
    let intent: TerminalLaunchIntent
    let launchMode: TerminalRunLaunchMode
    let providerSessionIDAtLaunch: String?
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
    private var suspendsTerminalDelete: Bool
    private var suspendsTerminalPrepare: Bool
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
    private var terminalPrepareReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var exitReports: [TerminalControllerExitReport] = []
    private var exitReportWaiters: [CheckedContinuation<TerminalControllerExitReport, Never>] = []
    private var exitAttempts: [TerminalControllerExitPayload] = []
    private var successfulExitCommitWaiters: [CheckedContinuation<Void, Never>] = []
    private var deletedIDs: [String] = []
    private var deletedSessionWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalDeleteReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var sessionMissing = false
    private var createdSessions: [(taskID: UUID, runtime: RuntimeKind, workspace: String)] = []

    init(
        bundle: TerminalSessionBundle,
        prepareResponseIsLost: Bool = false,
        startedResponseIsLost: Bool = false,
        exitFailuresBeforeCommit: Int = 0,
        suspendSuccessfulExitCommit: Bool = false,
        suspendTerminalLookup: Bool = false,
        suspendTerminalDelete: Bool = false,
        suspendTerminalPrepare: Bool = false
    ) {
        self.bundle = bundle
        self.prepareResponseIsLost = prepareResponseIsLost
        self.startedResponseIsLost = startedResponseIsLost
        self.exitFailuresBeforeCommit = exitFailuresBeforeCommit
        suspendsSuccessfulExitCommit = suspendSuccessfulExitCommit
        suspendsTerminalLookup = suspendTerminalLookup
        suspendsTerminalDelete = suspendTerminalDelete
        suspendsTerminalPrepare = suspendTerminalPrepare
    }

    func terminalSession(taskID: UUID) async throws -> TerminalSessionBundle? {
        let response: TerminalSessionBundle? = if !sessionMissing, taskID == bundle.session.taskID {
            bundle
        } else {
            nil
        }
        terminalLookups += 1
        let waiters = lookupStartWaiters
        lookupStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendsTerminalLookup {
            await withCheckedContinuation { continuation in
                lookupReleaseWaiters.append(continuation)
            }
        }
        if response != nil,
           didLoseStartedResponse,
           let activeRun = bundle.activeRun,
           activeRun.startedAt != nil,
           !recoveredStartedRunIDs.contains(activeRun.id) {
            recoveredStartedRunIDs.append(activeRun.id)
        }
        return response
    }

    func prepareTerminalLaunch(
        sessionID: String,
        runID: String,
        taskTitle _: String?,
        statusSocket: String,
        lifecycleToken: String,
        hookToken: String,
        providerHooksEnabled _: Bool,
        hostPID _: Int32,
        intent: TerminalLaunchIntent,
        runtimeKind: RuntimeKind?
    ) async throws -> TerminalLaunchPlan {
        prepareCalls += 1
        if suspendsTerminalPrepare {
            await withCheckedContinuation { continuation in
                terminalPrepareReleaseWaiters.append(continuation)
            }
        }
        let previousSession = bundle.session
        let launchRuntime = runtimeKind ?? previousSession.runtimeKind
        let launchMode: TerminalRunLaunchMode = switch intent {
        case .resume: .resume
        case .auto where previousSession.autoResume && previousSession.providerSessionID != nil: .resume
        case .auto, .fresh: .fresh
        }
        let providerSessionIDAtLaunch: String? = if launchMode == .fresh
            && launchRuntime == .claude {
            UUID().uuidString.lowercased()
        } else {
            previousSession.providerSessionID
        }
        let launch = TerminalControllerPreparedLaunch(
            sessionID: sessionID,
            runID: runID,
            socketPath: statusSocket,
            lifecycleToken: lifecycleToken,
            hookToken: hookToken,
            intent: intent,
            launchMode: launchMode,
            providerSessionIDAtLaunch: providerSessionIDAtLaunch
        )
        preparedLaunch = launch
        let launchWaiters = preparedLaunchWaiters
        preparedLaunchWaiters.removeAll()
        for waiter in launchWaiters { waiter.resume(returning: launch) }
        let startingRun = terminalRun(
            id: runID,
            sessionID: sessionID,
            state: .starting,
            launchMode: launchMode,
            providerSessionIDAtLaunch: providerSessionIDAtLaunch
        )
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: previousSession.taskID,
                sessionID: sessionID,
                runtimeKind: launchRuntime,
                workingDirectory: previousSession.workingDirectory,
                providerSessionID: providerSessionIDAtLaunch,
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
            executable: "/tmp/todoagent-terminal-runner",
            arguments: ["--descriptor", "/tmp/todoagent-descriptor.json"],
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
                runtimeKind: bundle.session.runtimeKind,
                workingDirectory: workspace,
                providerSessionID: bundle.session.providerSessionID,
                hasActiveRun: false,
                lastStartedAt: bundle.session.lastStartedAt,
                lastExitedAt: bundle.session.lastExitedAt,
                lastExitReason: bundle.session.lastExitReason,
                autoResume: bundle.session.autoResume
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
        let preparedRun = bundle.activeRun
        let runningRun = terminalRun(
            id: runID,
            sessionID: sessionID,
            state: .running,
            launchMode: preparedRun?.launchMode ?? .fresh,
            providerSessionIDAtLaunch: preparedRun?.providerSessionIDAtLaunch,
            startedAt: terminalControllerStartedAt
        )
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: bundle.session.taskID,
                sessionID: sessionID,
                runtimeKind: bundle.session.runtimeKind,
                workingDirectory: bundle.session.workingDirectory,
                providerSessionID: bundle.session.providerSessionID,
                hasActiveRun: true,
                lastStartedAt: terminalControllerStartedAt
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
        sessionID: String,
        runID: String,
        providerSessionID: String,
        source _: String
    ) async throws -> TerminalSessionBundle {
        bindCalls += 1
        #expect(sessionID == bundle.session.id)
        #expect(runID == bundle.activeRun?.id)
        let previous = bundle.session
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: previous.taskID,
                sessionID: previous.id,
                runtimeKind: previous.runtimeKind,
                workingDirectory: previous.workingDirectory,
                providerSessionID: providerSessionID,
                hasActiveRun: previous.hasActiveRun,
                lastErrorCode: previous.lastErrorCode,
                lastErrorMessage: previous.lastErrorMessage,
                lastStartedAt: previous.lastStartedAt,
                lastExitedAt: previous.lastExitedAt,
                lastExitReason: previous.lastExitReason,
                autoResume: false,
                updatedAt: previous.updatedAt
            ),
            activeRun: bundle.activeRun
        )
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

        let previousSession = bundle.session
        let previousRun = bundle.activeRun
        let exitedAt = "2026-08-14T00:00:01Z"
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: previousSession.taskID,
                sessionID: sessionID,
                runtimeKind: previousSession.runtimeKind,
                workingDirectory: previousSession.workingDirectory,
                providerSessionID: previousSession.providerSessionID,
                hasActiveRun: false,
                lastErrorCode: errorCode,
                lastErrorMessage: errorMessage,
                lastStartedAt: previousRun?.startedAt ?? previousSession.lastStartedAt,
                lastExitedAt: exitedAt,
                lastExitReason: reason.rawValue,
                autoResume: reason == .appShutdown && previousSession.providerSessionID != nil
            ),
            activeRun: terminalRun(
                id: runID,
                sessionID: sessionID,
                state: reason == .launchFailed ? .failed : .exited,
                launchMode: previousRun?.launchMode ?? .fresh,
                providerSessionIDAtLaunch: previousRun?.providerSessionIDAtLaunch,
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

    func releaseTerminalPrepare() {
        suspendsTerminalPrepare = false
        let waiters = terminalPrepareReleaseWaiters
        terminalPrepareReleaseWaiters.removeAll()
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

    func currentBundle() -> TerminalSessionBundle { bundle }
    func latestPreparedLaunch() -> TerminalControllerPreparedLaunch? { preparedLaunch }

    func waitUntilPrepareCallCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<100 {
            if prepareCalls >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return prepareCalls >= expectedCount
    }

    func createTerminalSession(
        taskID: UUID,
        runtime: RuntimeKind,
        workspace: String
    ) async throws -> TerminalSessionBundle {
        createdSessions.append((taskID, runtime, workspace))
        sessionMissing = false
        let sessionID = UUID().uuidString.lowercased()
        bundle = TerminalSessionBundle(
            session: testTerminalSession(
                taskID: taskID,
                sessionID: sessionID,
                runtimeKind: runtime,
                workingDirectory: workspace,
                providerSessionID: nil
            ),
            activeRun: nil
        )
        return bundle
    }

    func createTerminalSessionCount() -> Int { createdSessions.count }
    func createdWorkspaces() -> [String] { createdSessions.map(\.workspace) }

    func removeStoredSession() {
        sessionMissing = true
    }

    func deleteTerminalSession(sessionID: String) async throws {
        deletedIDs.append(sessionID)
        let waiters = deletedSessionWaiters
        deletedSessionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if suspendsTerminalDelete {
            await withCheckedContinuation { continuation in
                terminalDeleteReleaseWaiters.append(continuation)
            }
        }
    }

    func deletedSessionIDs() -> [String] { deletedIDs }

    func waitUntilDeletedSessionCount(_ expectedCount: Int) async -> Bool {
        for _ in 0..<100 {
            if deletedIDs.count >= expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return deletedIDs.count >= expectedCount
    }

    func releaseTerminalDelete() {
        suspendsTerminalDelete = false
        let waiters = terminalDeleteReleaseWaiters
        terminalDeleteReleaseWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
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

private let terminalControllerTestWorkspace: String = {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("todoagent-terminal-controller-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}()

private func testTask(id: UUID, title: String = "Host task") -> TaskItem {
    TaskItem(
        id: id,
        listID: nil,
        title: title,
        note: "",
        status: .open,
        dueDate: nil,
        completedAt: nil,
        createdAt: .distantPast,
        updatedAt: "2026-08-14T00:00:00Z"
    )
}

private func terminalBundle(
    taskID: UUID,
    sessionID: String,
    workingDirectory: String = terminalControllerTestWorkspace,
    providerSessionID: String? = "provider-session"
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
    runtimeKind: RuntimeKind = .claude,
    workingDirectory: String = terminalControllerTestWorkspace,
    providerSessionID: String? = "provider-session",
    hasActiveRun: Bool = false,
    lastErrorCode: String? = nil,
    lastErrorMessage: String? = nil,
    lastStartedAt: String? = nil,
    lastExitedAt: String? = nil,
    lastExitReason: String? = nil,
    autoResume: Bool = false,
    updatedAt: String = "2026-08-12T00:00:00Z"
) -> TerminalSessionDescriptor {
    TerminalSessionDescriptor(
        id: sessionID,
        taskID: taskID,
        runtimeKind: runtimeKind,
        workingDirectory: workingDirectory,
        providerSessionID: providerSessionID,
        providerBindingState: providerSessionID == nil ? .unbound : .bound,
        providerBindingSource: providerSessionID == nil ? nil : "test",
        agentStatus: hasActiveRun ? .active : .idle,
        hasActiveRun: hasActiveRun,
        lastErrorCode: lastErrorCode,
        lastErrorMessage: lastErrorMessage,
        lastStartedAt: lastStartedAt,
        lastExitedAt: lastExitedAt,
        lastExitReason: lastExitReason,
        autoResume: autoResume,
        createdAt: "2026-08-12T00:00:00Z",
        updatedAt: updatedAt
    )
}

private func terminalRun(
    id: String,
    sessionID: String,
    state: TerminalRunState,
    launchMode: TerminalRunLaunchMode = .fresh,
    providerSessionIDAtLaunch: String? = "provider-session",
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
        launchMode: launchMode,
        state: state,
        providerSessionIDAtLaunch: providerSessionIDAtLaunch,
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
