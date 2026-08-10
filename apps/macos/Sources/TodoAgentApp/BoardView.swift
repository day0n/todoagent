import AppKit
import SwiftUI

extension Notification.Name {
    /// Internal UI event emitted after the New Task command resolves the active
    /// board context. Only the composer currently on screen responds.
    static let todoAgentFocusTaskComposer = Notification.Name("TodoAgent.focusTaskComposer")
}

struct BoardView: View {
    let state: AppState

    var body: some View {
        Group {
            if isTimeline {
                TimelineColumns(state: state)
            } else {
                TaskListView(state: state)
            }
        }
        .navigationTitle(state.titleForSelection())
        .background(TodoAgentUI.canvasBackground)
        .toolbar { timelineToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewTask)) { _ in
            focusComposerForCurrentContext()
        }
    }

    private var isTimeline: Bool { state.selection == .smart(.timeline) }

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        if isTimeline {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    shiftDate(-1)
                } label: {
                    Label("前一天", systemImage: "chevron.left")
                }
                .labelStyle(.iconOnly)
                .help("前一天")
                .accessibilityIdentifier("timeline.previousDay")

                Text(selectedDayTitle)
                    .font(.headline)
                    .accessibilityIdentifier("timeline.selectedDate")

                Button {
                    shiftDate(1)
                } label: {
                    Label("后一天", systemImage: "chevron.right")
                }
                .labelStyle(.iconOnly)
                .help("后一天")
                .accessibilityIdentifier("timeline.nextDay")

                Button("今天") {
                    state.selectToday()
                }
                .disabled(state.selectedDay == state.currentDay)
                .help("回到今天")
                .accessibilityIdentifier("timeline.today")
            }

        }
    }

    private func shiftDate(_ days: Int) {
        state.shiftSelectedDay(by: days)
    }

    private var selectedDayTitle: String {
        guard let date = state.selectedDay.date(in: .todoAgentLocal) else {
            return state.selectedDay.rawValue
        }
        return date.formatted(.dateTime.month().day().weekday(.wide))
    }

    private func focusComposerForCurrentContext() {
        switch state.selection {
        case .smart(.running), .smart(.done), nil:
            state.selection = .smart(.tasks)
        case .smart(.timeline), .smart(.tasks), .list:
            break
        }

        // Navigation may replace the board subtree. Deliver focus on the next
        // main-run-loop turn so the destination composer has mounted.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .todoAgentFocusTaskComposer, object: nil)
        }
    }
}

private struct TimelineColumns: View {
    let state: AppState

    var body: some View {
        let days = state.timelineDays()

        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TodoAgentUI.boardSpacing) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { offset, timelineDay in
                        TimelineColumn(
                            offset: offset,
                            timelineDay: timelineDay,
                            selectedDateIsToday: state.selectedDay == state.currentDay,
                            state: state
                        )
                        .frame(width: columnWidth(for: proxy.size.width))
                    }
                }
                .padding(TodoAgentUI.boardPadding)
            }
            .scrollIndicators(.visible, axes: .horizontal)
        }
        .background(TodoAgentUI.canvasBackground)
    }

    private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
        TimelineColumnLayoutPolicy.columnWidth(availableWidth: availableWidth)
    }
}

enum TimelineColumnLayoutPolicy {
    static let dayCount: CGFloat = 4

    /// Four calendar days always share one continuous sizing rule. Once the
    /// minimum width is reached, the horizontal viewport simply reveals fewer
    /// days; there is no breakpoint where every card suddenly changes size.
    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        let spacing = TodoAgentUI.boardSpacing * (dayCount - 1)
        let padding = TodoAgentUI.boardPadding * 2
        let proposed = (availableWidth - spacing - padding) / dayCount
        return min(
            max(proposed, TodoAgentUI.columnMinimumWidth),
            TodoAgentUI.columnMaximumWidth
        )
    }
}

private struct TimelineColumn: View {
    let offset: Int
    let timelineDay: TimelineDay
    let selectedDateIsToday: Bool
    let state: AppState

