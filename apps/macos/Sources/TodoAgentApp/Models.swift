import Foundation

extension Calendar {
    /// TodoAgent stores civil dates as Gregorian `YYYY-MM-DD` values while
    /// still following the user's live system time zone. Never inherit the
    /// user's preferred calendar identifier (for example Buddhist or Japanese)
    /// for persistence or schedule projection.
    static var todoAgentLocal: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }
}

/// A calendar day without a time, time zone, or daylight-saving offset.
///
/// TodoAgent's task scheduling contract deliberately transports days as
/// `YYYY-MM-DD`. Keeping that value intact prevents a task from moving to an
/// adjacent column when the current time zone changes.
struct LocalDay: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init?(rawValue: String) {
        let pieces = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard
            pieces.count == 3,
            pieces[0].count == 4,
            pieces[1].count == 2,
            pieces[2].count == 2,
            let year = Int(pieces[0]),
            let month = Int(pieces[1]),
            let day = Int(pieces[2]),
            (1 ... 9999).contains(year),
            (1 ... 12).contains(month),
            (1 ... 31).contains(day)
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard
            let date = calendar.date(from: components),
            calendar.dateComponents([.year, .month, .day], from: date) ==
                DateComponents(year: year, month: month, day: day)
        else { return nil }

        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar = .todoAgentLocal) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        year = components.year ?? 1
        month = components.month ?? 1
        day = components.day ?? 1
    }

    init(date: Date, calendar: Calendar = .todoAgentLocal) {
        self.init(date, calendar: calendar)
    }

    var rawValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { rawValue }

    func date(in calendar: Calendar = .todoAgentLocal) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
            .map(calendar.startOfDay(for:))
    }

    func advanced(by days: Int, calendar: Calendar = .todoAgentLocal) -> LocalDay? {
        guard
            let date = date(in: calendar),
            let advanced = calendar.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return LocalDay(advanced, calendar: calendar)
    }

    static func today(now: Date = .now, calendar: Calendar = .todoAgentLocal) -> LocalDay {
        LocalDay(now, calendar: calendar)
    }

    static func < (lhs: LocalDay, rhs: LocalDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let day = LocalDay(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a real local day in YYYY-MM-DD format."
            )
        }
        self = day
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case open
    case completed

    var title: String { self == .open ? "未完成" : "已完成" }
}

enum RuntimeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claude, cursor, kiro

    var id: Self { self }
    var title: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude Code"
        case .cursor: "Cursor Agent"
        case .kiro: "Kiro CLI"
        }
    }
}

enum RuntimeAvailability: String, Codable, Sendable {
    case ready
    case authRequired = "auth_required"
    case detected
    case missing
    case error
}

struct RuntimeInfo: Identifiable, Codable, Equatable, Sendable {
    var id: RuntimeKind { kind }
    let kind: RuntimeKind
    let launchPath: String?
    let resolvedPath: String?
    let version: String?
    let status: RuntimeAvailability
    let authStatus: String
    let capabilities: [String: JSONValue]
    let providerEngine: String?
    let detectedAt: String?
    let verifiedAt: String?
    let verifyError: String?

    var isSelectable: Bool { status == .ready }
}

struct GeminiConnectionResult: Codable, Equatable, Sendable {
    let ok: Bool
    let model: String
    let displayName: String
    let version: String
}

// MARK: - TodoAgent Assistant IPC

/// The assistant owns its own state tree. None of these values are part of
/// `AppSnapshot`, which keeps high-frequency streaming updates from invalidating
/// the task board.
struct AssistantStatus: Codable, Equatable, Sendable {
    let configured: Bool
    let available: Bool
    let model: String?
    let reason: String?
}

struct AssistantSessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let archived: Bool
    let createdAt: String
    let updatedAt: String
    let lastSequence: Int64
    let isRunning: Bool
    /// Informational only. Each new turn may select a different model.
    let lastModel: String?

    init(
        id: String,
        title: String,
        archived: Bool = false,
        createdAt: String = "",
        updatedAt: String = "",
        lastSequence: Int64 = 0,
        isRunning: Bool = false,
        lastModel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.archived = archived
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSequence = lastSequence
        self.isRunning = isRunning
        self.lastModel = lastModel
    }

    var displayTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "新会话" : value
    }

    func updating(
        title: String? = nil,
        archived: Bool? = nil,
        lastSequence: Int64? = nil,
        isRunning: Bool? = nil,
        lastModel: String? = nil
    ) -> Self {
        Self(
            id: id,
            title: title ?? self.title,
            archived: archived ?? self.archived,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastSequence: lastSequence ?? self.lastSequence,
            isRunning: isRunning ?? self.isRunning,
            lastModel: lastModel ?? self.lastModel
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, archived, createdAt, updatedAt, lastSequence, isRunning, lastModel
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        lastSequence = try values.decodeIfPresent(Int64.self, forKey: .lastSequence) ?? 0
        isRunning = try values.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false
        lastModel = try values.decodeIfPresent(String.self, forKey: .lastModel)
    }
}

