import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Internal UI event emitted after the New Task command resolves the active
    /// board context. Only the composer currently on screen responds.
    static let todoAgentFocusTaskComposer = Notification.Name("TodoAgent.focusTaskComposer")
}

struct BoardView: View {
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    @State private var focusesComposerWhenWorkspaceCloses = false

    var body: some View {
        Group {
            if let taskID = taskWorkspace.presentedTaskID {
                TaskSplitWorkspace(
                    taskID: taskID,
                    state: state,
                    taskWorkspace: taskWorkspace
                )
            } else if isTimeline {
                TimelineColumns(state: state, taskWorkspace: taskWorkspace)
            } else {
                TaskListView(state: state, taskWorkspace: taskWorkspace)
            }
        }
        .navigationTitle(state.titleForSelection())
        .background(TodoAgentUI.canvasBackground)
        .toolbar { timelineToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewTask)) { _ in
            focusComposerForCurrentContext()
        }
        .onChange(of: taskWorkspace.presentedTaskID) { previousTaskID, taskID in
            guard previousTaskID != nil,
                  taskID == nil,
                  focusesComposerWhenWorkspaceCloses
            else { return }
            focusesComposerWhenWorkspaceCloses = false
            postComposerFocus()
        }
        .onChange(of: taskWorkspace.closingTaskID) { previousTaskID, taskID in
            guard previousTaskID != nil,
                  taskID == nil,
                  taskWorkspace.presentedTaskID != nil
            else { return }
            focusesComposerWhenWorkspaceCloses = false
        }
    }

    private var isTimeline: Bool {
        taskWorkspace.presentedTaskID == nil && state.selection == .smart(.timeline)
    }

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
        if let taskID = taskWorkspace.presentedTaskID {
            if taskWorkspace.activeWorkspaceShowsTaskRail {
                postComposerFocus()
            } else {
                state.selection = .smart(.tasks)
                focusesComposerWhenWorkspaceCloses = true
                taskWorkspace.closeTaskWorkspace(taskID: taskID)
            }
            return
        }

        switch state.selection {
        case .smart(.running), .smart(.done), nil:
            state.selection = .smart(.tasks)
        case .smart(.timeline), .smart(.tasks), .list:
            break
        }

        postComposerFocus()
    }

    private func postComposerFocus() {
        // Navigation may replace the board subtree. Deliver focus on the next
        // main-run-loop turn so the destination composer has mounted.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .todoAgentFocusTaskComposer, object: nil)
        }
    }
}

enum TaskWorkspaceRailVisibility: Equatable, Sendable {
    case split
    case compact
}

enum TaskWorkspaceLayoutPolicy {
    static let railWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1
    static let terminalMinimumWidth: CGFloat = 500
    static let initialSplitWidth: CGFloat = 830
    static let collapseSplitBelow = railWidth + dividerWidth + terminalMinimumWidth
    static let restoreSplitAt: CGFloat = 840

    static func railVisibility(
        availableWidth: CGFloat,
        previous: TaskWorkspaceRailVisibility?
    ) -> TaskWorkspaceRailVisibility {
        switch previous {
        case .split:
            availableWidth < collapseSplitBelow ? .compact : .split
        case .compact:
            availableWidth >= restoreSplitAt ? .split : .compact
        case nil:
            availableWidth >= initialSplitWidth ? .split : .compact
        }
    }
}

private struct TaskSplitWorkspace: View {
    let taskID: UUID
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator

