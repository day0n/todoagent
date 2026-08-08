import AppKit
import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()
    let client: EngineClient?
    let repository: any AppRepository
    let state: AppState

    private init() {
        do {
            let client = try EngineClient()
            let repository = EngineRepository(client: client)
            self.client = client
            self.repository = repository
            state = AppState(repository: repository)
        } catch {
            client = nil
            let repository = FailedRepository(message: error.localizedDescription)
            self.repository = repository
            state = AppState(repository: repository)
        }
    }
}

private actor FailedRepository: AppRepository {
    let message: String
    init(message: String) { self.message = message }
    private var failure: EngineClientError { .launchFailed(message) }
    func load() async throws -> AppSnapshot { throw failure }
    func sync() async throws -> AppSnapshot { throw failure }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot { throw failure }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot { throw failure }
    func detectRuntimes() async throws -> AppSnapshot { throw failure }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { throw failure }
    func session(taskID: UUID) async throws -> SessionBundle? { throw failure }
    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle { throw failure }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle { throw failure }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle { throw failure }
    func markRead(sessionID: String, through sequence: Int64) async throws { throw failure }
    func cancelTurn(sessionID: String) async throws { throw failure }
    func injectGeminiKey(_ key: String) async throws { throw failure }
    func shutdown() async {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await AppContainer.shared.state.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