enum AssistantTurnStatus: String, Codable, Equatable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted

    var isRunning: Bool { self == .queued || self == .running }
}

struct AssistantTurn: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let clientMessageID: String?
    let model: String?
    let status: AssistantTurnStatus
    let errorCode: String?
    let errorMessage: String?
    let startedAt: String?
    let endedAt: String?

    init(
        id: String,
        sessionID: String,
        clientMessageID: String? = nil,
        model: String? = nil,
        status: AssistantTurnStatus,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        startedAt: String? = nil,
        endedAt: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.clientMessageID = clientMessageID
        self.model = model
        self.status = status
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case clientMessageID = "clientMessageId"
        case model, status, errorCode, errorMessage, startedAt, endedAt
    }
}

enum AssistantMessageRole: String, Codable, Equatable, Sendable {
    case user
    case todoAgent = "todoagent"
    case system
    case tool
}

struct AssistantMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let sequence: Int64
    let clientMessageID: String?
    let role: AssistantMessageRole
    let kind: String
    let body: String
    let payloadJSON: String?
    let taskReferences: [UUID]
    let createdAt: String
    let updatedAt: String

    init(
        id: String,
        sessionID: String,
        turnID: String? = nil,
        sequence: Int64,
        clientMessageID: String? = nil,
        role: AssistantMessageRole,
        kind: String = "text",
        body: String,
        payloadJSON: String? = nil,
        taskReferences: [UUID] = [],
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.clientMessageID = clientMessageID
        self.role = role
        self.kind = kind
        self.body = body
        self.payloadJSON = payloadJSON
        self.taskReferences = taskReferences
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case sequence
        case clientMessageID = "clientMessageId"
        case role, kind, body
        case payloadJSON = "payloadJson"
        case taskReferences, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decodeIfPresent(String.self, forKey: .turnID)
        sequence = try values.decode(Int64.self, forKey: .sequence)
        clientMessageID = try values.decodeIfPresent(String.self, forKey: .clientMessageID)
        role = try values.decode(AssistantMessageRole.self, forKey: .role)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "text"
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        payloadJSON = try values.decodeIfPresent(String.self, forKey: .payloadJSON)
        taskReferences = try values.decodeIfPresent([UUID].self, forKey: .taskReferences) ?? []
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    var textAttachments: [AssistantAttachmentSummary] {
        AssistantAttachmentPayload.decode(from: payloadJSON)
    }
}

struct AssistantTextAttachment: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let content: String
    let byteCount: Int
}

struct AssistantAttachmentSummary: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
    let byteCount: Int
}

private struct AssistantAttachmentPayload: Decodable {
    let attachments: [AssistantAttachmentSummary]

    static func decode(from payloadJSON: String?) -> [AssistantAttachmentSummary] {
        guard
            let payloadJSON,
            let data = payloadJSON.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Self.self, from: data)
        else { return [] }
        return payload.attachments
    }
}

struct AssistantSessionBundle: Codable, Equatable, Sendable {
    let session: AssistantSessionDescriptor
    let messages: [AssistantMessage]
    let tools: [AssistantPersistedTool]
    /// Ordered provider-neutral UI parts. `nil` means an older Engine that only
    /// supports the legacy messages/tools projection; an empty array is an
    /// authoritative empty Chat V2 history.
    let timeline: [SessionTimelineItem]?
    let activeTurn: AssistantTurn?

    init(
        session: AssistantSessionDescriptor,
        messages: [AssistantMessage] = [],
        tools: [AssistantPersistedTool] = [],
        timeline: [SessionTimelineItem]? = nil,
        activeTurn: AssistantTurn? = nil
    ) {
        self.session = session
        self.messages = messages
        self.tools = tools
        self.timeline = timeline
        self.activeTurn = activeTurn
    }

    private enum CodingKeys: String, CodingKey {
        case session, messages, tools, timeline, activeTurn
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(AssistantSessionDescriptor.self, forKey: .session)
        messages = try values.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? []
        tools = try values.decodeIfPresent([AssistantPersistedTool].self, forKey: .tools) ?? []
        timeline = try values.decodeIfPresent([SessionTimelineItem].self, forKey: .timeline)
        activeTurn = try values.decodeIfPresent(AssistantTurn.self, forKey: .activeTurn)
    }
}

/// Stable tool projection returned by `assistant.history`. Live tool events use
/// the smaller event DTOs below, while this record rebuilds the same UI after an
/// Engine or App restart.
struct AssistantPersistedTool: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let callID: String
    let toolName: String
    let taskRefsJSON: String?
    let isError: Bool
    let status: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case callID = "callId"
        case toolName, taskRefsJSON = "taskRefsJson", isError, status
    }

    var taskReferences: [UUID] {
        guard
            let taskRefsJSON,
            let data = taskRefsJSON.data(using: .utf8),
            let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return values.compactMap(UUID.init(uuidString:))
    }

    var activity: AssistantToolActivity? {
        guard let turnID else { return nil }
        let state: AssistantToolState = switch status {
        case "queued", "running": .running
        case "completed" where !isError: .completed
        default: .failed
        }
        return AssistantToolActivity(
            sessionID: sessionID,
            turnID: turnID,
            toolCallID: callID,
            name: toolName,
            state: state,
            taskReferences: taskReferences
        )
    }
}

