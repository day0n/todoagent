import AppKit
import Observation
import SwiftUI

struct ContentView: View {
    @State private var state: AppState
    @State private var taskWorkspace: TaskWorkspaceCoordinator
    @State private var assistantResizeStartWidth: CGFloat?
    @State private var assistantLiveWidth: CGFloat?
    @State private var taskWorkspaceVisuallyMounted = false
    @State private var workspaceChrome: MainWorkspaceChromeCoordinator
    @AppStorage(AssistantPanePreferences.widthKey) private var storedAssistantWidth = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        state: AppState,
        taskWorkspace: TaskWorkspaceCoordinator,
        workspaceChrome: MainWorkspaceChromeCoordinator? = nil
    ) {
        let workspaceChrome = workspaceChrome ?? MainWorkspaceChromeCoordinator(state: state)
        taskWorkspace.presentationPreparer = workspaceChrome
        _state = State(initialValue: state)
        _taskWorkspace = State(initialValue: taskWorkspace)
        _workspaceChrome = State(initialValue: workspaceChrome)
    }

    init(repository: any AppRepository) {
        let state = AppState(repository: repository)
        let terminalSessions = TerminalSessionRegistry(repository: repository)
        let taskWorkspace = TaskWorkspaceCoordinator(
            state: state,
            terminalSessions: terminalSessions
        )
        let workspaceChrome = MainWorkspaceChromeCoordinator(state: state)
        state.taskWorkspacePresenter = taskWorkspace
        state.terminalSessions = terminalSessions
        taskWorkspace.presentationPreparer = workspaceChrome
        _state = State(initialValue: state)
        _taskWorkspace = State(initialValue: taskWorkspace)
        _workspaceChrome = State(initialValue: workspaceChrome)
    }

    var body: some View {
        @Bindable var workspaceChrome = workspaceChrome
        let navigationColumnVisibility = Binding(
            get: { workspaceChrome.navigationColumnVisibility },
            set: { workspaceChrome.acceptSystemNavigationVisibility($0) }
        )

        NavigationSplitView(columnVisibility: navigationColumnVisibility) {
            SidebarView(state: state)
                .tint(TodoAgentUI.primaryText)
                .navigationSplitViewColumnWidth(
                    min: 210,
                    ideal: TodoAgentUI.sidebarIdealWidth,
                    max: TodoAgentUI.sidebarMaximumWidth
                )
        } detail: {
            GeometryReader { proxy in
                let assistantWidth = MainWorkspaceLayoutPolicy.assistantWidth(
                    availableWidth: proxy.size.width,
                    preferredWidth: assistantLiveWidth ?? persistedAssistantWidth
                )
                let taskWorkspacePresented = taskWorkspaceIsVisuallyActive
                let externalChromeLocked = taskWorkspaceExternalChromeLocked
                let assistantPlacement = AssistantPanePlacementPolicy.resolve(
                    inspectorPresented: state.inspectorPresented,
                    taskWorkspacePresented: taskWorkspacePresented
                )
                let assistantIsVisible = assistantPlacement != .hidden
                let assistantDrawerWidth = assistantWidth + MainWorkspaceLayoutPolicy.dividerWidth
                let assistantLayoutTarget = AssistantWorkspaceLayoutTarget.resolve(
                    placement: assistantPlacement,
                    drawerWidth: assistantDrawerWidth
                )

                AssistantWorkspaceSynchronizedLayout(
                    reservedWidth: assistantLayoutTarget.reservedWidth,
                    visibleDrawerWidth: assistantLayoutTarget.visibleDrawerWidth,
                    drawerWidth: assistantDrawerWidth
                ) {
                    boardWorkspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    HStack(spacing: 0) {
                        AssistantResizeDivider(
                            assistantWidth: assistantWidth,
                            onDragChanged: { translation in
                                resizeAssistantPane(
                                    translation: translation,
                                    currentWidth: assistantWidth,
                                    availableWidth: proxy.size.width
                                )
                            },
                            onDragEnded: finishResizingAssistantPane,
                            onNudge: { delta in
                                nudgeAssistantPane(
                                    by: delta,
                                    currentWidth: assistantWidth,
                                    availableWidth: proxy.size.width
                                )
                            }
                        )

                        TodoAgentInspector(state: state)
                            .tint(TodoAgentUI.primaryText)
                            .frame(width: assistantWidth)
                    }
                    .frame(width: assistantDrawerWidth)
                    .background(TodoAgentUI.canvasBackground)
                    .shadow(
                        color: assistantPlacement == .taskOverlay && assistantIsVisible
                            ? TodoAgentUI.shadowColor
                            : .clear,
                        radius: 18,
                        x: -5
                    )
                    .allowsHitTesting(assistantIsVisible)
                    .accessibilityHidden(!assistantIsVisible)
                    .accessibilityIdentifier(
                        assistantPlacement == .taskOverlay
                            ? "assistant.task-overlay"
                            : "assistant.side-pane"
                    )
                    .zIndex(2)
                }
                .animation(
                    AssistantWorkspaceMotion.animation(
                        reduceMotion: reduceMotion || externalChromeLocked
                    ),
                    value: assistantPlacement
                )
                // The divider itself moves while it is being dragged. Keep
                // the gesture in this fixed workspace coordinate space so
                // its translation does not feed back into the next event.
                .coordinateSpace(name: AssistantWorkspaceCoordinateSpace.name)
                .clipped()
            }
        }
        // Unlike `.balanced`, prominent-detail keeps Board/Ghostty geometry
        // stable while the native Sidebar slides over the leading edge.
        .navigationSplitViewStyle(.prominentDetail)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        workspaceChrome.updateRootWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, width in
                        workspaceChrome.updateRootWidth(width)
                    }
                    .onDisappear {
                        workspaceChrome.updateRootWidth(0)
                    }
            }
        }
        // Workspace chrome lock must not disable this subtree. SwiftUI's
        // disabled styling can attach a washed filter to Ghostty's Metal
        // layer and leave Claude Code's yellow/orange palette looking white.
        .disabled(
            MainWorkspaceInteractionPolicy.disablesContent(
                loadState: state.loadState,
                isPreparingToTerminate: state.isPreparingToTerminate
            )
        )
        .onAppear {
            taskWorkspace.presentationPreparer = workspaceChrome
            taskWorkspace.mainWindowDidMount()
        }
        .task { await state.load() }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentToggleInspector)) { _ in
            guard taskWorkspaceExternalChromeLocked == false else { return }
            Task { await state.toggleAssistant() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewAssistantConversation)) { _ in
            guard taskWorkspaceExternalChromeLocked == false else { return }
            Task { await state.openNewAssistantConversation() }
        }
        .onChange(of: state.inspectorPresented) { wasPresented, isPresented in
            guard wasPresented,
                  !isPresented,
                  taskWorkspace.presentedTaskID != nil
            else { return }
            Task { @MainActor in
                await Task.yield()
                taskWorkspace.focusActiveTerminal()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == TodoAgentMainWindow.identifier
            else { return }
            taskWorkspace.mainWindowDidBecomeKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = note.object as? NSWindow,
                  window.identifier?.rawValue == TodoAgentMainWindow.identifier
            else { return }
            taskWorkspace.mainWindowWillClose()
        }
        .overlay {
            if state.isPreparingToTerminate {
                ProgressView("正在保存任务并退出…")
                    .padding(18)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("app.saving-before-quit")
            } else {
                switch state.loadState {
                case .loading:
                    ProgressView("正在准备 TodoAgent…")
                        .padding(18)
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                case let .failed(message):
                    ContentUnavailableView {
                        Label("无法载入任务", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重新载入") {
                            Task { await state.load() }
                        }
                        .accessibilityIdentifier("app.retry-load")
                    }
                case .loaded:
                    EmptyView()
                }
            }
        }
        .alert("操作未完成", isPresented: errorPresented) {
            Button("好", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "请稍后再试。")
        }
    }

    private var boardWorkspace: some View {
        let floatingButtonIsVisible = !state.inspectorPresented
        let taskWorkspacePresented = taskWorkspaceIsVisuallyActive

        return ZStack(alignment: .bottomTrailing) {
            BoardView(
                state: state,
                taskWorkspace: taskWorkspace,
                workspaceVisuallyMounted: $taskWorkspaceVisuallyMounted,
                geometryRequestGeneration: workspaceChrome.geometryRequestGeneration,
                onAvailableWidthChange: workspaceChrome.updateBoardWidth
            )

            AssistantFloatingButton(isOverTaskTerminal: taskWorkspacePresented) {
                guard taskWorkspaceExternalChromeLocked == false else { return }
                Task { await state.openAssistant() }
            }
            .padding(.trailing, TodoAgentUI.floatingButtonTrailingPadding)
            .padding(.bottom, TodoAgentUI.floatingButtonBottomPadding)
            .scaleEffect(floatingButtonIsVisible ? 1 : 0.88, anchor: .bottomTrailing)
            .opacity(floatingButtonIsVisible ? 1 : 0)
            .allowsHitTesting(floatingButtonIsVisible && !taskWorkspaceExternalChromeLocked)
            .accessibilityHidden(!floatingButtonIsVisible)
            .animation(
                reduceMotion || taskWorkspaceExternalChromeLocked
                    ? nil
                    : .easeInOut(duration: 0.22),
                value: floatingButtonIsVisible
            )
        }
        .background(TodoAgentUI.canvasBackground)
    }

    private var persistedAssistantWidth: CGFloat? {
        storedAssistantWidth > 0 ? CGFloat(storedAssistantWidth) : nil
    }

    /// The coordinator completes its save before the board finishes sliding
    /// the terminal away. Keep the assistant in overlay mode until that visual
    /// transition unmounts, otherwise its reserved side-pane width would
    /// resize Ghostty during the close animation.
    private var taskWorkspaceIsVisuallyActive: Bool {
        taskWorkspace.presentedTaskID != nil || taskWorkspaceVisuallyMounted
    }

    /// Keep the chrome closed across the small hand-off between the geometry
    /// preflight and the coordinator publishing its selected task. Otherwise a
    /// toolbar action can reopen a side pane in the exact frame Ghostty mounts.
    private var taskWorkspaceExternalChromeLocked: Bool {
        workspaceChrome.isPreparingTaskWorkspace
            || (taskWorkspace.pendingTaskID != nil && taskWorkspace.presentedTaskID == nil)
    }

    private func resizeAssistantPane(
        translation: CGFloat,
        currentWidth: CGFloat,
        availableWidth: CGFloat
    ) {
        let startingWidth = assistantResizeStartWidth ?? currentWidth
        assistantResizeStartWidth = startingWidth
        assistantLiveWidth = MainWorkspaceLayoutPolicy.resizedAssistantWidth(
            availableWidth: availableWidth,
            startingWidth: startingWidth,
            dividerTranslation: translation
        )
    }

    private func finishResizingAssistantPane() {
        if let assistantLiveWidth {
            storedAssistantWidth = Double(assistantLiveWidth)
        }
        assistantResizeStartWidth = nil
        assistantLiveWidth = nil
    }

    private func nudgeAssistantPane(
        by delta: CGFloat,
        currentWidth: CGFloat,
        availableWidth: CGFloat
    ) {
        let width = MainWorkspaceLayoutPolicy.clampedAssistantWidth(
            currentWidth + delta,
            availableWidth: availableWidth
        )
        storedAssistantWidth = Double(width)
        assistantResizeStartWidth = nil
        assistantLiveWidth = nil
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }
}

