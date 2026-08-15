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

    private(set) var detailsPresented = false
    private(set) var detailsWidth = idealDetailsWidth
    private(set) var hostRefreshToken = 0

    func toggleDetails() {
        detailsPresented.toggle()
    }

    func requestHostRefresh() {
        hostRefreshToken += 1
    }

    func recordDetailsWidth(_ proposedWidth: CGFloat) {
        detailsWidth = min(
            max(proposedWidth, Self.minimumDetailsWidth),
            Self.maximumDetailsWidth
        )
    }
}

@MainActor
@Observable
final class TaskWorkspaceCoordinator: TaskWorkspacePresenting {
    private let state: AppState
    let terminalSessions: TerminalSessionRegistry
    @ObservationIgnored private var layoutStates: [UUID: TaskWorkbenchLayoutState] = [:]
    @ObservationIgnored private var composerStates: [InlineAddTaskDestination: InlineAddTaskComposerState] = [:]
    @ObservationIgnored private var timelineComposerStates: [LocalDay: InlineAddTaskComposerState] = [:]
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var transitionGeneration: UInt64 = 0
    @ObservationIgnored private var detailsTransitionInFlight = false

    private(set) var selectedTaskID: UUID?
    private(set) var isPresented = false
    private(set) var pendingTaskID: UUID?
    private(set) var closingTaskID: UUID?
    private(set) var activeWorkspaceIsCompact = false

    var presentedTaskID: UUID? {
        isPresented ? selectedTaskID : nil
    }

    init(state: AppState, terminalSessions: TerminalSessionRegistry) {
        self.state = state
        self.terminalSessions = terminalSessions
    }

    func showTaskWorkspace(taskID: UUID) {
        guard state.task(id: taskID) != nil else { return }

        if !isPresented, state.inspectorPresented {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                state.inspectorPresented = false
            }
        }

        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        transitionTask = nil
        closingTaskID = nil

        if selectedTaskID == taskID {
            pendingTaskID = nil
            isPresented = true
            layoutState(for: taskID).requestHostRefresh()
            focusTerminalAfterMount(taskID: taskID, generation: generation)
            return
        }

        guard isPresented, let previousTaskID = selectedTaskID else {
            selectedTaskID = taskID
            pendingTaskID = nil
            isPresented = true
            layoutState(for: taskID).requestHostRefresh()
            focusTerminalAfterMount(taskID: taskID, generation: generation)
            return
        }

