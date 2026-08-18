import AppKit
import Foundation
import UserNotifications

@MainActor
protocol AgentReplyNotifying: AnyObject {
    /// `runtime` is the Agent actually observed in this session, which the
    /// caller resolves. It is deliberately not read from `session.runtimeKind`:
    /// that field is only the default a host session was created with.
    func consider(
        eventID: String,
        status: TerminalAgentStatus,
        runtime: RuntimeKind?,
        session: TerminalSessionDescriptor
    ) async
    func requestAuthorizationIfNeeded() async -> Bool
}

extension AgentReplyNotifying {
    func requestAuthorizationIfNeeded() async -> Bool { false }
}

@MainActor
protocol AgentReplyNotificationDelivering: AnyObject {
    func authorizationState() async -> AgentReplyNotificationAuthorization
    func requestAuthorization() async -> AgentReplyNotificationAuthorization
    func deliver(_ request: AgentReplyNotificationRequest) async
    func install()
}

extension AgentReplyNotificationDelivering {
    func install() {}
}

@MainActor
protocol AgentReplyNotificationInspecting: AnyObject {
    func isInspecting(taskID: UUID) -> Bool
}

@MainActor
protocol AgentReplyNotificationRouting: AnyObject {
    func taskTitle(for taskID: UUID) -> String?
    func openTask(id: UUID)
    var hasLoadedTasks: Bool { get }
}

@MainActor
final class AgentReplyWorkspaceInspector: AgentReplyNotificationInspecting {
    private let workspace: TaskWorkspaceCoordinator

    init(workspace: TaskWorkspaceCoordinator) {
        self.workspace = workspace
    }

    func isInspecting(taskID: UUID) -> Bool {
        guard let application = NSApp, application.isActive else { return false }
        guard workspace.presentedTaskID == taskID else { return false }
        guard let window = application.keyWindow,
              window.identifier?.rawValue == TodoAgentMainWindow.identifier
        else { return false }
        return window.isVisible
            && window.isMiniaturized == false
            && window.occlusionState.contains(.visible)
    }
}

@MainActor
final class AgentReplyAppStateRouter: AgentReplyNotificationRouting {
    private let state: AppState

    init(state: AppState) {
        self.state = state
    }

    func taskTitle(for taskID: UUID) -> String? {
        state.task(id: taskID)?.title
    }

    func openTask(id: UUID) {
        guard let task = state.task(id: id) else { return }
        state.openTask(task)
    }

    var hasLoadedTasks: Bool {
        if case .loaded = state.loadState { return true }
        return false
    }
}

@MainActor
final class AgentReplyNotifier: AgentReplyNotifying {
    static let maximumRememberedEventIDs = 256

    private let channel: any AgentReplyNotificationDelivering
    private let inspector: any AgentReplyNotificationInspecting
    private let router: any AgentReplyNotificationRouting
    private let defaults: UserDefaults
    private let graceInterval: TimeInterval
    private let now: () -> Date
    private var seenEventIDs: [String] = []
    private var seenEventIDSet: Set<String> = []
    private var lastSuccessAt: [AgentReplyNotificationGraceKey: Date] = [:]
    private var pendingWhileInspecting: [String: AgentReplyNotificationRequest] = [:]
    private var pendingTaskID: UUID?
    /// Set once an authorization request goes unanswered, so later events skip
    /// straight past it instead of each spending the timeout again.
    private var didRequestWithoutAnswer = false

    init(
        channel: any AgentReplyNotificationDelivering,
        inspector: any AgentReplyNotificationInspecting,
        router: any AgentReplyNotificationRouting,
        defaults: UserDefaults = .standard,
        graceInterval: TimeInterval = AgentReplyNotificationContext.defaultGraceInterval,
        now: @escaping () -> Date = { Date() }
    ) {
        self.channel = channel
        self.inspector = inspector
        self.router = router
        self.defaults = defaults
        self.graceInterval = graceInterval
        self.now = now
    }

    func install() {
        channel.install()
    }

