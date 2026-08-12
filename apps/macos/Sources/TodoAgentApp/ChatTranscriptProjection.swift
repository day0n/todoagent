import Foundation

/// Pure, deterministic projection from persisted/live protocol records to the
/// shared Chat V2 presentation model. JSON decoding, ordering, tool pairing,
/// and settled Markdown parsing happen here rather than from SwiftUI `body`.
enum ChatTranscriptProjection {
    static func task(
        bundle: SessionBundle,
        timelinePage: SessionTimelinePage? = nil
    ) -> ChatTranscript {
        let timeline: [ChatTimelineItem]
        if let timelinePage {
            timeline = normalize(timelinePage.items)
        } else {
            timeline = normalize(bundle.messages)
        }
        return project(
            sessionID: bundle.session.id,
            timeline: timeline,
            activeTurnID: timelinePage?.activeTurn?.id
                ?? bundle.activeTurn?.id
                ?? (bundle.session.state.isBusy ? timeline.last?.turnID : nil),
            isRunning: bundle.session.state.isBusy
        )
    }

    static func assistant(
        sessionID: String,
        messages: [AssistantMessage],
        tools: [AssistantToolActivity],
        draft: AssistantStreamingDraft?,
        isRunning: Bool,
        statusText: String? = nil,
        errorMessage: String? = nil,
        activeTurnID preferredActiveTurnID: String? = nil
    ) -> ChatTranscript {
        var timeline = normalize(messages, tools: tools)
        let lastSequence = timeline.map(\.order.sequence).max() ?? 0

        if let draft, !draft.body.isEmpty {
            timeline.append(
                ChatTimelineItem(
                    id: "assistant-draft-\(draft.messageID)",
                    sessionID: sessionID,
                    turnID: draft.turnID,
                    order: ChatTimelineOrder(sequence: lastSequence + 1, subindex: 0),
                    kind: .assistantText,
                    body: draft.body,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "draft-\(draft.attempt)-\(draft.body.utf8.count)",
                    fidelity: .exact
                )
            )
        } else if let statusText, !statusText.isEmpty, isRunning {
            let turnID = preferredActiveTurnID
                ?? tools.last?.turnID
                ?? messages.last(where: { $0.turnID != nil })?.turnID
                ?? "assistant-active"
            timeline.append(
                ChatTimelineItem(
                    id: "assistant-status-\(turnID)",
                    sessionID: sessionID,
                    turnID: turnID,
                    order: ChatTimelineOrder(sequence: lastSequence + 1, subindex: 0),
                    kind: .status,
                    body: statusText,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "",
                    fidelity: .exact
                )
            )
        }

        if let errorMessage, !errorMessage.isEmpty {
            let turnID = preferredActiveTurnID
                ?? tools.last?.turnID
                ?? messages.last(where: { $0.turnID != nil })?.turnID
                ?? "assistant-error"
            timeline.append(
                ChatTimelineItem(
                    id: "assistant-error-\(turnID)",
                    sessionID: sessionID,
                    turnID: turnID,
                    order: ChatTimelineOrder(sequence: lastSequence + 2, subindex: 0),
                    kind: .error,
                    body: errorMessage,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: true,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "",
                    fidelity: .exact
                )
            )
        }

        let activeTurnID = isRunning
            ? (preferredActiveTurnID
                ?? draft?.turnID
                ?? tools.last(where: { $0.state == .running })?.turnID
                ?? tools.last?.turnID
                ?? messages.last?.turnID)
            : nil
        return project(
            sessionID: sessionID,
            timeline: timeline,
            activeTurnID: activeTurnID,
            isRunning: isRunning
        )
    }