    var body: some View {
        let sections = TaskStatusSections(tasks: timelineDay.tasks)

        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dayTitle)
                        .font(.title3)
                        .bold()
                    Text(daySubtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if offset == 0 {
                    Text(selectedDateIsToday ? "今天" : "所选")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: .capsule)
                }
            }

            if timelineDay.tasks.isEmpty {
                Spacer().frame(height: 4)
            } else {
                ProgressView(value: timelineDay.progress)
                    .tint(.green)
                    .accessibilityLabel("\(daySubtitle)任务进度")
                    .accessibilityValue("完成 \(timelineDay.completedCount) 项，共 \(timelineDay.totalCount) 项")
            }

            Group {
                if timelineDay.tasks.isEmpty {
                    TimelineEmptyState()
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
                            ForEach(sections.openTasks) { task in
                                TaskCard(task: task, state: state)
                            }

                            if sections.hasCompletedSection {
                                CompletedTasksSectionHeader(
                                    hasOpenTasks: sections.openTasks.isEmpty == false,
                                    accessibilityIdentifier: "timeline.\(timelineDay.day.description).completed-section"
                                )

                                ForEach(sections.completedTasks) { task in
                                    TaskCard(task: task, state: state)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.visible)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            TimelineInlineTaskComposer(
                state: state,
                executionDay: timelineDay.day,
                focusesForNewTaskCommand: offset == 0
            )
        }
        .padding(TodoAgentUI.sectionSpacing)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            offset == 0 ? TodoAgentUI.selectionBackground : TodoAgentUI.surfaceBackground,
            in: .rect(cornerRadius: TodoAgentUI.panelRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.panelRadius)
                .stroke(
                    offset == 0 ? TodoAgentUI.primaryText.opacity(0.14) : TodoAgentUI.hairline,
                    lineWidth: 1
                )
        }
        .shadow(
            color: offset == 0 ? TodoAgentUI.shadowColor.opacity(0.45) : .clear,
            radius: 10,
            y: 3
        )
        .accessibilityIdentifier("timeline.day-\(offset).column")
    }

    private var displayDate: Date? {
        timelineDay.day.date(in: .todoAgentLocal)
    }

    private var dayTitle: String {
        displayDate?.formatted(.dateTime.weekday(.wide)) ?? timelineDay.day.rawValue
    }

    private var daySubtitle: String {
        displayDate?.formatted(.dateTime.month().day()) ?? timelineDay.day.rawValue
    }
}

private struct TimelineEmptyState: View {
    var body: some View {
        VStack(spacing: TodoAgentUI.compactSpacing) {
            Image(systemName: "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("这一天还没有安排")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

private struct TimelineInlineTaskComposer: View {
    let state: AppState
    let executionDay: LocalDay
    let focusesForNewTaskCommand: Bool

    @State private var draft = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: TodoAgentUI.compactSpacing) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("添加任务", text: $draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)
                .onExitCommand(perform: cancelEditing)
                .accessibilityLabel("添加当天任务")
                .accessibilityHint("输入标题并按回车创建，按 Escape 清空")
                .accessibilityIdentifier("timeline.\(executionDay.description).add-task")

            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在添加任务")
            }
        }
        .font(.callout)
        .foregroundStyle(TodoAgentUI.primaryText)
        .padding(.horizontal, TodoAgentUI.compactSpacing)
        .frame(minHeight: 36)
        .background(TodoAgentUI.surfaceBackground.opacity(0.78), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isFocused ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1)
        }
        .onTapGesture { isFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentFocusTaskComposer)) { _ in
            if focusesForNewTaskCommand {
                isFocused = true
            }
        }
    }

    private func submit() {
        let submittedDraft = draft
        let title = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSubmitting else { return }

        isSubmitting = true
        Task { @MainActor in
            let succeeded = await state.createTask(
                title: title,
                listID: nil,
                executionDate: executionDay,
                dueDate: nil
            )
            isSubmitting = false
            if succeeded, draft == submittedDraft {
                draft = ""
            }
            isFocused = true
        }
    }

    private func cancelEditing() {
        draft = ""
        isFocused = false
    }
}

