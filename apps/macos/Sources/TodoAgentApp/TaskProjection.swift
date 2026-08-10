import Foundation

/// Shared visual grouping for every task surface. Open tasks are intentionally
/// unlabelled; a completed section exists only when it has rows.
struct TaskStatusSections: Equatable, Sendable {
    let openTasks: [TaskItem]
    let completedTasks: [TaskItem]

    init(tasks: [TaskItem]) {
        openTasks = tasks.filter { $0.status == .open }
        completedTasks = tasks.filter { $0.status == .completed }
    }

    var hasCompletedSection: Bool { completedTasks.isEmpty == false }
}

/// The single schedule projection consumed by the timeline, sidebar badge and
/// menu-bar surface. Membership is based only on `executionDate`.
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
        case .timeline: tasks(executingOn: today).count
        case .tasks: tasks.count(where: { $0.status == .open })
        case .running: sessions.count(where: { $0.state.isBusy })
        case .done: tasks.count(where: { $0.status == .completed })
        }
    }

    func activeCount(forList id: UUID) -> Int { activeListCounts[id, default: 0] }
    func task(id: UUID) -> TaskItem? { tasksByID[id] }

    func tasks(executingOn day: LocalDay) -> [TaskItem] {
        tasksByExecutionDay[day, default: []]
    }

    func todayTasks() -> [TaskItem] { tasks(executingOn: today) }

    func timelineDays(
        startingAt selectedDay: LocalDay,
        calendar: Calendar = .todoAgentLocal
    ) -> [TimelineDay] {
        (0 ..< 4).compactMap { offset in
            selectedDay.advanced(by: offset, calendar: calendar).map { day in
                TimelineDay(day: day, tasks: tasks(executingOn: day))
            }
        }
    }

    func timelineBuckets(
        selectedDay: LocalDay,
        calendar: Calendar = .todoAgentLocal
    ) -> [BoardBucket: [TaskItem]] {
        let buckets = BoardBucket.allCases
        return Dictionary(uniqueKeysWithValues: buckets.enumerated().map { offset, bucket in
            let day = selectedDay.advanced(by: offset, calendar: calendar) ?? selectedDay
            return (bucket, tasks(executingOn: day))
        })
    }

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
