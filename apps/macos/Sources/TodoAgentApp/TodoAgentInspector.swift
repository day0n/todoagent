import AppKit
import SwiftUI

struct TodoAgentInspector: View {
    let state: AppState
    private let onClose: () -> Void

    @AppStorage("geminiModel") private var model = "gemini-3.6-flash"
    @State private var draft = ""
    @State private var pendingAttachments: [AssistantTextAttachment] = []
    @State private var attachmentError: String?
    @State private var renamingSession: AssistantSessionDescriptor?
    @State private var pendingArchive: AssistantSessionDescriptor?
    @FocusState private var composerFocused: Bool

    private var assistant: AssistantViewState { state.assistant }

    init(
        state: AppState,
        onClose: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = assistant.errorMessage {
                AssistantErrorBanner(message: error) { assistant.clearError() }
            }
            content
        }
        .background(TodoAgentUI.canvasBackground)
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
        .onChange(of: assistant.selectedSessionID) {
            pendingAttachments = []
            attachmentError = nil
        }
        .accessibilityIdentifier("todoagent.inspector")
    }

    private var header: some View {
        HStack(spacing: 8) {
            AssistantAvatar(statusColor: statusColor)
            sessionPicker

            Spacer()

            Button("新建会话", systemImage: "plus.bubble") {
                Task { _ = await assistant.createSession() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AssistantToolbarButtonStyle())
            .disabled(!assistant.canUseAssistant || assistant.isManagingSession)
            .help("新建 TodoAgent 对话")
            .accessibilityIdentifier("assistant.new-session")

            sessionActions

            Button("设置", systemImage: "gearshape") {
                SettingsWindowController.show(tab: .model)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AssistantToolbarButtonStyle())
            .help("TodoAgent 设置")
            .accessibilityIdentifier("assistant.settings")

            Button("收起 TodoAgent", systemImage: "chevron.right") {
                onClose()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(AssistantToolbarButtonStyle())
            .help("收起 TodoAgent")
            .accessibilityIdentifier("assistant.collapse")
        }
        .padding(.horizontal, TodoAgentUI.sectionSpacing)
        .frame(minHeight: 52)
        .background(TodoAgentUI.surfaceBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)
        }
    }

    private var sessionPicker: some View {
        Menu {
            ForEach(assistant.activeSessions) { session in
                Button {
                    Task { await assistant.selectSession(session.id) }
                } label: {
                    if session.id == assistant.selectedSessionID {
                        Label(session.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(session.displayTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(assistant.selectedSession?.displayTitle ?? "新建 AI 对话")
                    .font(.headline)
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .disabled(assistant.activeSessions.isEmpty || assistant.isManagingSession)
        .help("TodoAgent · \(statusLabel)")
        .accessibilityValue(statusLabel)
        .accessibilityIdentifier("assistant.session-picker")
    }

    private var sessionActions: some View {
        Menu {
            Button("重命名…", systemImage: "pencil") {
                renamingSession = assistant.selectedSession
            }
            .disabled(assistant.selectedSession == nil)

            Button("归档", systemImage: "archivebox", role: .destructive) {
                pendingArchive = assistant.selectedSession
            }
            .disabled(assistant.selectedSession == nil || assistant.isSelectedSessionRunning)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 28, height: 28)
                .contentShape(.rect(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("会话操作")
        .accessibilityIdentifier("assistant.session-actions")
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
                emptySessions
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
            Label("还没有会话", systemImage: "bubble.left")
        } description: {
            Text("创建一个独立会话，让 TodoAgent 帮你创建和整理任务。")
        } actions: {
            Button("新建会话") { Task { _ = await assistant.createSession() } }
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: TodoAgentUI.standardSpacing) {
                    if assistant.isLoadingHistory, assistant.selectedMessages.isEmpty {
                        ProgressView("正在载入历史…")
                            .padding(.vertical, 30)
                    } else if assistant.selectedMessages.isEmpty, assistant.selectedDraft == nil {
                        AssistantConversationEmptyState()
                            .padding(.vertical, 32)
                    }

                    ForEach(assistant.selectedMessages) { message in
                        AssistantMessageRow(message: message, state: state)
                            .id(message.id)
                    }

                    ForEach(assistant.selectedTools) { tool in
                        AssistantToolRow(tool: tool, state: state)
                            .id("tool-\(tool.id)")
                    }

                    if let draft = assistant.selectedDraft, !draft.body.isEmpty {
                        AssistantStreamingRow(draft: draft)
                            .id("streaming-\(draft.messageID)-\(draft.attempt)")
                    }

                    if let processingPhase {
                        AssistantProcessingRow(phase: processingPhase)
                            .id("assistant-processing")
                    }

                    if let turnError = assistant.selectedTurnError {
                        Label(turnError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
                    }

                    Color.clear.frame(height: 1).id("assistant-bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            .background(TodoAgentUI.canvasBackground)
            .onChange(of: assistant.selectedMessages.last?.id) {
                scrollToBottom(proxy)
            }
            .onChange(of: assistant.selectedDraft?.body) {
                scrollToBottom(proxy)
            }
            .onChange(of: assistant.selectedSessionID) {
                scrollToBottom(proxy, animated: false)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 11) {
            if !pendingAttachments.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(Array(pendingAttachments.enumerated()), id: \.offset) { index, attachment in
                        AssistantAttachmentChip(
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

            TextField("告诉 TodoAgent…", text: $draft, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($composerFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("assistant.composer")

            HStack(alignment: .center, spacing: 8) {
                Button("添加文本附件", systemImage: "plus") {
                    pickTextAttachments()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(AssistantComposerUtilityButtonStyle())
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

                Spacer()
                if assistant.isSelectedSessionRunning {
                    Button("停止本轮", systemImage: "stop.fill", role: .destructive) {
                        Task { await assistant.cancelSelectedTurn() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(AssistantComposerCircleButtonStyle(isEnabled: true))
                    .help("停止本轮")
                    .accessibilityIdentifier("assistant.stop")
                } else {
                    Button("发送", systemImage: "arrow.up") { submit() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(AssistantComposerCircleButtonStyle(isEnabled: canSubmit))
                        .disabled(!canSubmit)
                        .help("发送")
                        .accessibilityIdentifier("assistant.send")
                }
            }
        }
        .padding(13)
        .background(
            TodoAgentUI.surfaceBackground,
            in: .rect(cornerRadius: TodoAgentUI.composerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.composerRadius)
                .stroke(
                    composerFocused ? Color.accentColor : TodoAgentUI.hairline,
                    lineWidth: composerFocused ? 1.5 : 1
                )
        }
        .shadow(color: TodoAgentUI.shadowColor, radius: 10, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(TodoAgentUI.canvasBackground)
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
            return .processing
        }
        if assistant.selectedDraft?.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return .organizing
        }
        return .preparing
    }

    private var statusLabel: String {
        if assistant.loadState == .loading { return "正在连接" }
        guard let status = assistant.status else { return "未连接" }
        if !status.configured { return "未配置" }
        if !status.available { return "不可用" }
        return assistant.isSelectedSessionRunning ? "正在回复" : "已连接"
    }

    private var statusColor: Color {
        guard let status = assistant.status else { return .secondary }
        if !status.configured { return .orange }
        if !status.available { return .red }
        return .green
    }

    private var archivePresented: Binding<Bool> {
        Binding(
            get: { pendingArchive != nil },
            set: { if !$0 { pendingArchive = nil } }
        )
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

private struct AssistantErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button("关闭", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.07))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AssistantConversationEmptyState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(TodoAgentUI.primaryText)
                .frame(width: 44, height: 44)
                .background(TodoAgentUI.surfaceBackground, in: .circle)
                .overlay {
                    Circle().stroke(TodoAgentUI.hairline, lineWidth: 1)
                }
                .shadow(color: TodoAgentUI.shadowColor, radius: 8, y: 3)
                .accessibilityHidden(true)

            Text("随时待命，我能帮上什么忙吗？")
                .font(.title3.bold())
                .foregroundStyle(TodoAgentUI.primaryText)

            Text("TodoAgent 可以创建与更新任务、查找相关事项，并整理当前清单。")
                .font(.callout)
                .foregroundStyle(TodoAgentUI.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
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

private struct AssistantAvatar: View {
    let statusColor: Color

    var body: some View {
        Image(systemName: "sparkles")
            .font(.callout.weight(.semibold))
            .foregroundStyle(TodoAgentUI.primaryText)
            .frame(width: 30, height: 30)
            .background(TodoAgentUI.selectionBackground, in: .circle)
            .overlay {
                Circle().stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay { Circle().stroke(TodoAgentUI.surfaceBackground, lineWidth: 2) }
            }
            .accessibilityHidden(true)
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
                Text(message.body)
                    .font(.caption)
                    .textSelection(.enabled)
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
                Text(message.body)
                    .font(.callout)
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .textSelection(.enabled)
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
                Text(draft.body)
                    .font(.callout)
                    .textSelection(.enabled)
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
        HStack(spacing: 9) {
            AssistantOrbitGlyph()
            Text(phase.label)
                .font(.caption)
                .foregroundStyle(TodoAgentUI.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TodoAgent \(phase.label)")
    }
}

private struct AssistantOrbitGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.72)
                .stroke(TodoAgentUI.primaryText, style: .init(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(rotation))

            Circle()
                .trim(from: 0.18, to: 0.82)
                .stroke(TodoAgentUI.secondaryText, style: .init(lineWidth: 1.4, lineCap: .round))
                .frame(width: 10, height: 10)
                .rotationEffect(.degrees(-rotation * 1.35))
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
        .onAppear(perform: updateAnimation)
        .onChange(of: reduceMotion) { updateAnimation() }
    }

    private func updateAnimation() {
        if reduceMotion {
            withAnimation(.none) { rotation = 0 }
        } else {
            rotation = 0
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct AssistantToolRow: View {
    let tool: AssistantToolActivity
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if tool.state == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: tool.state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(tool.state == .failed ? .red : .green)
                }
                Text(tool.name)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer()
                Text(tool.state == .running ? "处理中" : tool.state == .failed ? "失败" : "完成")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if !tool.taskReferences.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tool.taskReferences, id: \.self) { taskID in
                        AssistantTaskReferenceButton(taskID: taskID, state: state)
                    }
                }
            }
        }
        .padding(9)
        .foregroundStyle(TodoAgentUI.primaryText)
        .background(TodoAgentUI.surfaceBackground, in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(TodoAgentUI.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
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
private struct FlowLayout: Layout {
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
