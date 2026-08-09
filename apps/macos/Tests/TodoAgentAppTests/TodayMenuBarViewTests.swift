import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Today menu bar projection")
struct TodayMenuBarViewTests {
    @Test("only incomplete tasks due on the local calendar day are shown")
    func filtersTodayOpenTasks() throws {
        let calendar = shanghaiCalendar()
        let now = try date(2026, 8, 9, 12, 0, calendar: calendar)
        let today = task(
            id: "00000000-0000-4000-8000-000000000601",
            title: "今天完成",
            status: .open,
            dueDate: try date(2026, 8, 9, 23, 59, calendar: calendar)
        )
        let completedToday = task(
            id: "00000000-0000-4000-8000-000000000602",
            title: "已完成",
            status: .completed,
            dueDate: try date(2026, 8, 9, 8, 0, calendar: calendar)
        )
        let tomorrow = task(
            id: "00000000-0000-4000-8000-000000000603",
            title: "明天处理",
            status: .open,
            dueDate: try date(2026, 8, 10, 0, 0, calendar: calendar)
        )
        let unscheduled = task(
            id: "00000000-0000-4000-8000-000000000604",
            title: "没有日期",
            status: .open,
            dueDate: nil
        )

        let projection = TodayMenuBarProjection(
            tasks: [today, completedToday, tomorrow, unscheduled],
            now: now,
            calendar: calendar
        )

        #expect(projection.tasks.map(\.id) == [today.id])
        #expect(projection.tasks.allSatisfy { $0.status == .open })
    }

    @Test("an empty or non-today task set produces the menu empty state")
    func emptyProjection() throws {
        let calendar = shanghaiCalendar()
        let now = try date(2026, 8, 9, 12, 0, calendar: calendar)
        let task = task(
            id: "00000000-0000-4000-8000-000000000605",
            title: "昨天的任务",
            status: .open,
            dueDate: try date(2026, 8, 8, 23, 59, calendar: calendar)
        )

        let projection = TodayMenuBarProjection(tasks: [task], now: now, calendar: calendar)

        #expect(projection.tasks.isEmpty)
    }

    @Test("local day matching follows the supplied time zone")
    func respectsLocalCalendarTimeZone() throws {
        let calendar = shanghaiCalendar()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-09T00:30:00Z"))
        let sameShanghaiDay = try #require(
            ISO8601DateFormatter().date(from: "2026-08-09T15:59:00Z")
        )
        let nextShanghaiDay = try #require(
            ISO8601DateFormatter().date(from: "2026-08-09T16:00:00Z")
        )
        let sameDayTask = task(
            id: "00000000-0000-4000-8000-000000000606",
            title: "上海当天",
            status: .open,
            dueDate: sameShanghaiDay
        )
        let nextDayTask = task(
            id: "00000000-0000-4000-8000-000000000607",
            title: "上海次日",
            status: .open,
            dueDate: nextShanghaiDay
        )

        let projection = TodayMenuBarProjection(
            tasks: [sameDayTask, nextDayTask],
            now: now,
            calendar: calendar
        )

        #expect(projection.tasks.map(\.id) == [sameDayTask.id])
    }

    private func shanghaiCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try #require(
            calendar.date(
                from: DateComponents(
                    year: year,
                    month: month,
                    day: day,
                    hour: hour,
                    minute: minute
                )
            )
        )
    }

    private func task(
        id: String,
        title: String,
        status: TaskStatus,
        dueDate: Date?
    ) -> TaskItem {
        TaskItem(
            id: UUID(uuidString: id)!,
            listID: nil,
            title: title,
            note: "",
            status: status,
            dueDate: dueDate,
            completedAt: status == .completed ? "2026-08-09T00:00:00Z" : nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }
}
