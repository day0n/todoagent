import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    /// Internal UI event emitted after the New Task command resolves the active
    /// board context. Only the composer currently on screen responds.
    static let todoAgentFocusTaskComposer = Notification.Name("TodoAgent.focusTaskComposer")
}

struct BoardView: View {
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    @Binding var workspaceVisuallyMounted: Bool
    let geometryRequestGeneration: UInt64
    let onAvailableWidthChange: @MainActor (CGFloat) -> Void
    @State private var pendingAutomaticCloseTaskID: UUID?
    @State private var mountedWorkspaceTaskID: UUID?
    @State private var workspaceChromePresented = false
    @State private var workspaceRevealProgress: CGFloat = 0
    @State private var workspaceTransitionGeneration = 0
    @State private var workspaceDismissalTaskID: UUID?
    @State private var workspaceDismissalAnimationCompletedTaskID: UUID?
    @State private var workspaceChromeAnimationTarget: Bool?
    @State private var workspaceChromeAnimationGeneration = 0
    @State private var workspaceSwitchState = TaskWorkspaceSwitchState()
    @State private var workspaceRailVisibility: TaskWorkspaceRailVisibility?
    @State private var workspaceTerminalLiveWidth: CGFloat?
    @AppStorage(TaskWorkspaceTerminalPanePreferences.widthKey)
    private var storedWorkspaceTerminalWidth = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let resolvedRailVisibility = TaskWorkspaceLayoutPolicy.railVisibility(
                availableWidth: proxy.size.width,
                previous: workspaceRailVisibility
            )
            let preferredTerminalWidth = workspaceTerminalLiveWidth
                ?? persistedWorkspaceTerminalWidth
            let resolvedWorkspaceLayout = TaskWorkspaceRevealLayoutPolicy.resolve(
                availableWidth: proxy.size.width,
                railVisibility: resolvedRailVisibility,
                preferredTerminalWidth: preferredTerminalWidth
            )
            let terminalResizeEnabled = workspaceChromePresented
                && workspaceChromeAnimationTarget == nil
                && workspaceSwitchState.isActive == false
            TaskWorkspaceSynchronizedLayout(
                railVisibility: resolvedRailVisibility,
                preferredTerminalWidth: preferredTerminalWidth,
                revealProgress: workspaceRevealProgress
            ) {
                TaskListView(
                    state: state,
                    taskWorkspace: taskWorkspace,
                    expandedPaneWidth: proxy.size.width,
                    collapsedPaneWidth: resolvedWorkspaceLayout.railWidth,
                    selectedWorkspaceTaskID: mountedWorkspaceTaskID,
                    pendingWorkspaceTaskID: workspaceSwitchState.requestedTaskID
                        ?? taskWorkspace.pendingTaskID,
                    receivesComposerFocus: workspaceChromeAnimationTarget == nil
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(workspaceChromeAnimationTarget == nil)
                .accessibilityHidden(workspaceChromeAnimationTarget != nil)

                TaskWorkspaceTerminalSlot(
                    taskID: mountedWorkspaceTaskID,
                    state: state,
                    taskWorkspace: taskWorkspace,
                    railVisibility: resolvedRailVisibility,
                    switchVeilPresented: workspaceSwitchState.veilPresented,
                    terminalWidth: resolvedWorkspaceLayout.terminalWidth
                )
                .allowsHitTesting(terminalResizeEnabled)
                .accessibilityHidden(!terminalResizeEnabled)
                .zIndex(1)
            }
            .overlay(alignment: .topLeading) {
                TaskWorkspaceTerminalResizeDivider(
                    terminalWidth: resolvedWorkspaceLayout.terminalWidth,
                    isEnabled: terminalResizeEnabled,
                    onResizeChanged: { proposedWidth in
                        updateWorkspaceTerminalWidth(
                            proposedWidth,
                            availableWidth: proxy.size.width,
                            railVisibility: resolvedRailVisibility
                        )
                    },
                    onResizeEnded: { proposedWidth in
                        commitWorkspaceTerminalWidth(
                            proposedWidth,
                            availableWidth: proxy.size.width,
                            railVisibility: resolvedRailVisibility
                        )
                    }
                )
                .offset(
                    x: TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetOrigin(
                        dividerX: resolvedWorkspaceLayout.dividerX(
                            revealProgress: workspaceRevealProgress
                        ),
                        visibleDividerWidth: TaskWorkspaceLayoutPolicy.dividerWidth
                    )
                )
                .accessibilityHidden(!terminalResizeEnabled)
                .id(mountedWorkspaceTaskID)
                .zIndex(2)
            }
            .clipped()
            .onAppear {
                updateWorkspaceRailVisibility(availableWidth: proxy.size.width)
                onAvailableWidthChange(proxy.size.width)
            }
            .onChange(of: proxy.size.width) { _, width in
                updateWorkspaceRailVisibility(availableWidth: width)
                onAvailableWidthChange(width)
            }
            .onChange(of: geometryRequestGeneration) { _, _ in
                // This callback is a layout acknowledgement, not a timer. It
                // also fires when a Sidebar overlay changes visibility without
                // changing the Board's measured width.
                onAvailableWidthChange(proxy.size.width)
            }
        }
        .clipped()
        .navigationTitle(state.titleForSelection())
        .background(TodoAgentUI.canvasBackground)
        .onAppear {
            workspaceVisuallyMounted = mountedWorkspaceTaskID != nil
            updateWorkspacePresentation(taskWorkspace.presentedTaskID)
        }
        .onDisappear {
            workspaceVisuallyMounted = false
            onAvailableWidthChange(0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewTask)) { _ in
            focusComposerForCurrentContext()
        }
        .onChange(of: visibleTaskIDs) { previousTaskIDs, taskIDs in
            requestAutomaticCloseIfNeeded(
                previousVisibleTaskIDs: previousTaskIDs,
                visibleTaskIDs: taskIDs
            )
        }
        .onChange(of: automaticCloseRetryReady) { _, isReady in
            guard isReady, let taskID = pendingAutomaticCloseTaskID else { return }
            taskWorkspace.closeTaskWorkspace(taskID: taskID)
        }
        .onChange(of: taskWorkspace.presentedTaskID) { _, taskID in
            if taskID != pendingAutomaticCloseTaskID {
                pendingAutomaticCloseTaskID = nil
            }
            updateWorkspacePresentation(taskID)
        }
        .onChange(of: taskWorkspace.closingTaskID) { _, closingTaskID in
            guard closingTaskID == mountedWorkspaceTaskID else {
                if closingTaskID == nil {
                    updateWorkspacePresentation(taskWorkspace.presentedTaskID)
                }
                return
            }
            hideMountedWorkspace()
        }
    }

    private var visibleTaskIDs: Set<UUID> {
        Set(state.displayedTasks(for: state.selection).map(\.id))
    }

    private var persistedWorkspaceTerminalWidth: CGFloat? {
        storedWorkspaceTerminalWidth > 0
            ? CGFloat(storedWorkspaceTerminalWidth)
            : nil
    }

    private func updateWorkspaceTerminalWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility
    ) {
        let width = TaskWorkspaceRevealLayoutPolicy.clampedTerminalWidth(
            proposedWidth,
            availableWidth: availableWidth,
            railVisibility: railVisibility
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            workspaceTerminalLiveWidth = width
        }
    }

    private func commitWorkspaceTerminalWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility
    ) {
        let width = TaskWorkspaceRevealLayoutPolicy.clampedTerminalWidth(
            proposedWidth,
            availableWidth: availableWidth,
            railVisibility: railVisibility
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            storedWorkspaceTerminalWidth = Double(width)
            workspaceTerminalLiveWidth = nil
        }
    }

    private func updateWorkspaceRailVisibility(availableWidth: CGFloat) {
        let next = TaskWorkspaceLayoutPolicy.railVisibility(
            availableWidth: availableWidth,
            previous: workspaceRailVisibility
        )
        guard next != workspaceRailVisibility else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            workspaceRailVisibility = next
        }
    }

    private var automaticCloseRetryReady: Bool {
        guard let taskID = pendingAutomaticCloseTaskID else { return false }
        return TaskWorkspaceScopeClosePolicy.shouldRetryAutomaticClose(
            pendingTaskID: taskID,
            presentedTaskID: taskWorkspace.presentedTaskID,
            visibleTaskIDs: visibleTaskIDs,
            saveState: state.taskSaveState(taskID: taskID)
        )
    }

    private func requestAutomaticCloseIfNeeded(
        previousVisibleTaskIDs: Set<UUID>,
        visibleTaskIDs: Set<UUID>
    ) {
        guard let taskID = taskWorkspace.presentedTaskID else {
            pendingAutomaticCloseTaskID = nil
            return
        }
        guard visibleTaskIDs.contains(taskID) == false else {
            if pendingAutomaticCloseTaskID == taskID {
                pendingAutomaticCloseTaskID = nil
            }
            return
        }
        guard TaskWorkspaceScopeClosePolicy.didLeaveScope(
            taskID: taskID,
            previousVisibleTaskIDs: previousVisibleTaskIDs,
            visibleTaskIDs: visibleTaskIDs
        ) else { return }
        pendingAutomaticCloseTaskID = taskID
        taskWorkspace.closeTaskWorkspace(taskID: taskID)
    }

    private func focusComposerForCurrentContext() {
        if taskWorkspace.presentedTaskID != nil {
            switch state.selection {
            case .smart(.running), .smart(.done), nil:
                state.selection = .smart(.tasks)
            case .smart(.myDay), .smart(.tasks), .list:
                break
            }
            postComposerFocus()
            return
        }

        switch state.selection {
        case .smart(.running), .smart(.done), nil:
            state.selection = .smart(.tasks)
        case .smart(.myDay), .smart(.tasks), .list:
            break
        }

        postComposerFocus()
    }

    private func postComposerFocus() {
        // Navigation may replace the board subtree. Deliver focus on the next
        // main-run-loop turn so the destination composer has mounted.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .todoAgentFocusTaskComposer, object: nil)
        }
    }

    private func updateWorkspacePresentation(_ taskID: UUID?) {
        guard let taskID else {
            dismissMountedWorkspace()
            return
        }

        guard mountedWorkspaceTaskID != taskID else {
            if taskWorkspace.closingTaskID != taskID {
                showMountedWorkspace()
            }
            return
        }

        transitionToWorkspace(taskID)
    }

    private func transitionToWorkspace(_ taskID: UUID) {
        workspaceTransitionGeneration &+= 1
        let generation = workspaceTransitionGeneration
        guard mountedWorkspaceTaskID != nil else {
            mountIncomingWorkspace(taskID, generation: generation)
            return
        }

        workspaceDismissalTaskID = nil
        workspaceDismissalAnimationCompletedTaskID = nil
        workspaceSwitchState.request(taskID)

        // A task-to-task switch keeps the terminal panel at its current
        // position and size. If a real close was already moving it away,
        // reverse that chrome motion while the internal veil hides the swap.
        if workspaceChromePresented == false || workspaceChromeAnimationTarget == false {
            animateWorkspaceChrome(to: true)
        }
        animateWorkspaceSwitchVeil(to: true)
    }

    private func mountIncomingWorkspace(_ taskID: UUID, generation: Int) {
        guard workspaceTransitionGeneration == generation,
              taskWorkspace.presentedTaskID == taskID,
              taskWorkspace.closingTaskID != taskID
        else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mountedWorkspaceTaskID = taskID
            workspaceVisuallyMounted = true
            workspaceChromePresented = false
            workspaceRevealProgress = 0
            workspaceDismissalTaskID = nil
            workspaceDismissalAnimationCompletedTaskID = nil
            workspaceChromeAnimationTarget = nil
            workspaceSwitchState.reset()
        }

        Task { @MainActor in
            await Task.yield()
            guard workspaceTransitionGeneration == generation,
                  mountedWorkspaceTaskID == taskID,
                  taskWorkspace.presentedTaskID == taskID,
                  taskWorkspace.closingTaskID != taskID
            else { return }
            animateWorkspaceChrome(to: true)
        }
    }

    private func dismissMountedWorkspace() {
        guard let taskID = mountedWorkspaceTaskID else { return }
        cancelWorkspaceSwitch()
        if workspaceChromeAnimationTarget == false { return }
        if workspaceDismissalTaskID == taskID {
            if workspaceDismissalAnimationCompletedTaskID == taskID {
                unmountWorkspace(taskID)
            }
            return
        }
        beginWorkspaceDismissal(taskID)
    }

    private func showMountedWorkspace() {
        workspaceTransitionGeneration &+= 1
        workspaceDismissalTaskID = nil
        workspaceDismissalAnimationCompletedTaskID = nil
        cancelWorkspaceSwitch()
        animateWorkspaceChrome(to: true)
    }

    private func hideMountedWorkspace() {
        guard let taskID = mountedWorkspaceTaskID else { return }
        guard workspaceDismissalTaskID != taskID else { return }
        beginWorkspaceDismissal(taskID)
    }

    private func beginWorkspaceDismissal(_ taskID: UUID) {
        workspaceTransitionGeneration &+= 1
        let generation = workspaceTransitionGeneration
        cancelWorkspaceSwitch()
        workspaceDismissalTaskID = taskID
        workspaceDismissalAnimationCompletedTaskID = nil
        guard workspaceChromeAnimationTarget != false else { return }
        animateWorkspaceChrome(to: false)
        guard workspaceTransitionGeneration == generation else {
            return
        }
    }

    private func unmountWorkspace(_ taskID: UUID) {
        guard mountedWorkspaceTaskID == taskID,
              taskWorkspace.presentedTaskID == nil
        else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mountedWorkspaceTaskID = nil
            workspaceVisuallyMounted = false
            workspaceRevealProgress = 0
            workspaceDismissalTaskID = nil
            workspaceDismissalAnimationCompletedTaskID = nil
            workspaceChromeAnimationTarget = nil
            workspaceSwitchState.reset()
        }
    }

    private func cancelWorkspaceSwitch() {
        workspaceSwitchState.cancel()
        animateWorkspaceSwitchVeil(to: false)
    }

    private func animateWorkspaceSwitchVeil(to isPresented: Bool) {
        guard let request = workspaceSwitchState.beginVeilAnimation(to: isPresented) else {
            if isPresented, workspaceSwitchState.isFullyCovered {
                swapLatestWorkspaceUnderVeil()
            }
            return
        }

        let complete: @MainActor @Sendable () -> Void = {
            guard workspaceSwitchState.completeVeilAnimation(request) else { return }
            if isPresented {
                swapLatestWorkspaceUnderVeil()
            } else if let taskID = mountedWorkspaceTaskID,
                      taskWorkspace.presentedTaskID == taskID,
                      taskWorkspace.closingTaskID != taskID,
                      workspaceChromePresented
            {
                taskWorkspace.focusActiveTerminal()
            }
        }

        guard workspaceSwitchState.veilPresented != isPresented else {
            complete()
            return
        }
        if let animation = TaskWorkspaceSwitchMotion.animation(
            covering: isPresented,
            reduceMotion: reduceMotion
        ) {
            withAnimation(animation, completionCriteria: .logicallyComplete) {
                workspaceSwitchState.setVeilPresented(isPresented)
            } completion: {
                complete()
            }
        } else {
            workspaceSwitchState.setVeilPresented(isPresented)
            complete()
        }
    }

    private func swapLatestWorkspaceUnderVeil() {
        guard workspaceSwitchState.isFullyCovered else { return }
        guard let taskID = workspaceSwitchState.takeRequestedTaskID() else {
            animateWorkspaceSwitchVeil(to: false)
            return
        }
        guard taskWorkspace.presentedTaskID == taskID,
              taskWorkspace.closingTaskID != taskID
        else {
            if let latestTaskID = taskWorkspace.presentedTaskID,
               taskWorkspace.closingTaskID != latestTaskID,
               latestTaskID != mountedWorkspaceTaskID
            {
                workspaceSwitchState.request(latestTaskID)
                swapLatestWorkspaceUnderVeil()
            } else {
                animateWorkspaceSwitchVeil(to: false)
            }
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            mountedWorkspaceTaskID = taskID
            workspaceVisuallyMounted = true
            workspaceDismissalTaskID = nil
            workspaceDismissalAnimationCompletedTaskID = nil
        }

        Task { @MainActor in
            await Task.yield()
            guard workspaceSwitchState.isFullyCovered else { return }
            if workspaceSwitchState.requestedTaskID != nil {
                swapLatestWorkspaceUnderVeil()
                return
            }
            guard mountedWorkspaceTaskID == taskID,
                  taskWorkspace.presentedTaskID == taskID,
                  taskWorkspace.closingTaskID != taskID
            else {
                if let latestTaskID = taskWorkspace.presentedTaskID,
                   taskWorkspace.closingTaskID != latestTaskID,
                   latestTaskID != mountedWorkspaceTaskID
                {
                    workspaceSwitchState.request(latestTaskID)
                    swapLatestWorkspaceUnderVeil()
                } else {
                    animateWorkspaceSwitchVeil(to: false)
                }
                return
            }
            animateWorkspaceSwitchVeil(to: false)
        }
    }

    private func animateWorkspaceChrome(to isPresented: Bool) {
        guard workspaceChromeAnimationTarget != isPresented else { return }
        workspaceChromeAnimationGeneration &+= 1
        let generation = workspaceChromeAnimationGeneration
        workspaceChromeAnimationTarget = isPresented

        let complete: @MainActor @Sendable () -> Void = {
            guard workspaceChromeAnimationGeneration == generation,
                  workspaceChromeAnimationTarget == isPresented
            else { return }
            workspaceChromeAnimationTarget = nil
            workspaceChromeAnimationDidComplete(isPresented: isPresented)
        }

        guard workspaceChromePresented != isPresented else {
            complete()
            return
        }
        if let animation = TaskWorkspaceMotion.animation(reduceMotion: reduceMotion) {
            withAnimation(animation, completionCriteria: .removed) {
                workspaceChromePresented = isPresented
                workspaceRevealProgress = isPresented ? 1 : 0
            } completion: {
                complete()
            }
        } else {
            workspaceChromePresented = isPresented
            workspaceRevealProgress = isPresented ? 1 : 0
            complete()
        }
    }

    private func workspaceChromeAnimationDidComplete(isPresented: Bool) {
        guard isPresented == false,
              let taskID = mountedWorkspaceTaskID
        else { return }

        workspaceDismissalTaskID = taskID
        workspaceDismissalAnimationCompletedTaskID = taskID

        guard let presentedTaskID = taskWorkspace.presentedTaskID else {
            unmountWorkspace(taskID)
            return
        }
        guard taskWorkspace.closingTaskID != presentedTaskID else { return }

        if presentedTaskID == taskID {
            showMountedWorkspace()
        } else {
            transitionToWorkspace(presentedTaskID)
        }
    }
}

