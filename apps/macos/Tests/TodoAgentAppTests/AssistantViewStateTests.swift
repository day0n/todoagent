import Foundation
import Testing
@testable import TodoAgentApp

@MainActor
struct AssistantViewStateTests {
    @Test("delta retry replaces an older streaming attempt")
    func deltaRetryReplacesDraft() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)
        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "旧"))
        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "回复"))
        #expect(state.selectedDraft?.body == "旧回复")

        await state.consumeAssistantEvent(try deltaEvent(attempt: 2, delta: "新"))
        #expect(state.selectedDraft?.body == "新")

        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "应忽略"))
        await state.consumeAssistantEvent(try deltaEvent(attempt: 2, delta: "答案"))
        #expect(state.selectedDraft?.body == "新答案")
        #expect(state.selectedDraft?.attempt == 2)
    }

    @Test("a sequence gap backfills history and duplicate appended events are idempotent")
    func sequenceGapBackfillsOnce() async throws {
        let session = sessionDescriptor(lastSequence: 2)
        let first = assistantMessage(id: "message-1", sequence: 1, role: .user, body: "创建任务")
        let second = assistantMessage(id: "message-2", sequence: 2, role: .todoAgent, body: "已创建")
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session, messages: [first, second])]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        let appended = try messageAppendedEvent(second)

        await state.consumeAssistantEvent(appended)
        await state.consumeAssistantEvent(appended)
        await state.selectSession(session.id)

        #expect(state.selectedMessages.map(\.sequence) == [1, 2])
        #expect(state.selectedMessages.filter { $0.id == second.id }.count == 1)
        #expect(await repository.historyRequests() == [0])
    }

    @Test("a persisted assistant message replaces the streaming draft")
    func appendedMessageClearsDraft() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)

        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "流式内容"))
        #expect(state.selectedDraft?.body == "流式内容")

        let final = assistantMessage(id: "assistant-final", sequence: 1, role: .todoAgent, body: "最终内容")
        await state.consumeAssistantEvent(try messageAppendedEvent(final))
        await state.consumeAssistantEvent(try deltaEvent(attempt: 2, delta: "迟到分片"))

        #expect(state.selectedDraft == nil)
        #expect(state.selectedMessages == [final])
    }

    @Test("session state clears a stale running turn when turn.finished was dropped")
    func sessionChangedClearsDroppedFinishedTurn() async throws {
        let runningSession = sessionDescriptor(isRunning: true)
        let activeTurn = AssistantTurn(
            id: "turn-1",
            sessionID: runningSession.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            runningSession.id: AssistantSessionBundle(
                session: runningSession,
                activeTurn: activeTurn
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        #expect(state.isSelectedSessionRunning)

        let idleSession = sessionDescriptor(isRunning: false)
        await state.consumeAssistantEvent(try sessionChangedEvent(idleSession))

        #expect(!state.isSelectedSessionRunning)
        #expect(state.selectedDraft == nil)
    }

    @Test("session state backfills a dropped final message")
    func sessionChangedBackfillsDroppedMessage() async throws {
        let session = sessionDescriptor(lastSequence: 2)
        let messages = [
            assistantMessage(id: "message-1", sequence: 1, role: .user, body: "问题"),
            assistantMessage(id: "message-2", sequence: 2, role: .todoAgent, body: "最终回复"),
        ]
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, messages: messages),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })

        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)

        #expect(state.selectedMessages == messages)
        #expect(await repository.historyRequests() == [0])
    }

    @Test("long histories page until every stable message is loaded")
    func longHistoryLoadsEveryPage() async {
        let messages = (1 ... 1_001).map { sequence in
            assistantMessage(
                id: "message-\(sequence)",
                sequence: Int64(sequence),
                role: sequence.isMultiple(of: 2) ? .todoAgent : .user,
                body: "message \(sequence)"
            )
        }
        let session = sessionDescriptor(lastSequence: 1_001)
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session, messages: messages)],
            historyPageSize: 500
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })

        await state.load()

        #expect(state.selectedMessages.count == 1_001)
        #expect(await repository.historyRequests() == [0, 500, 1_000])
    }

    @Test("persisted tools and task references return after a restart")
    func persistedToolsRestore() async throws {
        let taskID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000301"))
        let session = sessionDescriptor(lastSequence: 2)
        let messages = [
            assistantMessage(id: "message-1", sequence: 1, role: .user, body: "创建任务"),
            assistantMessage(id: "message-2", sequence: 2, role: .todoAgent, body: "已创建"),
        ]
        let tool = AssistantPersistedTool(
            id: "tool-execution-1",
            sessionID: session.id,
            turnID: "turn-1",
            callID: "call-1",
            toolName: "create_tasks",
            taskRefsJSON: "[\"\(taskID.uuidString.lowercased())\"]",
            isError: false,
            status: "completed"
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(
                session: session,
                messages: messages,
                tools: [tool]
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })

        await state.load()

        #expect(state.selectedTools.count == 1)
        #expect(state.selectedTools.first?.name == "create_tasks")
        #expect(state.selectedTools.first?.state == .completed)
        #expect(state.selectedTools.first?.taskReferences == [taskID])
    }

    @Test("tool activity stays inside its turn instead of collecting below the transcript")
    func conversationTimelineInterleavesToolsByTurn() async {
        let session = sessionDescriptor(lastSequence: 4)
        let messages = [
            AssistantMessage(
                id: "message-user-1",
                sessionID: session.id,
                turnID: "turn-1",
                sequence: 1,
                role: .user,
                body: "先创建任务"
            ),
            AssistantMessage(
                id: "message-agent-1",
                sessionID: session.id,
                turnID: "turn-1",
                sequence: 2,
                role: .todoAgent,
                body: "已创建"
            ),
            AssistantMessage(
                id: "message-user-2",
                sessionID: session.id,
                turnID: "turn-2",
                sequence: 3,
                role: .user,
                body: "再查询任务"
            ),
            AssistantMessage(
                id: "message-agent-2",
                sessionID: session.id,
                turnID: "turn-2",
                sequence: 4,
                role: .todoAgent,
                body: "查询完成"
            ),
        ]
        // Deliberately use call IDs whose alphabetical order is the opposite
        // of the Engine history order. The timeline must preserve occurrence
        // order and place each tool before that turn's final reply.
        let tools = [
            AssistantPersistedTool(
                id: "tool-1",
                sessionID: session.id,
                turnID: "turn-1",
                callID: "z-first",
                toolName: "create_tasks",
                taskRefsJSON: nil,
                isError: false,
                status: "completed"
            ),
            AssistantPersistedTool(
                id: "tool-2",
                sessionID: session.id,
                turnID: "turn-1",
                callID: "a-second",
                toolName: "find_related",
                taskRefsJSON: nil,
                isError: false,
                status: "completed"
            ),
            AssistantPersistedTool(
                id: "tool-3",
                sessionID: session.id,
                turnID: "turn-2",
                callID: "m-third",
                toolName: "list_state",
                taskRefsJSON: nil,
                isError: false,
                status: "completed"
            ),
        ]
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, messages: messages, tools: tools),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })

        await state.load()

        #expect(state.selectedTimelineItems.map(\.id) == [
            "message-message-user-1",
            "tool-group-turn-1",
            "message-message-agent-1",
            "message-message-user-2",
            "tool-group-turn-2",
            "message-message-agent-2",
        ])

        let groups = state.selectedTimelineItems.compactMap { item -> AssistantToolGroup? in
            guard case let .toolGroup(group) = item else { return nil }
            return group
        }
        #expect(groups.map { $0.tools.map(\.toolCallID) } == [
            ["z-first", "a-second"],
            ["m-third"],
        ])
    }

    @Test("live text remains ordered around tool boundaries")
    func liveTextToolTextInterleaving() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let user = assistantMessage(id: "user", sequence: 1, role: .user, body: "检查")
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(
                session: session,
                messages: [user],
                activeTurn: turn
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "先读取"))
        let initialTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let initialNarrationID = try #require(initialTurn.activity?.items.first?.id)

        let started = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "toolCallId": "call-1",
            "name": "list_state",
        ])
        await state.consumeAssistantEvent(EngineEvent(name: "assistant.tool.started", data: started))
        let finished = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "toolCallId": "call-1",
            "name": "list_state",
            "isError": false,
            "taskReferences": [],
        ])
        await state.consumeAssistantEvent(EngineEvent(name: "assistant.tool.finished", data: finished))
        await state.consumeAssistantEvent(try deltaEvent(attempt: 2, delta: "最终结果"))

        let projectedTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let activity = try #require(projectedTurn.activity)
        #expect(projectedTurn.id == initialTurn.id)
        #expect(activity.items.first?.id == initialNarrationID)
        #expect(activity.items.compactMap { item -> String? in
            guard case let .narration(text) = item else { return nil }
            return text.body
        } == ["先读取", "最终结果"])
        #expect(activity.items.compactMap { item -> String? in
            guard case let .tool(tool) = item else { return nil }
            return tool.callID
        } == ["call-1"])
    }

    @Test("live reducer coalesces six thousand deltas into bounded stable parts")
    func liveReducerStressKeepsPartCountBounded() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        let delta = try deltaEvent(attempt: 1, delta: "x")

        for toolIndex in 0..<20 {
            for _ in 0..<300 {
                await state.consumeAssistantEvent(delta)
            }
            let callID = "stress-call-\(toolIndex)"
            let started = try JSONSerialization.data(withJSONObject: [
                "sessionId": session.id,
                "turnId": turn.id,
                "toolCallId": callID,
                "name": "stress_tool",
            ])
            await state.consumeAssistantEvent(
                EngineEvent(name: "assistant.tool.started", data: started)
            )
            let finished = try JSONSerialization.data(withJSONObject: [
                "sessionId": session.id,
                "turnId": turn.id,
                "toolCallId": callID,
                "name": "stress_tool",
                "isError": false,
                "taskReferences": [],
            ])
            await state.consumeAssistantEvent(
                EngineEvent(name: "assistant.tool.finished", data: finished)
            )
        }

        let transcript = state.selectedChatTranscript
        let turns = chatTurns(transcript)
        let activity = try #require(turns.first?.activity)
        #expect(turns.count == 1)
        #expect(turns.first?.isRunning == true)
        #expect(activity.items.count == 40)
        #expect(Set(activity.items.map(\.id)).count == 40)
        let narration = activity.items.compactMap { item -> ChatTextItem? in
            guard case let .narration(text) = item else { return nil }
            return text
        }
        #expect(narration.count == 20)
        #expect(narration.allSatisfy { $0.body.count == 300 })
        #expect(activity.items.count < 6_000)
    }

    @Test("live text and reasoning enforce Engine UTF-8 bounds")
    func liveBodiesRespectEngineBounds() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let oversizedText = String(
            repeating: "界",
            count: AssistantLiveContentBounds.assistantTextBytes / 3 + 100
        )
        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: oversizedText))
        let oversizedReasoning = String(
            repeating: "思",
            count: AssistantLiveContentBounds.reasoningBytes / 3 + 100
        )
        let thought = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "attempt": 1,
            "providerAttempt": 1,
            "interactionOrdinal": 1,
            "partId": "bounded-reasoning",
            "partOrdinal": 0,
            "isDelta": true,
            "originalBytes": oversizedReasoning.utf8.count,
            "truncated": true,
            "content": oversizedReasoning,
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.thought.summary", data: thought)
        )

        let activity = try #require(firstChatTurn(state.selectedChatTranscript)?.activity)
        let text = try #require(activity.items.compactMap { item -> ChatTextItem? in
            guard case let .narration(text) = item else { return nil }
            return text
        }.first)
        let reasoning = try #require(activity.items.compactMap { item -> ChatReasoningItem? in
            guard case let .reasoning(reasoning) = item else { return nil }
            return reasoning
        }.first)
        #expect(text.body.utf8.count <= AssistantLiveContentBounds.assistantTextBytes)
        #expect(reasoning.body.utf8.count <= AssistantLiveContentBounds.reasoningBytes)
    }

    @Test("one MiB stream has one canonical retained text body")
    func largeStreamUsesSingleLiveTextAuthority() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let engineSizedDelta = String(repeating: "x", count: 8_192)
        let delta = try deltaEvent(attempt: 1, delta: engineSizedDelta)
        for _ in 0..<128 {
            await state.consumeAssistantEvent(delta)
        }

        let draft = try #require(state.selectedDraft)
        let activity = try #require(firstChatTurn(state.selectedChatTranscript)?.activity)
        let narration = try #require(activity.items.compactMap { item -> ChatTextItem? in
            guard case let .narration(text) = item else { return nil }
            return text
        }.first)
        #expect(draft.bodyUTF8ByteCount == AssistantLiveContentBounds.assistantTextBytes)
        #expect(narration.body == draft.body)
        #expect(state.retainedLiveTextBodyCount == 1)
        #expect(state.retainedLiveTextUTF8ByteCount == AssistantLiveContentBounds.assistantTextBytes)
    }

    @Test("live public thought summaries appear as reasoning")
    func liveThoughtSummaryProjection() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "attempt": 1,
            "content": "先核对相关任务",
        ])
        await state.consumeAssistantEvent(EngineEvent(name: "assistant.thought.summary", data: data))

        let projectedTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        guard case let .reasoning(reasoning) = projectedTurn.activity?.items.first else {
            Issue.record("thought summary should project as reasoning")
            return
        }
        #expect(reasoning.body == "先核对相关任务")
        #expect(reasoning.isStreaming)
    }

    @Test("delta thought updates accumulate into one stable reasoning part")
    func thoughtDeltaUpdatesAccumulate() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        for content in ["先检查", "，再确认"] {
            let data = try JSONSerialization.data(withJSONObject: [
                "sessionId": session.id,
                "turnId": turn.id,
                "attempt": 1,
                "partId": "reasoning-part-1",
                "partOrdinal": 0,
                "isDelta": true,
                "content": content,
            ])
            await state.consumeAssistantEvent(
                EngineEvent(name: "assistant.thought.summary", data: data)
            )
        }

        let activity = try #require(firstChatTurn(state.selectedChatTranscript)?.activity)
        let reasoning = activity.items.compactMap { item -> ChatReasoningItem? in
            guard case let .reasoning(reasoning) = item else { return nil }
            return reasoning
        }
        #expect(reasoning.count == 1)
        #expect(reasoning.first?.body == "先检查，再确认")
    }

    @Test("reasoning remains ordered across a tool interaction")
    func liveReasoningToolReasoningInterleaving() async throws {
        let session = sessionDescriptor(isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: session.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, activeTurn: turn),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let firstThought = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "attempt": 1,
            "providerAttempt": 1,
            "interactionOrdinal": 1,
            "partId": "turn-1-reasoning-1",
            "partOrdinal": 0,
            "isDelta": true,
            "originalBytes": 30,
            "truncated": false,
            "content": "先判断需要读取任务",
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.thought.summary", data: firstThought)
        )

        let started = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "toolCallId": "call-1",
            "name": "list_state",
        ])
        await state.consumeAssistantEvent(EngineEvent(name: "assistant.tool.started", data: started))
        let finished = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "toolCallId": "call-1",
            "name": "list_state",
            "isError": false,
            "taskReferences": [],
        ])
        await state.consumeAssistantEvent(EngineEvent(name: "assistant.tool.finished", data: finished))

        let secondThought = try JSONSerialization.data(withJSONObject: [
            "sessionId": session.id,
            "turnId": turn.id,
            "attempt": 2,
            "providerAttempt": 1,
            "interactionOrdinal": 2,
            "partId": "turn-1-reasoning-2",
            "partOrdinal": 0,
            "isDelta": true,
            "originalBytes": 39,
            "truncated": false,
            "content": "读取完成，继续组织答案",
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.thought.summary", data: secondThought)
        )

        let projectedTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let activity = try #require(projectedTurn.activity)
        #expect(activity.items.count == 3)
        let reasoning = activity.items.compactMap { item -> ChatReasoningItem? in
            guard case let .reasoning(reasoning) = item else { return nil }
            return reasoning
        }
        #expect(reasoning.map(\.body) == [
            "先判断需要读取任务",
            "读取完成，继续组织答案",
        ])
        #expect(Set(reasoning.map(\.id)).count == 2)
        #expect(reasoning.map(\.isStreaming) == [false, true])
        #expect(reasoning.map {
            ChatDisclosurePreference.automatic.resolved(automaticValue: $0.isStreaming)
        } == [false, true])
        #expect(activity.items.compactMap { item -> String? in
            guard case let .tool(tool) = item else { return nil }
            return tool.callID
        } == ["call-1"])
    }

    @Test("ordered Assistant history takes precedence over legacy messages and tools")
    func orderedHistoryIsPreferred() async throws {
        let session = sessionDescriptor(lastSequence: 2)
        let legacy = [
            assistantMessage(id: "legacy-user", sequence: 1, role: .user, body: "legacy"),
            assistantMessage(id: "legacy-answer", sequence: 2, role: .todoAgent, body: "wrong"),
        ]
        let timeline = [
            SessionTimelineItem(
                id: "ordered-user",
                sessionID: session.id,
                turnID: "turn-1",
                sequence: 8,
                turnOrdinal: 1,
                itemOrdinal: 0,
                kind: "user",
                body: "ordered"
            ),
            SessionTimelineItem(
                id: "ordered-reasoning",
                sessionID: session.id,
                turnID: "turn-1",
                sequence: 3,
                turnOrdinal: 1,
                itemOrdinal: 1,
                kind: "reasoning",
                body: "summary only"
            ),
            SessionTimelineItem(
                id: "ordered-answer",
                sessionID: session.id,
                turnID: "turn-1",
                sequence: 1,
                turnOrdinal: 1,
                itemOrdinal: 2,
                kind: "assistant_text",
                body: "correct"
            ),
        ]
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(
                session: session,
                messages: legacy,
                timeline: timeline
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let turn = try #require(firstChatTurn(state.selectedChatTranscript))
        #expect(turn.userMessages.first?.body == "ordered")
        #expect(turn.assistant?.body == "correct")
        guard case let .reasoning(reasoning) = turn.activity?.items.first else {
            Issue.record("ordered reasoning should be retained")
            return
        }
        #expect(reasoning.body == "summary only")
    }

    @Test("turn completion reconciles a dropped tool event from SQLite")
    func droppedToolEventReconciles() async throws {
        let taskID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000302"))
        let runningSession = sessionDescriptor(lastSequence: 1, isRunning: true)
        let turn = AssistantTurn(
            id: "turn-1",
            sessionID: runningSession.id,
            clientMessageID: "00000000-0000-4000-8000-000000000303",
            model: "gemini-test",
            status: .running
        )
        let user = assistantMessage(id: "message-1", sequence: 1, role: .user, body: "创建任务")
        let repository = AssistantTestRepository(bundles: [
            runningSession.id: AssistantSessionBundle(
                session: runningSession,
                messages: [user],
                activeTurn: turn
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        #expect(state.selectedTools.isEmpty)

        let completedSession = sessionDescriptor(lastSequence: 2, isRunning: false)
        let reply = assistantMessage(id: "message-2", sequence: 2, role: .todoAgent, body: "已创建")
        let tool = AssistantPersistedTool(
            id: "tool-execution-2",
            sessionID: completedSession.id,
            turnID: turn.id,
            callID: "call-dropped",
            toolName: "create_tasks",
            taskRefsJSON: "[\"\(taskID.uuidString.lowercased())\"]",
            isError: false,
            status: "completed"
        )
        await repository.setBundle(AssistantSessionBundle(
            session: completedSession,
            messages: [user, reply],
            tools: [tool]
        ))
        let finished = AssistantTurn(
            id: turn.id,
            sessionID: turn.sessionID,
            clientMessageID: turn.clientMessageID,
            model: turn.model,
            status: .completed
        )
        let finishedData = try JSONSerialization.data(withJSONObject: [
            "sessionId": completedSession.id,
            "turn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(finished)),
        ])

        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.finished",
            data: finishedData
        ))
        await repository.waitUntilHistoryRequestCount(2)
        await drainMainActorTasks()

        #expect(state.selectedTools.first?.toolCallID == "call-dropped")
        #expect(state.selectedTools.first?.taskReferences == [taskID])
        #expect(state.selectedMessages.last == reply)
    }

    @Test("a finished history response cannot clear the next assistant turn")
    func staleFinishedHistoryPreservesNewAssistantTurn() async throws {
        let runningSessionA = sessionDescriptor(isRunning: true)
        let turnA = AssistantTurn(
            id: "turn-a",
            sessionID: runningSessionA.id,
            model: "gemini-test",
            status: .running
        )
        let repository = AssistantTestRepository(
            bundles: [
                runningSessionA.id: AssistantSessionBundle(
                    session: runningSessionA,
                    activeTurn: turnA
                ),
            ],
            suspendHistoryAfterRequestCount: 1
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let finishedA = AssistantTurn(
            id: turnA.id,
            sessionID: turnA.sessionID,
            model: turnA.model,
            status: .completed
        )
        let finishData = try JSONSerialization.data(withJSONObject: [
            "sessionId": runningSessionA.id,
            "turn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(finishedA)),
        ])
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.finished",
            data: finishData
        ))
        await repository.waitUntilHistoryRequestCount(2)

        let turnB = AssistantTurn(
            id: "turn-b",
            sessionID: runningSessionA.id,
            model: "gemini-test",
            status: .running
        )
        let startData = try JSONSerialization.data(withJSONObject: [
            "sessionId": runningSessionA.id,
            "turn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(turnB)),
        ])
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.started",
            data: startData
        ))
        let deltaData = try JSONSerialization.data(withJSONObject: [
            "sessionId": runningSessionA.id,
            "turnId": turnB.id,
            "messageId": "turn-b-draft",
            "attempt": 1,
            "delta": "第二轮仍在输出",
        ])
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.message.delta",
            data: deltaData
        ))

        let staleCompletedA = AssistantSessionBundle(
            session: sessionDescriptor(isRunning: false),
            messages: [
                AssistantMessage(
                    id: "answer-a",
                    sessionID: runningSessionA.id,
                    turnID: turnA.id,
                    sequence: 1,
                    role: .todoAgent,
                    body: "第一轮结果"
                ),
            ],
            activeTurn: nil
        )
        await repository.releaseSuspendedHistory(with: staleCompletedA)
        await drainMainActorTasks()

        #expect(state.isSelectedSessionRunning)
        #expect(state.selectedDraft?.turnID == turnB.id)
        #expect(state.selectedDraft?.body == "第二轮仍在输出")
        #expect(state.selectedChatTranscript.isRunning)
        #expect(chatTurns(state.selectedChatTranscript).last?.turnID == turnB.id)
        #expect(chatTurns(state.selectedChatTranscript).last?.isRunning == true)
    }

    @Test("third live turn completion preserves earlier authoritative turns")
    func completedLiveTurnKeepsPriorHistory() async throws {
        func item(
            _ id: String,
            turnID: String,
            turnOrdinal: Int64,
            itemOrdinal: Int64,
            kind: String,
            body: String
        ) -> SessionTimelineItem {
            SessionTimelineItem(
                id: id,
                sessionID: "assistant-session",
                turnID: turnID,
                sequence: turnOrdinal * 10 + itemOrdinal,
                turnOrdinal: turnOrdinal,
                itemOrdinal: itemOrdinal,
                kind: kind,
                body: body
            )
        }

        let runningSession = sessionDescriptor(isRunning: true)
        let activeTurn = AssistantTurn(
            id: "turn-3",
            sessionID: runningSession.id,
            model: "gemini-test",
            status: .running
        )
        let initialTimeline = [
            item("u1", turnID: "turn-1", turnOrdinal: 1, itemOrdinal: 0, kind: "user", body: "第一问"),
            item("a1", turnID: "turn-1", turnOrdinal: 1, itemOrdinal: 1, kind: "assistant_text", body: "第一答"),
            item("u2", turnID: "turn-2", turnOrdinal: 2, itemOrdinal: 0, kind: "user", body: "第二问"),
            item("a2", turnID: "turn-2", turnOrdinal: 2, itemOrdinal: 1, kind: "assistant_text", body: "第二答"),
            item("u3", turnID: "turn-3", turnOrdinal: 3, itemOrdinal: 0, kind: "user", body: "第三问"),
        ]
        let repository = AssistantTestRepository(bundles: [
            runningSession.id: AssistantSessionBundle(
                session: runningSession,
                timeline: initialTimeline,
                activeTurn: activeTurn
            ),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let deltaData = try JSONSerialization.data(withJSONObject: [
            "sessionId": runningSession.id,
            "turnId": activeTurn.id,
            "messageId": "live-third-answer",
            "attempt": 1,
            "delta": "临时流式第三答",
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.message.delta", data: deltaData)
        )
        #expect(chatTurns(state.selectedChatTranscript).prefix(2).map(\.id) == [
            "chat:turn:assistant-session:turn-1",
            "chat:turn:assistant-session:turn-2",
        ])

        let completedSession = sessionDescriptor(isRunning: false)
        let authoritativeTimeline = initialTimeline + [
            item(
                "a3",
                turnID: "turn-3",
                turnOrdinal: 3,
                itemOrdinal: 1,
                kind: "assistant_text",
                body: "权威最终第三答"
            ),
        ]
        await repository.setBundle(
            AssistantSessionBundle(
                session: completedSession,
                timeline: authoritativeTimeline,
                activeTurn: nil
            )
        )
        let completedTurn = AssistantTurn(
            id: activeTurn.id,
            sessionID: activeTurn.sessionID,
            model: activeTurn.model,
            status: .completed
        )
        let finishedData = try JSONSerialization.data(withJSONObject: [
            "sessionId": completedSession.id,
            "turn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(completedTurn)),
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.turn.finished", data: finishedData)
        )

        // Before SQLite reconciliation gets a chance to run, the retained live
        // third turn must only replace parts belonging to turn 3.
        let optimisticTurns = chatTurns(state.selectedChatTranscript)
        #expect(optimisticTurns.map(\.id) == [
            "chat:turn:assistant-session:turn-1",
            "chat:turn:assistant-session:turn-2",
            "chat:turn:assistant-session:turn-3",
        ])
        #expect(optimisticTurns[0].assistant?.body == "第一答")
        #expect(optimisticTurns[1].assistant?.body == "第二答")

        await repository.waitUntilHistoryRequestCount(2)
        await drainMainActorTasks()
        let reconciledTurns = chatTurns(state.selectedChatTranscript)
        #expect(reconciledTurns.map(\.id) == optimisticTurns.map(\.id))
        #expect(reconciledTurns[0].assistant?.body == "第一答")
        #expect(reconciledTurns[1].assistant?.body == "第二答")
        #expect(reconciledTurns[2].assistant?.body == "权威最终第三答")
        #expect(reconciledTurns[2].activity == nil)
    }

    @Test("restored running turn preserves earlier interaction parts when new live parts arrive")
    func restoredRunningTurnMergesPartialLivePartsPrecisely() async throws {
        func item(
            _ id: String,
            sessionID: String,
            turnID: String,
            itemOrdinal: Int64,
            kind: String,
            body: String = "",
            callID: String? = nil,
            toolName: String? = nil,
            toolState: String? = nil
        ) -> SessionTimelineItem {
            SessionTimelineItem(
                id: id,
                sessionID: sessionID,
                turnID: turnID,
                sequence: itemOrdinal + 1,
                turnOrdinal: 1,
                itemOrdinal: itemOrdinal,
                kind: kind,
                body: body,
                callID: callID,
                toolName: toolName,
                toolState: toolState
            )
        }

        let sessionA = sessionDescriptor(id: "assistant-session-a", isRunning: true)
        let sessionB = sessionDescriptor(id: "assistant-session-b")
        let turn = AssistantTurn(
            id: "shared-running-turn",
            sessionID: sessionA.id,
            model: "gemini-test",
            status: .running
        )
        let earlyTimeline = [
            item("early-user", sessionID: sessionA.id, turnID: turn.id, itemOrdinal: 0, kind: "user", body: "继续检查"),
            item("early-reasoning", sessionID: sessionA.id, turnID: turn.id, itemOrdinal: 1, kind: "reasoning", body: "早期思考"),
            item("early-text", sessionID: sessionA.id, turnID: turn.id, itemOrdinal: 2, kind: "assistant_text", body: "先读取"),
            item(
                "early-tool",
                sessionID: sessionA.id,
                turnID: turn.id,
                itemOrdinal: 3,
                kind: "tool",
                callID: "call-early",
                toolName: "read",
                toolState: "completed"
            ),
        ]
        let repository = AssistantTestRepository(bundles: [
            sessionA.id: AssistantSessionBundle(
                session: sessionA,
                timeline: earlyTimeline,
                activeTurn: turn
            ),
            sessionB.id: AssistantSessionBundle(session: sessionB),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        await state.selectSession(sessionB.id)
        await state.selectSession(sessionA.id)

        let restoredTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let restoredActivity = try #require(restoredTurn.activity)
        let earlyReasoningID = try #require(restoredActivity.items.first { item in
            guard case let .reasoning(reasoning) = item else { return false }
            return reasoning.body == "早期思考"
        }?.id)
        let earlyTextID = try #require(restoredActivity.items.first { item in
            guard case let .narration(text) = item else { return false }
            return text.body == "先读取"
        }?.id)

        let thoughtData = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionA.id,
            "turnId": turn.id,
            "attempt": 2,
            "providerAttempt": 1,
            "interactionOrdinal": 2,
            "partId": "new-reasoning-part",
            "partOrdinal": 0,
            "isDelta": true,
            "originalBytes": 12,
            "truncated": false,
            "content": "新思考",
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.thought.summary", data: thoughtData)
        )
        let deltaData = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionA.id,
            "turnId": turn.id,
            "messageId": "new-live-text",
            "attempt": 2,
            "delta": "新回答",
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.message.delta", data: deltaData)
        )

        let liveTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let liveActivity = try #require(liveTurn.activity)
        #expect(liveActivity.items.contains { $0.id == earlyReasoningID })
        #expect(liveActivity.items.contains { $0.id == earlyTextID })
        #expect(liveActivity.items.compactMap { item -> String? in
            guard case let .reasoning(reasoning) = item else { return nil }
            return reasoning.body
        } == ["早期思考", "新思考"])
        #expect(liveActivity.items.compactMap { item -> String? in
            guard case let .narration(text) = item else { return nil }
            return text.body
        } == ["先读取", "新回答"])

        let authoritativeTimeline = earlyTimeline + [
            item("new-reasoning", sessionID: sessionA.id, turnID: turn.id, itemOrdinal: 4, kind: "reasoning", body: "新思考"),
            item("final-text", sessionID: sessionA.id, turnID: turn.id, itemOrdinal: 5, kind: "assistant_text", body: "权威最终回答"),
        ]
        await repository.setBundle(
            AssistantSessionBundle(
                session: sessionDescriptor(id: sessionA.id),
                timeline: authoritativeTimeline,
                activeTurn: nil
            )
        )
        let historyCountBeforeFinish = await repository.historyRequests().count
        let completedTurn = AssistantTurn(
            id: turn.id,
            sessionID: turn.sessionID,
            model: turn.model,
            status: .completed
        )
        let finishData = try JSONSerialization.data(withJSONObject: [
            "sessionId": sessionA.id,
            "turn": try JSONSerialization.jsonObject(with: JSONEncoder().encode(completedTurn)),
        ])
        await state.consumeAssistantEvent(
            EngineEvent(name: "assistant.turn.finished", data: finishData)
        )
        await repository.waitUntilHistoryRequestCount(historyCountBeforeFinish + 1)
        await drainMainActorTasks()

        let reconciledTurn = try #require(firstChatTurn(state.selectedChatTranscript))
        let reconciledActivity = try #require(reconciledTurn.activity)
        #expect(reconciledActivity.items.contains { $0.id == earlyReasoningID })
        #expect(reconciledActivity.items.contains { $0.id == earlyTextID })
        #expect(reconciledActivity.items.compactMap { item -> String? in
            guard case let .reasoning(reasoning) = item else { return nil }
            return reasoning.body
        } == ["早期思考", "新思考"])
        #expect(reconciledActivity.items.compactMap { item -> String? in
            guard case let .narration(text) = item else { return nil }
            return text.body
        } == ["先读取"])
        #expect(reconciledTurn.assistant?.body == "权威最终回答")
        #expect(Set(reconciledActivity.items.map(\.id)).count == reconciledActivity.items.count)
    }

    @Test("background tool events do not retain detailed history")
    func backgroundToolEventsStayOutOfCache() async throws {
        let selected = sessionDescriptor()
        let background = sessionDescriptor(id: "z-background", isRunning: true)
        let repository = AssistantTestRepository(bundles: [
            selected.id: AssistantSessionBundle(session: selected),
            background.id: AssistantSessionBundle(session: background),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        await state.selectSession(selected.id)
        #expect(state.selectedSessionID == selected.id)

        let started = try JSONSerialization.data(withJSONObject: [
            "sessionId": background.id,
            "turnId": "background-turn",
            "toolCallId": "background-call",
            "name": "list_state",
        ])
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.tool.started",
            data: started
        ))
        let finished = try JSONSerialization.data(withJSONObject: [
            "sessionId": background.id,
            "turnId": "background-turn",
            "toolCallId": "background-call",
            "name": "list_state",
            "isError": false,
            "taskReferences": [],
        ])
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.tool.finished",
            data: finished
        ))

        #expect(state.selectedTools.isEmpty)
        #expect(state.detailedSessionCacheCount == 0)
    }

    @Test("assistant streaming never mutates the global app snapshot")
    func streamingIsolatedFromAppSnapshot() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let appState = AppState(repository: repository)

        await appState.assistant.consumeAssistantEvent(try sessionChangedEvent(session))
        await appState.assistant.selectSession(session.id)
        await appState.assistant.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "流式内容"))

        #expect(appState.messages.isEmpty)
        #expect(appState.assistant.selectedDraft?.body == "流式内容")
    }

    @Test("a busy session rejects another send")
    func busySessionRejectsSend() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        let turnJSON = #"{"sessionId":"assistant-session","turn":{"id":"turn-1","sessionId":"assistant-session","clientMessageId":"client-1","model":"gemini-3.6-flash","status":"running"}}"#
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.started",
            data: Data(turnJSON.utf8)
        ))

        #expect(state.isSelectedSessionRunning)
        #expect(await state.send(text: "第二条", model: "gemini-3.6-flash") == false)
        #expect(await repository.sendCount() == 0)
    }

    @Test("a failed send retries with the same client message id")
    func failedSendKeepsIdempotencyKey() async {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            sendFailuresRemaining: 1
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        #expect(await state.send(text: "创建任务", model: "gemini-test") == false)
        let firstIdentifier = await repository.sentClientMessageIDs().first
        let clientMessageID = firstIdentifier?.uuidString ?? "missing"
        let startedJSON = """
        {"sessionId":"assistant-session","turn":{"id":"turn-accepted","sessionId":"assistant-session","clientMessageId":"\(clientMessageID)","model":"gemini-test","status":"running"}}
        """
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.started",
            data: Data(startedJSON.utf8)
        ))
        let finishedJSON = """
        {"sessionId":"assistant-session","turn":{"id":"turn-accepted","sessionId":"assistant-session","clientMessageId":"\(clientMessageID)","model":"gemini-test","status":"completed"}}
        """
        await state.consumeAssistantEvent(EngineEvent(
            name: "assistant.turn.finished",
            data: Data(finishedJSON.utf8)
        ))
        #expect(await state.send(text: "创建任务", model: "gemini-test") == true)

        let identifiers = await repository.sentClientMessageIDs()
        #expect(identifiers.count == 2)
        #expect(identifiers.first == identifiers.last)
    }

    @Test("a persisted send is accepted when its response is lost")
    func persistedSendSurvivesResponseFailure() async {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            sendFailuresRemaining: 1,
            persistFailedSend: true
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        #expect(await state.send(text: "创建任务", model: "gemini-test"))
        #expect(await repository.sendCount() == 1)
        #expect(state.selectedMessages.count == 1)
        #expect(state.selectedMessages.first?.clientMessageID?.isEmpty == false)
        #expect(state.isSelectedSessionRunning)
    }

    @Test("creating a conversation evicts the previous detailed history")
    func createSessionEvictsPreviousHistory() async {
        let session = sessionDescriptor(lastSequence: 1)
        let message = assistantMessage(
            id: "message-1",
            sequence: 1,
            role: .user,
            body: "旧会话"
        )
        let repository = AssistantTestRepository(bundles: [
            session.id: AssistantSessionBundle(session: session, messages: [message]),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        #expect(state.detailedSessionCacheCount == 1)

        #expect(await state.createSession())
        #expect(state.detailedSessionCacheCount == 0)
        #expect(state.selectedSessionID != session.id)
    }

    @Test("an open requested before loading creates one default conversation when ready")
    func deferredDefaultSessionCreation() async throws {
        let repository = AssistantTestRepository()
        let state = AssistantViewState(repository: repository, keyLoader: { nil })

        #expect(await state.ensureDefaultSession() == false)
        await state.load()

        let sessions = try await repository.assistantSessions(includeArchived: false)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(state.selectedSessionID == session.id)

        #expect(await state.ensureDefaultSession())
        #expect(try await repository.assistantSessions(includeArchived: false).count == 1)
    }

    @Test("opening with an existing conversation selects it without creating another")
    func existingSessionIsTheDefault() async throws {
        let existing = sessionDescriptor(id: "existing-session")
        let repository = AssistantTestRepository(bundles: [
            existing.id: AssistantSessionBundle(session: existing),
        ])
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        #expect(await state.ensureDefaultSession())

        let sessions = try await repository.assistantSessions(includeArchived: false)
        #expect(sessions.count == 1)
        #expect(state.selectedSessionID == existing.id)
    }

    @Test("a failed default conversation stays retryable")
    func failedDefaultSessionCanRetry() async throws {
        let repository = AssistantTestRepository(createSessionFailuresRemaining: 1)
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()

        #expect(await state.ensureDefaultSession() == false)
        #expect(state.errorMessage != nil)
        #expect(try await repository.assistantSessions(includeArchived: false).isEmpty)

        #expect(await state.ensureDefaultSession())
        #expect(state.errorMessage == nil)
        #expect(try await repository.assistantSessions(includeArchived: false).count == 1)
    }

    @Test("engine.ready restores the in-memory key and reloads assistant state")
    func engineReadyRestoresKey() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })

        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)
        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "stale"))
        #expect(state.selectedDraft?.body == "stale")

        await state.consumeAssistantEvent(EngineEvent(name: "engine.ready", data: Data("{}".utf8)))
        await repository.waitUntilAssistantStatusRequestCount(1)
        await repository.waitUntilKeyInjectionCount(1)
        await waitUntil { state.loadState == .loaded }

        #expect(await repository.keyInjectionCount() == 1)
        #expect(state.selectedDraft == nil)
        #expect(state.status?.configured == true)
        #expect(state.loadState == .loaded)
    }

    @Test("a dropped Engine event reloads authoritative Assistant state")
    func droppedEventReloadsAssistantState() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })

        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)
        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "stale"))
        #expect(state.selectedDraft?.body == "stale")

        await state.consumeAssistantEvent(.authoritativeResyncRequired(episode: 9))
        await repository.waitUntilAssistantStatusRequestCount(1)
        await repository.waitUntilKeyInjectionCount(1)
        await waitUntil { state.loadState == .loaded }

        #expect(state.selectedDraft == nil)
        #expect(state.status?.configured == true)
        #expect(state.loadState == .loaded)
    }

    @Test("a newer dropped-event episode waits for the active Assistant recovery")
    func newerDroppedEventQueuesAssistantRecovery() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            suspendHistoryAfterRequestCount: 0
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })

        let first = Task { @MainActor in
            await state.consumeAssistantEvent(.authoritativeResyncRequired(episode: 12))
        }
        await repository.waitUntilHistoryRequestCount(1)
        await state.consumeAssistantEvent(.authoritativeResyncRequired(episode: 13))
        await repository.releaseSuspendedHistory(with: AssistantSessionBundle(session: session))
        await repository.waitUntilHistoryRequestCount(2)
        await repository.releaseSuspendedHistory(with: AssistantSessionBundle(session: session))
        await first.value

        #expect(await repository.keyInjectionCount() == 2)
        #expect(await repository.historyRequests().count == 2)
        #expect(state.loadState == .loaded)
    }

    @Test("one engine.ready retries a failed Assistant reload without blocking events")
    func engineReadyRetriesAssistantReloadAndReturnsPromptly() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            assistantStatusFailuresRemaining: 1
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })

        await state.consumeAssistantEvent(try sessionChangedEvent(session))
        await state.selectSession(session.id)
        let readyHandler = Task { @MainActor in
            await state.consumeAssistantEvent(EngineEvent(name: "engine.ready", data: Data("{}".utf8)))
            return true
        }
        #expect(await readyHandler.value)

        await state.consumeAssistantEvent(try deltaEvent(attempt: 1, delta: "event-stream-alive"))
        #expect(state.selectedDraft?.body == "event-stream-alive")

        await repository.waitUntilAssistantStatusRequestCount(2)
        await repository.waitUntilKeyInjectionCount(2)
        await waitUntil { state.loadState == .loaded }
        #expect(state.status?.configured == true)
        #expect(state.loadState == .loaded)
    }

    @Test("one engine.ready retries a failed credential restore")
    func engineReadyRetriesCredentialRestore() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            keyInjectionFailuresRemaining: 1
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })

        await state.consumeAssistantEvent(EngineEvent(name: "engine.ready", data: Data("{}".utf8)))

        await repository.waitUntilKeyInjectionCount(2)
        await repository.waitUntilAssistantStatusRequestCount(2)
        await waitUntil { state.errorMessage == nil && state.loadState == .loaded }
        #expect(await repository.keyInjectionCount() == 2)
        #expect(state.status?.configured == true)
    }

    @Test("duplicate dropped-event signals coalesce while the retry worker is active")
    func duplicateDroppedEventSignalsCoalesceDuringRetry() async throws {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)],
            assistantStatusFailuresRemaining: 1
        )
        let state = AssistantViewState(repository: repository, keyLoader: { "key-from-keychain" })
        let dropped = EngineEvent.authoritativeResyncRequired(episode: 21)

        await state.consumeAssistantEvent(dropped)
        await state.consumeAssistantEvent(dropped)
        await state.consumeAssistantEvent(dropped)

        await repository.waitUntilAssistantStatusRequestCount(2)
        await repository.waitUntilKeyInjectionCount(2)
        await waitUntil { state.loadState == .loaded }
        #expect(await repository.assistantStatusRequestCount() == 2)
        #expect(state.loadState == .loaded)
    }

    @Test("assistant request payloads keep model on turns, not sessions")
    func requestWireShapes() throws {
        let createData = try JSONEncoder().encode(AssistantSessionCreateRequest(title: nil))
        let createObject = try #require(
            JSONSerialization.jsonObject(with: createData) as? [String: Any]
        )
        #expect(createObject["model"] == nil)

        let clientMessageID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000202"))
        let attachment = AssistantTextAttachment(
            name: "plan.md",
            mediaType: "text/markdown",
            content: "# Plan",
            byteCount: 6
        )
        let sendData = try JSONEncoder().encode(AssistantSendRequest(
            sessionID: "assistant-session",
            clientMessageID: clientMessageID,
            text: "整理任务",
            model: "gemini-3.6-flash",
            attachments: [attachment]
        ))
        let sendObject = try #require(
            JSONSerialization.jsonObject(with: sendData) as? [String: Any]
        )
        #expect(sendObject["sessionId"] as? String == "assistant-session")
        #expect(sendObject["clientMessageId"] as? String == clientMessageID.uuidString)
        #expect(sendObject["model"] as? String == "gemini-3.6-flash")
        #expect(sendObject["sessionID"] == nil)
        let attachments = try #require(sendObject["attachments"] as? [[String: Any]])
        #expect(attachments.first?["name"] as? String == "plan.md")
        #expect(attachments.first?["mediaType"] as? String == "text/markdown")
        #expect(attachments.first?["content"] as? String == "# Plan")
        #expect(attachments.first?["byteCount"] as? Int == 6)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !predicate(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate())
    }

    @Test("an attachment-only message reaches the repository")
    func sendsAttachmentOnlyMessage() async {
        let session = sessionDescriptor()
        let repository = AssistantTestRepository(
            bundles: [session.id: AssistantSessionBundle(session: session)]
        )
        let state = AssistantViewState(repository: repository, keyLoader: { nil })
        await state.load()
        let attachment = AssistantTextAttachment(
            name: "notes.txt",
            mediaType: "text/plain",
            content: "只处理这个文件",
            byteCount: 21
        )

        #expect(await state.send(text: "", model: "gemini-3.6-flash", attachments: [attachment]))
        #expect(await repository.lastSentAttachments() == [attachment])
    }

    private func sessionDescriptor(
        id: String = "assistant-session",
        lastSequence: Int64 = 0,
        isRunning: Bool = false
    ) -> AssistantSessionDescriptor {
        AssistantSessionDescriptor(
            id: id,
            title: "测试会话",
            createdAt: "2026-08-09T00:00:00Z",
            updatedAt: "2026-08-09T00:00:00Z",
            lastSequence: lastSequence,
            isRunning: isRunning
        )
    }

    private func assistantMessage(
        id: String,
        sequence: Int64,
        role: AssistantMessageRole,
        body: String
    ) -> AssistantMessage {
        AssistantMessage(
            id: id,
            sessionID: "assistant-session",
            turnID: "turn-1",
            sequence: sequence,
            role: role,
            body: body
        )
    }

    private func sessionChangedEvent(_ session: AssistantSessionDescriptor) throws -> EngineEvent {
        let sessionData = try JSONEncoder().encode(session)
        let sessionObject = try JSONSerialization.jsonObject(with: sessionData)
        let data = try JSONSerialization.data(withJSONObject: ["session": sessionObject])
        return EngineEvent(name: "assistant.session.changed", data: data)
    }

    private func deltaEvent(attempt: Int, delta: String) throws -> EngineEvent {
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": "assistant-session",
            "turnId": "turn-1",
            "messageId": "draft-message",
            "attempt": attempt,
            "delta": delta,
        ])
        return EngineEvent(name: "assistant.message.delta", data: data)
    }

    private func messageAppendedEvent(_ message: AssistantMessage) throws -> EngineEvent {
        let messageData = try JSONEncoder().encode(message)
        let messageObject = try JSONSerialization.jsonObject(with: messageData)
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": message.sessionID,
            "message": messageObject,
        ])
        return EngineEvent(name: "assistant.message.appended", data: data)
    }

    private func firstChatTurn(_ transcript: ChatTranscript) -> ChatTurnItem? {
        for item in transcript.items {
            if case let .turn(turn) = item { return turn }
        }
        return nil
    }

    private func chatTurns(_ transcript: ChatTranscript) -> [ChatTurnItem] {
        transcript.items.compactMap { item in
            guard case let .turn(turn) = item else { return nil }
            return turn
        }
    }

    private func drainMainActorTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

