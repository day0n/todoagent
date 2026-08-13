import AppKit
import Observation
import SwiftUI

@MainActor
protocol TaskWorkspacePresenting: AnyObject {
    func showTaskWorkspace(taskID: UUID)
    func closeTaskWorkspace(taskID: UUID)
    func destroyTaskWorkspace(taskID: UUID)
    func commitTaskWorkspaceInput()
}

@MainActor
@Observable
final class TaskWorkbenchLayoutState {
    static let minimumDetailsWidth: CGFloat = 300
    static let idealDetailsWidth: CGFloat = 330
    static let maximumDetailsWidth: CGFloat = 420

    private(set) var detailsPresented = true
    private(set) var detailsWidth = idealDetailsWidth

    func toggleDetails() {
        detailsPresented.toggle()
    }

    func recordDetailsWidth(_ proposedWidth: CGFloat) {
        detailsWidth = min(
            max(proposedWidth, Self.minimumDetailsWidth),
            Self.maximumDetailsWidth
        )
    }
}

@MainActor
final class TaskWorkbenchWindowRegistry: TaskWorkspacePresenting {
    private let state: AppState
    private let terminalSessions: TerminalSessionRegistry
    private var controllers: [UUID: TaskWorkbenchWindowController] = [:]

    init(state: AppState, terminalSessions: TerminalSessionRegistry) {
        self.state = state
        self.terminalSessions = terminalSessions
    }

    func showTaskWorkspace(taskID: UUID) {
        guard let task = state.task(id: taskID) else { return }
        if let existing = controllers[taskID] {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            Task { @MainActor [weak self] in
                await self?.terminalSessions.resumeIfNeeded(
                    taskID: taskID,
                    taskTitle: task.title
                )
            }
            return
        }

        let controller = TaskWorkbenchWindowController(
            taskID: taskID,
            state: state,
            terminalSessions: terminalSessions
        )
        controllers[taskID] = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeTaskWorkspace(taskID: UUID) {
        controllers[taskID]?.requestClose()
    }

    func destroyTaskWorkspace(taskID: UUID) {
        closeImmediately(taskID: taskID)
    }

    func commitTaskWorkspaceInput() {
        for controller in controllers.values {
            controller.commitInput()
        }
    }

    func closeImmediately(taskID: UUID) {
        controllers[taskID]?.closeImmediately()
        controllers[taskID] = nil
    }

    func contains(taskID: UUID) -> Bool { controllers[taskID] != nil }

    func focusActiveTerminal() {
        let activeTaskID = controllers.first(where: { $0.value.window?.isKeyWindow == true })?.key
        guard let activeTaskID else { return }
        terminalSessions.controller(for: activeTaskID)?.focusIfAppropriate()
    }

    func performTerminalAction(_ action: String) {
        let activeTaskID = controllers.first(where: { $0.value.window?.isKeyWindow == true })?.key
        guard let activeTaskID else { return }
        terminalSessions.controller(for: activeTaskID)?.performAction(action)
    }

    @discardableResult
    func toggleActiveTaskDetails() -> Bool {
        guard let controller = controllers.values.first(where: { $0.window?.isKeyWindow == true }) else {
            return false
        }
        controller.requestTaskDetailsToggle()
        return true
    }
}

@MainActor
final class TaskWorkbenchWindowController: NSWindowController, NSWindowDelegate {
    static let defaultContentSize = CGSize(width: 1_180, height: 760)
    static let minimumContentSize = CGSize(width: 900, height: 600)

    let taskID: UUID
    private let state: AppState
    private let terminalSessions: TerminalSessionRegistry
    private let layoutState = TaskWorkbenchLayoutState()
    private var closeInFlight = false
    private var authorizedClose = false
    private var detailsToggleInFlight = false

