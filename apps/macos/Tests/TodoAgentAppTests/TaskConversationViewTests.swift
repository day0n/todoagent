import AppKit
import SwiftUI
import Testing
@testable import TodoAgentApp

@Suite("Task conversation presentation")
@MainActor
struct TaskConversationViewTests {
    @Test("assistant tool cards expose quiet notification states without animated status")
    func assistantToolCardPresentation() {
        let running = AssistantToolCardPresentation(state: .running)
        let completed = AssistantToolCardPresentation(state: .completed)
        let failed = AssistantToolCardPresentation(state: .failed)

        #expect(running.systemImage == "ellipsis")
        #expect(running.stateTitle == "处理中")
        #expect(completed.systemImage == "checkmark")
        #expect(completed.stateTitle == "完成")
        #expect(failed.systemImage == "xmark")
        #expect(failed.stateTitle == "失败")
    }

    @Test("tool results are collapsed by default and toggle their complete body")
    func toolResultDisclosureState() throws {
        let rawResult = #"{"error":"provider failed","detail":"RAW_RESULT_SENTINEL"}"#
        let entry = toolResultEntry(
            body: rawResult,
            payloadJSON: #"{"tool":"javascript","callId":"call-1"}"#
        )
        let presentation = try #require(entry.toolResultPresentation)
        var disclosure = TaskToolResultDisclosureState()

        #expect(presentation.title == "tool_result · javascript")
        #expect(presentation.isFailure == true)
        #expect(presentation.accessibilityValue(isExpanded: false) == "已折叠")
        #expect(disclosure.visibleBody(for: entry) == nil)

        disclosure.toggle(entryID: entry.id)

        #expect(disclosure.visibleBody(for: entry) == rawResult)
        #expect(presentation.accessibilityValue(isExpanded: true) == "已展开")

        disclosure.toggle(entryID: entry.id)
        #expect(disclosure.visibleBody(for: entry) == nil)
    }

    @Test("tool name metadata accepts name, tool, and tool_name")
    func toolNameMetadataVariants() {
        let payloads = [
            (#"{"name":"read"}"#, "tool_result · read"),
            (#"{"tool":"shell"}"#, "tool_result · shell"),
            (#"{"tool_name":"write_file"}"#, "tool_result · write_file"),
        ]

        for (payload, expectedTitle) in payloads {
            let entry = toolResultEntry(body: "ok", payloadJSON: payload)
            #expect(entry.toolResultPresentation?.title == expectedTitle)
            #expect(entry.toolResultPresentation?.isFailure == false)
        }
    }

    @Test("long JSON does not expand the initial transcript row")
    func collapsedLongResultHasBoundedHeight() {
        let longJSON = #"{"result":""#
            + String(repeating: "RAW_RESULT_SENTINEL-0123456789\n", count: 500)
            + #""}"#
        let entry = toolResultEntry(
            body: longJSON,
            payloadJSON: #"{"tool_name":"read_large_json"}"#
        )

        let collapsedHeight = hostedHeight(entry: entry, isExpanded: false)
        let expandedHeight = hostedHeight(entry: entry, isExpanded: true)

        #expect(collapsedHeight > 0)
        #expect(collapsedHeight < 120)
        #expect(expandedHeight > collapsedHeight * 4)
        #expect(entry.toolResultPresentation?.subtitle(isExpanded: false).contains("点击展开") == true)
        #expect(entry.toolResultPresentation?.subtitle(isExpanded: false).contains("RAW_RESULT_SENTINEL") == false)
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

    @Test("task detail sheet follows the parent window instead of covering it")
    func taskDetailSheetAdaptsToWindowSize() {
        let standard = TaskConversationSheetLayoutPolicy.resolve(
            availableSize: CGSize(width: 1_120, height: 720)
        )
        switch standard {
        case let .sideBySide(size, detailsWidth):
            #expect(size.width < 1_120)
            #expect(size.height < 720)
            #expect(size.width <= TaskConversationSheetLayoutPolicy.maximumWidth)
            #expect(size.height <= TaskConversationSheetLayoutPolicy.maximumHeight)
            #expect(detailsWidth >= 300)
            #expect(size.width - detailsWidth >= 460)
        case .stacked:
            Issue.record("标准窗口应使用紧凑双栏")
        }

        let compact = TaskConversationSheetLayoutPolicy.resolve(
            availableSize: CGSize(width: 760, height: 560)
        )
        switch compact {
        case .sideBySide:
            Issue.record("窄窗口应切换为上下布局")
        case let .stacked(size, detailsHeight):
            #expect(size.width < 760)
            #expect(size.height <= 520)
            #expect(detailsHeight >= 200)
            #expect(size.height - detailsHeight >= 280)
        }

        let large = TaskConversationSheetLayoutPolicy.resolve(
            availableSize: CGSize(width: 2_000, height: 1_200)
        )
        #expect(large.size == CGSize(width: 960, height: 680))
    }

    private func toolResultEntry(
        body: String,
        payloadJSON: String?
    ) -> TaskConversationEntry {
        TaskConversationEntry(
            id: "tool-result-1",
            sequence: 1,
            role: .tool,
            kind: "tool_result",
            title: "tool_result",
            body: body,
            payloadJSON: payloadJSON
        )
    }

    private func hostedHeight(
        entry: TaskConversationEntry,
        isExpanded: Bool
    ) -> CGFloat {
        let host = NSHostingView(
            rootView: TaskConversationEntryRow(
                entry: entry,
                isToolResultExpanded: isExpanded
            )
            .frame(width: 560)
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
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