enum TaskWorkspaceRailVisibility: Equatable, Sendable {
    case split
    case compact
}

enum TaskWorkspaceScopeClosePolicy {
    static func didLeaveScope(
        taskID: UUID,
        previousVisibleTaskIDs: Set<UUID>,
        visibleTaskIDs: Set<UUID>
    ) -> Bool {
        previousVisibleTaskIDs.contains(taskID)
            && visibleTaskIDs.contains(taskID) == false
    }

    static func shouldRetryAutomaticClose(
        pendingTaskID: UUID?,
        presentedTaskID: UUID?,
        visibleTaskIDs: Set<UUID>,
        saveState: TaskSaveState
    ) -> Bool {
        guard let pendingTaskID,
              pendingTaskID == presentedTaskID,
              visibleTaskIDs.contains(pendingTaskID) == false
        else { return false }
        return saveState == .idle
    }
}

enum TaskWorkspaceLayoutPolicy {
    static let regularRailWidth: CGFloat = 320
    static let compactRailWidth: CGFloat = 252
    static let defaultOpenRailWidth = compactRailWidth
    static let minimumResizableRailWidth: CGFloat = 200
    static let dividerWidth: CGFloat = 1
    static let terminalPreferredMinimumWidth: CGFloat = 500
    static let terminalAbsoluteMinimumWidth: CGFloat = 320
    static let initialSplitWidth: CGFloat = 830
    static let collapseSplitBelow = regularRailWidth + dividerWidth + terminalPreferredMinimumWidth
    static let restoreSplitAt: CGFloat = 840