actor AssistantTestRepository: AppRepository {
    nonisolated let requiresExecutionConsent = true
    private let snapshot = AppSnapshot(
        revision: 0,
        lists: [],
        tasks: [],
        runtimes: [],
        sessions: [],
        messages: []
    )
    private var bundles: [String: AssistantSessionBundle]
    private var requestedHistorySequences: [Int64] = []
    private var historyRequestWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var injectedKeys = 0
    private var keyInjectionFailuresRemaining: Int
    private var keyInjectionWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var sentMessages = 0
    private var sentIDs: [UUID] = []
    private var sentAttachments: [AssistantTextAttachment] = []
    private var loadCallCount = 0
    private var sendFailuresRemaining: Int
    private var createSessionFailuresRemaining: Int
    private var assistantStatusFailuresRemaining: Int
    private var assistantStatusRequests = 0
    private var assistantStatusRequestWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private let persistFailedSend: Bool
    private let historyPageSize: Int
    private let suspendHistoryAfterRequestCount: Int?
    private var suspendedHistoryResponses: [
        CheckedContinuation<AssistantSessionBundle, Never>
    ] = []
    private var shouldSuspendLoad: Bool
    private var loadContinuations: [CheckedContinuation<Void, Never>] = []
    private var loadStartedContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        bundles: [String: AssistantSessionBundle] = [:],
        historyPageSize: Int = .max,
        sendFailuresRemaining: Int = 0,
        createSessionFailuresRemaining: Int = 0,
        keyInjectionFailuresRemaining: Int = 0,
        assistantStatusFailuresRemaining: Int = 0,
        persistFailedSend: Bool = false,
        suspendLoad: Bool = false,
        suspendHistoryAfterRequestCount: Int? = nil
    ) {
        self.bundles = bundles
        self.historyPageSize = historyPageSize
        self.sendFailuresRemaining = sendFailuresRemaining
        self.createSessionFailuresRemaining = createSessionFailuresRemaining
        self.keyInjectionFailuresRemaining = keyInjectionFailuresRemaining
        self.assistantStatusFailuresRemaining = assistantStatusFailuresRemaining
        self.persistFailedSend = persistFailedSend
        self.suspendHistoryAfterRequestCount = suspendHistoryAfterRequestCount
        shouldSuspendLoad = suspendLoad
    }

    func load() async throws -> AppSnapshot {
        loadCallCount += 1
        let started = loadStartedContinuations
        loadStartedContinuations.removeAll()
        for continuation in started { continuation.resume() }
        if shouldSuspendLoad {
            await withCheckedContinuation { continuation in
                loadContinuations.append(continuation)
            }
        }
        return snapshot
    }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: EngineEvent.self)
        continuation.finish()
        return stream
    }
    func createList(name: String, color: String) async throws -> AppSnapshot { snapshot }
    func createTask(title: String, note: String, listID: UUID?, executionDate: LocalDay?, dueDate: LocalDay?) async throws -> AppSnapshot { snapshot }
    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot { snapshot }
    func deleteTask(taskID: UUID) async throws -> AppSnapshot { snapshot }
    func createListFromTask(taskID: UUID) async throws -> AppSnapshot { snapshot }
    func addTaskAttachments(taskID: UUID, sourcePaths: [String], clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func removeTaskAttachment(taskID: UUID, attachmentID: UUID, clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot { snapshot }
    func detectRuntimes() async throws -> AppSnapshot { snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }
    func session(taskID: UUID) async throws -> SessionBundle? { nil }
    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {
        injectedKeys += 1
        let readyWaiters = keyInjectionWaiters.filter { injectedKeys >= $0.targetCount }
        keyInjectionWaiters.removeAll { injectedKeys >= $0.targetCount }
        for waiter in readyWaiters { waiter.continuation.resume() }
        if keyInjectionFailuresRemaining > 0 {
            keyInjectionFailuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
    }
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Gemini Test", version: "test")
    }

    func assistantStatus() async throws -> AssistantStatus {
        assistantStatusRequests += 1
        let readyWaiters = assistantStatusRequestWaiters.filter {
            assistantStatusRequests >= $0.targetCount
        }
        assistantStatusRequestWaiters.removeAll {
            assistantStatusRequests >= $0.targetCount
        }
        for waiter in readyWaiters { waiter.continuation.resume() }
        if assistantStatusFailuresRemaining > 0 {
            assistantStatusFailuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
        return AssistantStatus(
            configured: true,
            available: true,
            model: "gemini-3.6-flash",
            reason: nil
        )
    }

    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] {
        bundles.values.map(\.session).filter { includeArchived || !$0.archived }
    }

    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle {
        if createSessionFailuresRemaining > 0 {
            createSessionFailuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
        let session = AssistantSessionDescriptor(id: UUID().uuidString, title: title ?? "")
        let bundle = AssistantSessionBundle(session: session)
        bundles[session.id] = bundle
        return bundle
    }

    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle {
        guard let current = bundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        let bundle = AssistantSessionBundle(
            session: current.session.updating(title: title),
            messages: current.messages,
            tools: current.tools,
            timeline: current.timeline,
            activeTurn: current.activeTurn
        )
        bundles[sessionID] = bundle
        return bundle
    }

    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle {
        guard let current = bundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        let bundle = AssistantSessionBundle(
            session: current.session.updating(archived: true),
            messages: current.messages,
            tools: current.tools,
            timeline: current.timeline,
            activeTurn: current.activeTurn
        )
        bundles[sessionID] = bundle
        return bundle
    }

    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle {
        requestedHistorySequences.append(sequence)
        let readyWaiters = historyRequestWaiters.filter {
            requestedHistorySequences.count >= $0.targetCount
        }
        historyRequestWaiters.removeAll {
            requestedHistorySequences.count >= $0.targetCount
        }
        for waiter in readyWaiters { waiter.continuation.resume() }
        if let suspendHistoryAfterRequestCount,
           requestedHistorySequences.count > suspendHistoryAfterRequestCount {
            return await withCheckedContinuation { continuation in
                suspendedHistoryResponses.append(continuation)
            }
        }
        guard let bundle = bundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        return AssistantSessionBundle(
            session: bundle.session,
            messages: Array(
                bundle.messages
                    .filter { $0.sequence > sequence }
                    .prefix(historyPageSize)
            ),
            tools: bundle.tools,
            timeline: bundle.timeline,
            activeTurn: bundle.activeTurn
        )
    }

    func sendAssistantMessage(
        sessionID: String,
        clientMessageID: UUID,
        text: String,
        model: String,
        attachments: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle {
        sentMessages += 1
        sentIDs.append(clientMessageID)
        sentAttachments = attachments
        if sendFailuresRemaining > 0 {
            sendFailuresRemaining -= 1
            if persistFailedSend, let existing = bundles[sessionID] {
                let sequence = (existing.messages.map(\.sequence).max() ?? 0) + 1
                let message = AssistantMessage(
                    id: "accepted-\(clientMessageID.uuidString)",
                    sessionID: sessionID,
                    turnID: "accepted-turn",
                    sequence: sequence,
                    clientMessageID: clientMessageID.uuidString,
                    role: .user,
                    body: text
                )
                bundles[sessionID] = AssistantSessionBundle(
                    session: existing.session.updating(lastSequence: sequence, isRunning: true),
                    messages: existing.messages + [message],
                    tools: existing.tools,
                    timeline: existing.timeline,
                    activeTurn: AssistantTurn(
                        id: "accepted-turn",
                        sessionID: sessionID,
                        clientMessageID: clientMessageID.uuidString,
                        model: model,
                        status: .running
                    )
                )
            }
            throw AppRepositoryError.runtimeUnavailable
        }
        guard let bundle = bundles[sessionID] else { throw AppRepositoryError.assistantSessionNotFound }
        return bundle
    }

    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async {}

    func historyRequests() -> [Int64] { requestedHistorySequences }
    func waitUntilHistoryRequestCount(_ targetCount: Int) async {
        guard requestedHistorySequences.count < targetCount else { return }
        await withCheckedContinuation { continuation in
            historyRequestWaiters.append((targetCount, continuation))
        }
    }
    func keyInjectionCount() -> Int { injectedKeys }
    func waitUntilKeyInjectionCount(_ targetCount: Int) async {
        guard injectedKeys < targetCount else { return }
        await withCheckedContinuation { continuation in
            keyInjectionWaiters.append((targetCount, continuation))
        }
    }
    func assistantStatusRequestCount() -> Int { assistantStatusRequests }
    func waitUntilAssistantStatusRequestCount(_ targetCount: Int) async {
        guard assistantStatusRequests < targetCount else { return }
        await withCheckedContinuation { continuation in
            assistantStatusRequestWaiters.append((targetCount, continuation))
        }
    }
    func sendCount() -> Int { sentMessages }
    func sentClientMessageIDs() -> [UUID] { sentIDs }
    func lastSentAttachments() -> [AssistantTextAttachment] { sentAttachments }
    func loadCount() -> Int { loadCallCount }
    func setBundle(_ bundle: AssistantSessionBundle) { bundles[bundle.session.id] = bundle }
    func releaseSuspendedHistory(with bundle: AssistantSessionBundle) {
        guard !suspendedHistoryResponses.isEmpty else { return }
        suspendedHistoryResponses.removeFirst().resume(returning: bundle)
    }
    func waitUntilLoadStarts() async {
        guard loadCallCount == 0 else { return }
        await withCheckedContinuation { continuation in
            loadStartedContinuations.append(continuation)
        }
    }
    func releaseLoad() {
        shouldSuspendLoad = false
        let continuations = loadContinuations
        loadContinuations.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
