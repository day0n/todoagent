import AppKit
import SwiftUI

struct ChatTaskReferenceActions {
    let title: (UUID) -> String?
    let open: (UUID) -> Void

    static var unavailable: Self { Self(title: { _ in nil }, open: { _ in }) }
}

enum ChatDisclosurePreference {
    case automatic
    case expanded
    case collapsed

    func resolved(automaticValue: Bool) -> Bool {
        switch self {
        case .automatic: automaticValue
        case .expanded: true
        case .collapsed: false
        }
    }
}

struct ChatTranscriptView<EmptyContent: View>: View {
    let transcript: ChatTranscript
    let taskReferences: ChatTaskReferenceActions
    var maximumContentWidth: CGFloat = .infinity
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 20
    @ViewBuilder let emptyContent: EmptyContent

    @State private var isFollowingTail = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        transcript: ChatTranscript,
        taskReferences: ChatTaskReferenceActions = .unavailable,
        maximumContentWidth: CGFloat = .infinity,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 20,
        @ViewBuilder emptyContent: () -> EmptyContent
    ) {
        self.transcript = transcript
        self.taskReferences = taskReferences
        self.maximumContentWidth = maximumContentWidth
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.emptyContent = emptyContent()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if transcript.items.isEmpty {
                        emptyContent
                            .frame(maxWidth: .infinity)
                    }

                    ForEach(transcript.items) { item in
                        ChatTranscriptRow(item: item, taskReferences: taskReferences)
                            .id(item.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .frame(maxWidth: maximumContentWidth, alignment: .leading)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height <= geometry.containerSize.height + 2
                    || geometry.visibleRect.maxY >= geometry.contentSize.height - 48
            } action: { _, followsTail in
                isFollowingTail = followsTail
            }
            .task(id: transcript.sessionID) {
                await Task.yield()
                isFollowingTail = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onChange(of: transcript.tailRevision) {
                guard isFollowingTail else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = transcript.isRunning
                withTransaction(transaction) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isFollowingTail, !transcript.items.isEmpty {
                    Button("跳到最新消息", systemImage: "arrow.down") {
                        isFollowingTail = true
                        if reduceMotion {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .help("跳到最新消息")
                    .accessibilityIdentifier("chat.scroll-to-latest")
                    .padding(14)
                }
            }
        }
        .onChange(of: transcript.isRunning) { wasRunning, isRunning in
            guard wasRunning, !isRunning else { return }
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: ChatTerminalAnnouncementResolver.announcement(
                        for: transcript
                    ),
                ]
            )
        }
    }

    private var bottomID: String { "chat-bottom-\(transcript.sessionID)" }
}

/// Produces one terminal VoiceOver announcement from the newest completed
/// outcome only. Historical failures must not poison a later successful turn.
enum ChatTerminalAnnouncementResolver {
    static func announcement(for transcript: ChatTranscript) -> String {
        for item in transcript.items.reversed() {
            switch item {
            case let .turn(turn):
                guard !turn.isRunning else { continue }
                if !turn.errors.isEmpty { return "Agent 执行失败" }
                let tools = turn.activity?.items.compactMap { item -> ChatToolStep? in
                    guard case let .tool(tool) = item else { return nil }
                    return tool
                } ?? []
                if tools.contains(where: { $0.state == .failed || $0.isError }) {
                    return "Agent 执行失败"
                }
                if tools.contains(where: { $0.state == .interrupted }) {
                    return "Agent 已取消"
                }
                return "Agent 已完成回复"
            case .error:
                return "Agent 执行失败"
            case .notice:
                continue
            }
        }
        return "Agent 已完成回复"
    }
}

private struct ChatTranscriptRow: View {
    let item: ChatTranscriptItem
    let taskReferences: ChatTaskReferenceActions

    @ViewBuilder
    var body: some View {
        switch item {
        case let .turn(turn):
            ChatTurnRow(turn: turn, taskReferences: taskReferences)
        case let .notice(notice):
            ChatStatusRow(notice: notice)
        case let .error(error):
            AssistantFriendlyErrorView(rawMessage: error.body)
        }
    }
}

struct ChatTurnRow: View {
    let turn: ChatTurnItem
    let taskReferences: ChatTaskReferenceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(turn.userMessages) { message in
                ChatUserMessageRow(message: message, taskReferences: taskReferences)
            }

            if let activity = turn.activity {
                ChatActivityGroupView(group: activity, taskReferences: taskReferences)
            }

            if let assistant = turn.assistant, !assistant.body.isEmpty {
                ChatAssistantMessageRow(message: assistant, taskReferences: taskReferences)
            }

            ForEach(turn.notices) { notice in
                ChatStatusRow(notice: notice)
            }