struct AssistantStreamingDraft: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let messageID: String
    var attempt: Int
    var body: String
    var bodyUTF8ByteCount: Int

    init(
        sessionID: String,
        turnID: String,
        messageID: String,
        attempt: Int,
        body: String
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.messageID = messageID
        self.attempt = attempt
        self.body = AssistantLiveContentBounds.prefix(
            body,
            maxUTF8Bytes: AssistantLiveContentBounds.assistantTextBytes
        )
        bodyUTF8ByteCount = self.body.utf8.count
    }

    /// Builds a compatibility snapshot from the canonical live timeline
    /// without re-bounding or re-scanning its already bounded body.
    init(
        sessionID: String,
        turnID: String,
        messageID: String,
        attempt: Int,
        boundedBody: String,
        bodyUTF8ByteCount: Int
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.messageID = messageID
        self.attempt = attempt
        body = boundedBody
        self.bodyUTF8ByteCount = bodyUTF8ByteCount
    }
}

enum AssistantLiveContentBounds {
    static let assistantTextBytes = 1_048_576
    static let reasoningBytes = 262_144

    static func prefix(_ value: String, maxUTF8Bytes: Int) -> String {
        guard maxUTF8Bytes > 0 else { return "" }
        guard value.utf8.count > maxUTF8Bytes else { return value }
        var end = value.startIndex
        var byteCount = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let characterBytes = value[end ..< next].utf8.count
            guard byteCount + characterBytes <= maxUTF8Bytes else { break }
            byteCount += characterBytes
            end = next
        }
        return String(value[..<end])
    }

    static func appending(
        _ delta: String,
        to body: String,
        currentUTF8Bytes: Int,
        maxUTF8Bytes: Int
    ) -> (body: String, utf8Bytes: Int) {
        let remaining = max(0, maxUTF8Bytes - currentUTF8Bytes)
        guard remaining > 0, !delta.isEmpty else { return (body, currentUTF8Bytes) }
        let suffix = prefix(delta, maxUTF8Bytes: remaining)
        return (body + suffix, currentUTF8Bytes + suffix.utf8.count)
    }
}

enum AssistantToolState: Equatable, Sendable { case running, completed, failed }

struct AssistantToolActivity: Identifiable, Equatable, Sendable {
    var id: String { toolCallID }
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    var state: AssistantToolState
    var taskReferences: [UUID]
}

/// All tool activity produced by one assistant turn. The group keeps a stable
/// identity while individual tools move from running to completed, allowing the
/// compact transcript disclosure to preserve its local expansion state.
struct AssistantToolGroup: Identifiable, Equatable, Sendable {
    var id: String { "tool-group-\(turnID)" }
    let turnID: String
    var tools: [AssistantToolActivity]

    var isRunning: Bool {
        tools.contains(where: { $0.state == .running })
    }

    var hasFailure: Bool {
        tools.contains(where: { $0.state == .failed })
    }
}

/// One stable row in the TodoAgent conversation. Messages and tool activity
/// share a turn ID, so the UI can keep every tool beside the user request that
/// caused it instead of rendering a second tool list at the end of the chat.
enum AssistantConversationTimelineItem: Identifiable, Equatable, Sendable {
    case message(AssistantMessage)
    case toolGroup(AssistantToolGroup)

    var id: String {
        switch self {
        case let .message(message): "message-\(message.id)"
        case let .toolGroup(group): group.id
        }
    }

    var turnID: String? {
        switch self {
        case let .message(message): message.turnID
        case let .toolGroup(group): group.turnID
        }
    }
}

enum AssistantLoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

// MARK: Assistant request/response payloads

struct AssistantEmptyRequest: Encodable, Sendable {}
struct AssistantSessionListRequest: Encodable, Sendable { let includeArchived: Bool }
struct AssistantSessionCreateRequest: Encodable, Sendable { let title: String? }
struct AssistantSessionRenameRequest: Encodable, Sendable {
    let sessionID: String
    let title: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case title }
}
struct AssistantSessionArchiveRequest: Encodable, Sendable {
    let sessionID: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
}
struct AssistantHistoryRequest: Encodable, Sendable {
    let sessionID: String
    let afterSequence: Int64
    let limit: Int
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case afterSequence, limit
    }
}
struct AssistantSendRequest: Encodable, Sendable {
    let sessionID: String
    let clientMessageID: UUID
    let text: String
    let model: String
    let attachments: [AssistantTextAttachment]
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case clientMessageID = "clientMessageId"
        case text, model, attachments
    }
}
struct AssistantCancelTurnRequest: Encodable, Sendable {
    let sessionID: String
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
}

