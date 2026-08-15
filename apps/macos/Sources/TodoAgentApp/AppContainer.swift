import AppKit
import Foundation

@MainActor
final class AppContainer {
    static let shared = AppContainer()
    let client: EngineClient?
    let repository: any AppRepository
    let state: AppState
    let terminalSessions: TerminalSessionRegistry
    let taskWorkspace: TaskWorkspaceCoordinator

    private init() {
        do {
            let client = try EngineClient()
            let repository = EngineRepository(client: client)
            self.client = client
            self.repository = repository
            state = AppState(
                repository: repository,
                inspectorPresented: UserDefaults.standard.bool(forKey: "showAssistantAtLaunch")
            )
            terminalSessions = TerminalSessionRegistry(
                repository: repository,
                surfaceFactory: GhosttyTerminalSurfaceFactory()
            )
            taskWorkspace = TaskWorkspaceCoordinator(
                state: state,
                terminalSessions: terminalSessions
            )
            state.taskWorkspacePresenter = taskWorkspace
            state.terminalSessions = terminalSessions
        } catch {
            client = nil
            let repository = FailedRepository(message: error.localizedDescription)
            self.repository = repository
            state = AppState(
                repository: repository,
                inspectorPresented: UserDefaults.standard.bool(forKey: "showAssistantAtLaunch")
            )
            terminalSessions = TerminalSessionRegistry(repository: repository)
            taskWorkspace = TaskWorkspaceCoordinator(
                state: state,
                terminalSessions: terminalSessions
            )
            state.taskWorkspacePresenter = taskWorkspace
            state.terminalSessions = terminalSessions
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
    func createList(name: String, color: String) async throws -> AppSnapshot { throw failure }
    func renameList(listID: UUID, name: String) async throws -> AppSnapshot { throw failure }
    func deleteList(listID: UUID) async throws -> AppSnapshot { throw failure }
    func createTask(title: String, note: String, listID: UUID?, executionDate: LocalDay?, dueDate: LocalDay?) async throws -> AppSnapshot { throw failure }
    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot { throw failure }
    func deleteTask(taskID: UUID) async throws -> AppSnapshot { throw failure }
    func createListFromTask(taskID: UUID) async throws -> AppSnapshot { throw failure }
    func addTaskAttachments(taskID: UUID, sourcePaths: [String], clientMutationID: UUID) async throws -> AppSnapshot { throw failure }
    func removeTaskAttachment(taskID: UUID, attachmentID: UUID, clientMutationID: UUID) async throws -> AppSnapshot { throw failure }
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
    func clearGeminiKey() async throws { throw failure }
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult { throw failure }
    func assistantStatus() async throws -> AssistantStatus { throw failure }
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] { throw failure }
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle { throw failure }
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle { throw failure }
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle { throw failure }
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle { throw failure }
    func sendAssistantMessage(sessionID: String, clientMessageID: UUID, text: String, model: String, attachments: [AssistantTextAttachment]) async throws -> AssistantSessionBundle { throw failure }
    func cancelAssistantTurn(sessionID: String) async throws { throw failure }
    func shutdown() async {}
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminationTask: Task<Void, Never>?
    private let inputFocusMonitor = WindowInputFocusMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        inputFocusMonitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputFocusMonitor.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }

        let activeSessions = AppContainer.shared.terminalSessions.activeCount
        if activeSessions > 0 {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "退出 TodoAgent？"
            alert.informativeText = "退出会结束 \(activeSessions) 个正在运行的本地 Session。"
            alert.addButton(withTitle: "退出并结束 Session")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }

        terminationTask = Task { @MainActor [weak self] in
            let canTerminate = await AppContainer.shared.state.shutdown()
            self?.terminationTask = nil
            sender.reply(toApplicationShouldTerminate: canTerminate)

            if !canTerminate {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "任务修改尚未保存"
                alert.informativeText = "TodoAgent 已取消退出并保留当前草稿。请返回任务详情重试保存，然后再次退出。"
                alert.addButton(withTitle: "返回任务")
                alert.runModal()
            }
        }
        return .terminateLater
    }
}