            ForEach(turn.errors) { error in
                AssistantFriendlyErrorView(rawMessage: error.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.turn.\(turn.turnID)")
    }
}

private struct ChatUserMessageRow: View {
    let message: ChatTextItem
    let taskReferences: ChatTaskReferenceActions

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(alignment: .top) {
                Spacer(minLength: 42)
                VStack(alignment: .leading, spacing: 7) {
                    if !message.body.isEmpty {
                        Text(message.body)
                            .textSelection(.enabled)
                    }
                    if !message.attachments.isEmpty {
                        FlowLayout(spacing: 5) {
                            ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                                ChatAttachmentChip(attachment: attachment)
                            }
                        }
                    }
                    ChatTaskReferenceButtons(taskIDs: message.taskReferences, actions: taskReferences)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(TodoAgentUI.primaryText)
                .background(TodoAgentUI.selectionBackground, in: .rect(cornerRadius: 12))
            }

            HStack(spacing: 5) {
                if let timeLabel = message.timeLabel {
                    Text(timeLabel)
                        .font(.caption2)
                        .foregroundStyle(TodoAgentUI.secondaryText)
                }
                Button("复制消息", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.body, forType: .string)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(TodoAgentUI.secondaryText)
                .help("复制消息")
                .accessibilityIdentifier("\(message.id).copy")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("你发送的消息")
    }
}

private struct ChatAssistantMessageRow: View {
    let message: ChatTextItem
    let taskReferences: ChatTaskReferenceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ChatLazyMarkdownContent(
                id: message.id,
                text: message.body,
                isStreaming: message.isStreaming
            )
            .font(.callout)
            .foregroundStyle(TodoAgentUI.primaryText)
            ChatTaskReferenceButtons(taskIDs: message.taskReferences, actions: taskReferences)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.isStreaming ? "Agent 正在回复" : "Agent 回复")
    }
}

struct ChatMarkdownLoadKey: Hashable, Sendable {
    let id: String
    let body: String
    let shouldParse: Bool
}

struct ChatMarkdownLoadState: Equatable, Sendable {
    private(set) var key: ChatMarkdownLoadKey?
    private(set) var document: AssistantMarkdownDocument?

    mutating func begin(_ key: ChatMarkdownLoadKey) {
        self.key = key
        document = nil
    }

    @discardableResult
    mutating func accept(
        _ document: AssistantMarkdownDocument,
        for key: ChatMarkdownLoadKey
    ) -> Bool {
        guard self.key == key else { return false }
        self.document = document
        return true
    }
}

struct ChatLazyMarkdownContent: View {
    let id: String
    let text: String
    let isStreaming: Bool

    @State private var loadState = ChatMarkdownLoadState()

    var body: some View {
        ChatMarkdownContent(
            text: text,
            document: loadState.document,
            isStreaming: isStreaming
        )
        .task(id: ChatMarkdownLoadKey(id: id, body: text, shouldParse: !isStreaming)) {
            let key = ChatMarkdownLoadKey(id: id, body: text, shouldParse: !isStreaming)
            loadState.begin(key)
            guard key.shouldParse, !key.body.isEmpty else { return }
            guard let document = await AssistantMarkdownRenderCache.shared.document(
                id: key.id,
                source: key.body
            ), !Task.isCancelled else { return }
            loadState.accept(document, for: key)
        }
    }
}

private struct ChatMarkdownContent: View {
    let text: String
    let document: AssistantMarkdownDocument?
    let isStreaming: Bool