struct AssistantSessionListResponse: Decodable, Sendable { let sessions: [AssistantSessionDescriptor] }

/// Create/rename/archive may return either a descriptor or a complete bundle.
/// This one decoding boundary keeps the rest of the app independent of that
/// transport detail while Rust settles on its final response size.
struct AssistantSessionResponse: Decodable, Sendable {
    let bundle: AssistantSessionBundle

    private enum CodingKeys: String, CodingKey { case session, messages, tools, activeTurn }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bundle = try? value.decode(AssistantSessionBundle.self) {
            self.bundle = bundle
        } else if let session = try? value.decode(AssistantSessionDescriptor.self) {
            bundle = AssistantSessionBundle(session: session)
        } else {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let session = try values.decode(AssistantSessionDescriptor.self, forKey: .session)
            bundle = AssistantSessionBundle(
                session: session,
                messages: try values.decodeIfPresent([AssistantMessage].self, forKey: .messages) ?? [],
                tools: try values.decodeIfPresent([AssistantPersistedTool].self, forKey: .tools) ?? [],
                activeTurn: try values.decodeIfPresent(AssistantTurn.self, forKey: .activeTurn)
            )
        }
    }
}

// MARK: Assistant event payloads

struct AssistantSessionChangedEvent: Decodable, Sendable { let session: AssistantSessionDescriptor }
struct AssistantTurnEvent: Decodable, Sendable {
    let sessionID: String
    let turn: AssistantTurn
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case turn }
}
struct AssistantMessageDeltaEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let messageID: String
    let attempt: Int?
    let delta: String
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case messageID = "messageId"
        case attempt, delta
    }
}

struct AssistantThoughtSummaryEvent: Decodable, Equatable, Sendable {
    let sessionID: String
    let turnID: String
    /// Monotonic across the whole turn. Older Engines only send this field;
    /// newer Engines also expose the provider-local attempt for diagnostics.
    let attempt: Int
    let providerAttempt: Int?
    let interactionOrdinal: Int?
    let partID: String?
    let partOrdinal: Int?
    let isDelta: Bool?
    let originalBytes: Int?
    let truncated: Bool?
    let content: String

    var stableInteractionOrdinal: Int { interactionOrdinal ?? attempt }
    var stablePartIdentity: String {
        partID ?? "\(turnID)-\(stableInteractionOrdinal)-\(partOrdinal ?? 0)"
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case attempt, providerAttempt, interactionOrdinal
        case partID = "partId"
        case partOrdinal, isDelta, originalBytes, truncated, content
    }

    init(
        sessionID: String,
        turnID: String,
        attempt: Int,
        providerAttempt: Int? = nil,
        interactionOrdinal: Int? = nil,
        partID: String? = nil,
        partOrdinal: Int? = nil,
        isDelta: Bool? = nil,
        originalBytes: Int? = nil,
        truncated: Bool? = nil,
        content: String
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.attempt = attempt
        self.providerAttempt = providerAttempt
        self.interactionOrdinal = interactionOrdinal
        self.partID = partID
        self.partOrdinal = partOrdinal
        self.isDelta = isDelta
        self.originalBytes = originalBytes
        self.truncated = truncated
        self.content = content
    }

    func boundedForPresentation() -> Self {
        Self(
            sessionID: sessionID,
            turnID: turnID,
            attempt: attempt,
            providerAttempt: providerAttempt,
            interactionOrdinal: interactionOrdinal,
            partID: partID,
            partOrdinal: partOrdinal,
            isDelta: isDelta,
            originalBytes: originalBytes,
            truncated: truncated,
            content: AssistantLiveContentBounds.prefix(
                content,
                maxUTF8Bytes: AssistantLiveContentBounds.reasoningBytes
            )
        )
    }
}
struct AssistantMessageAppendedEvent: Decodable, Sendable {
    let sessionID: String
    let message: AssistantMessage
    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId"; case message }
}
struct AssistantToolStartedEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case toolCallID = "toolCallId"
        case name
    }
}
struct AssistantToolFinishedEvent: Decodable, Sendable {
    let sessionID: String
    let turnID: String
    let toolCallID: String
    let name: String
    let isError: Bool
    let taskReferences: [UUID]

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case toolCallID = "toolCallId"
        case name, isError, taskReferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decode(String.self, forKey: .turnID)
        toolCallID = try values.decode(String.self, forKey: .toolCallID)
        name = try values.decode(String.self, forKey: .name)
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError) ?? false
        taskReferences = try values.decodeIfPresent([UUID].self, forKey: .taskReferences) ?? []
    }
}

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([String: JSONValue].self) { self = .object(decoded) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .string(item): try value.encode(item)
        case let .number(item): try value.encode(item)
        case let .bool(item): try value.encode(item)
        case let .object(item): try value.encode(item)
        case let .array(item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
}

enum SessionState: String, Codable, Sendable {
    case idle, queued, running, failed, closed
    var isBusy: Bool { self == .queued || self == .running }
}

enum TerminalProviderBindingState: String, Codable, Sendable {
    case unbound
    case bound
    case captureFailed = "capture_failed"
}

enum TerminalAgentStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case idle
    case active
    case blocked
    case completed

    var isRunning: Bool { self == .active || self == .blocked }
    var needsAttention: Bool { self == .blocked || self == .completed }
}