enum MainWorkspaceInteractionPolicy {
    static func disablesContent(
        loadState: AppLoadState,
        isPreparingToTerminate: Bool
    ) -> Bool {
        switch loadState {
        case .loading:
            true
        case .loaded, .failed:
            isPreparingToTerminate
        }
    }
}

@MainActor
@Observable
final class MainWorkspaceChromeCoordinator: TaskWorkspacePresentationPreparing {
    var navigationColumnVisibility = MainWorkspaceNavigationPolicy.visibleColumns
    private(set) var isPreparingTaskWorkspace = false
    private(set) var geometryRequestGeneration: UInt64 = 0

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var rootWidth: CGFloat = 0
    @ObservationIgnored private var boardWidth: CGFloat = 0
    @ObservationIgnored private var boardGeometryRevision: UInt64 = 0
    @ObservationIgnored private var preparationSessionCounter: UInt64 = 0
    @ObservationIgnored private var preparationSession: ExternalChromePreparationSession?
    @ObservationIgnored private var geometryWaiters: [UUID: BoardGeometryWaiter] = [:]
    @ObservationIgnored private let preparationTimeout: TimeInterval

    init(
        state: AppState,
        preparationTimeout: TimeInterval = TaskWorkspaceExternalChromePreparationPolicy.timeout
    ) {
        self.state = state
        self.preparationTimeout = max(preparationTimeout, 0)
    }

