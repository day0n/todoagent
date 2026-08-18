import AppKit
import Darwin
import Dispatch
import Foundation
import Observation
import QuartzCore

enum TerminalSurfaceEvent: Equatable, Sendable {
    case started
    case titleChanged(String?)
    case workingDirectoryChanged(String)
    case attentionRequested
    case desktopNotification(title: String, body: String)
    case processExited(exitCode: Int32?, reason: TerminalRunExitReason)
}

@MainActor
protocol TerminalSurfaceSession: AnyObject {
    var view: NSView { get }
    var onEvent: (@MainActor (TerminalSurfaceEvent) -> Void)? { get set }
    /// PID currently in the foreground of this PTY, or `nil` when only a dead
    /// or absent process remains.
    var foregroundProcessID: pid_t? { get }
    func focus()
    func commitComposition()
    func performAction(_ action: String)
    func sendText(_ text: String)
    func terminate()
    func close()
}

@MainActor
protocol TerminalSurfaceFactory: AnyObject {
    func makeSurface(configuration: TerminalLaunchPlan) throws -> any TerminalSurfaceSession
    func makeHostSurface(workingDirectory: String, environment: [String: String]) throws -> any TerminalSurfaceSession
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

    func makeHostSurface(
        workingDirectory _: String,
        environment _: [String: String]
    ) throws -> any TerminalSurfaceSession {
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
    case shellIdle
    case hostExited
    case ended(exitCode: Int32?)
    case stopping
    case failed(String)

    var title: String {
        switch self {
        case .preparing: "正在准备"
        case .launching: "正在启动"
        case .agentRunning: "运行中"
        case .shellIdle: "终端就绪"
        case .hostExited: "终端已退出"
        case .ended: "已结束"
        case .stopping: "正在结束"
        case .failed: "启动失败"
        }
    }

    var isActive: Bool {
        switch self {
        case .preparing, .launching, .agentRunning, .stopping: true
        case .shellIdle, .hostExited, .ended, .failed: false
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
    /// Agent actually running in this host PTY, resolved from the foreground
    /// process. Distinct from the session's default `runtimeKind`, which is
    /// Claude for every newly opened host shell.
    private(set) var detectedRuntime: RuntimeKind?
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
    @ObservationIgnored private let exitJournal: TerminalExitJournalCoordinator
    @ObservationIgnored private var surfaceSession: (any TerminalSurfaceSession)?
    @ObservationIgnored private var hostView: TerminalSurfaceHostView?
    @ObservationIgnored private var launchTask: Task<Void, Never>?
    @ObservationIgnored private var statusServer: TerminalStatusServer?
    @ObservationIgnored private var statusEventTask: Task<Void, Never>?
    @ObservationIgnored private var hostStatusServer: TerminalStatusServer?
    @ObservationIgnored private var hostStatusEventTask: Task<Void, Never>?
    @ObservationIgnored private var terminationEscalationTask: Task<Void, Never>?
    @ObservationIgnored private var surfaceExitFallbackTask: Task<Void, Never>?
    @ObservationIgnored private var exitReasonOverride: TerminalRunExitReason?
    @ObservationIgnored private var activeRunID: String?
    @ObservationIgnored private var hostStatusRunID: String?
    @ObservationIgnored private var processGroupID: Int32?
    @ObservationIgnored private var runnerDidStart = false
    @ObservationIgnored private var didReportStarted = false
    @ObservationIgnored private var isReportingStarted = false
    @ObservationIgnored private var startedReportRetryTask: Task<Void, Never>?
    @ObservationIgnored private var startedReportWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var didReportExit = false
    @ObservationIgnored private var isReportingExit = false
    @ObservationIgnored private var pendingExitReport: TerminalExitRecord?
    @ObservationIgnored private var exitReportRetryTask: Task<Void, Never>?
    @ObservationIgnored private var exitReportFailureCount = 0
    @ObservationIgnored private var endOperationTask: Task<Void, Never>?
    @ObservationIgnored private var endOperationReason: TerminalRunExitReason?
    @ObservationIgnored private var endCallWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var shutdownExitDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownExitDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var isShutdownExitDeferred = false
    @ObservationIgnored private var isHandlingEngineRestart = false
    @ObservationIgnored private var kiroMetadataWatcher: KiroMetadataWatcher?
    @ObservationIgnored private var runtimeProbeTask: Task<Void, Never>?
    /// Injectable so tests can drive detection without a real PTY.
    @ObservationIgnored var runtimeProbe: (pid_t) -> RuntimeKind? = {
        HostAgentRuntimeProbe.detect(pid: $0)
    }
    @ObservationIgnored private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored var onHostAbandoned: (@MainActor () -> Void)?
    @ObservationIgnored var replyNotifier: (any AgentReplyNotifying)?

    convenience init(
        bundle: TerminalSessionBundle,
        repository: any AppRepository,
        surfaceFactory: any TerminalSurfaceFactory,
        exitJournal: any TerminalExitJournaling = NoopTerminalExitJournal()
    ) {
        self.init(
            bundle: bundle,
            repository: repository,
            surfaceFactory: surfaceFactory,
            exitJournalCoordinator: TerminalExitJournalCoordinator(journal: exitJournal)
        )
    }

    fileprivate init(
        bundle: TerminalSessionBundle,
        repository: any AppRepository,
        surfaceFactory: any TerminalSurfaceFactory,
        exitJournalCoordinator: TerminalExitJournalCoordinator
    ) {
        taskID = bundle.session.taskID
        self.bundle = bundle
        self.repository = repository
        self.surfaceFactory = surfaceFactory
        exitJournal = exitJournalCoordinator
        workingDirectory = bundle.session.workingDirectory
        needsAttention = bundle.session.hasUnread || bundle.session.agentStatus.needsAttention
        // Nothing is known about a host shell until its PTY exists and can be
        // probed. Seeding this from `session.runtimeKind` (Claude for every new
        // host session) and persisting it is what previously pinned the card to
        // the Claude icon forever.
        detectedRuntime = nil
        phase = Self.phase(for: bundle)
    }

    var session: TerminalSessionDescriptor { bundle.session }
    var activeRun: TerminalRun? { bundle.activeRun }
    var isActive: Bool { phase.isActive }

    /// The runtime to show for this task, and the only source the UI should
    /// read.
    ///
    /// The live probe wins: it observes the PTY directly. Failing that, a run
    /// TodoAgent launched itself is real evidence, because the runner spawned
    /// exactly that CLI — and during such a run the foreground process is often
    /// the runner rather than the Agent, so the probe legitimately finds
    /// nothing. Absent both, `nil` means a plain shell and must not fall back
    /// to the session's default, which is Claude for every new host session.
    ///
    /// Kept in step with `TaskCardAgentStatus.displayedRuntime`, which applies
    /// the same order for tasks whose controller is not in memory.
    var displayRuntime: RuntimeKind? {
        if let detectedRuntime { return detectedRuntime }
        if session.hasOfficialAgentRun { return session.runtimeKind }
        return nil
    }
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

    func launch(
        taskTitle: String?,
        intent: TerminalLaunchIntent = .auto,
        runtimeKind: RuntimeKind? = nil
    ) {
        guard launchTask == nil,
              !isShutdownExitDeferred,
              endOperationTask == nil,
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
                try self.ensureHostSurface()
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
                        for: runtimeKind ?? self.session.runtimeKind
                    ) == .enabled,
                    hostPID: ProcessInfo.processInfo.processIdentifier,
                    intent: intent,
                    runtimeKind: runtimeKind
                )
                guard !Task.isCancelled, self.session.id == plan.session.id else { return }
                self.bundle = TerminalSessionBundle(session: plan.session, activeRun: plan.run)
                self.phase = .launching
                let command = try GhosttyCommandBuilder.officialLaunchCommand(
                    executable: plan.executable,
                    arguments: plan.arguments,
                    workingDirectory: plan.workingDirectory
                )
                self.surfaceSession?.sendText(command)
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
                    self.finishStatusServer()
                }
            }
        }
    }

    func ensureHostSurface() throws {
        if surfaceSession != nil { return }
        let hookEnvironment = startHostStatusListenerIfPossible()
        let surface = try surfaceFactory.makeHostSurface(
            workingDirectory: TerminalHostDefaults.workingDirectory,
            environment: hookEnvironment
        )
        surface.onEvent = { [weak self] event in
            self?.handleSurfaceEvent(event)
        }
        Task { @MainActor [weak self] in
            _ = await self?.replyNotifier?.requestAuthorizationIfNeeded()
        }
        // A host shell reports status only if the provider's hooks are already
        // installed for this account, and the Agent reads them when it starts.
        // Asking here means the decision is made before the user types
        // `claude`; asking after would leave their first run silent.
        //
        // Gated on `requiresExecutionConsent` for the same reason
        // `ExecutionSafety.authorize` is: this presents an `NSAlert`, and a
        // modal runs a nested run loop that owns the main actor until someone
        // clicks it. Only the real Engine repository opts in, so tests and
        // previews never block. Runs detached so surface creation completes
        // first either way.
        if repository.requiresExecutionConsent {
            let runtime = session.runtimeKind
            Task { @MainActor in
                TerminalStatusAuthorization.requestIfNeeded(for: runtime)
            }
        }
        surfaceSession = surface
        hasLiveSurface = true
        startRuntimeProbe()
        workingDirectory = TerminalHostDefaults.workingDirectory
        hostView?.attach(surface.view)
        if !phase.isActive {
            phase = .shellIdle
        }
    }

    func reportHostFailure(_ message: String) {
        phase = .failed(message)
    }

    func attach(to host: TerminalSurfaceHostView) {
        let hostChanged = hostView !== host
        if let previous = hostView, previous !== host {
            previous.detach()
        }
        hostView = host
        isAttached = true
        if let view = surfaceSession?.view {
            host.attach(view)
        }
        // SwiftUI may call updateNSView for unrelated observed state changes.
        // Only a real reparent should request focus; repeated updates must not
        // steal keyboard navigation from toolbar buttons or other controls.
        if hostChanged {
            focusIfAppropriate()
        }
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

    func end(
        reason: TerminalRunExitReason = .userEnded,
        persistenceDeadline: Duration? = nil
    ) async {
        guard !isShutdownExitDeferred else { return }
        let authoritativeReason: TerminalRunExitReason
        if let endOperationReason {
            authoritativeReason = endOperationReason
        } else {
            endOperationReason = reason
            exitReasonOverride = reason
            authoritativeReason = reason
        }
        if endOperationTask == nil {
            let operation = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performEnd(reason: authoritativeReason)
                self.finishEndOperation()
            }
            endOperationTask = operation
        }
        if let persistenceDeadline {
            scheduleShutdownExitDeadline(after: persistenceDeadline, reason: authoritativeReason)
        }

        await withCheckedContinuation { continuation in
            if endOperationTask == nil || isShutdownExitDeferred {
                continuation.resume()
            } else {
                endCallWaiters.append(continuation)
            }
        }
    }

    private func finishEndOperation() {
        shutdownExitDeadlineTask?.cancel()
        shutdownExitDeadlineTask = nil
        shutdownExitDeadline = nil
        endOperationTask = nil
        endOperationReason = nil
        resumeEndCallWaiters()
    }

    private func resumeEndCallWaiters() {
        let waiters = endCallWaiters
        endCallWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func scheduleShutdownExitDeadline(
        after duration: Duration,
        reason: TerminalRunExitReason
    ) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        if let shutdownExitDeadline, shutdownExitDeadline <= deadline { return }
        shutdownExitDeadlineTask?.cancel()
        shutdownExitDeadline = deadline
        shutdownExitDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self else { return }
            await self.deferExitAtShutdownDeadline(reason: reason)
        }
    }

    private func performEnd(reason: TerminalRunExitReason) async {
        // `prepareTerminalLaunch` durably creates a `starting` Run before the
        // Ghostty surface exists. Never cancel that request halfway through:
        // wait for its bounded result, then transition the resulting Run out of
        // `starting` through the same authenticated teardown path.
        if let pendingLaunch = launchTask {
            phase = .stopping
            await pendingLaunch.value
            guard !isShutdownExitDeferred else { return }
        }
        if pendingExitReport != nil, !didReportExit {
            await persistPendingExitReportIfNeeded()
            guard !isShutdownExitDeferred else { return }
        }
        if activeRun == nil || activeRun?.state.isActive != true {
            if reason == .appShutdown {
                destroySurfaceAndServer()
                phase = .ended(exitCode: nil)
            }
            activeRunID = nil
            resumeExitWaiters()
            return
        }
        guard let runID = activeRun?.id ?? activeRunID else {
            if reason == .appShutdown {
                destroySurfaceAndServer()
            }
            return
        }
        phase = .stopping
        exitReasonOverride = reason
        // Termination is a user-visible, safety-critical action. Signal the
        // process group before any bounded Engine reconciliation so an Engine
        // outage can never leave the Agent running while End/Quit waits.
        surfaceSession?.commitComposition()
        if reason == .appShutdown {
            surfaceSession?.terminate()
        }
        if let processGroupID { Darwin.kill(-processGroupID, SIGTERM) }
        scheduleTerminationEscalation(runID: runID, reason: reason)
        if runnerDidStart, !didReportStarted { await reportStartedIfNeeded(runID: runID) }
        guard !isShutdownExitDeferred else { return }
        if activeRun?.state.isActive == true {
            let incoming = try? await repository.markTerminalRunStopping(
               sessionID: session.id,
               runID: runID
            )
            guard !isShutdownExitDeferred else { return }
            if let incoming { merge(incoming) }
        }
        guard !isShutdownExitDeferred else { return }
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
        guard activeRun?.state.isActive != true,
              launchTask == nil,
              pendingExitReport == nil
        else {
            throw TerminalWorkspaceRebindError.sessionIsActive
        }
        if hasLiveSurface {
            destroySurfaceAndServer()
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
            // The title is displayed but never used to infer which Agent runs
            // here. A task titled "学习 claude code 源码" reaches this string.
            terminalTitle = title
        case let .workingDirectoryChanged(path):
            workingDirectory = path
        case .attentionRequested:
            needsAttention = true
        case .desktopNotification:
            needsAttention = true
            Task { @MainActor [weak self] in
                await self?.notifyHostAgentReply()
            }
        case let .processExited(exitCode, reason):
            if exitReasonOverride == .appShutdown || isShutdownExitDeferred {
                scheduleSurfaceExitFallback(
                    exitCode: exitCode,
                    reason: exitReasonOverride ?? reason
                )
                return
            }
            Task { @MainActor [weak self] in
                await self?.abandonHost(exitCode: exitCode, reason: reason)
            }
        }
    }

    /// Polls the PTY's foreground process so the UI can show which Agent is
    /// really running. The kernel offers no "foreground process changed"
    /// notification, so this has to poll; each pass costs two syscalls.
    private func startRuntimeProbe() {
        guard runtimeProbeTask == nil else { return }
        refreshDetectedRuntime()
        runtimeProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                } catch {
                    return
                }
                guard let self, self.hasLiveSurface else { return }
                self.refreshDetectedRuntime()
            }
        }
    }

    private func stopRuntimeProbe() {
        runtimeProbeTask?.cancel()
        runtimeProbeTask = nil
        detectedRuntime = nil
    }

    private func refreshDetectedRuntime() {
        guard let pid = surfaceSession?.foregroundProcessID else {
            detectedRuntime = nil
            return
        }
        let probed = runtimeProbe(pid)
        guard detectedRuntime != probed else { return }
        detectedRuntime = probed
    }

    private func notifyHostAgentReply() async {
        // The last probed runtime is used as-is rather than re-probed here. By
        // the time an Agent announces it finished, the foreground process may
        // already be back to the shell; the remembered value attributes the
        // reply to the Agent that actually sent it.
        await replyNotifier?.consider(
            eventID: UUID().uuidString.lowercased(),
            status: .completed,
            runtime: displayRuntime,
            session: session
        )
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
                if status == .completed || status == .blocked {
                    await replyNotifier?.consider(
                        eventID: eventID,
                        status: status,
                        runtime: displayRuntime,
                        session: session
                    )
                }
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
        let report = TerminalExitRecord(
            taskID: taskID,
            sessionID: session.id,
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
        do {
            try await exitJournal.store(report)
        } catch {
            // The Engine request may still succeed. If both stores are
            // unavailable, surface the durability problem without changing the
            // first authoritative payload.
            phase = .failed(error.localizedDescription)
            needsAttention = true
        }
        guard !isShutdownExitDeferred else { return }
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
            guard !isShutdownExitDeferred else {
                isReportingExit = false
                return
            }
            completeDurableExit(incoming, report: report)
        } catch {
            if isShutdownExitDeferred {
                isReportingExit = false
                return
            }
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
        report: TerminalExitRecord
    ) {
        guard !isShutdownExitDeferred else {
            isReportingExit = false
            return
        }
        merge(incoming)
        didReportExit = true
        isReportingExit = false
        pendingExitReport = nil
        exitReportFailureCount = 0
        exitReportRetryTask?.cancel()
        exitReportRetryTask = nil
        // Engine acknowledgement makes the journal entry redundant. Cleanup is
        // ordered behind its store but never gates terminal teardown; retaining
        // it after an I/O failure is safe because exact replay is idempotent.
        exitJournal.enqueueRemove(runID: report.runID)
        finishStatusServer()
        activeRunID = nil
        processGroupID = nil
        kiroMetadataWatcher?.stop()
        kiroMetadataWatcher = nil
        switch report.reason {
        case .appShutdown:
            destroySurfaceAndServer()
            phase = .ended(exitCode: report.exitCode)
        case .launchFailed:
            phase = .failed(report.errorMessage ?? "终端启动失败。")
        case .processExit, .userEnded:
            phase = .shellIdle
        }
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

    private func deferExitAtShutdownDeadline(reason: TerminalRunExitReason) async {
        guard !didReportExit, !isShutdownExitDeferred else { return }
        isShutdownExitDeferred = true
        shutdownExitDeadlineTask = nil
        shutdownExitDeadline = nil
        endOperationTask?.cancel()
        launchTask?.cancel()
        if !didReportExit,
           pendingExitReport == nil,
           let runID = activeRun?.id ?? activeRunID {
            let report = TerminalExitRecord(
                taskID: taskID,
                sessionID: session.id,
                runID: runID,
                exitCode: nil,
                reason: reason,
                errorCode: nil,
                errorMessage: nil
            )
            pendingExitReport = report
            // This is intentionally non-waiting. The persistence deadline must
            // release AppKit even if fsync never returns, while the dedicated
            // serial queue retains and eventually performs this exact write.
            exitJournal.enqueueStore(report)
        }

        // Terminate the local process tree before releasing AppKit's
        // terminateLater gate. The journal is replayed by the next healthy
        // Engine generation, so the IPC retry can no longer keep Quit stuck.
        if let processGroupID { Darwin.kill(-processGroupID, SIGKILL) }
        isReportingExit = false
        destroySurfaceAndServer()
        phase = .ended(exitCode: pendingExitReport?.exitCode)
        activeRunID = nil
        resumeExitWaiters()
        resumeEndCallWaiters()
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
            if self.exitReasonOverride == .appShutdown {
                self.surfaceSession?.close()
            }
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
        stopRuntimeProbe()
        hostView = nil
        isAttached = false
        processGroupID = nil
        finishStatusServer()
        finishHostStatusServer()
    }

    private func abandonHost(exitCode: Int32?, reason: TerminalRunExitReason) async {
        if activeRun?.state.isActive == true || activeRunID != nil {
            await reportExitIfNeeded(exitCode: exitCode, reason: reason)
        }
        let sessionID = session.id
        try? await repository.deleteTerminalSession(sessionID: sessionID)
        destroySurfaceAndServer()
        phase = .hostExited
        onHostAbandoned?()
        resumeExitWaiters()
    }

    private func finishStatusServer() {
        statusEventTask?.cancel()
        statusEventTask = nil
        statusServer?.stop()
        statusServer = nil
    }

    private func finishHostStatusServer() {
        hostStatusEventTask?.cancel()
        hostStatusEventTask = nil
        hostStatusServer?.stop()
        hostStatusServer = nil
        hostStatusRunID = nil
    }

    @discardableResult
    private func startHostStatusListenerIfPossible() -> [String: String] {
        finishHostStatusServer()
        let runID = UUID().uuidString.lowercased()
        guard let server = try? TerminalStatusServer(sessionID: session.id, runID: runID) else {
            return [:]
        }
        hostStatusRunID = runID
        hostStatusServer = server
        consumeHostStatusEvents(from: server, runID: runID)
        return HostAgentHookSupport.environment(
            sessionID: session.id,
            runID: runID,
            runtime: session.runtimeKind,
            socketPath: server.credentials.socketPath,
            hookToken: server.credentials.hookToken
        )
    }

    private func consumeHostStatusEvents(from server: TerminalStatusServer, runID: String) {
        hostStatusEventTask?.cancel()
        hostStatusEventTask = Task { @MainActor [weak self] in
            for await event in server.events {
                guard let self, self.hostStatusRunID == runID else { return }
                await self.handleHostStatusEvent(event)
            }
        }
    }

    private func handleHostStatusEvent(_ event: TerminalStatusServerEvent) async {
        switch event {
        case .started, .exited:
            break
        case .providerBound:
            break
        case let .status(status, eventID):
            // A host hook event proves *an* Agent is running, but not which
            // one: the `TODOAGENT_RUNTIME` it carries is the session's default,
            // so attributing the event to it would report Claude no matter what
            // the user actually launched. The foreground-process probe answers
            // that question instead.
            guard status == .completed || status == .blocked else { return }
            needsAttention = true
            await replyNotifier?.consider(
                eventID: eventID,
                status: status,
                runtime: displayRuntime,
                session: session
            )
        }
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

    private func exitReport(_ report: TerminalExitRecord, matches run: TerminalRun?) -> Bool {
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
        if !hasLiveSurface {
            workingDirectory = incoming.session.workingDirectory
        }
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
        guard let run = bundle.activeRun else { return .shellIdle }
        switch run.state {
        case .starting: return .launching
        case .running: return .agentRunning
        case .stopping: return .stopping
        case .exited, .interrupted: return .shellIdle
        case .failed: return .failed(run.errorMessage ?? "终端启动失败。")
        }
    }
}

enum TerminalHostDefaults {
    static var workingDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .path
    }

    static let storedRuntime = RuntimeKind.claude
}

@MainActor
@Observable
final class TerminalSessionRegistry {
    @ObservationIgnored private let repository: any AppRepository
    @ObservationIgnored private let surfaceFactory: any TerminalSurfaceFactory
    @ObservationIgnored private let exitJournal: TerminalExitJournalCoordinator
    @ObservationIgnored private let shutdownExitPersistenceDeadline: Duration
    @ObservationIgnored private var controllers: [UUID: TerminalSessionController] = [:]
    @ObservationIgnored var replyNotifier: (any AgentReplyNotifying)? {
        didSet { applyReplyNotifier() }
    }
    private(set) var isShuttingDown = false
    private(set) var isRecoveringEngine = false

    init(
        repository: any AppRepository,
        surfaceFactory: any TerminalSurfaceFactory = UnavailableTerminalSurfaceFactory(),
        exitJournal: any TerminalExitJournaling = TerminalExitJournalStore(),
        shutdownExitPersistenceDeadline: Duration = .seconds(4),
        replyNotifier: (any AgentReplyNotifying)? = nil
    ) {
        self.repository = repository
        self.surfaceFactory = surfaceFactory
        self.exitJournal = TerminalExitJournalCoordinator(journal: exitJournal)
        self.shutdownExitPersistenceDeadline = shutdownExitPersistenceDeadline
        self.replyNotifier = replyNotifier
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
            existing.replyNotifier = replyNotifier
            existing.apply(bundle)
            return existing
        }
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        let controller = TerminalSessionController(
            bundle: bundle,
            repository: repository,
            surfaceFactory: surfaceFactory,
            exitJournalCoordinator: exitJournal
        )
        controller.replyNotifier = replyNotifier
        controllers[bundle.session.taskID] = controller
        controller.onHostAbandoned = { [weak self, weak controller, taskID = bundle.session.taskID] in
            guard let self, let controller, self.controllers[taskID] === controller else { return }
            self.controllers[taskID] = nil
        }
        return controller
    }

    private func applyReplyNotifier() {
        for controller in controllers.values {
            controller.replyNotifier = replyNotifier
        }
    }

    func forget(taskID: UUID) {
        controllers[taskID] = nil
    }

    /// Drops the in-memory controller only when it is still the deleted session.
    /// A late `terminal.session.deleted` for an exited host must not evict the
    /// replacement created by `ensureHost`.
    func forget(sessionID: String, taskID: UUID) {
        guard controllers[taskID]?.session.id == sessionID else { return }
        controllers[taskID] = nil
    }

    func load(taskID: UUID) async throws -> TerminalSessionController? {
        try Task.checkCancellation()
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        if let existing = controllers[taskID] { return existing }
        let bundle = try await repository.terminalSession(taskID: taskID)
        try Task.checkCancellation()
        guard !isShuttingDown, !isRecoveringEngine else { return nil }
        // Another open may have installed or launched the Controller while this
        // repository lookup was suspended. Never apply the older snapshot to
        // that newer in-memory state.
        if let existing = controllers[taskID] { return existing }
        guard let bundle else { return nil }
        return restore(bundle)
    }

    /// Opens or creates the task's host shell. Does not launch an Agent.
    func ensureHost(task: TaskItem) async throws -> TerminalSessionController {
        try Task.checkCancellation()
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        if let existing = controllers[task.id] {
            if existing.phase != .hostExited {
                try Task.checkCancellation()
                restoreHostIfNeeded(existing)
                existing.focusIfAppropriate()
                return existing
            }
            forget(taskID: task.id)
        }
        if let loaded = try await load(taskID: task.id), loaded.phase != .hostExited {
            try Task.checkCancellation()
            restoreHostIfNeeded(loaded)
            loaded.focusIfAppropriate()
            return loaded
        }
        let workspace = TerminalHostDefaults.workingDirectory
        try? WorkspaceAuthorizationStore.save(
            URL(fileURLWithPath: workspace, isDirectory: true)
        )
        let bundle = try await repository.createTerminalSession(
            taskID: task.id,
            runtime: TerminalHostDefaults.storedRuntime,
            workspace: workspace
        )
        try Task.checkCancellation()
        guard !isShuttingDown, !isRecoveringEngine, let controller = restore(bundle) else {
            throw CancellationError()
        }
        restoreHostIfNeeded(controller)
        return controller
    }

    /// Product entry point for a task's terminal. Every task opens directly to
    /// a retained host shell. Only a durable app-shutdown marker is allowed to
    /// auto-resume the exact provider conversation; ordinary exits stay idle.
    func openTask(_ task: TaskItem) async throws -> TerminalSessionController {
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        let controller = try await ensureHost(task: task)
        try Task.checkCancellation()
        guard controllers[task.id] === controller else { throw CancellationError() }
        await resumeIfNeeded(taskID: task.id, taskTitle: task.title)
        try Task.checkCancellation()
        guard controllers[task.id] === controller else { throw CancellationError() }
        return controller
    }

    func create(
        task: TaskItem,
        runtime: RuntimeKind,
        workspace: String
    ) async throws -> TerminalSessionController {
        guard !isShuttingDown, !isRecoveringEngine else { throw CancellationError() }
        if let existing = controllers[task.id] {
            if existing.activeRun?.state.isActive != true {
                if existing.session.workingDirectory != workspace {
                    try await existing.rebindWorkspace(workspace)
                }
                await launchAgent(existing, taskTitle: task.title, intent: .fresh, runtimeKind: runtime)
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
        await launchAgent(controller, taskTitle: task.title, intent: .fresh, runtimeKind: runtime)
        return controller
    }

    func resumeOrLaunch(_ controller: TerminalSessionController, taskTitle: String?) async {
        guard !isShuttingDown, !isRecoveringEngine else { return }
        let intent: TerminalLaunchIntent = if controller.session.hasOfficialAgentRun {
            .resume
        } else {
            .fresh
        }
        await launchAgent(controller, taskTitle: taskTitle, intent: intent)
    }

    func launchAgent(
        _ controller: TerminalSessionController,
        taskTitle: String?,
        intent: TerminalLaunchIntent,
        runtimeKind: RuntimeKind? = nil
    ) async {
        guard !Task.isCancelled, !isShuttingDown, !isRecoveringEngine else { return }
        if controller.requiresProviderSelection, intent != .fresh {
            await controller.loadResumeCandidates()
            guard !Task.isCancelled,
                  !isShuttingDown,
                  !isRecoveringEngine,
                  !controller.requiresProviderSelection
            else { return }
        }
        guard confirmResourceUseIfNeeded() else { return }
        guard !Task.isCancelled, !isShuttingDown, !isRecoveringEngine else { return }
        restoreHostIfNeeded(controller)
        guard !Task.isCancelled else { return }
        controller.launch(taskTitle: taskTitle, intent: intent, runtimeKind: runtimeKind)
    }

    func restoreHostIfNeeded(_ controller: TerminalSessionController) {
        guard !controller.hasLiveSurface, !controller.phase.isActive else { return }
        do {
            try controller.ensureHostSurface()
        } catch {
            controller.reportHostFailure(error.localizedDescription)
        }
    }

    /// Reopen entry point used by retained and newly reconstructed task
    /// windows. Only a durable app-shutdown marker is allowed to auto-launch.
    func resumeIfNeeded(taskID: UUID, taskTitle: String? = nil) async {
        guard !Task.isCancelled, let controller = controllers[taskID] else { return }
        guard controller.session.autoResume,
              controller.session.providerSessionID != nil
        else {
            controller.focusIfAppropriate()
            return
        }
        await launchAgent(controller, taskTitle: taskTitle, intent: .resume)
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
            controller.launch(taskTitle: taskTitle, intent: .resume)
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
                await controller.end(
                    reason: reason,
                    persistenceDeadline: shutdownExitPersistenceDeadline
                )
            }
        }
        for ending in endings {
            await ending.value
        }
        controllers.removeAll()
    }

    /// Replays write-ahead exit facts after a healthy Engine generation is
    /// available. Records are removed only after the Engine confirms the exact
    /// payload; a partial replay is retried on the next ready event.
    func replayPendingExitReports() async {
        let records: [TerminalExitRecord]
        do {
            records = try await exitJournal.records()
        } catch {
            return
        }
        for record in records {
            do {
                _ = try await repository.reportTerminalRunExited(
                    sessionID: record.sessionID,
                    runID: record.runID,
                    exitCode: record.exitCode,
                    reason: record.reason,
                    errorCode: record.errorCode,
                    errorMessage: record.errorMessage
                )
                try await exitJournal.remove(runID: record.runID)
            } catch {
                // The supervisor calls this again for every healthy Engine
                // generation. Never delete an unacknowledged exit fact.
            }
        }
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
        controllers.values.count(where: \.isActive)
    }

    private func confirmResourceUseIfNeeded() -> Bool {
        guard activeCount >= 3 else { return true }
        if isRunningUnitTests {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "启动第 4 个活跃 Agent？"
        alert.informativeText = "每个 Agent 都会保留独立的 runner 子进程，继续启动会增加内存与 CPU 消耗。空闲的 host shell 不计入这个上限。"
        alert.addButton(withTitle: "继续启动")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return true
        }
        return CommandLine.arguments.contains { argument in
            argument.contains("xctest") || argument.contains("PackageTests")
        }
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

    override func setFrameSize(_ newSize: NSSize) {
        performWithoutGeometryAnimation {
            setFrameSizeOnSuperclass(newSize)
            synchronizeTerminalFrameInCurrentTransaction()
        }
    }

    override func layout() {
        super.layout()
        synchronizeTerminalFrame()
    }

    func attach(_ view: NSView) {
        guard terminalView !== view else {
            synchronizeTerminalFrame()
            return
        }
        detach()
        terminalView = view
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        // Host resizing is synchronized explicitly below. An AppKit flexible
        // autoresizing mask would first apply its delta to the retained old
        // frame (producing an oversized intermediate framebuffer) before our
        // final assignment.
        view.autoresizingMask = []
        addSubview(view)
        synchronizeTerminalFrame()
    }

    func detach() {
        terminalView?.removeFromSuperview()
        terminalView = nil
    }

    private func synchronizeTerminalFrame() {
        performWithoutGeometryAnimation {
            synchronizeTerminalFrameInCurrentTransaction()
        }
    }

    private func synchronizeTerminalFrameInCurrentTransaction() {
        guard let terminalView, terminalView.superview === self else { return }
        let targetFrame = bounds
        // NSViewRepresentable creates its host before SwiftUI assigns the
        // final proposal. Preserve a retained Ghostty surface's last useful
        // framebuffer size instead of forcing old -> zero -> final during
        // reparenting; the first nonzero setFrameSize/layout performs the one
        // real synchronization.
        guard targetFrame.width > 0, targetFrame.height > 0 else { return }
        guard terminalView.frame != targetFrame else { return }
        // A terminal framebuffer must track the divider's model geometry on
        // every event. Do not inherit a surrounding SwiftUI/AppKit animation
        // transaction: Ghostty's view is layer-backed, so an implicit frame
        // animation would visually lag behind the divider and snap at the end.
        terminalView.frame = targetFrame
    }

    private func setFrameSizeOnSuperclass(_ newSize: NSSize) {
        super.setFrameSize(newSize)
    }

    private func performWithoutGeometryAnimation(_ updates: () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            updates()
            CATransaction.commit()
        }
    }
}
