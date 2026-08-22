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

enum TaskDetailsPresentation: Equatable, Sendable {
    case workbench
    case popover

    var showsHeader: Bool { self == .workbench }
}

enum TaskDetailPopoverLayoutPolicy {
    static let width: CGFloat = 360
    static let height: CGFloat = 560
}

enum TaskNoteEditorSynchronizationPolicy {
    static let maximumLength = 4_000
    static let editorHeight: CGFloat = 150

    static func committedText(_ value: String) -> String {
        String(value.prefix(maximumLength))
    }

    static func shouldApplyExternalText(
        nativeText: String,
        draftText: String,
        isFirstResponder: Bool,
        hasMarkedText: Bool
    ) -> Bool {
        nativeText != draftText && !isFirstResponder && !hasMarkedText
    }
}

@MainActor
enum TaskDetailTextInputCommitter {
    static func commitEditing(in window: NSWindow?) {
        guard let window else { return }
        if let textInput = window.firstResponder as? NSTextInputClient,
           textInput.hasMarkedText()
        {
            // AppKit does not necessarily commit an active IME marked range
            // when a transient popover resigns first responder. Unmark it
            // explicitly while the editor and its binding are still alive so
            // the final preedit text reaches the task draft before flushing.
            textInput.unmarkText()
            // `unmarkText()` changes the input client's marked range but does
            // not reliably emit NSTextDidChange. Notify the existing editor
            // delegate while the SwiftUI binding is still mounted.
            if let textView = textInput as? NSTextView {
                textView.delegate?.textDidChange?(
                    Notification(name: NSText.didChangeNotification, object: textView)
                )
            }
        }
        window.endEditing(for: nil)
        window.makeFirstResponder(nil)
    }

    static func commitActiveWindowEditing() {
        guard let application = NSApp else { return }
        let identifiedMainWindow = application.windows.first(where: {
            $0.identifier?.rawValue == TodoAgentMainWindow.identifier
        })
        let windows = [
            application.keyWindow,
            application.mainWindow,
            identifiedMainWindow,
        ].compactMap { $0 }
        var visitedWindowNumbers = Set<Int>()
        for window in windows where visitedWindowNumbers.insert(window.windowNumber).inserted {
            commitEditing(in: window)
        }
    }
}

@MainActor
final class WeakTaskDetailWindow {
    weak var value: NSWindow?
}

@MainActor
private struct TaskDetailWindowReader: NSViewRepresentable {
    let clearsInitialFocus: Bool
    let onWindowCapture: (NSWindow?) -> Void
    let onWindowReady: (NSWindow?) -> Void

    func makeNSView(context _: Context) -> ReaderView {
        ReaderView(
            clearsInitialFocus: clearsInitialFocus,
            onWindowCapture: onWindowCapture,
            onWindowReady: onWindowReady
        )
    }

    func updateNSView(_ nsView: ReaderView, context _: Context) {
        nsView.clearsInitialFocus = clearsInitialFocus
        nsView.onWindowCapture = onWindowCapture
        nsView.onWindowReady = onWindowReady
    }

    final class ReaderView: NSView {
        var clearsInitialFocus: Bool
        var onWindowCapture: (NSWindow?) -> Void
        var onWindowReady: (NSWindow?) -> Void
        private weak var preparedWindow: NSWindow?

        init(
            clearsInitialFocus: Bool,
            onWindowCapture: @escaping (NSWindow?) -> Void,
            onWindowReady: @escaping (NSWindow?) -> Void
        ) {
            self.clearsInitialFocus = clearsInitialFocus
            self.onWindowCapture = onWindowCapture
            self.onWindowReady = onWindowReady
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let resolvedWindow = window
            if let resolvedWindow {
                // Register a live window synchronously. A popover can be
                // dismissed in the same run-loop turn in which it appears;
                // onDisappear still needs the exact window to commit IME text.
                onWindowCapture(resolvedWindow)
            }
            let shouldPrepareInitialFocus = clearsInitialFocus
                && resolvedWindow != nil
                && preparedWindow !== resolvedWindow
            if shouldPrepareInitialFocus, let resolvedWindow {
                preparedWindow = resolvedWindow
                if !resolvedWindow.isKeyWindow {
                    resolvedWindow.makeKey()
                }
                if !(resolvedWindow.firstResponder is TaskNoteTextView) {
                    resolvedWindow.initialFirstResponder = nil
                    resolvedWindow.makeFirstResponder(nil)
                }
            }
            Task { @MainActor [weak self, weak resolvedWindow] in
                await Task.yield()
                guard let self, self.window === resolvedWindow else { return }
                if resolvedWindow == nil {
                    // Delay nil so the containing view's onDisappear can still
                    // commit against the last live popover window.
                    self.onWindowCapture(nil)
                } else if shouldPrepareInitialFocus {
                    self.onWindowReady(resolvedWindow)
                }
            }
        }
    }
}

