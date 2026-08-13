import AppKit
import Darwin
import Dispatch
import Foundation
import Observation

enum TerminalSurfaceEvent: Equatable, Sendable {
    case started
    case titleChanged(String?)
    case workingDirectoryChanged(String)
    case attentionRequested
    case processExited(exitCode: Int32?, reason: TerminalRunExitReason)
}

@MainActor
protocol TerminalSurfaceSession: AnyObject {
    var view: NSView { get }
    var onEvent: (@MainActor (TerminalSurfaceEvent) -> Void)? { get set }
    func focus()
    func commitComposition()
    func performAction(_ action: String)
    func terminate()
    func close()
}

@MainActor
protocol TerminalSurfaceFactory: AnyObject {
    func makeSurface(configuration: TerminalLaunchPlan) throws -> any TerminalSurfaceSession
}

@MainActor
final class UnavailableTerminalSurfaceFactory: TerminalSurfaceFactory {
    struct UnavailableError: LocalizedError {
        var errorDescription: String? {
            "内嵌终端尚未载入。请重新构建或安装 TodoAgent。"
        }
    }

    func makeSurface(configuration _: TerminalLaunchPlan) throws -> any TerminalSurfaceSession {
        throw UnavailableError()
    }
}

@MainActor
enum TerminalSurfaceFactoryProvider {
    static var make: () -> any TerminalSurfaceFactory = {
        UnavailableTerminalSurfaceFactory()
    }
}

enum TerminalSessionPresentationPhase: Equatable, Sendable {
    case preparing
    case launching
    case agentRunning
    case ended(exitCode: Int32?)
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .preparing: "正在准备"
        case .launching: "正在启动"
        case .agentRunning: "运行中"
        case .ended: "已结束"
        case .stopping: "正在结束"
        case .failed: "启动失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .launching, .agentRunning, .stopping: true
        case .ended, .failed: false
        }
    }
}

enum TerminalWorkspaceRebindError: LocalizedError {
    case sessionIsActive

    var errorDescription: String? {
        switch self {
        case .sessionIsActive:
            "正在运行的 Session 不能更换工作目录。"
        }
    }
}

@MainActor
@Observable
final class TerminalSessionController {
    let taskID: UUID
    private(set) var bundle: TerminalSessionBundle
    private(set) var phase: TerminalSessionPresentationPhase
    private(set) var terminalTitle: String?
    private(set) var workingDirectory: String
    private(set) var needsAttention = false
    private(set) var isAttached = false
    /// Presentation state must be observable independently of the retained
    /// AppKit/Ghostty object. Engine events can mark a Run ended before the
    /// local surface teardown finishes, so deriving this from an
    /// `@ObservationIgnored` reference leaves SwiftUI showing a stale blank
    /// terminal after the reference is cleared.
    private(set) var hasLiveSurface = false
    private(set) var resumeCandidates: [TerminalResumeCandidate] = []
    private(set) var isLoadingResumeCandidates = false
    private(set) var didLoadResumeCandidates = false
    private(set) var resumeErrorMessage: String?

    @ObservationIgnored private let repository: any AppRepository
    @ObservationIgnored private let surfaceFactory: any TerminalSurfaceFactory
    @ObservationIgnored private var surfaceSession: (any TerminalSurfaceSession)?
    @ObservationIgnored private var hostView: TerminalSurfaceHostView?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var statusServer: TerminalStatusServer?
    @ObservationIgnored private var statusEventTask: Task<Void, Never>?
    @ObservationIgnored private var terminationEscalationTask: Task<Void, Never>?
    @ObservationIgnored private var surfaceExitFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var exitReasonOverride: TerminalRunExitReason?
    @ObservationIgnored private var activeRunID: String?
    @ObservationIgnored private var processGroupID: Int32?
    @ObservationIgnored private var runnerDidStart = false
    @ObservationIgnored private var didReportStarted = false
    @ObservationIgnored private var isReportingStarted = false
    @ObservationIgnored private var startedReportRetryTask: Task<Void, Never>?
    @ObservationIgnored private var startedReportWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var didReportExit = false
    @ObservationIgnored private var isReportingExit = false
    @ObservationIgnored private var pendingExitReport: PendingExitReport?
    @ObservationIgnored private var exitReportRetryTask: Task<Void, Never>?
    @ObservationIgnored private var exitReportFailureCount = 0
    @ObservationIgnored private var isHandlingEngineRestart = false
    @ObservationIgnored private var kiroMetadataWatcher: KiroMetadataWatcher?
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    private struct PendingExitReport: Equatable {
        let runID: String
        let exitCode: Int32?
        let reason: TerminalRunExitReason
        let errorCode: String?
        let errorMessage: String?
    }

