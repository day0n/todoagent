import Foundation

/// Shared visual grouping for every task surface. Open tasks are intentionally
/// unlabelled; a completed section exists only when it has rows.
struct TaskStatusSections: Equatable, Sendable {
    let openTasks: [TaskItem]
    let completedTasks: [TaskItem]

    init(
        tasks: [TaskItem],
        pinnedTaskID: UUID? = nil,
        pinnedStatus: TaskStatus? = nil
    ) {
        func groupedStatus(for task: TaskItem) -> TaskStatus {
            if task.id == pinnedTaskID, let pinnedStatus { return pinnedStatus }
            return task.status
        }

        openTasks = tasks.filter { groupedStatus(for: $0) == .open }
        completedTasks = tasks.filter { groupedStatus(for: $0) == .completed }
    }

    var hasCompletedSection: Bool { completedTasks.isEmpty == false }

    var rows: [TaskStatusSectionRow] {
        var rows = openTasks.map(TaskStatusSectionRow.task)
        if hasCompletedSection {
            rows.append(.completedHeader(hasOpenTasks: openTasks.isEmpty == false))
            rows.append(contentsOf: completedTasks.map(TaskStatusSectionRow.task))
        }
        return rows
    }
}

enum TaskStatusSectionRow: Identifiable, Equatable, Sendable {
    case task(TaskItem)
    case completedHeader(hasOpenTasks: Bool)

    var id: TaskStatusSectionRowID {
        switch self {
        case let .task(task): .task(task.id)
        case .completedHeader: .completedHeader
        }
    }
}

enum TaskStatusSectionRowID: Hashable, Sendable {
    case task(UUID)
    case completedHeader
}

/// The single projection over the authoritative task rows. Today, task, list,
/// sidebar and menu-bar surfaces never own task copies; they only select the
/// same `TaskItem.id` values by execution date, list or status.
struct TaskProjection: Equatable, Sendable {
    static let empty = TaskProjection(tasks: [], today: .today())

    private let tasks: [TaskItem]
    private let activeListCounts: [UUID: Int]
    private let tasksByID: [UUID: TaskItem]
    private let tasksByExecutionDay: [LocalDay: [TaskItem]]
    let today: LocalDay

    init(
        tasks: [TaskItem],
        today: LocalDay = .today()
    ) {
        self.tasks = tasks
        self.today = today
        tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        activeListCounts = tasks.reduce(into: [:]) { result, task in
            if task.status == .open, let id = task.listID {
                result[id, default: 0] += 1
            }
        }
        let scheduled = tasks.reduce(into: [LocalDay: [TaskItem]]()) { result, task in
            if let day = task.executionDate { result[day, default: []].append(task) }
        }
        tasksByExecutionDay = scheduled.mapValues { Self.order($0, today: today) }
    }

    init(tasks: [TaskItem], now: Date, calendar: Calendar = .todoAgentLocal) {
        self.init(tasks: tasks, today: LocalDay(now, calendar: calendar))
    }

    func count(for view: SmartView, sessions: [TaskSessionDescriptor]) -> Int {
        switch view {
        case .myDay:
            tasks(executingOn: today).count(where: { $0.status == .open })
        case .tasks: tasks.count(where: { $0.status == .open })
        case .running: sessions.count(where: { $0.state.isBusy })
        case .done: tasks.count(where: { $0.status == .completed })
        }
    }

    func activeCount(forList id: UUID) -> Int { activeListCounts[id, default: 0] }
    func task(id: UUID) -> TaskItem? { tasksByID[id] }

    func visibleTasks(
        for selection: SidebarSelection?,
        sessions: [TaskSessionDescriptor]
    ) -> [TaskItem] {
        guard let selection else { return tasks }
        switch selection {
        case let .smart(view):
            switch view {
            case .myDay:
                return tasks(executingOn: today)
            case .tasks:
                return tasks
            case .running:
                let busyTaskIDs = Set(
                    sessions.lazy.filter { $0.state.isBusy }.map(\.taskID)
                )
                return tasks.filter { busyTaskIDs.contains($0.id) }
            case .done:
                return tasks.filter { $0.status == .completed }
            }
        case let .list(id):
            return tasks.filter { $0.listID == id }
        }
    }

    func tasks(executingOn day: LocalDay) -> [TaskItem] {
        tasksByExecutionDay[day, default: []]
    }

    func todayTasks() -> [TaskItem] { tasks(executingOn: today) }

    func isOverdue(_ task: TaskItem) -> Bool { task.isOverdue(on: today) }

    private static func order(_ tasks: [TaskItem], today: LocalDay) -> [TaskItem] {
        tasks.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .open }
            if lhs.status == .open {
                let lhsOverdue = lhs.isOverdue(on: today)
                let rhsOverdue = rhs.isOverdue(on: today)
                if lhsOverdue != rhsOverdue { return lhsOverdue }
                switch (lhs.dueDate, rhs.dueDate) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    return lhsDate < rhsDate
                case (_?, nil): return true
                case (nil, _?): return false
                default: break
                }
            } else if lhs.completedAt != rhs.completedAt {
                return (lhs.completedAt ?? "") > (rhs.completedAt ?? "")
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