    func updateRootWidth(_ width: CGFloat) {
        rootWidth = max(width, 0)
    }

    /// NavigationSplitView can publish a semantically equivalent `.all` value
    /// after its native transition. Store one concrete two-column state so that
    /// completion does not invalidate and rebuild the workspace a second time.
    func acceptSystemNavigationVisibility(_ visibility: NavigationSplitViewVisibility) {
        guard isPreparingTaskWorkspace == false else { return }
        navigationColumnVisibility = MainWorkspaceNavigationPolicy.canonicalVisibility(visibility)
    }

    func updateBoardWidth(_ width: CGFloat) {
        boardWidth = max(width, 0)
        boardGeometryRevision &+= 1
        resumeCommittedGeometryWaiters()
    }

    /// The terminal must be sized from the final main-window geometry. Collapse
    /// external chrome first, wait for its visual transaction and a stable
    /// detail layout, and only then let the task coordinator publish a mounted
    /// workspace.
    func acquireTaskWorkspacePreparation() -> TaskWorkspacePresentationPreparation {
        let requestID = UUID()
        let sessionID = acquirePreparationSession(requestID: requestID)
        isPreparingTaskWorkspace = true
        return TaskWorkspacePresentationPreparation(
            sessionID: sessionID,
            requestID: requestID,
            minimumBoardGeometryRevision: boardGeometryRevision,
            isReady: false
        )
    }

