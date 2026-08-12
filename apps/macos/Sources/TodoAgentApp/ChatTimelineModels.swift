import Foundation

// MARK: - Engine Chat V2 DTOs

/// Provider-neutral timeline item returned by the optional `session.timeline`
/// Engine capability. This DTO deliberately mirrors the additive Engine API so
/// older engines can continue to use `SessionMessage` through the legacy
/// projection in `ChatTranscriptProjection`.
struct SessionTimelineItem: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let sequence: Int64
    let turnOrdinal: Int64
    let itemOrdinal: Int64
    let kind: String
    let body: String
    let callID: String?
    let toolName: String?
    let inputJSON: String?
    let outputText: String?
    let toolState: String?
    let isError: Bool
    let sourceEventSequence: Int64?
    let sourceBlockIndex: Int64?
    let fidelity: String
    let metadataJSON: String?
    let createdAt: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "sessionId"
        case turnID = "turnId"
        case sequence, turnOrdinal, itemOrdinal, kind, body
        case callID = "callId"
        case toolName
        case inputJSON = "inputJson"
        case outputText, toolState, isError, sourceEventSequence, sourceBlockIndex, fidelity
        case metadataJSON = "metadataJson"
        case createdAt, updatedAt
    }

    init(
        id: String,
        sessionID: String,
        turnID: String,
        sequence: Int64,
        turnOrdinal: Int64,
        itemOrdinal: Int64,
        kind: String,
        body: String = "",
        callID: String? = nil,
        toolName: String? = nil,
        inputJSON: String? = nil,
        outputText: String? = nil,
        toolState: String? = nil,
        isError: Bool = false,
        sourceEventSequence: Int64? = nil,
        sourceBlockIndex: Int64? = nil,
        fidelity: String = "exact",
        metadataJSON: String? = nil,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID
        self.sequence = sequence
        self.turnOrdinal = turnOrdinal
        self.itemOrdinal = itemOrdinal
        self.kind = kind
        self.body = body
        self.callID = callID
        self.toolName = toolName
        self.inputJSON = inputJSON
        self.outputText = outputText
        self.toolState = toolState
        self.isError = isError
        self.sourceEventSequence = sourceEventSequence
        self.sourceBlockIndex = sourceBlockIndex
        self.fidelity = fidelity
        self.metadataJSON = metadataJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct SessionTimelineCursor: Codable, Equatable, Hashable, Sendable {
    let turnOrdinal: Int64
    let itemOrdinal: Int64
}

struct SessionTimelinePage: Codable, Equatable, Sendable {
    let session: TaskSessionDescriptor
    let items: [SessionTimelineItem]
    let activeTurn: SessionTurn?
    let nextSequence: Int64
    let nextCursor: SessionTimelineCursor?
    let hasMore: Bool
    let fidelity: String

    private enum CodingKeys: String, CodingKey {
        case session, items, activeTurn, nextSequence, nextCursor, hasMore, fidelity
    }

    init(
        session: TaskSessionDescriptor,
        items: [SessionTimelineItem],
        activeTurn: SessionTurn?,
        nextSequence: Int64,
        nextCursor: SessionTimelineCursor? = nil,
        hasMore: Bool = false,
        fidelity: String
    ) {
        self.session = session
        self.items = items
        self.activeTurn = activeTurn
        self.nextSequence = nextSequence
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.fidelity = fidelity
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        session = try values.decode(TaskSessionDescriptor.self, forKey: .session)
        items = try values.decodeIfPresent([SessionTimelineItem].self, forKey: .items) ?? []
        activeTurn = try values.decodeIfPresent(SessionTurn.self, forKey: .activeTurn)
        nextSequence = try values.decodeIfPresent(Int64.self, forKey: .nextSequence) ?? 0
        nextCursor = try values.decodeIfPresent(SessionTimelineCursor.self, forKey: .nextCursor)
        hasMore = try values.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        fidelity = try values.decodeIfPresent(String.self, forKey: .fidelity) ?? "legacy"
    }
}

struct SessionTimelineTurnFinishedEvent: Codable, Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let fidelity: String
    /// New Engines include terminal mutations for immediate UI convergence.
    /// They are not a complete turn: every finish still schedules a coalesced,
    /// turn-scoped authoritative reconciliation because the live event buffer
    /// may have dropped earlier text, reasoning, or tool events.
    let items: [SessionTimelineItem]?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case turnID = "turnId"
        case fidelity, items
    }

    init(
        sessionID: String,
        turnID: String,
        fidelity: String,
        items: [SessionTimelineItem]? = nil
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.fidelity = fidelity
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try values.decode(String.self, forKey: .sessionID)
        turnID = try values.decode(String.self, forKey: .turnID)
        fidelity = try values.decodeIfPresent(String.self, forKey: .fidelity) ?? "committed"
        items = try values.decodeIfPresent([SessionTimelineItem].self, forKey: .items)
    }
}

