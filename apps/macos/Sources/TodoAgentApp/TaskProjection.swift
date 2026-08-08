import Foundation

struct TaskProjection: Equatable, Sendable {
    static let empty = TaskProjection(tasks: [], now: .distantPast)
    private let tasks: [TaskItem]
    private let activeListCounts: [UUID: Int]
    private let tasksByID: [UUID: TaskItem]
    private let todayCount: Int

    init(tasks: [TaskItem], now: Date = .now, calendar: Calendar = .current) {
        self.tasks = tasks
        tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        activeListCounts = tasks.reduce(into: [:]) { result, task in
            if task.status == .open, let id = task.listID { result[id, default: 0] += 1 }
        }
        todayCount = tasks.filter { task in
            task.status == .open && calendar.isDate(task.dueDate ?? task.createdAt, inSameDayAs: now)
        }.count
    }

    func count(for view: SmartView, sessions: [TaskSessionDescriptor]) -> Int {
        switch view {
        case .timeline: todayCount
        case .tasks: tasks.count(where: { $0.status == .open })
        case .running: sessions.count(where: { $0.state.isBusy })
        case .done: tasks.count(where: { $0.status == .completed })
        }
    }

    func activeCount(forList id: UUID) -> Int { activeListCounts[id, default: 0] }
    func task(id: UUID) -> TaskItem? { tasksByID[id] }

    func timelineBuckets(selectedDate: Date, calendar: Calendar = .current) -> [BoardBucket: [TaskItem]] {
        var result = Dictionary(uniqueKeysWithValues: BoardBucket.allCases.map { ($0, [TaskItem]()) })
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: selectedDate) ?? selectedDate
        for task in tasks where task.status == .open {
            let date = task.dueDate
            let bucket: BoardBucket
            if let date, calendar.isDate(date, inSameDayAs: selectedDate) { bucket = .today }
            else if let date, calendar.isDate(date, inSameDayAs: tomorrow) { bucket = .tomorrow }
            else if let date, calendar.isDate(date, inSameDayAs: dayAfter) { bucket = .dayAfter }
            else { bucket = .later }
            result[bucket, default: []].append(task)
        }
        return result
    }
}