    init(
        bundle: TerminalSessionBundle,
        repository: any AppRepository,
        surfaceFactory: any TerminalSurfaceFactory
    ) {
        taskID = bundle.session.taskID
        self.bundle = bundle
        self.repository = repository
        self.surfaceFactory = surfaceFactory
        workingDirectory = bundle.session.workingDirectory
        needsAttention = bundle.session.hasUnread || bundle.session.agentStatus.needsAttention
        phase = Self.phase(for: bundle)
    }

    var session: TerminalSessionDescriptor { bundle.session }
    var activeRun: TerminalRun? { bundle.activeRun }
    var view: NSView? { surfaceSession?.view }
    var workingDirectoryIsAvailable: Bool {
        TerminalWorkingDirectoryPolicy.isAvailable(session.workingDirectory)
    }
    var requiresProviderSelection: Bool {
        activeRun?.state != .failed
            && activeRun != nil
            && session.providerSessionID == nil
            && (session.runtimeKind == .codex || session.runtimeKind == .kiro)
    }

    func launch(taskTitle: String?) {
        guard surfaceSession == nil,
              launchTask == nil,
              activeRun?.state.isActive != true,
              pendingExitReport == nil
        else { return }
        phase = .preparing
        let sessionID = session.id
        let runID = UUID().uuidString.lowercased()
        activeRunID = runID
        runnerDidStart = false
        didReportStarted = false
        isReportingStarted = false
        startedReportRetryTask?.cancel()
        startedReportRetryTask = nil
        resumeStartedReportWaiters()
        didReportExit = false
        isReportingExit = false
        pendingExitReport = nil
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        exitReportFailureCount = 0
        surfaceExitFallbackTask?.cancel()
        surfaceExitFallbackTask = nil
        exitReasonOverride = nil
        processGroupID = nil
        kiroMetadataWatcher?.stop()
        kiroMetadataWatcher = nil
        resumeCandidates = []
        didLoadResumeCandidates = false
        resumeErrorMessage = nil

        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.launchTask = nil }
            do {
                let server = try TerminalStatusServer(sessionID: sessionID, runID: runID)
                self.statusServer = server
                self.consumeStatusEvents(from: server, runID: runID)
                let plan = try await repository.prepareTerminalLaunch(
                    sessionID: sessionID,
                    runID: runID,
                    taskTitle: taskTitle,
                    statusSocket: server.credentials.socketPath,
                    lifecycleToken: server.credentials.lifecycleToken,
                    hookToken: server.credentials.hookToken,
                    providerHooksEnabled: TerminalStatusAuthorization.state(
                        for: self.session.runtimeKind
                    ) == .enabled,
                    hostPID: ProcessInfo.processInfo.processIdentifier
                )
                guard !Task.isCancelled, self.session.id == plan.session.id else { return }
                self.bundle = TerminalSessionBundle(session: plan.session, activeRun: plan.run)
                self.phase = .launching
                let surface = try self.surfaceFactory.makeSurface(configuration: plan)
                surface.onEvent = { [weak self] event in
                    self?.handleSurfaceEvent(event)
                }
                self.surfaceSession = surface
                self.hasLiveSurface = true
                self.hostView?.attach(surface.view)
                self.focusIfAppropriate()
            } catch is CancellationError {
                self.finishStatusServer()
                return
            } catch {
                self.phase = .failed(error.localizedDescription)
                let hasDurableRun = await self.reportLaunchFailureIfPossible(
                    runID: runID,
                    error: error
                )
                if !hasDurableRun {
                    self.destroySurfaceAndServer()
                }
            }
        }
    }

    func attach(to host: TerminalSurfaceHostView) {
        if let previous = hostView, previous !== host {
            previous.detach()
        }
        hostView = host
        isAttached = true
        if let view = surfaceSession?.view {
            host.attach(view)
        }
        focusIfAppropriate()
    }

    func detach(from host: TerminalSurfaceHostView) {
        guard hostView === host else { return }
        surfaceSession?.commitComposition()
        host.detach()
        hostView = nil
        isAttached = false
    }

    func focusIfAppropriate() {
        guard let surfaceSession, let window = surfaceSession.view.window, window.isKeyWindow else { return }
        guard !(window.firstResponder is NSText) else { return }
        surfaceSession.focus()
        markSeenIfNeeded()
    }

    func markSeenIfNeeded() {
        guard session.hasUnread else {
            needsAttention = false
            return
        }
        let sessionID = session.id
        let sequence = session.statusSequence
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await repository.markTerminalSessionSeen(
                    sessionID: sessionID,
                    through: sequence
                )
                guard self.session.id == session.id else { return }
                self.bundle = TerminalSessionBundle(session: session, activeRun: self.activeRun)
                self.needsAttention = session.hasUnread || session.agentStatus.needsAttention
            } catch {
                // Seen state is best-effort and must never interrupt terminal input.
            }
        }
    }

    func performAction(_ action: String) {
        surfaceSession?.performAction(action)
    }

    func surfaceCommitComposition() {
        surfaceSession?.commitComposition()
    }

    func end(reason: TerminalRunExitReason = .userEnded) async {
        // `prepareTerminalLaunch` durably creates a `starting` Run before the
        // Ghostty surface exists. Never cancel that request halfway through:
        // wait for its bounded result, then transition the resulting Run out of
        // `starting` through the same authenticated teardown path.
        if let pendingLaunch = launchTask {
            phase = .stopping
            await pendingLaunch.value
        }
        if pendingExitReport != nil, !didReportExit {
            await persistPendingExitReportIfNeeded()
        }
        if activeRun == nil {
            destroySurfaceAndServer()
            phase = .ended(exitCode: nil)
            activeRunID = nil
            resumeExitWaiters()
            return
        }
        guard let runID = activeRun?.id ?? activeRunID,
              activeRun?.state.isActive == true || surfaceSession != nil
        else {
            destroySurfaceAndServer()
            return
        }
        phase = .stopping
        exitReasonOverride = reason
        // Termination is a user-visible, safety-critical action. Signal the
        // process group before any bounded Engine reconciliation so an Engine
        // outage can never leave the Agent running while End/Quit waits.
        surfaceSession?.commitComposition()
        surfaceSession?.terminate()
        if let processGroupID { Darwin.kill(-processGroupID, SIGTERM) }
        scheduleTerminationEscalation(runID: runID, reason: reason)
        if runnerDidStart, !didReportStarted { await reportStartedIfNeeded(runID: runID) }
        if activeRun?.state.isActive == true,
           let incoming = try? await repository.markTerminalRunStopping(
               sessionID: session.id,
               runID: runID
        ) {
            merge(incoming)
        }
        await withCheckedContinuation { continuation in
            if didReportExit, !isReportingExit {
                continuation.resume()
            } else {
                exitWaiters.append(continuation)
            }
        }
    }

    func apply(_ incoming: TerminalSessionBundle) {
        merge(incoming)
    }

    func applyAuthoritativeSessionDescriptor(_ incoming: TerminalSessionDescriptor) {
        guard incoming.id == session.id else { return }
        // Task snapshots and terminal events travel on independent IPC paths.
        // Never let an older bootstrap descriptor roll a newly rebound cwd
        // back after `terminal.session.changed` has already been applied.
        guard incoming.updatedAt >= session.updatedAt else { return }
        let preservedRun = incoming.hasActiveRun ? activeRun : nil
        merge(TerminalSessionBundle(session: incoming, activeRun: preservedRun))
    }

    func rebindWorkspace(_ workspace: String) async throws {
        guard !hasLiveSurface,
              activeRun?.state.isActive != true,
              launchTask == nil,
              pendingExitReport == nil
        else {
            throw TerminalWorkspaceRebindError.sessionIsActive
        }
        let incoming = try await repository.rebindTerminalWorkspace(
            sessionID: session.id,
            workspace: workspace
        )
        merge(incoming)
        workingDirectory = incoming.session.workingDirectory
        phase = Self.phase(for: incoming)
        resumeCandidates = []
        didLoadResumeCandidates = false
        resumeErrorMessage = nil
    }

    /// A restarted Engine has already reconciled every active database Run to
    /// `interrupted`. Its old runner/PTY belongs to that terminal generation and
    /// must not outlive the durable state or be allowed to emit into the new
    /// Engine generation.
    func terminateForEngineRestart() async {
        guard hasLiveSurface || launchTask != nil || activeRun?.state.isActive == true else { return }
        isHandlingEngineRestart = true
        phase = .stopping
        launchTask?.cancel()
        if let launchTask { await launchTask.value }

        startedReportRetryTask?.cancel()
        startedReportRetryTask = nil
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        terminationEscalationTask?.cancel()
        terminationEscalationTask = nil
        surfaceExitFallbackTask?.cancel()
        surfaceExitFallbackTask = nil
        pendingExitReport = nil
        didReportExit = true

        surfaceSession?.commitComposition()
        surfaceSession?.terminate()
        if let processGroupID { Darwin.kill(-processGroupID, SIGTERM) }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            // Continue with the final kill/cleanup even if App shutdown cancels
            // this delay.
        }
        if let processGroupID { Darwin.kill(-processGroupID, SIGKILL) }
        destroySurfaceAndServer()
        activeRunID = nil
        isReportingExit = false
        resumeStartedReportWaiters()
        resumeExitWaiters()
    }

    func loadResumeCandidates() async {
        guard requiresProviderSelection, !isLoadingResumeCandidates else { return }
        isLoadingResumeCandidates = true
        resumeErrorMessage = nil
        defer {
            isLoadingResumeCandidates = false
            didLoadResumeCandidates = true
        }
        do {
            let result = try await repository.terminalResumeCandidates(sessionID: session.id)
            guard result.session.id == session.id else { return }
            bundle = TerminalSessionBundle(session: result.session, activeRun: activeRun)
            resumeCandidates = result.candidates
            if result.candidates.count == 1, let candidate = result.candidates.first {
                try await bindResumeCandidate(candidate)
            }
        } catch {
            resumeCandidates = []
            resumeErrorMessage = error.localizedDescription
        }
    }

    func bindResumeCandidate(_ candidate: TerminalResumeCandidate) async throws {
        guard requiresProviderSelection, let runID = activeRun?.id else {
            throw AppRepositoryError.sessionNotFound
        }
        let incoming = try await repository.bindTerminalProvider(
            sessionID: session.id,
            runID: runID,
            providerSessionID: candidate.providerSessionID,
            source: "manual"
        )
        merge(incoming)
        resumeCandidates = []
        didLoadResumeCandidates = false
        resumeErrorMessage = nil
    }

    private func handleSurfaceEvent(_ event: TerminalSurfaceEvent) {
        switch event {
        case .started:
            // Surface creation only means the renderer is ready. The runner's
            // authenticated `started` datagram is the authority for process state.
            break
        case let .titleChanged(title):
            terminalTitle = title
        case let .workingDirectoryChanged(path):
            workingDirectory = path
        case .attentionRequested:
            needsAttention = true
        case let .processExited(exitCode, reason):
            scheduleSurfaceExitFallback(
                exitCode: exitCode,
                reason: exitReasonOverride ?? reason
            )
        }
    }

    private func consumeStatusEvents(from server: TerminalStatusServer, runID: String) {
        statusEventTask?.cancel()
        statusEventTask = Task { @MainActor [weak self] in
            for await event in server.events {
                guard let self, self.activeRunID == runID else { return }
                await self.handleStatusServerEvent(event, runID: runID)
            }
        }
    }

    private func handleStatusServerEvent(
        _ event: TerminalStatusServerEvent,
        runID: String
    ) async {
        switch event {
        case let .started(_, pgid):
            processGroupID = pgid
            await reportStartedIfNeeded(runID: runID)
            startKiroMetadataWatcherIfNeeded(runID: runID)
        case let .providerBound(providerSessionID, source):
            guard activeRunID == runID else { return }
            do {
                merge(try await repository.bindTerminalProvider(
                    sessionID: session.id,
                    runID: runID,
                    providerSessionID: providerSessionID,
                    source: source
                ))
            } catch {
                needsAttention = true
            }
        case let .status(status, eventID):
            guard activeRunID == runID else { return }
            do {
                merge(try await repository.reportTerminalStatus(
                    sessionID: session.id,
                    runID: runID,
                    status: status,
                    eventID: eventID
                ))
            } catch {
                needsAttention = true
            }
        case let .exited(exitCode, _):
            await reportExitIfNeeded(
                exitCode: exitCode,
                reason: exitReasonOverride ?? .processExit
            )
        }
    }

    private func reportStartedIfNeeded(runID: String?) async {
        guard let runID else { return }
        runnerDidStart = true
        phase = .agentRunning
        guard activeRunID == runID else { return }
        guard !didReportStarted else { return }
        if isReportingStarted {
            await withCheckedContinuation { continuation in
                startedReportWaiters.append(continuation)
            }
            return
        }
        isReportingStarted = true
        defer {
            isReportingStarted = false
            resumeStartedReportWaiters()
        }
        do {
            merge(try await repository.markTerminalRunStarted(
                sessionID: session.id,
                runID: runID
            ))
            didReportStarted = true
        } catch {
            // A timed-out IPC response may still have committed. Reconcile the
            // exact run before replaying the idempotent mutation so a real Agent
            // can never exit with a missing `started_at` merely because its
            // first response was lost.
            if await reconcileStartedRun(runID: runID) {
                didReportStarted = true
                return
            }
            do {
                merge(try await repository.markTerminalRunStarted(
                    sessionID: session.id,
                    runID: runID
                ))
                didReportStarted = true
            } catch {
                if await reconcileStartedRun(runID: runID) {
                    didReportStarted = true
                } else {
                    // The authenticated runner is already alive. Keep the
                    // terminal usable but make the durable-state problem visible.
                    needsAttention = true
                    scheduleStartedReportRetry(runID: runID)
                }
            }
        }
    }

    private func reportExitIfNeeded(
        exitCode: Int32?,
        reason: TerminalRunExitReason,
        errorCode: String? = nil,
        errorMessage: String? = nil
    ) async {
        guard let runID = activeRun?.id ?? activeRunID else { return }
        let report = PendingExitReport(
            runID: runID,
            exitCode: exitCode,
            reason: reason,
            errorCode: errorCode,
            errorMessage: errorMessage
        )
        if let pendingExitReport, pendingExitReport != report {
            // The first authenticated terminal outcome is authoritative. End,
            // fallback, and retry paths must replay the exact same payload.
            return
        }
        pendingExitReport = report
        await persistPendingExitReportIfNeeded()
    }

    private func persistPendingExitReportIfNeeded() async {
        guard !didReportExit, !isReportingExit, let report = pendingExitReport else { return }
        isReportingExit = true
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        terminationEscalationTask?.cancel()
        terminationEscalationTask = nil
        surfaceExitFallbackTask?.cancel()
        surfaceExitFallbackTask = nil
        if runnerDidStart, !didReportStarted { await reportStartedIfNeeded(runID: report.runID) }
        do {
            let incoming = try await repository.reportTerminalRunExited(
                sessionID: session.id,
                runID: report.runID,
                exitCode: report.exitCode,
                reason: report.reason,
                errorCode: report.errorCode,
                errorMessage: report.errorMessage
            )
            completeDurableExit(incoming, report: report)
        } catch {
            if isHandlingEngineRestart {
                isReportingExit = false
                return
            }
            if let reconciled = try? await repository.terminalSession(taskID: session.taskID),
               exitReport(report, matches: reconciled.activeRun) {
                completeDurableExit(reconciled, report: report)
                return
            }
            isReportingExit = false
            exitReportFailureCount += 1
            phase = .failed(error.localizedDescription)
            needsAttention = true
            scheduleExitReportRetry()
        }
    }

    private func completeDurableExit(
        _ incoming: TerminalSessionBundle,
        report: PendingExitReport
    ) {
        merge(incoming)
        didReportExit = true
        isReportingExit = false
        pendingExitReport = nil
        exitReportFailureCount = 0
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        phase = report.reason == .launchFailed
            ? .failed(report.errorMessage ?? "终端启动失败。")
            : .ended(exitCode: report.exitCode)
        destroySurfaceAndServer()
        resumeExitWaiters()
    }

    private func scheduleExitReportRetry() {
        guard !didReportExit, pendingExitReport != nil, exitReportRetryTask == nil else { return }
        let delay = min(5_000, 200 * (1 << min(exitReportFailureCount - 1, 4)))
        exitReportRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                return
            }
            guard let self else { return }
            self.exitReportRetryTask = nil
            await self.persistPendingExitReportIfNeeded()
        }
    }

    private func scheduleSurfaceExitFallback(exitCode: Int32?, reason: TerminalRunExitReason) {
        guard !didReportExit else { return }
        surfaceExitFallbackTask?.cancel()
        surfaceExitFallbackTask = Task { @MainActor [weak self] in
            do {
                // The authenticated runner datagram is authoritative. Ghostty's
                // child-exit callback is a bounded fallback for a lost datagram.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, !self.didReportExit else { return }
            await self.reportExitIfNeeded(exitCode: exitCode, reason: reason)
        }
    }

    private func scheduleTerminationEscalation(runID: String, reason: TerminalRunExitReason) {
        terminationEscalationTask?.cancel()
        terminationEscalationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self, !self.didReportExit, self.activeRunID == runID else { return }
            if let processGroupID = self.processGroupID { Darwin.kill(-processGroupID, SIGKILL) }
            self.surfaceSession?.close()
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !self.didReportExit else { return }
            await self.reportExitIfNeeded(exitCode: nil, reason: reason)
        }
    }

    private func destroySurfaceAndServer() {
        surfaceExitFallbackTask?.cancel()
        surfaceExitFallbackTask = nil
        startedReportRetryTask?.cancel()
        startedReportRetryTask = nil
        kiroMetadataWatcher?.stop()
        kiroMetadataWatcher = nil
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        surfaceSession?.commitComposition()
        hostView?.detach()
        surfaceSession?.onEvent = nil
        surfaceSession?.close()
        surfaceSession = nil
        hasLiveSurface = false
        hostView = nil
        isAttached = false
        processGroupID = nil
        finishStatusServer()
    }

    private func finishStatusServer() {
        statusEventTask?.cancel()
        statusEventTask = nil
        statusServer?.stop()
        statusServer = nil
    }

    private func resumeExitWaiters() {
        let continuations = exitWaiters
        exitWaiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func resumeStartedReportWaiters() {
        let continuations = startedReportWaiters
        startedReportWaiters.removeAll()
        for continuation in continuations { continuation.resume() }
    }

    private func reconcileStartedRun(runID: String) async -> Bool {
        guard let incoming = try? await repository.terminalSession(taskID: session.taskID),
              let run = incoming.activeRun,
              run.id == runID,
              run.startedAt != nil
        else { return false }
        merge(incoming)
        return true
    }

    private func scheduleStartedReportRetry(runID: String) {
        guard !didReportStarted, startedReportRetryTask == nil else { return }
        startedReportRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self else { return }
            self.startedReportRetryTask = nil
            await self.reportStartedIfNeeded(runID: runID)
        }
    }

    private func startKiroMetadataWatcherIfNeeded(runID: String) {
        guard session.runtimeKind == .kiro,
              session.providerSessionID == nil,
              kiroMetadataWatcher == nil
        else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kiro/sessions/cli", isDirectory: true)
        kiroMetadataWatcher = KiroMetadataWatcher(directory: directory) { [weak self] in
            guard let self, self.activeRunID == runID else { return }
            await self.captureKiroProviderIfUnique(runID: runID)
        }
        kiroMetadataWatcher?.start()
    }

    private func captureKiroProviderIfUnique(runID: String) async {
        guard session.runtimeKind == .kiro,
              session.providerSessionID == nil,
              activeRunID == runID,
              activeRun?.state.isActive == true
        else { return }
        do {
            let result = try await repository.terminalResumeCandidates(sessionID: session.id)
            guard activeRunID == runID,
                  session.providerSessionID == nil,
                  result.candidates.count == 1,
                  let candidate = result.candidates.first
            else { return }
            merge(try await repository.bindTerminalProvider(
                sessionID: session.id,
                runID: runID,
                providerSessionID: candidate.providerSessionID,
                // Candidate.source identifies the provider's metadata store.
                // The Engine persists the stable cross-provider scan source.
                source: TerminalProviderCaptureStrategy.sessionStoreScan.rawValue
            ))
            kiroMetadataWatcher?.stop()
            kiroMetadataWatcher = nil
        } catch {
            // Metadata writes can be observed before the provider has flushed a
            // complete JSON document. The next filesystem event retries; no
            // candidate is ever guessed or bound from a partial file.
        }
    }

    private func exitReport(_ report: PendingExitReport, matches run: TerminalRun?) -> Bool {
        guard let run,
              run.id == report.runID,
              !run.state.isActive,
              run.exitCode == report.exitCode,
              run.exitReason == report.reason,
              run.errorCode == report.errorCode
        else { return false }
        if let expected = report.errorMessage {
            return run.errorMessage == expected
        }
        return true
    }

    private func merge(_ incoming: TerminalSessionBundle) {
        guard incoming.session.id == session.id else { return }
        bundle = incoming
        workingDirectory = incoming.session.workingDirectory
        if incoming.activeRun?.state.isActive != true {
            isHandlingEngineRestart = false
        }
        needsAttention = incoming.session.hasUnread || incoming.session.agentStatus.needsAttention
        if case .failed = phase { return }
        phase = Self.phase(for: incoming)
    }

    private func reportLaunchFailureIfPossible(runID: String, error: any Error) async -> Bool {
        // `prepare_launch` commits the starting Run before returning its launch
        // plan. If that response is lost, the local bundle still points at the
        // previous Run. Reconcile by the stable run ID so the committed Run is
        // durably finished and its descriptor cannot block another launch for
        // the remainder of this App process.
        if activeRun?.id != runID,
           let reconciled = try? await repository.terminalSession(taskID: session.taskID),
           reconciled.activeRun?.id == runID {
            merge(reconciled)
        }
        guard activeRun?.id == runID, activeRun?.state.isActive == true else { return false }
        await reportExitIfNeeded(
            exitCode: nil,
            reason: .launchFailed,
            errorCode: "terminal_surface_launch_failed",
            errorMessage: error.localizedDescription
        )
        return true
    }

    private static func phase(for bundle: TerminalSessionBundle) -> TerminalSessionPresentationPhase {
        guard let run = bundle.activeRun else {
            if let message = bundle.session.lastErrorMessage, !message.isEmpty { return .failed(message) }
            return .ended(exitCode: nil)
        }
        switch run.state {
        case .starting: return .launching
        case .running: return .agentRunning
        case .stopping: return .stopping
        case .exited, .interrupted: return .ended(exitCode: run.exitCode)
        case .failed: return .failed(run.errorMessage ?? "终端启动失败。")
        }
    }
}