enum TerminalRunLaunchMode: String, Codable, Sendable {
    case fresh
    case resume
}

enum TerminalLaunchIntent: String, Codable, Sendable {
    case auto
    case fresh
    case resume
}

enum TerminalRunState: String, Codable, Sendable {
    case starting
    case running
    case stopping
    case exited
    case failed
    case interrupted

    var isActive: Bool { self == .starting || self == .running || self == .stopping }
}

enum TerminalRunExitReason: String, Codable, Sendable {
    case processExit = "process_exit"
    case userEnded = "user_ended"
    case appShutdown = "app_shutdown"
    case launchFailed = "launch_failed"
}

enum TerminalProviderCaptureStrategy: String, Codable, Sendable {
    case sessionStartHook = "session_start_hook"
    case preallocated
    case createChat = "create_chat"
    case sessionStoreScan = "session_store_scan"
    case alreadyBound = "already_bound"
}

enum TurnStatus: String, Codable, Sendable {
    case queued, running, completed, failed, cancelled, interrupted
}

enum SessionMessageRole: String, Codable, Sendable {
    case user, agent, system, tool
}

struct TerminalSessionDescriptor: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: UUID
    let runtimeKind: RuntimeKind
    let workingDirectory: String
    let providerSessionID: String?
    let providerBindingState: TerminalProviderBindingState
    let providerBindingSource: String?
    let agentStatus: TerminalAgentStatus
    let hasActiveRun: Bool
    let statusSequence: Int64
    let seenStatusSequence: Int64
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let lastStartedAt: String?
    let lastExitedAt: String?
    let lastExitReason: String?
    let autoResume: Bool
    let createdAt: String
    let updatedAt: String

    var hasUnread: Bool { statusSequence > seenStatusSequence }
    var state: SessionState { hasActiveRun ? .running : .idle }
    var hasOfficialAgentRun: Bool { hasActiveRun || lastStartedAt != nil }
    var lastAgentSequence: Int64 { statusSequence }
    var lastReadSequence: Int64 { seenStatusSequence }
    var providerEngine: String? { nil }

    init(
        id: String,
        taskID: UUID,
        runtimeKind: RuntimeKind,
        workingDirectory: String,
        providerSessionID: String? = nil,
        providerBindingState: TerminalProviderBindingState = .unbound,
        providerBindingSource: String? = nil,
        agentStatus: TerminalAgentStatus = .unknown,
        hasActiveRun: Bool = false,
        statusSequence: Int64 = 0,
        seenStatusSequence: Int64 = 0,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil,
        lastStartedAt: String? = nil,
        lastExitedAt: String? = nil,
        lastExitReason: String? = nil,
        autoResume: Bool = false,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.taskID = taskID
        self.runtimeKind = runtimeKind
        self.workingDirectory = workingDirectory
        self.providerSessionID = providerSessionID
        self.providerBindingState = providerBindingState
        self.providerBindingSource = providerBindingSource
        self.agentStatus = agentStatus
        self.hasActiveRun = hasActiveRun
        self.statusSequence = statusSequence
        self.seenStatusSequence = seenStatusSequence
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
        self.lastStartedAt = lastStartedAt
        self.lastExitedAt = lastExitedAt
        self.lastExitReason = lastExitReason
        self.autoResume = autoResume
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Source compatibility for fixtures from the pre-terminal message renderer.
    init(
        id: String,
        taskID: UUID,
        runtimeKind: RuntimeKind,
        workingDirectory: String,
        providerSessionID: String?,
        providerEngine _: String?,
        state: SessionState,
        lastAgentSequence: Int64,
        lastReadSequence: Int64,
        lastErrorCode: String?,
        lastErrorMessage: String?,
        createdAt: String,
        updatedAt: String
    ) {
        self.init(
            id: id,
            taskID: taskID,
            runtimeKind: runtimeKind,
            workingDirectory: workingDirectory,
            providerSessionID: providerSessionID,
            providerBindingState: providerSessionID == nil ? .unbound : .bound,
            agentStatus: state.isBusy ? .active : .idle,
            hasActiveRun: state.isBusy,
            statusSequence: lastAgentSequence,
            seenStatusSequence: lastReadSequence,
            lastErrorCode: lastErrorCode,
            lastErrorMessage: lastErrorMessage,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID = "taskId"
        case runtimeKind, workingDirectory
        case providerSessionID = "providerSessionId"
        case providerBindingState, providerBindingSource, agentStatus, hasActiveRun
        case statusSequence, seenStatusSequence
        case lastErrorCode, lastErrorMessage, lastStartedAt, lastExitedAt
        case lastExitReason, autoResume
        case createdAt, updatedAt
        case providerEngine, state, lastAgentSequence, lastReadSequence
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        taskID = try values.decode(UUID.self, forKey: .taskID)
        runtimeKind = try values.decode(RuntimeKind.self, forKey: .runtimeKind)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        providerSessionID = try values.decodeIfPresent(String.self, forKey: .providerSessionID)
        providerBindingState = try values.decodeIfPresent(
            TerminalProviderBindingState.self,
            forKey: .providerBindingState
        ) ?? (providerSessionID == nil ? .unbound : .bound)
        providerBindingSource = try values.decodeIfPresent(String.self, forKey: .providerBindingSource)
        let legacyState = try values.decodeIfPresent(SessionState.self, forKey: .state)
        agentStatus = try values.decodeIfPresent(TerminalAgentStatus.self, forKey: .agentStatus)
            ?? (legacyState?.isBusy == true ? .active : .idle)
        hasActiveRun = try values.decodeIfPresent(Bool.self, forKey: .hasActiveRun)
            ?? legacyState?.isBusy
            ?? false
        statusSequence = try values.decodeIfPresent(Int64.self, forKey: .statusSequence)
            ?? values.decodeIfPresent(Int64.self, forKey: .lastAgentSequence)
            ?? 0
        seenStatusSequence = try values.decodeIfPresent(Int64.self, forKey: .seenStatusSequence)
            ?? values.decodeIfPresent(Int64.self, forKey: .lastReadSequence)
            ?? 0
        lastErrorCode = try values.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorMessage = try values.decodeIfPresent(String.self, forKey: .lastErrorMessage)
        lastStartedAt = try values.decodeIfPresent(String.self, forKey: .lastStartedAt)
        lastExitedAt = try values.decodeIfPresent(String.self, forKey: .lastExitedAt)
        lastExitReason = try values.decodeIfPresent(String.self, forKey: .lastExitReason)
        autoResume = try values.decodeIfPresent(Bool.self, forKey: .autoResume) ?? false
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(taskID, forKey: .taskID)
        try values.encode(runtimeKind, forKey: .runtimeKind)
        try values.encode(workingDirectory, forKey: .workingDirectory)
        try values.encodeIfPresent(providerSessionID, forKey: .providerSessionID)
        try values.encode(providerBindingState, forKey: .providerBindingState)
        try values.encodeIfPresent(providerBindingSource, forKey: .providerBindingSource)
        try values.encode(agentStatus, forKey: .agentStatus)
        try values.encode(hasActiveRun, forKey: .hasActiveRun)
        try values.encode(statusSequence, forKey: .statusSequence)
        try values.encode(seenStatusSequence, forKey: .seenStatusSequence)
        try values.encodeIfPresent(lastErrorCode, forKey: .lastErrorCode)
        try values.encodeIfPresent(lastErrorMessage, forKey: .lastErrorMessage)
        try values.encodeIfPresent(lastStartedAt, forKey: .lastStartedAt)
        try values.encodeIfPresent(lastExitedAt, forKey: .lastExitedAt)
        try values.encodeIfPresent(lastExitReason, forKey: .lastExitReason)
        try values.encode(autoResume, forKey: .autoResume)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }
}

typealias TaskSessionDescriptor = TerminalSessionDescriptor

struct TerminalRun: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let ordinal: Int64
    let launchMode: TerminalRunLaunchMode
    let state: TerminalRunState
    let providerSessionIDAtLaunch: String?
    let exitCode: Int32?
    let exitReason: TerminalRunExitReason?
    let errorCode: String?
    let errorMessage: String?
    let startedAt: String?
    let exitedAt: String?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case ordinal, launchMode, state
        case providerSessionIDAtLaunch = "providerSessionIdAtLaunch"
        case exitCode, exitReason, errorCode, errorMessage, startedAt, exitedAt, createdAt
    }
}