    func consider(
        eventID: String,
        status: TerminalAgentStatus,
        runtime: RuntimeKind?,
        session: TerminalSessionDescriptor
    ) async {
        guard let kind = AgentReplyNotificationKind(status: status) else { return }
        let trimmedTitle = router.taskTitle(for: session.taskID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let request = AgentReplyNotificationRequest(
            eventID: eventID,
            taskID: session.taskID,
            taskTitle: trimmedTitle.isEmpty ? "任务" : trimmedTitle,
            runtime: runtime,
            kind: kind
        )
        await consider(request)
    }

    func consider(_ request: AgentReplyNotificationRequest) async {
        pendingWhileInspecting[request.eventID] = nil
        switch evaluate(request, authorizationGranted: await isAuthorized()) {
        case .send:
            await deliverAndRecord(request)
        case .grace, .noop(.duplicateEvent), .noop(.disabled), .noop(.kindDisabled):
            remember(eventID: request.eventID)
        case .noop(.inspecting):
            pendingWhileInspecting[request.eventID] = request
            if await channel.authorizationState() == .notDetermined {
                _ = await requestAuthorizationIfNeeded()
            }
        case .noop(.unauthorized):
            let granted = await requestAuthorizationIfNeeded()
            guard granted else {
                remember(eventID: request.eventID)
                return
            }
            switch evaluate(request, authorizationGranted: true) {
            case .send:
                await deliverAndRecord(request)
            case .noop(.inspecting):
                pendingWhileInspecting[request.eventID] = request
            case .grace, .noop:
                remember(eventID: request.eventID)
            }
        }
    }

    /// Deliver replies that arrived while the user was looking at that terminal.
    /// Collapse and app resign both make `isInspecting` false.
    func flushPendingIfUninspected() async {
        let pending = Array(pendingWhileInspecting.values)
        for request in pending {
            await consider(request)
        }
    }

    func handleNotificationOpen(taskID: UUID) {
        activateAppIfPossible()
        if router.hasLoadedTasks {
            pendingTaskID = nil
            router.openTask(id: taskID)
        } else {
            pendingTaskID = taskID
        }
    }

    func deliverPendingOpenIfNeeded() {
        guard let pendingTaskID, router.hasLoadedTasks else { return }
        self.pendingTaskID = nil
        activateAppIfPossible()
        router.openTask(id: pendingTaskID)
    }

    private func activateAppIfPossible() {
        guard let application = NSApp else { return }
        application.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        // Reading the current state is always safe and fast, and it is what
        // picks up a permission the user granted later in System Settings.
        let state = await channel.authorizationState()
        if state == .granted { return true }
        // Asking again is pointless once a request has gone unanswered: the
        // system is not prompting for this build, so every later attempt would
        // just spend the timeout again and delay the events queued behind it.
        guard !didRequestWithoutAnswer else { return false }
        let result = await channel.requestAuthorization()
        if result == .notDetermined { didRequestWithoutAnswer = true }
        return result == .granted
    }

    func authorizationState() async -> AgentReplyNotificationAuthorization {
        await channel.authorizationState()
    }

    private func evaluate(
        _ request: AgentReplyNotificationRequest,
        authorizationGranted: Bool
    ) -> AgentReplyNotificationDecision {
        AgentReplyNotificationEvaluator.evaluate(
            request,
            context: AgentReplyNotificationContext(
                repliesEnabled: AgentReplyNotificationPreferences.repliesEnabled(defaults: defaults),
                permissionsEnabled: AgentReplyNotificationPreferences.permissionsEnabled(defaults: defaults),
                authorizationGranted: authorizationGranted,
                isInspectingTask: inspector.isInspecting(taskID: request.taskID),
                seenEventIDs: seenEventIDSet,
                lastSuccessAt: lastSuccessAt,
                now: now(),
                graceInterval: graceInterval
            )
        )
    }

    private func isAuthorized() async -> Bool {
        await channel.authorizationState() == .granted
    }

    private func deliverAndRecord(_ request: AgentReplyNotificationRequest) async {
        remember(eventID: request.eventID)
        lastSuccessAt[AgentReplyNotificationGraceKey(taskID: request.taskID, kind: request.kind)] = now()
        await channel.deliver(request)
    }

    private func remember(eventID: String) {
        guard seenEventIDSet.insert(eventID).inserted else { return }
        seenEventIDs.append(eventID)
        if seenEventIDs.count > Self.maximumRememberedEventIDs {
            let removed = seenEventIDs.removeFirst()
            seenEventIDSet.remove(removed)
        }
    }
}

@MainActor
final class UserNotificationsAgentReplyChannel: NSObject, AgentReplyNotificationDelivering {
    weak var notifier: AgentReplyNotifier?

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: AgentReplyNotificationIdentity.categoryIdentifier,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    func authorizationState() async -> AgentReplyNotificationAuthorization {
        Self.authorization(from: await UNUserNotificationCenter.current().notificationSettings())
    }

    /// Timeout for the authorization request.
    ///
    /// A build with no code-signing identity can leave
    /// `requestAuthorization` pending forever — the system neither prompts nor
    /// calls back. This request is awaited from the terminal status event loop,
    /// so waiting without a bound would stop every later status event for that
    /// session.
    ///
    /// Kept short on purpose. With a stored answer the call returns in
    /// milliseconds, and the one case that legitimately takes longer is a live
    /// system prompt — which macOS records whether or not TodoAgent is still
    /// waiting. So giving up early can cost at most the single notification
    /// being decided, and the next event sees the granted state.
    static let authorizationTimeout: Duration = .seconds(3)

    func requestAuthorization() async -> AgentReplyNotificationAuthorization {
        await AbandonableRequest.result(
            of: {
                do {
                    let granted = try await UNUserNotificationCenter.current()
                        .requestAuthorization(options: [.alert, .sound])
                    return granted ? .granted : .denied
                } catch {
                    return .denied
                }
            },
            timeout: Self.authorizationTimeout,
            timedOut: .notDetermined
        )
    }

    func deliver(_ request: AgentReplyNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.taskTitle
        content.subtitle = request.runtime.displayTitle
        content.body = request.kind.body
        content.sound = .default
        content.threadIdentifier = request.taskID.uuidString
        content.categoryIdentifier = AgentReplyNotificationIdentity.categoryIdentifier
        content.userInfo = [AgentReplyNotificationIdentity.taskIDKey: request.taskID.uuidString]
        content.interruptionLevel = .active
        let notification = UNNotificationRequest(
            identifier: request.eventID,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(notification)
    }

    private static func authorization(
        from settings: UNNotificationSettings
    ) -> AgentReplyNotificationAuthorization {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            .granted
        case .denied:
            .denied
        case .notDetermined:
            .notDetermined
        @unknown default:
            .notDetermined
        }
    }
}

extension UserNotificationsAgentReplyChannel: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let raw = response.notification.request.content.userInfo[AgentReplyNotificationIdentity.taskIDKey] as? String
        guard let raw, let taskID = UUID(uuidString: raw) else { return }
        await openTask(id: taskID)
    }

    @MainActor
    private func openTask(id taskID: UUID) {
        notifier?.handleNotificationOpen(taskID: taskID)
    }
}