@MainActor
@Observable
final class TerminalSessionRegistry {
    @ObservationIgnored private let repository: any AppRepository
    @ObservationIgnored private let surfaceFactory: any TerminalSurfaceFactory
    @ObservationIgnored private var controllers: [UUID: TerminalSessionController] = [:]
    private(set) var isShuttingDown = false
    private(set) var isRecoveringEngine = false

    init(
        repository: any AppRepository,
        surfaceFactory: any TerminalSurfaceFactory = UnavailableTerminalSurfaceFactory()
    ) {
        self.repository = repository
        self.surfaceFactory = surfaceFactory
    }

    func controller(for taskID: UUID) -> TerminalSessionController? {
        controllers[taskID]
    }

    func beginShutdown() {
        isShuttingDown = true
    }

    func cancelShutdown() {
        isShuttingDown = false
    }

    @discardableResult
    func restore(_ bundle: TerminalSessionBundle) -> TerminalSessionController? {
        if let existing = controllers[bundle.session.taskID] {
            existing.apply(bundle)
            return existing
        }
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        let controller = TerminalSessionController(
            bundle: bundle,
            repository: repository,
            surfaceFactory: surfaceFactory
        )
        controllers[bundle.session.taskID] = controller
        return controller
    }

    func load(taskID: UUID) async throws -> TerminalSessionController? {
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        if let existing = controllers[taskID] { return existing }
        guard let bundle = try await repository.terminalSession(taskID: taskID) else { return nil }
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        return restore(bundle)
    }