    init(
        taskID: UUID,
        state: AppState,
        terminalSessions: TerminalSessionRegistry
    ) {
        self.taskID = taskID
        self.state = state
        self.terminalSessions = terminalSessions

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier("TodoAgentTaskWorkbench-\(taskID.uuidString)")
        window.title = state.task(id: taskID)?.title ?? "任务工作台"
        window.minSize = Self.minimumContentSize
        window.toolbarStyle = .unifiedCompact
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.contentViewController = NSHostingController(
            rootView: TaskWorkbenchView(
                taskID: taskID,
                state: state,
                terminalSessions: terminalSessions,
                layoutState: layoutState,
                toggleTaskDetails: { [weak self] in self?.requestTaskDetailsToggle() },
                requestClose: { [weak self] in self?.requestClose() }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }

    func requestClose() {
        window?.performClose(nil)
    }

    func closeImmediately() {
        authorizedClose = true
        window?.close()
    }

    func commitInput() {
        terminalSessions.controller(for: taskID)?.surfaceCommitComposition()
        window?.endEditing(for: nil)
        window?.makeFirstResponder(nil)
    }

    func requestTaskDetailsToggle() {
        guard !detailsToggleInFlight else { return }
        guard layoutState.detailsPresented else {
            layoutState.toggleDetails()
            terminalSessions.controller(for: taskID)?.focusIfAppropriate()
            return
        }

        detailsToggleInFlight = true
        commitInput()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: self.taskID)
            self.detailsToggleInFlight = false
            guard saved else { return }
            self.layoutState.toggleDetails()
            self.terminalSessions.controller(for: self.taskID)?.focusIfAppropriate()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !authorizedClose else { return true }
        guard !closeInFlight else { return false }
        closeInFlight = true
        Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            self.commitInput()
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: self.taskID)
            self.closeInFlight = false
            guard saved else {
                sender.makeKeyAndOrderFront(nil)
                return
            }
            sender.orderOut(nil)
        }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        terminalSessions.controller(for: taskID)?.focusIfAppropriate()
        guard let title = state.task(id: taskID)?.title else { return }
        window?.title = title
    }

}

struct TaskWorkbenchView: View {
    let taskID: UUID
    let state: AppState
    let terminalSessions: TerminalSessionRegistry
    let layoutState: TaskWorkbenchLayoutState
    let toggleTaskDetails: () -> Void
    let requestClose: () -> Void

    @State private var isStarting = false
    @State private var terminalController: TerminalSessionController?
    @State private var isLoadingSession = false
    @State private var isRebindingWorkspace = false
    @State private var workspaceRebindError: String?