/// A stable AppKit-backed editor for task notes.
///
/// SwiftUI's `TextEditor` can reconfigure its private `NSTextView` when the
/// surrounding transient popover refreshes. During Chinese IME composition
/// that resets the marked range and candidate-window geometry. Keep one native
/// text view alive, never replace its contents while it is first responder, and
/// only publish committed (non-marked) text back into the SwiftUI draft.
@MainActor
struct TaskNoteEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = TaskNoteTextView(frame: scrollView.contentView.bounds)
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("task.details.note-input")
        textView.string = text
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(text: $text, isFocused: $isFocused)
        guard let textView = scrollView.documentView as? TaskNoteTextView else { return }
        let isFirstResponder = scrollView.window?.firstResponder === textView
        guard TaskNoteEditorSynchronizationPolicy.shouldApplyExternalText(
            nativeText: textView.string,
            draftText: text,
            isFirstResponder: isFirstResponder,
            hasMarkedText: textView.hasMarkedText()
        ) else { return }
        context.coordinator.applyExternalText(text, to: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        fileprivate weak var textView: NSTextView?

        private var text: Binding<String>
        private var isFocused: Binding<Bool>
        private var isApplyingText = false

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func update(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidBeginEditing(_: Notification) {
            if isFocused.wrappedValue == false {
                isFocused.wrappedValue = true
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingText,
                  let textView = notification.object as? NSTextView,
                  textView.hasMarkedText() == false
            else { return }
            publishCommittedText(from: textView)
        }

        func textDidEndEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                publishCommittedText(from: textView)
            }
            if isFocused.wrappedValue {
                isFocused.wrappedValue = false
            }
        }

        fileprivate func applyExternalText(_ value: String, to textView: NSTextView) {
            guard textView.string != value else { return }
            isApplyingText = true
            let location = min(
                textView.selectedRange().location,
                (value as NSString).length
            )
            textView.string = value
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isApplyingText = false
        }

        private func publishCommittedText(from textView: NSTextView) {
            guard textView.hasMarkedText() == false else { return }
            let committed = TaskNoteEditorSynchronizationPolicy.committedText(textView.string)
            if committed != textView.string {
                applyExternalText(committed, to: textView)
            }
            if text.wrappedValue != committed {
                text.wrappedValue = committed
            }
        }
    }
}

final class TaskNoteTextView: NSTextView {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
}

struct TaskDetailsEditor: View {
    let task: TaskItem
    let state: AppState
    let presentation: TaskDetailsPresentation

    @State private var draft: TaskDetailDraft
    @State private var presentationWindow = WeakTaskDetailWindow()
    @FocusState private var focusedTextField: TaskDetailTextField?

    init(
        task: TaskItem,
        state: AppState,
        presentation: TaskDetailsPresentation = .workbench
    ) {
        self.task = task
        self.state = state
        self.presentation = presentation
        _draft = State(initialValue: TaskDetailDraft(task: task))
    }

