import Foundation
import Testing
@testable import TodoAgentApp

struct AgentReplyNotificationEvaluatorTests {
    @Test("status maps only attention states onto notification kinds", arguments: [
        (TerminalAgentStatus.completed, AgentReplyNotificationKind.reply),
        (.blocked, .permission),
    ])
    func attentionStatusMapsToKind(status: TerminalAgentStatus, kind: AgentReplyNotificationKind) {
        #expect(AgentReplyNotificationKind(status: status) == kind)
    }

    @Test("non-attention statuses do not notify", arguments: [
        TerminalAgentStatus.unknown,
        .idle,
        .active,
    ])
    func nonAttentionStatusHasNoKind(status: TerminalAgentStatus) {
        #expect(AgentReplyNotificationKind(status: status) == nil)
    }

    @Test(arguments: [
        EvaluateExample(
            name: "send reply",
            kind: .reply,
            expected: .send
        ),
        EvaluateExample(
            name: "send permission",
            kind: .permission,
            expected: .send
        ),
        EvaluateExample(
            name: "replies disabled",
            kind: .reply,
            repliesEnabled: false,
            expected: .noop(.disabled)
        ),
        EvaluateExample(
            name: "permission kind disabled",
            kind: .permission,
            permissionsEnabled: false,
            expected: .noop(.kindDisabled)
        ),
        EvaluateExample(
            name: "duplicate event",
            kind: .reply,
            seen: true,
            expected: .noop(.duplicateEvent)
        ),
        EvaluateExample(
            name: "inspecting task",
            kind: .reply,
            isInspectingTask: true,
            expected: .noop(.inspecting)
        ),
        EvaluateExample(
            name: "unauthorized",
            kind: .reply,
            authorizationGranted: false,
            expected: .noop(.unauthorized)
        ),
        EvaluateExample(
            name: "grace period",
            kind: .reply,
            inGrace: true,
            expected: .grace
        ),
        EvaluateExample(
            name: "inspecting wins over unauthorized",
            kind: .reply,
            authorizationGranted: false,
            isInspectingTask: true,
            expected: .noop(.inspecting)
        ),
        EvaluateExample(
            name: "disabled wins over inspecting",
            kind: .reply,
            repliesEnabled: false,
            isInspectingTask: true,
            expected: .noop(.disabled)
        ),
    ])
    func evaluate(_ example: EvaluateExample) {
        let request = example.request()
        let decision = AgentReplyNotificationEvaluator.evaluate(
            request,
            context: example.context(for: request)
        )
        #expect(decision == example.expected, Comment(rawValue: example.name))
    }

    @Test("missing preference keys default to enabled")
    func missingPreferenceKeysDefaultEnabled() throws {
        let (defaults, suite) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AgentReplyNotificationPreferences.repliesEnabled(defaults: defaults))
        #expect(AgentReplyNotificationPreferences.permissionsEnabled(defaults: defaults))

        AgentReplyNotificationPreferences.setRepliesEnabled(false, defaults: defaults)
        AgentReplyNotificationPreferences.setPermissionsEnabled(false, defaults: defaults)
        #expect(AgentReplyNotificationPreferences.repliesEnabled(defaults: defaults) == false)
        #expect(AgentReplyNotificationPreferences.permissionsEnabled(defaults: defaults) == false)
    }
}

/// Regression guard for the unread dot. `UNUserNotificationCenter.requestAuthorization`
/// never calls back on a build with no code-signing identity: the system neither
/// prompts nor answers. That request is awaited from the terminal status event
/// loop, which processes events one at a time — so an unbounded wait there
/// silently stops every later status event for that session, and the dot would
/// appear exactly once and never again.
struct AbandonableRequestTests {
    @Test("an operation that never answers still returns the timeout value")
    func givesUpOnAHang() async {
        let result = await AbandonableRequest.result(
            of: {
                try? await Task.sleep(for: .seconds(3_600))
                return "answered"
            },
            timeout: .milliseconds(50),
            timedOut: "gave-up"
        )

        #expect(result == "gave-up")
    }