private struct TaskListView: View {
    let state: AppState

    var body: some View {
        let tasks = state.visibleTasks()
        let sections = TaskStatusSections(tasks: tasks)

        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: TodoAgentUI.standardSpacing) {
                    if tasks.isEmpty {
                        ContentUnavailableView(
                            "没有任务",
                            systemImage: "checklist",
                            description: Text(emptyDescription)
                        )
                        .frame(maxWidth: .infinity, minHeight: 240)
                    } else {
                        ForEach(sections.openTasks) { task in
                            TaskCard(task: task, state: state)
                        }

                        if sections.hasCompletedSection {
                            CompletedTasksSectionHeader(
                                hasOpenTasks: sections.openTasks.isEmpty == false,
                                accessibilityIdentifier: completedSectionIdentifier
                            )

                            ForEach(sections.completedTasks) { task in
                                TaskCard(task: task, state: state)
                            }
                        }
                    }
                }
                .frame(maxWidth: 780)
                .padding(20)
            }

            if let addTaskDestination {
                InlineAddTaskComposer(state: state, destination: addTaskDestination)
                    .id(addTaskDestination)
            }
        }
        .frame(maxWidth: .infinity)
        .background(TodoAgentUI.canvasBackground)
    }

    private var addTaskDestination: InlineAddTaskDestination? {
        switch state.selection {
        case .smart(.tasks):
            .allTasks
        case let .list(id):
            .list(id)
        default:
            nil
        }
    }

    private var completedSectionIdentifier: String {
        switch state.selection {
        case .smart(.timeline):
            "timeline.completed-section"
        case .smart(.tasks):
            "task-list.completed-section"
        case .smart(.running):
            "running.completed-section"
        case .smart(.done):
            "done.completed-section"
        case let .list(id):
            "task-list.\(id.uuidString).completed-section"
        case nil:
            "task-list.completed-section"
        }
    }

    private var emptyDescription: String {
        switch state.selection {
        case .smart(.running):
            "当前没有正在运行的本地 Session。"
        case .smart(.done):
            "完成任务后会显示在这里。"
        case .smart(.tasks), .list:
            "使用下方的“添加任务”创建第一项。"
        default:
            "当前列表为空。"
        }
    }
}

private struct CompletedTasksSectionHeader: View {
    let hasOpenTasks: Bool
    let accessibilityIdentifier: String

    var body: some View {
        HStack {
            Text("已完成")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Spacer(minLength: 0)
        }
        .padding(.top, hasOpenTasks ? TodoAgentUI.compactSpacing : 0)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private enum InlineAddTaskDestination: Hashable {
    case allTasks
    case list(UUID)

    var listID: UUID? {
        switch self {
        case .allTasks: nil
        case let .list(id): id
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .allTasks:
            "task-list.add-task"
        case let .list(id):
            "task-list.\(id.uuidString).add-task"
        }
    }
}

private struct InlineAddTaskComposer: View {
    let state: AppState
    let destination: InlineAddTaskDestination

    @State private var draft = ""
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)

            HStack(spacing: TodoAgentUI.standardSpacing) {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .accessibilityHidden(true)

                TextField("添加任务", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancelEditing)
                    .accessibilityLabel("添加任务")
                    .accessibilityHint("输入任务标题并按回车创建，按 Escape 清空")
                    .accessibilityIdentifier(destination.accessibilityIdentifier)

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在添加任务")
                }
            }
            .font(.callout)
            .foregroundStyle(TodoAgentUI.primaryText)
            .padding(.horizontal, TodoAgentUI.cardPadding)
            .frame(maxWidth: 780, minHeight: 44)
            .background(TodoAgentUI.surfaceBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                    .stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .background(TodoAgentUI.canvasBackground)
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentFocusTaskComposer)) { _ in
            isFocused = true
        }
    }

    private func submit() {
        let submittedDraft = draft
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isSubmitting else { return }

        isSubmitting = true
        Task { @MainActor in
            let succeeded = await state.createTask(
                title: title,
                listID: destination.listID,
                executionDate: nil,
                dueDate: nil
            )
            isSubmitting = false
            if succeeded, draft == submittedDraft {
                draft = ""
            }
        }
    }

    private func cancelEditing() {
        draft = ""
        isFocused = false
    }
}

