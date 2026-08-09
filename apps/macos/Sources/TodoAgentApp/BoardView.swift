import SwiftUI

struct BoardView: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TimelineTopBar(state: state)
            if isTimeline {
                TimelineColumns(state: state)
            } else {
                TaskListView(state: state)
            }
        }
        .navigationTitle(state.titleForSelection())
        .background(TodoAgentUI.canvasBackground)
    }

    private var isTimeline: Bool { state.selection == .smart(.timeline) }
}

private struct TimelineTopBar: View {
    let state: AppState
    private static let calendar = Calendar.current

    var body: some View {
        HStack(spacing: TodoAgentUI.standardSpacing) {
            if state.selection == .smart(.timeline) {
                Button {
                    shiftDate(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("前一天")
                .accessibilityLabel("前一天")
                .accessibilityIdentifier("timeline.previousDay")

                Text(state.selectedDate.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.title3)
                    .bold()
                    .accessibilityIdentifier("timeline.selectedDate")

                Button {
                    shiftDate(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .help("后一天")
                .accessibilityLabel("后一天")
                .accessibilityIdentifier("timeline.nextDay")

                if !Self.calendar.isDateInToday(state.selectedDate) {
                    Button("今天") {
                        state.selectedDate = Self.calendar.startOfDay(for: .now)
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("timeline.today")
                }

                Spacer()

                Label("2 个 CLI 可用", systemImage: "circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.green, .secondary)
            } else {
                Text(state.titleForSelection())
                    .font(.title3)
                    .bold()
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, TodoAgentUI.sectionSpacing)
        .frame(height: 52)
        .background(TodoAgentUI.surfaceBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)
        }
    }

    private func shiftDate(_ days: Int) {
        state.selectedDate = Self.calendar.date(
            byAdding: .day,
            value: days,
            to: state.selectedDate
        ) ?? state.selectedDate
    }
}

private struct TimelineColumns: View {
    let state: AppState
    private static let calendar = Calendar.current

    var body: some View {
        let buckets = state.timelineBuckets()
        let selectedDate = state.selectedDate
        let selectedDateIsToday = Self.calendar.isDateInToday(selectedDate)

        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: TodoAgentUI.boardSpacing) {
                    ForEach(BoardBucket.allCases) { bucket in
                        TimelineColumn(
                            bucket: bucket,
                            date: date(for: bucket, selectedDate: selectedDate),
                            tasks: buckets[bucket] ?? [],
                            selectedDateIsToday: selectedDateIsToday,
                            state: state
                        )
                        .frame(width: columnWidth(for: proxy.size.width))
                    }
                }
                .padding(TodoAgentUI.boardPadding)
            }
            .scrollIndicators(.visible)
        }
        .background(TodoAgentUI.canvasBackground)
    }

    private func date(for bucket: BoardBucket, selectedDate: Date) -> Date? {
        let offset: Int? = switch bucket {
        case .today: 0
        case .tomorrow: 1
        case .dayAfter: 2
        case .later: nil
        }
        guard let offset else { return nil }
        return Self.calendar.date(byAdding: .day, value: offset, to: selectedDate)
    }

    private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
        let visibleColumnCount: CGFloat = availableWidth >= 1_180 ? 4 : availableWidth >= 820 ? 3 : 2
        let spacing = TodoAgentUI.boardSpacing * (visibleColumnCount - 1)
        let padding = TodoAgentUI.boardPadding * 2
        let proposed = (availableWidth - spacing - padding) / visibleColumnCount
        return min(max(proposed, TodoAgentUI.columnMinimumWidth), TodoAgentUI.columnMaximumWidth)
    }
}

private struct TimelineColumn: View {
    let bucket: BoardBucket
    let date: Date?
    let tasks: [TaskItem]
    let selectedDateIsToday: Bool
    let state: AppState

    var body: some View {
        let completedCount = tasks.reduce(into: 0) { count, task in
            if task.status == .completed { count += 1 }
        }

        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(heading)
                        .font(.title3)
                        .bold()
                    Text(date?.formatted(.dateTime.month().day()) ?? "没有截止日期，或更远")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if bucket == .today {
                    Text(selectedDateIsToday ? "今天" : "所选")
                        .font(.caption)
                        .bold()
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.1), in: .capsule)
                }
            }

            if bucket == .today, !tasks.isEmpty {
                ProgressView(value: Double(completedCount), total: Double(tasks.count))
                    .tint(.green)
                    .accessibilityLabel("今日任务进度")
                    .accessibilityValue("完成 \(completedCount) 项，共 \(tasks.count) 项")
            } else {
                Spacer().frame(height: 4)
            }

            if tasks.isEmpty {
                TimelineEmptyState(bucket: bucket)
            } else {
                ForEach(tasks) { task in TaskCard(task: task, state: state) }
            }

            Button {
                state.presentNewTask()
            } label: {
                Label("添加任务", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .padding(.vertical, TodoAgentUI.compactSpacing)
            .accessibilityIdentifier("timeline.\(bucket.rawValue).addTask")

            Spacer(minLength: 0)
        }
        .padding(TodoAgentUI.sectionSpacing)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(columnBackground, in: .rect(cornerRadius: TodoAgentUI.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.panelRadius)
                .stroke(
                    bucket == .today
                        ? TodoAgentUI.primaryText.opacity(0.14)
                        : TodoAgentUI.hairline,
                    lineWidth: 1
                )
        }
        .shadow(
            color: bucket == .today ? TodoAgentUI.shadowColor.opacity(0.45) : .clear,
            radius: 10,
            y: 3
        )
        .accessibilityIdentifier("timeline.\(bucket.rawValue).column")
    }

    private var heading: String {
        guard let date else { return "以后" }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private var columnBackground: Color {
        if bucket == .today {
            return TodoAgentUI.selectionBackground
        }
        return TodoAgentUI.surfaceBackground.opacity(bucket == .later ? 0.76 : 1)
    }
}

private struct TimelineEmptyState: View {
    let bucket: BoardBucket

    var body: some View {
        VStack(spacing: TodoAgentUI.compactSpacing) {
            Image(systemName: bucket == .later ? "calendar.badge.clock" : "checkmark.circle")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(bucket == .later ? "没有更远的安排" : "这一天还没有安排")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
    }
}

private struct TaskListView: View {
    let state: AppState

    var body: some View {
        let tasks = state.visibleTasks()

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
                        ForEach(tasks) { task in TaskCard(task: task, state: state) }
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

private struct TaskCard: View {
    let task: TaskItem
    let state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: TodoAgentUI.standardSpacing) {
            completionButton
            sessionButton
        }
        .padding(TodoAgentUI.cardPadding)
        .background(TodoAgentUI.surfaceBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(borderColor, lineWidth: state.hasUnreadAgentMessage(for: task) ? 1.5 : 1)
        }
        .shadow(color: TodoAgentUI.shadowColor.opacity(0.55), radius: 5, y: 2)
        .accessibilityLabel("\(task.title)，\(state.session(for: task) == nil ? "尚未创建 Session" : "进入 Session")")
        .accessibilityIdentifier("task.\(task.id.uuidString).card")
    }

    private var completionButton: some View {
        Button {
            Task { _ = await state.setCompleted(task, completed: task.status == .open) }
        } label: {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.status == .completed ? Color.green : Color.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
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
                    Text(task.status.title)
                        .font(.caption)
                        .bold()
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.1), in: .capsule)
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

    private var statusColor: Color {
        task.status == .completed ? .green : .secondary
    }

    private var borderColor: Color {
        state.hasUnreadAgentMessage(for: task) ? .red.opacity(0.58) : TodoAgentUI.hairline
    }
}
