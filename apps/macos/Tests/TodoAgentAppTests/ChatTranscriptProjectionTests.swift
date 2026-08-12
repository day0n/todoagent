import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Shared Chat V2 transcript projection")
struct ChatTranscriptProjectionTests {
    @Test("timeline hydration accepts normal thousand-item history and stops before its budget")
    func timelineHydrationBudget() {
        let normalItems = (0 ..< 1_000).map { index in
            timelineItem(
                id: "normal-\(index)",
                sequence: Int64(index + 1),
                turnID: "normal-turn-\(index)",
                turnOrdinal: Int64(index),
                itemOrdinal: Int64(index),
                kind: "assistant_text",
                body: "正常历史 \(index)"
            )
        }
        var normal = ChatTimelineHydrationAccumulator(budget: .sessionHistory)
        normal.appendPage(Array(normalItems.prefix(500)))
        normal.appendPage(Array(normalItems.suffix(500)))
        #expect(normal.items.count == 1_000)
        #expect(normal.reachedLimit == false)

        let tinyBudget = ChatTimelineHydrationBudget(
            maximumItemCount: 3,
            maximumUTF8Bytes: 1_024
        )
        var limited = ChatTimelineHydrationAccumulator(budget: tinyBudget)
        limited.appendPage(Array(normalItems.prefix(4)))
        #expect(limited.items.map(\.id) == ["normal-1", "normal-2", "normal-3"])
        #expect(limited.reachedLimit)
    }

    @Test("timeline hydration evicts complete oldest turns and retains the active tail")
    func timelineHydrationRetainsNewestCompleteTurns() {
        let items = [
            timelineItem(id: "old-user", sequence: 1, turnID: "old", turnOrdinal: 1, itemOrdinal: 0, kind: "user"),
            timelineItem(id: "old-answer", sequence: 2, turnID: "old", turnOrdinal: 1, itemOrdinal: 1, kind: "assistant_text"),
            timelineItem(id: "active-user", sequence: 3, turnID: "active", turnOrdinal: 2, itemOrdinal: 0, kind: "user"),
            timelineItem(id: "active-text", sequence: 4, turnID: "active", turnOrdinal: 2, itemOrdinal: 1, kind: "assistant_text"),
        ]
        var accumulator = ChatTimelineHydrationAccumulator(
            budget: ChatTimelineHydrationBudget(maximumItemCount: 3, maximumUTF8Bytes: 4_096)
        )
        accumulator.appendPage(items)

        #expect(accumulator.items.map(\.id) == ["active-user", "active-text"])
        #expect(accumulator.reachedLimit)
    }

    @Test("assistant hydration retains the latest completed turn and active turn")
    func assistantHydrationRetainsNewestTurns() {
        let session = AssistantSessionDescriptor(
            id: "session-1",
            title: "history",
            lastSequence: 3,
            isRunning: true
        )
        let messages = [
            AssistantMessage(id: "message-1", sessionID: session.id, turnID: "turn-1", sequence: 1, role: .todoAgent, body: "old"),
            AssistantMessage(id: "message-2", sessionID: session.id, turnID: "turn-2", sequence: 2, role: .todoAgent, body: "latest completed"),
            AssistantMessage(id: "message-3", sessionID: session.id, turnID: "turn-3", sequence: 3, role: .user, body: "active"),
        ]
        let timeline = [
            timelineItem(id: "timeline-1", sequence: 1, turnID: "turn-1", turnOrdinal: 1, itemOrdinal: 0, kind: "assistant_text", body: "old"),
            timelineItem(id: "timeline-2", sequence: 2, turnID: "turn-2", turnOrdinal: 2, itemOrdinal: 0, kind: "assistant_text", body: "latest completed"),
            timelineItem(id: "timeline-3", sequence: 3, turnID: "turn-3", turnOrdinal: 3, itemOrdinal: 0, kind: "user", body: "active"),
        ]
        let bundle = AssistantSessionBundle(
            session: session,
            messages: messages,
            timeline: timeline,
            activeTurn: AssistantTurn(
                id: "turn-3",
                sessionID: session.id,
                status: .running
            )
        )
        var accumulator = AssistantHistoryHydrationAccumulator(
            budget: ChatTimelineHydrationBudget(maximumItemCount: 4, maximumUTF8Bytes: 4_096)
        )
        let result = accumulator.retainNewestTurns(in: bundle)

        #expect(result.didTruncate)
        #expect(result.bundle.messages.map(\.id) == ["message-2", "message-3"])
        #expect(result.bundle.timeline?.map(\.id) == ["timeline-2", "timeline-3"])
        #expect(result.bundle.activeTurn?.id == "turn-3")
        #expect(result.evictedThroughSequence == 1)
    }