struct ChatTimelineHydrationBudget: Equatable, Sendable {
    let maximumItemCount: Int
    let maximumUTF8Bytes: Int

    static let sessionHistory = Self(
        maximumItemCount: 12_000,
        maximumUTF8Bytes: 32 * 1_048_576
    )
    static let singleTurn = Self(
        maximumItemCount: 4_000,
        maximumUTF8Bytes: 16 * 1_048_576
    )
}

struct ChatTimelineHydrationAccumulator: Sendable {
    let budget: ChatTimelineHydrationBudget
    private(set) var items: [SessionTimelineItem] = []
    private(set) var utf8ByteCount = 0
    private(set) var reachedLimit = false

    mutating func appendPage(_ pageItems: [SessionTimelineItem]) {
        for item in pageItems {
            items.append(item)
            utf8ByteCount += Self.presentationUTF8ByteCount(item)
        }
        trimOldestTurnsIfNeeded()
    }

    private mutating func trimOldestTurnsIfNeeded() {
        guard items.count > budget.maximumItemCount
                || utf8ByteCount > budget.maximumUTF8Bytes
        else { return }
        reachedLimit = true

        var removalCount = 0
        var removedBytes = 0
        while removalCount < items.count {
            let turnID = items[removalCount].turnID
            repeat {
                removedBytes += Self.presentationUTF8ByteCount(items[removalCount])
                removalCount += 1
            } while removalCount < items.count && items[removalCount].turnID == turnID

            let retainedCount = items.count - removalCount
            let retainedBytes = utf8ByteCount - removedBytes
            if retainedCount <= budget.maximumItemCount,
               retainedBytes <= budget.maximumUTF8Bytes {
                break
            }
        }

        if removalCount == items.count {
            // A pathological single turn may exceed a test/client budget.
            // Retain its newest suffix; normal Engine turns are independently
            // bounded, so production history usually takes the whole-turn path.
            removalCount = 0
            removedBytes = 0
            while items.count - removalCount > 1 {
                let retainedCount = items.count - removalCount
                let retainedBytes = utf8ByteCount - removedBytes
                guard retainedCount > budget.maximumItemCount
                        || retainedBytes > budget.maximumUTF8Bytes
                else { break }
                removedBytes += Self.presentationUTF8ByteCount(items[removalCount])
                removalCount += 1
            }
        }
        guard removalCount > 0 else { return }
        items.removeFirst(removalCount)
        utf8ByteCount -= removedBytes
    }

    static func presentationUTF8ByteCount(_ item: SessionTimelineItem) -> Int {
        var total = item.id.utf8.count
        total += item.turnID.utf8.count
        total += item.body.utf8.count
        total += item.callID?.utf8.count ?? 0
        total += item.toolName?.utf8.count ?? 0
        total += item.inputJSON?.utf8.count ?? 0
        total += item.outputText?.utf8.count ?? 0
        total += item.metadataJSON?.utf8.count ?? 0
        return total
    }
}

struct AssistantHistoryHydrationAccumulator: Sendable {
    let budget: ChatTimelineHydrationBudget
    private(set) var itemCount = 0
    private(set) var utf8ByteCount = 0
    private(set) var reachedLimit = false

    init(budget: ChatTimelineHydrationBudget) {
        self.budget = budget
    }