    func awaitTaskWorkspacePreparation(
        _ preparation: TaskWorkspacePresentationPreparation
    ) async -> TaskWorkspacePresentationPreparation {
        let sessionID = preparation.sessionID
        let requestID = preparation.requestID
        let deadline = Date().addingTimeInterval(preparationTimeout)
        geometryRequestGeneration &+= 1

        while !Task.isCancelled,
              ownsPreparationRequest(sessionID: sessionID, requestID: requestID),
              Date() < deadline
        {
            let chromeAlreadyCollapsed = navigationColumnVisibility == .detailOnly
                && state?.inspectorPresented != true
            let hasFreshBoardGeometry = boardGeometryRevision
                > preparation.minimumBoardGeometryRevision
            if chromeAlreadyCollapsed, hasFreshBoardGeometry, boardGeometryIsReady {
                return TaskWorkspacePresentationPreparation(
                    sessionID: sessionID,
                    requestID: requestID,
                    minimumBoardGeometryRevision: preparation.minimumBoardGeometryRevision,
                    isReady: true
                )
            }

            let revisionBeforeCollapse = boardGeometryRevision
            applyExternalChrome(
                navigationVisibility: .detailOnly,
                inspectorPresented: false
            )

            // Ask the live Board GeometryReader to commit a sample even when
            // macOS presents the Sidebar as an overlay and its width is
            // unchanged. The terminal remains unmounted until this ack.
            geometryRequestGeneration &+= 1
            let committed = await waitForBoardGeometry(
                after: revisionBeforeCollapse,
                timeout: max(deadline.timeIntervalSinceNow, 0)
            )
            if committed == false { break }
        }

        return TaskWorkspacePresentationPreparation(
            sessionID: sessionID,
            requestID: requestID,
            minimumBoardGeometryRevision: preparation.minimumBoardGeometryRevision,
            isReady: false
        )
    }

    func finishTaskWorkspacePreparation(
        _ preparation: TaskWorkspacePresentationPreparation,
        didPresent: Bool
    ) {
        guard var session = preparationSession,
              session.id == preparation.sessionID,
              session.requestIDs.remove(preparation.requestID) != nil
        else { return }

        if didPresent, preparation.isReady {
            preparationSession = nil
            isPreparingTaskWorkspace = false
            return
        }

        if session.requestIDs.isEmpty {
            preparationSession = nil
            applyExternalChrome(
                navigationVisibility: session.originalNavigationVisibility,
                inspectorPresented: session.originalInspectorPresented
            )
            geometryRequestGeneration &+= 1
            isPreparingTaskWorkspace = false
        } else {
            preparationSession = session
        }
    }

    private var boardGeometryIsReady: Bool {
        navigationColumnVisibility == .detailOnly
            && state?.inspectorPresented != true
            && rootWidth > 0
            && boardWidth > 0
            // NavigationSplitView can retain a device-pixel separator/inset
            // even in detail-only mode. A two-point tolerance still rejects
            // every real Sidebar or Assistant pane while avoiding a false
            // timeout on those native rounding differences.
            && abs(rootWidth - boardWidth)
                <= TaskWorkspaceExternalChromePreparationPolicy.geometryTolerance
    }