    /// Preferred Assistant Chat V2 path. The persisted ordered timeline is
    /// authoritative; bounded live tool state and the streaming text draft are
    /// overlaid only for the active turn until the next history reconciliation.
    static func assistant(
        sessionID: String,
        timeline: [ChatTimelineItem],
        liveReasoning: AssistantThoughtSummaryEvent? = nil,
        liveTools: [AssistantToolActivity],
        draft: AssistantStreamingDraft?,
        isRunning: Bool,
        statusText: String? = nil,
        errorMessage: String? = nil,
        activeTurnID: String?
    ) -> ChatTranscript {
        var items = timeline
        var toolIndexByCallID: [String: Int] = [:]
        for (index, item) in items.enumerated() where item.kind == .tool {
            if let callID = item.callID { toolIndexByCallID[callID] = index }
        }

        var nextSequence = (items.map(\.order.sequence).max() ?? 0) + 1
        if let liveReasoning, !liveReasoning.content.isEmpty {
            if let existingIndex = items.firstIndex(where: {
                $0.turnID == liveReasoning.turnID && $0.kind == .reasoning
            }) {
                let existing = items[existingIndex]
                items[existingIndex] = ChatTimelineItem(
                    id: existing.id,
                    sessionID: existing.sessionID,
                    turnID: existing.turnID,
                    order: existing.order,
                    kind: .reasoning,
                    body: liveReasoning.content,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: existing.taskReferences,
                    attachments: existing.attachments,
                    createdAt: existing.createdAt,
                    updatedAt: "thought-summary-\(liveReasoning.attempt)",
                    fidelity: existing.fidelity
                )
            } else {
                items.append(
                    ChatTimelineItem(
                        id: "assistant-live-reasoning-\(liveReasoning.turnID)",
                        sessionID: sessionID,
                        turnID: liveReasoning.turnID,
                        order: ChatTimelineOrder(sequence: nextSequence, subindex: 0),
                        kind: .reasoning,
                        body: liveReasoning.content,
                        callID: nil,
                        toolName: nil,
                        inputJSON: nil,
                        outputText: nil,
                        toolState: nil,
                        isError: false,
                        taskReferences: [],
                        attachments: [],
                        createdAt: "",
                        updatedAt: "thought-summary-\(liveReasoning.attempt)",
                        fidelity: .partial
                    )
                )
                nextSequence += 1
            }
        }
        for (index, tool) in liveTools.enumerated() {
            let state: ChatToolState = switch tool.state {
            case .running: .running
            case .completed: .completed
            case .failed: .failed
            }
            if let existingIndex = toolIndexByCallID[tool.toolCallID] {
                let existing = items[existingIndex]
                items[existingIndex] = ChatTimelineItem(
                    id: existing.id,
                    sessionID: existing.sessionID,
                    turnID: existing.turnID,
                    order: existing.order,
                    kind: .tool,
                    body: existing.body,
                    callID: existing.callID,
                    toolName: existing.toolName ?? tool.name,
                    inputJSON: existing.inputJSON,
                    outputText: existing.outputText,
                    toolState: state,
                    isError: tool.state == .failed,
                    taskReferences: unique(existing.taskReferences + tool.taskReferences),
                    attachments: existing.attachments,
                    createdAt: existing.createdAt,
                    updatedAt: "live-\(state)",
                    fidelity: existing.fidelity
                )
            } else {
                items.append(
                    ChatTimelineItem(
                        id: "assistant-live-tool-\(tool.toolCallID)",
                        sessionID: sessionID,
                        turnID: tool.turnID,
                        order: ChatTimelineOrder(sequence: nextSequence, subindex: Int64(index)),
                        kind: .tool,
                        body: "",
                        callID: tool.toolCallID,
                        toolName: tool.name,
                        inputJSON: nil,
                        outputText: nil,
                        toolState: state,
                        isError: tool.state == .failed,
                        taskReferences: tool.taskReferences,
                        attachments: [],
                        createdAt: "",
                        updatedAt: "live-\(state)",
                        fidelity: .partial
                    )
                )
                nextSequence += 1
            }
        }

        if let draft, !draft.body.isEmpty {
            items.append(
                ChatTimelineItem(
                    id: "assistant-draft-\(draft.messageID)",
                    sessionID: sessionID,
                    turnID: draft.turnID,
                    order: ChatTimelineOrder(sequence: nextSequence, subindex: 0),
                    kind: .assistantText,
                    body: draft.body,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "draft-\(draft.attempt)-\(draft.body.utf8.count)",
                    fidelity: .exact
                )
            )
            nextSequence += 1
        } else if let statusText, !statusText.isEmpty, isRunning,
                  let activeTurnID,
                  !items.contains(where: { item in
                      item.turnID == activeTurnID && item.kind != .user
                  }) {
            items.append(
                ChatTimelineItem(
                    id: "assistant-status-\(activeTurnID)",
                    sessionID: sessionID,
                    turnID: activeTurnID,
                    order: ChatTimelineOrder(sequence: nextSequence, subindex: 0),
                    kind: .status,
                    body: statusText,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "",
                    fidelity: .exact
                )
            )
            nextSequence += 1
        }

        if let errorMessage, !errorMessage.isEmpty {
            let turnID = activeTurnID ?? items.last?.turnID ?? "assistant-error"
            items.append(
                ChatTimelineItem(
                    id: "assistant-error-\(turnID)",
                    sessionID: sessionID,
                    turnID: turnID,
                    order: ChatTimelineOrder(sequence: nextSequence, subindex: 0),
                    kind: .error,
                    body: errorMessage,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: true,
                    taskReferences: [],
                    attachments: [],
                    createdAt: "",
                    updatedAt: "",
                    fidelity: .exact
                )
            )
        }

        return project(
            sessionID: sessionID,
            timeline: items,
            activeTurnID: isRunning ? activeTurnID : nil,
            isRunning: isRunning
        )
    }

