import Foundation

enum TaskConversationRole: Equatable, Sendable { case system, agent, user, tool }

struct TaskConversationEntry: Identifiable, Sendable {
    let id: String
    let sequence: Int64
    let role: TaskConversationRole
    let kind: String
    let title: String?
    let body: String
    let payloadJSON: String?

    var isToolResult: Bool { role == .tool && kind == "tool_result" }

    var toolResultPresentation: TaskToolResultPresentation? {
        guard isToolResult else { return nil }
        return TaskToolResultPresentation(entry: self)
    }
}

struct TaskToolResultPresentation: Equatable, Sendable {
    let toolName: String
    let isFailure: Bool
    let contentByteCount: Int

    init(entry: TaskConversationEntry) {
        let payload = Self.metadata(from: entry.payloadJSON)
        let bodyMetadata = Self.metadata(from: entry.body)
        toolName = Self.metadataName(payload)
            ?? Self.metadataName(bodyMetadata)
            ?? Self.entryTitle(entry)
            ?? "工具"
        isFailure = Self.isFailure(
            payload: payload,
            bodyMetadata: bodyMetadata,
            body: entry.body
        )
        contentByteCount = entry.body.utf8.count
    }

    var statusTitle: String { isFailure ? "失败" : "成功" }

    var title: String {
        toolName == "工具" ? "tool_result" : "tool_result · \(toolName)"
    }

    var contentSizeTitle: String {
        switch contentByteCount {
        case 0 ..< 1_024:
            "\(contentByteCount) B"
        case 1_024 ..< 1_048_576:
            String(format: "%.1f KB", Double(contentByteCount) / 1_024)
        default:
            String(format: "%.1f MB", Double(contentByteCount) / 1_048_576)
        }
    }

    func subtitle(isExpanded: Bool) -> String {
        "\(statusTitle) · \(contentSizeTitle) · \(isExpanded ? "点击收起" : "点击展开")"
    }

    func accessibilityValue(isExpanded: Bool) -> String {
        isExpanded ? "已展开" : "已折叠"
    }

    private struct Metadata: Decodable {
        let name: String?
        let tool: String?
        let toolName: String?
        let status: String?
        let isError: Bool?
        let success: Bool?
        let error: JSONValue?

        private enum CodingKeys: String, CodingKey {
            case name, tool, status, isError, success, error
            case toolName = "tool_name"
        }
    }

    private static func metadata(from value: String?) -> Metadata? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Metadata.self, from: data)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func metadataName(_ metadata: Metadata?) -> String? {
        nonEmpty(metadata?.name)
            ?? nonEmpty(metadata?.tool)
            ?? nonEmpty(metadata?.toolName)
    }

    private static func entryTitle(_ entry: TaskConversationEntry) -> String? {
        guard let title = nonEmpty(entry.title), title != "tool_result" else { return nil }
        return title
    }

    private static func isFailure(
        payload: Metadata?,
        bodyMetadata: Metadata?,
        body: String
    ) -> Bool {
        let values = [payload, bodyMetadata].compactMap { $0 }
        if values.contains(where: { $0.isError == true || $0.success == false }) {
            return true
        }
        if values.contains(where: { metadata in
            guard let status = metadata.status?.lowercased() else { return false }
            return ["error", "failed", "failure", "cancelled", "interrupted"].contains(status)
        }) {
            return true
        }
        if values.contains(where: { metadata in
            guard let error = metadata.error else { return false }
            return error != .null
        }) {
            return true
        }

        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("error:")
            || normalized.hasPrefix("failed:")
            || normalized.hasPrefix("failure:")
            || normalized.hasPrefix("错误：")
            || normalized.hasPrefix("失败：")
    }
}

struct TaskToolResultDisclosureState: Equatable, Sendable {
    private(set) var expandedEntryIDs: Set<String> = []

    func isExpanded(entryID: String) -> Bool {
        expandedEntryIDs.contains(entryID)
    }

    mutating func toggle(entryID: String) {
        if expandedEntryIDs.contains(entryID) {
            expandedEntryIDs.remove(entryID)
        } else {
            expandedEntryIDs.insert(entryID)
        }
    }

    func visibleBody(for entry: TaskConversationEntry) -> String? {
        guard entry.isToolResult, isExpanded(entryID: entry.id) else { return nil }
        return entry.body
    }
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
                kind: message.kind,
                title: message.kind == "text" ? nil : message.kind,
                body: message.body,
                payloadJSON: message.payloadJSON
            )
        }
        latestSequence = bundle.messages.last?.sequence ?? 0
    }
}