    var body: some View {
        TaskDetailsPane(
            task: task,
            draft: $draft,
            focusedTextField: $focusedTextField,
            state: state,
            presentation: presentation
        )
        .onChange(of: task) { _, authoritativeTask in
            reconcileDraft(with: authoritativeTask)
        }
        .onChange(of: state.taskSaveState(taskID: task.id)) { _, _ in
            guard let authoritativeTask = state.task(id: task.id) else { return }
            reconcileDraft(with: authoritativeTask)
        }
        .onChange(of: focusedTextField) { _, field in
            Task { @MainActor in
                await Task.yield()
                guard focusedTextField == field else { return }
                if field == nil { _ = await state.flushTaskEdits(taskID: task.id) }
                guard let authoritativeTask = state.task(id: task.id) else { return }
                reconcileDraft(with: authoritativeTask)
            }
        }
        .background {
            TaskDetailWindowReader(
                clearsInitialFocus: presentation == .popover,
                onWindowCapture: { window in
                    presentationWindow.value = window
                },
                onWindowReady: { window in
                    if presentation == .popover,
                       let window,
                       !(window.firstResponder is TaskNoteTextView)
                    {
                        // AppKit can install the first TextField's field editor only
                        // after the popover becomes key. Clear that automatic title
                        // selection, but never steal focus from a user's first click
                        // into the native note editor.
                        window.makeFirstResponder(nil)
                    }
                }
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onDisappear {
            TaskDetailTextInputCommitter.commitEditing(in: presentationWindow.value)
            focusedTextField = nil
            Task { @MainActor in
                // Let AppKit commit the final marked-text/selection change before
                // the transient popover flushes its debounced edit.
                await Task.yield()
                _ = await state.flushTaskEdits(taskID: task.id)
            }
        }
    }

    private func reconcileDraft(with authoritativeTask: TaskItem) {
        let reconciled = draft.reconciled(
            with: authoritativeTask,
            saveState: state.taskSaveState(taskID: task.id),
            preserving: focusedTextField
        )
        guard reconciled != draft else { return }
        draft = reconciled
    }
}

struct TaskDetailsPopover: View {
    let task: TaskItem
    let state: AppState

    var body: some View {
        TaskDetailsEditor(task: task, state: state, presentation: .popover)
            .frame(
                width: TaskDetailPopoverLayoutPolicy.width,
                height: TaskDetailPopoverLayoutPolicy.height
            )
            .accessibilityIdentifier("task.details.popover.\(task.id.uuidString)")
    }
}

struct TaskDetailsPane: View {
    let task: TaskItem
    @Binding var draft: TaskDetailDraft
    var focusedTextField: FocusState<TaskDetailTextField?>.Binding
    let state: AppState
    let presentation: TaskDetailsPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if presentation.showsHeader {
                detailsHeader
                Divider()
            }

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
                TaskMyDayRow(
                    executionDate: draft.executionDate,
                    today: state.currentDay,
                    isInMyDay: myDayBinding
                )
                .padding(10)

                Divider().padding(.leading, 38)

                OptionalLocalDayRow(
                    title: "截止日期",
                    systemImage: "calendar",
                    day: dueDateBinding,
                    today: state.currentDay,
                    tint: isDueDateOverdue(draft.dueDate) ? .red : .primary,
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

    private func isDueDateOverdue(_ day: LocalDay?) -> Bool {
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
                        .accessibilityIdentifier("task.details.note-counter")
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
                TaskNoteEditor(
                    text: noteBinding,
                    isFocused: noteFocusBinding
                )
                    .padding(8)
                    .accessibilityLabel("任务备注")
                    .accessibilityHint("最多 4000 字，自动保存")
                    .accessibilityIdentifier("task.details.note")
            }
            .frame(height: TaskNoteEditorSynchronizationPolicy.editorHeight)
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
                let limited = TaskNoteEditorSynchronizationPolicy.committedText(value)
                guard limited != draft.note else { return }
                draft.note = limited
                state.scheduleTaskUpdate(
                    taskID: task.id,
                    patch: TaskPatch(note: limited)
                )
            }
        )
    }

    private var noteFocusBinding: Binding<Bool> {
        Binding(
            get: { focusedTextField.wrappedValue == .note },
            set: { isFocused in
                if isFocused {
                    focusedTextField.wrappedValue = .note
                } else if focusedTextField.wrappedValue == .note {
                    focusedTextField.wrappedValue = nil
                }
            }
        )
    }

    private var myDayBinding: Binding<Bool> {
        Binding(
            get: { draft.executionDate == state.currentDay },
            set: { isInMyDay in
                guard !state.isPreparingToTerminate else { return }
                let executionDate = isInMyDay ? state.currentDay : nil
                guard executionDate != draft.executionDate else { return }
                draft.executionDate = executionDate
                state.setTask(task, inMyDay: isInMyDay)
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

private struct TaskMyDayRow: View {
    let executionDate: LocalDay?
    let today: LocalDay
    @Binding var isInMyDay: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isInMyDay ? "sun.max.fill" : "sun.max")
                .foregroundStyle(isInMyDay ? Color.accentColor : Color.primary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("今天")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Toggle(isOn: $isInMyDay) { EmptyView() }
                .toggleStyle(TodoAgentCompactSwitchStyle())
                .accessibilityLabel("加入今天")
                .accessibilityValue(isInMyDay ? "已加入" : "未加入")
        }
        .accessibilityIdentifier("task.details.my-day")
    }

    private var detail: String {
        if isInMyDay { return "今天要处理" }
        if let executionDate {
            return "保留原执行日期 \(executionDate.month)月\(executionDate.day)日；加入后改为今天"
        }
        return "需要今天处理时加入"
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
