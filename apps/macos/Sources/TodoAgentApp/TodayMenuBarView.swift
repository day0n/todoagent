import AppKit
import SwiftUI

struct TodayMenuBarProjection: Equatable, Sendable {
    let tasks: [TaskItem]

    init(todayTasks: [TaskItem]) {
        tasks = todayTasks
    }

    init(tasks: [TaskItem], now: Date = .now, calendar: Calendar = .todoAgentLocal) {
        let today = LocalDay(date: now, calendar: calendar)
        self.init(todayTasks: TaskProjection(tasks: tasks, today: today).todayTasks())
    }
}

/// The menu-bar popover cannot infer a useful ideal height from a ScrollView.
/// Giving the real task region a finite, nonzero height prevents the rows from
/// collapsing while still capping long lists.
enum TodayMenuBarTaskAreaMetrics {
    static let rowHeight: CGFloat = 52
    static let minimumHeight: CGFloat = 52
    static let maximumHeight: CGFloat = 300

    static func height(taskCount: Int) -> CGFloat {
        min(max(CGFloat(taskCount) * rowHeight, minimumHeight), maximumHeight)
    }
}

struct TodayMenuBarView: View {
    let state: AppState

    @Environment(\.openWindow) private var openWindow

    private var projection: TodayMenuBarProjection {
        TodayMenuBarProjection(todayTasks: state.todayTasks())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            content
                .padding(.vertical, 8)

            Divider()
            openAppButton
                .padding(.top, 8)
        }
        .padding(14)
        .frame(width: 340)
        .background(TodoAgentUI.surfaceBackground)
        .task { await state.load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("今日任务")
                    .font(.headline)
                Text(Date.now.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }

            Spacer()

            Text("\(projection.tasks.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(TodoAgentUI.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(TodoAgentUI.selectionBackground, in: .capsule)
                .accessibilityLabel("今日任务 \(projection.tasks.count) 项")
        }
        .padding(.bottom, 10)
        .accessibilityIdentifier("menubar.today.header")
    }

    @ViewBuilder
    private var content: some View {
        switch state.loadState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("正在载入今日任务…")
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menubar.today.loading")

        case let .failed(message):
            VStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                Text("暂时无法载入任务")
                    .font(.callout.weight(.medium))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menubar.today.error")

        case .loaded where projection.tasks.isEmpty:
            VStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("今天还没有安排")
                    .font(.callout.weight(.medium))
                Text("在时间线中安排任务后会显示在这里。")
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menubar.today.empty")

        case .loaded:
            TodayMenuTaskList(tasks: projection.tasks) { task in
                state.openTask(task)
                TodoAgentMainWindow.show(using: openWindow)
            }
        }
    }

    private var openAppButton: some View {
        Button {
            TodoAgentMainWindow.show(using: openWindow)
        } label: {
            Label("打开 TodoAgent", systemImage: "macwindow")
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contentShape(.rect)
        .help("打开 TodoAgent 主窗口")
        .accessibilityHint("激活已有主窗口，或在主窗口已关闭时重新打开")
        .accessibilityIdentifier("menubar.open-main-window")
    }
}

/// Internal so the AppKit hosting/layout regression test exercises the same
/// SwiftUI tree that ships in MenuBarExtra.
struct TodayMenuTaskList: View {
    let tasks: [TaskItem]
    var onOpen: (TaskItem) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(tasks) { task in
                    Button {
                        onOpen(task)
                    } label: {
                        TodayMenuTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(
            minHeight: TodayMenuBarTaskAreaMetrics.minimumHeight,
            idealHeight: TodayMenuBarTaskAreaMetrics.height(taskCount: tasks.count),
            maxHeight: TodayMenuBarTaskAreaMetrics.height(taskCount: tasks.count)
        )
        .accessibilityIdentifier("menubar.today.task-list")
    }
}

private struct TodayMenuTaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.callout)
                .foregroundStyle(task.status == .completed ? Color.green : TodoAgentUI.secondaryText)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .strikethrough(task.status == .completed)
                    .lineLimit(2)
                Text(task.status.title)
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: TodayMenuBarTaskAreaMetrics.rowHeight, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.title)，\(task.status.title)")
        .accessibilityIdentifier("menubar.today.task.\(task.id.uuidString)")
    }
}

enum TodoAgentMainWindow {
    static let sceneID = "todoagent-main"
    static let identifier = "org.niuzj.todoagent.main-window"

    @MainActor
    static func show(using openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: sceneID)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Versioned once-per-install placement fixes the oversized legacy default
/// without fighting the user's later window moves or resizes. SwiftUI's
/// `.defaultPosition(.center)` covers new installs; this migration also covers
/// an existing install whose restored frame still fills most of the display.
enum TodoAgentMainWindowPlacement {
    static let layoutVersion = 1
    static let appliedVersionKey = "TodoAgentMainWindowCenteredLayoutVersion"
    static let preferredContentSize = CGSize(width: 1_120, height: 720)
    static let minimumContentSize = CGSize(width: 760, height: 560)
    static let maximumVisibleFraction: CGFloat = 0.82

    static func contentSize(for visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(
                preferredContentSize.width,
                max(minimumContentSize.width, visibleFrame.width * maximumVisibleFraction)
            ),
            height: min(
                preferredContentSize.height,
                max(minimumContentSize.height, visibleFrame.height * maximumVisibleFraction)
            )
        )
    }
}

struct TodoAgentMainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowMarkerView {
        MainWindowMarkerView()
    }

    func updateNSView(_ nsView: MainWindowMarkerView, context: Context) {}
}

final class MainWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(TodoAgentMainWindow.identifier)

        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: TodoAgentMainWindowPlacement.appliedVersionKey)
            < TodoAgentMainWindowPlacement.layoutVersion,
            let visibleFrame = window.screen?.visibleFrame
        else { return }

        window.setContentSize(TodoAgentMainWindowPlacement.contentSize(for: visibleFrame))
        window.center()
        defaults.set(
            TodoAgentMainWindowPlacement.layoutVersion,
            forKey: TodoAgentMainWindowPlacement.appliedVersionKey
        )
    }
}
