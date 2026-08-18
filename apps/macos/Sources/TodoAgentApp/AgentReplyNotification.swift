import AppKit
import Foundation

enum AgentReplyNotificationIdentity {
    static let categoryIdentifier = "todoagent.agent-reply"
    static let taskIDKey = "taskID"
}

enum AgentReplyNotificationKind: String, Equatable, Sendable {
    case reply
    case permission

    init?(status: TerminalAgentStatus) {
        switch status {
        case .completed: self = .reply
        case .blocked: self = .permission
        case .unknown, .idle, .active: return nil
        }
    }

    var body: String {
        switch self {
        case .reply: "有新回复"
        case .permission: "需要你确认权限"
        }
    }
}

struct AgentReplyNotificationRequest: Equatable, Sendable {
    let eventID: String
    let taskID: UUID
    let taskTitle: String
    /// `nil` when the Agent that replied could not be identified, which happens
    /// for a host shell whose foreground process has already moved on.
    let runtime: RuntimeKind?
    let kind: AgentReplyNotificationKind
}

enum AgentReplyNotificationSuppression: Equatable, Sendable {
    case disabled
    case kindDisabled
    case unauthorized
    case duplicateEvent
    case inspecting
}

enum AgentReplyNotificationDecision: Equatable, Sendable {
    case send
    case grace
    case noop(AgentReplyNotificationSuppression)
}

struct AgentReplyNotificationGraceKey: Hashable, Sendable {
    let taskID: UUID
    let kind: AgentReplyNotificationKind
}

struct AgentReplyNotificationContext: Equatable, Sendable {
    var repliesEnabled: Bool
    var permissionsEnabled: Bool
    var authorizationGranted: Bool
    var isInspectingTask: Bool
    var seenEventIDs: Set<String>
    var lastSuccessAt: [AgentReplyNotificationGraceKey: Date]
    var now: Date
    var graceInterval: TimeInterval

    static let defaultGraceInterval: TimeInterval = 2
}

enum AgentReplyNotificationEvaluator {
    static func evaluate(
        _ request: AgentReplyNotificationRequest,
        context: AgentReplyNotificationContext
    ) -> AgentReplyNotificationDecision {
        switch request.kind {
        case .reply:
            guard context.repliesEnabled else { return .noop(.disabled) }
        case .permission:
            guard context.permissionsEnabled else { return .noop(.kindDisabled) }
        }

        if context.seenEventIDs.contains(request.eventID) {
            return .noop(.duplicateEvent)
        }
        if context.isInspectingTask {
            return .noop(.inspecting)
        }
        guard context.authorizationGranted else {
            return .noop(.unauthorized)
        }

        let key = AgentReplyNotificationGraceKey(taskID: request.taskID, kind: request.kind)
        if let lastSuccess = context.lastSuccessAt[key],
           context.now.timeIntervalSince(lastSuccess) < context.graceInterval
        {
            return .grace
        }
        return .send
    }
}

enum AgentReplyNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// Runs an operation that may never answer, without trapping the caller.
///
/// Needed because `UNUserNotificationCenter.requestAuthorization` can hang
/// indefinitely on a build with no code-signing identity: the system neither
/// prompts the user nor invokes the completion handler. That call is awaited
/// from the terminal status event loop, so a hang there stops every later
/// status event for that session — the unread dot would appear once and never
/// again.
///
/// A task group is deliberately not used: it awaits its children at scope
/// exit, which would restore the hang. The stuck child is abandoned instead. It
/// keeps one continuation alive for the life of the process, which is the
/// lesser cost.
enum AbandonableRequest {
    static func result<Value: Sendable>(
        of operation: @Sendable @escaping () async -> Value,
        timeout: Duration,
        timedOut: Value
    ) async -> Value {
        let box = FirstResultBox<Value>()
        return await withCheckedContinuation { continuation in
            box.attach(continuation)
            Task { box.deliver(await operation()) }
            Task {
                try? await Task.sleep(for: timeout)
                box.deliver(timedOut)
            }
        }
    }
}

/// Resumes its continuation exactly once, whichever racer finishes first.
private final class FirstResultBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    func attach(_ continuation: CheckedContinuation<Value, Never>) {
        lock.lock()
        defer { lock.unlock() }
        self.continuation = continuation
    }

    func deliver(_ value: Value) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

enum AgentReplyNotificationPreferences {
    static let repliesEnabledKey = "agentReplyNotificationsEnabled"
    static let permissionsEnabledKey = "agentPermissionNotificationsEnabled"

    static func repliesEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(for: repliesEnabledKey, defaults: defaults)
    }

    static func permissionsEnabled(defaults: UserDefaults = .standard) -> Bool {
        bool(for: permissionsEnabledKey, defaults: defaults)
    }

    static func setRepliesEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: repliesEnabledKey)
    }

    static func setPermissionsEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: permissionsEnabledKey)
    }

    static func openSystemNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "org.niuzj.todoagent"
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }

    private static func bool(for key: String, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return true }
        return defaults.bool(forKey: key)
    }
}