struct TerminalSessionBundle: Codable, Equatable, Sendable {
    let session: TerminalSessionDescriptor
    let activeRun: TerminalRun?
}

struct TerminalSessionDeletedEvent: Codable, Equatable, Sendable {
    let sessionID: String
    let taskID: UUID

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case taskID = "taskId"
    }
}

struct TerminalResumeCandidate: Identifiable, Codable, Equatable, Sendable {
    let providerSessionID: String
    let source: String
    let createdAt: String?

    var id: String { providerSessionID }

    private enum CodingKeys: String, CodingKey {
        case providerSessionID = "providerSessionId"
        case source, createdAt
    }
}

struct TerminalResumeCandidates: Codable, Equatable, Sendable {
    let session: TerminalSessionDescriptor
    let candidates: [TerminalResumeCandidate]
}

struct TerminalLaunchPlan: Codable, Equatable, Sendable {
    let session: TerminalSessionDescriptor
    let run: TerminalRun
    let executable: String
    let arguments: [String]
    let workingDirectory: String
    let environment: [String: String]
    let captureStrategy: TerminalProviderCaptureStrategy
}

struct SessionTurn: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let ordinal: Int64
    let userMessageID: String
    let providerSessionIDBefore: String?
    let providerSessionIDAfter: String?
    let status: TurnStatus
    let exitCode: Int?
    let finalOutput: String?
    let errorCode: String?
    let errorMessage: String?
    let providerUsageJSON: String?
    let startedAt: String?
    let endedAt: String?
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case ordinal
        case userMessageID = "userMessageId"
        case providerSessionIDBefore = "providerSessionIdBefore"
        case providerSessionIDAfter = "providerSessionIdAfter"
        case status, exitCode, finalOutput, errorCode, errorMessage
        case providerUsageJSON = "providerUsageJson"
        case startedAt, endedAt, createdAt
    }
}

