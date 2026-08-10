import AppKit
import SwiftUI

extension Notification.Name {
    static let todoAgentRequestTaskSheetClose = Notification.Name("TodoAgent.requestTaskSheetClose")
}

struct TaskConversationSheet: View {
    let taskID: UUID
    let state: AppState
    let availableSize: CGSize

    @State private var detailDraft: TaskDetailDraft
    @State private var isClosing = false
    @State private var isStartingSession = false

    init(
        task: TaskItem,
        state: AppState,
        availableSize: CGSize = TodoAgentMainWindowPlacement.preferredContentSize
    ) {
        taskID = task.id
        self.state = state
        self.availableSize = availableSize
        _detailDraft = State(initialValue: TaskDetailDraft(task: task))
    }

    var body: some View {
        let layout = TaskConversationSheetLayoutPolicy.resolve(
            availableSize: availableSize
        )

        Group {
            if let task = state.task(id: taskID) {
                taskLayout(task, layout: layout)
                .onChange(of: task) { _, authoritativeTask in
                    detailDraft.reconcile(
                        with: authoritativeTask,
                        saveState: state.taskSaveState(taskID: taskID)
                    )
                }
                .onChange(of: state.taskSaveState(taskID: taskID)) { _, saveState in
                    guard let authoritativeTask = state.task(id: taskID) else { return }
                    detailDraft.reconcile(with: authoritativeTask, saveState: saveState)
                }
            } else {
                ContentUnavailableView(
                    "任务已不存在",
                    systemImage: "questionmark.folder",
                    description: Text("关闭窗口后刷新任务列表。")
                )
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .interactiveDismissDisabled(true)
        .accessibilityIdentifier("task.session.\(taskID.uuidString)")
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentRequestTaskSheetClose)) { _ in
            close()
        }
    }

    @ViewBuilder
    private func taskLayout(
        _ task: TaskItem,
        layout: TaskConversationSheetLayout
    ) -> some View {
        switch layout {
        case let .sideBySide(_, detailsWidth):
            HStack(spacing: 0) {
                detailsPane(task)
                    .frame(width: detailsWidth)
                Divider()
                taskSessionPane(task)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case let .stacked(_, detailsHeight):
            VStack(spacing: 0) {
                taskSessionPane(task)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detailsPane(task)
                    .frame(height: detailsHeight)
            }
        }
    }

    private func detailsPane(_ task: TaskItem) -> some View {
        TaskDetailsPane(
            task: task,
            draft: $detailDraft,
            state: state
        )
        .disabled(isClosing || isStartingSession)
    }

    @ViewBuilder
    private func taskSessionPane(_ task: TaskItem) -> some View {
        if state.isLoadingSession(for: task) {
            TaskSessionLoadingView(task: task, isClosing: isClosing, onClose: close)
        } else if let session = state.conversation(for: task) {
            TaskConversationPanel(
                task: task,
                session: session,
                state: state,
                isClosing: isClosing,
                onClose: close
            )
        } else {
            TaskSessionSetupView(
                task: task,
                state: state,
                isClosing: isClosing,
                isStarting: $isStartingSession,
                flushTaskEdits: flushTaskEdits,
                onClose: close
            )
        }
    }

    private func flushTaskEdits() async -> Bool {
        await state.flushTaskEdits(taskID: taskID)
    }

    private func close() {
        guard !isClosing, !isStartingSession else { return }
        isClosing = true
        Task { @MainActor in
            if await state.flushAndDismissTaskSession(taskID: taskID) == false {
                isClosing = false
            }
        }
    }
}

enum TaskConversationSheetLayout: Equatable, Sendable {
    case sideBySide(size: CGSize, detailsWidth: CGFloat)
    case stacked(size: CGSize, detailsHeight: CGFloat)

    var size: CGSize {
        switch self {
        case let .sideBySide(size, _), let .stacked(size, _): size
        }
    }
}

enum TaskConversationSheetLayoutPolicy {
    static let sideBySideThreshold: CGFloat = 900
    static let maximumWidth: CGFloat = 960
    static let maximumHeight: CGFloat = 680

