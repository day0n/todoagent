import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TodoAgentApp

@Suite("Unified task time and autosave")
@MainActor
struct TaskTimeSystemTests {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    @Test("LocalDay accepts only real strict YYYY-MM-DD values")
    func strictLocalDay() throws {
        let leapDay = try #require(LocalDay(rawValue: "2028-02-29"))
        #expect(leapDay.rawValue == "2028-02-29")
        #expect(LocalDay(rawValue: "2026-2-09") == nil)
        #expect(LocalDay(rawValue: "2026-02-30") == nil)
        #expect(LocalDay(rawValue: "2026-13-01") == nil)

        let encoded = try JSONEncoder().encode(leapDay)
        #expect(String(decoding: encoded, as: UTF8.self) == #""2028-02-29""#)
        #expect(try JSONDecoder().decode(LocalDay.self, from: encoded) == leapDay)
    }

    @Test("production local calendar stays Gregorian across Buddhist and Japanese locales")
    func productionCalendarIsGregorian() throws {
        let instant = try date("2026-08-09T12:00:00+08:00")
        let expected = try day("2026-08-09")

        for localeID in ["th_TH", "ja_JP"] {
            var productionCalendar = Calendar.todoAgentLocal
            productionCalendar.locale = Locale(identifier: localeID)
            productionCalendar.timeZone = shanghai

            #expect(productionCalendar.identifier == .gregorian)
            #expect(LocalDay(instant, calendar: productionCalendar) == expected)
            #expect(expected.date(in: productionCalendar).map {
                LocalDay($0, calendar: productionCalendar)
            } == expected)

