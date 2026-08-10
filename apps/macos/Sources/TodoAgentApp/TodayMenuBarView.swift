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

/// Keeps the menu compact for short lists and introduces a scroll container
/// only after ten rows. A fixed row height makes the 10/11-task boundary
/// deterministic instead of relying on the popover's intrinsic sizing.
enum TodayMenuBarTaskAreaMetrics {
    static let rowHeight: CGFloat = 42
    static let rowSpacing: CGFloat = 2
    static let maximumVisibleTaskCount = 10

    static func height(taskCount: Int) -> CGFloat {
        let visibleTaskCount = min(max(taskCount, 0), maximumVisibleTaskCount)
        guard visibleTaskCount > 0 else { return 0 }
        return CGFloat(visibleTaskCount) * rowHeight
            + CGFloat(visibleTaskCount - 1) * rowSpacing
    }

    static func requiresScrolling(taskCount: Int) -> Bool {
        taskCount > maximumVisibleTaskCount
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
                .padding(.vertical, 6)

            Divider()
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 304)
        .background(.regularMaterial)
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
        .padding(.bottom, 8)
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

    private var actions: some View {
        VStack(spacing: 0) {
            TodayMenuBarActionButton(
                title: "Open TodoAgent",
                accessibilityIdentifier: "menubar.open-main-window"
            ) {
                TodoAgentMainWindow.show(using: openWindow)
            }
            .help("打开 TodoAgent 主窗口")
            .accessibilityHint("激活已有主窗口，或在主窗口已关闭时重新打开")

            Divider()

            TodayMenuBarActionButton(
                title: "Quit TodoAgent",
                accessibilityIdentifier: "menubar.quit"
            ) {
                NSApp.terminate(nil)
            }
            .help("退出 TodoAgent")
        }
        .padding(.top, 4)
    }
}

private struct TodayMenuBarActionButton: View {
    let title: String
    let accessibilityIdentifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .foregroundStyle(TodoAgentUI.primaryText)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                .padding(.horizontal, 6)
                .background(
                    isHovering ? TodoAgentUI.selectionBackground : .clear,
                    in: .rect(cornerRadius: 6)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

/// Internal so the AppKit hosting/layout regression test exercises the same
/// SwiftUI tree that ships in MenuBarExtra.
struct TodayMenuTaskList: View {
    let tasks: [TaskItem]
    var onOpen: (TaskItem) -> Void = { _ in }

    var body: some View {
        Group {
            if TodayMenuBarTaskAreaMetrics.requiresScrolling(taskCount: tasks.count) {
                ScrollView(.vertical) {
                    rows
                }
                .scrollIndicators(.visible)
            } else {
                rows
            }
        }
        .frame(height: TodayMenuBarTaskAreaMetrics.height(taskCount: tasks.count))
        .accessibilityIdentifier("menubar.today.task-list")
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: TodayMenuBarTaskAreaMetrics.rowSpacing) {
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
}

private struct TodayMenuTaskRow: View {
    let task: TaskItem

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.subheadline)
                .foregroundStyle(task.status == .completed ? Color.green : TodoAgentUI.secondaryText)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 0) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .strikethrough(task.status == .completed)
                    .lineLimit(1)
                Text(task.status.title)
                    .font(.caption2)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: TodayMenuBarTaskAreaMetrics.rowHeight,
            maxHeight: TodayMenuBarTaskAreaMetrics.rowHeight,
            alignment: .leading
        )
        .background(
            isHovering ? TodoAgentUI.selectionBackground : .clear,
            in: .rect(cornerRadius: 6)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
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
/// without fighting the user's later window moves or resizes. New and migrated
/// windows are horizontally centered at the usable screen's top edge.
enum TodoAgentMainWindowPlacement {
    static let layoutVersion = 3
    static let appliedVersionKey = "TodoAgentMainWindowCenteredLayoutVersion"
    // Keep launch sizing independent from the live SwiftUI layout graph. The
    // value matches a 260-point sidebar plus three complete 270-point day
    // columns, their gaps, and the board padding.
    static let preferredTimelineWidth: CGFloat = 854
    static let preferredContentSize = CGSize(width: 1_114, height: 820)
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

    /// Mirrors compact desktop tools: horizontally centered, touching the
    /// usable screen's top edge, with breathing room left below the window.
    static func windowOrigin(
        for windowFrameSize: CGSize,
        in visibleFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: visibleFrame.midX - (windowFrameSize.width / 2),
            y: visibleFrame.maxY - windowFrameSize.height
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
    private var placementScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier(TodoAgentMainWindow.identifier)

        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: TodoAgentMainWindowPlacement.appliedVersionKey)
            < TodoAgentMainWindowPlacement.layoutVersion,
            !placementScheduled
        else { return }

        placementScheduled = true

        // viewDidMoveToWindow runs while SwiftUI is still resolving its initial
        // window preferences. Mutating the frame synchronously here re-enters
        // that preference graph and can trip AttributeGraph's recursion guard.
        // Yield once, then apply a single AppKit frame mutation.
        Task { @MainActor [weak self, weak window] in
            await Task.yield()
            guard let self, let window, self.window === window else {
                self?.placementScheduled = false
                return
            }

            let defaults = UserDefaults.standard
            guard defaults.integer(forKey: TodoAgentMainWindowPlacement.appliedVersionKey)
                < TodoAgentMainWindowPlacement.layoutVersion,
                let visibleFrame = window.screen?.visibleFrame
            else { return }

            let contentSize = TodoAgentMainWindowPlacement.contentSize(for: visibleFrame)
            let frameSize = window.frameRect(
                forContentRect: CGRect(origin: .zero, size: contentSize)
            ).size
            let targetFrame = CGRect(
                origin: TodoAgentMainWindowPlacement.windowOrigin(
                    for: frameSize,
                    in: visibleFrame
                ),
                size: frameSize
            )

            window.setFrame(targetFrame, display: true)
            defaults.set(
                TodoAgentMainWindowPlacement.layoutVersion,
                forKey: TodoAgentMainWindowPlacement.appliedVersionKey
            )
        }
    }
}