    static func resolve(availableSize: CGSize) -> TaskConversationSheetLayout {
        let available = normalized(availableSize)

        if available.width >= sideBySideThreshold {
            let size = CGSize(
                width: bounded(
                    available.width * 0.78,
                    minimum: 800,
                    maximum: min(maximumWidth, available.width - 48)
                ),
                height: bounded(
                    available.height * 0.78,
                    minimum: 520,
                    maximum: min(maximumHeight, available.height - 40)
                )
            )
            let detailsWidth = bounded(
                size.width * 0.38,
                minimum: 300,
                maximum: 350
            )
            return .sideBySide(size: size, detailsWidth: detailsWidth)
        }

        let size = CGSize(
            width: bounded(
                available.width * 0.90,
                minimum: 520,
                maximum: min(720, available.width - 32)
            ),
            height: bounded(
                available.height * 0.86,
                minimum: 500,
                maximum: min(680, available.height - 40)
            )
        )
        let detailsHeight = bounded(
            size.height * 0.42,
            minimum: 200,
            maximum: 260
        )
        return .stacked(size: size, detailsHeight: detailsHeight)
    }

    private static func normalized(_ size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return TodoAgentMainWindowPlacement.preferredContentSize
        }
        return size
    }

    private static func bounded(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        let upperBound = max(maximum, 0)
        guard upperBound >= minimum else { return upperBound }
        return min(max(value, minimum), upperBound)
    }
}

struct TaskDetailDraft: Equatable {
    var title: String
    var note: String
    var status: TaskStatus
    var executionDate: LocalDay?
    var dueDate: LocalDay?

    init(task: TaskItem) {
        title = task.title
        note = task.note
        status = task.status
        executionDate = task.executionDate
        dueDate = task.dueDate
    }

    mutating func reconcile(with task: TaskItem, saveState: TaskSaveState) {
        guard saveState == .idle else { return }
        self = TaskDetailDraft(task: task)
    }
}