    private func applyExternalChrome(
        navigationVisibility: NavigationSplitViewVisibility,
        inspectorPresented: Bool
    ) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            navigationColumnVisibility = MainWorkspaceNavigationPolicy.canonicalVisibility(
                navigationVisibility
            )
            state?.inspectorPresented = inspectorPresented
        }
    }

    private func acquirePreparationSession(requestID: UUID) -> UInt64 {
        var session: ExternalChromePreparationSession
        if let current = preparationSession {
            session = current
        } else {
            preparationSessionCounter &+= 1
            session = ExternalChromePreparationSession(
                id: preparationSessionCounter,
                originalNavigationVisibility: MainWorkspaceNavigationPolicy.canonicalVisibility(
                    navigationColumnVisibility
                ),
                originalInspectorPresented: state?.inspectorPresented == true,
                requestIDs: []
            )
        }
        session.requestIDs.insert(requestID)
        preparationSession = session
        return session.id
    }

    private func ownsPreparationRequest(sessionID: UInt64, requestID: UUID) -> Bool {
        preparationSession?.id == sessionID
            && preparationSession?.requestIDs.contains(requestID) == true
    }

    private func waitForBoardGeometry(
        after revision: UInt64,
        timeout: TimeInterval
    ) async -> Bool {
        guard boardGeometryRevision <= revision else { return true }
        guard timeout > 0 else { return false }
        let waiterID = UUID()
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard Task.isCancelled == false else { return }
            self?.resolveGeometryWaiter(waiterID, committed: false)
        }
        let committed = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || boardGeometryRevision > revision {
                    continuation.resume(returning: !Task.isCancelled)
                } else {
                    geometryWaiters[waiterID] = BoardGeometryWaiter(
                        minimumRevision: revision,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveGeometryWaiter(waiterID, committed: false)
            }
        }
        timeoutTask.cancel()
        return committed
    }

    private func resumeCommittedGeometryWaiters() {
        let readyIDs = geometryWaiters.compactMap { id, waiter in
            boardGeometryRevision > waiter.minimumRevision ? id : nil
        }
        for id in readyIDs {
            resolveGeometryWaiter(id, committed: true)
        }
    }

    private func resolveGeometryWaiter(_ id: UUID, committed: Bool) {
        geometryWaiters.removeValue(forKey: id)?.continuation.resume(returning: committed)
    }
}

private struct BoardGeometryWaiter {
    let minimumRevision: UInt64
    let continuation: CheckedContinuation<Bool, Never>
}

private struct ExternalChromePreparationSession {
    let id: UInt64
    let originalNavigationVisibility: NavigationSplitViewVisibility
    let originalInspectorPresented: Bool
    var requestIDs: Set<UUID>
}

enum TaskWorkspaceExternalChromePreparationPolicy {
    static let timeout: TimeInterval = 2
    static let geometryTolerance: CGFloat = 2
}

enum MainWorkspaceNavigationPolicy {
    /// This is the concrete visible state for a two-column split. `.all` has
    /// the same meaning, but retaining two representations creates an avoidable
    /// observation update when AppKit commits its native Sidebar transition.
    static let visibleColumns: NavigationSplitViewVisibility = .doubleColumn

    static func canonicalVisibility(
        _ visibility: NavigationSplitViewVisibility
    ) -> NavigationSplitViewVisibility {
        visibility == .all ? visibleColumns : visibility
    }
}

enum MainWorkspaceLayout: Equatable, Sendable {
    case boardOnly
    case sideBySide(assistantWidth: CGFloat)
}

enum AssistantPanePlacement: Equatable, Sendable {
    case hidden
    case sideBySide
    case taskOverlay
}

enum AssistantPanePlacementPolicy {
    static func resolve(
        inspectorPresented: Bool,
        taskWorkspacePresented: Bool
    ) -> AssistantPanePlacement {
        guard inspectorPresented else { return .hidden }
        return taskWorkspacePresented ? .taskOverlay : .sideBySide
    }
}

struct AssistantWorkspaceLayoutTarget: Equatable, Sendable {
    let reservedWidth: CGFloat
    let visibleDrawerWidth: CGFloat

