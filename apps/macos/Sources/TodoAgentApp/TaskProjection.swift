import Foundation

struct TaskProjection: Equatable, Sendable {
    static let empty = TaskProjection(tasks: [], now: .distantPast)

    private let tasks: [TaskItem]
    private let smartCounts: [SmartView: Int]
    private let activeListCounts: [UUID: Int]
    private let statusCounts: [TaskStatus: Int]
    private let tasksByID: [UUID: TaskItem]

    init(tasks: [TaskItem], now: Date = .now, calendar: Calendar = .current) {
        self.tasks = tasks

        var smartCounts = Dictionary(uniqueKeysWithValues: SmartView.allCases.map { ($0, 0) })
        var activeListCounts: [UUID: Int] = [:]
        var statusCounts = Dictionary(uniqueKeysWithValues: TaskStatus.allCases.map { ($0, 0) })
        var tasksByID: [UUID: TaskItem] = [:]

        for task in tasks {
            tasksByID[task.id] = task
            statusCounts[task.status, default: 0] += 1

            if task.status != .done {
                smartCounts[.tasks, default: 0] += 1
                if let listID = task.listID {
                    activeListCounts[listID, default: 0] += 1
                }

                let referenceDate = task.dueDate ?? task.createdAt
                if calendar.isDate(referenceDate, inSameDayAs: now) {
                    smartCounts[.timeline, default: 0] += 1
                }
            }

            if task.status == .running { smartCounts[.running, default: 0] += 1 }
            if task.status == .done { smartCounts[.done, default: 0] += 1 }
        }

        self.smartCounts = smartCounts
        self.activeListCounts = activeListCounts
        self.statusCounts = statusCounts
        self.tasksByID = tasksByID
    }

    func count(for view: SmartView) -> Int {
        smartCounts[view, default: 0]
    }

    func activeCount(forList id: UUID) -> Int {
        activeListCounts[id, default: 0]
    }

    func count(for status: TaskStatus) -> Int {
        statusCounts[status, default: 0]
    }

    func task(id: UUID) -> TaskItem? {
        tasksByID[id]
    }

    func timelineBuckets(
        selectedDate: Date,
        calendar: Calendar = .current
    ) -> [BoardBucket: [TaskItem]] {
        var result = Dictionary(uniqueKeysWithValues: BoardBucket.allCases.map { ($0, [TaskItem]()) })
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: selectedDate) ?? selectedDate
        let dayAfter = calendar.date(byAdding: .day, value: 2, to: selectedDate) ?? selectedDate

        for task in tasks {
            let bucket: BoardBucket?
            if task.status == .running || task.status == .needsYou || task.status == .review {
                bucket = .today
            } else if let dueDate = task.dueDate {
                if calendar.isDate(dueDate, inSameDayAs: selectedDate) {
                    bucket = .today
                } else if calendar.isDate(dueDate, inSameDayAs: tomorrow) {
                    bucket = .tomorrow
                } else if calendar.isDate(dueDate, inSameDayAs: dayAfter) {
                    bucket = .dayAfter
                } else if dueDate > dayAfter {
                    bucket = .later
                } else {
                    bucket = nil
                }
            } else {
                bucket = .later
            }

            if let bucket {
                result[bucket, default: []].append(task)
            }
        }

        return result
    }
}