private struct TaskDetailsPane: View {
    let task: TaskItem
    @Binding var draft: TaskDetailDraft
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailsHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    titleAndCompletion
                    dateSection
                    attachmentSection
                    noteSection
                    saveFeedback
                }
                .padding(22)
            }
        }
        .background(TodoAgentUI.surfaceBackground)
        .accessibilityIdentifier("task.details.\(task.id.uuidString)")
    }

    private var detailsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("任务详情")
                    .font(.headline)
                Text("所有修改自动保存")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            saveStateLabel
        }
        .padding(.horizontal, 22)
        .frame(height: 64)
    }

    @ViewBuilder
    private var saveStateLabel: some View {
        switch state.taskSaveState(taskID: task.id) {
        case .idle:
            Label("已保存", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .debouncing:
            Label("等待保存", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .saving:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("保存中")
            }
            .foregroundStyle(.secondary)
        case .failed:
            Label("保存失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var titleAndCompletion: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                setStatus(draft.status == .open ? .completed : .open)
            } label: {
                Image(systemName: draft.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(draft.status == .completed ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(draft.status == .completed ? "重新打开" : "标记完成")
            .accessibilityIdentifier("task.details.completed")

            TextField("任务标题", text: titleBinding, axis: .vertical)
                .font(.title2.bold())
                .textFieldStyle(.plain)
                .lineLimit(1 ... 3)
                .strikethrough(draft.status == .completed)
                .accessibilityIdentifier("task.details.title")
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            OptionalLocalDayRow(
                title: "执行日期",
                systemImage: "sun.max",
                day: executionDateBinding,
                today: state.currentDay,
                tint: isDraftDateOverdue(draft.executionDate) ? .red : .primary,
                accessibilityIdentifier: "task.details.execution-date"
            )

            Divider()

            OptionalLocalDayRow(
                title: "截止日期",
                systemImage: "calendar",
                day: dueDateBinding,
                today: state.currentDay,
                tint: isDraftDateOverdue(draft.dueDate) ? .red : .primary,
                accessibilityIdentifier: "task.details.due-date"
            )
        }
    }

    private func isDraftDateOverdue(_ day: LocalDay?) -> Bool {
        draft.status == .open && day.map { $0 < state.currentDay } == true
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("附件")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Button("添加文件", systemImage: "paperclip", action: chooseAttachments)
                    .controlSize(.small)
                    .accessibilityIdentifier("task.details.add-attachment")
            }

            if task.attachments.isEmpty {
                Text("附件只作为你的备忘，不会发送给 Agent。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(task.attachments) { attachment in
                        TaskAttachmentRow(
                            attachment: attachment,
                            onOpen: { open(attachment) },
                            onReveal: { reveal(attachment) },
                            onRemove: { remove(attachment) }
                        )
                    }
                }
            }
        }
    }

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("备注")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text("\(draft.note.count)/4000")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: noteBinding)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 150)
                .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(TodoAgentUI.hairline, lineWidth: 1)
                }
                .accessibilityLabel("任务备注")
                .accessibilityIdentifier("task.details.note")
        }
    }

    @ViewBuilder
    private var saveFeedback: some View {
        if case let .failed(message) = state.taskSaveState(taskID: task.id) {
            VStack(alignment: .leading, spacing: 10) {
                Label("修改尚未保存", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Button("重试") {
                    Task { _ = await state.retryTaskEdits(taskID: task.id) }
                }
                .accessibilityIdentifier("task.details.retry-save")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.07), in: .rect(cornerRadius: 9))
            .accessibilityIdentifier("task.details.save-error")
        }
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft.title },
            set: { value in
                let limited = String(value.prefix(500))
                guard limited != draft.title else { return }
                draft.title = limited
                state.scheduleTaskUpdate(
                    taskID: task.id,
                    patch: TaskPatch(title: limited)
                )
            }
        )
    }

    private var noteBinding: Binding<String> {
        Binding(
            get: { draft.note },
            set: { value in
                let limited = String(value.prefix(4_000))
                guard limited != draft.note else { return }
                draft.note = limited
                state.scheduleTaskUpdate(
                    taskID: task.id,
                    patch: TaskPatch(note: limited)
                )
            }
        )
    }

    private var executionDateBinding: Binding<LocalDay?> {
        Binding(
            get: { draft.executionDate },
            set: { value in
                guard value != draft.executionDate else { return }
                draft.executionDate = value
                saveImmediately(
                    TaskPatch(executionDate: value.map(TaskPatchField.set) ?? .clear)
                )
            }
        )
    }

    private var dueDateBinding: Binding<LocalDay?> {
        Binding(
            get: { draft.dueDate },
            set: { value in
                guard value != draft.dueDate else { return }
                draft.dueDate = value
                saveImmediately(TaskPatch(dueDate: value.map(TaskPatchField.set) ?? .clear))
            }
        )
    }

    private func setStatus(_ status: TaskStatus) {
        guard status != draft.status else { return }
        draft.status = status
        saveImmediately(TaskPatch(status: status))
    }

    private func saveImmediately(_ patch: TaskPatch) {
        state.enqueueImmediateTaskUpdate(taskID: task.id, patch: patch)
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "添加任务附件"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = false

        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map { $0.path(percentEncoded: false) }
        guard !paths.isEmpty else { return }
        state.enqueueTaskAttachmentAdd(taskID: task.id, sourcePaths: paths)
    }

    private func open(_ attachment: TaskAttachment) {
        guard let url = attachment.managedURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func reveal(_ attachment: TaskAttachment) {
        guard let url = attachment.managedURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func remove(_ attachment: TaskAttachment) {
        state.enqueueTaskAttachmentRemoval(
            taskID: task.id,
            attachmentID: attachment.id
        )
    }
}

private struct OptionalLocalDayRow: View {
    let title: String
    let systemImage: String
    @Binding var day: LocalDay?
    let today: LocalDay
    let tint: Color
    let accessibilityIdentifier: String

    @State private var datePickerPresented = false

    private static var calendar: Calendar { .todoAgentLocal }

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
                .frame(width: 100, alignment: .leading)

            Spacer(minLength: 8)

            if let day {
                Button {
                    datePickerPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Text(dateLabel(day))
                            .monospacedDigit()
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TodoAgentUI.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(TodoAgentUI.selectionBackground.opacity(0.6), in: .capsule)
                    .overlay {
                        Capsule().stroke(TodoAgentUI.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("选择\(title)")
                .popover(isPresented: $datePickerPresented) {
                    TodoAgentDatePickerPanel(
                        title: "选择\(title)",
                        initialDay: day,
                        today: today,
                        onCancel: { datePickerPresented = false },
                        onApply: { selectedDay in
                            self.day = selectedDay
                            datePickerPresented = false
                        }
                    )
                }
            }

            Toggle(title, isOn: isEnabledBinding)
                .labelsHidden()
                .toggleStyle(TodoAgentCompactSwitchStyle())
                .accessibilityLabel("启用\(title)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var isEnabledBinding: Binding<Bool> {
        Binding(
            get: { day != nil },
            set: { enabled in
                guard enabled != (day != nil) else { return }
                day = enabled ? today : nil
            }
        )
    }

    private func dateLabel(_ day: LocalDay) -> String {
        day.date(in: Self.calendar)?.formatted(.dateTime.month().day().weekday(.abbreviated))
            ?? day.rawValue
    }
}

private struct TaskAttachmentRow: View {
    let attachment: TaskAttachment
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            attachmentIcon
                .frame(width: 28, height: 28)

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.originalName)
                        .font(.callout)
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: attachment.sizeBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(attachment.managedURL() == nil)
            .accessibilityLabel("打开附件 \(attachment.originalName)")

            Menu {
                Button("打开", systemImage: "arrow.up.forward.app", action: onOpen)
                Button("在 Finder 中显示", systemImage: "folder", action: onReveal)
                Divider()
                Button("移除附件", systemImage: "trash", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("附件操作")
        }
        .padding(8)
        .background(TodoAgentUI.selectionBackground.opacity(0.7), in: .rect(cornerRadius: 8))
        .accessibilityIdentifier("task.details.attachment.\(attachment.id.uuidString)")
    }

    @ViewBuilder
    private var attachmentIcon: some View {
        if let url = attachment.managedURL() {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "doc")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TaskConversationPanel: View {
    let task: TaskItem
    let session: TaskConversationSnapshot
    let state: AppState
    let isClosing: Bool
    let onClose: () -> Void

    @State private var draft = ""
    @State private var isSubmitting = false
    @State private var toolResultDisclosure = TaskToolResultDisclosureState()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sessionMetadata
            Divider()
            transcript
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack(spacing: TodoAgentUI.standardSpacing) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.title2)
                    .bold()
                    .lineLimit(1)
                Text("\(session.runtime.title) 本地会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(sessionStateTitle)
                .font(.caption.bold())
                .foregroundStyle(session.state.isBusy ? Color.blue : Color.secondary)

            if session.state.isBusy {
                Button("停止本轮", role: .destructive) {
                    Task { await state.cancelTurn(for: task) }
                }
            }

            closeButton
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            if isClosing {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "xmark")
            }
        }
        .buttonStyle(.borderless)
        .disabled(isClosing)
        .help("保存并关闭")
        .accessibilityLabel("保存并关闭")
        .accessibilityIdentifier("task.session.close")
    }

    private var sessionMetadata: some View {
        HStack(spacing: 20) {
            Label(session.runtime.title, systemImage: "cpu")
            Label(session.workspace, systemImage: "folder")
            Label(session.sessionID, systemImage: "number")
                .fontDesign(.monospaced)
            Spacer()
            Label("本机直连", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.runtime.title) 本地会话，工作目录 \(session.workspace)，Session \(session.sessionID)"
        )
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: TodoAgentUI.sectionSpacing) {
                    ForEach(session.entries) { entry in
                        TaskConversationEntryRow(
                            entry: entry,
                            isToolResultExpanded: toolResultDisclosure.isExpanded(
                                entryID: entry.id
                            ),
                            onToggleToolResult: {
                                toolResultDisclosure.toggle(entryID: entry.id)
                            }
                        )
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.24))
            .onChange(of: session.entries.count) {
                guard let lastID = session.entries.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            Label(
                session.state.isBusy ? "Agent 正在处理本轮消息" : "随时向这个本地 Session 继续发送消息",
                systemImage: session.state.isBusy ? "hourglass" : "arrow.triangle.2.circlepath"
            )
            .font(.callout)
            .foregroundStyle(session.state.isBusy ? Color.blue : Color.secondary)

            HStack(alignment: .bottom, spacing: TodoAgentUI.standardSpacing) {
                TextField("发送消息给 \(session.runtime.title)…", text: $draft, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .accessibilityIdentifier("task.session.composer")

                Button("发送", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting || session.state.isBusy
                    )
                    .accessibilityIdentifier("task.session.send")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .task { await state.markReadIfCurrent(task) }
        .onChange(of: session.latestSequence) {
            Task { await state.markReadIfCurrent(task) }
        }
    }

    private var sessionStateTitle: String {
        switch session.state {
        case .running: "运行中"
        case .queued: "排队中"
        case .failed: "失败"
        default: "可继续"
        }
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSubmitting else { return }
        isSubmitting = true

        Task {
            if await state.sendToSession(task, text: value) {
                draft = ""
            }
            isSubmitting = false
        }
    }
}

private struct TaskSessionLoadingView: View {
    let task: TaskItem
    let isClosing: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.title2.bold())
                    Text("正在载入本地 Agent Session")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    if isClosing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "xmark")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isClosing)
                .accessibilityLabel("保存并关闭")
                .accessibilityIdentifier("task.session.close")
            }
            .padding(.horizontal, 24)
            .frame(height: 64)

            Divider()

            ProgressView("正在恢复完整聊天记录…")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TaskSessionSetupView: View {
    let task: TaskItem
    let state: AppState
    let isClosing: Bool
    @Binding var isStarting: Bool
    let flushTaskEdits: () async -> Bool
    let onClose: () -> Void

    @State private var runtime = RuntimeKind.codex
    @State private var workspace = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("启动本地 Agent")
                        .font(.title2.bold())
                    Text("选择 Runtime 与执行目录")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    if isClosing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "xmark")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(isClosing || isStarting)
                .help("保存并关闭")
                .accessibilityLabel("保存并关闭")
                .accessibilityIdentifier("task.session.close")
            }
            .padding(.horizontal, 24)
            .frame(height: 64)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("选择由哪个本地 Agent 执行，以及它可以操作的目录。启动后会直接进入完整聊天记录。", systemImage: "terminal")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
                        GridRow {
                            Text("Runtime")
                                .foregroundStyle(.secondary)
                            Picker("Runtime", selection: $runtime) {
                                ForEach(RuntimeKind.allCases) { kind in
                                    let info = state.runtime(kind)
                                    Text(runtimeTitle(kind, info: info))
                                        .tag(kind)
                                        .disabled(info?.isSelectable != true)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 260)
                            .accessibilityIdentifier("task.session.runtime")
                        }

                        GridRow(alignment: .top) {
                            Text("执行目录")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("选择一个文件夹", text: $workspace)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(true)
                                        .accessibilityIdentifier("task.session.workspace")
                                    Button("选择…", action: chooseDirectory)
                                        .accessibilityIdentifier("task.session.choose-workspace")
                                }
                                Text("Agent 将以这个目录作为工作目录，并在其中读取或修改文件。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let error = state.taskSessionErrorMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                                .accessibilityHidden(true)
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .textSelection(.enabled)
                            Spacer()
                            Button("关闭", systemImage: "xmark") {
                                state.clearTaskSessionError()
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                        .padding(12)
                        .background(.red.opacity(0.07), in: .rect(cornerRadius: 9))
                        .accessibilityIdentifier("task.session.error")
                    }
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .topLeading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    setupFooter
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(.bar)
                }
            }
        }
        .onAppear {
            if state.runtime(runtime)?.isSelectable != true,
               let firstReady = RuntimeKind.allCases.first(where: { state.runtime($0)?.isSelectable == true }) {
                runtime = firstReady
            }
        }
        .onChange(of: runtime) { _, _ in state.clearTaskSessionError() }
    }

    private var setupFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                setupSaveLabel
                Spacer()
                startButton
            }

            VStack(alignment: .trailing, spacing: 10) {
                setupSaveLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                startButton
            }
        }
    }

    private var setupSaveLabel: some View {
        Label("启动前会先保存任务详情。", systemImage: "checkmark.arrow.trianglehead.counterclockwise")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var startButton: some View {
        Button(action: start) {
            if isStarting {
                Label("正在启动…", systemImage: "hourglass")
            } else {
                Text("启动并进入 Session")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || state.runtime(runtime)?.isSelectable != true
                || isStarting || isClosing
        )
        .accessibilityIdentifier("task.session.start")
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "选择 Agent 执行目录"
        if panel.runModal() == .OK, let url = panel.url {
            try? WorkspaceAuthorizationStore.save(url)
            workspace = url.path(percentEncoded: false)
        }
    }

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            guard await flushTaskEdits() else {
                isStarting = false
                return
            }
            let started = await state.startSession(task, runtime: runtime, workspace: workspace)
            isStarting = false
            if started {
                workspace = ""
            }
        }
    }

    private func runtimeTitle(_ kind: RuntimeKind, info: RuntimeInfo?) -> String {
        guard let info else { return "\(kind.title)（检测中）" }
        switch info.status {
        case .ready: return "\(kind.title) · \(info.version ?? "已验证")"
        case .authRequired: return "\(kind.title)（需要登录）"
        case .missing: return "\(kind.title)（未安装）"
        case .detected: return "\(kind.title)（待验证）"
        case .error: return "\(kind.title)（不可用）"
        }
    }
}

