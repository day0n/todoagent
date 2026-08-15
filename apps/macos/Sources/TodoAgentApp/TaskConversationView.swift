import AppKit
import SwiftUI

enum TaskDetailTextField: Hashable {
    case title
    case note
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

    func reconciled(
        with task: TaskItem,
        saveState: TaskSaveState,
        preserving focusedField: TaskDetailTextField? = nil
    ) -> TaskDetailDraft {
        // Do not write to the compound @State value while either native text
        // control owns focus. Even changing another field can reconfigure the
        // underlying NSTextView and discard its marked text or selection.
        guard saveState == .idle, focusedField == nil else { return self }
        return TaskDetailDraft(task: task)
    }
}

struct TaskDetailsPane: View {
    let task: TaskItem
    @Binding var draft: TaskDetailDraft
    var focusedTextField: FocusState<TaskDetailTextField?>.Binding
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailsHeader
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    titleAndCompletion
                    dateSection
                    attachmentSection
                    noteSection
                    saveFeedback
                }
                .padding(16)
            }
        }
        .background(TodoAgentUI.surfaceBackground)
        .disabled(state.isPreparingToTerminate)
        .accessibilityIdentifier("task.details.\(task.id.uuidString)")
    }

    private var detailsHeader: some View {
        HStack {
            Text("任务详情")
                .font(.headline)
            Spacer()
            saveStateLabel
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    @ViewBuilder
    private var saveStateLabel: some View {
        let saveState = state.taskSaveState(taskID: task.id)

        if focusedTextField.wrappedValue != nil {
            switch saveState {
            case .failed:
                Label("保存失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            case .idle, .debouncing, .saving:
                Label("自动保存", systemImage: "pencil")
                    .foregroundStyle(.secondary)
            }
        } else {
            switch saveState {
            case .idle:
                Label("已保存", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            case .debouncing:
                Label("待保存", systemImage: "clock")
                    .foregroundStyle(.secondary)
            case .saving:
                Label("保存中", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .failed:
                Label("保存失败", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
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
                .font(.title3.weight(.semibold))
                .textFieldStyle(.plain)
                .lineLimit(1 ... 2)
                .strikethrough(draft.status == .completed)
                .focused(focusedTextField, equals: .title)
                .accessibilityIdentifier("task.details.title")
        }
    }

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("时间")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                OptionalLocalDayRow(
                    title: "执行日期",
                    systemImage: "sun.max",
                    day: executionDateBinding,
                    today: state.currentDay,
                    tint: isDraftDateOverdue(draft.executionDate) ? .red : .primary,
                    accessibilityIdentifier: "task.details.execution-date"
                )
                .padding(10)

                Divider().padding(.leading, 38)

                OptionalLocalDayRow(
                    title: "截止日期",
                    systemImage: "calendar",
                    day: dueDateBinding,
                    today: state.currentDay,
                    tint: isDraftDateOverdue(draft.dueDate) ? .red : .primary,
                    accessibilityIdentifier: "task.details.due-date"
                )
                .padding(10)
            }
            .background(TodoAgentUI.selectionBackground.opacity(0.48), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
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
                if !task.attachments.isEmpty {
                    Text("\(task.attachments.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(TodoAgentUI.selectionBackground, in: .capsule)
                }
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
                if focusedTextField.wrappedValue == .note || !draft.note.isEmpty {
                    Text("\(draft.note.count)/4000")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            ZStack(alignment: .topLeading) {
                if draft.note.isEmpty {
                    Text("添加备注…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: noteBinding)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused(focusedTextField, equals: .note)
                    .accessibilityLabel("任务备注")
                    .accessibilityIdentifier("task.details.note")
            }
            .frame(minHeight: 120, idealHeight: 150, maxHeight: 220)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
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
                guard !state.isPreparingToTerminate else { return }
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
                guard !state.isPreparingToTerminate else { return }
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
                guard !state.isPreparingToTerminate else { return }
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
                guard !state.isPreparingToTerminate else { return }
                guard value != draft.dueDate else { return }
                draft.dueDate = value
                saveImmediately(TaskPatch(dueDate: value.map(TaskPatchField.set) ?? .clear))
            }
        )
    }

    private func setStatus(_ status: TaskStatus) {
        guard !state.isPreparingToTerminate else { return }
        guard status != draft.status else { return }
        draft.status = status
        saveImmediately(TaskPatch(status: status))
    }

    private func saveImmediately(_ patch: TaskPatch) {
        state.enqueueImmediateTaskUpdate(taskID: task.id, patch: patch)
    }

    private func chooseAttachments() {
        guard !state.isPreparingToTerminate else { return }
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
        guard !state.isPreparingToTerminate else { return }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Toggle(isOn: isEnabledBinding) { EmptyView() }
                    .toggleStyle(TodoAgentCompactSwitchStyle())
                    .accessibilityLabel("启用\(title)")
                    .accessibilityValue(day == nil ? "已关闭" : "已开启")
            }

            if let day {
                Button {
                    datePickerPresented = true
                } label: {
                    HStack(spacing: 6) {
                        Text(dateLabel(day))
                            .monospacedDigit()
                        Spacer(minLength: 6)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TodoAgentUI.secondaryText)
                            .accessibilityHidden(true)
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .background(TodoAgentUI.surfaceBackground.opacity(0.72), in: .rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(TodoAgentUI.hairline, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .help("选择\(title)")
                .accessibilityLabel("\(title)，\(dateLabel(day))")
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
            } else {
                Text("未设置；开启后默认为今天")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 28)
            }
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