    static func resolve(
        placement: AssistantPanePlacement,
        drawerWidth: CGFloat
    ) -> AssistantWorkspaceLayoutTarget {
        let drawerWidth = max(drawerWidth, 0)
        switch placement {
        case .hidden:
            return AssistantWorkspaceLayoutTarget(reservedWidth: 0, visibleDrawerWidth: 0)
        case .sideBySide:
            return AssistantWorkspaceLayoutTarget(
                reservedWidth: drawerWidth,
                visibleDrawerWidth: drawerWidth
            )
        case .taskOverlay:
            return AssistantWorkspaceLayoutTarget(
                reservedWidth: 0,
                visibleDrawerWidth: drawerWidth
            )
        }
    }
}

struct AssistantWorkspaceLayoutGeometry: Equatable, Sendable {
    let boardFrame: CGRect
    let drawerFrame: CGRect
}

enum AssistantWorkspaceSynchronizedLayoutPolicy {
    static func resolve(
        in bounds: CGRect,
        reservedWidth: CGFloat,
        visibleDrawerWidth: CGFloat,
        drawerWidth: CGFloat
    ) -> AssistantWorkspaceLayoutGeometry {
        let drawerWidth = max(drawerWidth, 0)
        let reservedWidth = min(max(reservedWidth, 0), bounds.width)
        let visibleDrawerWidth = min(
            max(visibleDrawerWidth, 0),
            min(drawerWidth, bounds.width)
        )
        return AssistantWorkspaceLayoutGeometry(
            boardFrame: CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: max(bounds.width - reservedWidth, 0),
                height: bounds.height
            ),
            drawerFrame: CGRect(
                x: bounds.maxX - visibleDrawerWidth,
                y: bounds.minY,
                width: drawerWidth,
                height: bounds.height
            )
        )
    }
}

/// Places Board and the Assistant from one animatable pair. Side-by-side mode
/// keeps `reservedWidth == visibleDrawerWidth` at every frame, so their shared
/// boundary cannot drift. Overlay mode changes only visible width, preserving
/// the Board (and any mounted Ghostty surface) at a fixed proposal.
struct AssistantWorkspaceSynchronizedLayout: Layout {
    var reservedWidth: CGFloat
    var visibleDrawerWidth: CGFloat
    let drawerWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(reservedWidth, visibleDrawerWidth) }
        set {
            reservedWidth = newValue.first
            visibleDrawerWidth = newValue.second
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews _: Subviews,
        cache _: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard subviews.count >= 2 else { return }
        let geometry = AssistantWorkspaceSynchronizedLayoutPolicy.resolve(
            in: bounds,
            reservedWidth: reservedWidth,
            visibleDrawerWidth: visibleDrawerWidth,
            drawerWidth: drawerWidth
        )
        subviews[0].place(
            at: geometry.boardFrame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: geometry.boardFrame.width,
                height: geometry.boardFrame.height
            )
        )
        subviews[1].place(
            at: geometry.drawerFrame.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: geometry.drawerFrame.width,
                height: geometry.drawerFrame.height
            )
        )
    }
}

enum MainWorkspaceLayoutPolicy {
    static let dividerWidth: CGFloat = 10
    static let assistantMinimumWidth: CGFloat = 260
    static let boardMinimumVisibleWidth: CGFloat = 360
    static let defaultBoardWidth: CGFloat = 560

    static func resolve(
        availableWidth: CGFloat,
        assistantRequested: Bool,
        preferredAssistantWidth: CGFloat? = nil
    ) -> MainWorkspaceLayout {
        guard assistantRequested else { return .boardOnly }

        return .sideBySide(
            assistantWidth: assistantWidth(
                availableWidth: availableWidth,
                preferredWidth: preferredAssistantWidth
            )
        )
    }

    static func assistantWidth(
        availableWidth: CGFloat,
        preferredWidth: CGFloat? = nil
    ) -> CGFloat {
        let defaultWidth = availableWidth - defaultBoardWidth - dividerWidth
        return clampedAssistantWidth(
            preferredWidth ?? defaultWidth,
            availableWidth: availableWidth
        )
    }

    static func resizedAssistantWidth(
        availableWidth: CGFloat,
        startingWidth: CGFloat,
        dividerTranslation: CGFloat
    ) -> CGFloat {
        clampedAssistantWidth(
            startingWidth - dividerTranslation,
            availableWidth: availableWidth
        )
    }

    static func clampedAssistantWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat
    ) -> CGFloat {
        let maximumWidth = max(
            availableWidth - boardMinimumVisibleWidth - dividerWidth,
            0
        )
        let minimumWidth = min(assistantMinimumWidth, maximumWidth)
        return min(max(proposedWidth, minimumWidth), maximumWidth)
    }
}