struct TaskConversationEntryRow: View {
    let entry: TaskConversationEntry
    let isToolResultExpanded: Bool
    let onToggleToolResult: () -> Void

    init(
        entry: TaskConversationEntry,
        isToolResultExpanded: Bool = false,
        onToggleToolResult: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.isToolResultExpanded = isToolResultExpanded
        self.onToggleToolResult = onToggleToolResult
    }

    @ViewBuilder
    var body: some View {
        if entry.isToolResult {
            TaskToolResultRow(
                entry: entry,
                isExpanded: isToolResultExpanded,
                onToggle: onToggleToolResult
            )
        } else {
            switch entry.role {
            case .system:
                systemEntry
            case .tool:
                toolEntry
            case .agent, .user:
                messageEntry
            }
        }
    }

    private var systemEntry: some View {
        Label(entry.body, systemImage: "link")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("系统：\(entry.body)")
    }

    private var toolEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.title ?? "工具调用", systemImage: "terminal")
                .font(.callout)
                .bold()
                .foregroundStyle(.secondary)
            Text(entry.body)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TodoAgentUI.cardPadding)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工具调用，\(entry.title ?? "")：\(entry.body)")
    }

    private var messageEntry: some View {
        HStack(alignment: .top) {
            if entry.role == .user { Spacer(minLength: 120) }

            VStack(alignment: .leading, spacing: TodoAgentUI.compactSpacing) {
                if let title = entry.title {
                    Text(title)
                        .font(.callout)
                        .bold()
                }
                Text(entry.body)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .foregroundStyle(entry.role == .user ? Color.white : Color.primary)
            .background(
                entry.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: TodoAgentUI.panelRadius)
            )

            if entry.role == .agent { Spacer(minLength: 120) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.role == .user ? "你" : "CLI")：\(entry.body)")
    }
}