    static func railWidth(for visibility: TaskWorkspaceRailVisibility) -> CGFloat {
        visibility == .split ? regularRailWidth : compactRailWidth
    }

    static func railVisibility(
        availableWidth: CGFloat,
        previous: TaskWorkspaceRailVisibility?
    ) -> TaskWorkspaceRailVisibility {
        switch previous {
        case .split:
            availableWidth < collapseSplitBelow ? .compact : .split
        case .compact:
            availableWidth >= restoreSplitAt ? .split : .compact
        case nil:
            availableWidth >= initialSplitWidth ? .split : .compact
        }
    }
}

enum TaskListContentTrackLayoutPolicy {
    static let maximumCardWidth: CGFloat = 780
    static let horizontalPadding: CGFloat = 20
    static let maximumTrackWidth = maximumCardWidth + horizontalPadding * 2

    static func contentWidth(availableWidth: CGFloat) -> CGFloat {
        let safeWidth = max(availableWidth, 0)
        return min(
            maximumCardWidth,
            max(safeWidth - horizontalPadding * 2, 0)
        )
    }

    static func trackWidth(availableWidth: CGFloat) -> CGFloat {
        min(
            contentWidth(availableWidth: availableWidth) + horizontalPadding * 2,
            max(availableWidth, 0)
        )
    }

    /// A normal max-width track does not visibly shrink until a wide pane has
    /// crossed 820 points. During terminal reveal, interpolate the track from
    /// its expanded width to its rail width using the pane's real layout
    /// progress so the task UI moves from the first frame instead of catching
    /// up at the end.
    static func synchronizedContentWidth(
        paneWidth: CGFloat,
        expandedPaneWidth: CGFloat,
        collapsedPaneWidth: CGFloat
    ) -> CGFloat {
        let expanded = max(expandedPaneWidth, 0)
        let collapsed = min(max(collapsedPaneWidth, 0), expanded)
        let travel = expanded - collapsed
        guard travel > 0 else {
            return contentWidth(availableWidth: paneWidth)
        }

        let progress = min(max((expanded - paneWidth) / travel, 0), 1)
        let expandedContent = contentWidth(availableWidth: expanded)
        let collapsedContent = contentWidth(availableWidth: collapsed)
        return expandedContent + (collapsedContent - expandedContent) * progress
    }
}

struct TaskWorkspaceRevealLayout: Equatable, Sendable {
    let railWidth: CGFloat
    let terminalWidth: CGFloat
    let terminalShownX: CGFloat
    let terminalHiddenX: CGFloat

    private var availableWidth: CGFloat {
        max(terminalHiddenX - TaskWorkspaceLayoutPolicy.dividerWidth, 0)
    }

    private var terminalSlotWidth: CGFloat {
        terminalWidth + TaskWorkspaceLayoutPolicy.dividerWidth
    }

    func terminalX(revealProgress: CGFloat) -> CGFloat {
        let progress = min(max(revealProgress, 0), 1)
        return taskPaneWidth(revealProgress: progress)
            + TaskWorkspaceLayoutPolicy.dividerWidth
    }

    func terminalX(isPresented: Bool) -> CGFloat {
        terminalX(revealProgress: isPresented ? 1 : 0)
    }

    func dividerX(revealProgress: CGFloat) -> CGFloat {
        taskPaneWidth(revealProgress: revealProgress)
    }

    func dividerX(isPresented: Bool) -> CGFloat {
        dividerX(revealProgress: isPresented ? 1 : 0)
    }

    func taskPaneWidth(revealProgress: CGFloat) -> CGFloat {
        let progress = min(max(revealProgress, 0), 1)
        return max(availableWidth - terminalSlotWidth * progress, 0)
    }

    func taskPaneWidth(isPresented: Bool) -> CGFloat {
        taskPaneWidth(revealProgress: isPresented ? 1 : 0)
    }

    func terminalReservedWidth(revealProgress: CGFloat) -> CGFloat {
        let progress = min(max(revealProgress, 0), 1)
        return terminalSlotWidth * progress
    }

    func terminalReservedWidth(isPresented: Bool) -> CGFloat {
        terminalReservedWidth(revealProgress: isPresented ? 1 : 0)
    }
}

enum TaskWorkspaceRevealLayoutPolicy {
    static func resolve(
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility,
        preferredTerminalWidth: CGFloat? = nil
    ) -> TaskWorkspaceRevealLayout {
        let safeAvailableWidth = max(availableWidth, 0)
        let range = terminalWidthRange(
            availableWidth: safeAvailableWidth,
            railVisibility: railVisibility
        )
        let contentWidth = max(
            safeAvailableWidth - TaskWorkspaceLayoutPolicy.dividerWidth,
            0
        )
        let automaticTerminalWidth = max(
            contentWidth - TaskWorkspaceLayoutPolicy.defaultOpenRailWidth,
            0
        )
        let requestedTerminalWidth = preferredTerminalWidth ?? automaticTerminalWidth
        let terminalWidth = min(
            max(requestedTerminalWidth, range.lowerBound),
            range.upperBound
        )
        let railWidth = max(
            safeAvailableWidth
                - TaskWorkspaceLayoutPolicy.dividerWidth
                - terminalWidth,
            0
        )
        return TaskWorkspaceRevealLayout(
            railWidth: railWidth,
            terminalWidth: terminalWidth,
            terminalShownX: railWidth + TaskWorkspaceLayoutPolicy.dividerWidth,
            terminalHiddenX: safeAvailableWidth + TaskWorkspaceLayoutPolicy.dividerWidth
        )
    }

