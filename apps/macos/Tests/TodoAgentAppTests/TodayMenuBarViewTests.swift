import AppKit
import SwiftUI
import Testing
@testable import TodoAgentApp

@Suite("Today menu bar projection")
struct TodayMenuBarViewTests {
    @Test("Today selects today's execution date and keeps completed items")
    func myDayFiltersExecutionDateAndKeepsCompletedTasks() throws {
        let calendar = shanghaiCalendar()
        let now = try date(2026, 8, 9, 12, 0, calendar: calendar)
        let today = LocalDay(now, calendar: calendar)
        let tomorrow = try #require(today.advanced(by: 1, calendar: calendar))
        let openToday = task(
            id: "00000000-0000-4000-8000-000000000601",
            title: "今天完成",
            status: .open,
            executionDate: today
        )
        let completedToday = task(
            id: "00000000-0000-4000-8000-000000000602",
            title: "已完成",
            status: .completed,
            executionDate: today
        )
        let tomorrowTask = task(
            id: "00000000-0000-4000-8000-000000000603",
            title: "明天处理",
            status: .open,
            executionDate: tomorrow
        )
        let dueOnly = task(
            id: "00000000-0000-4000-8000-000000000604",
            title: "仅截止日期",
            status: .open,
            executionDate: nil,
            dueDate: today
        )

        let projection = TodayMenuBarProjection(
            tasks: [completedToday, tomorrowTask, openToday, dueOnly],
            now: now,
            calendar: calendar
        )

        #expect(projection.tasks.map(\.id) == [openToday.id, completedToday.id])
    }

    @Test("tasks outside Today produce no menu rows")
    func emptyMyDayProjection() throws {
        let calendar = shanghaiCalendar()
        let now = try date(2026, 8, 9, 12, 0, calendar: calendar)
        let yesterday = LocalDay(try date(2026, 8, 8, 23, 59, calendar: calendar), calendar: calendar)
        let oldTask = task(
            id: "00000000-0000-4000-8000-000000000605",
            title: "昨天的任务",
            status: .open,
            executionDate: yesterday
        )

        let projection = TodayMenuBarProjection(tasks: [oldTask], now: now, calendar: calendar)

        #expect(projection.tasks.isEmpty)
    }

    @Test("Today matching follows the supplied local time zone")
    func myDayRespectsLocalCalendarTimeZone() throws {
        let calendar = shanghaiCalendar()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-09T00:30:00Z"))
        let shanghaiToday = LocalDay(now, calendar: calendar)
        let nextShanghaiDay = try #require(shanghaiToday.advanced(by: 1, calendar: calendar))
        let sameDayTask = task(
            id: "00000000-0000-4000-8000-000000000606",
            title: "上海当天",
            status: .open,
            executionDate: shanghaiToday
        )
        let nextDayTask = task(
            id: "00000000-0000-4000-8000-000000000607",
            title: "上海次日",
            status: .open,
            executionDate: nextShanghaiDay
        )

        let projection = TodayMenuBarProjection(
            tasks: [sameDayTask, nextDayTask],
            now: now,
            calendar: calendar
        )

        #expect(projection.tasks.map(\.id) == [sameDayTask.id])
    }

    @MainActor
    @Test("real SwiftUI task list has nonzero hosted height")
    func hostedTaskListDoesNotCollapse() {
        let visibleTask = task(
            id: "00000000-0000-4000-8000-000000000608",
            title: "菜单栏可见任务",
            status: .open,
            executionDate: .today()
        )
        let host = NSHostingView(rootView: TodayMenuTaskList(tasks: [visibleTask]))
        host.frame = NSRect(x: 0, y: 0, width: 312, height: 300)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let renderedWithTitle = renderedPNG(of: host)

        var blankTask = visibleTask
        blankTask.title = ""
        let blankHost = NSHostingView(rootView: TodayMenuTaskList(tasks: [blankTask]))
        blankHost.frame = host.frame
        let blankWindow = NSWindow(
            contentRect: blankHost.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        blankWindow.contentView = blankHost
        blankWindow.layoutIfNeeded()
        blankHost.layoutSubtreeIfNeeded()
        blankHost.displayIfNeeded()
        let renderedWithoutTitle = renderedPNG(of: blankHost)

        #expect(TodayMenuBarTaskAreaMetrics.height(taskCount: 1) > 0)
        #expect(host.fittingSize.height > 0)
        #expect(renderedWithTitle != nil)
        #expect(renderedWithTitle != renderedWithoutTitle)
        window.orderOut(nil)
        blankWindow.orderOut(nil)
    }

    @Test("ten tasks expand without scrolling and the eleventh caps the viewport")
    func scrollingStartsAfterTenTasks() {
        let tenTaskHeight = TodayMenuBarTaskAreaMetrics.height(taskCount: 10)

        #expect(TodayMenuBarTaskAreaMetrics.maximumVisibleTaskCount == 10)
        #expect(TodayMenuBarTaskAreaMetrics.requiresScrolling(taskCount: 0) == false)
        #expect(TodayMenuBarTaskAreaMetrics.requiresScrolling(taskCount: 10) == false)
        #expect(TodayMenuBarTaskAreaMetrics.requiresScrolling(taskCount: 11))
        #expect(TodayMenuBarTaskAreaMetrics.height(taskCount: 0) == 0)
        #expect(TodayMenuBarTaskAreaMetrics.height(taskCount: 11) == tenTaskHeight)
        #expect(TodayMenuBarTaskAreaMetrics.height(taskCount: 50) == tenTaskHeight)
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
        executionDate: LocalDay?,
        dueDate: LocalDay? = nil
    ) -> TaskItem {
        TaskItem(
            id: UUID(uuidString: id)!,
            listID: nil,
            title: title,
            note: "",
            status: status,
            executionDate: executionDate,
            dueDate: dueDate,
            completedAt: status == .completed ? "2026-08-09T00:00:00Z" : nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }

    @MainActor
    private func renderedPNG(of view: NSView) -> Data? {
        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}