    func create(
        task: TaskItem,
        runtime: RuntimeKind,
        workspace: String
    ) async throws -> TerminalSessionController {
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        if let existing = controllers[task.id] {
            if !existing.hasLiveSurface, existing.activeRun?.state.isActive != true {
                await resumeOrLaunch(existing, taskTitle: task.title)
            }
            return existing
        }
        let bundle = try await repository.createTerminalSession(
            taskID: task.id,
            runtime: runtime,
            workspace: workspace
        )
        guard !isShuttingDown, !isRecoveringEngine, let controller = restore(bundle) else {
            throw CancellationError()
        }
        await resumeOrLaunch(controller, taskTitle: task.title)
        return controller
    }

    func resumeOrLaunch(_ controller: TerminalSessionController, taskTitle: String?) async {
        guard !isShuttingDown, !isRecoveringEngine else { return }
        guard !controller.hasLiveSurface, !controller.phase.isActive else {
            controller.focusIfAppropriate()
            return
        }
        if controller.requiresProviderSelection {
            await controller.loadResumeCandidates()
            guard !isShuttingDown, !isRecoveringEngine, !controller.requiresProviderSelection else { return }
        }
        guard confirmResourceUseIfNeeded() else { return }
        guard !isShuttingDown, !isRecoveringEngine else { return }
        controller.launch(taskTitle: taskTitle)
    }