    // MARK: Normalization

    static func normalize(_ items: [SessionTimelineItem]) -> [ChatTimelineItem] {
        items.map { item in
            ChatTimelineItem(
                id: item.id,
                sessionID: item.sessionID,
                turnID: item.turnID,
                // The Engine's cross-page cursor and authoritative UI order are
                // both based on turn/item ordinals. Storage `sequence` is a
                // mutation cursor and can be reassigned during reconciliation.
                order: ChatTimelineOrder(sequence: item.turnOrdinal, subindex: item.itemOrdinal),
                kind: ChatTimelineKind(protocolValue: item.kind),
                body: item.body,
                callID: item.callID,
                toolName: item.toolName,
                inputJSON: item.inputJSON,
                outputText: item.outputText,
                toolState: toolState(item.toolState, output: item.outputText, isError: item.isError),
                isError: item.isError,
                taskReferences: taskReferences(from: item.metadataJSON),
                attachments: [],
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                fidelity: ChatTimelineFidelity(protocolValue: item.fidelity)
            )
        }
        .sorted(by: orderedBefore)
    }

    /// A partial Engine timeline preserves activity order but may omit bounded
    /// user/final detail. Reinsert only missing message essentials; exact
    /// timelines remain untouched and therefore fully authoritative.
    static func normalizeAssistantHistory(
        _ items: [SessionTimelineItem],
        supplementing messages: [AssistantMessage]
    ) -> [ChatTimelineItem] {
        var timeline = normalize(items)
        let needsSupplement = timeline.isEmpty && !messages.isEmpty
            || timeline.contains { $0.fidelity != .exact }
        guard needsSupplement else { return timeline }

        var nextTurnOrdinal = (timeline.map(\.order.sequence).max() ?? -1) + 1
        var fallbackTurnOrdinals: [String: Int64] = [:]
        for message in messages.sorted(by: { $0.sequence < $1.sequence }) {
            guard message.role == .user || message.role == .todoAgent else { continue }
            let turnID = message.turnID ?? "assistant-turn-\(message.id)"
            let turnItems = timeline.filter { $0.turnID == turnID }
            let alreadyPresent = turnItems.contains { item in
                if item.id == message.id { return true }
                if message.role == .user { return item.kind == .user }
                return item.kind == .assistantText && item.body == message.body
            }
            guard !alreadyPresent else { continue }

            let order: ChatTimelineOrder
            if message.role == .user, let first = turnItems.map(\.order).min() {
                order = ChatTimelineOrder(sequence: first.sequence, subindex: first.subindex - 1)
            } else if let last = turnItems.map(\.order).max() {
                order = ChatTimelineOrder(sequence: last.sequence, subindex: last.subindex + 1)
            } else {
                let turnOrdinal: Int64
                if let existing = fallbackTurnOrdinals[turnID] {
                    turnOrdinal = existing
                } else {
                    turnOrdinal = nextTurnOrdinal
                    fallbackTurnOrdinals[turnID] = turnOrdinal
                    nextTurnOrdinal += 1
                }
                order = ChatTimelineOrder(
                    sequence: turnOrdinal,
                    subindex: message.role == .user ? 0 : 1
                )
            }
            timeline.append(
                ChatTimelineItem(
                    id: message.id,
                    sessionID: message.sessionID,
                    turnID: turnID,
                    order: order,
                    kind: message.role == .user ? .user : .assistantText,
                    body: message.body,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: false,
                    taskReferences: message.taskReferences,
                    attachments: message.textAttachments,
                    createdAt: message.createdAt,
                    updatedAt: message.updatedAt,
                    fidelity: .partial
                )
            )
        }
        return timeline.sorted(by: orderedBefore)
    }