    static func terminalWidthRange(
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility
    ) -> ClosedRange<CGFloat> {
        let contentWidth = max(
            max(availableWidth, 0) - TaskWorkspaceLayoutPolicy.dividerWidth,
            0
        )
        let minimumTerminalWidth = min(
            TaskWorkspaceLayoutPolicy.terminalAbsoluteMinimumWidth,
            contentWidth
        )
        let maximumWithUsableTaskRail = max(
            contentWidth - TaskWorkspaceLayoutPolicy.minimumResizableRailWidth,
            0
        )
        // The default rail stays at the screenshot-derived compact width in
        // both density modes. Explicit resizing may take it down to 200pt,
        // which still preserves the completion control and task-open target.
        // On very narrow windows the terminal's absolute minimum wins.
        let maximumTerminalWidth = max(
            minimumTerminalWidth,
            maximumWithUsableTaskRail
        )
        return minimumTerminalWidth ... maximumTerminalWidth
    }

    static func clampedTerminalWidth(
        _ proposedWidth: CGFloat,
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility
    ) -> CGFloat {
        let range = terminalWidthRange(
            availableWidth: availableWidth,
            railVisibility: railVisibility
        )
        return min(max(proposedWidth, range.lowerBound), range.upperBound)
    }

    static func resizedTerminalWidth(
        availableWidth: CGFloat,
        railVisibility: TaskWorkspaceRailVisibility,
        startingWidth: CGFloat,
        dividerTranslation: CGFloat
    ) -> CGFloat {
        clampedTerminalWidth(
            startingWidth - dividerTranslation,
            availableWidth: availableWidth,
            railVisibility: railVisibility
        )
    }
}

struct TaskWorkspaceTerminalResizeInteractionState: Equatable, Sendable {
    private(set) var startingWidth: CGFloat?
    private(set) var latestWidth: CGFloat?

    var isDragging: Bool {
        startingWidth != nil
    }

    mutating func update(
        currentWidth: CGFloat,
        dividerTranslation: CGFloat
    ) -> CGFloat {
        let start = startingWidth ?? currentWidth
        startingWidth = start
        let width = start - dividerTranslation
        latestWidth = width
        return width
    }

    mutating func end(currentWidth: CGFloat) -> CGFloat {
        let width = latestWidth ?? currentWidth
        reset()
        return width
    }

    mutating func reset() {
        startingWidth = nil
        latestWidth = nil
    }
}

enum TaskWorkspaceTerminalResizeInteractionPolicy {
    static let hitTargetWidth: CGFloat = 12
    static let accessibilityStep: CGFloat = 24

    static func hitTargetOrigin(
        dividerX: CGFloat,
        visibleDividerWidth: CGFloat
    ) -> CGFloat {
        dividerX + (visibleDividerWidth - hitTargetWidth) / 2
    }
}

enum TaskWorkspaceTerminalPanePreferences {
    // v1 was used only by local previews. Reset it so the narrower default is
    // visible on first launch instead of inheriting an experimental drag.
    static let widthKey = "taskWorkspaceTerminalWidth.v2"
}

/// Owns the complete drawer geometry. Task width and terminal position are
/// placed from one animatable value, so the shared boundary cannot drift even
/// though the task list performs real responsive layout. Ghostty keeps one
/// fixed final proposal throughout reveal; an explicit divider drag can update
/// that final proposal without becoming a second reveal animation value.
struct TaskWorkspaceSynchronizedLayout: Layout {
    let railVisibility: TaskWorkspaceRailVisibility
    let preferredTerminalWidth: CGFloat?
    var revealProgress: CGFloat

    var animatableData: CGFloat {
        get { revealProgress }
        set { revealProgress = newValue }
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
        let layout = TaskWorkspaceRevealLayoutPolicy.resolve(
            availableWidth: bounds.width,
            railVisibility: railVisibility,
            preferredTerminalWidth: preferredTerminalWidth
        )
        let progress = min(max(revealProgress, 0), 1)
        let taskPaneWidth = layout.taskPaneWidth(revealProgress: progress)
        let terminalSlotWidth = layout.terminalWidth
            + TaskWorkspaceLayoutPolicy.dividerWidth

        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: taskPaneWidth, height: bounds.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + taskPaneWidth, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: terminalSlotWidth, height: bounds.height)
        )
    }
}

enum TaskWorkspaceMotion {
    static let duration: TimeInterval = 0.34

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: duration)
    }
}

struct TaskWorkspaceSwitchAnimationRequest: Equatable, Sendable {
    let veilPresented: Bool
    let generation: UInt64
}

struct TaskWorkspaceSwitchState: Equatable, Sendable {
    private(set) var requestedTaskID: UUID?
    private(set) var veilPresented = false
    private(set) var animationTarget: Bool?
    private var animationGeneration: UInt64 = 0

    var isActive: Bool {
        requestedTaskID != nil || veilPresented || animationTarget != nil
    }

    var isFullyCovered: Bool {
        veilPresented && animationTarget == nil
    }

    mutating func request(_ taskID: UUID) {
        requestedTaskID = taskID
    }

    mutating func cancel() {
        requestedTaskID = nil
    }

    mutating func takeRequestedTaskID() -> UUID? {
        defer { requestedTaskID = nil }
        return requestedTaskID
    }

    mutating func beginVeilAnimation(
        to isPresented: Bool
    ) -> TaskWorkspaceSwitchAnimationRequest? {
        guard animationTarget != isPresented else { return nil }
        guard animationTarget != nil || veilPresented != isPresented else { return nil }
        animationGeneration &+= 1
        animationTarget = isPresented
        return TaskWorkspaceSwitchAnimationRequest(
            veilPresented: isPresented,
            generation: animationGeneration
        )
    }

    mutating func setVeilPresented(_ isPresented: Bool) {
        veilPresented = isPresented
    }

    mutating func completeVeilAnimation(
        _ request: TaskWorkspaceSwitchAnimationRequest
    ) -> Bool {
        guard animationGeneration == request.generation,
              animationTarget == request.veilPresented
        else { return false }
        animationTarget = nil
        return true
    }

    mutating func reset() {
        animationGeneration &+= 1
        requestedTaskID = nil
        veilPresented = false
        animationTarget = nil
    }
}

enum TaskWorkspaceSwitchMotion {
    static let coverDuration: TimeInterval = 0.07
    static let revealDuration: TimeInterval = 0.11

    static func animation(covering: Bool, reduceMotion: Bool) -> Animation? {
        guard reduceMotion == false else { return nil }
        return .easeOut(duration: covering ? coverDuration : revealDuration)
    }
}

private struct TaskWorkspaceTerminalSlot: View {
    let taskID: UUID?
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    let railVisibility: TaskWorkspaceRailVisibility
    let switchVeilPresented: Bool
    let terminalWidth: CGFloat