struct TaskToolResultRow: View {
    let entry: TaskConversationEntry
    let isExpanded: Bool
    let onToggle: () -> Void

    private var presentation: TaskToolResultPresentation {
        entry.toolResultPresentation ?? TaskToolResultPresentation(entry: entry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(
                        systemName: presentation.isFailure
                            ? "xmark.octagon.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.title3)
                    .foregroundStyle(presentation.isFailure ? Color.red : Color.green)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font(.callout.bold())
                            .foregroundStyle(presentation.isFailure ? Color.red : Color.primary)
                            .lineLimit(1)
                        Text(presentation.subtitle(isExpanded: isExpanded))
                            .font(.caption)
                            .foregroundStyle(presentation.isFailure ? Color.red : Color.secondary)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .padding(TodoAgentUI.cardPadding)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(presentation.title)，\(presentation.statusTitle)，\(presentation.contentSizeTitle)"
            )
            .accessibilityValue(presentation.accessibilityValue(isExpanded: isExpanded))
            .accessibilityHint(isExpanded ? "点击收起完整结果" : "点击展开完整结果")
            .accessibilityIdentifier("task.session.tool-result.\(entry.id).toggle")

            if isExpanded {
                Divider()
                    .padding(.horizontal, TodoAgentUI.cardPadding)

                Text(entry.body.isEmpty ? "（无输出）" : entry.body)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(TodoAgentUI.cardPadding)
                    .accessibilityLabel("完整工具结果：\(entry.body)")
                    .accessibilityIdentifier("task.session.tool-result.\(entry.id).body")
            }
        }
        .background(
            presentation.isFailure
                ? Color.red.opacity(0.07)
                : Color(nsColor: .controlBackgroundColor),
            in: .rect(cornerRadius: TodoAgentUI.cardRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(
                    presentation.isFailure
                        ? Color.red.opacity(0.45)
                        : Color(nsColor: .separatorColor).opacity(0.4)
                )
        }
        .accessibilityIdentifier("task.session.tool-result.\(entry.id)")
    }
}