    /// Reopen entry point used by retained task windows. Active terminals are
    /// only focused; ended terminals start exactly one fresh/resume launch.
    func resumeIfNeeded(taskID: UUID, taskTitle: String?) async {
        guard let controller = controllers[taskID] else { return }
        await resumeOrLaunch(controller, taskTitle: taskTitle)
    }

    func bindAndResume(
        _ candidate: TerminalResumeCandidate,
        controller: TerminalSessionController,
        taskTitle: String?
    ) async {
        guard !isShuttingDown, !isRecoveringEngine else { return }
        do {
            try await controller.bindResumeCandidate(candidate)
            guard !isShuttingDown, !isRecoveringEngine else { return }
            guard confirmResourceUseIfNeeded() else { return }
            guard !isShuttingDown, !isRecoveringEngine else { return }
            controller.launch(taskTitle: taskTitle)
        } catch {
            guard !isShuttingDown, !isRecoveringEngine else { return }
            // Keep the candidate list visible; the workbench renders this error.
            await controller.loadResumeCandidates()
        }
    }

    func rebindWorkspaceAndResume(
        _ workspace: String,
        controller: TerminalSessionController,
        taskTitle: String?
    ) async throws {
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        try await controller.rebindWorkspace(workspace)
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        await resumeOrLaunch(controller, taskTitle: taskTitle)
    }