    var body: some View {
        Group {
            if let taskID {
                TaskSplitWorkspace(
                    taskID: taskID,
                    state: state,
                    taskWorkspace: taskWorkspace,
                    railVisibility: railVisibility,
                    switchVeilPresented: switchVeilPresented,
                    terminalWidth: terminalWidth
                )
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct TaskSplitWorkspace: View {
    let taskID: UUID
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    let railVisibility: TaskWorkspaceRailVisibility
    let switchVeilPresented: Bool
    let terminalWidth: CGFloat

    var body: some View {
        let layoutState = taskWorkspace.layoutState(for: taskID)
        let isClosing = taskWorkspace.closingTaskID == taskID

        HStack(spacing: 0) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(width: TaskWorkspaceLayoutPolicy.dividerWidth)
                .accessibilityHidden(true)

            ZStack {
                TaskWorkbenchView(
                    taskID: taskID,
                    state: state,
                    terminalSessions: taskWorkspace.terminalSessions,
                    layoutState: layoutState,
                    toggleTaskDetails: {},
                    requestClose: {
                        taskWorkspace.closeTaskWorkspace(taskID: taskID)
                    },
                    presentation: .embedded(compact: railVisibility == .compact),
                    isClosing: isClosing
                )
                .id(taskID)
                // Reveal changes only the slot's position. A divider drag may
                // update its final width, but never replaces the Ghostty view.
                .transaction { transaction in
                    transaction.animation = nil
                }

                Rectangle()
                    .fill(Color(nsColor: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1)))
                    .opacity(switchVeilPresented ? 1 : 0)
                    .allowsHitTesting(switchVeilPresented)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TodoAgentUI.canvasBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            taskWorkspace.updateActiveWorkspaceCompactState(
                taskID: taskID,
                isCompact: railVisibility == .compact
            )
        }
        .onChange(of: railVisibility) { _, next in
            taskWorkspace.updateActiveWorkspaceCompactState(
                taskID: taskID,
                isCompact: next == .compact
            )
        }
        .onChange(of: taskID) { _, nextTaskID in
            taskWorkspace.updateActiveWorkspaceCompactState(
                taskID: nextTaskID,
                isCompact: railVisibility == .compact
            )
        }
        .accessibilityIdentifier("task.workspace.split")
    }
}

private struct TaskWorkspaceTerminalResizeDivider: View {
    let terminalWidth: CGFloat
    let isEnabled: Bool
    let onResizeChanged: (CGFloat) -> Void
    let onResizeEnded: (CGFloat) -> Void

    @State private var interactionState = TaskWorkspaceTerminalResizeInteractionState()

    var body: some View {
        HorizontalResizeHandle(
            isEnabled: isEnabled,
            onDragChanged: { translation in
                let width = interactionState.update(
                    currentWidth: terminalWidth,
                    dividerTranslation: translation
                )
                onResizeChanged(width)
            },
            onDragEnded: { translation in
                _ = interactionState.update(
                    currentWidth: terminalWidth,
                    dividerTranslation: translation
                )
                onResizeEnded(interactionState.end(currentWidth: terminalWidth))
            }
        )
            .frame(width: TaskWorkspaceTerminalResizeInteractionPolicy.hitTargetWidth)
            .frame(maxHeight: .infinity)
            .accessibilityElement()
            .accessibilityLabel("调整终端宽度")
            .accessibilityValue("宽度 \(Int(terminalWidth)) 点")
            .accessibilityHint("左右拖动调整终端大小")
            .accessibilityIdentifier("task.workspace.resize-divider")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    onResizeEnded(
                        terminalWidth
                            + TaskWorkspaceTerminalResizeInteractionPolicy.accessibilityStep
                    )
                case .decrement:
                    onResizeEnded(
                        terminalWidth
                            - TaskWorkspaceTerminalResizeInteractionPolicy.accessibilityStep
                    )
                @unknown default:
                    break
                }
            }
    }
}

private struct TaskListView: View {
    let state: AppState
    let taskWorkspace: TaskWorkspaceCoordinator
    let expandedPaneWidth: CGFloat
    let collapsedPaneWidth: CGFloat
    var selectedWorkspaceTaskID: UUID?
    var pendingWorkspaceTaskID: UUID?
    var receivesComposerFocus: Bool
    @State private var detailsSelection: TaskDetailsPopoverSelection?

    init(
        state: AppState,
        taskWorkspace: TaskWorkspaceCoordinator,
        expandedPaneWidth: CGFloat,
        collapsedPaneWidth: CGFloat,
        selectedWorkspaceTaskID: UUID? = nil,
        pendingWorkspaceTaskID: UUID? = nil,
        receivesComposerFocus: Bool = true
    ) {
        self.state = state
        self.taskWorkspace = taskWorkspace
        self.expandedPaneWidth = expandedPaneWidth
        self.collapsedPaneWidth = collapsedPaneWidth
        self.selectedWorkspaceTaskID = selectedWorkspaceTaskID
        self.pendingWorkspaceTaskID = pendingWorkspaceTaskID
        self.receivesComposerFocus = receivesComposerFocus
    }

    var body: some View {
        let tasks = displayedTasks
        let sections = TaskStatusSections(
            tasks: tasks,
            pinnedTaskID: detailsSelection?.taskID,
            pinnedStatus: detailsSelection?.originalStatus
        )

        GeometryReader { proxy in
            let contentWidth = TaskListContentTrackLayoutPolicy.synchronizedContentWidth(
                paneWidth: proxy.size.width,
                expandedPaneWidth: expandedPaneWidth,
                collapsedPaneWidth: collapsedPaneWidth
            )

            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: TodoAgentUI.standardSpacing) {
                        if tasks.isEmpty {
                            ContentUnavailableView(
                                "没有任务",
                                systemImage: "checklist",
                                description: Text(emptyDescription)
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        } else {
                            ForEach(sections.rows) { row in
                                switch row {
                                case let .completedHeader(hasOpenTasks):
                                CompletedTasksSectionHeader(
                                    hasOpenTasks: hasOpenTasks,
                                    accessibilityIdentifier: completedSectionIdentifier
                                )
                                case let .task(task):
                                    TaskCard(
                                        task: task,
                                        state: state,
                                        detailsSelection: $detailsSelection,
                                        isWorkspaceSelected: task.id == selectedWorkspaceTaskID,
                                        isWorkspacePending: task.id == pendingWorkspaceTaskID,
                                        liveSession: taskWorkspace.terminalSessions.controller(for: task.id)
                                    )
                                }
                            }
                        }
                    }
                    .frame(width: contentWidth)
                    .padding(.horizontal, TaskListContentTrackLayoutPolicy.horizontalPadding)
                    .padding(.vertical, TaskListContentTrackLayoutPolicy.horizontalPadding)
                    .frame(maxWidth: .infinity, alignment: .center)
                }

                if let addTaskDestination {
                    InlineAddTaskComposer(
                        state: state,
                        destination: addTaskDestination,
                        composerState: taskWorkspace.composerState(for: addTaskDestination),
                        contentWidth: contentWidth,
                        receivesFocusNotifications: receivesComposerFocus
                    )
                    .id(addTaskDestination)
                }

                if let parkedTask {
                    ParkedTerminalDock(task: parkedTask) {
                        state.openTask(parkedTask)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TodoAgentUI.canvasBackground)
        }
    }

    private var addTaskDestination: InlineAddTaskDestination? {
        switch state.selection {
        case .smart(.myDay):
            .myDay
        case .smart(.tasks):
            .allTasks
        case let .list(id):
            .list(id)
        default:
            nil
        }
    }

    private var parkedTask: TaskItem? {
        guard taskWorkspace.presentedTaskID == nil,
              let taskID = taskWorkspace.selectedTaskID,
              let task = state.task(id: taskID),
              state.session(for: task)?.state.isBusy == true
        else { return nil }
        return task
    }

    private var displayedTasks: [TaskItem] {
        let scopedTasks = state.displayedTasks(for: state.selection)
        guard let selectedWorkspaceTaskID,
              scopedTasks.contains(where: { $0.id == selectedWorkspaceTaskID }) == false,
              let selectedTask = state.task(id: selectedWorkspaceTaskID)
        else { return scopedTasks }

        // A Today/filter mutation is optimistic. Keep the open card reachable
        // until the workspace flush succeeds so a failed save still exposes
        // its inline retry action instead of stranding an unlisted terminal.
        return [selectedTask] + scopedTasks
    }

    private var completedSectionIdentifier: String {
        switch state.selection {
        case .smart(.myDay):
            "my-day.completed-section"
        case .smart(.tasks):
            "task-list.completed-section"
        case .smart(.running):
            "running.completed-section"
        case .smart(.done):
            "done.completed-section"
        case let .list(id):
            "task-list.\(id.uuidString).completed-section"
        case nil:
            "task-list.completed-section"
        }
    }

    private var emptyDescription: String {
        switch state.selection {
        case .smart(.myDay):
            "今天还没有安排。使用下方的“添加任务”创建，或从“任务”加入。"
        case .smart(.running):
            "当前没有正在运行的本地 Session。"
        case .smart(.done):
            "完成任务后会显示在这里。"
        case .smart(.tasks), .list:
            "使用下方的“添加任务”创建第一项。"
        default:
            "当前列表为空。"
        }
    }
}

private struct ParkedTerminalDock: View {
    let task: TaskItem
    let reopen: () -> Void

    var body: some View {
        Button(action: reopen) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.green.opacity(0.8), radius: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("终端仍在运行 · 收起不是结束")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Text("打开")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(TodoAgentUI.sidebarBackground)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)
        }
        .accessibilityLabel("重新打开 \(task.title) 的终端，终端仍在运行")
        .accessibilityIdentifier("task.workspace.parked-terminal")
    }
}