struct TaskCard: View {
    let task: TaskItem
    let state: AppState

    @State private var datePickerRequest: TaskDatePickerRequest?
    @State private var isConfirmingDelete = false
    @State private var contextHighlight = TaskContextHighlightState()

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: TodoAgentUI.standardSpacing) {
                completionButton
                sessionButton
            }
            .padding(TodoAgentUI.cardPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(task.title)，\(state.session(for: task) == nil ? "尚未创建 Session" : "进入 Session")")

            if case let .failed(message) = state.taskSaveState(taskID: task.id) {
                Divider()
                taskSaveFailure(message)
            }
        }
        .background(taskCardBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(borderColor, lineWidth: state.hasUnreadAgentMessage(for: task) ? 1.5 : 1)
        }
        .shadow(
            color: TodoAgentUI.shadowColor.opacity(contextHighlight.isHighlighted ? 0.9 : 0.55),
            radius: contextHighlight.isHighlighted ? 9 : 5,
            y: contextHighlight.isHighlighted ? 4 : 2
        )
        .accessibilityIdentifier("task.\(task.id.uuidString).card")
        .contextMenu {
            taskContextMenu
        }
        .onHover { contextHighlight.pointerInside = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            contextHighlight.menuDidBeginTracking()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            contextHighlight.menuDidEndTracking()
        }
        .popover(item: $datePickerRequest) { request in
            TaskDatePickerPopover(request: request) { day in
                setDate(day, for: request.field)
            }
        }
        .alert("删除任务？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除任务", role: .destructive) {
                Task { _ = await state.deleteTask(taskID: task.id) }
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.deleteConfirmation)
        } message: {
            Text("“\(task.title)”将被永久删除，此操作无法撤销。")
        }
    }

    @ViewBuilder
    private var taskContextMenu: some View {
        let presentation = TaskContextMenuPresentation(task: task, lists: state.lists)

        Button {
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(
                    status: task.status == .open ? .completed : .open
                )
            )
        } label: {
            Label(presentation.completionTitle, systemImage: presentation.completionSystemImage)
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.completion)

        Divider()

        taskDateMenu(field: .execution, presentation: presentation)
        taskDateMenu(field: .due, presentation: presentation)

        Divider()

        Button {
            Task { _ = await state.createListFromTask(taskID: task.id) }
        } label: {
            Label("根据此任务创建列表", systemImage: "plus.rectangle.on.folder")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.createList)

        Menu {
            ForEach(presentation.moveDestinations) { destination in
                Button {
                    moveTask(to: destination.listID)
                } label: {
                    Label(
                        destination.title,
                        systemImage: destination.isSelected ? "checkmark" : destination.systemImage
                    )
                }
                .accessibilityIdentifier(
                    TaskContextMenuAccessibility.moveDestination(destination.listID)
                )
            }
        } label: {
            Label("将任务移动到…", systemImage: "list.bullet.indent")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.moveMenu)

        Divider()

        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("删除任务", systemImage: "trash")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.delete)
    }

    private func taskDateMenu(
        field: TaskContextDateField,
        presentation: TaskContextMenuPresentation
    ) -> some View {
        Menu {
            Button {
                setDate(state.currentDay, for: field)
            } label: {
                Label("今天", systemImage: "calendar")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateToday(field))

            Button {
                if let tomorrow = state.currentDay.advanced(by: 1) {
                    setDate(tomorrow, for: field)
                }
            } label: {
                Label("明天", systemImage: "calendar.badge.plus")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateTomorrow(field))

            Button {
                datePickerRequest = TaskDatePickerRequest(
                    field: field,
                    initialDay: presentation.currentDate(for: field) ?? state.currentDay,
                    today: state.currentDay
                )
            } label: {
                Label("选择日期…", systemImage: "calendar")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateChoose(field))

            if presentation.currentDate(for: field) != nil {
                Divider()
                Button {
                    setDate(nil, for: field)
                } label: {
                    Label(field.clearTitle, systemImage: "calendar.badge.minus")
                }
                .accessibilityIdentifier(TaskContextMenuAccessibility.dateClear(field))
            }
        } label: {
            Label(presentation.dateMenuTitle(for: field), systemImage: field.systemImage)
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.dateMenu(field))
    }

    private func setDate(_ day: LocalDay?, for field: TaskContextDateField) {
        let value = day.map(TaskPatchField.set) ?? .clear
        switch field {
        case .execution:
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(executionDate: value)
            )
        case .due:
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(dueDate: value)
            )
        }
    }

    private func moveTask(to listID: UUID?) {
        state.enqueueImmediateTaskUpdate(
            taskID: task.id,
            patch: TaskPatch(listID: listID.map(TaskPatchField.set) ?? .clear)
        )
    }

    private func taskSaveFailure(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("修改尚未保存")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("重试") {
                Task { _ = await state.retryTaskEdits(taskID: task.id) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("task.\(task.id.uuidString).retry-save")
        }
        .padding(.horizontal, TodoAgentUI.cardPadding)
        .padding(.vertical, 9)
        .background(.red.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.\(task.id.uuidString).save-error")
    }

    private var completionButton: some View {
        Button {
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(
                    status: task.status == .open ? .completed : .open
                )
            )
        } label: {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.status == .completed ? Color.green : Color.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityLabel(task.status == .completed ? "重新打开" : "标记完成")
        .help(task.status == .completed ? "重新打开任务" : "标记任务为已完成")
    }

    private var sessionButton: some View {
        Button { state.openTask(task) } label: {
            VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
                HStack(alignment: .top, spacing: TodoAgentUI.standardSpacing) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(task.title)
                            .font(.body)
                            .bold()
                            .strikethrough(task.status == .completed)

                        if let datePresentation = task.cardDatePresentation(on: state.currentDay) {
                            Label(dateText(datePresentation.day), systemImage: "calendar")
                                .font(.callout)
                                .foregroundStyle(datePresentation.isOverdue ? Color.red : Color.secondary)
                                .accessibilityLabel(dateAccessibilityLabel(datePresentation))
                                .accessibilityIdentifier(
                                    "task.\(task.id.uuidString).\(datePresentation.kind.rawValue)-date"
                                )
                        }

                        if !task.note.isEmpty {
                            Text(task.note)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: TodoAgentUI.compactSpacing)
                    if state.hasUnreadAgentMessage(for: task) {
                        Circle()
                            .fill(.red)
                            .frame(width: 9, height: 9)
                            .accessibilityLabel("Agent 有新消息")
                    }
                }

                HStack(spacing: TodoAgentUI.standardSpacing) {
                    if let session = state.session(for: task) {
                        Label(session.runtimeKind.title, systemImage: "terminal")
                        Label(session.workingDirectory, systemImage: "folder")
                            .lineLimit(1)
                    } else {
                        Label("进入后选择 Runtime 和执行目录", systemImage: "arrow.right.circle")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func dateText(_ day: LocalDay) -> String {
        guard let date = day.date(in: .todoAgentLocal) else { return day.description }
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private func dateAccessibilityLabel(_ presentation: TaskCardDatePresentation) -> String {
        let field = presentation.kind == .due ? "截止日期" : "执行日期"
        let overdue = presentation.isOverdue ? "，已过期" : ""
        return "\(field)\(dateText(presentation.day))\(overdue)"
    }

    private var borderColor: Color {
        if case .failed = state.taskSaveState(taskID: task.id) { return .red.opacity(0.58) }
        if state.hasUnreadAgentMessage(for: task) { return .red.opacity(0.58) }
        return contextHighlight.isHighlighted ? TodoAgentUI.primaryText.opacity(0.2) : TodoAgentUI.hairline
    }

    private var taskCardBackground: Color {
        contextHighlight.isHighlighted ? TodoAgentUI.selectionBackground : TodoAgentUI.surfaceBackground
    }
}

struct TaskContextHighlightState: Equatable, Sendable {
    var pointerInside = false
    private(set) var trackingDepth = 0

    var isHighlighted: Bool { trackingDepth > 0 }

    mutating func menuDidBeginTracking() {
        guard pointerInside || isHighlighted else { return }
        trackingDepth += 1
    }

    mutating func menuDidEndTracking() {
        guard trackingDepth > 0 else { return }
        trackingDepth -= 1
    }
}

enum TaskContextDateField: String, Identifiable, Sendable {
    case execution
    case due

    var id: String { rawValue }
    var menuTitle: String { self == .execution ? "执行日期" : "截止日期" }
    var clearTitle: String { self == .execution ? "清除执行日期" : "清除截止日期" }
    var systemImage: String { self == .execution ? "calendar.badge.clock" : "calendar.badge.exclamationmark" }
}

struct TaskMoveDestination: Identifiable, Equatable, Sendable {
    let listID: UUID?
    let title: String
    let isSelected: Bool

    var id: String { listID?.uuidString ?? "no-list" }
    var systemImage: String { listID == nil ? "tray" : "list.bullet" }
}

struct TaskContextMenuPresentation: Equatable, Sendable {
    let task: TaskItem
    let lists: [TodoList]

    var completionTitle: String { task.status == .completed ? "重新打开" : "标记为完成" }
    var completionSystemImage: String {
        task.status == .completed ? "arrow.uturn.backward.circle" : "checkmark.circle"
    }

    var moveDestinations: [TaskMoveDestination] {
        [
            TaskMoveDestination(
                listID: nil,
                title: "任务（无清单）",
                isSelected: task.listID == nil
            ),
        ] + lists.map { list in
            TaskMoveDestination(
                listID: list.id,
                title: list.name,
                isSelected: task.listID == list.id
            )
        }
    }

    func currentDate(for field: TaskContextDateField) -> LocalDay? {
        switch field {
        case .execution: task.executionDate
        case .due: task.dueDate
        }
    }

    func dateMenuTitle(for field: TaskContextDateField) -> String {
        guard let day = currentDate(for: field) else { return field.menuTitle }
        return "\(field.menuTitle) · \(day.month)月\(day.day)日"
    }
}

enum TaskContextMenuAccessibility {
    static let completion = "task.context.completion"
    static let createList = "task.context.create-list"
    static let moveMenu = "task.context.move-menu"
    static let delete = "task.context.delete"
    static let deleteConfirmation = "task.context.delete-confirmation"

    static func dateMenu(_ field: TaskContextDateField) -> String {
        "task.context.\(field.rawValue)-date"
    }

    static func dateToday(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).today"
    }

    static func dateTomorrow(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).tomorrow"
    }

    static func dateChoose(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).choose"
    }

    static func dateClear(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).clear"
    }

    static func moveDestination(_ listID: UUID?) -> String {
        "task.context.move.\(listID?.uuidString ?? "no-list")"
    }
}

struct TaskDatePickerRequest: Identifiable {
    let field: TaskContextDateField
    let initialDay: LocalDay
    let today: LocalDay

    var id: String { field.id }
}

private struct TaskDatePickerPopover: View {
    let request: TaskDatePickerRequest
    let onApply: (LocalDay) -> Void

    @Environment(\.dismiss) private var dismiss
    init(request: TaskDatePickerRequest, onApply: @escaping (LocalDay) -> Void) {
        self.request = request
        self.onApply = onApply
    }

    var body: some View {
        TodoAgentDatePickerPanel(
            title: "选择\(request.field.menuTitle)",
            initialDay: request.initialDay,
            today: request.today,
            onCancel: { dismiss() },
            onApply: { day in
                onApply(day)
                dismiss()
            }
        )
        .accessibilityIdentifier("task.context.\(request.field.rawValue)-date.picker")
    }
}