struct SessionMessage: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String?
    let sequence: Int64
    let clientMessageID: String?
    let role: SessionMessageRole
    let kind: String
    let body: String
    let payloadJSON: String?
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case sequence
        case clientMessageID = "clientMessageId"
        case role, kind, body
        case payloadJSON = "payloadJson"
        case createdAt, updatedAt
    }
}

struct SessionBundle: Codable, Equatable, Sendable {
    let session: TaskSessionDescriptor
    let messages: [SessionMessage]
    let activeTurn: SessionTurn?
}

enum AppLoadState: Equatable, Sendable { case loading, loaded, failed(String) }

enum AppSheet: Identifiable, Equatable, Sendable {
    case taskSession(UUID)
    var id: String {
        switch self {
        case let .taskSession(id): "task-session-\(id)"
        }
    }
}

struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var listID: UUID?
    var title: String
    var note: String
    var status: TaskStatus
    var executionDate: LocalDay?
    var dueDate: LocalDay?
    var attachments: [TaskAttachment]
    var completedAt: String?
    let createdAt: Date
    var updatedAt: String

    init(
        id: UUID,
        listID: UUID?,
        title: String,
        note: String,
        status: TaskStatus,
        executionDate: LocalDay? = nil,
        dueDate: LocalDay? = nil,
        attachments: [TaskAttachment] = [],
        completedAt: String?,
        createdAt: Date,
        updatedAt: String
    ) {
        self.id = id
        self.listID = listID
        self.title = title
        self.note = note
        self.status = status
        self.executionDate = executionDate
        self.dueDate = dueDate
        self.attachments = attachments
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case listID = "listId"
        case title, note, status, executionDate, dueDate, completedAt, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        listID = try values.decodeIfPresent(UUID.self, forKey: .listID)
        title = try values.decode(String.self, forKey: .title)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        status = try values.decode(TaskStatus.self, forKey: .status)
        executionDate = try values.decodeIfPresent(LocalDay.self, forKey: .executionDate)
        dueDate = try values.decodeIfPresent(LocalDay.self, forKey: .dueDate)
        attachments = []
        completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(listID, forKey: .listID)
        try values.encode(title, forKey: .title)
        try values.encode(note, forKey: .note)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(executionDate, forKey: .executionDate)
        try values.encodeIfPresent(dueDate, forKey: .dueDate)
        try values.encodeIfPresent(completedAt, forKey: .completedAt)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    func isDueDateOverdue(on today: LocalDay = .today()) -> Bool {
        status == .open && dueDate.map { $0 < today } == true
    }

    /// A task is overdue only when its deadline has passed. `executionDate`
    /// selects whether a task appears in Today and is not a deadline.
    func isOverdue(on today: LocalDay = .today()) -> Bool {
        isDueDateOverdue(on: today)
    }

    func cardDatePresentation(on today: LocalDay = .today()) -> TaskCardDatePresentation? {
        let candidates = [
            dueDate.map {
                TaskCardDatePresentation(
                    kind: .due,
                    day: $0,
                    isOverdue: isDueDateOverdue(on: today)
                )
            },
            executionDate.map {
                TaskCardDatePresentation(
                    kind: .execution,
                    day: $0,
                    isOverdue: false
                )
            },
        ].compactMap { $0 }

        return candidates.first(where: \.isOverdue) ?? candidates.first
    }
}

enum TaskCardDateKind: String, Equatable, Sendable {
    case execution
    case due
}

struct TaskCardDatePresentation: Equatable, Sendable {
    let kind: TaskCardDateKind
    let day: LocalDay
    let isOverdue: Bool
}

