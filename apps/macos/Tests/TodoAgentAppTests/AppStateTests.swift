import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Native task and session state")
@MainActor
struct AppStateTests {
    @Test("tasks only transition between open and completed")
    func completionLifecycle() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(task.status == .open)
        #expect(await state.setCompleted(task, completed: true))
        let completed = try #require(state.task(id: task.id))
        #expect(completed.status == .completed)
        #expect(await state.setCompleted(completed, completed: false))
        #expect(state.task(id: task.id)?.status == .open)
    }

    @Test("a task binds one runtime and working directory")
    func sessionConfiguration() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(state.session(for: task) == nil)
        #expect(await state.startSession(task, runtime: .kiro, workspace: "/tmp/project"))
        let session = try #require(state.session(for: task))
        #expect(session.runtimeKind == .kiro)
        #expect(session.workingDirectory == "/tmp/project")
        #expect(session.providerEngine == "v2")
    }

    @Test("composer sends into the bound logical session")
    func sessionMessage() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)
        #expect(await state.startSession(task, runtime: .codex, workspace: "/tmp/project"))
        #expect(await state.sendToSession(task, text: "继续检查测试"))
        let conversation = try #require(state.conversation(for: task))
        #expect(conversation.entries.last?.role == .user)
        #expect(conversation.entries.last?.body == "继续检查测试")
    }

    @Test("projection separates completion from active session state")
    func projectionCounts() {
        let now = Date(timeIntervalSince1970: 1_786_080_000)
        let task = TaskItem(id: UUID(), listID: nil, title: "任务", note: "", status: .open, dueDate: now, completedAt: nil, createdAt: now, updatedAt: "")
        let projection = TaskProjection(tasks: [task], now: now)
        let session = TaskSessionDescriptor(id: UUID().uuidString, taskID: task.id, runtimeKind: .claude, workingDirectory: "/tmp", providerSessionID: nil, providerEngine: nil, state: .running, lastAgentSequence: 3, lastReadSequence: 2, lastErrorCode: nil, lastErrorMessage: nil, createdAt: "", updatedAt: "")

        #expect(projection.count(for: .timeline, sessions: [session]) == 1)
        #expect(projection.count(for: .running, sessions: [session]) == 1)
        #expect(projection.count(for: .done, sessions: [session]) == 0)
        #expect(session.hasUnread)
    }
}