enum AssistantPanePreferences {
    // Today uses a normal task list rather than fixed day columns. Start the
    // pane from the new list-friendly width, then preserve user resizing.
    static let widthKey = "assistantPaneWidth.v4"
}

enum AssistantWorkspaceMotion {
    /// Long enough for the eye to follow the board compression, while keeping
    /// the pane feeling attached to the window rather than modal.
    static let duration: TimeInterval = 0.34

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: duration)
    }
}

private enum AssistantWorkspaceCoordinateSpace {
    static let name = "todoagent.assistant-workspace"
}

private struct AssistantResizeDivider: View {
    let assistantWidth: CGFloat
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onNudge: (CGFloat) -> Void

    @State private var pointerInside = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: MainWorkspaceLayoutPolicy.dividerWidth)
            .overlay {
                Rectangle()
                    .fill(TodoAgentUI.hairline)
                    .frame(width: 1)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(AssistantWorkspaceCoordinateSpace.name)
                )
                    .onChanged { onDragChanged($0.translation.width) }
                    .onEnded { _ in onDragEnded() }
            )
            .onHover { isInside in
                pointerInside = isInside
                (isInside ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .onDisappear {
                if pointerInside {
                    NSCursor.arrow.set()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("调整 TodoAgent 宽度")
            .accessibilityValue("宽度 \(Int(assistantWidth)) 点")
            .accessibilityHint("左右拖动调整对话面板大小")
            .accessibilityIdentifier("assistant.resize-divider")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onNudge(24)
                case .decrement:
                    onNudge(-24)
                @unknown default:
                    break
                }
            }
    }
}

private struct AssistantFloatingButton: View {
    let isOverTaskTerminal: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TodoAgentBrandMarkView(size: 28)
                .frame(
                    width: TodoAgentUI.floatingButtonSize,
                    height: TodoAgentUI.floatingButtonSize
                )
                .background(TodoAgentUI.surfaceBackground, in: .circle)
                .overlay {
                    Circle()
                        .stroke(TodoAgentUI.hairline, lineWidth: 1)
                }
                .shadow(color: TodoAgentUI.shadowColor, radius: 12, y: 5)
        }
        .buttonStyle(.plain)
        .contentShape(.circle)
        .help("打开 TodoAgent")
        .accessibilityLabel("打开 TodoAgent")
        .accessibilityHint(
            isOverTaskTerminal
                ? "在当前任务终端上方打开 TodoAgent"
                : "打开 TodoAgent 对话面板"
        )
        .accessibilityIdentifier("assistant.floating-button")
    }
}

#Preview("完整演示") {
    ContentView(repository: DemoRepository(now: Date(timeIntervalSince1970: 1_786_080_000)))
}

#Preview("空任务") {
    ContentView(repository: EmptyPreviewRepository())
}

private actor EmptyPreviewRepository: AppRepository {
    private let snapshot = AppSnapshot(revision: 0, lists: [], tasks: [], runtimes: [], sessions: [], messages: [])

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createList(name: String, color: String) async throws -> AppSnapshot { snapshot }
    func createTask(
        title: String,
        note: String,
        listID: UUID?,
        executionDate: LocalDay?,
        dueDate: LocalDay?
    ) async throws -> AppSnapshot { snapshot }
    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot { snapshot }
    func deleteTask(taskID: UUID) async throws -> AppSnapshot { snapshot }
    func createListFromTask(taskID: UUID) async throws -> AppSnapshot { snapshot }
    func addTaskAttachments(taskID: UUID, sourcePaths: [String], clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func removeTaskAttachment(taskID: UUID, attachmentID: UUID, clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot { snapshot }
    func detectRuntimes() async throws -> AppSnapshot { snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }
    func session(taskID: UUID) async throws -> SessionBundle? { nil }
    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle { throw AppRepositoryError.sessionNotFound }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {}
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Gemini Preview", version: "preview")
    }
    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(configured: false, available: false, model: nil, reason: "尚未配置 Gemini API Key。")
    }
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] { [] }
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func sendAssistantMessage(sessionID: String, clientMessageID: UUID, text: String, model: String, attachments: [AssistantTextAttachment]) async throws -> AssistantSessionBundle { throw AppRepositoryError.assistantSessionNotFound }
    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async {}
}