    @Test("a fast answer is returned without waiting out the timeout")
    func doesNotDelayAFastAnswer() async {
        let clock = ContinuousClock()
        let started = clock.now
        let result = await AbandonableRequest.result(
            of: { "answered" },
            timeout: .seconds(30),
            timedOut: "gave-up"
        )

        #expect(result == "answered")
        // Must resolve on the operation's own schedule, not the deadline.
        #expect(clock.now - started < .seconds(5))
    }
}

struct EvaluateExample: Sendable, CustomTestStringConvertible {
    var testDescription: String { name }
    let name: String
    let kind: AgentReplyNotificationKind
    var repliesEnabled = true
    var permissionsEnabled = true
    var authorizationGranted = true
    var isInspectingTask = false
    var seen = false
    var inGrace = false
    let expected: AgentReplyNotificationDecision

    func request() -> AgentReplyNotificationRequest {
        AgentReplyNotificationRequest(
            eventID: "11111111-1111-4111-8111-111111111111",
            taskID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            taskTitle: "写周报",
            runtime: .claude,
            kind: kind
        )
    }

    func context(for request: AgentReplyNotificationRequest) -> AgentReplyNotificationContext {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var lastSuccessAt: [AgentReplyNotificationGraceKey: Date] = [:]
        if inGrace {
            lastSuccessAt[AgentReplyNotificationGraceKey(taskID: request.taskID, kind: request.kind)] =
                now.addingTimeInterval(-1)
        }
        return AgentReplyNotificationContext(
            repliesEnabled: repliesEnabled,
            permissionsEnabled: permissionsEnabled,
            authorizationGranted: authorizationGranted,
            isInspectingTask: isInspectingTask,
            seenEventIDs: seen ? [request.eventID] : [],
            lastSuccessAt: lastSuccessAt,
            now: now,
            graceInterval: AgentReplyNotificationContext.defaultGraceInterval
        )
    }
}

@MainActor
struct AgentReplyNotifierTests {
    @Test("a completed status delivers one reply notification")
    func completedStatusDeliversReply() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.router.titles[fixture.taskID] = "  写周报  "

        await fixture.notifier.consider(
            eventID: fixture.eventID,
            status: .completed,
            runtime: .claude,
            session: fixture.session
        )