            let projected = TaskProjection(
                tasks: [task("当天", execution: expected)],
                now: instant,
                calendar: productionCalendar
            )
            #expect(projected.todayTasks().map(\.title) == ["当天"])
        }

        #expect(Calendar.todoAgentLocal.identifier == .gregorian)
        #expect(Calendar.todoAgentLocal.timeZone.identifier == TimeZone.autoupdatingCurrent.identifier)
    }

    @Test("four timeline days use execution date only and retain completed tasks")
    func fourDayProjection() throws {
        let start = try day("2026-08-09")
        let dueOnly = task("仅截止", due: try day("2026-08-09"))
        let first = task("今天执行", execution: start)
        let completed = task("今天完成", status: .completed, execution: start)
        let fourth = task("第四天", execution: try day("2026-08-12"))
        let outside = task("第五天", execution: try day("2026-08-13"))
        let projection = TaskProjection(
            tasks: [dueOnly, first, completed, fourth, outside],
            today: start
        )

        let days = projection.timelineDays(startingAt: start, calendar: calendar())
        #expect(days.map(\.day.rawValue) == ["2026-08-09", "2026-08-10", "2026-08-11", "2026-08-12"])
        #expect(Set(days[0].tasks.map(\.title)) == ["今天执行", "今天完成"])
        #expect(days[0].completedCount == 1)
        #expect(days[0].progress == 0.5)
        #expect(days[3].tasks.map(\.title) == ["第四天"])
        #expect(days.flatMap(\.tasks).contains(where: { $0.id == dueOnly.id }) == false)
        #expect(days.flatMap(\.tasks).contains(where: { $0.id == outside.id }) == false)
    }

    @Test("every task surface groups open rows first and hides an empty completed section")
    func taskStatusSections() {
        let completedFirst = task("先完成", status: .completed)
        let firstOpen = task("待处理一")
        let completedSecond = task("后完成", status: .completed)
        let secondOpen = task("待处理二")

        let mixed = TaskStatusSections(
            tasks: [completedFirst, firstOpen, completedSecond, secondOpen]
        )
        #expect(mixed.openTasks.map(\.id) == [firstOpen.id, secondOpen.id])
        #expect(mixed.completedTasks.map(\.id) == [completedFirst.id, completedSecond.id])
        #expect(mixed.hasCompletedSection)

        let openOnly = TaskStatusSections(tasks: [firstOpen, secondOpen])
        #expect(openOnly.openTasks.map(\.id) == [firstOpen.id, secondOpen.id])
        #expect(openOnly.completedTasks.isEmpty)
        #expect(openOnly.hasCompletedSection == false)
    }

    @Test("one authoritative task row drives timeline, tasks and list surfaces")
    func oneAuthoritativeTaskAcrossSurfaces() async throws {
        let list = TodoList(
            id: UUID(),
            name: "项目清单",
            colorName: "blue",
            repositoryPath: nil
        )
        let originalDay = try day("2026-08-10")
        let movedDay = try day("2026-08-11")
        var item = task("同一条任务", execution: originalDay)
        item.listID = list.id

        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(lists: [list], tasks: [item])
        )
        let state = AppState(repository: repository)
        await state.load()

        state.selection = .smart(.tasks)
        #expect(state.visibleTasks().map(\.id) == [item.id])
        state.selection = .list(list.id)
        #expect(state.visibleTasks().map(\.id) == [item.id])
        #expect(state.tasks(executingOn: originalDay).map(\.id) == [item.id])
        #expect(state.tasks.count == 1)

        #expect(await state.updateTask(
            taskID: item.id,
            patch: TaskPatch(
                title: "三个界面同步更新",
                status: .completed,
                executionDate: .set(movedDay)
            )
        ))

        state.selection = .smart(.tasks)
        let allVisibleTasks = state.visibleTasks()
        #expect(allVisibleTasks.count == 1)
        let allTask = try #require(allVisibleTasks.first)
        #expect(allTask.id == item.id)
        #expect(allTask.title == "三个界面同步更新")
        #expect(allTask.status == .completed)

        state.selection = .list(list.id)
        let listVisibleTasks = state.visibleTasks()
        #expect(listVisibleTasks.count == 1)
        let listTask = try #require(listVisibleTasks.first)
        #expect(listTask == allTask)
        let listSections = TaskStatusSections(tasks: listVisibleTasks)
        #expect(listSections.openTasks.isEmpty)
        #expect(listSections.completedTasks.map(\.id) == [item.id])
        #expect(state.tasks(executingOn: originalDay).isEmpty)
        #expect(state.tasks(executingOn: movedDay) == [allTask])
        #expect(state.tasks.count == 1)

        #expect(await state.deleteTask(taskID: item.id))

        state.selection = .smart(.tasks)
        #expect(state.visibleTasks().isEmpty)
        state.selection = .list(list.id)
        #expect(state.visibleTasks().isEmpty)
        #expect(state.tasks(executingOn: movedDay).isEmpty)
        #expect(state.task(id: item.id) == nil)
        #expect(state.tasks.isEmpty)
    }

    @Test("overdue and timeline ordering share the documented rule")
    func overdueOrdering() throws {
        let today = try day("2026-08-09")
        let execution = today
        let overdueLater = task("较晚逾期", execution: execution, due: try day("2026-08-08"))
        let overdueEarlier = task("较早逾期", execution: execution, due: try day("2026-08-07"))
        let dueToday = task("今日截止", execution: execution, due: today)
        let noDue = task("无截止", execution: execution)
        let completed = task(
            "已完成",
            status: .completed,
            execution: execution,
            due: try day("2026-08-01"),
            completedAt: "2026-08-09T01:00:00Z"
        )
        let projection = TaskProjection(
            tasks: [noDue, completed, dueToday, overdueLater, overdueEarlier],
            today: today
        )

        #expect(overdueEarlier.isOverdue(on: today))
        #expect(dueToday.isOverdue(on: today) == false)
        #expect(completed.isOverdue(on: today) == false)
        #expect(projection.todayTasks().map(\.title) == [
            "较早逾期", "较晚逾期", "今日截止", "无截止", "已完成",
        ])
    }

    @Test("task cards surface a past execution day when no deadline explains the warning")
    func taskCardDatePresentation() throws {
        let today = try day("2026-08-10")
        let pastExecution = try day("2026-08-07")
        let futureExecution = try day("2026-08-12")
        let pastDue = try day("2026-08-08")
        let futureDue = try day("2026-08-13")

        let executionOnly = task("错过执行日", execution: pastExecution)
        let executionPresentation = try #require(executionOnly.cardDatePresentation(on: today))
        #expect(executionOnly.isOverdue(on: today))
        #expect(executionPresentation.kind == .execution)
        #expect(executionPresentation.day == pastExecution)
        #expect(executionPresentation.isOverdue)

        let futureDeadline = task(
            "执行日已过但截止日未到",
            execution: pastExecution,
            due: futureDue
        )
        let missedExecutionPresentation = try #require(
            futureDeadline.cardDatePresentation(on: today)
        )
        #expect(missedExecutionPresentation.kind == .execution)
        #expect(missedExecutionPresentation.isOverdue)

        let overdueDeadline = task(
            "两个日期都已过",
            execution: pastExecution,
            due: pastDue
        )
        let duePresentation = try #require(overdueDeadline.cardDatePresentation(on: today))
        #expect(duePresentation.kind == .due)
        #expect(duePresentation.day == pastDue)
        #expect(duePresentation.isOverdue)

        let upcoming = task("尚未到期", execution: futureExecution, due: futureDue)
        let upcomingPresentation = try #require(upcoming.cardDatePresentation(on: today))
        #expect(upcoming.isOverdue(on: today) == false)
        #expect(upcomingPresentation.kind == .due)
        #expect(upcomingPresentation.isOverdue == false)

        let completed = task(
            "已完成不标红",
            status: .completed,
            execution: pastExecution,
            completedAt: "2026-08-09T01:00:00Z"
        )
        let completedPresentation = try #require(completed.cardDatePresentation(on: today))
        #expect(completed.isOverdue(on: today) == false)
        #expect(completedPresentation.kind == .execution)
        #expect(completedPresentation.isOverdue == false)

        #expect(task("没有日期").cardDatePresentation(on: today) == nil)
    }

    @Test("inline creation persists the exact execution day")
    func inlineCreationDate() async throws {
        let repository = TaskMutationSpyRepository(snapshot: snapshot())
        let state = AppState(repository: repository)
        await state.load()
        let execution = try day("2026-08-10")

        #expect(await state.createTask(title: "8月10日执行", executionDate: execution))

        let call = try #require(await repository.createCalls().first)
        #expect(call.executionDate == execution)
        #expect(call.dueDate == nil)
    }

    @Test("title edits debounce and an explicit flush cancels the wait")
    func debounceAndFlush() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.updateTask(
            taskID: item.id,
            patch: TaskPatch(title: "草稿"),
            debounce: true
        ))
        #expect(state.taskSaveState(taskID: item.id) == .debouncing)
        #expect(await repository.updateCallCount() == 0)
        #expect(state.task(id: item.id)?.title == "草稿")

        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(await repository.updateCallCount() == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        try await Task.sleep(for: .milliseconds(850))
        #expect(await repository.updateCallCount() == 1)
    }

    @Test("a typing burst is merged into one trailing autosave")
    func typingBurstCoalescesIntoOneAutosave() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        state.scheduleTaskUpdate(taskID: item.id, patch: TaskPatch(note: "三"))
        state.scheduleTaskUpdate(taskID: item.id, patch: TaskPatch(note: "三个"))
        state.scheduleTaskUpdate(taskID: item.id, patch: TaskPatch(note: "三个 skill"))

        #expect(state.taskSaveState(taskID: item.id) == .debouncing)
        #expect(state.task(id: item.id)?.note == "三个 skill")
        #expect(await repository.updateCallCount() == 0)

        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(await repository.updateCallCount() == 1)
        #expect(await repository.persistedTask(id: item.id)?.note == "三个 skill")
    }

    @Test("failed autosave retains its draft and retries the same patch")
    func failedSaveRetainsDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            failuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.updateTask(taskID: item.id, patch: TaskPatch(note: "不能丢")) == false)
        #expect(state.task(id: item.id)?.note == "不能丢")
        guard case let .failed(message) = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected a visible failed save state.")
            return
        }
        #expect(message.isEmpty == false)

        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(await repository.updateCallCount() == 2)
        #expect(state.task(id: item.id)?.note == "不能丢")
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("closing task details flushes the draft before the debounce deadline")
    func closingTaskDetailsFlushesDebouncedDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(title: "关闭前必须保存")
        )
        #expect(state.presentedSheet == .taskSession(item.id))
        #expect(state.taskSaveState(taskID: item.id) == .debouncing)
        #expect(await repository.updateCallCount() == 0)

        #expect(await state.flushAndDismissTaskSession(taskID: item.id))
        #expect(state.presentedSheet == nil)
        #expect(await repository.updateCallCount() == 1)
        #expect(await repository.persistedTask(id: item.id)?.title == "关闭前必须保存")
        #expect(state.taskSaveState(taskID: item.id) == .idle)

        try await Task.sleep(for: .milliseconds(850))
        #expect(await repository.updateCallCount() == 1)
    }

    @Test("failed close keeps task details and its retryable draft")
    func failedCloseKeepsTaskDetailsAndDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            failuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: "关闭失败也不能丢")
        )

        #expect(await state.flushAndDismissTaskSession(taskID: item.id) == false)
        #expect(state.presentedSheet == .taskSession(item.id))
        #expect(state.task(id: item.id)?.note == "关闭失败也不能丢")
        guard case let .failed(message) = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected the failed close write to remain retryable.")
            return
        }
        #expect(message.isEmpty == false)
        #expect(await repository.updateCallCount() == 1)

        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(state.presentedSheet == .taskSession(item.id))
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        #expect(await repository.updateCallCount() == 2)
        #expect(await repository.persistedTask(id: item.id)?.note == "关闭失败也不能丢")

        #expect(await state.flushAndDismissTaskSession(taskID: item.id))
        #expect(state.presentedSheet == nil)
        #expect(await repository.updateCallCount() == 2)
    }

    @Test("same-run-loop date edit is durable before task details close")
    func immediateDateEditFlushesBeforeClose() async throws {
        let item = task("原始")
        let executionDay = try day("2026-08-12")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(executionDate: .set(executionDay))
        )
        #expect(await state.flushAndDismissTaskSession(taskID: item.id))

        #expect(state.presentedSheet == nil)
        #expect(await repository.persistedTask(id: item.id)?.executionDate == executionDay)
        #expect(await repository.updateCallCount() == 1)
    }

    @Test("same-run-loop date edit is durable before Session start")
    func immediateDateEditFlushesBeforeSessionStart() async throws {
        let item = task("原始")
        let executionDay = try day("2026-08-13")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item], runtimes: [readyRuntime()])
        )
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(executionDate: .set(executionDay))
        )
        #expect(await state.startSession(
            item,
            runtime: .codex,
            workspace: "/tmp/todoagent-project"
        ))

        #expect(await repository.persistedTask(id: item.id)?.executionDate == executionDay)
        #expect(await repository.sessionCreateCallCount() == 1)
    }

    @Test("Agent deletion ignores a late successful Session creation")
    func taskDeletionDuringSessionCreationDropsLateSuccess() async throws {
        let item = task("创建 Session 时被删除")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item], runtimes: [readyRuntime()]),
            gatedSessionCreateCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        let creation = Task {
            await state.startSession(
                item,
                runtime: .codex,
                workspace: "/tmp/todoagent-project"
            )
        }
        await repository.waitUntilSessionCreateStarted(1)
        await state.consume(try taskRemovalEvent(revision: 2))
        await repository.releaseSessionCreate(1)

        #expect(await creation.value == false)
        #expect(state.task(id: item.id) == nil)
        #expect(state.presentedSheet == nil)
        #expect(state.conversation(for: item) == nil)
        #expect(state.sessions.isEmpty)
        #expect(state.taskSessionErrorMessage == nil)
    }

    @Test("Agent deletion suppresses a late Session creation error")
    func taskDeletionDuringSessionCreationDropsLateFailure() async throws {
        let item = task("创建 Session 失败前被删除")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item], runtimes: [readyRuntime()]),
            gatedSessionCreateCalls: [1],
            sessionCreateError: .taskNotFound
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        let creation = Task {
            await state.startSession(
                item,
                runtime: .codex,
                workspace: "/tmp/todoagent-project"
            )
        }
        await repository.waitUntilSessionCreateStarted(1)
        await state.consume(try taskRemovalEvent(revision: 2))
        await repository.releaseSessionCreate(1)

        #expect(await creation.value == false)
        #expect(state.taskSessionErrorMessage == nil)
        #expect(state.taskSaveStates[item.id] == nil)
    }

    @Test("failed in-flight attachment blocks close and remains retryable")
    func failedAttachmentBlocksClose() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            attachmentFailuresRemaining: 1,
            gatedAttachmentCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)
        state.enqueueTaskAttachmentAdd(
            taskID: item.id,
            sourcePaths: ["/tmp/report.pdf"]
        )

        let release = Task {
            await repository.waitUntilAttachmentStarted(1)
            await repository.releaseAttachment(1)
        }
        #expect(await state.flushAndDismissTaskSession(taskID: item.id) == false)
        await release.value

        #expect(state.presentedSheet == .taskSession(item.id))
        guard case let .failed(message) = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected an attachment failure visible in task details.")
            return
        }
        #expect(message.isEmpty == false)
        #expect(await repository.attachmentCallCount() == 1)

        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        #expect(state.task(id: item.id)?.attachments.count == 1)
        #expect(await state.flushAndDismissTaskSession(taskID: item.id))
        #expect(state.presentedSheet == nil)
    }

    @Test("failed in-flight attachment blocks Session start")
    func failedAttachmentBlocksSessionStart() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item], runtimes: [readyRuntime()]),
            attachmentFailuresRemaining: 1,
            gatedAttachmentCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.enqueueTaskAttachmentAdd(
            taskID: item.id,
            sourcePaths: ["/tmp/report.pdf"]
        )

        let release = Task {
            await repository.waitUntilAttachmentStarted(1)
            await repository.releaseAttachment(1)
        }
        #expect(await state.startSession(
            item,
            runtime: .codex,
            workspace: "/tmp/todoagent-project"
        ) == false)
        await release.value

        #expect(await repository.sessionCreateCallCount() == 0)
        #expect(state.taskSessionErrorMessage?.contains("尚未保存") == true)
        guard case .failed = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected the attachment failure to remain visible and retryable.")
            return
        }
    }

    @Test("app shutdown waits for an in-flight attachment")
    func shutdownWaitsForAttachment() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedAttachmentCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.enqueueTaskAttachmentAdd(
            taskID: item.id,
            sourcePaths: ["/tmp/report.pdf"]
        )

        let release = Task {
            await repository.waitUntilAttachmentStarted(1)
            #expect(await repository.shutdownCallCount() == 0)
            await repository.releaseAttachment(1)
        }
        #expect(await state.shutdown())
        await release.value

        #expect(await repository.attachmentCallCount() == 1)
        #expect(await repository.shutdownCallCount() == 1)
        #expect(await repository.persistedTask(id: item.id)?.attachments.count == 1)
    }

    @Test("lost add response reconciles and replays one durable attachment mutation")
    func ambiguousAttachmentAddDoesNotDuplicate() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            ambiguousAttachmentFailuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.addTaskAttachments(
            taskID: item.id,
            sourcePaths: ["/tmp/report.pdf"]
        ))

        #expect(state.task(id: item.id)?.attachments.count == 1)
        #expect(await repository.persistedTask(id: item.id)?.attachments.count == 1)
        #expect(await repository.attachmentCallCount() == 2)
        #expect(await repository.uniqueAttachmentMutationIDCount() == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("lost remove response reconciles an already-absent attachment as success")
    func ambiguousAttachmentRemoveDoesNotRetryCommittedRemoval() async throws {
        var item = task("原始")
        let existingAttachment = attachment(
            taskID: item.id,
            relativePath: "Attachments/managed-report.pdf"
        )
        item.attachments = [existingAttachment]
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            ambiguousAttachmentFailuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.removeTaskAttachment(
            taskID: item.id,
            attachmentID: existingAttachment.id
        ))

        #expect(state.task(id: item.id)?.attachments.isEmpty == true)
        #expect(await repository.persistedTask(id: item.id)?.attachments.isEmpty == true)
        #expect(await repository.attachmentCallCount() == 1)
        #expect(await repository.uniqueAttachmentMutationIDCount() == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("shutdown freezes task edits after its input commit barrier")
    func shutdownFreezesLateTaskMutation() async throws {
        let first = task("A")
        let second = task("B")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [first, second]),
            gatedUpdateCalls: [1, 2]
        )
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: first.id,
            patch: TaskPatch(note: "A 已修改")
        )
        await repository.waitUntilUpdateStarted(1)

        let shutdown = Task { await state.shutdown() }
        await Task.yield()
        state.enqueueImmediateTaskUpdate(
            taskID: second.id,
            patch: TaskPatch(note: "B 晚到修改")
        )

        await repository.releaseUpdate(1)
        #expect(await shutdown.value)
        #expect(await repository.updateCallCount() == 1)
        #expect(await repository.persistedTask(id: second.id)?.note != "B 晚到修改")
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("same-run-loop completion edit is registered before shutdown")
    func completionEditFlushesBeforeShutdown() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(status: .completed)
        )
        #expect(await state.shutdown())

        #expect(await repository.persistedTask(id: item.id)?.status == .completed)
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("shutdown accepts the final input commit before freezing mutations")
    func shutdownCommitsMarkedTextBeforeFreeze() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()
        let presenter = TaskWorkspaceInputCommitSpy {
            state.scheduleTaskUpdate(
                taskID: item.id,
                patch: TaskPatch(title: "中文输入完成")
            )
        }
        state.taskWorkspacePresenter = presenter

        #expect(await state.shutdown())

        #expect(presenter.commitCount == 1)
        #expect(await repository.persistedTask(id: item.id)?.title == "中文输入完成")
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("immediate app shutdown flushes a debounced task draft")
    func shutdownFlushesDebouncedDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(title: "退出前必须保存")
        )
        #expect(state.taskSaveState(taskID: item.id) == .debouncing)

        #expect(await state.shutdown())
        #expect(await repository.updateCallCount() == 1)
        #expect(await repository.persistedTask(id: item.id)?.title == "退出前必须保存")
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("failed shutdown save cancels termination and keeps a retryable draft")
    func failedShutdownKeepsDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            failuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: "退出失败也不能丢")
        )

        #expect(await state.shutdown() == false)
        #expect(state.isPreparingToTerminate == false)
        #expect(state.task(id: item.id)?.note == "退出失败也不能丢")
        #expect(await repository.shutdownCallCount() == 0)
        guard case .failed = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected the failed shutdown write to remain retryable.")
            return
        }
        #expect(state.errorMessage?.contains("已取消退出") == true)

        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(await state.shutdown())
        #expect(await repository.persistedTask(id: item.id)?.note == "退出失败也不能丢")
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("per-task writes stay serial and merge newer drafts")
    func serialWrites() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            updateDelay: .milliseconds(80)
        )
        let state = AppState(repository: repository)
        await state.load()

        let first = Task {
            await state.updateTask(taskID: item.id, patch: TaskPatch(title: "标题"))
        }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task {
            await state.updateTask(taskID: item.id, patch: TaskPatch(note: "备注"))
        }

        #expect(await first.value)
        #expect(await second.value)
        #expect(await repository.maximumConcurrentUpdates() == 1)
        #expect(state.task(id: item.id)?.title == "标题")
        #expect(state.task(id: item.id)?.note == "备注")
    }

    @Test("three interleaved flush callers keep one per-task drain")
    func threeInterleavedFlushesStaySerial() async throws {
        let item = task("原始")
        let dueDate = try day("2026-08-12")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedUpdateCalls: [1, 2]
        )
        let state = AppState(repository: repository)
        await state.load()

        let first = Task {
            await state.updateTask(taskID: item.id, patch: TaskPatch(title: "标题"))
        }
        await repository.waitUntilUpdateStarted(1)

        let second = Task {
            await state.updateTask(taskID: item.id, patch: TaskPatch(note: "备注"))
        }
        await waitUntil { state.task(id: item.id)?.note == "备注" }

        await repository.releaseUpdate(1)
        await repository.waitUntilUpdateStarted(2)

        let third = Task {
            await state.updateTask(
                taskID: item.id,
                patch: TaskPatch(dueDate: .set(dueDate))
            )
        }
        await waitUntil { state.task(id: item.id)?.dueDate == dueDate }
        #expect(await repository.maximumConcurrentUpdates() == 1)

        await repository.releaseUpdate(2)
        #expect(await first.value)
        #expect(await second.value)
        #expect(await third.value)
        #expect(await repository.updateCallCount() == 3)
        #expect(await repository.maximumConcurrentUpdates() == 1)
        #expect(await repository.persistedTask(id: item.id)?.title == "标题")
        #expect(await repository.persistedTask(id: item.id)?.note == "备注")
        #expect(await repository.persistedTask(id: item.id)?.dueDate == dueDate)
    }

    @Test("consecutive immediate date and status callbacks preserve their final values")
    func consecutiveImmediateEditsStayOrdered() async throws {
        let item = task("原始")
        let firstDay = try day("2026-08-11")
        let finalDay = try day("2026-08-12")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(executionDate: .set(firstDay))
        )
        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(executionDate: .set(finalDay))
        )
        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(status: .completed)
        )
        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(status: .open)
        )

        #expect(state.task(id: item.id)?.executionDate == finalDay)
        #expect(state.task(id: item.id)?.status == .open)
        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(await repository.persistedTask(id: item.id)?.executionDate == finalDay)
        #expect(await repository.persistedTask(id: item.id)?.status == .open)
        #expect(await repository.updateCallCount() == 1)
        #expect(await repository.maximumConcurrentUpdates() == 1)
    }

    @Test("in-flight patch survives a newer snapshot and failed response")
    func inFlightPatchSurvivesSnapshotAndFailure() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            failuresRemaining: 1,
            gatedUpdateCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: "本地草稿")
        )
        await repository.waitUntilUpdateStarted(1)

        var external = item
        external.title = "Agent 改名"
        external.updatedAt = "2026-08-09T00:00:02Z"
        await repository.replaceSnapshot(snapshot(revision: 2, tasks: [external]))
        #expect(await state.detectRuntimes())
        #expect(state.task(id: item.id)?.title == "Agent 改名")
        #expect(state.task(id: item.id)?.note == "本地草稿")

        await repository.releaseUpdate(1)
        #expect(await state.flushTaskEdits(taskID: item.id) == false)
        #expect(state.task(id: item.id)?.title == "Agent 改名")
        #expect(state.task(id: item.id)?.note == "本地草稿")
        guard case .failed = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected the restored in-flight patch to remain retryable.")
            return
        }

        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(await repository.persistedTask(id: item.id)?.title == "Agent 改名")
        #expect(await repository.persistedTask(id: item.id)?.note == "本地草稿")
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("task.changed deletion clears debounced drafts and task detail state")
    func taskChangedDeletionCleansLocalState() async throws {
        let item = task("由 Agent 删除")
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        let bundle = sessionBundle(taskID: item.id)
        await state.consume(try sessionChangedEvent(bundle))
        state.openTask(item)
        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(title: "不会在删除后落盘")
        )
        #expect(state.conversation(for: item) != nil)
        #expect(state.presentedSheet == .taskSession(item.id))
        #expect(state.taskSaveState(taskID: item.id) == .debouncing)

        await repository.replaceSnapshot(snapshot(revision: 2))
        await state.consume(try taskRemovalEvent(revision: 2))

        #expect(state.task(id: item.id) == nil)
        #expect(state.conversation(for: item) == nil)
        #expect(state.sessions.isEmpty)
        #expect(state.presentedSheet == nil)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        #expect(state.taskSaveStates[item.id] == nil)
        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(state.taskSaveStates[item.id] == nil)

        // A stale session event arriving after the deletion cannot recreate
        // the removed task's bundle or detail state.
        await state.consume(try sessionChangedEvent(bundle))
        #expect(state.conversation(for: item) == nil)
        #expect(state.sessions.isEmpty)

        try await Task.sleep(for: .milliseconds(850))
        #expect(await repository.updateCallCount() == 0)
    }

    @Test("task.changed deletion does not restore an in-flight failed patch")
    func taskChangedDeletionDropsInFlightPatch() async throws {
        let item = task("保存中被 Agent 删除")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedUpdateCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: "不能复活")
        )
        await repository.waitUntilUpdateStarted(1)
        let flush = Task { await state.flushTaskEdits(taskID: item.id) }
        await Task.yield()

        await repository.replaceSnapshot(snapshot(revision: 2))
        await state.consume(try taskRemovalEvent(revision: 2))
        await repository.releaseUpdate(1)

        #expect(await flush.value)
        #expect(state.task(id: item.id) == nil)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        #expect(state.taskSaveStates[item.id] == nil)
        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(state.taskSaveStates[item.id] == nil)
        #expect(await repository.updateCallCount() == 1)
    }

    @Test("task.changed deletion drops queued attachment work after the active call")
    func taskChangedDeletionDropsAttachmentQueue() async throws {
        let item = task("附件上传中被 Agent 删除")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedAttachmentCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()

        state.enqueueTaskAttachmentAdd(
            taskID: item.id,
            sourcePaths: ["/tmp/first.txt"]
        )
        await repository.waitUntilAttachmentStarted(1)
        state.enqueueTaskAttachmentAdd(
            taskID: item.id,
            sourcePaths: ["/tmp/second.txt"]
        )
        let flush = Task { await state.flushTaskEdits(taskID: item.id) }
        await Task.yield()

        await repository.replaceSnapshot(snapshot(revision: 2))
        await state.consume(try taskRemovalEvent(revision: 2))
        await repository.releaseAttachment(1)

        #expect(await flush.value)
        #expect(state.task(id: item.id) == nil)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
        #expect(state.taskSaveStates[item.id] == nil)
        #expect(await state.retryTaskEdits(taskID: item.id))
        #expect(state.taskSaveStates[item.id] == nil)
        #expect(await repository.attachmentCallCount() == 1)
    }

    @Test("equal-revision mutation response reconciles Engine-normalized detail draft")
    func equalRevisionResponseReconcilesDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedUpdateCalls: [1],
            normalizesTaskTitles: true,
            commitsTaskUpdateBeforeGate: true
        )
        let state = AppState(repository: repository)
        await state.load()
        var draft = TaskDetailDraft(task: item)
        draft.title = "  权威标题  "

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(title: draft.title)
        )
        await repository.waitUntilUpdateStarted(1)

        // Models task.changed arriving before the matching mutation response.
        #expect(await state.detectRuntimes())
        #expect(state.task(id: item.id)?.title == "  权威标题  ")
        draft = draft.reconciled(
            with: try #require(state.task(id: item.id)),
            saveState: state.taskSaveState(taskID: item.id)
        )
        #expect(draft.title == "  权威标题  ")

        await repository.releaseUpdate(1)
        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(state.task(id: item.id)?.title == "权威标题")
        #expect(state.taskSaveState(taskID: item.id) == .idle)

        draft = draft.reconciled(
            with: try #require(state.task(id: item.id)),
            saveState: state.taskSaveState(taskID: item.id)
        )
        #expect(draft.title == "权威标题")
    }

    @Test("detail draft reconciles an external title after its save becomes idle")
    func detailDraftReconcilesExternalSnapshotAfterSave() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedUpdateCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        var draft = TaskDetailDraft(task: item)
        draft.note = "本地备注"

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: draft.note)
        )
        await repository.waitUntilUpdateStarted(1)

        var external = item
        external.title = "Agent 改名"
        external.updatedAt = "2026-08-09T00:00:02Z"
        await repository.replaceSnapshot(snapshot(revision: 2, tasks: [external]))
        #expect(await state.detectRuntimes())
        draft = draft.reconciled(
            with: try #require(state.task(id: item.id)),
            saveState: state.taskSaveState(taskID: item.id)
        )
        #expect(draft.title == "原始")
        #expect(draft.note == "本地备注")

        await repository.releaseUpdate(1)
        #expect(await state.flushTaskEdits(taskID: item.id))
        draft = draft.reconciled(
            with: try #require(state.task(id: item.id)),
            saveState: state.taskSaveState(taskID: item.id)
        )
        #expect(draft.title == "Agent 改名")
        #expect(draft.note == "本地备注")
    }

    @Test("an active note edit cannot be overwritten by an autosave response")
    func activeNoteEditSurvivesAutosaveReconciliation() {
        let item = task("输入保护")
        var draft = TaskDetailDraft(task: item)
        draft.note = "三个 skill"

        var staleResponse = item
        staleResponse.title = "Engine 同时改了标题"
        staleResponse.note = "三个 sk"
        draft = draft.reconciled(
            with: staleResponse,
            saveState: .idle,
            preserving: .note
        )

        #expect(draft.title == "输入保护")
        #expect(draft.note == "三个 skill")

        draft = draft.reconciled(
            with: staleResponse,
            saveState: .idle
        )
        #expect(draft.title == "Engine 同时改了标题")
        #expect(draft.note == "三个 sk")
    }

    @Test("same-value task patches never create a mutation")
    func sameValuePatchIsNoOp() async throws {
        let executionDay = try day("2026-08-10")
        let item = task("原始", execution: executionDay)
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.updateTask(
            taskID: item.id,
            patch: TaskPatch(
                title: item.title,
                note: item.note,
                status: item.status,
                listID: .clear,
                executionDate: .set(executionDay),
                dueDate: .clear
            )
        ))
        state.scheduleTaskUpdate(taskID: item.id, patch: TaskPatch(title: item.title))
        try await Task.sleep(for: .milliseconds(850))

        #expect(await repository.updateCallCount() == 0)
        #expect(state.revision == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("task cards expose failed completion saves and a retry row")
    func taskCardShowsSaveFailure() async throws {
        let item = task("卡片保存失败")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            failuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.setCompleted(item, completed: true) == false)
        let failedTask = try #require(state.task(id: item.id))
        guard case .failed = state.taskSaveState(taskID: item.id) else {
            Issue.record("Expected a card-visible failed save state.")
            return
        }
        let failedHeight = hostedCardHeight(task: failedTask, state: state)

        #expect(await state.retryTaskEdits(taskID: item.id))
        let savedTask = try #require(state.task(id: item.id))
        let savedHeight = hostedCardHeight(task: savedTask, state: state)

        #expect(failedHeight > savedHeight)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("task card agent lights distinguish running work from unread replies")
    func taskCardAgentLights() {
        let taskID = UUID()
        let idle = sessionBundle(taskID: taskID).session
        let running = sessionBundle(
            taskID: taskID,
            state: .running,
            lastAgentSequence: 4,
            lastReadSequence: 4
        ).session
        let unread = sessionBundle(
            taskID: taskID,
            lastAgentSequence: 5,
            lastReadSequence: 4
        ).session
        let runningUnread = sessionBundle(
            taskID: taskID,
            state: .running,
            lastAgentSequence: 6,
            lastReadSequence: 4
        ).session

        #expect(TaskCardAgentStatus(session: nil) == .init(isRunning: false, hasUnread: false))
        #expect(TaskCardAgentStatus(session: idle) == .init(isRunning: false, hasUnread: false))
        #expect(TaskCardAgentStatus(session: running) == .init(isRunning: true, hasUnread: false))
        #expect(TaskCardAgentStatus(session: unread) == .init(isRunning: false, hasUnread: true))
        #expect(TaskCardAgentStatus(session: runningUnread) == .init(isRunning: true, hasUnread: true))
    }

    @Test("task cards stay compact when a local Agent session exists")
    func taskCardStaysCompactWithSession() async throws {
        let executionDay = try day("2026-08-11")
        var item = task("完善中英文 skill 教程", execution: executionDay)
        item.note = "增加 instruction 和 information 教程"
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [item]))
        let state = AppState(repository: repository)
        await state.load()
        await state.consume(try sessionChangedEvent(sessionBundle(taskID: item.id)))

        #expect(state.session(for: item) != nil)
        #expect(hostedCardHeight(task: item, state: state) < 100)
    }

    @Test("managed attachments honor the isolated data root and strict path shape")
    func managedAttachmentURL() {
        let taskID = UUID()
        let root = "/private/tmp/todoagent-isolated-\(UUID().uuidString)"
        let valid = attachment(
            taskID: taskID,
            relativePath: "Attachments/managed-report.pdf"
        )

        #expect(
            valid.managedURL(environment: ["TODOAGENT_NATIVE_DATA_DIR": root])?.path
                == "\(root)/Attachments/managed-report.pdf"
        )

        let invalidPaths = [
            "managed-report.pdf",
            "Other/managed-report.pdf",
            "Attachments/",
            "Attachments/.",
            "Attachments/..",
            "Attachments/nested/managed-report.pdf",
            "/Attachments/managed-report.pdf",
        ]
        for relativePath in invalidPaths {
            #expect(
                attachment(taskID: taskID, relativePath: relativePath)
                    .managedURL(environment: ["TODOAGENT_NATIVE_DATA_DIR": root]) == nil,
                "Expected \(relativePath) to be rejected."
            )
        }
    }

    @Test("engine restart ready coalesces recovery and keeps a pending draft on top")
    func engineReadyRecoversSnapshotAndDraft() async throws {
        let item = task("原始")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(revision: 4, tasks: [item]),
            gatedSyncCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.scheduleTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(note: "未落盘草稿")
        )

        var recovered = item
        recovered.title = "重启后权威任务"
        recovered.updatedAt = "2026-08-09T00:00:05Z"
        await repository.replaceSnapshot(snapshot(revision: 5, tasks: [recovered]))
        let ready = EngineEvent(name: "engine.ready", data: Data("{}".utf8))

        await state.consume(ready)
        await repository.waitUntilSyncStarted(1)
        await state.consume(ready)
        await repository.releaseSync(1)
        await waitUntil { state.revision == 5 }

        #expect(await repository.syncCallCount() == 1)
        #expect(state.task(id: item.id)?.title == "重启后权威任务")
        #expect(state.task(id: item.id)?.note == "未落盘草稿")
        #expect(await state.flushTaskEdits(taskID: item.id))
        #expect(await repository.persistedTask(id: item.id)?.note == "未落盘草稿")
    }

    @Test("runtime changed applies only a newer authoritative revision")
    func runtimeChangedRequiresNewRevision() async throws {
        let repository = TaskMutationSpyRepository(snapshot: snapshot(revision: 7))
        let state = AppState(repository: repository)
        await state.load()
        let event = EngineEvent(name: "runtime.changed", data: Data("{}".utf8))

        await repository.replaceSnapshot(
            snapshot(revision: 8, runtimes: [readyRuntime()])
        )
        await state.consume(event)
        #expect(state.revision == 8)
        #expect(state.readyRuntimeCount == 1)

        await repository.replaceSnapshot(snapshot(revision: 8, runtimes: []))
        await state.consume(event)
        #expect(state.revision == 8)
        #expect(state.readyRuntimeCount == 1)

        await repository.replaceSnapshot(snapshot(revision: 6, runtimes: []))
        await state.consume(event)
        #expect(state.revision == 8)
        #expect(state.readyRuntimeCount == 1)
    }

    @Test("older snapshots cannot roll state or revision backward")
    func rejectsOldRevision() async throws {
        let current = task("新快照")
        let stale = task("旧快照")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(revision: 8, tasks: [current]),
            staleRuntimeSnapshot: snapshot(revision: 7, tasks: [stale])
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.detectRuntimes())
        #expect(state.revision == 8)
        #expect(state.tasks.first?.title == "新快照")
    }

    @Test("timeline following today advances across midnight with every today consumer")
    func localDayRefresh() async throws {
        var calendar = calendar()
        calendar.timeZone = shanghai
        let augustNinth = try date("2026-08-09T08:00:00+08:00")
        let augustTenth = try date("2026-08-10T00:00:01+08:00")
        let task = task("明天", execution: try day("2026-08-10"))
        let repository = TaskMutationSpyRepository(snapshot: snapshot(tasks: [task]))
        let state = AppState(repository: repository, now: augustNinth, calendar: calendar)
        await state.load()
        #expect(state.count(for: .timeline) == 0)

        state.refreshLocalDay(now: augustTenth)

        let expectedDay = try day("2026-08-10")
        #expect(state.currentDay == expectedDay)
        #expect(state.selectedDay == expectedDay)
        #expect(state.timelineDays().first?.day == expectedDay)
        #expect(state.todayTasks().map(\.id) == [task.id])
        #expect(state.count(for: .timeline) == state.todayTasks().count)
    }

    @Test("midnight refresh preserves a date the user deliberately browsed")
    func localDayRefreshPreservesBrowsedDate() throws {
        var calendar = calendar()
        calendar.timeZone = shanghai
        let augustNinth = try date("2026-08-09T08:00:00+08:00")
        let augustTenth = try date("2026-08-10T00:00:01+08:00")
        let currentDay = try day("2026-08-10")
        let browsedDay = try day("2026-08-12")
        let state = AppState(
            repository: TaskMutationSpyRepository(snapshot: snapshot()),
            now: augustNinth,
            calendar: calendar
        )
        state.selectedDay = browsedDay

        state.refreshLocalDay(now: augustTenth)

        #expect(state.currentDay == currentDay)
        #expect(state.selectedDay == browsedDay)
        #expect(state.timelineDays().first?.day == browsedDay)
    }

    @Test("task context menu exposes status, dates, destinations, and stable accessibility ids")
    func taskContextMenuPresentation() throws {
        let firstList = TodoList(
            id: UUID(),
            name: "工作",
            colorName: "blue",
            repositoryPath: nil
        )
        let secondList = TodoList(
            id: UUID(),
            name: "个人",
            colorName: "green",
            repositoryPath: nil
        )
        var openTask = task(
            "右键菜单",
            execution: try day("2026-08-10"),
            due: try day("2026-08-12")
        )
        openTask.listID = firstList.id

        let open = TaskContextMenuPresentation(
            task: openTask,
            lists: [firstList, secondList]
        )
        let expectedExecutionDate = try day("2026-08-10")
        let expectedDueDate = try day("2026-08-12")
        #expect(open.completionTitle == "标记为完成")
        #expect(open.currentDate(for: .execution) == expectedExecutionDate)
        #expect(open.currentDate(for: .due) == expectedDueDate)
        #expect(open.dateMenuTitle(for: .execution) == "执行日期 · 8月10日")
        #expect(open.dateMenuTitle(for: .due) == "截止日期 · 8月12日")
        #expect(open.moveDestinations.count == 3)
        #expect(open.moveDestinations.first?.title == "任务（无清单）")
        #expect(open.moveDestinations.first(where: { $0.listID == firstList.id })?.isSelected == true)

        openTask.status = .completed
        let completed = TaskContextMenuPresentation(task: openTask, lists: [firstList])
        #expect(completed.completionTitle == "重新打开")

        let identifiers = [
            TaskContextMenuAccessibility.completion,
            TaskContextMenuAccessibility.dateMenu(.execution),
            TaskContextMenuAccessibility.dateToday(.execution),
            TaskContextMenuAccessibility.dateTomorrow(.execution),
            TaskContextMenuAccessibility.dateChoose(.execution),
            TaskContextMenuAccessibility.dateClear(.execution),
            TaskContextMenuAccessibility.dateMenu(.due),
            TaskContextMenuAccessibility.createList,
            TaskContextMenuAccessibility.moveMenu,
            TaskContextMenuAccessibility.moveDestination(nil),
            TaskContextMenuAccessibility.delete,
            TaskContextMenuAccessibility.deleteConfirmation,
        ]
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("compact date picker week strip always runs Monday through Sunday")
    func compactDatePickerWeekStrip() throws {
        let midweek = TodoAgentWeekStripPresentation(selectedDay: try day("2026-08-12"))
        #expect(midweek.days.map(\.rawValue) == [
            "2026-08-10",
            "2026-08-11",
            "2026-08-12",
            "2026-08-13",
            "2026-08-14",
            "2026-08-15",
            "2026-08-16",
        ])

        let sunday = TodoAgentWeekStripPresentation(selectedDay: try day("2026-08-16"))
        #expect(sunday.days == midweek.days)
    }

    @Test("lost create-list response syncs the atomic result without duplicating it")
    func ambiguousCreateListFromTaskRecovers() async throws {
        let existingList = TodoList(
            id: UUID(),
            name: "已有清单",
            colorName: "blue",
            repositoryPath: nil
        )
        let item = task("根据任务建清单")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(lists: [existingList], tasks: [item]),
            ambiguousCreateListFailuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.createListFromTask(taskID: item.id))

        let createdList = try #require(state.lists.first(where: { $0.id != existingList.id }))
        #expect(state.lists.count == 2)
        #expect(createdList.name == item.title)
        #expect(state.task(id: item.id)?.listID == createdList.id)
        #expect(state.selection == .list(createdList.id))
        #expect(await repository.syncCallCount() == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("lost delete response syncs the committed deletion and closes details")
    func ambiguousDeleteRecovers() async {
        let item = task("删除后响应丢失")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            ambiguousDeleteFailuresRemaining: 1
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(item)

        #expect(await state.deleteTask(taskID: item.id))

        #expect(state.task(id: item.id) == nil)
        #expect(state.presentedSheet == nil)
        #expect(await repository.syncCallCount() == 1)
        #expect(state.taskSaveState(taskID: item.id) == .idle)
    }

    @Test("active local Session delete conflict is presented in clear Chinese")
    func activeSessionDeleteError() async {
        let item = task("运行中的任务")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            deleteError: .requestFailed(
                code: "task_session_active",
                message: "task session active"
            )
        )
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.deleteTask(taskID: item.id) == false)

        let message = "任务的本地 Session 正在运行，请先停止本轮再删除。"
        #expect(state.task(id: item.id) != nil)
        #expect(state.errorMessage == message)
        #expect(state.taskSaveState(taskID: item.id) == .failed(message))
    }

    @Test("shutdown waits for a confirmed delete and rejects competing task patches")
    func shutdownWaitsForDeleteCommand() async {
        let item = task("删除时退出")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item]),
            gatedDeleteCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()

        let deletion = Task { await state.deleteTask(taskID: item.id) }
        await repository.waitUntilDeleteStarted(1)
        #expect(state.isTaskCommandInFlight(taskID: item.id))

        state.enqueueImmediateTaskUpdate(
            taskID: item.id,
            patch: TaskPatch(status: .completed)
        )
        #expect(state.task(id: item.id)?.status == .open)

        let shutdown = Task { await state.shutdown() }
        await Task.yield()
        #expect(await repository.shutdownCallCount() == 0)

        await repository.releaseDelete(1)
        #expect(await deletion.value)
        #expect(await shutdown.value)
        #expect(await repository.shutdownCallCount() == 1)
    }

    @Test("shutdown waits for an in-flight Session start and rejects its late result")
    func shutdownWaitsForSessionStart() async {
        let item = task("启动时退出")
        let repository = TaskMutationSpyRepository(
            snapshot: snapshot(tasks: [item], runtimes: [readyRuntime()]),
            gatedSessionCreateCalls: [1]
        )
        let state = AppState(repository: repository)
        await state.load()

        let creation = Task {
            await state.startSession(
                item,
                runtime: .codex,
                workspace: "/tmp/todoagent-project"
            )
        }
        await repository.waitUntilSessionCreateStarted(1)

        let shutdown = Task { await state.shutdown() }
        await Task.yield()
        #expect(await repository.shutdownCallCount() == 0)

        await repository.releaseSessionCreate(1)
        #expect(await creation.value == false)
        #expect(await shutdown.value)
        #expect(state.sessions.isEmpty)
        #expect(await repository.shutdownCallCount() == 1)
    }

    private func day(_ value: String) throws -> LocalDay {
        try #require(LocalDay(rawValue: value))
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func task(
        _ title: String,
        status: TaskStatus = .open,
        execution: LocalDay? = nil,
        due: LocalDay? = nil,
        completedAt: String? = nil
    ) -> TaskItem {
        TaskItem(
            id: UUID(),
            listID: nil,
            title: title,
            note: "",
            status: status,
            executionDate: execution,
            dueDate: due,
            completedAt: completedAt,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }

    private func snapshot(
        revision: Int64 = 1,
        lists: [TodoList] = [],
        tasks: [TaskItem] = [],
        runtimes: [RuntimeInfo] = []
    ) -> AppSnapshot {
        AppSnapshot(
            revision: revision,
            lists: lists,
            tasks: tasks,
            runtimes: runtimes,
            sessions: [],
            messages: []
        )
    }

    private func taskRemovalEvent(revision: Int64) throws -> EngineEvent {
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "lists": [],
            "tasks": [],
            "taskAttachments": [],
            "runtimes": [],
            "sessions": [],
        ])
        return EngineEvent(name: "task.changed", data: data)
    }

    private func sessionChangedEvent(_ bundle: SessionBundle) throws -> EngineEvent {
        EngineEvent(name: "session.changed", data: try JSONEncoder().encode(bundle))
    }

    private func sessionBundle(
        taskID: UUID,
        state: SessionState = .idle,
        lastAgentSequence: Int64 = 0,
        lastReadSequence: Int64 = 0
    ) -> SessionBundle {
        SessionBundle(
            session: TaskSessionDescriptor(
                id: "session-\(taskID.uuidString)",
                taskID: taskID,
                runtimeKind: .codex,
                workingDirectory: "/tmp/project",
                providerSessionID: nil,
                providerEngine: nil,
                state: state,
                lastAgentSequence: lastAgentSequence,
                lastReadSequence: lastReadSequence,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: "2026-08-09T00:00:00Z",
                updatedAt: "2026-08-09T00:00:00Z"
            ),
            messages: [],
            activeTurn: nil
        )
    }

    private func readyRuntime() -> RuntimeInfo {
        RuntimeInfo(
            kind: .codex,
            launchPath: "/usr/local/bin/codex",
            resolvedPath: "/usr/local/bin/codex",
            version: "codex-cli test",
            status: .ready,
            authStatus: "authenticated",
            capabilities: [:],
            providerEngine: nil,
            detectedAt: nil,
            verifiedAt: "2026-08-09T00:00:00Z",
            verifyError: nil
        )
    }

    private func attachment(taskID: UUID, relativePath: String) -> TaskAttachment {
        TaskAttachment(
            id: UUID(),
            taskID: taskID,
            originalName: "report.pdf",
            sizeBytes: 42,
            mimeType: "application/pdf",
            relativePath: relativePath,
            createdAt: "2026-08-09T00:00:00Z"
        )
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0 ..< 100 where !predicate() {
            await Task.yield()
        }
        #expect(predicate())
    }

    private func hostedCardHeight(task: TaskItem, state: AppState) -> CGFloat {
        let host = NSHostingView(rootView: TaskCard(task: task, state: state).frame(width: 520))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }
}