    func remove(taskID: UUID, reason: TerminalRunExitReason) async {
        guard let controller = controllers[taskID] else { return }
        await controller.end(reason: reason)
        controllers[taskID] = nil
    }

    func endRetaining(taskID: UUID, reason: TerminalRunExitReason) async {
        guard let controller = controllers[taskID] else { return }
        await controller.end(reason: reason)
    }

    func endAll(reason: TerminalRunExitReason) async {
        isShuttingDown = true
        let active = controllers
        let endings = active.values.map { controller in
            return Task { @MainActor in
                await controller.end(reason: reason)
            }
        }
        for ending in endings {
            await ending.value
        }
        controllers.removeAll()
    }

    func reconcileEngineRestart() async {
        guard !isShuttingDown, !isRecoveringEngine else { return }
        isRecoveringEngine = true
        defer { isRecoveringEngine = false }
        let realized = Array(controllers.values)
        let terminations = realized.map { controller in
            Task { @MainActor in
                await controller.terminateForEngineRestart()
            }
        }
        for termination in terminations { await termination.value }

        for controller in realized {
            guard let incoming = try? await repository.terminalSession(taskID: controller.taskID) else {
                continue
            }
            controller.apply(incoming)
        }
    }

    var activeCount: Int {
        controllers.values.count(where: { $0.hasLiveSurface || $0.phase.isActive })
    }

