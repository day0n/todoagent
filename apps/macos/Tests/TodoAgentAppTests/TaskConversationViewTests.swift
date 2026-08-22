import AppKit
import SwiftUI
import Testing
@testable import TodoAgentApp

@Suite("Task conversation presentation")
@MainActor
struct TaskConversationViewTests {
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

    @Test("task workbench detail disclosure state is isolated per task")
    func taskWorkbenchDetailsAreTaskLocal() {
        let firstTask = TaskWorkbenchLayoutState()
        let secondTask = TaskWorkbenchLayoutState()

        firstTask.recordDetailsWidth(TaskWorkbenchLayoutState.maximumDetailsWidth)
        firstTask.toggleDetails()

        #expect(firstTask.detailsPresented)
        #expect(firstTask.detailsWidth == TaskWorkbenchLayoutState.maximumDetailsWidth)
        #expect(secondTask.detailsPresented == false)
        #expect(secondTask.detailsWidth == TaskWorkbenchLayoutState.idealDetailsWidth)
    }

    @Test("embedded task rail remains visible at compact and regular widths")
    func embeddedTaskRailLayoutPolicy() {
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 829,
                previous: nil
            ) == .compact
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 830,
                previous: nil
            ) == .split
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 820,
                previous: .split
            ) == .compact
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 821,
                previous: .split
            ) == .split
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 839,
                previous: .compact
            ) == .compact
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 840,
                previous: .compact
            ) == .split
        )
        #expect(TaskWorkspaceLayoutPolicy.regularRailWidth == 320)
        #expect(TaskWorkspaceLayoutPolicy.compactRailWidth == 252)
        #expect(TaskWorkspaceLayoutPolicy.defaultOpenRailWidth == 252)
        #expect(TaskWorkspaceLayoutPolicy.minimumResizableRailWidth == 200)
        #expect(TaskWorkspaceLayoutPolicy.railWidth(for: .split) == 320)
        #expect(TaskWorkspaceLayoutPolicy.railWidth(for: .compact) == 252)
        #expect(TaskWorkspaceLayoutPolicy.terminalPreferredMinimumWidth == 500)
        #expect(TaskWorkspaceLayoutPolicy.terminalAbsoluteMinimumWidth == 320)
        #expect(TaskWorkbenchPresentation.embedded(compact: true).allowsTaskDetails == false)
        #expect(TaskWorkbenchPresentation.embedded(compact: false).allowsTaskDetails == false)
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 846,
                previous: nil
            ) == .split
        )
        #expect(
            TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: 550,
                previous: nil
            ) == .compact
        )
        #expect(TaskWorkspaceTerminalPanePreferences.widthKey.hasSuffix(".v2"))
    }

    @Test("task content adaptively shrinks with the terminal drawer")
    func taskContentTrackLayoutPolicy() {
        #expect(TaskListContentTrackLayoutPolicy.maximumCardWidth == 780)
        #expect(TaskListContentTrackLayoutPolicy.horizontalPadding == 20)
        #expect(TaskListContentTrackLayoutPolicy.maximumTrackWidth == 820)
        #expect(TaskListContentTrackLayoutPolicy.contentWidth(availableWidth: 1_100) == 780)
        #expect(TaskListContentTrackLayoutPolicy.trackWidth(availableWidth: 1_100) == 820)
        #expect(TaskListContentTrackLayoutPolicy.contentWidth(availableWidth: 320) == 280)
        #expect(TaskListContentTrackLayoutPolicy.trackWidth(availableWidth: 320) == 320)
        #expect(TaskListContentTrackLayoutPolicy.contentWidth(availableWidth: 252) == 212)
        #expect(TaskListContentTrackLayoutPolicy.trackWidth(availableWidth: 252) == 252)
        #expect(TaskListContentTrackLayoutPolicy.contentWidth(availableWidth: 40) == 0)
        #expect(TaskListContentTrackLayoutPolicy.trackWidth(availableWidth: 40) == 40)
        #expect(TaskListContentTrackLayoutPolicy.synchronizedContentWidth(
            paneWidth: 1_100,
            expandedPaneWidth: 1_100,
            collapsedPaneWidth: 252
        ) == 780)
        #expect(TaskListContentTrackLayoutPolicy.synchronizedContentWidth(
            paneWidth: 676,
            expandedPaneWidth: 1_100,
            collapsedPaneWidth: 252
        ) == 496)
        #expect(TaskListContentTrackLayoutPolicy.synchronizedContentWidth(
            paneWidth: 252,
            expandedPaneWidth: 1_100,
            collapsedPaneWidth: 252
        ) == 212)
    }

    @Test("narrow task cards keep controls while truncating text at the tail")
    func narrowTaskCardLayoutPolicy() {
        #expect(TaskCardNarrowLayoutPolicy.textLineLimit == 1)
        #expect(TaskCardNarrowLayoutPolicy.textTruncation == .tail)
        #expect(TaskCardNarrowLayoutPolicy.allowsTextTightening == false)
        #expect(TaskCardNarrowLayoutPolicy.completionControlSize == 22)
        #expect(
            TaskCardNarrowLayoutPolicy.sessionTargetWidth(
                railWidth: TaskWorkspaceLayoutPolicy.minimumResizableRailWidth
            ) == 100
        )
        #expect(
            TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
                isWorkspacePending: false,
                isRunning: false,
                hasUnread: false
            ) == false
        )
        #expect(
            TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
                isWorkspacePending: true,
                isRunning: false,
                hasUnread: false
            )
        )
        #expect(
            TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
                isWorkspacePending: false,
                isRunning: true,
                hasUnread: false
            )
        )
        #expect(
            TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
                isWorkspacePending: false,
                isRunning: false,
                hasUnread: true
            )
        )
        #expect(
            TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
                isWorkspacePending: false,
                isRunning: false,
                hasUnread: false,
                showsRuntime: true
            )
        )
    }

    @Test("task click opens details while terminal remains an explicit context action")
    func taskCardActivationPolicy() {
        #expect(
            TaskCardInteractionPolicy.destination(for: .primaryClick) == .detailsPopover
        )
        #expect(
            TaskCardInteractionPolicy.destination(for: .terminalContextMenu) == .terminalWorkspace
        )
        #expect(TaskContextMenuAccessibility.terminal == "task.context.open-terminal")
        #expect(TaskDetailPopoverLayoutPolicy.width == 360)
        #expect(TaskDetailPopoverLayoutPolicy.height == 560)
        #expect(
            TaskDetailPopoverLayoutPolicy.width >= TaskWorkbenchLayoutState.minimumDetailsWidth
        )
        #expect(
            TaskDetailPopoverLayoutPolicy.width <= TaskWorkbenchLayoutState.maximumDetailsWidth
        )

        let taskID = UUID()
        let task = TaskItem(
            id: taskID,
            listID: nil,
            title: "保持弹窗",
            note: "",
            status: .open,
            completedAt: nil,
            createdAt: .now,
            updatedAt: ""
        )
        var completedTask = task
        completedTask.status = .completed
        let selection = TaskDetailsPopoverSelection(
            taskID: taskID,
            originalStatus: .open
        )
        let rowsBeforeCompletion = TaskStatusSections(tasks: [task]).rows.map(\.id)
        let rowsAfterCompletion = TaskStatusSections(
            tasks: [completedTask],
            pinnedTaskID: selection.taskID,
            pinnedStatus: selection.originalStatus
        ).rows.map(\.id)

        #expect(rowsAfterCompletion == rowsBeforeCompletion)
    }

    @MainActor
    @Test("task note editor keeps first-click focus and marked text stable")
    func taskNoteEditorSynchronizationPolicy() {
        let textView = TaskNoteTextView()
        #expect(textView.acceptsFirstMouse(for: nil))
        #expect(TaskNoteEditorSynchronizationPolicy.maximumLength == 4_000)
        #expect(TaskNoteEditorSynchronizationPolicy.editorHeight == 150)

        let chinese = String(repeating: "备", count: 4_001)
        let emoji = String(repeating: "🙂", count: 4_001)
        #expect(TaskNoteEditorSynchronizationPolicy.committedText(chinese).count == 4_000)
        #expect(TaskNoteEditorSynchronizationPolicy.committedText(emoji).count == 4_000)

        #expect(TaskNoteEditorSynchronizationPolicy.shouldApplyExternalText(
            nativeText: "正在输入 ni",
            draftText: "权威快照",
            isFirstResponder: true,
            hasMarkedText: false
        ) == false)
        #expect(TaskNoteEditorSynchronizationPolicy.shouldApplyExternalText(
            nativeText: "正在输入 ni",
            draftText: "权威快照",
            isFirstResponder: false,
            hasMarkedText: true
        ) == false)
        #expect(TaskNoteEditorSynchronizationPolicy.shouldApplyExternalText(
            nativeText: "旧值",
            draftText: "新值",
            isFirstResponder: false,
            hasMarkedText: false
        ))

        #expect(TaskCardMetadataLayoutPolicy.reservesLine(
            whileDetailsArePresented: true,
            hasVisibleMetadata: false
        ))
        #expect(TaskCardMetadataLayoutPolicy.reservesLine(
            whileDetailsArePresented: false,
            hasVisibleMetadata: false
        ) == false)
        #expect(TaskCardMetadataLayoutPolicy.reservesLine(
            whileDetailsArePresented: true,
            hasVisibleMetadata: true
        ) == false)
    }

    @Test("task note editor keeps marked text local until IME commits it")
    func taskNoteEditorMarkedTextLifecycle() throws {
        var draft = ""
        var focused = false
        let coordinator = TaskNoteEditor.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        )
        let textView = TaskNoteTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = textView
        textView.delegate = coordinator
        #expect(window.makeFirstResponder(textView))
        coordinator.textDidBeginEditing(
            Notification(name: NSText.didBeginEditingNotification, object: textView)
        )
        #expect(focused)

        textView.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        #expect(draft.isEmpty)

        textView.unmarkText()
        coordinator.textDidChange(
            Notification(name: NSText.didChangeNotification, object: textView)
        )
        #expect(draft == "nihao")

        textView.string = "你好"
        coordinator.textDidEndEditing(
            Notification(name: NSText.didEndEditingNotification, object: textView)
        )
        #expect(draft == "你好")
        #expect(focused == false)
    }

    @Test("task note editor commits replacement text and active marked text")
    func taskNoteEditorCommitsMarkedTextAtWindowBoundary() throws {
        var draft = "前缀"
        var focused = false
        let coordinator = TaskNoteEditor.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }),
            isFocused: Binding(get: { focused }, set: { focused = $0 })
        )
        let textView = TaskNoteTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        textView.string = draft
        textView.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = textView
        textView.delegate = coordinator
        try #require(window.makeFirstResponder(textView))

        textView.setMarkedText(
            "nihao",
            selectedRange: NSRange(location: 5, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let greetingMarkedRange = textView.markedRange()
        try #require(greetingMarkedRange.location != NSNotFound)
        #expect(focused)
        #expect(draft == "前缀")

        textView.insertText("你好", replacementRange: greetingMarkedRange)
        #expect(textView.hasMarkedText() == false)
        #expect(textView.string == "前缀你好")
        #expect(draft == "前缀你好")

        textView.setMarkedText(
            "世界",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(textView.hasMarkedText())
        #expect(draft == "前缀你好")

        TaskDetailTextInputCommitter.commitEditing(in: window)

        #expect(textView.hasMarkedText() == false)
        #expect(textView.string == "前缀你好世界")
        #expect(draft == "前缀你好世界")
        #expect(focused == false)
    }

    @Test("workspace reveal moves a fixed-width terminal instead of resizing it")
    func workspaceRevealLayoutPolicy() {
        let regular = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 1_100,
            railVisibility: .split
        )
        #expect(regular.railWidth == 252)
        #expect(regular.terminalWidth == 847)
        #expect(regular.terminalX(revealProgress: 0) == 1_101)
        #expect(regular.terminalX(revealProgress: 0.5) == 677)
        #expect(regular.terminalX(revealProgress: 1) == 253)
        #expect(regular.taskPaneWidth(isPresented: false) == 1_100)
        #expect(regular.taskPaneWidth(isPresented: true) == 252)
        #expect(regular.terminalReservedWidth(isPresented: false) == 0)
        #expect(regular.terminalReservedWidth(isPresented: true) == 848)
        #expect(regular.dividerX(isPresented: false) == 1_100)
        #expect(regular.dividerX(isPresented: true) == 252)

        for progress in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            let taskPaneWidth = regular.taskPaneWidth(revealProgress: progress)
            #expect(regular.dividerX(revealProgress: progress) == taskPaneWidth)
            #expect(
                regular.terminalX(revealProgress: progress)
                    == taskPaneWidth + TaskWorkspaceLayoutPolicy.dividerWidth
            )
            #expect(
                taskPaneWidth + regular.terminalReservedWidth(revealProgress: progress)
                    == 1_100
            )
            #expect(regular.terminalWidth == 847)
        }

        let sameWidthCompact = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 1_100,
            railVisibility: .compact
        )
        #expect(sameWidthCompact.railWidth == regular.railWidth)
        #expect(sameWidthCompact.terminalWidth == regular.terminalWidth)

        let splitThreshold = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 821,
            railVisibility: .split
        )
        let compactThreshold = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 820,
            railVisibility: .compact
        )
        #expect(splitThreshold.railWidth == 252)
        #expect(compactThreshold.railWidth == 252)
        #expect(splitThreshold.terminalWidth == 568)
        #expect(compactThreshold.terminalWidth == 567)

        let compact = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 700,
            railVisibility: .compact
        )
        #expect(compact.railWidth == 252)
        #expect(compact.terminalWidth == 447)
        #expect(compact.terminalX(revealProgress: -1) == 701)
        #expect(compact.terminalX(revealProgress: 2) == 253)
        #expect(compact.taskPaneWidth(isPresented: true) == 252)
        #expect(compact.terminalReservedWidth(isPresented: true) == 448)

        let narrow = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 550,
            railVisibility: .compact
        )
        #expect(narrow.railWidth == 229)
        #expect(narrow.terminalWidth == 320)
        #expect(narrow.terminalShownX == 230)
        #expect(narrow.terminalHiddenX == 551)
        #expect(TaskWorkspaceMotion.duration == 0.34)
    }

    @Test("terminal resize policy preserves usable split and compact panes")
    func workspaceTerminalResizeLayoutPolicy() {
        let splitRange = TaskWorkspaceRevealLayoutPolicy.terminalWidthRange(
            availableWidth: 1_100,
            railVisibility: .split
        )
        #expect(splitRange == 320 ... 899)

        let compactRange = TaskWorkspaceRevealLayoutPolicy.terminalWidthRange(
            availableWidth: 700,
            railVisibility: .compact
        )
        #expect(compactRange == 320 ... 499)

        let narrowRange = TaskWorkspaceRevealLayoutPolicy.terminalWidthRange(
            availableWidth: 550,
            railVisibility: .compact
        )
        #expect(narrowRange == 320 ... 349)
        #expect(
            TaskWorkspaceRevealLayoutPolicy.terminalWidthRange(
                availableWidth: 300,
                railVisibility: .compact
            ) == 299 ... 299
        )

        #expect(
            TaskWorkspaceRevealLayoutPolicy.resizedTerminalWidth(
                availableWidth: 1_100,
                railVisibility: .split,
                startingWidth: 650,
                dividerTranslation: 100
            ) == 550
        )
        #expect(
            TaskWorkspaceRevealLayoutPolicy.resizedTerminalWidth(
                availableWidth: 1_100,
                railVisibility: .split,
                startingWidth: 650,
                dividerTranslation: -300
            ) == 899
        )
        #expect(
            TaskWorkspaceRevealLayoutPolicy.resizedTerminalWidth(
                availableWidth: 1_100,
                railVisibility: .split,
                startingWidth: 650,
                dividerTranslation: 400
            ) == 320
        )

        let preferred = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 1_100,
            railVisibility: .split,
            preferredTerminalWidth: 650
        )
        #expect(preferred.terminalWidth == 650)
        #expect(preferred.railWidth == 449)

        // A smaller window clamps presentation only. Supplying the same saved
        // preference after the window grows restores the user's width.
        let constrained = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 800,
            railVisibility: .split,
            preferredTerminalWidth: 650
        )
        let compact = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 700,
            railVisibility: .compact,
            preferredTerminalWidth: 650
        )
        let restored = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: 1_100,
            railVisibility: .split,
            preferredTerminalWidth: 650
        )
        #expect(constrained.terminalWidth == 599)
        #expect(constrained.railWidth == 200)
        #expect(compact.terminalWidth == 499)
        #expect(compact.railWidth == 200)
        #expect(restored.terminalWidth == 650)
        #expect(TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetWidth == 12)
        #expect(TaskWorkspaceTerminalResizeInteractionPolicy.accessibilityStep == 24)

        let dividerX: CGFloat = 252
        let hitOrigin = TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetOrigin(
            dividerX: dividerX,
            visibleDividerWidth: TaskWorkspaceLayoutPolicy.dividerWidth
        )
        #expect(
            hitOrigin + TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetWidth / 2
                == dividerX + TaskWorkspaceLayoutPolicy.dividerWidth / 2
        )
        #expect(hitOrigin < dividerX)
        #expect(
            hitOrigin + TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetWidth
                > dividerX + TaskWorkspaceLayoutPolicy.dividerWidth
        )
    }

    @Test("terminal resize interaction anchors every update to the drag start")
    func workspaceTerminalResizeInteractionState() {
        var state = TaskWorkspaceTerminalResizeInteractionState()

        let firstWidth = state.update(
            currentWidth: 650,
            dividerTranslation: 20
        )
        let secondWidth = state.update(
            currentWidth: firstWidth,
            dividerTranslation: 50
        )
        #expect(firstWidth == 630)
        #expect(secondWidth == 600)
        #expect(state.startingWidth == 650)
        #expect(state.latestWidth == 600)
        #expect(state.isDragging)

        #expect(state.end(currentWidth: secondWidth) == 600)
        #expect(state.startingWidth == nil)
        #expect(state.latestWidth == nil)
        #expect(state.isDragging == false)

        let nextDragWidth = state.update(
            currentWidth: 700,
            dividerTranslation: -10
        )
        #expect(nextDragWidth == 710)
        #expect(state.startingWidth == 700)
        state.reset()
        #expect(state.isDragging == false)
    }

    @Test("native horizontal resize handle resets cancelled drag baselines")
    func horizontalResizeHandleTracksOneWindowCoordinateBaseline() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let handle = HorizontalResizeHandleView(
            frame: NSRect(x: 0, y: 0, width: 12, height: 100)
        )
        window.contentView = handle
        var changed: [CGFloat] = []
        var ended: [CGFloat] = []
        var nextEnded: [CGFloat] = []
        handle.onDragChanged = { changed.append($0) }
        handle.onDragEnded = { ended.append($0) }

        let down = try #require(resizeMouseEvent(.leftMouseDown, x: 100, window: window))
        let drag = try #require(resizeMouseEvent(.leftMouseDragged, x: 130, window: window))
        handle.mouseDown(with: down)
        handle.mouseDragged(with: drag)
        #expect(changed == [30])
        #expect(handle.dragOriginInWindow == 100)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: window))

        handle.isInteractionEnabled = false
        handle.onDragEnded = { nextEnded.append($0) }
        #expect(handle.dragOriginInWindow == nil)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: window) == false)
        let lateUp = try #require(resizeMouseEvent(.leftMouseUp, x: 135, window: window))
        handle.mouseUp(with: lateUp)
        for _ in 0 ..< 3 {
            if !ended.isEmpty { break }
            await Task.yield()
        }
        #expect(ended == [30])
        #expect(nextEnded.isEmpty)

        handle.isInteractionEnabled = true
        let nextDown = try #require(resizeMouseEvent(.leftMouseDown, x: 200, window: window))
        let nextDrag = try #require(resizeMouseEvent(.leftMouseDragged, x: 210, window: window))
        let nextUp = try #require(resizeMouseEvent(.leftMouseUp, x: 215, window: window))
        handle.mouseDown(with: nextDown)
        handle.mouseDragged(with: nextDrag)
        handle.mouseUp(with: nextUp)
        #expect(changed == [30, 10])
        #expect(ended == [30])
        #expect(nextEnded == [15])
        #expect(handle.dragOriginInWindow == nil)
    }

    @Test("window lifecycle interruption ends a resize exactly once")
    func horizontalResizeHandleEndsOnceWhenWindowResigns() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let handle = HorizontalResizeHandleView(
            frame: NSRect(x: 0, y: 0, width: 12, height: 100)
        )
        window.contentView = handle
        var ended: [CGFloat] = []
        handle.onDragEnded = { ended.append($0) }

        let down = try #require(resizeMouseEvent(.leftMouseDown, x: 80, window: window))
        let drag = try #require(resizeMouseEvent(.leftMouseDragged, x: 104, window: window))
        handle.mouseDown(with: down)
        handle.mouseDragged(with: drag)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: window))

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(handle.dragOriginInWindow == nil)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: window) == false)
        for _ in 0 ..< 3 {
            if !ended.isEmpty { break }
            await Task.yield()
        }
        #expect(ended == [24])

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        let lateUp = try #require(resizeMouseEvent(.leftMouseUp, x: 110, window: window))
        handle.mouseUp(with: lateUp)
        await Task.yield()
        #expect(ended == [24])
    }

    @Test("cursor ownership queries do not clear another window's owner")
    func horizontalResizeCursorOwnershipIsWindowScoped() throws {
        let firstWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        firstWindow.isReleasedWhenClosed = false
        secondWindow.isReleasedWhenClosed = false
        let firstHandle = HorizontalResizeHandleView(
            frame: NSRect(x: 0, y: 0, width: 12, height: 100)
        )
        firstWindow.contentView = firstHandle
        defer {
            HorizontalResizeCursorOwnership.release(firstHandle)
            firstWindow.close()
            secondWindow.close()
        }

        let down = try #require(resizeMouseEvent(.leftMouseDown, x: 100, window: firstWindow))
        firstHandle.mouseDown(with: down)

        #expect(firstHandle.dragOriginInWindow == 100)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: firstWindow))
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: secondWindow) == false)
        #expect(HorizontalResizeCursorOwnership.ownsCursor(in: firstWindow))
    }

    @Test("disabled horizontal resize handles reject first mouse and hit testing")
    func disabledHorizontalResizeHandleRejectsInteraction() {
        let handle = HorizontalResizeHandleView(
            frame: NSRect(x: 0, y: 0, width: 12, height: 100)
        )
        let insidePoint = NSPoint(x: 6, y: 50)

        #expect(handle.acceptsFirstMouse(for: nil))
        #expect(handle.hitTest(insidePoint) === handle)

        handle.isInteractionEnabled = false

        #expect(handle.acceptsFirstMouse(for: nil) == false)
        #expect(handle.hitTest(insidePoint) == nil)
    }

    private func resizeMouseEvent(
        _ type: NSEvent.EventType,
        x: CGFloat,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: x, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
    }

    @Test("workspace switch veil coalesces rapid requests onto the newest task")
    func workspaceSwitchVeilUsesNewestTask() throws {
        let taskB = UUID()
        let taskC = UUID()
        var state = TaskWorkspaceSwitchState()

        state.request(taskB)
        let coverRequest = state.beginVeilAnimation(to: true)
        let cover = try #require(coverRequest)
        state.setVeilPresented(true)

        state.request(taskC)
        let duplicateCover = state.beginVeilAnimation(to: true)
        let coverCompleted = state.completeVeilAnimation(cover)
        let requestedTaskID = state.takeRequestedTaskID()
        #expect(duplicateCover == nil)
        #expect(coverCompleted)
        #expect(state.isFullyCovered)
        #expect(requestedTaskID == taskC)
        #expect(state.requestedTaskID == nil)
    }

    @Test("a newer switch invalidates an in-flight veil reveal")
    func workspaceSwitchVeilRetargetsDuringReveal() throws {
        let taskB = UUID()
        let taskC = UUID()
        var state = TaskWorkspaceSwitchState()

        state.request(taskB)
        let initialCoverRequest = state.beginVeilAnimation(to: true)
        let initialCover = try #require(initialCoverRequest)
        state.setVeilPresented(true)
        let initialCoverCompleted = state.completeVeilAnimation(initialCover)
        let initiallyRequestedTaskID = state.takeRequestedTaskID()
        #expect(initialCoverCompleted)
        #expect(initiallyRequestedTaskID == taskB)

        let revealRequest = state.beginVeilAnimation(to: false)
        let reveal = try #require(revealRequest)
        state.setVeilPresented(false)
        state.request(taskC)
        let recoveryCoverRequest = state.beginVeilAnimation(to: true)
        let recoveryCover = try #require(recoveryCoverRequest)
        state.setVeilPresented(true)

        let staleRevealCompleted = state.completeVeilAnimation(reveal)
        let recoveryCoverCompleted = state.completeVeilAnimation(recoveryCover)
        let requestedTaskID = state.takeRequestedTaskID()
        #expect(staleRevealCompleted == false)
        #expect(recoveryCoverCompleted)
        #expect(state.isFullyCovered)
        #expect(requestedTaskID == taskC)
    }

    @Test("closing cancels a pending workspace switch and invalidates its completion")
    func workspaceSwitchVeilCancelsForClose() throws {
        var state = TaskWorkspaceSwitchState()

        state.request(UUID())
        let staleCoverRequest = state.beginVeilAnimation(to: true)
        let staleCover = try #require(staleCoverRequest)
        state.setVeilPresented(true)

        state.cancel()
        let closeRevealRequest = state.beginVeilAnimation(to: false)
        let closeReveal = try #require(closeRevealRequest)
        state.setVeilPresented(false)

        let staleCoverCompleted = state.completeVeilAnimation(staleCover)
        let closeRevealCompleted = state.completeVeilAnimation(closeReveal)
        #expect(staleCoverCompleted == false)
        #expect(closeRevealCompleted)
        #expect(state.requestedTaskID == nil)
        #expect(state.isActive == false)
        #expect(state.isFullyCovered == false)
        #expect(TaskWorkspaceSwitchMotion.coverDuration == 0.07)
        #expect(TaskWorkspaceSwitchMotion.revealDuration == 0.11)
    }

    @Test("a live terminal stays visible except while an automatic command is preparing")
    func terminalPaneIsSurfaceFirst() {
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: true,
            phase: .shellIdle
        ) == .terminal)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: true,
            phase: .failed("resume failed")
        ) == .terminal)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: true,
            phase: .preparing
        ) == .launching)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: false,
            phase: .preparing
        ) == .launching)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: false,
            phase: .hostExited
        ) == .rebuilding)
        #expect(TaskTerminalPaneMode.resolve(
            hasLiveSurface: false,
            phase: .failed("host failed")
        ) == .unavailable("host failed"))
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