    @ViewBuilder
    var bodyView: some View {
        if let document {
            AssistantMarkdownView(document: document)
        } else {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            bodyView
            if isStreaming {
                Circle()
                    .fill(TodoAgentUI.secondaryText)
                    .frame(width: 4, height: 4)
                    .padding(.top, 8)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatActivityGroupView: View {
    let group: ChatActivityGroup
    let taskReferences: ChatTaskReferenceActions

    @State private var preference: ChatDisclosurePreference = .automatic

    private var isExpanded: Bool { preference.resolved(automaticValue: group.isRunning) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                preference = isExpanded ? .collapsed : .expanded
            } label: {
                HStack(spacing: 7) {
                    if group.isRunning {
                        AssistantWaveText(text: title)
                    } else {
                        Text(title)
                            .foregroundStyle(group.hasFailure ? Color.orange : TodoAgentUI.secondaryText)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TodoAgentUI.secondaryText)
                    Spacer(minLength: 0)
                }
                .font(.callout.weight(.medium))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Agent 活动，\(title)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityIdentifier("chat.activity.\(group.turnID)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(group.items) { item in
                        ChatActivityRow(item: item, taskReferences: taskReferences)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private var title: String {
        if group.isRunning { return "正在处理 · \(group.items.count) 个步骤" }
        if group.hasFailure { return "\(group.items.count) 个步骤 · 有未完成项" }
        return "\(group.items.count) 个步骤"
    }
}

private struct ChatActivityRow: View {
    let item: ChatActivityItem
    let taskReferences: ChatTaskReferenceActions

    @ViewBuilder
    var body: some View {
        switch item {
        case let .reasoning(reasoning):
            ChatReasoningRow(reasoning: reasoning)
        case let .narration(narration):
            ChatLazyMarkdownContent(
                id: narration.id,
                text: narration.body,
                isStreaming: narration.isStreaming
            )
            .font(.caption)
            .foregroundStyle(TodoAgentUI.secondaryText)
            .padding(.leading, 22)
        case let .tool(tool):
            ChatToolRow(tool: tool, taskReferences: taskReferences)
        case let .status(status):
            ChatStatusRow(notice: status)
                .padding(.leading, 22)
        }
    }
}

private struct ChatReasoningRow: View {
    let reasoning: ChatReasoningItem
    @State private var preference: ChatDisclosurePreference = .automatic

    private var isExpanded: Bool {
        preference.resolved(automaticValue: reasoning.isStreaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                let willExpand = !isExpanded
                preference = willExpand ? .expanded : .collapsed
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "brain")
                        .foregroundStyle(TodoAgentUI.secondaryText)
                    Text(reasoning.isStreaming ? "正在思考" : "思考过程")
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .foregroundStyle(TodoAgentUI.secondaryText)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reasoning.isStreaming ? "正在思考" : "思考过程")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")

            if isExpanded {
                ChatLazyMarkdownContent(
                    id: reasoning.id,
                    text: reasoning.body,
                    isStreaming: reasoning.isStreaming
                )
                .font(.caption)
                .foregroundStyle(TodoAgentUI.secondaryText)
                .padding(.leading, 22)
            }
        }
    }
}

private struct ChatToolRow: View {
    let tool: ChatToolStep
    let taskReferences: ChatTaskReferenceActions
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: stateIcon)
                        .foregroundStyle(stateColor)
                    Text(title)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TodoAgentUI.secondaryText)
                    Spacer(minLength: 0)
                }
                .font(.caption)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("工具 \(tool.name)，\(stateTitle)")
            .accessibilityValue(isExpanded ? "详情已展开" : "详情已折叠")
            .accessibilityIdentifier("chat.tool.\(tool.callID)")

            if isExpanded {
                ChatToolDetails(tool: tool, taskReferences: taskReferences)
                    .padding(.leading, 22)
            }
        }
    }

    private var title: String {
        switch tool.state {
        case .running: "正在运行 \(tool.name)"
        case .completed: "已完成 \(tool.name)"
        case .failed: "\(tool.name) 执行失败"
        case .interrupted: "\(tool.name) 已中断"
        case let .unknown(value): "\(tool.name) · \(value)"
        }
    }

    private var stateTitle: String {
        switch tool.state {
        case .running: "运行中"
        case .completed: "已完成"
        case .failed: "失败"
        case .interrupted: "已中断"
        case let .unknown(value): value
        }
    }

    private var stateIcon: String {
        switch tool.state {
        case .running: "circle"
        case .completed: "checkmark.circle.fill"
        case .failed, .interrupted: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var stateColor: Color {
        switch tool.state {
        case .failed, .interrupted: .orange
        case .completed: .green
        case .running, .unknown: TodoAgentUI.secondaryText
        }
    }
}

private struct ChatToolDetails: View {
    let tool: ChatToolStep
    let taskReferences: ChatTaskReferenceActions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LabeledContent("工具") {
                Text(tool.name).fontDesign(.monospaced)
            }
            LabeledContent("调用 ID") {
                Text(tool.callID)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let inputJSON = tool.inputJSON, !inputJSON.isEmpty {
                detailSection(title: "输入", value: inputJSON)
            }
            if let outputText = tool.outputText, !outputText.isEmpty {
                detailSection(title: "输出", value: outputText)
            }
            ChatTaskReferenceButtons(taskIDs: tool.taskReferences, actions: taskReferences)
        }
        .font(.caption2)
        .foregroundStyle(TodoAgentUI.secondaryText)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TodoAgentUI.selectionBackground.opacity(0.56), in: .rect(cornerRadius: 8))
    }

    private func detailSection(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(bounded(value))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bounded(_ value: String) -> String {
        let limit = 32_000
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "\n…内容过长，已截断显示"
    }
}

private struct ChatStatusRow: View {
    let notice: ChatNoticeItem

    var body: some View {
        Label(notice.body, systemImage: "circle.fill")
            .font(.caption)
            .foregroundStyle(TodoAgentUI.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("状态：\(notice.body)")
    }
}

struct ChatAttachmentChip: View {
    let attachment: AssistantAttachmentSummary
    var remove: (() -> Void)?

    init(attachment: AssistantAttachmentSummary, remove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.remove = remove
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.mediaType == "text/markdown" ? "text.document" : "doc.text")
                .accessibilityHidden(true)
            Text(attachment.name).lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                .foregroundStyle(TodoAgentUI.secondaryText)
            if let remove {
                Button("移除 \(attachment.name)", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(TodoAgentUI.primaryText)
        .background(TodoAgentUI.canvasBackground, in: .capsule)
        .overlay { Capsule().stroke(TodoAgentUI.hairline, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文本附件 \(attachment.name)")
    }
}

private struct ChatTaskReferenceButtons: View {
    let taskIDs: [UUID]
    let actions: ChatTaskReferenceActions

    @ViewBuilder
    var body: some View {
        if !taskIDs.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(taskIDs, id: \.self) { taskID in
                    if let title = actions.title(taskID) {
                        Button {
                            actions.open(taskID)
                        } label: {
                            Label(title, systemImage: "checklist")
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("打开任务")
                    } else {
                        Label("任务 \(taskID.uuidString.prefix(8))", systemImage: "checklist")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