    @State private var railVisibility: TaskWorkspaceRailVisibility?
    @State private var chromePresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let resolvedVisibility = TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: proxy.size.width,
                previous: railVisibility
            )
            let layoutState = taskWorkspace.layoutState(for: taskID)
            let showsRail = resolvedVisibility == .split
            let isClosing = taskWorkspace.closingTaskID == taskID

            HStack(spacing: 0) {
                if showsRail {
                    taskRail
                        .frame(width: TaskWorkspaceLayoutPolicy.railWidth)
                        .opacity(chromePresented && !isClosing ? 1 : 0)
                        .offset(x: chromePresented && !isClosing ? 0 : -10)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.18),
                            value: chromePresented && !isClosing
                        )

                    Rectangle()
                        .fill(TodoAgentUI.hairline)
                        .frame(width: TaskWorkspaceLayoutPolicy.dividerWidth)
                        .accessibilityHidden(true)
                }

                TaskWorkbenchView(
                    taskID: taskID,
                    state: state,
                    terminalSessions: taskWorkspace.terminalSessions,
                    layoutState: layoutState,
                    toggleTaskDetails: {},
                    requestClose: {
                        taskWorkspace.closeTaskWorkspace(taskID: taskID)
                    },
                    presentation: .embedded(compact: resolvedVisibility == .compact),
                    isClosing: isClosing
                )
                .id(taskID)
                // Ghostty must jump directly to its final AppKit frame. A
                // per-frame width animation sends a resize on every frame and
                // makes terminal input visibly stutter.
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
            .onAppear {
                railVisibility = resolvedVisibility
                taskWorkspace.updateActiveWorkspaceCompactState(
                    taskID: taskID,
                    isCompact: resolvedVisibility == .compact
                )
                presentChrome()
            }
            .onChange(of: proxy.size.width) { _, width in
                let next = TaskWorkspaceLayoutPolicy.railVisibility(
                    availableWidth: width,
                    previous: railVisibility
                )
                guard next != railVisibility else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    railVisibility = next
                }
                taskWorkspace.updateActiveWorkspaceCompactState(
                    taskID: taskID,
                    isCompact: next == .compact
                )
            }
        }
        .background(TodoAgentUI.canvasBackground)
        .accessibilityIdentifier("task.workspace.split")
    }

    private var taskRail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("任务")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)

            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)

            TaskListView(
                state: state,
                taskWorkspace: taskWorkspace,
                selectedWorkspaceTaskID: taskID,
                pendingWorkspaceTaskID: taskWorkspace.pendingTaskID,
                usesWorkspaceRailLayout: true
            )
        }
        .background(TodoAgentUI.sidebarBackground)
    }

    private func presentChrome() {
        guard !reduceMotion else {
            chromePresented = true
            return
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 0.22)) {
                chromePresented = true
            }
        }
    }
}

private struct TimelineColumns: View {
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator

    @State private var pointerNearScrollIndicator = false

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
                            state: state,
                            taskWorkspace: taskWorkspace
                        )
                        .frame(width: columnWidth(for: proxy.size.width))
                    }
                }
                .padding(TodoAgentUI.boardPadding)
            }
            .scrollIndicators(
                TimelineScrollIndicatorPolicy.showsIndicators(
                    pointerNearIndicator: pointerNearScrollIndicator
                )
                    ? .visible
                    : .hidden,
                axes: .horizontal
            )
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    pointerNearScrollIndicator = location.y
                        >= proxy.size.height - TimelineScrollIndicatorPolicy.hoverZoneHeight
                case .ended:
                    pointerNearScrollIndicator = false
                }
            }
            .overlay(alignment: .bottom) {
                // macOS can force scrollbars to remain visible system-wide.
                // This quiet cover preserves scrolling while making the track
                // visually disappear until the pointer enters the timeline.
                Rectangle()
                    .fill(TodoAgentUI.canvasBackground)
                    .frame(height: TimelineScrollIndicatorPolicy.coverHeight)
                    .opacity(
                        TimelineScrollIndicatorPolicy.coverOpacity(
                            pointerNearIndicator: pointerNearScrollIndicator
                        )
                    )
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.18), value: pointerNearScrollIndicator)
        }
        .background(TodoAgentUI.canvasBackground)
    }

    private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
        TimelineColumnLayoutPolicy.columnWidth(availableWidth: availableWidth)
    }
}

enum TimelineScrollIndicatorPolicy {
    static let coverHeight: CGFloat = 18
    static let hoverZoneHeight: CGFloat = 26

    static func showsIndicators(pointerNearIndicator: Bool) -> Bool {
        pointerNearIndicator
    }

    static func coverOpacity(pointerNearIndicator: Bool) -> Double {
        pointerNearIndicator ? 0 : 0.96
    }
}