        #expect(fixture.channel.delivered.count == 1)
        let delivered = try #require(fixture.channel.delivered.first)
        #expect(delivered.taskTitle == "写周报")
        #expect(delivered.runtime == .claude)
        #expect(delivered.kind == .reply)
        #expect(delivered.bodyMatchesKind)
    }

    @Test("active status is ignored")
    func activeStatusIsIgnored() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }

        await fixture.notifier.consider(
            eventID: fixture.eventID,
            status: .active,
            runtime: .claude,
            session: fixture.session
        )

        #expect(fixture.channel.delivered.isEmpty)
        #expect(fixture.channel.requestCount == 0)
    }

    @Test("duplicate event IDs are delivered once")
    func duplicateEventIDIsDeliveredOnce() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }

        await fixture.notifier.consider(fixture.request())
        await fixture.notifier.consider(fixture.request())

        #expect(fixture.channel.delivered.count == 1)
    }

    @Test("the same kind stays in grace for a second event")
    func sameKindIsSuppressedDuringGrace() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }

        await fixture.notifier.consider(fixture.request(eventID: "event-a"))
        await fixture.notifier.consider(fixture.request(eventID: "event-b"))

        #expect(fixture.channel.delivered.map(\.eventID) == ["event-a"])
    }

    @Test("a later event after grace expires is delivered")
    func eventAfterGraceExpiresIsDelivered() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }

        await fixture.notifier.consider(fixture.request(eventID: "event-a"))
        fixture.now.offset = 3
        await fixture.notifier.consider(fixture.request(eventID: "event-b"))

        #expect(fixture.channel.delivered.map(\.eventID) == ["event-a", "event-b"])
    }

    @Test("inspecting the task queues delivery and still requests authorization")
    func inspectingQueuesAndRequestsAuthorization() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.channel.authorization = .notDetermined
        fixture.channel.requestResult = .granted
        fixture.inspector.inspectingTaskID = fixture.taskID

        await fixture.notifier.consider(fixture.request())

        #expect(fixture.channel.delivered.isEmpty)
        #expect(fixture.channel.requestCount == 1)
    }

    @Test("leaving the inspected task delivers the queued reply")
    func flushAfterInspectingDeliversQueuedReply() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.inspector.inspectingTaskID = fixture.taskID

        await fixture.notifier.consider(fixture.request())
        #expect(fixture.channel.delivered.isEmpty)

        fixture.inspector.inspectingTaskID = nil
        await fixture.notifier.flushPendingIfUninspected()
        #expect(fixture.channel.delivered.map(\.eventID) == [fixture.eventID])
    }

    @Test("flush keeps a queued reply while the task is still inspected")
    func flushWhileInspectingKeepsQueue() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.inspector.inspectingTaskID = fixture.taskID

        await fixture.notifier.consider(fixture.request())
        await fixture.notifier.flushPendingIfUninspected()

        #expect(fixture.channel.delivered.isEmpty)
    }

    @Test("the first send requests authorization and then delivers")
    func firstSendRequestsAuthorizationThenDelivers() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.channel.authorization = .notDetermined
        fixture.channel.requestResult = .granted

        await fixture.notifier.consider(fixture.request())

        #expect(fixture.channel.requestCount == 1)
        #expect(fixture.channel.delivered.count == 1)
    }

    @Test("a denied authorization request does not deliver")
    func deniedAuthorizationDoesNotDeliver() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.channel.authorization = .notDetermined
        fixture.channel.requestResult = .denied

        await fixture.notifier.consider(fixture.request())

        #expect(fixture.channel.requestCount == 1)
        #expect(fixture.channel.delivered.isEmpty)
    }

    /// An unanswered request must be asked once and never again. Each attempt
    /// costs the full timeout, and the status event loop is sequential — asking
    /// per event would stall every later event behind it.
    @Test("an unanswered authorization request is not repeated for later events")
    func unansweredAuthorizationIsAskedOnce() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.channel.authorization = .notDetermined
        fixture.channel.requestResult = .notDetermined

        await fixture.notifier.consider(fixture.request(eventID: "event-a"))
        await fixture.notifier.consider(fixture.request(eventID: "event-b"))

        #expect(fixture.channel.requestCount == 1)
        #expect(fixture.channel.delivered.isEmpty)
    }

    /// The latch is on the request, not on authorization: a permission granted
    /// later in System Settings is picked up from the state read.
    @Test("a permission granted later is honoured without asking again")
    func laterGrantIsHonouredWithoutAsking() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.channel.authorization = .notDetermined
        fixture.channel.requestResult = .notDetermined

        await fixture.notifier.consider(fixture.request(eventID: "event-a"))
        #expect(fixture.channel.delivered.isEmpty)

        fixture.channel.authorization = .granted
        await fixture.notifier.consider(fixture.request(eventID: "event-b"))

        #expect(fixture.channel.requestCount == 1)
        #expect(fixture.channel.delivered.map(\.eventID) == ["event-b"])
    }

    @Test("clicking a notification opens the task after load")
    func clickOpensTaskWhenLoaded() throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.router.hasLoadedTasks = true

        fixture.notifier.handleNotificationOpen(taskID: fixture.taskID)

        #expect(fixture.router.opened == [fixture.taskID])
    }

    @Test("a click before load opens the task from pending")
    func clickBeforeLoadOpensFromPending() throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.router.hasLoadedTasks = false

        fixture.notifier.handleNotificationOpen(taskID: fixture.taskID)
        #expect(fixture.router.opened.isEmpty)

        fixture.router.hasLoadedTasks = true
        fixture.notifier.deliverPendingOpenIfNeeded()
        #expect(fixture.router.opened == [fixture.taskID])
    }

    @Test("an empty task title falls back to 任务")
    func emptyTitleFallsBack() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        fixture.router.titles[fixture.taskID] = "   "

        await fixture.notifier.consider(
            eventID: fixture.eventID,
            status: .blocked,
            runtime: .claude,
            session: fixture.session
        )

        #expect(fixture.channel.delivered.first?.taskTitle == "任务")
        #expect(fixture.channel.delivered.first?.kind == .permission)
    }

    @Test("disabled reply preferences do not deliver")
    func disabledRepliesDoNotDeliver() async throws {
        let fixture = try NotifierFixture()
        defer { fixture.cleanup() }
        AgentReplyNotificationPreferences.setRepliesEnabled(false, defaults: fixture.defaults)

        await fixture.notifier.consider(fixture.request())

        #expect(fixture.channel.delivered.isEmpty)
        #expect(fixture.channel.requestCount == 0)
    }
}