    static func normalize(_ messages: [SessionMessage]) -> [ChatTimelineItem] {
        let orderedMessages = messages.sorted {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
        var timeline: [ChatTimelineItem] = []
        var currentTurnID: String?
        var toolIndexByKey: [String: Int] = [:]

        for message in orderedMessages {
            if message.role == .user {
                currentTurnID = message.turnID ?? "legacy-turn-\(message.id)"
            }
            let turnID = message.turnID ?? currentTurnID ?? "legacy-turn-\(message.id)"
            let payload = LegacyToolPayload.decode(message.payloadJSON)

            if message.role == .tool, message.kind == "tool_call" {
                let callID = payload?.callID ?? "legacy-\(message.id)"
                let tool = ChatTimelineItem(
                    id: "legacy-tool-\(turnID)-\(callID)",
                    sessionID: message.sessionID,
                    turnID: turnID,
                    order: ChatTimelineOrder(sequence: message.sequence, subindex: 0),
                    kind: .tool,
                    body: "",
                    callID: callID,
                    toolName: payload?.resolvedName ?? nonEmpty(message.body) ?? "tool",
                    inputJSON: payload?.inputJSON,
                    outputText: nil,
                    toolState: .running,
                    isError: false,
                    taskReferences: payload?.taskReferences ?? [],
                    attachments: [],
                    createdAt: message.createdAt,
                    updatedAt: message.updatedAt,
                    fidelity: payload?.callID == nil ? .partial : .legacy
                )
                toolIndexByKey[toolKey(turnID: turnID, callID: callID)] = timeline.count
                timeline.append(tool)
                continue
            }

            if message.role == .tool, message.kind == "tool_result" {
                let callID = payload?.callID
                let key = callID.map { toolKey(turnID: turnID, callID: $0) }
                let isError = payload?.isFailure == true || legacyBodyLooksLikeFailure(message.body)
                if let key, let index = toolIndexByKey[key] {
                    let call = timeline[index]
                    timeline[index] = ChatTimelineItem(
                        id: call.id,
                        sessionID: call.sessionID,
                        turnID: call.turnID,
                        order: call.order,
                        kind: .tool,
                        body: "",
                        callID: call.callID,
                        toolName: payload?.resolvedName ?? call.toolName,
                        inputJSON: call.inputJSON,
                        outputText: message.body,
                        toolState: isError ? .failed : .completed,
                        isError: isError,
                        taskReferences: call.taskReferences + (payload?.taskReferences ?? []),
                        attachments: [],
                        createdAt: call.createdAt,
                        updatedAt: message.updatedAt,
                        fidelity: call.fidelity
                    )
                } else {
                    let syntheticCallID = callID ?? "orphan-\(message.id)"
                    timeline.append(
                        ChatTimelineItem(
                            id: "legacy-tool-\(turnID)-\(syntheticCallID)",
                            sessionID: message.sessionID,
                            turnID: turnID,
                            order: ChatTimelineOrder(sequence: message.sequence, subindex: 0),
                            kind: .tool,
                            body: "",
                            callID: syntheticCallID,
                            toolName: payload?.resolvedName ?? "tool",
                            inputJSON: nil,
                            outputText: message.body,
                            toolState: isError ? .failed : .completed,
                            isError: isError,
                            taskReferences: payload?.taskReferences ?? [],
                            attachments: [],
                            createdAt: message.createdAt,
                            updatedAt: message.updatedAt,
                            fidelity: .partial
                        )
                    )
                }
                continue
            }

            let kind: ChatTimelineKind = switch (message.role, message.kind) {
            case (.user, _): .user
            case (.agent, _): .assistantText
            case (.system, "error"): .error
            case (.system, _): .status
            case (.tool, "error"): .error
            case (.tool, _): .status
            }
            timeline.append(
                ChatTimelineItem(
                    id: message.id,
                    sessionID: message.sessionID,
                    turnID: turnID,
                    order: ChatTimelineOrder(sequence: message.sequence, subindex: 0),
                    kind: kind,
                    body: message.body,
                    callID: nil,
                    toolName: nil,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: nil,
                    isError: kind == .error,
                    taskReferences: [],
                    attachments: [],
                    createdAt: message.createdAt,
                    updatedAt: message.updatedAt,
                    fidelity: .legacy
                )
            )
        }

        return timeline.sorted(by: orderedBefore)
    }

    static func normalize(
        _ messages: [AssistantMessage],
        tools: [AssistantToolActivity]
    ) -> [ChatTimelineItem] {
        var timeline = messages.compactMap { message -> ChatTimelineItem? in
            let kind: ChatTimelineKind
            switch message.role {
            case .user: kind = .user
            case .todoAgent: kind = .assistantText
            case .system: kind = message.kind == "error" ? .error : .status
            case .tool: return nil
            }
            let turnID = message.turnID ?? "assistant-turn-\(message.id)"
            return ChatTimelineItem(
                id: message.id,
                sessionID: message.sessionID,
                turnID: turnID,
                order: ChatTimelineOrder(sequence: message.sequence, subindex: 0),
                kind: kind,
                body: message.body,
                callID: nil,
                toolName: nil,
                inputJSON: nil,
                outputText: nil,
                toolState: nil,
                isError: kind == .error,
                taskReferences: message.taskReferences,
                attachments: message.textAttachments,
                createdAt: message.createdAt,
                updatedAt: message.updatedAt,
                fidelity: .exact
            )
        }

        let maximumSequence = timeline.map(\.order.sequence).max() ?? 0
        let assistantSequenceByTurn = Dictionary(
            timeline.compactMap { item -> (String, Int64)? in
                item.kind == .assistantText ? (item.turnID, item.order.sequence) : nil
            },
            uniquingKeysWith: min
        )
        let userSequenceByTurn = Dictionary(
            timeline.compactMap { item -> (String, Int64)? in
                item.kind == .user ? (item.turnID, item.order.sequence) : nil
            },
            uniquingKeysWith: min
        )

        for (index, tool) in tools.enumerated() {
            let state: ChatToolState = switch tool.state {
            case .running: .running
            case .completed: .completed
            case .failed: .failed
            }
            let sequence = assistantSequenceByTurn[tool.turnID]
                ?? userSequenceByTurn[tool.turnID].map { $0 + 1 }
                ?? maximumSequence + 1
            timeline.append(
                ChatTimelineItem(
                    id: "assistant-tool-\(tool.toolCallID)",
                    sessionID: tool.sessionID,
                    turnID: tool.turnID,
                    order: ChatTimelineOrder(sequence: sequence, subindex: Int64(index) - 10_000),
                    kind: .tool,
                    body: "",
                    callID: tool.toolCallID,
                    toolName: tool.name,
                    inputJSON: nil,
                    outputText: nil,
                    toolState: state,
                    isError: tool.state == .failed,
                    taskReferences: tool.taskReferences,
                    attachments: [],
                    createdAt: "",
                    updatedAt: "",
                    fidelity: .exact
                )
            )
        }
        return timeline.sorted(by: orderedBefore)
    }

    // MARK: Presentation

    static func project(
        sessionID: String,
        timeline: [ChatTimelineItem],
        activeTurnID: String?,
        isRunning: Bool
    ) -> ChatTranscript {
        let ordered = timeline.sorted(by: orderedBefore)
        struct OrderedTurn {
            let id: String
            var items: [ChatTimelineItem]
        }
        var turns: [OrderedTurn] = []
        var turnIndexByID: [String: Int] = [:]
        for item in ordered {
            if let index = turnIndexByID[item.turnID] {
                turns[index].items.append(item)
            } else {
                turnIndexByID[item.turnID] = turns.count
                turns.append(OrderedTurn(id: item.turnID, items: [item]))
            }
        }
        var transcriptItems: [ChatTranscriptItem] = []

        for turn in turns {
            let turnID = turn.id
            let turnItems = turn.items
            let turnIsRunning = isRunning && activeTurnID == turnID
            let assistantTexts = turnItems.filter { $0.kind == .assistantText }
            let lastAssistantIndex = turnItems.lastIndex { $0.kind == .assistantText }
            let finalBoundaryIndex = turnItems.indices.last { index in
                switch turnItems[index].kind {
                case .reasoning, .tool, .error, .unknown:
                    true
                case .status:
                    // A status between narration and a later answer is a real
                    // activity boundary. A trailing informational status is a
                    // turn notice and must not hide the final answer.
                    lastAssistantIndex.map { index < $0 } ?? true
                case .user, .assistantText:
                    false
                }
            }
            let finalAssistantTexts: [ChatTimelineItem]
            if turnIsRunning {
                finalAssistantTexts = []
            } else if let finalBoundaryIndex {
                finalAssistantTexts = turnItems
                    .dropFirst(finalBoundaryIndex + 1)
                    .filter { $0.kind == .assistantText }
            } else {
                finalAssistantTexts = assistantTexts
            }
            let finalAssistantIDs = Set(finalAssistantTexts.map(\.id))
            let lastFinalAssistantOrder = finalAssistantTexts.last?.order
            let trailingNoticeIDs = Set(
                turnIsRunning ? [] : turnItems.compactMap { item -> String? in
                    guard item.kind == .status,
                          let lastFinalAssistantOrder,
                          item.order > lastFinalAssistantOrder
                    else { return nil }
                    return item.id
                }
            )
            let userMessages = turnItems
                .filter { $0.kind == .user }
                .map { textItem(from: $0, role: "user", isStreaming: false) }

            var activities: [ChatActivityItem] = []
            for item in turnItems {
                switch item.kind {
                case .reasoning:
                    activities.append(
                        .reasoning(
                            ChatReasoningItem(
                                id: namespaced("reasoning", sessionID: sessionID, sourceID: item.id),
                                body: item.body,
                                // Reasoning can be hundreds of KiB and is
                                // collapsed after completion. Parse it lazily
                                // in the disclosure only when the user opens it.
                                markdown: nil,
                                // Only the active tail can still be changing.
                                // Earlier reasoning freezes as soon as a later
                                // narration/tool/status part arrives.
                                isStreaming: turnIsRunning && item.id == turnItems.last?.id
                            )
                        )
                    )
                case .tool:
                    activities.append(.tool(toolStep(from: item, sessionID: sessionID)))
                case .status:
                    guard !trailingNoticeIDs.contains(item.id) else { continue }
                    activities.append(
                        .status(
                            ChatNoticeItem(
                                id: namespaced("status", sessionID: sessionID, sourceID: item.id),
                                body: item.body
                            )
                        )
                    )
                case .assistantText where turnIsRunning || !finalAssistantIDs.contains(item.id):
                    activities.append(
                        .narration(
                            textItem(
                                from: item,
                                role: "narration",
                                isStreaming: turnIsRunning && item.id == assistantTexts.last?.id
                            )
                        )
                    )
                case let .unknown(rawKind):
                    activities.append(
                        .status(
                            ChatNoticeItem(
                                id: namespaced("unknown", sessionID: sessionID, sourceID: item.id),
                                body: nonEmpty(item.body) ?? "未知事件：\(rawKind)"
                            )
                        )
                    )
                case .user, .assistantText, .error:
                    break
                }
            }
            let activity = activities.isEmpty
                ? nil
                : ChatActivityGroup(
                    id: "chat:activity:\(sessionID):\(turnID)",
                    turnID: turnID,
                    items: activities,
                    isRunning: turnIsRunning || activities.contains(where: activityIsRunning),
                    hasFailure: activities.contains(where: activityHasFailure)
                )

            let assistant: ChatTextItem? = if turnIsRunning {
                nil
            } else if !finalAssistantTexts.isEmpty {
                combinedAssistantText(
                    finalAssistantTexts,
                    sessionID: sessionID,
                    turnID: turnID,
                    isStreaming: false
                )
            } else {
                nil
            }
            let errors = turnItems.compactMap { item -> ChatErrorItem? in
                guard item.kind == .error else { return nil }
                return ChatErrorItem(
                    id: namespaced("error", sessionID: sessionID, sourceID: item.id),
                    body: item.body
                )
            }
            let notices = turnItems.compactMap { item -> ChatNoticeItem? in
                guard trailingNoticeIDs.contains(item.id) else { return nil }
                return ChatNoticeItem(
                    id: namespaced("status", sessionID: sessionID, sourceID: item.id),
                    body: item.body
                )
            }

            transcriptItems.append(
                .turn(
                    ChatTurnItem(
                        id: "chat:turn:\(sessionID):\(turnID)",
                        turnID: turnID,
                        userMessages: userMessages,
                        activity: activity,
                        assistant: assistant,
                        notices: notices,
                        errors: errors,
                        isRunning: turnIsRunning
                    )
                )
            )
        }

        return ChatTranscript(
            sessionID: sessionID,
            items: transcriptItems,
            tailRevision: tailRevision(for: ordered, isRunning: isRunning),
            isRunning: isRunning
        )
    }

    private static func textItem(
        from item: ChatTimelineItem,
        role: String,
        isStreaming: Bool
    ) -> ChatTextItem {
        ChatTextItem(
            id: namespaced(role, sessionID: item.sessionID, sourceID: item.id),
            turnID: item.turnID,
            body: item.body,
            markdown: nil,
            attachments: item.attachments,
            taskReferences: item.taskReferences,
            createdAt: item.createdAt,
            timeLabel: timeLabel(item.createdAt),
            isStreaming: isStreaming
        )
    }

    private static func combinedAssistantText(
        _ items: [ChatTimelineItem],
        sessionID: String,
        turnID: String,
        isStreaming: Bool
    ) -> ChatTextItem {
        let body = items.map(\.body).filter { !$0.isEmpty }.joined(separator: "\n\n")
        return ChatTextItem(
            id: "chat:assistant:\(sessionID):\(turnID)",
            turnID: turnID,
            body: body,
            markdown: nil,
            attachments: items.flatMap(\.attachments),
            taskReferences: unique(items.flatMap(\.taskReferences)),
            createdAt: items.first?.createdAt ?? "",
            timeLabel: timeLabel(items.first?.createdAt ?? ""),
            isStreaming: isStreaming
        )
    }

    private static func toolStep(from item: ChatTimelineItem, sessionID: String) -> ChatToolStep {
        let callID = item.callID ?? item.id
        let state = item.toolState ?? (item.isError ? .failed : .completed)
        return ChatToolStep(
            id: "chat:tool:\(sessionID):\(item.turnID):\(callID)",
            callID: callID,
            name: item.toolName ?? "tool",
            inputJSON: item.inputJSON,
            outputText: item.outputText,
            state: state,
            isError: item.isError || state == .failed,
            taskReferences: item.taskReferences
        )
    }

    private static func activityIsRunning(_ item: ChatActivityItem) -> Bool {
        switch item {
        case let .reasoning(value): value.isStreaming
        case let .narration(value): value.isStreaming
        case let .tool(value): value.state == .running
        case .status: false
        }
    }

    private static func activityHasFailure(_ item: ChatActivityItem) -> Bool {
        guard case let .tool(value) = item else { return false }
        return value.isError || value.state == .failed || value.state == .interrupted
    }

    // MARK: Helpers

    private static func orderedBefore(_ lhs: ChatTimelineItem, _ rhs: ChatTimelineItem) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        return lhs.id < rhs.id
    }