enum TimelineColumnLayoutPolicy {
    static let dayCount: CGFloat = 4
    static let preferredVisibleDayCount: CGFloat = 3

    static func viewportWidth(showingDayCount visibleDayCount: Int) -> CGFloat {
        let totalDayCount = Int(dayCount)
        let safeDayCount = min(max(visibleDayCount, 1), totalDayCount)
        let columns = CGFloat(safeDayCount) * TodoAgentUI.columnMinimumWidth
        let spacing = CGFloat(safeDayCount - 1) * TodoAgentUI.boardSpacing

        if safeDayCount == totalDayCount {
            return (TodoAgentUI.boardPadding * 2) + columns + spacing
        }

        // The viewport ends in the middle of the following inter-column gap.
        // This lets the Assistant rail meet the timeline cleanly between two
        // complete days without revealing a sliver of the next card.
        return TodoAgentUI.boardPadding
            + columns
            + spacing
            + (TodoAgentUI.boardSpacing / 2)
    }

    /// Day cards grow continuously so a medium launch window ends in the gap
    /// after the third complete day instead of exposing a distracting sliver
    /// of day four. Once the minimum width is reached, a narrower viewport
    /// naturally reveals two days; wider windows can eventually reveal all
    /// four without a breakpoint-sized jump.
    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        let gapAllowance = TodoAgentUI.boardSpacing * (preferredVisibleDayCount - 0.5)
        let proposed = (
            availableWidth - TodoAgentUI.boardPadding - gapAllowance
        ) / preferredVisibleDayCount
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
    let taskWorkspace: TaskWorkspaceCoordinator

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
                focusesForNewTaskCommand: offset == 0,
                composerState: taskWorkspace.timelineComposerState(for: timelineDay.day)
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
    @Bindable var composerState: InlineAddTaskComposerState

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: TodoAgentUI.compactSpacing) {
            Image(systemName: "plus.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("添加任务", text: $composerState.draft)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit(submit)
                .onExitCommand(perform: cancelEditing)
                .accessibilityLabel("添加当天任务")
                .accessibilityHint("输入标题并按回车创建，按 Escape 清空")
                .accessibilityIdentifier("timeline.\(executionDay.description).add-task")

            if composerState.isSubmitting {
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
        let submittedDraft = composerState.draft
        let title = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !composerState.isSubmitting else { return }

        composerState.isSubmitting = true
        Task { @MainActor in
            let succeeded = await state.createTask(
                title: title,
                listID: nil,
                executionDate: executionDay,
                dueDate: nil
            )
            composerState.isSubmitting = false
            if succeeded, composerState.draft == submittedDraft {
                composerState.draft = ""
            }
            isFocused = true
        }
    }

    private func cancelEditing() {
        composerState.draft = ""
        isFocused = false
    }
}

private struct TaskListView: View {
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    var selectedWorkspaceTaskID: UUID?
    var pendingWorkspaceTaskID: UUID?
    var usesWorkspaceRailLayout: Bool

    init(
        state: AppState,
        taskWorkspace: TaskWorkspaceCoordinator,
        selectedWorkspaceTaskID: UUID? = nil,
        pendingWorkspaceTaskID: UUID? = nil,
        usesWorkspaceRailLayout: Bool = false
    ) {
        self.state = state
        self.taskWorkspace = taskWorkspace
        self.selectedWorkspaceTaskID = selectedWorkspaceTaskID
        self.pendingWorkspaceTaskID = pendingWorkspaceTaskID
        self.usesWorkspaceRailLayout = usesWorkspaceRailLayout
    }

    var body: some View {
        let tasks = state.visibleTasks()
        let sections = TaskStatusSections(tasks: tasks)

        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
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
                                TaskCard(
                                    task: task,
                                    state: state,
                                    isWorkspaceSelected: task.id == selectedWorkspaceTaskID,
                                    isWorkspacePending: task.id == pendingWorkspaceTaskID
                                )
                                .id(task.id)
                            }

                            if sections.hasCompletedSection {
                                CompletedTasksSectionHeader(
                                    hasOpenTasks: sections.openTasks.isEmpty == false,
                                    accessibilityIdentifier: completedSectionIdentifier
                                )

                                ForEach(sections.completedTasks) { task in
                                    TaskCard(
                                        task: task,
                                        state: state,
                                        isWorkspaceSelected: task.id == selectedWorkspaceTaskID,
                                        isWorkspacePending: task.id == pendingWorkspaceTaskID
                                    )
                                    .id(task.id)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: usesWorkspaceRailLayout ? .infinity : 780)
                    .padding(usesWorkspaceRailLayout ? 14 : 20)
                }
                .onAppear { scrollSelectedTaskToVisible(using: scrollProxy) }
                .onChange(of: selectedWorkspaceTaskID) { _, _ in
                    scrollSelectedTaskToVisible(using: scrollProxy)
                }
            }

            if let addTaskDestination {
                InlineAddTaskComposer(
                    state: state,
                    destination: addTaskDestination,
                    composerState: taskWorkspace.composerState(for: addTaskDestination),
                    horizontalPadding: usesWorkspaceRailLayout ? 14 : 20
                )
                    .id(addTaskDestination)
            }
        }
        .frame(maxWidth: .infinity)
        .background(TodoAgentUI.canvasBackground)
    }

    private var addTaskDestination: InlineAddTaskDestination? {
        switch state.selection {
        case .smart where usesWorkspaceRailLayout:
            .allTasks
        case .smart(.tasks):
            .allTasks
        case let .list(id):
            .list(id)
        default:
            nil
        }
    }

    private func scrollSelectedTaskToVisible(using proxy: ScrollViewProxy) {
        guard usesWorkspaceRailLayout, let selectedWorkspaceTaskID else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(selectedWorkspaceTaskID, anchor: .center)
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

enum InlineAddTaskDestination: Hashable {
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

@MainActor
@Observable
final class InlineAddTaskComposerState {
    var draft = ""
    var isSubmitting = false
}

private struct InlineAddTaskComposer: View {
    let state: AppState
    let destination: InlineAddTaskDestination
    @Bindable var composerState: InlineAddTaskComposerState
    let horizontalPadding: CGFloat

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

                TextField("添加任务", text: $composerState.draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancelEditing)
                    .accessibilityLabel("添加任务")
                    .accessibilityHint("输入任务标题并按回车创建，按 Escape 清空")
                    .accessibilityIdentifier(destination.accessibilityIdentifier)

                if composerState.isSubmitting {
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
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity)
        .background(TodoAgentUI.canvasBackground)
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentFocusTaskComposer)) { _ in
            isFocused = true
        }
    }

    private func submit() {
        let submittedDraft = composerState.draft
        let title = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !composerState.isSubmitting else { return }

        composerState.isSubmitting = true
        Task { @MainActor in
            let succeeded = await state.createTask(
                title: title,
                listID: destination.listID,
                executionDate: nil,
                dueDate: nil
            )
            composerState.isSubmitting = false
            if succeeded, composerState.draft == submittedDraft {
                composerState.draft = ""
            }
        }
    }

    private func cancelEditing() {
        composerState.draft = ""
        isFocused = false
    }
}

