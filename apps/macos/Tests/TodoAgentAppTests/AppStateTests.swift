import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Native preview state")
struct AppStateTests {
    @Test("demo snapshot includes every human-facing task state")
    func demoStates() async throws {
        let snapshot = try await DemoRepository(now: Date(timeIntervalSince1970: 1_800_000_000)).load()
        let states = Set(snapshot.tasks.map(\.status))
        #expect(states == Set(TaskStatus.allCases))
    }

    @Test("human confirmation is the only transition from review to done")
    @MainActor
    func confirmation() async throws {
        let repository = DemoRepository()
        let state = AppState(repository: repository)
        await state.load()
        let review = try #require(state.tasks.first { $0.status == .review })

        let completed = await state.confirm(review)

        #expect(completed)
        #expect(state.task(id: review.id)?.status == .done)
    }

    @Test("tasks cannot bypass review and become done")
    @MainActor
    func confirmationRejectsTodo() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let todo = try #require(state.tasks.first { $0.status == .todo })

        let completed = await state.confirm(todo)

        #expect(completed == false)
        #expect(state.task(id: todo.id)?.status == .todo)
        #expect(state.errorMessage != nil)
    }

    @Test("repository load failures are visible to the user")
    @MainActor
    func loadFailureIsVisible() async {
        let state = AppState(repository: FailingRepository())

        await state.load()

        #expect(state.loadState == .failed("测试仓库不可用。"))
    }

    @Test("rapid task actions preserve the latest user intent")
    @MainActor
    func rapidActionsAreSerialized() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let todo = try #require(state.tasks.first { $0.status == .todo })

        let start = Task { @MainActor in await state.start(todo) }
        await Task.yield()
        let cancel = Task { @MainActor in await state.cancel(todo) }

        #expect(await start.value)
        #expect(await cancel.value)
        #expect(state.task(id: todo.id)?.status == .todo)
    }

    @Test("answer resumes a parked task")
    func answer() async throws {
        let repository = DemoRepository()
        let initial = try await repository.load()
        let parked = try #require(initial.tasks.first { $0.status == .needsYou })

        let resumed = try await repository.answer(taskID: parked.id, text: "只支持 Apple Silicon")
        let task = try #require(resumed.tasks.first { $0.id == parked.id })

        #expect(task.status == .running)
        #expect(task.needsText == nil)
        #expect(task.note.contains("Apple Silicon"))
    }

    @Test("task conversation keeps the complete CLI session context")
    func taskConversationContext() async throws {
        let snapshot = try await DemoRepository().load()
        let task = try #require(snapshot.tasks.first { $0.status == .needsYou })

        let session = DemoTaskConversation.snapshot(for: task)

        #expect(session.runtime == task.runtime)
        #expect(session.entries.contains { $0.role == .tool })
        #expect(session.entries.contains { $0.role == .user && $0.body == task.title })
        #expect(session.entries.last?.body == task.needsText)
    }

    @Test("a new task configures runtime and workspace before entering its session")
    @MainActor
    func configureTaskSession() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first { $0.runtime == nil && $0.status == .todo })

        #expect(state.session(for: task) == nil)
        #expect(await state.startSession(task, runtime: "Claude Code", workspace: "/tmp/project"))

        let refreshed = try #require(state.task(id: task.id))
        let session = try #require(state.session(for: refreshed))
        #expect(session.runtime == "Claude Code")
        #expect(session.workspace == "/tmp/project")
        #expect(refreshed.status == .running)
    }

    @Test("opening a task session clears its unread agent indicator")
    @MainActor
    func openingSessionClearsUnread() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first { $0.status == .needsYou })

        #expect(state.hasUnreadAgentMessage(for: task))
        state.openTask(task)
        #expect(!state.hasUnreadAgentMessage(for: task))
        #expect(state.presentedSheet == .taskSession(task.id))
    }

    @Test(
        "allowed task transitions",
        arguments: [
            Transition(from: .todo, to: .running),
            Transition(from: .running, to: .needsYou),
            Transition(from: .running, to: .review),
            Transition(from: .needsYou, to: .running),
            Transition(from: .review, to: .done),
            Transition(from: .done, to: .todo),
        ]
    )
    func allowedTransitions(_ transition: Transition) {
        #expect(throws: Never.self) {
            try TaskStateMachine.validate(from: transition.from, to: transition.to)
        }
    }

    @Test(
        "invalid task transitions",
        arguments: [
            Transition(from: .todo, to: .done),
            Transition(from: .running, to: .done),
            Transition(from: .needsYou, to: .done),
            Transition(from: .done, to: .running),
        ]
    )
    func invalidTransitions(_ transition: Transition) {
        #expect(throws: TaskTransitionError.invalid(from: transition.from, to: transition.to)) {
            try TaskStateMachine.validate(from: transition.from, to: transition.to)
        }
    }

    @Test("task projection groups the timeline in one pass")
    func timelineProjection() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = try await DemoRepository(now: now).load()
        let projection = TaskProjection(tasks: snapshot.tasks, now: now)
        let buckets = projection.timelineBuckets(selectedDate: Calendar.current.startOfDay(for: now))

        #expect(buckets[.today]?.count == 4)
        #expect(buckets[.dayAfter]?.count == 1)
        #expect(projection.count(for: TaskStatus.running) == 1)
        #expect(projection.count(for: TaskStatus.needsYou) == 1)
    }
}

struct Transition: Sendable, CustomTestStringConvertible {
    let from: TaskStatus
    let to: TaskStatus

    var testDescription: String { "\(from.rawValue) -> \(to.rawValue)" }
}

private enum TestRepositoryError: LocalizedError, Sendable {
    case unavailable

    var errorDescription: String? { "测试仓库不可用。" }
}

private actor FailingRepository: AppRepository {
    func load() async throws -> AppSnapshot { throw TestRepositoryError.unavailable }
    func createTask(title: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot {
        throw TestRepositoryError.unavailable
    }
    func setStatus(taskID: UUID, status: TaskStatus) async throws -> AppSnapshot {
        throw TestRepositoryError.unavailable
    }
    func answer(taskID: UUID, text: String) async throws -> AppSnapshot {
        throw TestRepositoryError.unavailable
    }
    func cancel(taskID: UUID) async throws -> AppSnapshot { throw TestRepositoryError.unavailable }
    func sendChat(_ text: String) async throws -> AppSnapshot { throw TestRepositoryError.unavailable }
}
