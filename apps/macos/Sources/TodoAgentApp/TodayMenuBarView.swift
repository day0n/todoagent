import AppKit
import SwiftUI

struct TodayMenuBarProjection: Equatable, Sendable {
    let tasks: [TaskItem]

    init(tasks: [TaskItem], now: Date = .now, calendar: Calendar = .current) {
        self.tasks = tasks.filter { task in
            guard task.status == .open, let dueDate = task.dueDate else { return false }
            return calendar.isDate(dueDate, inSameDayAs: now)
        }
    }
}

struct TodayMenuBarView: View {
    let state: AppState

    @Environment(\.calendar) private var calendar
    @Environment(\.openWindow) private var openWindow

    private var projection: TodayMenuBarProjection {
        TodayMenuBarProjection(tasks: state.tasks, calendar: calendar)
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
                .accessibilityLabel("今日未完成任务 \(projection.tasks.count) 项")
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
                Text("今天没有未完成任务")
                    .font(.callout.weight(.medium))
                Text("可以安心开始新的一天。")
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 108)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("menubar.today.empty")

        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(projection.tasks) { task in
                        taskRow(task)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
    }

    private func taskRow(_ task: TaskItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle")
                .font(.callout)
                .foregroundStyle(TodoAgentUI.secondaryText)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TodoAgentUI.primaryText)
                    .lineLimit(2)
                Text("未完成")
                    .font(.caption)
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(task.title)，未完成")
        .accessibilityIdentifier("menubar.today.task.\(task.id.uuidString)")
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

struct TodoAgentMainWindowMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> MainWindowMarkerView {
        MainWindowMarkerView()
    }

    func updateNSView(_ nsView: MainWindowMarkerView, context: Context) {}
}

final class MainWindowMarkerView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.identifier = NSUserInterfaceItemIdentifier(TodoAgentMainWindow.identifier)
    }
}