struct TaskAttachment: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let taskID: UUID
    let originalName: String
    let sizeBytes: Int64
    let mimeType: String
    let relativePath: String
    let createdAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case taskID = "taskId"
        case originalName, sizeBytes, mimeType, relativePath, createdAt
    }

    /// Resolves the Engine-managed copy from the same data root selection used
    /// by the Rust process. Attachment metadata is intentionally restricted to
    /// exactly `Attachments/<safe leaf>` before it becomes a local file URL.
    func managedURL(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard
            components.count == 2,
            components[0] == "Attachments"
        else { return nil }

        let leaf = String(components[1])
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("\0") else {
            return nil
        }

        let root: URL
        if let configuredRoot = environment["TODOAGENT_NATIVE_DATA_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredRoot.isEmpty {
            root = URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL
        } else {
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            root = applicationSupport
                .appendingPathComponent("TodoAgent", isDirectory: true)
                .standardizedFileURL
        }

        let attachmentsRoot = root
            .appendingPathComponent("Attachments", isDirectory: true)
            .standardizedFileURL
        let candidate = attachmentsRoot
            .appendingPathComponent(leaf, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == attachmentsRoot else { return nil }
        return candidate
    }
}

extension TaskItem {
    mutating func apply(_ patch: TaskPatch) {
        if let title = patch.title { self.title = title }
        if let note = patch.note { self.note = note }
        if let status = patch.status {
            self.status = status
            completedAt = status == .completed
                ? completedAt ?? ISO8601DateFormatter().string(from: .now)
                : nil
        }
        switch patch.listID {
        case .unchanged: break
        case let .set(value): listID = value
        case .clear: listID = nil
        }
        switch patch.executionDate {
        case .unchanged: break
        case let .set(value): executionDate = value
        case .clear: executionDate = nil
        }
        switch patch.dueDate {
        case .unchanged: break
        case let .set(value): dueDate = value
        case .clear: dueDate = nil
        }
    }
}

enum TaskPatchField<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case set(Value)
    case clear
}

/// A tri-state task patch. `.unchanged` omits a key from JSON while `.clear`
/// emits an explicit `null`; this distinction is part of IPC v4.
struct TaskPatch: Encodable, Equatable, Sendable {
    var title: String?
    var note: String?
    var status: TaskStatus?
    var listID: TaskPatchField<UUID>
    var executionDate: TaskPatchField<LocalDay>
    var dueDate: TaskPatchField<LocalDay>

    init(
        title: String? = nil,
        note: String? = nil,
        status: TaskStatus? = nil,
        listID: TaskPatchField<UUID> = .unchanged,
        executionDate: TaskPatchField<LocalDay> = .unchanged,
        dueDate: TaskPatchField<LocalDay> = .unchanged
    ) {
        self.title = title
        self.note = note
        self.status = status
        self.listID = listID
        self.executionDate = executionDate
        self.dueDate = dueDate
    }

    var isEmpty: Bool {
        title == nil && note == nil && status == nil && listID == .unchanged &&
            executionDate == .unchanged && dueDate == .unchanged
    }

    func merging(_ newer: TaskPatch) -> TaskPatch {
        TaskPatch(
            title: newer.title ?? title,
            note: newer.note ?? note,
            status: newer.status ?? status,
            listID: newer.listID == .unchanged ? listID : newer.listID,
            executionDate: newer.executionDate == .unchanged ? executionDate : newer.executionDate,
            dueDate: newer.dueDate == .unchanged ? dueDate : newer.dueDate
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title, note, status
        case listID = "listId"
        case executionDate, dueDate
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(note, forKey: .note)
        try values.encodeIfPresent(status, forKey: .status)
        try Self.encode(listID, forKey: .listID, into: &values)
        try Self.encode(executionDate, forKey: .executionDate, into: &values)
        try Self.encode(dueDate, forKey: .dueDate, into: &values)
    }

    private static func encode<Value: Encodable & Equatable & Sendable>(
        _ field: TaskPatchField<Value>,
        forKey key: CodingKeys,
        into values: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch field {
        case .unchanged: break
        case let .set(value): try values.encode(value, forKey: key)
        case .clear: try values.encodeNil(forKey: key)
        }
    }
}

enum TaskSaveState: Equatable, Sendable {
    case idle
    case debouncing
    case saving
    case failed(String)
}

struct TodoList: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var colorName: String
    var repositoryPath: String?
}

enum SmartView: String, CaseIterable, Identifiable, Sendable {
    case myDay, tasks, running, done
    var id: Self { self }
    var title: String {
        switch self { case .myDay: "今天"; case .tasks: "任务"; case .running: "进行中"; case .done: "已完成" }
    }
    var symbol: String {
        switch self { case .myDay: "sun.max"; case .tasks: "checklist"; case .running: "circle.dotted.circle"; case .done: "checkmark.circle" }
    }
}

enum SidebarSelection: Hashable, Sendable { case smart(SmartView), list(UUID) }

struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable { case user, todoAgent }
    let id: UUID
    let role: Role
    let body: String
    let createdAt: Date
    var taskReference: UUID?
}

struct AppSnapshot: Codable, Equatable, Sendable {
    var revision: Int64
    var lists: [TodoList]
    var tasks: [TaskItem]
    var runtimes: [RuntimeInfo]
    var sessions: [TaskSessionDescriptor]
    var messages: [ChatMessage]
}