        pendingTaskID = taskID
        commitInput(taskID: previousTaskID)
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: previousTaskID)
            guard !Task.isCancelled,
                  self.transitionGeneration == generation,
                  self.pendingTaskID == taskID
            else { return }
            self.transitionTask = nil
            self.pendingTaskID = nil
            guard saved, self.state.task(id: taskID) != nil else { return }
            self.selectedTaskID = taskID
            self.isPresented = true
            self.layoutState(for: taskID).requestHostRefresh()
            self.focusTerminalAfterMount(taskID: taskID, generation: generation)
        }
    }

    func closeTaskWorkspace(taskID: UUID) {
        guard isPresented, selectedTaskID == taskID else { return }
        guard closingTaskID == nil else { return }
        transitionGeneration &+= 1
        let generation = transitionGeneration
        transitionTask?.cancel()
        pendingTaskID = nil
        closingTaskID = taskID
        commitInput(taskID: taskID)
        transitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: taskID)
            guard !Task.isCancelled,
                  self.transitionGeneration == generation,
                  self.selectedTaskID == taskID
            else {
                if self.closingTaskID == taskID { self.closingTaskID = nil }
                return
            }
            self.transitionTask = nil
            guard saved else {
                self.closingTaskID = nil
                return
            }
            guard !Task.isCancelled,
                  self.transitionGeneration == generation,
                  self.selectedTaskID == taskID,
                  self.closingTaskID == taskID
            else { return }
            // Keep the selection and TerminalSessionController so reopening
            // attaches the exact same Ghostty surface and scrollback.
            self.isPresented = false
            self.closingTaskID = nil
        }
    }

    func destroyTaskWorkspace(taskID: UUID) {
        if pendingTaskID == taskID {
            transitionGeneration &+= 1
            transitionTask?.cancel()
            transitionTask = nil
            pendingTaskID = nil
        }
        layoutStates[taskID] = nil
        guard selectedTaskID == taskID else { return }
        transitionGeneration &+= 1
        transitionTask?.cancel()
        transitionTask = nil
        selectedTaskID = nil
        isPresented = false
        closingTaskID = nil
        activeWorkspaceIsCompact = false
    }

    func commitTaskWorkspaceInput() {
        guard let selectedTaskID else { return }
        commitInput(taskID: selectedTaskID)
    }

    func layoutState(for taskID: UUID) -> TaskWorkbenchLayoutState {
        if let existing = layoutStates[taskID] { return existing }
        let created = TaskWorkbenchLayoutState()
        layoutStates[taskID] = created
        return created
    }

    func composerState(for destination: InlineAddTaskDestination) -> InlineAddTaskComposerState {
        if let existing = composerStates[destination] { return existing }
        let created = InlineAddTaskComposerState()
        composerStates[destination] = created
        return created
    }

    func timelineComposerState(for day: LocalDay) -> InlineAddTaskComposerState {
        if let existing = timelineComposerStates[day] { return existing }
        let created = InlineAddTaskComposerState()
        timelineComposerStates[day] = created
        return created
    }

    var activeWorkspaceShowsTaskRail: Bool {
        presentedTaskID != nil && !activeWorkspaceIsCompact
    }

    func updateActiveWorkspaceCompactState(taskID: UUID, isCompact: Bool) {
        guard presentedTaskID == taskID else { return }
        activeWorkspaceIsCompact = isCompact
        guard isCompact, layoutState(for: taskID).detailsPresented else { return }
        closeTaskDetails(taskID: taskID)
    }

    func contains(taskID: UUID) -> Bool {
        selectedTaskID == taskID
    }

    func focusActiveTerminal() {
        guard isMainWindowCommandTarget, let taskID = presentedTaskID else { return }
        terminalSessions.controller(for: taskID)?.focusIfAppropriate()
    }

    @discardableResult
    func collapseActiveWorkspace() -> Bool {
        guard isMainWindowCommandTarget, let taskID = presentedTaskID else { return false }
        closeTaskWorkspace(taskID: taskID)
        return true
    }

    func performTerminalAction(_ action: String) {
        guard isMainWindowCommandTarget, let taskID = presentedTaskID else { return }
        terminalSessions.controller(for: taskID)?.performAction(action)
    }

    @discardableResult
    func toggleActiveTaskDetails() -> Bool {
        guard isMainWindowCommandTarget,
              !activeWorkspaceIsCompact,
              let taskID = presentedTaskID,
              !detailsTransitionInFlight
        else { return false }
        let layoutState = layoutState(for: taskID)
        guard layoutState.detailsPresented else {
            layoutState.toggleDetails()
            return true
        }

        detailsTransitionInFlight = true
        commitInput(taskID: taskID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: taskID)
            self.detailsTransitionInFlight = false
            guard saved, self.presentedTaskID == taskID else { return }
            self.layoutState(for: taskID).toggleDetails()
            self.terminalSessions.controller(for: taskID)?.focusIfAppropriate()
        }
        return true
    }

    func mainWindowDidBecomeKey() {
        guard let taskID = presentedTaskID else { return }
        terminalSessions.controller(for: taskID)?.focusIfAppropriate()
    }

    func mainWindowWillClose() {
        guard let taskID = presentedTaskID else { return }
        commitInput(taskID: taskID)
        Task { @MainActor [weak self] in
            await Task.yield()
            _ = await self?.state.flushTaskEdits(taskID: taskID)
        }
    }

    private func commitInput(taskID: UUID) {
        terminalSessions.controller(for: taskID)?.surfaceCommitComposition()
        guard let application = NSApp,
              let window = application.windows.first(where: {
            $0.identifier?.rawValue == TodoAgentMainWindow.identifier
        }) else { return }
        window.endEditing(for: nil)
        window.makeFirstResponder(nil)
    }

    private var isMainWindowCommandTarget: Bool {
        guard presentedTaskID != nil,
              let application = NSApp,
              application.keyWindow?.identifier?.rawValue == TodoAgentMainWindow.identifier
        else { return false }
        return true
    }

    private func closeTaskDetails(taskID: UUID) {
        guard !detailsTransitionInFlight else { return }
        let layoutState = layoutState(for: taskID)
        guard layoutState.detailsPresented else { return }
        detailsTransitionInFlight = true
        commitInput(taskID: taskID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            let saved = await self.state.flushTaskEdits(taskID: taskID)
            self.detailsTransitionInFlight = false
            guard saved,
                  self.presentedTaskID == taskID,
                  self.activeWorkspaceIsCompact,
                  self.layoutState(for: taskID).detailsPresented
            else { return }
            self.layoutState(for: taskID).toggleDetails()
        }
    }

    private func focusTerminalAfterMount(taskID: UUID, generation: UInt64) {
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.transitionGeneration == generation,
                  self.presentedTaskID == taskID
            else { return }
            self.terminalSessions.controller(for: taskID)?.focusIfAppropriate()
        }
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

    func requestHostRefresh() {
        layoutState.requestHostRefresh()
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

@MainActor
enum TaskWorkbenchPresentation: Equatable, Sendable {
    case window
    case embedded(compact: Bool)

    var minimumContentSize: CGSize? {
        switch self {
        case .window: TaskWorkbenchWindowController.minimumContentSize
        case .embedded: nil
        }
    }

    var terminalMinimumWidth: CGFloat {
        switch self {
        case .window: 560
        case .embedded: 320
        }
    }

    var minimumDetailsWidth: CGFloat {
        switch self {
        case .window: TaskWorkbenchLayoutState.minimumDetailsWidth
        case .embedded: 220
        }
    }

    var isEmbedded: Bool {
        if case .embedded = self { return true }
        return false
    }

    var isCompactEmbedded: Bool {
        if case let .embedded(compact) = self { return compact }
        return false
    }

    var allowsTaskDetails: Bool {
        self == .window
    }
}

enum TaskTerminalPaneMode: Equatable, Sendable {
    case terminal
    case launching
    case rebuilding
    case unavailable(String)

    static func resolve(
        hasLiveSurface: Bool,
        phase: TerminalSessionPresentationPhase
    ) -> TaskTerminalPaneMode {
        // `launch()` prepares an exact resume command asynchronously. Keep the
        // host surface detached until that command has been enqueued so user
        // keystrokes cannot be concatenated with a delayed automatic resume.
        if case .preparing = phase { return .launching }
        if hasLiveSurface { return .terminal }
        if phase.isActive { return .launching }
        if case .hostExited = phase { return .rebuilding }
        if case let .failed(message) = phase { return .unavailable(message) }
        return .unavailable("终端暂时不可用，请重试。")
    }
}

struct TaskWorkbenchView: View {
    let taskID: UUID
    let state: AppState
    let terminalSessions: TerminalSessionRegistry
    let layoutState: TaskWorkbenchLayoutState
    let toggleTaskDetails: () -> Void
    let requestClose: () -> Void
    var presentation: TaskWorkbenchPresentation = .window
    var isClosing = false

    @State private var terminalController: TerminalSessionController?
    @State private var isLoadingSession = true
    @State private var terminalLoadGeneration = 0
    @State private var terminalReloadToken = 0
    @State private var hostBindError: String?

    var body: some View {
        Group {
            if let task = state.task(id: taskID) {
                TaskWorkbenchContent(
                    task: task,
                    state: state,
                    layoutState: layoutState,
                    terminalMinimumWidth: presentation.terminalMinimumWidth,
                    minimumDetailsWidth: presentation.minimumDetailsWidth,
                    allowsTaskDetails: presentation.allowsTaskDetails,
                    terminalPane: { terminalPane($0) }
                )
            } else {
                TaskEmbeddedStateContainer(
                    title: "任务已不存在",
                    subtitle: "这个任务已被删除",
                    presentation: presentation,
                    isClosing: isClosing,
                    close: requestClose
                ) {
                    ContentUnavailableView(
                        "任务已不存在",
                        systemImage: "questionmark.folder",
                        description: Text("这个任务已被删除。")
                    )
                }
            }
        }
        .frame(
            minWidth: presentation.minimumContentSize?.width,
            minHeight: presentation.minimumContentSize?.height
        )
        .disabled(state.isPreparingToTerminate)
        .accessibilityIdentifier("task.workbench.\(taskID.uuidString)")
        .task(id: "\(taskID.uuidString)-\(layoutState.hostRefreshToken)-\(terminalReloadToken)") {
            await loadTerminalController()
        }
        .onChange(of: terminalController?.phase) { _, phase in
            if case .hostExited = phase,
               hostBindError == nil,
               !terminalSessions.isShuttingDown,
               !terminalSessions.isRecoveringEngine
            {
                requestTerminalReload()
            }
        }
        .onChange(of: terminalSessions.isShuttingDown) { wasShuttingDown, isShuttingDown in
            if wasShuttingDown, !isShuttingDown {
                requestTerminalReload()
            }
        }
        .onChange(of: terminalSessions.isRecoveringEngine) { wasRecovering, isRecovering in
            if wasRecovering, !isRecovering {
                requestTerminalReload()
            }
        }
    }

    @ViewBuilder
    private func terminalPane(_ task: TaskItem) -> some View {
        if let hostBindError {
            TaskEmbeddedStateContainer(
                title: task.title,
                subtitle: "终端暂时不可用",
                presentation: presentation,
                isClosing: isClosing,
                close: requestClose
            ) {
                TaskTerminalBindFailedPane(
                    message: hostBindError,
                    retry: {
                        requestTerminalReload()
                    }
                )
            }
        } else if let terminalController {
            VStack(spacing: 0) {
                TaskTerminalToolbar(
                    task: task,
                    controller: terminalController,
                    detailsPresented: layoutState.detailsPresented,
                    presentation: presentation,
                    isClosing: isClosing,
                    toggleTaskDetails: toggleTaskDetails,
                    close: requestClose
                )
                Divider()
                switch TaskTerminalPaneMode.resolve(
                    hasLiveSurface: terminalController.hasLiveSurface,
                    phase: terminalController.phase
                ) {
                case .terminal:
                    TerminalSurfaceContainer(controller: terminalController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("task.terminal.surface")
                case .launching:
                    TaskTerminalLaunchingPane(controller: terminalController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .rebuilding:
                    ProgressView("正在重新连接终端…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case let .unavailable(message):
                    TaskTerminalBindFailedPane(
                        message: message,
                        retry: requestTerminalReload
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider()
                TaskTerminalStatusBar(controller: terminalController)
            }
        } else {
            TaskEmbeddedStateContainer(
                title: task.title,
                subtitle: "正在打开任务终端",
                presentation: presentation,
                isClosing: isClosing,
                close: requestClose
            ) {
                ProgressView(isLoadingSession ? "正在打开任务终端…" : "正在等待终端服务…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadTerminalController() async {
        guard let task = state.task(id: taskID) else { return }
        terminalLoadGeneration &+= 1
        let generation = terminalLoadGeneration
        isLoadingSession = true
        hostBindError = nil
        defer {
            if terminalLoadGeneration == generation,
               terminalController != nil || (
                   !terminalSessions.isShuttingDown
                       && !terminalSessions.isRecoveringEngine
               )
            {
                isLoadingSession = false
            }
        }
        do {
            let loaded = try await terminalSessions.openTask(task)
            guard !Task.isCancelled, terminalLoadGeneration == generation else { return }
            terminalController = loaded
        } catch is CancellationError {
            return
        } catch {
            guard terminalLoadGeneration == generation else { return }
            hostBindError = error.localizedDescription
        }
    }

    private func requestTerminalReload() {
        terminalReloadToken &+= 1
    }
}

private struct TaskEmbeddedStateContainer<Content: View>: View {
    let title: String
    let subtitle: String
    let presentation: TaskWorkbenchPresentation
    let isClosing: Bool
    let close: () -> Void
    let content: Content

    init(
        title: String,
        subtitle: String,
        presentation: TaskWorkbenchPresentation,
        isClosing: Bool,
        close: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.presentation = presentation
        self.isClosing = isClosing
        self.close = close
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if presentation.isEmbedded {
            VStack(spacing: 0) {
                TaskEmbeddedStateToolbar(
                    title: title,
                    subtitle: subtitle,
                    isCompact: presentation.isCompactEmbedded,
                    isClosing: isClosing,
                    close: close
                )
                Divider()
                content
            }
        } else {
            content
        }
    }
}

private struct TaskEmbeddedStateToolbar: View {
    let title: String
    let subtitle: String
    let isCompact: Bool
    let isClosing: Bool
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            collapseButton

            Image(systemName: "terminal")
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                if !isCompact {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.bar)
    }

    @ViewBuilder
    private var collapseButton: some View {
        if isClosing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .accessibilityLabel("正在收起任务终端")
        } else {
            Button("收起任务终端", systemImage: "sidebar.leading", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("返回任务页，终端继续运行")
                .accessibilityHint("返回任务页，终端继续运行")
                .accessibilityIdentifier("task.workspace.toolbar.collapse")
        }
    }
}

private struct TaskTerminalBindFailedPane: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.secondary)
            Text("无法打开终端")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("task.terminal.bind-failed")
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

private struct TaskWorkbenchContent<TerminalPane: View>: View {
    private static var resizeCoordinateSpace: String { "task-workbench-details-resize" }

    let task: TaskItem
    let state: AppState
    let layoutState: TaskWorkbenchLayoutState
    let terminalMinimumWidth: CGFloat
    let minimumDetailsWidth: CGFloat
    let allowsTaskDetails: Bool
    let terminalPane: (TaskItem) -> TerminalPane

    @State private var detailDraft: TaskDetailDraft
    @FocusState private var focusedTextField: TaskDetailTextField?

    init(
        task: TaskItem,
        state: AppState,
        layoutState: TaskWorkbenchLayoutState,
        terminalMinimumWidth: CGFloat,
        minimumDetailsWidth: CGFloat,
        allowsTaskDetails: Bool,
        @ViewBuilder terminalPane: @escaping (TaskItem) -> TerminalPane
    ) {
        self.task = task
        self.state = state
        self.layoutState = layoutState
        self.terminalMinimumWidth = terminalMinimumWidth
        self.minimumDetailsWidth = minimumDetailsWidth
        self.allowsTaskDetails = allowsTaskDetails
        self.terminalPane = terminalPane
        _detailDraft = State(initialValue: TaskDetailDraft(task: task))
    }

    var body: some View {
        GeometryReader { proxy in
            let detailsPresented = layoutState.detailsPresented && allowsTaskDetails
            let maximumAvailableDetailsWidth = max(
                minimumDetailsWidth,
                proxy.size.width - terminalMinimumWidth - TaskDetailsResizeDivider.width
            )
            let presentedWidth = min(layoutState.detailsWidth, maximumAvailableDetailsWidth)

            HStack(spacing: 0) {
                TaskDetailsPane(
                    task: task,
                    draft: $detailDraft,
                    focusedTextField: $focusedTextField,
                    state: state
                )
                .frame(width: detailsPresented ? presentedWidth : 0)
                .clipped()
                .opacity(detailsPresented ? 1 : 0)
                .allowsHitTesting(detailsPresented)
                .accessibilityHidden(!detailsPresented)

                TaskDetailsResizeDivider(
                    detailsWidth: presentedWidth,
                    isPresented: detailsPresented,
                    coordinateSpace: Self.resizeCoordinateSpace,
                    onResize: layoutState.recordDetailsWidth
                )

                terminalPane(task)
                    .frame(
                        minWidth: terminalMinimumWidth,
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
    let presentation: TaskWorkbenchPresentation
    let isClosing: Bool
    let toggleTaskDetails: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if case .embedded = presentation {
                collapseButton
            }

            if presentation.allowsTaskDetails {
                Button(
                    detailsPresented ? "隐藏任务详情" : "显示任务详情",
                    systemImage: "sidebar.leading",
                    action: toggleTaskDetails
                )
                .labelStyle(.iconOnly)
                .help(detailsPresented ? "隐藏任务详情（⌃⌘S）" : "显示任务详情（⌃⌘S）")
                .accessibilityValue(detailsPresented ? "已展开" : "已收起")
                .accessibilityIdentifier("task.details.toggle")
            }

            RuntimeIconView(kind: controller.session.runtimeKind, fallbackSymbol: "terminal")
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(.headline).lineLimit(1)
                if !isCompactEmbedded {
                    Text("\(controller.session.runtimeKind.title) 终端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            phaseLabel
            if controller.hasLiveSurface {
                Button("聚焦终端", systemImage: "cursorarrow.click") {
                    controller.focusIfAppropriate()
                }
                .labelStyle(.iconOnly)
                .help("聚焦终端")
            }
            if presentation == .window {
                Button("关闭", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .help("关闭工作台，终端继续运行")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(.bar)
    }

    @ViewBuilder
    private var phaseLabel: some View {
        if isCompactEmbedded {
            Label(controller.phase.title, systemImage: phaseSymbol)
                .labelStyle(.iconOnly)
                .help(controller.phase.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(controller.needsAttention ? .orange : .secondary)
        } else {
            Label(controller.phase.title, systemImage: phaseSymbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(controller.needsAttention ? .orange : .secondary)
        }
    }

    @ViewBuilder
    private var collapseButton: some View {
        if isClosing {
            ProgressView()
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .accessibilityLabel("正在收起任务终端")
        } else {
            Button("收起任务终端", systemImage: "sidebar.leading", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("返回任务页，终端继续运行")
                .accessibilityHint("返回任务页，终端继续运行")
                .accessibilityIdentifier("task.workspace.toolbar.collapse")
        }
    }

    private var isCompactEmbedded: Bool {
        if case let .embedded(compact) = presentation { return compact }
        return false
    }

    private var phaseSymbol: String {
        if controller.needsAttention { return "bell.badge.fill" }
        return controller.phase.isActive ? "circle.dotted.circle" : "terminal"
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