private struct CompletedTasksSectionHeader: View {
    let hasOpenTasks: Bool
    let accessibilityIdentifier: String

    var body: some View {
        HStack {
            Text("已完成")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: .rect(cornerRadius: 5))
            Spacer(minLength: 0)
        }
        .padding(.top, hasOpenTasks ? TodoAgentUI.compactSpacing : 0)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

enum InlineAddTaskDestination: Hashable {
    case myDay
    case allTasks
    case list(UUID)

    var listID: UUID? {
        switch self {
        case .myDay, .allTasks: nil
        case let .list(id): id
        }
    }

    func executionDate(today: LocalDay) -> LocalDay? {
        self == .myDay ? today : nil
    }

    var accessibilityIdentifier: String {
        switch self {
        case .myDay:
            "my-day.add-task"
        case .allTasks:
            "task-list.add-task"
        case let .list(id):
            "task-list.\(id.uuidString).add-task"
        }
    }
}

@MainActor
@Observable
final class InlineAddTaskComposerState {
    var draft = ""
    var isSubmitting = false
}

private struct InlineAddTaskComposer: View {
    let state: AppState
    let destination: InlineAddTaskDestination
    @Bindable var composerState: InlineAddTaskComposerState
    let contentWidth: CGFloat
    let receivesFocusNotifications: Bool

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(TodoAgentUI.hairline)
                .frame(height: 1)

            HStack(spacing: TodoAgentUI.standardSpacing) {
                Image(systemName: "plus")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(TodoAgentUI.secondaryText)
                    .accessibilityHidden(true)

                TextField("添加任务", text: $composerState.draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit(submit)
                    .onExitCommand(perform: cancelEditing)
                    .accessibilityLabel("添加任务")
                    .accessibilityHint("输入任务标题并按回车创建，按 Escape 清空")
                    .accessibilityIdentifier(destination.accessibilityIdentifier)

                if composerState.isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在添加任务")
                }
            }
            .font(.callout)
            .foregroundStyle(TodoAgentUI.primaryText)
            .padding(.horizontal, TodoAgentUI.cardPadding)
            .frame(width: contentWidth)
            .frame(minHeight: 44)
            .background(TodoAgentUI.surfaceBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                    .stroke(TodoAgentUI.hairline, lineWidth: 1)
            }
            .padding(.horizontal, TaskListContentTrackLayoutPolicy.horizontalPadding)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .background(TodoAgentUI.canvasBackground)
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentFocusTaskComposer)) { _ in
            guard receivesFocusNotifications else { return }
            isFocused = true
        }
    }

    private func submit() {
        let submittedDraft = composerState.draft
        let title = composerState.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !composerState.isSubmitting else { return }

        composerState.isSubmitting = true
        Task { @MainActor in
            let succeeded = await state.createTask(
                title: title,
                listID: destination.listID,
                executionDate: destination.executionDate(today: state.currentDay),
                dueDate: nil
            )
            composerState.isSubmitting = false
            if succeeded, composerState.draft == submittedDraft {
                composerState.draft = ""
            }
        }
    }

    private func cancelEditing() {
        composerState.draft = ""
        isFocused = false
    }
}

enum TaskCardTextTruncation: Equatable, Sendable {
    case tail
}

enum TaskCardNarrowLayoutPolicy {
    static let textLineLimit = 1
    static let textTruncation: TaskCardTextTruncation = .tail
    static let allowsTextTightening = false
    static let completionControlSize: CGFloat = 22

    static var swiftUITruncationMode: Text.TruncationMode {
        switch textTruncation {
        case .tail:
            .tail
        }
    }

    static func reservesAgentIndicatorSpace(
        isWorkspacePending: Bool,
        isRunning: Bool,
        hasUnread: Bool,
        showsRuntime: Bool = false
    ) -> Bool {
        isWorkspacePending || isRunning || hasUnread || showsRuntime
    }

    static func sessionTargetWidth(railWidth: CGFloat) -> CGFloat {
        let cardWidth = TaskListContentTrackLayoutPolicy.contentWidth(
            availableWidth: railWidth
        )
        let innerWidth = max(cardWidth - TodoAgentUI.cardPadding * 2, 0)
        return max(
            innerWidth - completionControlSize - TodoAgentUI.standardSpacing,
            0
        )
    }
}

enum TaskCardActivationSource: Equatable, Sendable {
    case primaryClick
    case terminalContextMenu
}

enum TaskCardActivationDestination: Equatable, Sendable {
    case detailsPopover
    case terminalWorkspace
}

enum TaskCardInteractionPolicy {
    static func destination(
        for source: TaskCardActivationSource
    ) -> TaskCardActivationDestination {
        switch source {
        case .primaryClick:
            .detailsPopover
        case .terminalContextMenu:
            .terminalWorkspace
        }
    }
}

enum TaskCardMetadataLayoutPolicy {
    static func reservesLine(
        whileDetailsArePresented: Bool,
        hasVisibleMetadata: Bool
    ) -> Bool {
        whileDetailsArePresented && !hasVisibleMetadata
    }
}

struct TaskDetailsPopoverSelection: Equatable, Sendable {
    let taskID: UUID
    let originalStatus: TaskStatus
}

struct TaskCard: View {
    let task: TaskItem
    let state: AppState
    @Binding private var detailsSelection: TaskDetailsPopoverSelection?
    let isWorkspaceSelected: Bool
    let isWorkspacePending: Bool
    let liveSession: TerminalSessionController?

    init(
        task: TaskItem,
        state: AppState,
        detailsSelection: Binding<TaskDetailsPopoverSelection?> = .constant(nil),
        isWorkspaceSelected: Bool = false,
        isWorkspacePending: Bool = false,
        liveSession: TerminalSessionController? = nil
    ) {
        self.task = task
        self.state = state
        _detailsSelection = detailsSelection
        self.isWorkspaceSelected = isWorkspaceSelected
        self.isWorkspacePending = isWorkspacePending
        self.liveSession = liveSession
    }

    @State private var datePickerRequest: TaskDatePickerRequest?
    @State private var isConfirmingDelete = false
    @State private var contextHighlight = TaskContextHighlightState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var agentStatus: TaskCardAgentStatus {
        let session = liveSession?.session ?? state.session(for: task)
        return TaskCardAgentStatus(
            session: session,
            displayRuntime: liveSession?.displayRuntime,
            hasHostAttention: liveSession?.needsAttention == true
        )
    }

    private var reservesAgentIndicatorSpace: Bool {
        TaskCardNarrowLayoutPolicy.reservesAgentIndicatorSpace(
            isWorkspacePending: isWorkspacePending,
            isRunning: agentStatus.isRunning,
            hasUnread: agentStatus.hasUnread,
            showsRuntime: agentStatus.showsRuntime
        )
    }

    private var isCardSelected: Bool {
        isWorkspaceSelected || isDetailsPresented
    }

