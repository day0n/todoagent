import Foundation

enum TaskConversationRole: Equatable, Sendable { case system, agent, user, tool }

struct TaskConversationEntry: Identifiable, Sendable {
    let id: String
    let sequence: Int64
    let role: TaskConversationRole
    let title: String?
    let body: String
}

struct TaskConversationSnapshot: Sendable {
    let sessionID: String
    let runtime: RuntimeKind
    let workspace: String
    let state: SessionState
    let entries: [TaskConversationEntry]
    let latestSequence: Int64

    init(bundle: SessionBundle) {
        sessionID = bundle.session.id
        runtime = bundle.session.runtimeKind
        workspace = bundle.session.workingDirectory
        state = bundle.session.state
        entries = bundle.messages.map { message in
            let role: TaskConversationRole = switch message.role {
            case .system: .system
            case .agent: .agent
            case .user: .user
            case .tool: .tool
            }
            return TaskConversationEntry(
                id: message.id,
                sequence: message.sequence,
                role: role,
                title: message.kind == "text" ? nil : message.kind,
                body: message.body
            )
        }
        latestSequence = bundle.messages.last?.sequence ?? 0
    }
}
