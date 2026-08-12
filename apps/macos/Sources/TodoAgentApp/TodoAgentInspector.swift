import AppKit
import SwiftUI

struct TodoAgentInspector: View {
    let state: AppState

    @AppStorage("geminiModel") private var model = "gemini-3.6-flash"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var pendingAttachments: [AssistantTextAttachment] = []
    @State private var attachmentError: String?
    @State private var sessionSwitcherPresented = false
    @State private var renamingSession: AssistantSessionDescriptor?
    @State private var pendingArchive: AssistantSessionDescriptor?
    @State private var pointerNearTranscriptIndicator = false
    @FocusState private var composerFocused: Bool

    private var assistant: AssistantViewState { state.assistant }

    init(state: AppState) {
        self.state = state
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                TodoAgentToolbar(
                    state: state,
                    sessionSwitcherPresented: $sessionSwitcherPresented
                ) {
                    state.inspectorPresented = false
                }

                Divider()

                if let error = assistant.errorMessage,
                   error != assistant.selectedTurnError
                {
                    AssistantFriendlyErrorView(rawMessage: error) { assistant.clearError() }
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                }
                content
            }

            if sessionSwitcherPresented {
                Color.black.opacity(0.001)
                    .contentShape(.rect)
                    .padding(.top, TodoAgentToolbar.height)
                    .onTapGesture { sessionSwitcherPresented = false }
                    .accessibilityHidden(true)

                AssistantSessionSwitcherPanel(
                    sessions: assistant.activeSessions,
                    selectedSessionID: assistant.selectedSessionID,
                    selectedSessionRunning: assistant.isSelectedSessionRunning,
                    selectionDisabled: assistant.isManagingSession,
                    onSelect: selectSession,
                    onRename: beginRenamingSelectedSession,
                    onArchive: beginArchivingSelectedSession
                )
                .padding(.horizontal, 10)
                .offset(y: AssistantSessionSwitcherLayout.panelTopOffset)
                .transition(
                    .scale(scale: 0.985, anchor: .topLeading)
                        .combined(with: .opacity)
                )
                .zIndex(2)
            }
        }
        .background(TodoAgentUI.canvasBackground)
        .onChange(of: assistant.selectedSessionID) {
            sessionSwitcherPresented = false
            pendingAttachments = []
            attachmentError = nil
        }
        .sheet(item: $renamingSession) { session in
            RenameAssistantSessionSheet(session: session, assistant: assistant)
        }
        .confirmationDialog(
            "归档这个会话？",
            isPresented: archivePresented,
            titleVisibility: .visible
        ) {
            Button("归档会话", role: .destructive) {
                Task { _ = await assistant.archiveSelectedSession() }
            }
            Button("取消", role: .cancel) { pendingArchive = nil }
        } message: {
            Text("会话会从列表中隐藏，已有任务和清单不会被删除。")
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: AssistantSessionSwitcherLayout.animationDuration),
            value: sessionSwitcherPresented
        )
        .accessibilityIdentifier("todoagent.inspector")
    }

    private func selectSession(_ sessionID: String) {
        sessionSwitcherPresented = false
        Task { await assistant.selectSession(sessionID) }
    }

    private func beginRenamingSelectedSession() {
        sessionSwitcherPresented = false
        renamingSession = assistant.selectedSession
    }

    private func beginArchivingSelectedSession() {
        sessionSwitcherPresented = false
        pendingArchive = assistant.selectedSession
    }

    private var archivePresented: Binding<Bool> {
        Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch assistant.loadState {
        case .idle, .loading:
            ProgressView("正在载入 TodoAgent…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case let .failed(message):
            ContentUnavailableView {
                Label("TodoAgent 暂时不可用", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await assistant.refresh() } }
            }

        case .loaded:
            if assistant.status?.configured != true {
                missingKey
            } else if assistant.status?.available != true {
                unavailableAssistant
            } else if assistant.activeSessions.isEmpty {
                if assistant.isManagingSession {
                    ProgressView("正在准备默认会话…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("assistant.default-session-loading")
                } else {
                    emptySessions
                }
            } else if assistant.selectedSession == nil {
                ContentUnavailableView("选择一个会话", systemImage: "bubble.left.and.bubble.right")
            } else {
                conversation
            }
        }
    }

    private var missingKey: some View {
        ContentUnavailableView {
            Label("配置 Gemini 后开始", systemImage: "key")
        } description: {
            Text("API Key 只保存在当前账户的 TodoAgent 本地凭据文件中。未配置时，任务和本地 Session 仍可正常使用。")
        } actions: {
            Button("打开 TodoAgent 设置") { SettingsWindowController.show(tab: .model) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var unavailableAssistant: some View {
        ContentUnavailableView {
            Label("无法连接 Gemini", systemImage: "wifi.exclamationmark")
        } description: {
            Text(assistant.status?.reason ?? "请检查 API Key 和模型设置。")
        } actions: {
            Button("打开设置") { SettingsWindowController.show(tab: .model) }
            Button("重试") { Task { await assistant.refresh() } }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptySessions: some View {
        ContentUnavailableView {
            Label("无法开始会话", systemImage: "exclamationmark.bubble")
        } description: {
            Text("默认会话没有创建成功。你的任务数据不受影响，可以直接重试。")
        } actions: {
            Button("重试创建默认会话") {
                Task { _ = await assistant.ensureDefaultSession() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(assistant.isManagingSession)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            transcript
            composer
        }
    }

    private var transcript: some View {
        ChatTranscriptView(
            transcript: assistant.selectedChatTranscript,
            taskReferences: chatTaskReferences,
            horizontalPadding: 24,
            verticalPadding: 18
        ) {
            if assistant.isLoadingHistory {
                Text("正在载入历史…")
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .padding(.vertical, 30)
            } else {
                AssistantConversationEmptyState { suggestion in
                    draft = suggestion
                    composerFocused = true
                }
                .padding(.vertical, 32)
            }
        }
        .background(TodoAgentUI.canvasBackground)
    }

    private var chatTaskReferences: ChatTaskReferenceActions {
        ChatTaskReferenceActions(
            title: { taskID in state.task(id: taskID)?.title },
            open: { taskID in
                guard let task = state.task(id: taskID) else { return }
                state.openTask(task)
            }
        )
    }

    private var composer: some View {
        ChatComposer(
            text: $draft,
            focus: $composerFocused,
            placeholder: "告诉 TodoAgent…",
            isRunning: assistant.isSelectedSessionRunning,
            canSubmit: canSubmit,
            accessibilityPrefix: "assistant",
            onSubmit: submit,
            onStop: { Task { await assistant.cancelSelectedTurn() } }
        ) {
            if !pendingAttachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                        ChatAttachmentChip(
                            attachment: AssistantAttachmentSummary(
                                name: attachment.name,
                                mediaType: attachment.mediaType,
                                byteCount: attachment.byteCount
                            ),
                            remove: {
                                guard !assistant.isSelectedSessionRunning else { return }
                                pendingAttachments.remove(at: index)
                            }
                        )
                    }
                }
                .accessibilityIdentifier("assistant.pending-attachments")
                .disabled(assistant.isSelectedSessionRunning)
            }

            if let attachmentError {
                Text(attachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("assistant.attachment-error")
            }
        } accessories: {
            Button("添加文本附件", systemImage: "plus") {
                pickTextAttachments()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ChatComposerUtilityButtonStyle())
            .help("添加 .txt 或 .md 附件")
            .accessibilityHint("选择文本或 Markdown 文件")
            .accessibilityIdentifier("assistant.add-attachment")
            .disabled(assistant.isSelectedSessionRunning)

            Button {
                SettingsWindowController.show(tab: .model)
            } label: {
                Label("自动", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }
            .buttonStyle(.plain)
            .help("TodoAgent 设置 · 当前模型 \(model)")
            .accessibilityLabel("TodoAgent 设置，自动模式")
            .accessibilityIdentifier("assistant.composer-settings")
        }
    }

    private var canSubmit: Bool {
        (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingAttachments.isEmpty)
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && assistant.canUseAssistant
            && assistant.selectedSession != nil
            && !assistant.isSelectedSessionRunning
    }

    private var processingPhase: AssistantProcessingPhase? {
        guard assistant.isSelectedSessionRunning else { return nil }
        if assistant.selectedTools.contains(where: { $0.state == .running }) {
            // The active tool group already carries the animated progress
            // treatment, so a second status row would duplicate it.
            return nil
        }
        if assistant.selectedDraft?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .organizing
        }
        return .preparing
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }
        Task {
            if await assistant.send(text: value, model: model, attachments: pendingAttachments) {
                draft = ""
                pendingAttachments = []
                attachmentError = nil
                composerFocused = true
            }
        }
    }

    private func pickTextAttachments() {
        guard !assistant.isSelectedSessionRunning else { return }
        Task { @MainActor in
            do {
                guard let picked = try await AssistantTextAttachmentPicker.pick() else { return }
                pendingAttachments = try AssistantTextAttachmentSelection.appending(
                    picked,
                    to: pendingAttachments
                )
                attachmentError = nil
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("assistant-bottom", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("assistant-bottom", anchor: .bottom)
        }
    }
}

/// Compact controls owned by the assistant pane. Keeping them inside the pane
/// lets the conversation switcher expand below this row instead of allowing a
/// native menu to cover the window toolbar.
struct TodoAgentToolbar: View {
    static let height: CGFloat = 46

    let state: AppState
    @Binding var sessionSwitcherPresented: Bool
    let onClose: () -> Void

    private var assistant: AssistantViewState { state.assistant }

    var body: some View {
        HStack(spacing: 6) {
            sessionPicker

            Button("开始新对话", systemImage: "plus.bubble") {
                Task { _ = await assistant.createSession() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AssistantToolbarButtonStyle())
            .disabled(!assistant.canUseAssistant || assistant.isManagingSession)
            .help("开始新对话")
            .accessibilityIdentifier("assistant.new-session")

            Button("隐藏对话", systemImage: "chevron.right") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AssistantToolbarButtonStyle())
            .help("隐藏对话")
            .accessibilityIdentifier("assistant.collapse")
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(TodoAgentUI.canvasBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.window-toolbar")
    }

    private var sessionPicker: some View {
        Button {
            sessionSwitcherPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(assistant.selectedSession?.displayTitle ?? "新建 AI 对话")
                    .font(.headline)
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .lineLimit(1)
                Image(systemName: sessionSwitcherPresented ? "chevron.up" : "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 30, alignment: .leading)
            .background(
                sessionSwitcherPresented ? TodoAgentUI.selectionBackground : .clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
        .disabled(assistant.activeSessions.isEmpty || assistant.isManagingSession)
        .help("切换对话 · \(statusLabel)")
        .accessibilityValue("\(statusLabel)，\(sessionSwitcherPresented ? "已展开" : "已折叠")")
        .accessibilityIdentifier("assistant.session-picker")
    }

    private var statusLabel: String {
        if assistant.loadState == .loading { return "正在连接" }
        guard let status = assistant.status else { return "未连接" }
        if !status.configured { return "未配置" }
        if !status.available { return "不可用" }
        return assistant.isSelectedSessionRunning ? "正在回复" : "已连接"
    }
}

struct AssistantSessionSwitcherPanel: View {
    let sessions: [AssistantSessionDescriptor]
    let selectedSessionID: String?
    let selectedSessionRunning: Bool
    let selectionDisabled: Bool
    let onSelect: (String) -> Void
    let onRename: () -> Void
    let onArchive: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(historySections) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TodoAgentUI.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.top, 7)
                            .padding(.bottom, 3)

                        ForEach(section.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
            .frame(height: sessionListHeight)

            if selectedSessionID != nil {
                Divider()
                    .padding(.horizontal, 10)
                    .padding(.top, 7)

                HStack(spacing: 8) {
                    Button("重命名", systemImage: "pencil", action: onRename)
                        .buttonStyle(AssistantSwitcherActionButtonStyle())

                    Spacer(minLength: 0)

                    Button("归档", systemImage: "archivebox", role: .destructive, action: onArchive)
                        .buttonStyle(AssistantSwitcherActionButtonStyle(isDestructive: true))
                        .disabled(selectedSessionRunning)
                }
                .padding(8)
                .disabled(selectionDisabled)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            TodoAgentUI.surfaceBackground,
            in: .rect(cornerRadius: AssistantSessionSwitcherLayout.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AssistantSessionSwitcherLayout.cornerRadius)
                .stroke(TodoAgentUI.hairline, lineWidth: 1)
        }
        .shadow(color: TodoAgentUI.shadowColor, radius: 14, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("assistant.session-switcher")
    }

    private var historySections: [AssistantSessionHistorySection] {
        AssistantSessionHistoryProjection.sections(from: sessions)
    }

    private func sessionRow(_ session: AssistantSessionDescriptor) -> some View {
        let isSelected = session.id == selectedSessionID

        return Button {
            onSelect(session.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? TodoAgentUI.primaryText : .clear)
                    .frame(width: 14)
                    .accessibilityHidden(true)

                Text(session.displayTitle)
                    .font(.body)
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if session.isRunning {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.green)
                        .accessibilityLabel("正在回复")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(
                isSelected ? TodoAgentUI.selectionBackground : .clear,
                in: .rect(cornerRadius: 8)
            )
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(selectionDisabled)
        .accessibilityValue(isSelected ? "当前对话" : "")
        .accessibilityIdentifier("assistant.session-row.\(session.id)")
    }

    private var sessionListHeight: CGFloat {
        AssistantSessionSwitcherLayout.listHeight(
            sessionCount: sessions.count,
            sectionCount: historySections.count
        )
    }
}

@MainActor
enum AssistantSessionSwitcherLayout {
    static let verticalGap: CGFloat = 4
    static let panelTopOffset = TodoAgentToolbar.height + verticalGap
    static let cornerRadius: CGFloat = 12
    static let animationDuration: TimeInterval = 0.18
    static let maximumListHeight: CGFloat = 172

    static func listHeight(sessionCount: Int, sectionCount: Int) -> CGFloat {
        let rows = CGFloat(max(sessionCount, 1)) * 39
        let headings = CGFloat(max(sectionCount, 1)) * 23
        return min(max(rows + headings + 8, 70), maximumListHeight)
    }
}

struct AssistantSessionHistorySection: Identifiable, Equatable {
    let id: String
    let title: String
    var sessions: [AssistantSessionDescriptor]
}

enum AssistantSessionHistoryProjection {
    static func sections(
        from sessions: [AssistantSessionDescriptor],
        now: Date = .now,
        calendar: Calendar = .todoAgentLocal
    ) -> [AssistantSessionHistorySection] {
        let today = LocalDay(now, calendar: calendar)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
            .map { LocalDay($0, calendar: calendar) }
        var sections: [AssistantSessionHistorySection] = []

        for session in sessions {
            let date = date(from: session.updatedAt) ?? date(from: session.createdAt)
            let day = date.map { LocalDay($0, calendar: calendar) }
            let id = day?.rawValue ?? "recent"

            if let index = sections.firstIndex(where: { $0.id == id }) {
                sections[index].sessions.append(session)
            } else {
                sections.append(
                    AssistantSessionHistorySection(
                        id: id,
                        title: title(
                            for: day,
                            displayDate: date,
                            today: today,
                            yesterday: yesterday
                        ),
                        sessions: [session]
                    )
                )
            }
        }

        if sections.isEmpty {
            sections.append(
                AssistantSessionHistorySection(
                    id: "recent",
                    title: "最近",
                    sessions: []
                )
            )
        }
        return sections
    }

    private static func date(from value: String) -> Date? {
        guard !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func title(
        for day: LocalDay?,
        displayDate: Date?,
        today: LocalDay,
        yesterday: LocalDay?
    ) -> String {
        guard let day else { return "最近" }
        if day == today { return "今天" }
        if day == yesterday { return "昨天" }
        return displayDate?.formatted(.dateTime.month().day()) ?? day.rawValue
    }
}

private struct AssistantSwitcherActionButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(isDestructive ? Color.red : TodoAgentUI.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                configuration.isPressed ? TodoAgentUI.selectionBackground : .clear,
                in: .rect(cornerRadius: 7)
            )
            .contentShape(.rect(cornerRadius: 7))
    }
}

private struct AssistantConversationEmptyState: View {
    private struct Suggestion: Identifiable {
        let title: String
        let prompt: String

        var id: String { title }
    }

    let selectSuggestion: (String) -> Void

    private let suggestions = [
        Suggestion(title: "整理今天的任务", prompt: "把今天要执行的任务按优先级整理一下"),
        Suggestion(title: "检查逾期事项", prompt: "帮我找出所有未完成且已经逾期的任务"),
        Suggestion(title: "规划接下来四天", prompt: "根据现有任务规划接下来四天的执行安排"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TodoAgentBrandMarkView(size: 34)
                .frame(width: 48, height: 48)
                .background(TodoAgentUI.surfaceBackground, in: .circle)
                .overlay {
                    Circle().stroke(TodoAgentUI.hairline, lineWidth: 1)
                }
                .shadow(color: TodoAgentUI.shadowColor, radius: 8, y: 3)
                .accessibilityHidden(true)

            Text("随时待命，我能帮上什么忙吗？")
                .font(.title3.bold())
                .foregroundStyle(TodoAgentUI.primaryText)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(suggestions) { suggestion in
                    Button {
                        selectSuggestion(suggestion.prompt)
                    } label: {
                        Label(suggestion.title, systemImage: suggestionIcon(for: suggestion.title))
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .accessibilityHint("把建议填入输入框，不会自动发送")
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func suggestionIcon(for title: String) -> String {
        switch title {
        case "整理今天的任务": "list.bullet"
        case "检查逾期事项": "calendar.badge.exclamationmark"
        default: "calendar.badge.clock"
        }
    }
}

private struct AssistantToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TodoAgentUI.primaryText)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed ? TodoAgentUI.selectionBackground : .clear,
                in: .rect(cornerRadius: 7)
            )
            .contentShape(.rect(cornerRadius: 7))
    }
}

struct AssistantTranscriptTrack<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVStack(spacing: TodoAgentUI.standardSpacing) {
            content
        }
        // The transcript owns one stable, viewport-wide message track.
        // Expandable descendants may grow vertically, but must never resize
        // and recenter unrelated history rows.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }
}

private struct AssistantComposerUtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(TodoAgentUI.secondaryText)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed ? TodoAgentUI.selectionBackground : .clear,
                in: .circle
            )
            .contentShape(.circle)
    }
}

private struct AssistantComposerCircleButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                isEnabled ? Color.black.opacity(configuration.isPressed ? 0.72 : 1) : Color.black.opacity(0.16),
                in: .circle
            )
            .contentShape(.circle)
    }
}

private struct AssistantMessageRow: View {
    let message: AssistantMessage
    let state: AppState

    var body: some View {
        switch message.role {
        case .system:
            Label(message.body, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                Label(message.kind, systemImage: "wrench.and.screwdriver")
                    .font(.caption.bold())
                ChatLazyMarkdownContent(
                    id: message.id,
                    text: message.body,
                    isStreaming: false
                )
                    .font(.caption)
                taskReferences
            }
            .padding(10)
            .foregroundStyle(TodoAgentUI.primaryText)
            .background(TodoAgentUI.surfaceBackground, in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
        case .user:
            VStack(alignment: .trailing, spacing: 5) {
                VStack(alignment: .leading, spacing: 7) {
                    if !message.body.isEmpty {
                        Text(message.body)
                            .textSelection(.enabled)
                    }
                    if !message.textAttachments.isEmpty {
                        FlowLayout(spacing: 5) {
                            ForEach(Array(message.textAttachments.enumerated()), id: \.offset) { _, attachment in
                                AssistantAttachmentChip(attachment: attachment)
                            }
                        }
                    }
                    taskReferences
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .foregroundStyle(TodoAgentUI.primaryText)
                .background(TodoAgentUI.selectionBackground, in: .rect(cornerRadius: 12))

                HStack(spacing: 5) {
                    if let timeLabel {
                        Text(timeLabel)
                            .font(.caption2)
                            .foregroundStyle(TodoAgentUI.secondaryText)
                    }
                    Button("复制消息", systemImage: "doc.on.doc", action: copyMessage)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(TodoAgentUI.secondaryText)
                        .help("复制消息")
                        .accessibilityIdentifier("assistant.message.\(message.id).copy")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .todoAgent:
            VStack(alignment: .leading, spacing: 7) {
                ChatLazyMarkdownContent(
                    id: message.id,
                    text: message.body,
                    isStreaming: false
                )
                    .font(.callout)
                    .foregroundStyle(TodoAgentUI.primaryText)
                taskReferences
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
    }

    private var timeLabel: String? {
        guard !message.createdAt.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: message.createdAt) ?? ISO8601DateFormatter().date(from: message.createdAt)
        return date?.formatted(date: .omitted, time: .shortened)
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.body, forType: .string)
    }

    @ViewBuilder
    private var taskReferences: some View {
        if !message.taskReferences.isEmpty {
            FlowLayout(spacing: 5) {
                ForEach(message.taskReferences, id: \.self) { taskID in
                    AssistantTaskReferenceButton(taskID: taskID, state: state)
                }
            }
        }
    }
}

private struct AssistantAttachmentChip: View {
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
            Text(attachment.name)
                .lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                .foregroundStyle(TodoAgentUI.secondaryText)
            if let remove {
                Button("移除 \(attachment.name)", systemImage: "xmark", action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("assistant.attachment.remove")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(TodoAgentUI.primaryText)
        .background(TodoAgentUI.canvasBackground, in: .capsule)
        .overlay {
            Capsule().stroke(TodoAgentUI.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("文本附件 \(attachment.name)")
    }
}

private struct AssistantStreamingRow: View {
    let draft: AssistantStreamingDraft

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                ChatLazyMarkdownContent(
                    id: draft.messageID,
                    text: draft.body,
                    isStreaming: true
                )
                    .font(.callout)
            }
            .foregroundStyle(TodoAgentUI.primaryText)
            Spacer(minLength: 38)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("TodoAgent 正在回复：\(draft.body)")
    }
}

private enum AssistantProcessingPhase {
    case preparing
    case processing
    case organizing

    var label: String {
        switch self {
        case .preparing: "准备中"
        case .processing: "正在处理"
        case .organizing: "正在整理"
        }
    }
}

private struct AssistantProcessingRow: View {
    let phase: AssistantProcessingPhase

    var body: some View {
        HStack(spacing: 7) {
            AssistantWaveText(text: phase.label)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TodoAgent \(phase.label)")
    }
}

private struct AssistantTaskReferenceButton: View {
    let taskID: UUID
    let state: AppState

    var body: some View {
        if let task = state.task(id: taskID) {
            Button {
                state.openTask(task)
            } label: {
                Label(task.title, systemImage: "checklist")
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

private struct RenameAssistantSessionSheet: View {
    let session: AssistantSessionDescriptor
    let assistant: AssistantViewState

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isSaving = false
    @FocusState private var titleFocused: Bool

    init(session: AssistantSessionDescriptor, assistant: AssistantViewState) {
        self.session = session
        self.assistant = assistant
        _title = State(initialValue: session.displayTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("重命名会话")
                .font(.title2.bold())
            TextField("会话名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($titleFocused)
                .onSubmit(save)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedTitle.isEmpty || isSaving)
            }
        }
        .padding(22)
        .frame(width: 360)
        .defaultFocus($titleFocused, true)
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !normalizedTitle.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            if await assistant.renameSelectedSession(to: normalizedTitle) { dismiss() }
            isSaving = false
        }
    }
}

/// A compact wrapping layout keeps task references readable inside the narrow
/// native inspector without nesting horizontal scroll views.
struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let width = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + spacing
                lineHeight = 0
            }
            points.append(origin)
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, origin.x - spacing)
        }

        return (CGSize(width: min(usedWidth, width), height: origin.y + lineHeight), points)
    }
}