    private var isDetailsPresented: Bool {
        detailsSelection?.taskID == task.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: TodoAgentUI.standardSpacing) {
                completionButton
                detailsButton
            }
            .padding(TodoAgentUI.cardPadding)
            .overlay(alignment: .bottom) {
                detailsPopoverAnchor
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(cardAccessibilityLabel)

            if case let .failed(message) = state.taskSaveState(taskID: task.id) {
                Divider()
                taskSaveFailure(message)
            }
        }
        .background(taskCardBackground, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(
                    borderColor,
                    lineWidth: agentStatus.isRunning || isCardSelected ? 1.5 : 1
                )
        }
        .shadow(
            color: cardShadowColor,
            radius: agentStatus.isRunning ? 10 : (contextHighlight.isHighlighted ? 9 : 5),
            y: agentStatus.isRunning ? 0 : (contextHighlight.isHighlighted ? 4 : 2)
        )
        .accessibilityIdentifier("task.\(task.id.uuidString).card")
        .accessibilityAddTraits(isCardSelected ? .isSelected : [])
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.12),
            value: isCardSelected
        )
        .contextMenu {
            taskContextMenu
        }
        .onHover { contextHighlight.pointerInside = $0 }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            contextHighlight.menuDidBeginTracking()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            contextHighlight.menuDidEndTracking()
        }
        .popover(item: $datePickerRequest) { request in
            TaskDatePickerPopover(request: request) { day in
                setDate(day, for: request.field)
            }
        }
        .alert("删除任务？", isPresented: $isConfirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除任务", role: .destructive) {
                Task { _ = await state.deleteTask(taskID: task.id) }
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.deleteConfirmation)
        } message: {
            Text("“\(task.title)”将被永久删除，此操作无法撤销。")
        }
    }

    @ViewBuilder
    private var taskContextMenu: some View {
        let presentation = TaskContextMenuPresentation(task: task, lists: state.lists)

        Button {
            performActivation(from: .terminalContextMenu)
        } label: {
            Label("打开终端", systemImage: "terminal")
        }
        .accessibilityIdentifier(TaskContextMenuAccessibility.terminal)

        Divider()

        Button {
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(
                    status: task.status == .open ? .completed : .open
                )
            )
        } label: {
            Label(presentation.completionTitle, systemImage: presentation.completionSystemImage)
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.completion)

        Divider()

        Button {
            state.setTask(task, inMyDay: state.isTaskInMyDay(task) == false)
        } label: {
            Label(
                state.isTaskInMyDay(task) ? "移出今天" : "加入今天",
                systemImage: state.isTaskInMyDay(task) ? "sun.max.fill" : "sun.max"
            )
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.myDay)

        taskDateMenu(field: .due, presentation: presentation)

        Divider()

        Button {
            Task { _ = await state.createListFromTask(taskID: task.id) }
        } label: {
            Label("根据此任务创建列表", systemImage: "plus.rectangle.on.folder")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.createList)

        Menu {
            ForEach(presentation.moveDestinations) { destination in
                Button {
                    moveTask(to: destination.listID)
                } label: {
                    Label(
                        destination.title,
                        systemImage: destination.isSelected ? "checkmark" : destination.systemImage
                    )
                }
                .accessibilityIdentifier(
                    TaskContextMenuAccessibility.moveDestination(destination.listID)
                )
            }
        } label: {
            Label("将任务移动到…", systemImage: "list.bullet.indent")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.moveMenu)

        Divider()

        Button(role: .destructive) {
            isConfirmingDelete = true
        } label: {
            Label("删除任务", systemImage: "trash")
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.delete)
    }

    private func taskDateMenu(
        field: TaskContextDateField,
        presentation: TaskContextMenuPresentation
    ) -> some View {
        Menu {
            Button {
                setDate(state.currentDay, for: field)
            } label: {
                Label("今天", systemImage: "calendar")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateToday(field))

            Button {
                if let tomorrow = state.currentDay.advanced(by: 1) {
                    setDate(tomorrow, for: field)
                }
            } label: {
                Label("明天", systemImage: "calendar.badge.plus")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateTomorrow(field))

            Button {
                datePickerRequest = TaskDatePickerRequest(
                    field: field,
                    initialDay: presentation.currentDate(for: field) ?? state.currentDay,
                    today: state.currentDay
                )
            } label: {
                Label("选择日期…", systemImage: "calendar")
            }
            .accessibilityIdentifier(TaskContextMenuAccessibility.dateChoose(field))

            if presentation.currentDate(for: field) != nil {
                Divider()
                Button {
                    setDate(nil, for: field)
                } label: {
                    Label(field.clearTitle, systemImage: "calendar.badge.minus")
                }
                .accessibilityIdentifier(TaskContextMenuAccessibility.dateClear(field))
            }
        } label: {
            Label(presentation.dateMenuTitle(for: field), systemImage: field.systemImage)
        }
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityIdentifier(TaskContextMenuAccessibility.dateMenu(field))
    }

    private func setDate(_ day: LocalDay?, for field: TaskContextDateField) {
        let value = day.map(TaskPatchField.set) ?? .clear
        state.enqueueImmediateTaskUpdate(
            taskID: task.id,
            patch: TaskPatch(dueDate: value)
        )
    }

    private func moveTask(to listID: UUID?) {
        state.enqueueImmediateTaskUpdate(
            taskID: task.id,
            patch: TaskPatch(listID: listID.map(TaskPatchField.set) ?? .clear)
        )
    }

    private func taskSaveFailure(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("修改尚未保存")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("重试") {
                Task { _ = await state.retryTaskEdits(taskID: task.id) }
            }
            .controlSize(.small)
            .accessibilityIdentifier("task.\(task.id.uuidString).retry-save")
        }
        .padding(.horizontal, TodoAgentUI.cardPadding)
        .padding(.vertical, 9)
        .background(.red.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task.\(task.id.uuidString).save-error")
    }

    private var completionButton: some View {
        Button {
            state.enqueueImmediateTaskUpdate(
                taskID: task.id,
                patch: TaskPatch(
                    status: task.status == .open ? .completed : .open
                )
            )
        } label: {
            Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(task.status == .completed ? Color.green : Color.secondary)
                .frame(
                    width: TaskCardNarrowLayoutPolicy.completionControlSize,
                    height: TaskCardNarrowLayoutPolicy.completionControlSize
                )
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .disabled(state.isTaskCommandInFlight(taskID: task.id))
        .accessibilityLabel(task.status == .completed ? "重新打开" : "标记完成")
        .help(task.status == .completed ? "重新打开任务" : "标记任务为已完成")
        .accessibilityIdentifier("task.\(task.id.uuidString).toggle-completion")
        .fixedSize(horizontal: true, vertical: true)
        .layoutPriority(2)
    }

    private var detailsButton: some View {
        Button { performActivation(from: .primaryClick) } label: {
            HStack(alignment: .center, spacing: TodoAgentUI.standardSpacing) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.body)
                        .bold()
                        .strikethrough(task.status == .completed)
                        .lineLimit(TaskCardNarrowLayoutPolicy.textLineLimit)
                        .truncationMode(TaskCardNarrowLayoutPolicy.swiftUITruncationMode)
                        .allowsTightening(TaskCardNarrowLayoutPolicy.allowsTextTightening)
                        .layoutPriority(2)

                    taskMetadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if reservesAgentIndicatorSpace {
                    agentIndicators
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("编辑任务 \(task.title)")
        .accessibilityHint("打开任务详情弹窗")
        .accessibilityIdentifier("task.\(task.id.uuidString).open-details")
    }

    private var detailsPopoverAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .popover(isPresented: detailsPresentationBinding) {
                TaskDetailsPopover(task: task, state: state)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var detailsPresentationBinding: Binding<Bool> {
        Binding(
            get: { isDetailsPresented },
            set: { isPresented in
                if isPresented {
                    if !isDetailsPresented { presentDetailsPopover() }
                } else {
                    dismissDetailsPopover()
                }
            }
        )
    }

    private func performActivation(from source: TaskCardActivationSource) {
        switch TaskCardInteractionPolicy.destination(for: source) {
        case .detailsPopover:
            presentDetailsPopover()
        case .terminalWorkspace:
            dismissDetailsPopover()
            guard let currentTask = state.task(id: task.id) else { return }
            state.openTask(currentTask)
        }
    }

    private func presentDetailsPopover() {
        detailsSelection = TaskDetailsPopoverSelection(
            taskID: task.id,
            originalStatus: task.status
        )
    }

    private func dismissDetailsPopover() {
        guard let selection = detailsSelection,
              selection.taskID == task.id
        else { return }
        detailsSelection = nil
    }

    @ViewBuilder
    private var taskMetadata: some View {
        let datePresentation = task.cardDatePresentation(on: state.currentDay)
        let hasVisibleMetadata = datePresentation != nil || !task.note.isEmpty
        if let datePresentation, datePresentation.isOverdue {
            taskDateLabel(datePresentation)
        } else if !task.note.isEmpty {
            taskMetadataLine(
                task.note,
                systemImage: "note.text",
                color: TodoAgentUI.secondaryText
            )
        } else if let datePresentation {
            taskDateLabel(datePresentation)
        } else if TaskCardMetadataLayoutPolicy.reservesLine(
            whileDetailsArePresented: isDetailsPresented,
            hasVisibleMetadata: hasVisibleMetadata
        ) {
            // A newly saved note would otherwise add this row while the
            // transient popover is open, moving its anchor and the IME
            // candidate window. Reserve the exact metadata height for the
            // lifetime of the presentation.
            taskMetadataLine(
                "占位",
                systemImage: "note.text",
                color: .clear
            )
            .hidden()
            .accessibilityHidden(true)
        }
    }

    private func taskDateLabel(_ presentation: TaskCardDatePresentation) -> some View {
        taskMetadataLine(
            dateText(presentation.day),
            systemImage: "calendar",
            color: presentation.isOverdue ? .red : TodoAgentUI.secondaryText
        )
            .accessibilityLabel(dateAccessibilityLabel(presentation))
            .accessibilityIdentifier(
                "task.\(task.id.uuidString).\(presentation.kind.rawValue)-date"
            )
    }

    private func taskMetadataLine(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityHidden(true)

            Text(text)
                .lineLimit(TaskCardNarrowLayoutPolicy.textLineLimit)
                .truncationMode(TaskCardNarrowLayoutPolicy.swiftUITruncationMode)
                .allowsTightening(TaskCardNarrowLayoutPolicy.allowsTextTightening)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(0)
    }

    private var agentIndicators: some View {
        HStack(spacing: 7) {
            if isWorkspacePending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在切换到此任务")
            }

            if let runtimeKind = agentStatus.runtimeKind {
                RuntimeIconView(
                    kind: runtimeKind,
                    fallbackSymbol: runtimeKind.fallbackSymbol,
                    glyphSize: 15
                )
                .accessibilityLabel(runtimeKind.title)
            }

            if agentStatus.isRunning {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 18, height: 18)
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .shadow(color: Color.green.opacity(0.9), radius: 5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agent 正在运行")
            }

            if agentStatus.hasUnread {
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .overlay {
                        Circle().stroke(TodoAgentUI.surfaceBackground, lineWidth: 1.5)
                    }
                    .accessibilityLabel("Agent 有新回复")
            }
        }
    }

    private func dateText(_ day: LocalDay) -> String {
        guard let date = day.date(in: .todoAgentLocal) else { return day.description }
        return date.formatted(.dateTime.month().day().weekday(.abbreviated))
    }

    private func dateAccessibilityLabel(_ presentation: TaskCardDatePresentation) -> String {
        let field = presentation.kind == .due ? "截止日期" : "执行日期"
        let overdue = presentation.isOverdue ? "，已过期" : ""
        return "\(field)\(dateText(presentation.day))\(overdue)"
    }

    private var borderColor: Color {
        if case .failed = state.taskSaveState(taskID: task.id) { return .red.opacity(0.58) }
        if isCardSelected { return TodoAgentUI.primaryText.opacity(0.55) }
        if agentStatus.isRunning { return .green.opacity(0.72) }
        return contextHighlight.isHighlighted ? TodoAgentUI.primaryText.opacity(0.2) : TodoAgentUI.hairline
    }

    private var cardShadowColor: Color {
        if agentStatus.isRunning { return .green.opacity(0.34) }
        return TodoAgentUI.shadowColor.opacity(contextHighlight.isHighlighted ? 0.9 : 0.55)
    }

    private var cardAccessibilityLabel: String {
        var parts = [task.title]
        if isWorkspaceSelected { parts.append("已在工作区打开") }
        if isDetailsPresented { parts.append("任务详情已打开") }
        if isWorkspacePending { parts.append("正在切换") }
        if let runtimeKind = agentStatus.runtimeKind { parts.append(runtimeKind.title) }
        if agentStatus.isRunning { parts.append("Agent 正在运行") }
        if agentStatus.hasUnread { parts.append("Agent 有新回复") }
        return parts.joined(separator: "，")
    }

    private var taskCardBackground: Color {
        if isCardSelected { return TodoAgentUI.selectionBackground }
        return contextHighlight.isHighlighted ? TodoAgentUI.selectionBackground : TodoAgentUI.surfaceBackground
    }
}

struct TaskCardAgentStatus: Equatable, Sendable {
    let isRunning: Bool
    let hasUnread: Bool
    let runtimeKind: RuntimeKind?

    var showsRuntime: Bool { runtimeKind != nil }

    init(isRunning: Bool, hasUnread: Bool, runtimeKind: RuntimeKind? = nil) {
        self.isRunning = isRunning
        self.hasUnread = hasUnread
        self.runtimeKind = runtimeKind
    }

    init(
        session: TaskSessionDescriptor?,
        displayRuntime: RuntimeKind? = nil,
        hasHostAttention: Bool = false
    ) {
        self.init(
            isRunning: session?.state.isBusy == true || session?.agentStatus.isRunning == true,
            hasUnread: session?.hasUnread == true || hasHostAttention,
            runtimeKind: Self.displayedRuntime(from: session, live: displayRuntime)
        )
    }

    /// Resolves the icon without ever guessing.
    ///
    /// A live controller's answer wins, including its `nil` — a host shell
    /// sitting at a prompt runs no Agent and must show no icon.
    ///
    /// With no live controller, an official run is the one case where the stored
    /// `runtimeKind` is real evidence: TodoAgent launched exactly that CLI for
    /// this task, so it stays meaningful after the run ends. For a task that
    /// only ever had a host shell, that field is just the default every new
    /// session gets (Claude) — falling back to it is what made every task look
    /// like a Claude task.
    private static func displayedRuntime(
        from session: TaskSessionDescriptor?,
        live: RuntimeKind?
    ) -> RuntimeKind? {
        if let live { return live }
        guard let session, session.hasOfficialAgentRun else { return nil }
        return session.runtimeKind
    }
}

struct TaskContextHighlightState: Equatable, Sendable {
    var pointerInside = false
    private(set) var trackingDepth = 0

    var isHighlighted: Bool { trackingDepth > 0 }

    mutating func menuDidBeginTracking() {
        guard pointerInside || isHighlighted else { return }
        trackingDepth += 1
    }

    mutating func menuDidEndTracking() {
        guard trackingDepth > 0 else { return }
        trackingDepth -= 1
    }
}

enum TaskContextDateField: String, Identifiable, Sendable {
    case due

    var id: String { rawValue }
    var menuTitle: String { "截止日期" }
    var clearTitle: String { "清除截止日期" }
    var systemImage: String { "calendar.badge.exclamationmark" }
}

struct TaskMoveDestination: Identifiable, Equatable, Sendable {
    let listID: UUID?
    let title: String
    let isSelected: Bool

    var id: String { listID?.uuidString ?? "no-list" }
    var systemImage: String { listID == nil ? "tray" : "list.bullet" }
}

struct TaskContextMenuPresentation: Equatable, Sendable {
    let task: TaskItem
    let lists: [TodoList]

    var completionTitle: String { task.status == .completed ? "重新打开" : "标记为完成" }
    var completionSystemImage: String {
        task.status == .completed ? "arrow.uturn.backward.circle" : "checkmark.circle"
    }

    var moveDestinations: [TaskMoveDestination] {
        [
            TaskMoveDestination(
                listID: nil,
                title: "任务（无清单）",
                isSelected: task.listID == nil
            ),
        ] + lists.map { list in
            TaskMoveDestination(
                listID: list.id,
                title: list.name,
                isSelected: task.listID == list.id
            )
        }
    }

    func currentDate(for field: TaskContextDateField) -> LocalDay? {
        task.dueDate
    }

    func dateMenuTitle(for field: TaskContextDateField) -> String {
        guard let day = currentDate(for: field) else { return field.menuTitle }
        return "\(field.menuTitle) · \(day.month)月\(day.day)日"
    }
}

enum TaskContextMenuAccessibility {
    static let terminal = "task.context.open-terminal"
    static let completion = "task.context.completion"
    static let myDay = "task.context.my-day"
    static let createList = "task.context.create-list"
    static let moveMenu = "task.context.move-menu"
    static let delete = "task.context.delete"
    static let deleteConfirmation = "task.context.delete-confirmation"

    static func dateMenu(_ field: TaskContextDateField) -> String {
        "task.context.\(field.rawValue)-date"
    }

    static func dateToday(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).today"
    }

    static func dateTomorrow(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).tomorrow"
    }

    static func dateChoose(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).choose"
    }

    static func dateClear(_ field: TaskContextDateField) -> String {
        "\(dateMenu(field)).clear"
    }

    static func moveDestination(_ listID: UUID?) -> String {
        "task.context.move.\(listID?.uuidString ?? "no-list")"
    }
}

struct TaskDatePickerRequest: Identifiable {
    let field: TaskContextDateField
    let initialDay: LocalDay
    let today: LocalDay

    var id: String { field.id }
}

private struct TaskDatePickerPopover: View {
    let request: TaskDatePickerRequest
    let onApply: (LocalDay) -> Void

    @Environment(\.dismiss) private var dismiss
    init(request: TaskDatePickerRequest, onApply: @escaping (LocalDay) -> Void) {
        self.request = request
        self.onApply = onApply
    }

    var body: some View {
        TodoAgentDatePickerPanel(
            title: "选择\(request.field.menuTitle)",
            initialDay: request.initialDay,
            today: request.today,
            onCancel: { dismiss() },
            onApply: { day in
                onApply(day)
                dismiss()
            }
        )
        .accessibilityIdentifier("task.context.\(request.field.rawValue)-date.picker")
    }
}