    @Test("exact timeline keeps reasoning and tools before the final answer")
    func exactTimelineOrdering() throws {
        let items = [
            timelineItem(id: "user", sequence: 1, itemOrdinal: 0, kind: "user", body: "检查项目"),
            timelineItem(id: "thinking", sequence: 2, itemOrdinal: 1, kind: "reasoning", body: "先检查目录"),
            timelineItem(
                id: "tool",
                sequence: 3,
                itemOrdinal: 2,
                kind: "tool",
                callID: "call-1",
                toolName: "read",
                outputText: "ok",
                toolState: "completed"
            ),
            timelineItem(id: "answer", sequence: 4, itemOrdinal: 3, kind: "assistant_text", body: "检查完成"),
        ]

        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize(items),
            activeTurnID: nil,
            isRunning: false
        )

        #expect(transcript.items.map(\.id) == ["chat:turn:session-1:turn-1"])
        let projectedTurn = try #require(firstTurn(in: transcript))
        #expect(projectedTurn.userMessages.map(\.id) == ["chat:user:session-1:user"])
        #expect(projectedTurn.assistant?.id == "chat:assistant:session-1:turn-1")
        let group = try #require(projectedTurn.activity)
        #expect(group.items.count == 2)
        guard case let .reasoning(reasoning) = group.items[0] else {
            Issue.record("first activity should be reasoning")
            return
        }
        #expect(reasoning.body == "先检查目录")
        guard case let .tool(tool) = group.items[1] else {
            Issue.record("second activity should be a paired tool")
            return
        }
        #expect(tool.callID == "call-1")
        #expect(tool.outputText == "ok")
        #expect(tool.state == .completed)
    }

    @Test("partial assistant timeline supplements missing final message without duplicating user")
    func partialAssistantTimelineKeepsEssentialMessages() throws {
        let messages = [
            AssistantMessage(
                id: "message-user",
                sessionID: "session-1",
                turnID: "turn-1",
                sequence: 1,
                role: .user,
                body: "检查"
            ),
            AssistantMessage(
                id: "message-final",
                sessionID: "session-1",
                turnID: "turn-1",
                sequence: 2,
                role: .todoAgent,
                body: "最终结果"
            ),
        ]
        let timeline = [
            timelineItem(id: "timeline-user", sequence: 1, itemOrdinal: 0, kind: "user", body: "检查"),
            timelineItem(id: "reasoning", sequence: 2, itemOrdinal: 1, kind: "reasoning", body: "核对", fidelity: "partial"),
            timelineItem(id: "partial-notice", sequence: 3, itemOrdinal: 2, kind: "status", body: "部分详情已省略", fidelity: "partial"),
        ]

        let normalized = ChatTranscriptProjection.normalizeAssistantHistory(
            timeline,
            supplementing: messages
        )
        #expect(normalized.filter { $0.kind == .user }.count == 1)
        #expect(normalized.filter { $0.kind == .assistantText }.map(\.id) == ["message-final"])

        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: normalized,
            activeTurnID: nil,
            isRunning: false
        )
        let turn = try #require(firstTurn(in: transcript))
        #expect(turn.assistant?.body == "最终结果")
        #expect(turn.activity?.items.contains { item in
            guard case .status = item else { return false }
            return true
        } == true)
    }

    @Test("partial status after an essential final answer does not hide the answer")
    func partialStatusDoesNotBecomeFinalBoundary() throws {
        let timeline = [
            timelineItem(id: "user", sequence: 1, itemOrdinal: 0, kind: "user", body: "检查"),
            timelineItem(id: "reasoning", sequence: 2, itemOrdinal: 1, kind: "reasoning", body: "核对", fidelity: "partial"),
            timelineItem(id: "final", sequence: 3, itemOrdinal: 2, kind: "assistant_text", body: "最终结果", fidelity: "partial"),
            timelineItem(id: "partial-notice", sequence: 4, itemOrdinal: 3, kind: "status", body: "部分详情已省略", fidelity: "partial"),
        ]
        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize(timeline),
            activeTurnID: nil,
            isRunning: false
        )
        let turn = try #require(firstTurn(in: transcript))

        #expect(turn.assistant?.body == "最终结果")
        #expect(turn.notices.map(\.body) == ["部分详情已省略"])
    }

    @Test("running turn keeps a stable row and splits the final suffix only after completion")
    func runningTurnSuffixLifecycle() throws {
        let user = timelineItem(id: "user", sequence: 1, itemOrdinal: 0, kind: "user", body: "继续")
        let firstText = timelineItem(id: "narration", sequence: 2, itemOrdinal: 1, kind: "assistant_text", body: "我先读取文件")
        let tool = timelineItem(id: "tool", sequence: 3, itemOrdinal: 2, kind: "tool", callID: "c", toolName: "read", toolState: "running")
        let secondText = timelineItem(id: "answer", sequence: 4, itemOrdinal: 3, kind: "assistant_text", body: "已经完成")

        let textOnly = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([user, firstText]),
            activeTurnID: "turn-1",
            isRunning: true
        )
        let withTool = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([user, firstText, tool]),
            activeTurnID: "turn-1",
            isRunning: true
        )
        let withSecondText = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([user, firstText, tool, secondText]),
            activeTurnID: "turn-1",
            isRunning: true
        )
        let completed = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([
                user,
                firstText,
                timelineItem(
                    id: "tool",
                    sequence: 3,
                    itemOrdinal: 2,
                    kind: "tool",
                    callID: "c",
                    toolName: "read",
                    outputText: "done",
                    toolState: "completed"
                ),
                secondText,
            ]),
            activeTurnID: nil,
            isRunning: false
        )

        let turns = try [textOnly, withTool, withSecondText, completed].map { transcript in
            try #require(firstTurn(in: transcript))
        }
        #expect(turns.map(\.id) == Array(repeating: "chat:turn:session-1:turn-1", count: 4))
        #expect(turns[0].assistant == nil)
        #expect(turns[1].assistant == nil)
        #expect(turns[2].assistant == nil)
        #expect(turns[0].activity?.items.count == 1)
        #expect(turns[1].activity?.items.count == 2)
        #expect(turns[2].activity?.items.count == 3)
        #expect(turns[3].activity?.items.count == 2)
        #expect(turns[3].assistant?.body == "已经完成")
        #expect(turns[3].assistant?.markdown == nil)

        guard case let .narration(streamingNarration) = turns[2].activity?.items.last else {
            Issue.record("running suffix should remain narration")
            return
        }
        #expect(streamingNarration.body == "已经完成")
        #expect(streamingNarration.markdown == nil)
        #expect(streamingNarration.isStreaming)
    }

    @Test("legacy tool call and result pair into one stable row")
    func legacyToolPairing() throws {
        let messages = [
            sessionMessage(id: "u", sequence: 1, role: .user, body: "读取"),
            sessionMessage(
                id: "call",
                sequence: 2,
                role: .tool,
                kind: "tool_call",
                body: "read",
                payloadJSON: #"{"name":"read","callId":"call-1","input":{"path":"a.md"}}"#
            ),
            sessionMessage(
                id: "result",
                sequence: 3,
                role: .tool,
                kind: "tool_result",
                body: "contents",
                payloadJSON: #"{"name":"read","callId":"call-1","isError":false}"#
            ),
            sessionMessage(id: "a", sequence: 4, role: .agent, body: "已读取"),
        ]

        let normalized = ChatTranscriptProjection.normalize(messages)
        let tools = normalized.filter { $0.kind == .tool }
        let tool = try #require(tools.first)

        #expect(tools.count == 1)
        #expect(tool.id == "legacy-tool-turn-1-call-1")
        #expect(tool.inputJSON == #"{"path":"a.md"}"#)
        #expect(tool.outputText == "contents")
        #expect(tool.toolState == .completed)
    }

    @Test("tool identity does not change when its state changes")
    func stableToolIdentity() throws {
        let running = timelineItem(
            id: "tool-source",
            sequence: 2,
            itemOrdinal: 0,
            kind: "tool",
            callID: "same-call",
            toolName: "Bash",
            toolState: "running"
        )
        let completed = timelineItem(
            id: "tool-source",
            sequence: 2,
            itemOrdinal: 0,
            kind: "tool",
            callID: "same-call",
            toolName: "Bash",
            outputText: "done",
            toolState: "completed"
        )

        let runningTranscript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([running]),
            activeTurnID: "turn-1",
            isRunning: true
        )
        let completedTranscript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize([completed]),
            activeTurnID: nil,
            isRunning: false
        )

        let runningGroup = try #require(firstTurn(in: runningTranscript)?.activity)
        let completedGroup = try #require(firstTurn(in: completedTranscript)?.activity)
        #expect(runningGroup.id == completedGroup.id)
        #expect(runningGroup.items.first?.id == completedGroup.items.first?.id)
        #expect(runningGroup.isRunning)
        #expect(completedGroup.isRunning == false)
    }

    @Test("timeline DTO decodes the additive Engine API")
    func timelineDTODecoding() throws {
        let data = try #require(
            #"{"id":"i","sessionId":"s","turnId":"t","sequence":7,"turnOrdinal":2,"itemOrdinal":3,"kind":"reasoning","body":"why","callId":null,"toolName":null,"inputJson":null,"outputText":null,"toolState":null,"isError":false,"sourceEventSequence":12,"sourceBlockIndex":1,"fidelity":"exact","metadataJson":null,"createdAt":"now","updatedAt":"now"}"#.data(using: .utf8)
        )

        let item = try JSONDecoder().decode(SessionTimelineItem.self, from: data)

        #expect(item.sessionID == "s")
        #expect(item.turnID == "t")
        #expect(item.itemOrdinal == 3)
        #expect(item.sourceEventSequence == 12)
        #expect(item.kind == "reasoning")
    }

    @Test("turn finish distinguishes missing terminal items from authoritative empty items")
    func turnFinishItemsPresenceIsPreserved() throws {
        let legacy = try JSONDecoder().decode(
            SessionTimelineTurnFinishedEvent.self,
            from: Data(#"{"sessionId":"s","turnId":"t","fidelity":"committed"}"#.utf8)
        )
        let authoritativeEmpty = try JSONDecoder().decode(
            SessionTimelineTurnFinishedEvent.self,
            from: Data(#"{"sessionId":"s","turnId":"t","fidelity":"committed","items":[]}"#.utf8)
        )

        #expect(legacy.items == nil)
        #expect(authoritativeEmpty.items == [])
    }

    @Test("unknown protocol values remain visible in the canonical timeline")
    func unknownProtocolValuesArePreserved() throws {
        let unknown = timelineItem(
            id: "future",
            sequence: 1,
            itemOrdinal: 0,
            kind: "provider_future_event",
            body: "future payload",
            callID: nil,
            toolName: nil,
            outputText: nil,
            toolState: nil,
            fidelity: "future_fidelity"
        )

        let normalized = try #require(ChatTranscriptProjection.normalize([unknown]).first)
        #expect(normalized.kind == .unknown("provider_future_event"))
        #expect(normalized.fidelity == .unknown("future_fidelity"))

        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: [normalized],
            activeTurnID: nil,
            isRunning: false
        )
        let projectedTurn = try #require(firstTurn(in: transcript))
        #expect(projectedTurn.activity?.items.count == 1)
    }

    @Test("only text after the final activity becomes the final response")
    func finalContinuousTextSuffix() throws {
        let items = [
            timelineItem(id: "user", sequence: 11, itemOrdinal: 0, kind: "user", body: "执行"),
            timelineItem(id: "prelude", sequence: 2, itemOrdinal: 1, kind: "assistant_text", body: "先检查"),
            timelineItem(
                id: "tool",
                sequence: 90,
                itemOrdinal: 2,
                kind: "tool",
                callID: "call",
                toolName: "read",
                outputText: "ok",
                toolState: "completed"
            ),
            timelineItem(id: "candidate", sequence: 4, itemOrdinal: 3, kind: "assistant_text", body: "检查完成"),
            timelineItem(id: "late-reasoning", sequence: 1, itemOrdinal: 4, kind: "reasoning", body: "再确认一次"),
        ]
        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-1",
            timeline: ChatTranscriptProjection.normalize(items),
            activeTurnID: nil,
            isRunning: false
        )
        let turn = try #require(firstTurn(in: transcript))
        #expect(turn.assistant == nil)
        let narrations = turn.activity?.items.compactMap { item -> String? in
            guard case let .narration(text) = item else { return nil }
            return text.body
        }
        #expect(narrations == ["先检查", "检查完成"])
    }

    @Test("cross-page records use turn and item ordinals instead of storage sequence")
    func authoritativeOrdinalOrdering() {
        let normalized = ChatTranscriptProjection.normalize([
            timelineItem(id: "third", sequence: 1, itemOrdinal: 2, kind: "assistant_text"),
            timelineItem(id: "first", sequence: 99, itemOrdinal: 0, kind: "user"),
            timelineItem(id: "second", sequence: 5, itemOrdinal: 1, kind: "reasoning"),
        ])
        #expect(normalized.map(\.id) == ["first", "second", "third"])
    }

    @Test("large settled histories keep stable IDs without eagerly parsing Markdown")
    func largeHistoryIsStructurallyLazy() throws {
        var records: [SessionTimelineItem] = []
        records.reserveCapacity(2_000)
        let longBody = String(repeating: "paragraph **value**\n", count: 2_000)
        for ordinal in 0 ..< 1_000 {
            let turnID = "turn-\(ordinal)"
            records.append(
                SessionTimelineItem(
                    id: "user-\(ordinal)",
                    sessionID: "session-large",
                    turnID: turnID,
                    sequence: Int64(ordinal * 2),
                    turnOrdinal: Int64(ordinal),
                    itemOrdinal: 0,
                    kind: "user",
                    body: "request \(ordinal)"
                )
            )
            records.append(
                SessionTimelineItem(
                    id: "answer-\(ordinal)",
                    sessionID: "session-large",
                    turnID: turnID,
                    sequence: Int64(ordinal * 2 + 1),
                    turnOrdinal: Int64(ordinal),
                    itemOrdinal: 1,
                    kind: "assistant_text",
                    body: ordinal == 999 ? longBody : "answer \(ordinal)"
                )
            )
        }
        let transcript = ChatTranscriptProjection.project(
            sessionID: "session-large",
            timeline: ChatTranscriptProjection.normalize(records),
            activeTurnID: nil,
            isRunning: false
        )
        #expect(transcript.items.count == 1_000)
        #expect(Set(transcript.items.map(\.id)).count == 1_000)
        let turns = transcript.items.compactMap { item -> ChatTurnItem? in
            guard case let .turn(turn) = item else { return nil }
            return turn
        }
        #expect(turns.allSatisfy { $0.assistant?.markdown == nil })
        let lastAssistant = try #require(turns.last?.assistant)
        #expect(lastAssistant.body == longBody)
    }

    @Test("terminal announcement ignores failures from older turns")
    func terminalAnnouncementUsesNewestCompletedTurn() {
        let oldFailure = ChatTurnItem(
            id: "chat:turn:session-1:old",
            turnID: "old",
            userMessages: [],
            activity: ChatActivityGroup(
                id: "old-activity",
                turnID: "old",
                items: [
                    .tool(
                        ChatToolStep(
                            id: "old-tool",
                            callID: "old-call",
                            name: "Bash",
                            inputJSON: nil,
                            outputText: "failed",
                            state: .failed,
                            isError: true,
                            taskReferences: []
                        )
                    ),
                ],
                isRunning: false,
                hasFailure: true
            ),
            assistant: nil,
            notices: [],
            errors: [ChatErrorItem(id: "old-error", body: "旧错误")],
            isRunning: false
        )
        let newestSuccess = ChatTurnItem(
            id: "chat:turn:session-1:new",
            turnID: "new",
            userMessages: [],
            activity: nil,
            assistant: ChatTextItem(
                id: "new-answer",
                turnID: "new",
                body: "已完成",
                markdown: nil,
                attachments: [],
                taskReferences: [],
                createdAt: "",
                timeLabel: nil,
                isStreaming: false
            ),
            notices: [],
            errors: [],
            isRunning: false
        )
        let transcript = ChatTranscript(
            sessionID: "session-1",
            items: [.turn(oldFailure), .turn(newestSuccess)],
            tailRevision: 2,
            isRunning: false
        )

        #expect(
            ChatTerminalAnnouncementResolver.announcement(for: transcript)
                == "Agent 已完成回复"
        )
    }

    private func firstTurn(in transcript: ChatTranscript) -> ChatTurnItem? {
        for item in transcript.items {
            if case let .turn(turn) = item { return turn }
        }
        return nil
    }

    private func timelineItem(
        id: String,
        sequence: Int64,
        turnID: String = "turn-1",
        turnOrdinal: Int64 = 1,
        itemOrdinal: Int64,
        kind: String,
        body: String = "",
        callID: String? = nil,
        toolName: String? = nil,
        outputText: String? = nil,
        toolState: String? = nil,
        fidelity: String = "exact"
    ) -> SessionTimelineItem {
        SessionTimelineItem(
            id: id,
            sessionID: "session-1",
            turnID: turnID,
            sequence: sequence,
            turnOrdinal: turnOrdinal,
            itemOrdinal: itemOrdinal,
            kind: kind,
            body: body,
            callID: callID,
            toolName: toolName,
            outputText: outputText,
            toolState: toolState,
            fidelity: fidelity
        )
    }

    private func sessionMessage(
        id: String,
        sequence: Int64,
        role: SessionMessageRole,
        kind: String = "text",
        body: String,
        payloadJSON: String? = nil
    ) -> SessionMessage {
        SessionMessage(
            id: id,
            sessionID: "session-1",
            turnID: "turn-1",
            sequence: sequence,
            clientMessageID: nil,
            role: role,
            kind: kind,
            body: body,
            payloadJSON: payloadJSON,
            createdAt: "now",
            updatedAt: "now"
        )
    }
}