struct TaskCard: View {
    let task: TaskItem
    let state: AppState
    let isWorkspaceSelected: Bool
    let isWorkspacePending: Bool

    init(
        task: TaskItem,
        state: AppState,
        isWorkspaceSelected: Bool = false,
        isWorkspacePending: Bool = false
    ) {
        self.task = task
        self.state = state
        self.isWorkspaceSelected = isWorkspaceSelected
        self.isWorkspacePending = isWorkspacePending
    }

    @State private var datePickerRequest: TaskDatePickerRequest?
    @State private var isConfirmingDelete = false
    @State private var contextHighlight = TaskContextHighlightState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var agentStatus: TaskCardAgentStatus {
        TaskCardAgentStatus(session: state.session(for: task))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: TodoAgentUI.standardSpacing) {
                completionButton
                sessionButton
            }
            .padding(TodoAgentUI.cardPadding)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(cardAccessibilityLabel)

            if case let .failed(message) = state.taskSaveState(taskID: task.id) {
                Divider()
                taskSaveFailure(message)
            }
        }
        .background(taskCardBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(
                    borderColor,
                    lineWidth: agentStatus.isRunning || isWorkspaceSelected ? 1.5 : 1
                )
        }
        .shadow(
            color: cardShadowColor,
            radius: agentStatus.isRunning ? 10 : (contextHighlight.isHighlighted ? 9 : 5),
            y: agentStatus.isRunning ? 0 : (contextHighlight.isHighlighted ? 4 : 2)
        )
        .accessibilityIdentifier("task.\(task.id.uuidString).card")
        .accessibilityAddTraits(isWorkspaceSelected ? .isSelected : [])
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.12),
            value: isWorkspaceSelected
        )
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
            HStack(alignment: .center, spacing: TodoAgentUI.standardSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.body)
                        .bold()
                        .strikethrough(task.status == .completed)
                        .lineLimit(1)

                    taskMetadata
                }

                Spacer(minLength: TodoAgentUI.compactSpacing)
                agentIndicators
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var taskMetadata: some View {
        let datePresentation = task.cardDatePresentation(on: state.currentDay)
        if let datePresentation, datePresentation.isOverdue {
            taskDateLabel(datePresentation)
        } else if !task.note.isEmpty {
            Label(task.note, systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if let datePresentation {
            taskDateLabel(datePresentation)
        }
    }

    private func taskDateLabel(_ presentation: TaskCardDatePresentation) -> some View {
        Label(dateText(presentation.day), systemImage: "calendar")
            .font(.caption)
            .foregroundStyle(presentation.isOverdue ? Color.red : Color.secondary)
            .accessibilityLabel(dateAccessibilityLabel(presentation))
            .accessibilityIdentifier(
                "task.\(task.id.uuidString).\(presentation.kind.rawValue)-date"
            )
            .lineLimit(1)
    }

    private var agentIndicators: some View {
        HStack(spacing: 7) {
            if isWorkspacePending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在切换到此任务")
            }

            if agentStatus.isRunning {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.green.opacity(0.9), radius: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agent 正在运行")
            }

            if agentStatus.hasUnread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle().stroke(TodoAgentUI.surfaceBackground, lineWidth: 1.5)
                    }
                    .accessibilityLabel("Agent 有新回复")
            }
        }
        .frame(width: 36, alignment: .trailing)
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
        if isWorkspaceSelected { return TodoAgentUI.primaryText.opacity(0.55) }
        if agentStatus.isRunning { return .green.opacity(0.72) }
        return contextHighlight.isHighlighted ? TodoAgentUI.primaryText.opacity(0.2) : TodoAgentUI.hairline
    }

    private var cardShadowColor: Color {
        if agentStatus.isRunning { return .green.opacity(0.34) }
        return TodoAgentUI.shadowColor.opacity(contextHighlight.isHighlighted ? 0.9 : 0.55)
    }

    private var cardAccessibilityLabel: String {
        var parts = [task.title]
        if isWorkspaceSelected { parts.append("已在工作区打开") }
        if isWorkspacePending { parts.append("正在切换") }
        if agentStatus.isRunning { parts.append("Agent 正在运行") }
        if agentStatus.hasUnread { parts.append("Agent 有新回复") }
        return parts.joined(separator: "，")
    }

    private var taskCardBackground: Color {
        if isWorkspaceSelected { return TodoAgentUI.selectionBackground }
        return contextHighlight.isHighlighted ? TodoAgentUI.selectionBackground : TodoAgentUI.surfaceBackground
    }
}

struct TaskCardAgentStatus: Equatable, Sendable {
    let isRunning: Bool
    let hasUnread: Bool

    init(isRunning: Bool, hasUnread: Bool) {
        self.isRunning = isRunning
        self.hasUnread = hasUnread
    }

    init(session: TaskSessionDescriptor?) {
        self.init(
            isRunning: session?.state.isBusy == true,
            hasUnread: session?.hasUnread == true
        )
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