private extension AgentReplyNotificationRequest {
    var bodyMatchesKind: Bool { kind.body == (kind == .reply ? "有新回复" : "需要你确认权限") }
}

@MainActor
private final class RecordingAgentReplyChannel: AgentReplyNotificationDelivering {
    var authorization: AgentReplyNotificationAuthorization = .granted
    var requestResult: AgentReplyNotificationAuthorization = .granted
    var requestCount = 0
    private(set) var delivered: [AgentReplyNotificationRequest] = []

    func authorizationState() async -> AgentReplyNotificationAuthorization { authorization }

    func requestAuthorization() async -> AgentReplyNotificationAuthorization {
        requestCount += 1
        authorization = requestResult
        return requestResult
    }

    func deliver(_ request: AgentReplyNotificationRequest) async {
        delivered.append(request)
    }
}

@MainActor
private final class FakeAgentReplyInspector: AgentReplyNotificationInspecting {
    var inspectingTaskID: UUID?

    func isInspecting(taskID: UUID) -> Bool { inspectingTaskID == taskID }
}

@MainActor
private final class FakeAgentReplyRouter: AgentReplyNotificationRouting {
    var titles: [UUID: String] = [:]
    var hasLoadedTasks = true
    private(set) var opened: [UUID] = []

    func taskTitle(for taskID: UUID) -> String? { titles[taskID] }
    func openTask(id: UUID) { opened.append(id) }
}

@MainActor
private final class ControllableClock {
    var offset: TimeInterval = 0
    let origin = Date(timeIntervalSince1970: 1_700_000_000)

    var now: Date { origin.addingTimeInterval(offset) }
}

@MainActor
private struct NotifierFixture {
    let taskID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let eventID = "44444444-4444-4444-8444-444444444444"
    let defaults: UserDefaults
    let suite: String
    let channel: RecordingAgentReplyChannel
    let inspector: FakeAgentReplyInspector
    let router: FakeAgentReplyRouter
    let now: ControllableClock
    let notifier: AgentReplyNotifier
    let session: TerminalSessionDescriptor

    init() throws {
        suite = "AgentReplyNotifierTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        channel = RecordingAgentReplyChannel()
        inspector = FakeAgentReplyInspector()
        router = FakeAgentReplyRouter()
        now = ControllableClock()
        let clock = now
        notifier = AgentReplyNotifier(
            channel: channel,
            inspector: inspector,
            router: router,
            defaults: defaults,
            now: { clock.now }
        )
        session = TerminalSessionDescriptor(
            id: "session",
            taskID: taskID,
            runtimeKind: .claude,
            workingDirectory: "/tmp"
        )
    }

    func request(
        eventID: String? = nil,
        kind: AgentReplyNotificationKind = .reply
    ) -> AgentReplyNotificationRequest {
        AgentReplyNotificationRequest(
            eventID: eventID ?? self.eventID,
            taskID: taskID,
            taskTitle: "写周报",
            runtime: .claude,
            kind: kind
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private func isolatedDefaults() throws -> (UserDefaults, String) {
    let suite = "AgentReplyNotificationPreferencesTests.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}