    var body: some View {
        Group {
            if let task = state.task(id: taskID) {
                TaskWorkbenchContent(
                    task: task,
                    state: state,
                    layoutState: layoutState,
                    terminalPane: { terminalPane($0) }
                )
            } else {
                ContentUnavailableView(
                    "任务已不存在",
                    systemImage: "questionmark.folder",
                    description: Text("这个任务已被删除。")
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .disabled(state.isPreparingToTerminate)
        .accessibilityIdentifier("task.workbench.\(taskID.uuidString)")
        .task(id: taskID) { await loadTerminalController() }
        .alert(
            "无法重新定位工作目录",
            isPresented: Binding(
                get: { workspaceRebindError != nil },
                set: { if !$0 { workspaceRebindError = nil } }
            )
        ) {
            Button("好", role: .cancel) { workspaceRebindError = nil }
        } message: {
            Text(workspaceRebindError ?? "")
        }
    }

    @ViewBuilder
    private func terminalPane(_ task: TaskItem) -> some View {
        if let terminalController {
            VStack(spacing: 0) {
                TaskTerminalToolbar(
                    task: task,
                    controller: terminalController,
                    detailsPresented: layoutState.detailsPresented,
                    toggleTaskDetails: toggleTaskDetails,
                    close: requestClose,
                    resumeSession: {
                        resume(terminalController, task: task)
                    },
                    endSession: {
                        Task {
                            await terminalSessions.endRetaining(taskID: taskID, reason: .userEnded)
                        }
                    }
                )
                Divider()
                if terminalController.hasLiveSurface {
                    TerminalSurfaceContainer(controller: terminalController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if terminalController.phase.isActive {
                    TaskTerminalLaunchingPane(controller: terminalController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TaskTerminalEndedPane(
                        task: task,
                        controller: terminalController,
                        resume: {
                            resume(terminalController, task: task)
                        },
                        relocateWorkspace: {
                            relocateWorkspace(terminalController, task: task)
                        },
                        isRebindingWorkspace: isRebindingWorkspace,
                        chooseCandidate: { candidate in
                            Task {
                                await terminalSessions.bindAndResume(
                                    candidate,
                                    controller: terminalController,
                                    taskTitle: task.title
                                )
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                TaskTerminalStatusBar(controller: terminalController)
            }
        } else if isLoadingSession {
            ProgressView("正在载入本地终端…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TaskSessionSetupView(
                task: task,
                state: state,
                isClosing: false,
                isStarting: $isStarting,
                flushTaskEdits: { await state.flushTaskEdits(taskID: taskID) },
                onClose: requestClose
            )
            .onChange(of: isStarting) { wasStarting, nowStarting in
                if wasStarting, !nowStarting {
                    terminalController = terminalSessions.controller(for: taskID)
                }
            }
        }
    }

    private func loadTerminalController() async {
        if let existing = terminalSessions.controller(for: taskID) {
            terminalController = existing
            if !existing.hasLiveSurface,
               !existing.phase.isActive,
               let task = state.task(id: taskID) {
                await terminalSessions.resumeIfNeeded(taskID: taskID, taskTitle: task.title)
            }
            return
        }
        isLoadingSession = true
        defer { isLoadingSession = false }
        do {
            terminalController = try await terminalSessions.load(taskID: taskID)
            if terminalController?.view == nil, let task = state.task(id: taskID) {
                if let terminalController {
                    await terminalSessions.resumeOrLaunch(terminalController, taskTitle: task.title)
                }
            }
        } catch {
            state.errorMessage = error.localizedDescription
        }
    }

    private func resume(_ controller: TerminalSessionController, task: TaskItem) {
        Task { @MainActor in
            await terminalSessions.resumeOrLaunch(controller, taskTitle: task.title)
        }
    }

    private func relocateWorkspace(_ controller: TerminalSessionController, task: TaskItem) {
        guard !isRebindingWorkspace else { return }
        isRebindingWorkspace = true
        workspaceRebindError = nil
        Task { @MainActor in
            defer { isRebindingWorkspace = false }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = false
            panel.title = "重新定位 Agent 工作目录"
            panel.message = "原目录已移动或删除。请选择这个项目现在所在的目录；原 Provider 对话绑定会保留。"
            panel.prompt = "重新定位并恢复"
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                try WorkspaceAuthorizationStore.save(url)
                try await terminalSessions.rebindWorkspaceAndResume(
                    url.path(percentEncoded: false),
                    controller: controller,
                    taskTitle: task.title
                )
            } catch is CancellationError {
                return
            } catch {
                workspaceRebindError = error.localizedDescription
            }
        }
    }
}

private struct TaskTerminalLaunchingPane: View {
    let controller: TerminalSessionController

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(controller.phase.title)
                .font(.headline)
            Text("正在启动本机 \(controller.session.runtimeKind.title)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .accessibilityIdentifier("task.terminal.launching")
    }
}

private struct TaskTerminalEndedPane: View {
    let task: TaskItem
    let controller: TerminalSessionController
    let resume: () -> Void
    let relocateWorkspace: () -> Void
    let isRebindingWorkspace: Bool
    let chooseCandidate: (TerminalResumeCandidate) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text(heading)
                .font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            if !controller.workingDirectoryIsAvailable {
                VStack(spacing: 10) {
                    Button("重新定位工作目录", systemImage: "folder.badge.questionmark") {
                        relocateWorkspace()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRebindingWorkspace)
                    if isRebindingWorkspace {
                        ProgressView("正在重新绑定并恢复…")
                            .controlSize(.small)
                    }
                    Text("会保留这个任务绑定的 \(controller.session.runtimeKind.title) Provider 对话；TodoAgent 不会自动猜测同名目录。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
            } else if controller.isLoadingResumeCandidates {
                ProgressView("正在查找这个工作目录的会话…")
            } else if controller.requiresProviderSelection,
                      controller.didLoadResumeCandidates,
                      !controller.resumeCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("选择要永久绑定的 Provider 会话")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(controller.resumeCandidates) { candidate in
                        Button {
                            chooseCandidate(candidate)
                        } label: {
                            HStack {
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.providerSessionID)
                                        .font(.system(.callout, design: .monospaced))
                                    if let createdAt = candidate.createdAt {
                                        Text(createdAt)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 560)
            } else {
                Button(controller.requiresProviderSelection ? "查找可恢复会话" : "恢复会话") {
                    resume()
                }
                .buttonStyle(.borderedProminent)
            }

            if controller.requiresProviderSelection,
               controller.didLoadResumeCandidates,
               controller.resumeCandidates.isEmpty,
               !controller.isLoadingResumeCandidates {
                Text(controller.resumeErrorMessage ?? "没有找到可精确确认的会话。TodoAgent 不会猜测“最近会话”；请先用该 Agent 在此目录创建会话后重试。")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
        }
        .padding(40)
        .accessibilityIdentifier("task.terminal.ended")
    }

    private var heading: String {
        if !controller.workingDirectoryIsAvailable { return "原工作目录已移动或删除" }
        if case .failed = controller.phase { return "终端启动失败" }
        if controller.activeRun == nil { return "终端尚未启动" }
        return "Agent 已退出"
    }

    private var detail: String {
        if !controller.workingDirectoryIsAvailable {
            return "这个 Session 原来绑定到 \(controller.session.workingDirectory)。请选择项目现在所在的目录后继续原对话。"
        }
        if case let .failed(message) = controller.phase { return message }
        if controller.activeRun == nil {
            return "启动后 \(controller.session.runtimeKind.title) 将直接在所选目录中运行，不会自动发送任务标题、备注或附件。"
        }
        if controller.requiresProviderSelection {
            return "恢复前需要确认 \(controller.session.runtimeKind.title) 的原会话。绑定后这个任务将始终恢复同一段对话。"
        }
        return "终端滚屏不会跨应用重启保存；恢复后会由 \(controller.session.runtimeKind.title) 继续原 Provider 对话。"
    }
}

private struct TaskWorkbenchContent<TerminalPane: View>: View {
    private static var resizeCoordinateSpace: String { "task-workbench-details-resize" }
    private static var terminalMinimumWidth: CGFloat { 560 }

    let task: TaskItem
    let state: AppState
    let layoutState: TaskWorkbenchLayoutState
    let terminalPane: (TaskItem) -> TerminalPane

    @State private var detailDraft: TaskDetailDraft
    @FocusState private var focusedTextField: TaskDetailTextField?

    init(
        task: TaskItem,
        state: AppState,
        layoutState: TaskWorkbenchLayoutState,
        @ViewBuilder terminalPane: @escaping (TaskItem) -> TerminalPane
    ) {
        self.task = task
        self.state = state
        self.layoutState = layoutState
        self.terminalPane = terminalPane
        _detailDraft = State(initialValue: TaskDetailDraft(task: task))
    }

    var body: some View {
        GeometryReader { proxy in
            let maximumAvailableDetailsWidth = max(
                TaskWorkbenchLayoutState.minimumDetailsWidth,
                proxy.size.width - Self.terminalMinimumWidth - TaskDetailsResizeDivider.width
            )
            let presentedWidth = min(layoutState.detailsWidth, maximumAvailableDetailsWidth)

            HStack(spacing: 0) {
                TaskDetailsPane(
                    task: task,
                    draft: $detailDraft,
                    focusedTextField: $focusedTextField,
                    state: state
                )
                .frame(width: layoutState.detailsPresented ? presentedWidth : 0)
                .clipped()
                .opacity(layoutState.detailsPresented ? 1 : 0)
                .allowsHitTesting(layoutState.detailsPresented)
                .accessibilityHidden(!layoutState.detailsPresented)

                TaskDetailsResizeDivider(
                    detailsWidth: presentedWidth,
                    isPresented: layoutState.detailsPresented,
                    coordinateSpace: Self.resizeCoordinateSpace,
                    onResize: layoutState.recordDetailsWidth
                )

                terminalPane(task)
                    .frame(
                        minWidth: Self.terminalMinimumWidth,
                        maxWidth: .infinity,
                        maxHeight: .infinity
                    )
                    .id(task.id)
            }
            .coordinateSpace(name: Self.resizeCoordinateSpace)
        }
        .onChange(of: task) { _, authoritativeTask in
            reconcileDetailDraft(with: authoritativeTask)
        }
        .onChange(of: state.taskSaveState(taskID: task.id)) { _, _ in
            guard let authoritativeTask = state.task(id: task.id) else { return }
            reconcileDetailDraft(with: authoritativeTask)
        }
        .onChange(of: focusedTextField) { _, field in
            Task { @MainActor in
                await Task.yield()
                guard focusedTextField == field else { return }
                if field == nil { _ = await state.flushTaskEdits(taskID: task.id) }
                guard let authoritativeTask = state.task(id: task.id) else { return }
                reconcileDetailDraft(with: authoritativeTask)
            }
        }
    }

    private func reconcileDetailDraft(with authoritativeTask: TaskItem) {
        let reconciled = detailDraft.reconciled(
            with: authoritativeTask,
            saveState: state.taskSaveState(taskID: task.id),
            preserving: focusedTextField
        )
        guard reconciled != detailDraft else { return }
        detailDraft = reconciled
    }
}

private struct TaskDetailsResizeDivider: View {
    static let width: CGFloat = 8

    let detailsWidth: CGFloat
    let isPresented: Bool
    let coordinateSpace: String
    let onResize: (CGFloat) -> Void

    @State private var dragStartWidth: CGFloat?
    @State private var pointerInside = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: isPresented ? Self.width : 0)
            .overlay {
                if isPresented {
                    Rectangle()
                        .fill(TodoAgentUI.hairline)
                        .frame(width: 1)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { value in
                        let start = dragStartWidth ?? detailsWidth
                        if dragStartWidth == nil { dragStartWidth = start }
                        onResize(start + value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onHover { inside in
                pointerInside = inside
                (inside && isPresented ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .onDisappear {
                if pointerInside { NSCursor.arrow.set() }
            }
            .accessibilityElement()
            .accessibilityHidden(!isPresented)
            .accessibilityLabel("调整任务详情宽度")
            .accessibilityValue("宽度 \(Int(detailsWidth)) 点")
            .accessibilityHint("左右拖动调整任务详情宽度")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onResize(detailsWidth + 24)
                case .decrement: onResize(detailsWidth - 24)
                @unknown default: break
                }
            }
    }
}

private struct TerminalSurfaceContainer: NSViewRepresentable {
    let controller: TerminalSessionController

    final class Coordinator {
        weak var controller: TerminalSessionController?

        init(controller: TerminalSessionController) {
            self.controller = controller
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> TerminalSurfaceHostView {
        context.coordinator.controller = controller
        let host = TerminalSurfaceHostView()
        controller.attach(to: host)
        return host
    }

    func updateNSView(_ nsView: TerminalSurfaceHostView, context: Context) {
        context.coordinator.controller = controller
        controller.attach(to: nsView)
    }

    static func dismantleNSView(
        _ nsView: TerminalSurfaceHostView,
        coordinator: Coordinator
    ) {
        // The owning controller remains in TerminalSessionRegistry. The surface
        // and child process must outlive SwiftUI view churn and window closes.
        coordinator.controller?.detach(from: nsView)
    }
}

private struct TaskTerminalToolbar: View {
    let task: TaskItem
    let controller: TerminalSessionController
    let detailsPresented: Bool
    let toggleTaskDetails: () -> Void
    let close: () -> Void
    let resumeSession: () -> Void
    let endSession: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(
                detailsPresented ? "隐藏任务详情" : "显示任务详情",
                systemImage: "sidebar.leading",
                action: toggleTaskDetails
            )
            .labelStyle(.iconOnly)
            .help(detailsPresented ? "隐藏任务详情（⌃⌘S）" : "显示任务详情（⌃⌘S）")
            .accessibilityValue(detailsPresented ? "已展开" : "已收起")
            .accessibilityIdentifier("task.details.toggle")

            RuntimeIconView(kind: controller.session.runtimeKind, fallbackSymbol: "terminal")
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline).lineLimit(1)
                Text("\(controller.session.runtimeKind.title) 本地终端")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(controller.phase.title, systemImage: phaseSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(controller.needsAttention ? .orange : .secondary)
            if controller.hasLiveSurface {
                Button("聚焦终端", systemImage: "cursorarrow.click") {
                    controller.focusIfAppropriate()
                }
                .labelStyle(.iconOnly)
                .help("聚焦终端")
            }
            if controller.phase.isActive {
                Button("结束 Session…", systemImage: "stop.circle", role: .destructive) {
                    confirmEndSession()
                }
                .labelStyle(.iconOnly)
                .help("结束 Session")
            } else {
                Button("恢复会话", systemImage: "arrow.clockwise.circle", action: resumeSession)
                    .labelStyle(.iconOnly)
                    .help(controller.workingDirectoryIsAvailable ? "恢复会话" : "请在中间区域重新定位工作目录")
                    .disabled(!controller.workingDirectoryIsAvailable)
            }
            Button("关闭", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .help("关闭工作台，Session 继续运行")
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.bar)
    }

    private var phaseSymbol: String {
        if controller.needsAttention { return "bell.badge.fill" }
        return controller.phase.isActive ? "circle.dotted.circle" : "terminal"
    }

    private func confirmEndSession() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "结束这个 Session？"
        alert.informativeText = "这会终止正在运行的 Agent 和它的子进程。任务不会被删除。"
        alert.addButton(withTitle: "结束 Session")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        endSession()
    }
}

private struct TaskTerminalStatusBar: View {
    let controller: TerminalSessionController

    var body: some View {
        HStack(spacing: 16) {
            Label(controller.session.runtimeKind.title, systemImage: "cpu")
            Label(controller.workingDirectory, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Label("本机直连", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(.bar)
    }
}
