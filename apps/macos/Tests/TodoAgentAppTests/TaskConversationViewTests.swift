import AppKit
import SwiftUI
import Testing
@testable import TodoAgentApp

@Suite("Task conversation presentation")
@MainActor
struct TaskConversationViewTests {
    @Test("runtime picker names the Agent without pinning its detected version")
    func runtimePickerUsesCurrentInstallation() {
        let readyClaude = RuntimeInfo(
            kind: .claude,
            launchPath: "/Users/test/.local/bin/claude",
            resolvedPath: "/Users/test/.local/share/claude/versions/2.1.228",
            version: "2.1.228 (Claude Code)",
            status: .ready,
            authStatus: "authenticated",
            capabilities: [:],
            providerEngine: nil,
            detectedAt: nil,
            verifiedAt: "2026-08-13T00:00:00Z",
            verifyError: nil
        )
        let cursorNeedsLogin = RuntimeInfo(
            kind: .cursor,
            launchPath: "/usr/local/bin/cursor-agent",
            resolvedPath: "/usr/local/bin/cursor-agent",
            version: "2026.07.23",
            status: .authRequired,
            authStatus: "unauthenticated",
            capabilities: [:],
            providerEngine: nil,
            detectedAt: nil,
            verifiedAt: nil,
            verifyError: nil
        )

        let claudeTitle = RuntimePickerPresentation.title(.claude, info: readyClaude)
        #expect(claudeTitle == "Claude Code")
        #expect(claudeTitle.contains("2.1.228") == false)
        #expect(
            RuntimePickerPresentation.title(.cursor, info: cursorNeedsLogin)
                == "Cursor Agent（需要登录）"
        )
    }

    @Test("assistant tools use friendly actions and collapse into one turn summary")
    func assistantToolStepPresentation() {
        let completed = assistantTool(name: "create_tasks", state: .completed, callID: "create")
        let running = assistantTool(name: "list_state", state: .running, callID: "list")
        let failed = assistantTool(name: "delete_task", state: .failed, callID: "delete")
        let sixSteps = AssistantToolGroup(
            turnID: "turn-six",
            tools: (0 ..< 6).map {
                assistantTool(name: "find_related", state: .completed, callID: "call-\($0)")
            }
        )

        #expect(AssistantToolStepPresentation(tool: completed).title == "已创建任务")
        #expect(AssistantToolStepPresentation(tool: running).title == "正在读取任务")
        #expect(AssistantToolStepPresentation(tool: failed).title == "删除任务时遇到问题")
        #expect(AssistantToolGroupPresentation(group: sixSteps).title == "6 个步骤")
        #expect(AssistantToolGroupPresentation(group: sixSteps).accessibilityValue == "已完成")
    }

    @Test("markdown keeps block structure and removes inline syntax markers")
    func assistantMarkdownPresentation() {
        let document = AssistantMarkdownDocument(
            markdown: "已成功删除你的 **6 个任务**：\n\n1. **测试 cc**\n2. **123**（未完成）"
        )
        let inline = AssistantMarkdownInlineParser.parse("已删除 **6 个任务**")

        #expect(document.blocks.count == 2)
        #expect(document.blocks.first == .paragraph("已成功删除你的 **6 个任务**："))
        #expect(
            document.blocks.last == .orderedList([
                (number: 1, text: "**测试 cc**"),
                (number: 2, text: "**123**（未完成）"),
            ])
        )
        #expect(String(inline.characters) == "已删除 6 个任务")
    }

    @Test("long Markdown prepares block and inline content through a bounded async cache")
    func longMarkdownUsesBoundedRenderCache() async throws {
        let cache = AssistantMarkdownRenderCache(
            maximumEntryCount: 2,
            maximumSourceBytes: 320 * 1_024
        )
        let longSource = "**完成** " + String(repeating: "长正文内容 ", count: 20_000)
        let document = try #require(await cache.document(id: "long", source: longSource))

        #expect(document.blocks.count == 1)
        guard case let .paragraph(parsedLongSource) = document.blocks.first else {
            Issue.record("long Markdown should remain one paragraph")
            return
        }
        #expect(parsedLongSource.hasPrefix("**完成** 长正文内容"))
        #expect(parsedLongSource.utf8.count >= longSource.utf8.count - 1)
        let shortDocument = try #require(
            await cache.document(id: "short", source: "**完成** 长正文内容")
        )
        #expect(
            String(shortDocument.inlineValue(for: "**完成** 长正文内容").characters)
                == "完成 长正文内容"
        )

        for index in 0 ..< 2 {
            _ = await cache.document(id: "small-\(index)", source: "**\(index)**")
        }
        let metrics = await cache.cacheMetrics()
        #expect(metrics.entryCount <= 2)
        #expect(metrics.sourceBytes <= 320 * 1_024)
    }

    @Test("a late Markdown parse cannot replace the newest row revision")
    func staleMarkdownResultIsRejected() {
        let oldKey = ChatMarkdownLoadKey(id: "answer", body: "old", shouldParse: true)
        let newKey = ChatMarkdownLoadKey(id: "answer", body: "new", shouldParse: true)
        let oldDocument = AssistantMarkdownDocument(markdown: "**old**")
        let newDocument = AssistantMarkdownDocument(markdown: "**new**")
        var state = ChatMarkdownLoadState()

        state.begin(oldKey)
        state.begin(newKey)
        #expect(state.accept(oldDocument, for: oldKey) == false)
        #expect(state.document == nil)
        let acceptedNewestDocument = state.accept(newDocument, for: newKey)
        #expect(acceptedNewestDocument)
        #expect(state.document == newDocument)
    }

    @Test("technical provider failures are hidden behind a friendly summary")
    func assistantErrorPresentation() {
        let raw = "Gemini 请求失败：provider network error: error sending request for url (https://example.invalid/v1)"
        let presentation = AssistantErrorPresentation(rawMessage: raw)

        #expect(presentation.title == "连接 Gemini 时遇到网络问题")
        #expect(presentation.guidance == "请检查网络或代理设置，然后重试。")
        #expect(presentation.guidance.contains("https://") == false)
        #expect(presentation.technicalDetails == raw)
    }

    @Test("assistant scrollbar stays quiet until the pointer reaches the trailing edge")
    func assistantScrollbarPolicy() {
        #expect(AssistantScrollIndicatorPolicy.showsIndicators(pointerNearIndicator: false) == false)
        #expect(AssistantScrollIndicatorPolicy.showsIndicators(pointerNearIndicator: true))
        #expect(AssistantScrollIndicatorPolicy.coverOpacity(pointerNearIndicator: false) == 0.97)
        #expect(AssistantScrollIndicatorPolicy.coverOpacity(pointerNearIndicator: true) == 0)
        #expect(AssistantScrollIndicatorPolicy.hoverZoneWidth > AssistantScrollIndicatorPolicy.coverWidth)
    }

    @Test("six completed tools occupy one compact transcript row")
    func completedToolGroupHasCompactHeight() {
        let state = AppState(repository: AssistantTestRepository())
        let completed = AssistantToolGroup(
            turnID: "completed-turn",
            tools: (0 ..< 6).map {
                assistantTool(name: "find_related", state: .completed, callID: "done-\($0)")
            }
        )
        let running = AssistantToolGroup(
            turnID: "running-turn",
            tools: (0 ..< 6).map {
                assistantTool(
                    name: $0 == 5 ? "create_tasks" : "find_related",
                    state: $0 == 5 ? .running : .completed,
                    callID: "running-\($0)"
                )
            }
        )

        let completedHeight = hostedToolGroupHeight(group: completed, state: state)
        let runningHeight = hostedToolGroupHeight(group: running, state: state)

        #expect(completedHeight > 0)
        #expect(completedHeight < 80)
        #expect(runningHeight > completedHeight * 3)
        #expect(runningHeight < 500)
    }

    @Test("expandable transcript content cannot resize the message track")
    func expandableContentKeepsTranscriptTrackWidthStable() {
        let collapsedWidth = hostedTranscriptTrackWidth(showsExpandedContent: false)
        let expandedWidth = hostedTranscriptTrackWidth(showsExpandedContent: true)

        #expect(collapsedWidth == 360)
        #expect(expandedWidth == collapsedWidth)
    }

    @Test("completed tool steps expand in one stable layout transaction")
    func toolGroupDisclosureLifecycle() {
        var disclosure = AssistantToolGroupDisclosureState()

        #expect(disclosure.isExpanded(isRunning: false) == false)
        disclosure.toggleGroup(isRunning: false)
        #expect(disclosure.isExpanded(isRunning: false))

        disclosure.toggleTool("step-1")
        #expect(disclosure.expandedToolIDs == ["step-1"])

        disclosure.finishRunningGroup()
        #expect(disclosure.isExpanded(isRunning: false) == false)
        #expect(disclosure.expandedToolIDs.isEmpty)

        disclosure.toggleGroup(isRunning: true)
        #expect(disclosure.manuallyExpanded == false)
        #expect(disclosure.isExpanded(isRunning: true))
    }

    @Test("conversation history uses a bounded in-pane card")
    func conversationSwitcherCardStaysCompact() {
        let compactHeight = hostedSwitcherHeight(sessionCount: 2)
        let crowdedHeight = hostedSwitcherHeight(sessionCount: 12)

        #expect(compactHeight > TodoAgentToolbar.height)
        #expect(compactHeight < 240)
        #expect(crowdedHeight > compactHeight)
        #expect(crowdedHeight < 300)
        #expect(AssistantSessionSwitcherLayout.panelTopOffset > TodoAgentToolbar.height)
    }

    @Test("conversation history groups today and yesterday below a stable toolbar")
    func conversationSwitcherGroupsRecentDaysWithoutMovingToolbar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(
            ISO8601DateFormatter().date(from: "2026-08-10T02:00:00Z")
        )
        let sessions = [
            AssistantSessionDescriptor(
                id: "today",
                title: "今天的对话",
                updatedAt: "2026-08-10T01:30:00Z"
            ),
            AssistantSessionDescriptor(
                id: "yesterday",
                title: "昨天的对话",
                updatedAt: "2026-08-09T01:30:00Z"
            ),
        ]

        let sections = AssistantSessionHistoryProjection.sections(
            from: sessions,
            now: now,
            calendar: calendar
        )

        #expect(sections.map(\.title) == ["今天", "昨天"])
        #expect(sections.map(\.sessions.first?.id) == ["today", "yesterday"])
        #expect(hostedToolbarHeight(isSwitcherPresented: false) == TodoAgentToolbar.height)
        #expect(hostedToolbarHeight(isSwitcherPresented: true) == TodoAgentToolbar.height)
    }

    @Test("task workbench uses the terminal-first window dimensions")
    func taskWorkbenchWindowDimensions() {
        #expect(TaskWorkbenchWindowController.defaultContentSize == CGSize(width: 1_180, height: 760))
        #expect(TaskWorkbenchWindowController.minimumContentSize == CGSize(width: 900, height: 600))
    }

    @Test("task workbench details start collapsed with the ideal reveal width")
    func taskWorkbenchDetailsDefaultLayout() {
        let layout = TaskWorkbenchLayoutState()

        #expect(layout.detailsPresented == false)
        #expect(layout.detailsWidth == TaskWorkbenchLayoutState.idealDetailsWidth)
    }

    @Test("task workbench details width stays inside its usable range")
    func taskWorkbenchDetailsWidthClamping() {
        let layout = TaskWorkbenchLayoutState()

        layout.recordDetailsWidth(TaskWorkbenchLayoutState.minimumDetailsWidth - 100)
        #expect(layout.detailsWidth == TaskWorkbenchLayoutState.minimumDetailsWidth)

        layout.recordDetailsWidth(TaskWorkbenchLayoutState.maximumDetailsWidth + 100)
        #expect(layout.detailsWidth == TaskWorkbenchLayoutState.maximumDetailsWidth)

        let customWidth = TaskWorkbenchLayoutState.idealDetailsWidth + 24
        layout.recordDetailsWidth(customWidth)
        #expect(layout.detailsWidth == customWidth)
    }

    @Test("opening, recollapsing, and reopening task details preserves the user's width")
    func taskWorkbenchDetailsPreserveWidthAcrossDisclosure() {
        let layout = TaskWorkbenchLayoutState()
        let customWidth = TaskWorkbenchLayoutState.maximumDetailsWidth - 18
        layout.recordDetailsWidth(customWidth)

        layout.toggleDetails()
        #expect(layout.detailsPresented)
        #expect(layout.detailsWidth == customWidth)

        layout.toggleDetails()
        #expect(layout.detailsPresented == false)
        #expect(layout.detailsWidth == customWidth)

        layout.toggleDetails()
        #expect(layout.detailsPresented)
        #expect(layout.detailsWidth == customWidth)
    }

    @Test("task workbench detail disclosure is isolated per window")
    func taskWorkbenchDetailsAreWindowLocal() {
        let firstWindow = TaskWorkbenchLayoutState()
        let secondWindow = TaskWorkbenchLayoutState()

        firstWindow.recordDetailsWidth(TaskWorkbenchLayoutState.maximumDetailsWidth)
        firstWindow.toggleDetails()

        #expect(firstWindow.detailsPresented)
        #expect(firstWindow.detailsWidth == TaskWorkbenchLayoutState.maximumDetailsWidth)
        #expect(secondWindow.detailsPresented == false)
        #expect(secondWindow.detailsWidth == TaskWorkbenchLayoutState.idealDetailsWidth)
    }

    private func assistantTool(
        name: String,
        state: AssistantToolState,
        callID: String
    ) -> AssistantToolActivity {
        AssistantToolActivity(
            sessionID: "session-1",
            turnID: "turn-1",
            toolCallID: callID,
            name: name,
            state: state,
            taskReferences: []
        )
    }

    private func hostedToolGroupHeight(
        group: AssistantToolGroup,
        state: AppState
    ) -> CGFloat {
        let host = NSHostingView(
            rootView: AssistantToolStepsView(group: group, state: state)
                .frame(width: 360)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func hostedTranscriptTrackWidth(showsExpandedContent: Bool) -> CGFloat {
        let host = NSHostingView(
            rootView: AssistantTranscriptTrack {
                Text("之前的消息")
                    .frame(maxWidth: .infinity, alignment: .trailing)

                if showsExpandedContent {
                    VStack(alignment: .leading) {
                        Text("已检查相关任务")
                        Text("已检查相关任务")
                        Text("已创建任务")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(width: 360)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    private func hostedSwitcherHeight(sessionCount: Int) -> CGFloat {
        let sessions = (0 ..< sessionCount).map { index in
            AssistantSessionDescriptor(
                id: "session-\(index)",
                title: "对话 \(index + 1)",
                isRunning: index == 0
            )
        }
        let host = NSHostingView(
            rootView: AssistantSessionSwitcherPanel(
                sessions: sessions,
                selectedSessionID: sessions.first?.id,
                selectedSessionRunning: false,
                selectionDisabled: false,
                onSelect: { _ in },
                onRename: {},
                onArchive: {}
            )
            .frame(width: 300)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func hostedToolbarHeight(isSwitcherPresented: Bool) -> CGFloat {
        let state = AppState(repository: AssistantTestRepository())
        let host = NSHostingView(
            rootView: TodoAgentToolbar(
                state: state,
                sessionSwitcherPresented: .constant(isSwitcherPresented),
                onClose: {}
            )
            .frame(width: 360)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}