    mutating func retainNewestTurns(
        in bundle: AssistantSessionBundle
    ) -> AssistantHistoryHydrationResult {
        struct TurnCost {
            var itemCount = 0
            var utf8Bytes = 0
        }

        func turnKey(_ turnID: String?) -> String? {
            turnID.map { "turn:\($0)" }
        }
        func messageKey(_ message: AssistantMessage) -> String {
            turnKey(message.turnID) ?? "message:\(message.id)"
        }
        func toolKey(_ tool: AssistantPersistedTool) -> String {
            turnKey(tool.turnID) ?? "tool:\(tool.id)"
        }
        func timelineKey(_ item: SessionTimelineItem) -> String {
            "turn:\(item.turnID)"
        }

        var orderedKeys: [String] = []
        var costs: [String: TurnCost] = [:]
        func remember(_ key: String, itemBytes: Int) {
            if costs[key] == nil { orderedKeys.append(key) }
            var cost = costs[key] ?? TurnCost()
            cost.itemCount += 1
            cost.utf8Bytes += itemBytes
            costs[key] = cost
        }

        if let timeline = bundle.timeline {
            for item in timeline.sorted(by: Self.timelineOrderedBefore) {
                remember(
                    timelineKey(item),
                    itemBytes: ChatTimelineHydrationAccumulator.presentationUTF8ByteCount(item)
                )
            }
        }
        for message in bundle.messages.sorted(by: { $0.sequence < $1.sequence }) {
            var bytes = message.id.utf8.count
            bytes += message.turnID?.utf8.count ?? 0
            bytes += message.body.utf8.count
            bytes += message.payloadJSON?.utf8.count ?? 0
            remember(messageKey(message), itemBytes: bytes)
        }
        for tool in bundle.tools {
            var bytes = tool.id.utf8.count
            bytes += tool.turnID?.utf8.count ?? 0
            bytes += tool.callID.utf8.count
            bytes += tool.toolName.utf8.count
            bytes += tool.taskRefsJSON?.utf8.count ?? 0
            remember(toolKey(tool), itemBytes: bytes)
        }
        if let activeTurn = bundle.activeTurn {
            let key = "turn:\(activeTurn.id)"
            if costs[key] == nil {
                orderedKeys.append(key)
                costs[key] = TurnCost()
            }
        }

        var retainedKeys: Set<String> = []
        var retainedItemCount = 0
        var retainedBytes = 0
        for key in orderedKeys.reversed() {
            let cost = costs[key] ?? TurnCost()
            let fits = retainedItemCount + cost.itemCount <= budget.maximumItemCount
                && retainedBytes + cost.utf8Bytes <= budget.maximumUTF8Bytes
            guard fits || retainedItemCount == 0 else { break }
            retainedKeys.insert(key)
            retainedItemCount += cost.itemCount
            retainedBytes += cost.utf8Bytes
        }

        let didTruncate = retainedKeys.count < orderedKeys.count
        reachedLimit = reachedLimit || didTruncate
        itemCount = retainedItemCount
        utf8ByteCount = retainedBytes
        let retainedMessages = bundle.messages.filter { retainedKeys.contains(messageKey($0)) }
        let retainedTools = bundle.tools.filter { retainedKeys.contains(toolKey($0)) }
        let retainedTimeline = bundle.timeline.map { timeline in
            timeline.filter { retainedKeys.contains(timelineKey($0)) }
        }
        let retainedMessageIDs = Set(retainedMessages.map(\.id))
        let evictedThroughSequence = bundle.messages.lazy
            .filter { !retainedMessageIDs.contains($0.id) }
            .map(\.sequence)
            .max()
        return AssistantHistoryHydrationResult(
            bundle: AssistantSessionBundle(
                session: bundle.session,
                messages: retainedMessages,
                tools: retainedTools,
                timeline: retainedTimeline,
                activeTurn: bundle.activeTurn
            ),
            didTruncate: didTruncate,
            evictedThroughSequence: evictedThroughSequence,
            retainedTurnKeys: retainedKeys
        )
    }

    private static func timelineOrderedBefore(
        _ lhs: SessionTimelineItem,
        _ rhs: SessionTimelineItem
    ) -> Bool {
        if lhs.turnOrdinal != rhs.turnOrdinal { return lhs.turnOrdinal < rhs.turnOrdinal }
        if lhs.itemOrdinal != rhs.itemOrdinal { return lhs.itemOrdinal < rhs.itemOrdinal }
        return lhs.id < rhs.id
    }
}

struct AssistantHistoryHydrationResult: Sendable {
    let bundle: AssistantSessionBundle
    let didTruncate: Bool
    let evictedThroughSequence: Int64?
    let retainedTurnKeys: Set<String>
}

// MARK: - Shared ordered timeline model