    private static func namespaced(_ role: String, sessionID: String, sourceID: String) -> String {
        "chat:\(role):\(sessionID):\(sourceID)"
    }

    private static func toolKey(turnID: String, callID: String) -> String {
        "\(turnID)\u{1f}\(callID)"
    }

    private static func toolState(
        _ rawValue: String?,
        output: String?,
        isError: Bool
    ) -> ChatToolState? {
        if let rawValue { return ChatToolState(protocolValue: rawValue) }
        if isError { return .failed }
        if output != nil { return .completed }
        return nil
    }

    fileprivate static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func taskReferences(from metadataJSON: String?) -> [UUID] {
        LegacyToolPayload.decode(metadataJSON)?.taskReferences ?? []
    }

    private static func legacyBodyLooksLikeFailure(_ body: String) -> Bool {
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("error:")
            || normalized.hasPrefix("failed:")
            || normalized.hasPrefix("failure:")
            || normalized.hasPrefix("错误：")
            || normalized.hasPrefix("失败：")
    }

    private static func unique(_ values: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func timeLabel(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fractional.date(from: rawValue) ?? ISO8601DateFormatter().date(from: rawValue)
        return date?.formatted(date: .omitted, time: .shortened)
    }

    /// A small stable fingerprint is enough to drive tail-following. It only
    /// samples the tail so a streaming delta does not re-hash the full history.
    private static func tailRevision(for timeline: [ChatTimelineItem], isRunning: Bool) -> Int {
        var hash: UInt64 = 1_469_598_103_934_665_603
        func feed(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        for item in timeline.suffix(8) {
            for byte in item.id.utf8 { feed(byte) }
            for byte in item.updatedAt.utf8 { feed(byte) }
            for byte in item.body.utf8.suffix(256) { feed(byte) }
            for byte in (item.outputText ?? "").utf8.suffix(128) { feed(byte) }
            feed(item.toolState == .running ? 1 : 0)
        }
        feed(isRunning ? 1 : 0)
        return Int(truncatingIfNeeded: hash)
    }
}

private struct LegacyToolPayload: Decodable {
    let name: String?
    let tool: String?
    let toolName: String?
    let callID: String?
    let input: JSONValue?
    let isError: Bool?
    let success: Bool?
    let status: String?
    let taskReferences: [UUID]

    var resolvedName: String? {
        for candidate in [name, tool, toolName] {
            if let candidate = ChatTranscriptProjection.nonEmpty(candidate) { return candidate }
        }
        return nil
    }

    var inputJSON: String? {
        guard let input, let data = try? JSONEncoder.sorted.encode(input) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var isFailure: Bool {
        if isError == true || success == false { return true }
        guard let status = status?.lowercased() else { return false }
        return ["error", "failed", "failure", "cancelled", "interrupted"].contains(status)
    }

    private enum CodingKeys: String, CodingKey {
        case name, tool
        case toolName = "tool_name"
        case camelToolName = "toolName"
        case callID = "callId"
        case input, isError, success, status, taskReferences
        case taskRefs = "taskRefs"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        tool = try values.decodeIfPresent(String.self, forKey: .tool)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
            ?? values.decodeIfPresent(String.self, forKey: .camelToolName)
        callID = try values.decodeIfPresent(String.self, forKey: .callID)
        input = try values.decodeIfPresent(JSONValue.self, forKey: .input)
        isError = try values.decodeIfPresent(Bool.self, forKey: .isError)
        success = try values.decodeIfPresent(Bool.self, forKey: .success)
        status = try values.decodeIfPresent(String.self, forKey: .status)
        let references = try values.decodeIfPresent([String].self, forKey: .taskReferences)
            ?? values.decodeIfPresent([String].self, forKey: .taskRefs)
            ?? []
        taskReferences = references.compactMap(UUID.init(uuidString:))
    }

    static func decode(_ json: String?) -> Self? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