@MainActor
private final class TaskWorkspaceInputCommitSpy: TaskWorkspacePresenting {
    private let commit: () -> Void
    private(set) var commitCount = 0

    init(commit: @escaping () -> Void) {
        self.commit = commit
    }

    func showTaskWorkspace(taskID _: UUID) {}
    func closeTaskWorkspace(taskID _: UUID) {}
    func destroyTaskWorkspace(taskID _: UUID) {}

    func commitTaskWorkspaceInput() {
        commitCount += 1
        commit()
    }
}

private struct TaskCreateObservation: Equatable, Sendable {
    let executionDate: LocalDay?
    let dueDate: LocalDay?
}

private actor TaskMutationSpyRepository: AppRepository {
    private var snapshot: AppSnapshot
    private let staleRuntimeSnapshot: AppSnapshot?
    private var failuresRemaining: Int
    private var attachmentFailuresRemaining: Int
    private var ambiguousAttachmentFailuresRemaining: Int
    private var ambiguousDeleteFailuresRemaining: Int
    private var ambiguousCreateListFailuresRemaining: Int
    private let deleteError: EngineClientError?
    private let updateDelay: Duration
    private let gatedUpdateCalls: Set<Int>
    private let gatedAttachmentCalls: Set<Int>
    private let gatedSyncCalls: Set<Int>
    private let gatedDeleteCalls: Set<Int>
    private let gatedSessionCreateCalls: Set<Int>
    private let sessionCreateError: AppRepositoryError?
    private let normalizesTaskTitles: Bool
    private let commitsTaskUpdateBeforeGate: Bool
    private var creates: [TaskCreateObservation] = []
    private var updates: [TaskPatch] = []
    private var activeUpdates = 0
    private var maxActiveUpdates = 0
    private var shutdowns = 0
    private var sessionCreates = 0
    private var updateAttempts = 0
    private var attachmentAttempts = 0
    private var deleteAttempts = 0
    private var attachmentMutationIDs: [UUID] = []
    private var completedAttachmentMutationIDs: Set<UUID> = []
    private var syncAttempts = 0
    private var startedUpdateCalls: Set<Int> = []
    private var updateStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var updateReleaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedAttachmentCalls: Set<Int> = []
    private var attachmentStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var attachmentReleaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedSyncCalls: Set<Int> = []
    private var syncStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var syncReleaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedDeleteCalls: Set<Int> = []
    private var deleteStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var deleteReleaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startedSessionCreateCalls: Set<Int> = []
    private var sessionCreateStartWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var sessionCreateReleaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(
        snapshot: AppSnapshot,
        failuresRemaining: Int = 0,
        attachmentFailuresRemaining: Int = 0,
        ambiguousAttachmentFailuresRemaining: Int = 0,
        ambiguousDeleteFailuresRemaining: Int = 0,
        ambiguousCreateListFailuresRemaining: Int = 0,
        deleteError: EngineClientError? = nil,
        updateDelay: Duration = .zero,
        gatedUpdateCalls: Set<Int> = [],
        gatedAttachmentCalls: Set<Int> = [],
        gatedSyncCalls: Set<Int> = [],
        gatedDeleteCalls: Set<Int> = [],
        gatedSessionCreateCalls: Set<Int> = [],
        sessionCreateError: AppRepositoryError? = nil,
        normalizesTaskTitles: Bool = false,
        commitsTaskUpdateBeforeGate: Bool = false,
        staleRuntimeSnapshot: AppSnapshot? = nil
    ) {
        self.snapshot = snapshot
        self.failuresRemaining = failuresRemaining
        self.attachmentFailuresRemaining = attachmentFailuresRemaining
        self.ambiguousAttachmentFailuresRemaining = ambiguousAttachmentFailuresRemaining
        self.ambiguousDeleteFailuresRemaining = ambiguousDeleteFailuresRemaining
        self.ambiguousCreateListFailuresRemaining = ambiguousCreateListFailuresRemaining
        self.deleteError = deleteError
        self.updateDelay = updateDelay
        self.gatedUpdateCalls = gatedUpdateCalls
        self.gatedAttachmentCalls = gatedAttachmentCalls
        self.gatedSyncCalls = gatedSyncCalls
        self.gatedDeleteCalls = gatedDeleteCalls
        self.gatedSessionCreateCalls = gatedSessionCreateCalls
        self.sessionCreateError = sessionCreateError
        self.normalizesTaskTitles = normalizesTaskTitles
        self.commitsTaskUpdateBeforeGate = commitsTaskUpdateBeforeGate
        self.staleRuntimeSnapshot = staleRuntimeSnapshot
    }

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot {
        syncAttempts += 1
        let call = syncAttempts
        startedSyncCalls.insert(call)
        let waiters = syncStartWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if gatedSyncCalls.contains(call) {
            await withCheckedContinuation { continuation in
                syncReleaseContinuations[call] = continuation
            }
        }
        return snapshot
    }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createList(name: String, color: String) async throws -> AppSnapshot { snapshot }

    func createTask(
        title: String,
        note: String,
        listID: UUID?,
        executionDate: LocalDay?,
        dueDate: LocalDay?
    ) async throws -> AppSnapshot {
        creates.append(TaskCreateObservation(executionDate: executionDate, dueDate: dueDate))
        snapshot.tasks.append(
            TaskItem(
                id: UUID(),
                listID: listID,
                title: title,
                note: note,
                status: .open,
                executionDate: executionDate,
                dueDate: dueDate,
                completedAt: nil,
                createdAt: .now,
                updatedAt: ""
            )
        )
        snapshot.revision += 1
        return snapshot
    }

    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot {
        activeUpdates += 1
        maxActiveUpdates = max(maxActiveUpdates, activeUpdates)
        defer { activeUpdates -= 1 }
        updateAttempts += 1
        let call = updateAttempts
        startedUpdateCalls.insert(call)
        let waiters = updateStartWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        updates.append(patch)

        let storedPatch = normalizedPatch(patch)
        var committed = false
        if commitsTaskUpdateBeforeGate, failuresRemaining == 0 {
            try applyTaskPatch(storedPatch, taskID: taskID)
            committed = true
        }
        if gatedUpdateCalls.contains(call) {
            await withCheckedContinuation { continuation in
                updateReleaseContinuations[call] = continuation
            }
        }
        if updateDelay != .zero { try await Task.sleep(for: updateDelay) }
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
        if committed == false {
            try applyTaskPatch(storedPatch, taskID: taskID)
        }
        return snapshot
    }

    func deleteTask(taskID: UUID) async throws -> AppSnapshot {
        deleteAttempts += 1
        let call = deleteAttempts
        startedDeleteCalls.insert(call)
        let waiters = deleteStartWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if gatedDeleteCalls.contains(call) {
            await withCheckedContinuation { continuation in
                deleteReleaseContinuations[call] = continuation
            }
        }
        if let deleteError { throw deleteError }
        guard snapshot.tasks.contains(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks.removeAll(where: { $0.id == taskID })
        snapshot.revision += 1
        if ambiguousDeleteFailuresRemaining > 0 {
            ambiguousDeleteFailuresRemaining -= 1
            throw EngineClientError.processExited(17)
        }
        return snapshot
    }

    func createListFromTask(taskID: UUID) async throws -> AppSnapshot {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        let list = TodoList(
            id: UUID(),
            name: snapshot.tasks[index].title,
            colorName: "blue",
            repositoryPath: nil
        )
        snapshot.lists.append(list)
        snapshot.tasks[index].listID = list.id
        snapshot.revision += 1
        if ambiguousCreateListFailuresRemaining > 0 {
            ambiguousCreateListFailuresRemaining -= 1
            throw EngineClientError.timedOut("task.create_list")
        }
        return snapshot
    }

    func addTaskAttachments(
        taskID: UUID,
        sourcePaths: [String],
        clientMutationID: UUID
    ) async throws -> AppSnapshot {
        _ = await beginAttachmentMutation()
        attachmentMutationIDs.append(clientMutationID)
        if completedAttachmentMutationIDs.contains(clientMutationID) {
            return snapshot
        }
        if attachmentFailuresRemaining > 0 {
            attachmentFailuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        for sourcePath in sourcePaths {
            let name = URL(fileURLWithPath: sourcePath).lastPathComponent
            snapshot.tasks[index].attachments.append(
                TaskAttachment(
                    id: UUID(),
                    taskID: taskID,
                    originalName: name,
                    sizeBytes: 42,
                    mimeType: "application/octet-stream",
                    relativePath: "Attachments/\(UUID().uuidString)-\(name)",
                    createdAt: "2026-08-09T00:00:00Z"
                )
            )
        }
        snapshot.revision += 1
        completedAttachmentMutationIDs.insert(clientMutationID)
        if ambiguousAttachmentFailuresRemaining > 0 {
            ambiguousAttachmentFailuresRemaining -= 1
            throw EngineClientError.processExited(17)
        }
        return snapshot
    }

    func removeTaskAttachment(
        taskID: UUID,
        attachmentID: UUID,
        clientMutationID: UUID
    ) async throws -> AppSnapshot {
        _ = await beginAttachmentMutation()
        attachmentMutationIDs.append(clientMutationID)
        if completedAttachmentMutationIDs.contains(clientMutationID) {
            return snapshot
        }
        if attachmentFailuresRemaining > 0 {
            attachmentFailuresRemaining -= 1
            throw AppRepositoryError.runtimeUnavailable
        }
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks[index].attachments.removeAll(where: { $0.id == attachmentID })
        snapshot.revision += 1
        completedAttachmentMutationIDs.insert(clientMutationID)
        if ambiguousAttachmentFailuresRemaining > 0 {
            ambiguousAttachmentFailuresRemaining -= 1
            throw EngineClientError.processExited(17)
        }
        return snapshot
    }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot {
        try await updateTask(taskID: taskID, patch: TaskPatch(status: completed ? .completed : .open))
    }
    func detectRuntimes() async throws -> AppSnapshot { staleRuntimeSnapshot ?? snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }
    func session(taskID: UUID) async throws -> SessionBundle? { nil }
    func createSession(
        taskID: UUID,
        runtime: RuntimeKind,
        workspace: String
    ) async throws -> SessionBundle {
        sessionCreates += 1
        let call = sessionCreates
        startedSessionCreateCalls.insert(call)
        let waiters = sessionCreateStartWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if gatedSessionCreateCalls.contains(call) {
            await withCheckedContinuation { continuation in
                sessionCreateReleaseContinuations[call] = continuation
            }
        }
        if let sessionCreateError { throw sessionCreateError }
        let session = TaskSessionDescriptor(
            id: "task-session-\(call)",
            taskID: taskID,
            runtimeKind: runtime,
            workingDirectory: workspace,
            providerSessionID: nil,
            providerEngine: nil,
            state: .idle,
            lastAgentSequence: 0,
            lastReadSequence: 0,
            lastErrorCode: nil,
            lastErrorMessage: nil,
            createdAt: "2026-08-09T00:00:00Z",
            updatedAt: "2026-08-09T00:00:00Z"
        )
        snapshot.sessions.removeAll(where: { $0.taskID == taskID })
        snapshot.sessions.append(session)
        snapshot.revision += 1
        return SessionBundle(session: session, messages: [], activeTurn: nil)
    }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {}
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult { .init(ok: true, model: model, displayName: "", version: "") }
    func assistantStatus() async throws -> AssistantStatus { .init(configured: false, available: false, model: nil, reason: nil) }
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] { [] }
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func sendAssistantMessage(sessionID: String, clientMessageID: UUID, text: String, model: String, attachments: [AssistantTextAttachment]) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async { shutdowns += 1 }

    func createCalls() -> [TaskCreateObservation] { creates }
    func updateCallCount() -> Int { updates.count }
    func attachmentCallCount() -> Int { attachmentAttempts }
    func uniqueAttachmentMutationIDCount() -> Int { Set(attachmentMutationIDs).count }
    func syncCallCount() -> Int { syncAttempts }
    func sessionCreateCallCount() -> Int { sessionCreates }
    func maximumConcurrentUpdates() -> Int { maxActiveUpdates }
    func shutdownCallCount() -> Int { shutdowns }
    func persistedTask(id: UUID) -> TaskItem? { snapshot.tasks.first(where: { $0.id == id }) }
    func replaceSnapshot(_ replacement: AppSnapshot) { snapshot = replacement }

    func waitUntilUpdateStarted(_ call: Int) async {
        guard !startedUpdateCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            updateStartWaiters[call, default: []].append(continuation)
        }
    }

    func releaseUpdate(_ call: Int) {
        updateReleaseContinuations.removeValue(forKey: call)?.resume()
    }

    func waitUntilAttachmentStarted(_ call: Int) async {
        guard !startedAttachmentCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            attachmentStartWaiters[call, default: []].append(continuation)
        }
    }

    func releaseAttachment(_ call: Int) {
        attachmentReleaseContinuations.removeValue(forKey: call)?.resume()
    }

    func waitUntilSyncStarted(_ call: Int) async {
        guard !startedSyncCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            syncStartWaiters[call, default: []].append(continuation)
        }
    }

    func releaseSync(_ call: Int) {
        syncReleaseContinuations.removeValue(forKey: call)?.resume()
    }

    func waitUntilDeleteStarted(_ call: Int) async {
        guard !startedDeleteCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            deleteStartWaiters[call, default: []].append(continuation)
        }
    }

    func releaseDelete(_ call: Int) {
        deleteReleaseContinuations.removeValue(forKey: call)?.resume()
    }

    func waitUntilSessionCreateStarted(_ call: Int) async {
        guard !startedSessionCreateCalls.contains(call) else { return }
        await withCheckedContinuation { continuation in
            sessionCreateStartWaiters[call, default: []].append(continuation)
        }
    }

    func releaseSessionCreate(_ call: Int) {
        sessionCreateReleaseContinuations.removeValue(forKey: call)?.resume()
    }

    private func normalizedPatch(_ patch: TaskPatch) -> TaskPatch {
        guard normalizesTaskTitles, let title = patch.title else { return patch }
        var normalized = patch
        normalized.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private func applyTaskPatch(_ patch: TaskPatch, taskID: UUID) throws {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw AppRepositoryError.taskNotFound
        }
        snapshot.tasks[index].apply(patch)
        snapshot.revision += 1
    }

    private func beginAttachmentMutation() async -> Int {
        attachmentAttempts += 1
        let call = attachmentAttempts
        startedAttachmentCalls.insert(call)
        let waiters = attachmentStartWaiters.removeValue(forKey: call) ?? []
        for waiter in waiters { waiter.resume() }
        if gatedAttachmentCalls.contains(call) {
            await withCheckedContinuation { continuation in
                attachmentReleaseContinuations[call] = continuation
            }
        }
        return call
    }
}