enum ChatTimelineKind: Equatable, Sendable {
    case user
    case assistantText
    case reasoning
    case tool
    case status
    case error
    case unknown(String)

    init(protocolValue: String) {
        self = switch protocolValue {
        case "user": .user
        case "assistant_text": .assistantText
        case "reasoning": .reasoning
        case "tool": .tool
        case "status": .status
        case "error": .error
        default: .unknown(protocolValue)
        }
    }
}

enum ChatToolState: Equatable, Sendable {
    case running
    case completed
    case failed
    case interrupted
    case unknown(String)

    init(protocolValue: String) {
        self = switch protocolValue {
        case "running": .running
        case "completed": .completed
        case "failed": .failed
        case "interrupted": .interrupted
        default: .unknown(protocolValue)
        }
    }

    var isTerminal: Bool {
        if case .running = self { return false }
        return true
    }
}

enum ChatTimelineFidelity: Equatable, Sendable {
    case exact
    case partial
    case legacy
    case mixed
    case unknown(String)

    init(protocolValue: String) {
        self = switch protocolValue {
        case "exact": .exact
        case "partial": .partial
        case "legacy": .legacy
        case "mixed": .mixed
        default: .unknown(protocolValue)
        }
    }
}

struct ChatTimelineOrder: Comparable, Hashable, Sendable {
    let sequence: Int64
    let subindex: Int64

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.subindex < rhs.subindex
    }
}

struct ChatTimelineItem: Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let turnID: String
    let order: ChatTimelineOrder
    let kind: ChatTimelineKind
    let body: String
    let callID: String?
    let toolName: String?
    let inputJSON: String?
    let outputText: String?
    let toolState: ChatToolState?
    let isError: Bool
    let taskReferences: [UUID]
    let attachments: [AssistantAttachmentSummary]
    let createdAt: String
    let updatedAt: String
    let fidelity: ChatTimelineFidelity
}

// MARK: - Shared transcript presentation model

struct ChatTranscript: Equatable, Sendable {
    let sessionID: String
    let items: [ChatTranscriptItem]
    let tailRevision: Int
    let isRunning: Bool

    static func empty(sessionID: String = "") -> Self {
        Self(sessionID: sessionID, items: [], tailRevision: 0, isRunning: false)
    }
}

enum ChatTranscriptItem: Identifiable, Equatable, Sendable {
    case turn(ChatTurnItem)
    case notice(ChatNoticeItem)
    case error(ChatErrorItem)

    var id: String {
        switch self {
        case let .turn(item): item.id
        case let .notice(item): item.id
        case let .error(item): item.id
        }
    }
}

/// The stable top-level row for one provider turn. Streaming can append
/// reasoning, tools, and narration without replacing or moving the row itself.
struct ChatTurnItem: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: String
    let userMessages: [ChatTextItem]
    let activity: ChatActivityGroup?
    let assistant: ChatTextItem?
    let notices: [ChatNoticeItem]
    let errors: [ChatErrorItem]
    let isRunning: Bool
}

struct ChatTextItem: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: String
    let body: String
    let markdown: AssistantMarkdownDocument?
    let attachments: [AssistantAttachmentSummary]
    let taskReferences: [UUID]
    let createdAt: String
    let timeLabel: String?
    let isStreaming: Bool
}

struct ChatActivityGroup: Identifiable, Equatable, Sendable {
    let id: String
    let turnID: String
    let items: [ChatActivityItem]
    let isRunning: Bool
    let hasFailure: Bool
}

enum ChatActivityItem: Identifiable, Equatable, Sendable {
    case reasoning(ChatReasoningItem)
    case narration(ChatTextItem)
    case tool(ChatToolStep)
    case status(ChatNoticeItem)

    var id: String {
        switch self {
        case let .reasoning(item): item.id
        case let .narration(item): item.id
        case let .tool(item): item.id
        case let .status(item): item.id
        }
    }
}

struct ChatReasoningItem: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
    let markdown: AssistantMarkdownDocument?
    let isStreaming: Bool
}

struct ChatToolStep: Identifiable, Equatable, Sendable {
    let id: String
    let callID: String
    let name: String
    let inputJSON: String?
    let outputText: String?
    let state: ChatToolState
    let isError: Bool
    let taskReferences: [UUID]
}

struct ChatNoticeItem: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
}

struct ChatErrorItem: Identifiable, Equatable, Sendable {
    let id: String
    let body: String
}