    private func confirmResourceUseIfNeeded() -> Bool {
        guard activeCount >= 3 else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "启动第 4 个活跃终端？"
        alert.informativeText = "每个 Agent 都会保留独立的 PTY、渲染 Surface 和子进程，继续启动会增加内存与 CPU 消耗。"
        alert.addButton(withTitle: "继续启动")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Watches Kiro's session metadata directory without polling. The directory
/// already exists for supported Kiro CLI installations; if it is created a
/// little later, a short bounded attach sequence covers first launch without a
/// permanent timer or background status loop.
private final class KiroMetadataWatcher: @unchecked Sendable {
    private let directory: URL
    private let onChange: @MainActor @Sendable () async -> Void
    private let lock = NSLock()
    private var source: (any DispatchSourceFileSystemObject)?
    private var attachTask: Task<Void, Never>?
    private var stopped = false

    init(
        directory: URL,
        onChange: @escaping @MainActor @Sendable () async -> Void
    ) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        lock.lock()
        guard !stopped, attachTask == nil, source == nil else {
            lock.unlock()
            return
        }
        lock.unlock()
        let directory = directory
        attachTask = Task { [weak self] in
            for attempt in 0..<8 {
                guard !Task.isCancelled, let self else { return }
                if self.attach(directory: directory) {
                    await self.onChange()
                    return
                }
                guard attempt < 7 else { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let attachTask = attachTask
        self.attachTask = nil
        let source = source
        self.source = nil
        lock.unlock()
        attachTask?.cancel()
        source?.cancel()
    }

    private func attach(directory: URL) -> Bool {
        let opened = Darwin.open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard opened >= 0 else { return false }
        let queue = DispatchQueue(label: "com.todoagent.kiro-metadata", qos: .utility)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: opened,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.onChange() }
        }
        source.setCancelHandler { Darwin.close(opened) }

        lock.lock()
        guard !stopped, self.source == nil else {
            lock.unlock()
            source.cancel()
            return false
        }
        self.source = source
        attachTask = nil
        lock.unlock()
        source.resume()
        return true
    }

    deinit {
        stop()
    }
}

@MainActor
final class TerminalSurfaceHostView: NSView {
    private weak var terminalView: NSView?

    override var acceptsFirstResponder: Bool { false }

    func attach(_ view: NSView) {
        guard terminalView !== view else { return }
        detach()
        terminalView = view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func detach() {
        terminalView?.removeFromSuperview()
        terminalView = nil
    }
}
