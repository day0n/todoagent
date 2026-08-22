import AppKit
import Foundation
import Testing
@testable import TodoAgentApp

@Suite("Native task and session state")
@MainActor
struct AppStateTests {
    @Test("Gemini secret uses the IPC v4 field spelling")
    func geminiSecretWireName() throws {
        let data = try JSONEncoder().encode(SecretRequest(geminiAPIKey: "test-secret"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object["geminiApiKey"] == "test-secret")
        #expect(object["geminiAPIKey"] == nil)
    }

    @Test("turn timeline request uses the paged Engine contract")
    func timelineTurnRequestWireNames() throws {
        let cursor = SessionTimelineCursor(turnOrdinal: 4, itemOrdinal: 9)
        let data = try JSONEncoder().encode(
            TimelineTurnRequest(
                sessionID: "session-1",
                turnID: "turn-4",
                afterCursor: cursor,
                limit: 500
            )
        )
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["sessionId"] as? String == "session-1")
        #expect(object["turnId"] as? String == "turn-4")
        #expect(object["limit"] as? Int == 500)
        let encodedCursor = try #require(object["afterCursor"] as? [String: Any])
        #expect(encodedCursor["turnOrdinal"] as? Int == 4)
        #expect(encodedCursor["itemOrdinal"] as? Int == 9)
    }

    @Test("TodoAgent starts with its inspector collapsed")
    func assistantStartsCollapsed() {
        let state = AppState(repository: AssistantTestRepository())

        #expect(state.inspectorPresented == false)
    }

    @Test("TodoAgent docks on the task page and overlays a task terminal")
    func assistantPlacementFollowsWorkspaceMode() {
        #expect(AssistantPanePlacementPolicy.resolve(
            inspectorPresented: false,
            taskWorkspacePresented: false
        ) == .hidden)
        #expect(AssistantPanePlacementPolicy.resolve(
            inspectorPresented: true,
            taskWorkspacePresented: false
        ) == .sideBySide)
        #expect(AssistantPanePlacementPolicy.resolve(
            inspectorPresented: true,
            taskWorkspacePresented: true
        ) == .taskOverlay)
    }

    @Test("main workspace keeps one concrete native Sidebar state")
    func mainWorkspaceNavigationVisibilityIsCanonical() {
        #expect(MainWorkspaceNavigationPolicy.visibleColumns == .doubleColumn)
        #expect(MainWorkspaceNavigationPolicy.canonicalVisibility(.all) == .doubleColumn)
        #expect(MainWorkspaceNavigationPolicy.canonicalVisibility(.doubleColumn) == .doubleColumn)
        #expect(MainWorkspaceNavigationPolicy.canonicalVisibility(.detailOnly) == .detailOnly)
        #expect(
            MainWorkspaceChromeCollapsePolicy.shouldRevealNavigationSidebar(
                wasPresented: true,
                isPresented: false,
                isPreparing: false
            )
        )
        #expect(
            MainWorkspaceChromeCollapsePolicy.shouldRevealNavigationSidebar(
                wasPresented: true,
                isPresented: false,
                isPreparing: true
            ) == false
        )
        #expect(
            MainWorkspaceChromeCollapsePolicy.shouldRevealNavigationSidebar(
                wasPresented: true,
                isPresented: true,
                isPreparing: false
            ) == false
        )
        #expect(
            MainWorkspaceChromeCollapsePolicy.shouldRevealNavigationSidebar(
                wasPresented: false,
                isPresented: false,
                isPreparing: false
            ) == false
        )
    }

    @Test("workspace chrome lock does not disable the Ghostty surface")
    func workspaceChromeLockDoesNotDisableContent() {
        #expect(
            MainWorkspaceInteractionPolicy.disablesContent(
                loadState: .loaded,
                isPreparingToTerminate: false
            ) == false
        )
        #expect(
            MainWorkspaceInteractionPolicy.disablesContent(
                loadState: .loading,
                isPreparingToTerminate: false
            )
        )
        #expect(
            MainWorkspaceInteractionPolicy.disablesContent(
                loadState: .loaded,
                isPreparingToTerminate: true
            )
        )
    }

    @Test("native Sidebar writes cannot interrupt terminal geometry preparation")
    func nativeSidebarWriteIsLockedDuringTerminalPreparation() {
        let state = AppState(repository: AssistantTestRepository())
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        let preparation = chrome.acquireTaskWorkspacePreparation()

        chrome.acceptSystemNavigationVisibility(.detailOnly)
        #expect(chrome.navigationColumnVisibility == .doubleColumn)

        chrome.finishTaskWorkspacePreparation(preparation, didPresent: false)
        chrome.acceptSystemNavigationVisibility(.all)
        #expect(chrome.navigationColumnVisibility == .doubleColumn)

        chrome.acceptSystemNavigationVisibility(.detailOnly)
        #expect(chrome.navigationColumnVisibility == .detailOnly)
    }

    @Test("cold task terminal waits for external chrome and live Board geometry")
    func taskWorkspacePreparationCollapsesSidebarAndAssistant() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository, inspectorPresented: true)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)

        #expect(workspace.presentedTaskID == nil)
        #expect(workspace.pendingTaskID == task.id)

        // Merely changing the requested chrome state is not enough. The
        // terminal remains unmounted until the live Board reports the final
        // full-detail width.
        await drainMainActorTasks()
        #expect(chrome.isPreparingTaskWorkspace)
        #expect(workspace.presentedTaskID == nil)

        // This is the cold menu-bar order: the request exists before the main
        // window mounts, then root and Board geometry arrive from ContentView.
        chrome.updateRootWidth(900)
        chrome.updateBoardWidth(900)

        await drainMainActorTasks()

        #expect(chrome.navigationColumnVisibility == .detailOnly)
        #expect(state.inspectorPresented == false)
        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == task.id)
        #expect(chrome.isPreparingTaskWorkspace == false)
    }

    @Test("collapsing a presented workspace reveals the navigation sidebar")
    func collapsingPresentedWorkspaceRevealsNavigationSidebar() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()
        chrome.updateRootWidth(900)
        chrome.updateBoardWidth(900)
        await drainMainActorTasks()

        #expect(workspace.presentedTaskID == task.id)
        #expect(chrome.navigationColumnVisibility == .detailOnly)

        workspace.closeTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()
        #expect(workspace.isPresented == false)

        chrome.handleTaskWorkspacePresentationChange(
            wasPresented: true,
            isPresented: workspace.isPresented
        )
        #expect(chrome.navigationColumnVisibility == .doubleColumn)
    }

    @Test("sidebar reveal is ignored while a terminal is being prepared")
    func revealNavigationSidebarIsLockedDuringPreparation() {
        let state = AppState(repository: AssistantTestRepository())
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.navigationColumnVisibility = .detailOnly
        _ = chrome.acquireTaskWorkspacePreparation()

        chrome.revealNavigationSidebar()
        #expect(chrome.navigationColumnVisibility == .detailOnly)
    }

    @Test("cancelled task preflight restores chrome and never mounts a terminal")
    func cancellingTaskWorkspacePreparationRestoresExternalChrome() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository, inspectorPresented: true)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.updateRootWidth(900)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()
        #expect(chrome.navigationColumnVisibility == .detailOnly)
        #expect(state.inspectorPresented == false)
        #expect(workspace.pendingTaskID == task.id)

        workspace.destroyTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == nil)
        #expect(chrome.isPreparingTaskWorkspace == false)
        #expect(chrome.navigationColumnVisibility == .doubleColumn)
        #expect(state.inspectorPresented)
    }

    @Test("superseded task preflights preserve the first external chrome snapshot")
    func supersededTaskWorkspacePreparationRestoresOriginalChrome() async {
        let first = taskFixture()
        let second = TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000410")!,
            listID: nil,
            title: "第二个等待中的终端",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-16T00:00:00Z"
        )
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [first, second],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository, inspectorPresented: true)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.updateRootWidth(900)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: first.id)
        await drainMainActorTasks()
        workspace.showTaskWorkspace(taskID: second.id)
        await drainMainActorTasks()
        #expect(workspace.pendingTaskID == second.id)

        workspace.destroyTaskWorkspace(taskID: second.id)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == nil)
        #expect(chrome.isPreparingTaskWorkspace == false)
        #expect(chrome.navigationColumnVisibility == .doubleColumn)
        #expect(state.inspectorPresented)
    }

    @Test("missing Board geometry times out without locking the main window")
    func taskWorkspacePreparationTimeoutRestoresExternalChrome() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository, inspectorPresented: true)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state, preparationTimeout: 0.01)
        chrome.updateRootWidth(900)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)
        try? await Task.sleep(for: .milliseconds(30))
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == nil)
        #expect(chrome.isPreparingTaskWorkspace == false)
        #expect(chrome.navigationColumnVisibility == .doubleColumn)
        #expect(state.inspectorPresented)
        #expect(state.errorMessage == "无法准备终端布局，请重试。")
    }

    @Test("native one-point detail inset does not block terminal preparation")
    func taskWorkspacePreparationAcceptsNativeGeometryRounding() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.updateRootWidth(900)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()
        chrome.updateBoardWidth(899)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == task.id)
        #expect(chrome.isPreparingTaskWorkspace == false)
        #expect(TaskWorkspaceExternalChromePreparationPolicy.geometryTolerance == 2)
    }

    @Test("cached geometry cannot mount a terminal before a fresh Board ack")
    func taskWorkspacePreparationRequiresFreshBoardGeometry() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.navigationColumnVisibility = .detailOnly
        chrome.updateRootWidth(900)
        chrome.updateBoardWidth(900)
        workspace.presentationPreparer = chrome
        await state.load()

        workspace.showTaskWorkspace(taskID: task.id)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == task.id)
        #expect(workspace.presentedTaskID == nil)

        chrome.updateBoardWidth(900)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == task.id)
    }

    @Test("reopening the main window reacquires geometry before reattaching a terminal")
    func reopenedMainWindowPreparesDormantWorkspace() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        await state.load()
        workspace.showTaskWorkspace(taskID: task.id)
        #expect(workspace.presentedTaskID == task.id)

        workspace.mainWindowWillClose()
        #expect(workspace.presentedTaskID == nil)
        #expect(workspace.selectedTaskID == task.id)
        #expect(workspace.dormantTaskID == task.id)

        let chrome = MainWorkspaceChromeCoordinator(state: state)
        chrome.navigationColumnVisibility = .detailOnly
        chrome.updateRootWidth(1_100)
        chrome.updateBoardWidth(0)
        workspace.presentationPreparer = chrome
        workspace.mainWindowDidMount()
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == task.id)
        #expect(workspace.presentedTaskID == nil)

        // Close once more before the fresh geometry ack. A third window must
        // still remember and resume the retained workspace.
        workspace.mainWindowWillClose()
        await drainMainActorTasks()
        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.dormantTaskID == task.id)

        workspace.mainWindowDidMount()
        await drainMainActorTasks()
        #expect(workspace.pendingTaskID == task.id)
        #expect(workspace.presentedTaskID == nil)

        chrome.updateBoardWidth(1_100)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == task.id)
        #expect(workspace.dormantTaskID == nil)
    }

    @Test("closing the main window cannot remount a task already collapsing")
    func mainWindowCloseDoesNotRemountCollapsingWorkspace() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        await state.load()
        workspace.showTaskWorkspace(taskID: task.id)

        workspace.closeTaskWorkspace(taskID: task.id)
        #expect(workspace.closingTaskID == task.id)
        workspace.mainWindowWillClose()

        #expect(workspace.presentedTaskID == nil)
        #expect(workspace.dormantTaskID == nil)
        workspace.mainWindowDidMount()
        #expect(workspace.presentedTaskID == nil)

        await drainMainActorTasks()
        #expect(workspace.presentedTaskID == nil)
    }

    @Test("scope-driven workspace close retries only after a failed save becomes idle")
    func scopeCloseRetryPolicy() {
        let taskID = UUID()
        let visibleTaskIDs: Set<UUID> = []

        #expect(TaskWorkspaceScopeClosePolicy.didLeaveScope(
            taskID: taskID,
            previousVisibleTaskIDs: [taskID],
            visibleTaskIDs: visibleTaskIDs
        ))
        #expect(TaskWorkspaceScopeClosePolicy.didLeaveScope(
            taskID: taskID,
            previousVisibleTaskIDs: visibleTaskIDs,
            visibleTaskIDs: [UUID()]
        ) == false)

        #expect(TaskWorkspaceScopeClosePolicy.shouldRetryAutomaticClose(
            pendingTaskID: taskID,
            presentedTaskID: taskID,
            visibleTaskIDs: visibleTaskIDs,
            saveState: .idle
        ))
        #expect(TaskWorkspaceScopeClosePolicy.shouldRetryAutomaticClose(
            pendingTaskID: taskID,
            presentedTaskID: taskID,
            visibleTaskIDs: visibleTaskIDs,
            saveState: .saving
        ) == false)
        #expect(TaskWorkspaceScopeClosePolicy.shouldRetryAutomaticClose(
            pendingTaskID: taskID,
            presentedTaskID: taskID,
            visibleTaskIDs: [taskID],
            saveState: .idle
        ) == false)
        #expect(TaskWorkspaceScopeClosePolicy.shouldRetryAutomaticClose(
            pendingTaskID: taskID,
            presentedTaskID: UUID(),
            visibleTaskIDs: visibleTaskIDs,
            saveState: .idle
        ) == false)
    }

    @Test("TodoAgent keeps a fixed board width when space allows")
    func assistantWorkspaceUsesFixedBoardWidth() {
        #expect(MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 640,
            assistantRequested: false
        ) == .boardOnly)

        guard case let .sideBySide(assistantWidth) = MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 640,
            assistantRequested: true
        ) else {
            Issue.record("窄窗口也应保留任务区并将 TodoAgent 停靠在右侧")
            return
        }
        #expect(assistantWidth == 260)
        #expect(640 - assistantWidth - MainWorkspaceLayoutPolicy.dividerWidth == 370)

        guard case let .sideBySide(proportionalWidth) = MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 960,
            assistantRequested: true
        ) else {
            Issue.record("常规宽度应继续保持右侧双栏")
            return
        }
        #expect(proportionalWidth == 390)
        #expect(
            960 - proportionalWidth - MainWorkspaceLayoutPolicy.dividerWidth
                == MainWorkspaceLayoutPolicy.defaultBoardWidth
        )
        #expect(MainWorkspaceLayoutPolicy.defaultBoardWidth == 560)
        #expect(MainWorkspaceLayoutPolicy.boardMinimumVisibleWidth == 360)

        #expect(MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 1_340,
            assistantRequested: true
        ) == .sideBySide(assistantWidth: 770))

        #expect(MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 500,
            assistantRequested: true
        ) == .sideBySide(assistantWidth: 130))
    }

    @Test("assistant Board and drawer share one continuous layout boundary")
    func assistantWorkspaceLayoutStaysSynchronized() {
        #expect(AssistantWorkspaceLayoutTarget.resolve(
            placement: .hidden,
            drawerWidth: 140
        ) == AssistantWorkspaceLayoutTarget(reservedWidth: 0, visibleDrawerWidth: 0))
        #expect(AssistantWorkspaceLayoutTarget.resolve(
            placement: .sideBySide,
            drawerWidth: 140
        ) == AssistantWorkspaceLayoutTarget(reservedWidth: 140, visibleDrawerWidth: 140))
        #expect(AssistantWorkspaceLayoutTarget.resolve(
            placement: .taskOverlay,
            drawerWidth: 140
        ) == AssistantWorkspaceLayoutTarget(reservedWidth: 0, visibleDrawerWidth: 140))

        let bounds = CGRect(x: 10, y: 20, width: 500, height: 400)
        let sideBySideMidpoint = AssistantWorkspaceSynchronizedLayoutPolicy.resolve(
            in: bounds,
            reservedWidth: 70,
            visibleDrawerWidth: 70,
            drawerWidth: 140
        )
        #expect(sideBySideMidpoint.boardFrame.maxX == sideBySideMidpoint.drawerFrame.minX)

        let overlayMidpoint = AssistantWorkspaceSynchronizedLayoutPolicy.resolve(
            in: bounds,
            reservedWidth: 0,
            visibleDrawerWidth: 70,
            drawerWidth: 140
        )
        #expect(overlayMidpoint.boardFrame == bounds)
        #expect(overlayMidpoint.drawerFrame.minX == 440)

        let hidden = AssistantWorkspaceSynchronizedLayoutPolicy.resolve(
            in: bounds,
            reservedWidth: 0,
            visibleDrawerWidth: 0,
            drawerWidth: 140
        )
        #expect(hidden.boardFrame == bounds)
        #expect(hidden.drawerFrame.minX == bounds.maxX)
    }

    @Test("assistant divider resizes while preserving the minimum board width")
    func assistantDividerClampsResize() {
        #expect(MainWorkspaceLayoutPolicy.resizedAssistantWidth(
            availableWidth: 960,
            startingWidth: 378,
            dividerTranslation: 50
        ) == 328)
        #expect(MainWorkspaceLayoutPolicy.resizedAssistantWidth(
            availableWidth: 960,
            startingWidth: 378,
            dividerTranslation: -80
        ) == 458)
        #expect(MainWorkspaceLayoutPolicy.resizedAssistantWidth(
            availableWidth: 960,
            startingWidth: 378,
            dividerTranslation: -2_000
        ) == 590)
        #expect(MainWorkspaceLayoutPolicy.resolve(
            availableWidth: 960,
            assistantRequested: true,
            preferredAssistantWidth: 430
        ) == .sideBySide(assistantWidth: 430))
    }

    @Test("main window uses compact native toolbar chrome")
    @MainActor
    func mainWindowToolbarIsCompact() {
        let window = NSWindow()

        TodoAgentMainWindowChrome.configure(window)

        #expect(window.toolbarStyle == .unifiedCompact)
    }

    @Test("assistant rail uses a visible native-paced transition")
    func assistantWorkspaceMotionIsPerceptible() {
        #expect(AssistantWorkspaceMotion.duration >= 0.30)
        #expect(AssistantWorkspaceMotion.duration <= 0.40)
        #expect(AssistantWorkspaceMotion.animation(reduceMotion: true) == nil)
        #expect(AssistantWorkspaceMotion.animation(reduceMotion: false) != nil)
        #expect(MainWorkspaceLayoutPolicy.assistantWidth(availableWidth: 960) == 390)
        #expect(TodoAgentUI.floatingButtonTrailingPadding == 22)
        #expect(TodoAgentUI.floatingButtonBottomPadding == 48)
    }

    @Test("assistant floating button placement survives dragging and resizing")
    func assistantFloatingButtonPlacement() {
        let largeContainer = CGSize(width: 1_000, height: 800)
        let defaultCenter = AssistantFloatingButtonPlacementPolicy.center(
            for: AssistantFloatingButtonPlacementPolicy.defaultNormalizedPosition,
            in: largeContainer
        )
        #expect(defaultCenter == CGPoint(x: 955, y: 729))
        #expect(AssistantFloatingButtonPlacementPolicy.dragMinimumDistance == 4)
        #expect(AssistantFloatingButtonPreferences.normalizedXKey.hasSuffix(".v1"))
        #expect(AssistantFloatingButtonPreferences.normalizedYKey.hasSuffix(".v1"))

        let normalized = CGPoint(x: 0.25, y: 0.6)
        let center = AssistantFloatingButtonPlacementPolicy.center(
            for: normalized,
            in: largeContainer
        )
        let roundTrip = AssistantFloatingButtonPlacementPolicy.normalizedPosition(
            for: center,
            in: largeContainer
        )
        #expect(abs(roundTrip.x - normalized.x) < 0.000_001)
        #expect(abs(roundTrip.y - normalized.y) < 0.000_001)

        #expect(AssistantFloatingButtonPlacementPolicy.clampedCenter(
            CGPoint(x: -500, y: 5_000),
            in: largeContainer
        ) == CGPoint(x: 45, y: 729))
        #expect(AssistantFloatingButtonPlacementPolicy.clampedCenter(
            CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
            in: largeContainer
        ) == defaultCenter)
        #expect(AssistantFloatingButtonPlacementPolicy.center(
            for: CGPoint(x: CGFloat.nan, y: -CGFloat.infinity),
            in: largeContainer
        ) == defaultCenter)

        let tinyContainer = CGSize(width: 30, height: 20)
        #expect(AssistantFloatingButtonPlacementPolicy.clampedCenter(
            CGPoint(x: 500, y: -500),
            in: tinyContainer
        ) == CGPoint(x: 15, y: 10))

        let start = CGPoint(x: 400, y: 300)
        let translated = AssistantFloatingButtonPlacementPolicy.dragCenter(
            startingAt: start,
            translation: CGSize(width: 80, height: -40),
            in: largeContainer
        )
        #expect(translated == CGPoint(x: 480, y: 260))
        #expect(AssistantFloatingButtonPlacementPolicy.dragCenter(
            startingAt: start,
            translation: CGSize(width: 80, height: -40),
            in: largeContainer
        ) == translated)

        let resizedCenter = AssistantFloatingButtonPlacementPolicy.center(
            for: normalized,
            in: CGSize(width: 620, height: 460)
        )
        let resizedRoundTrip = AssistantFloatingButtonPlacementPolicy.normalizedPosition(
            for: resizedCenter,
            in: CGSize(width: 620, height: 460)
        )
        #expect(abs(resizedRoundTrip.x - normalized.x) < 0.000_001)
        #expect(abs(resizedRoundTrip.y - normalized.y) < 0.000_001)
    }

    @Test("right-click menu keeps its task highlighted through nested submenus")
    func taskContextMenuHighlightTracksMenuLifetime() {
        var highlight = TaskContextHighlightState(pointerInside: true)

        highlight.menuDidBeginTracking()
        #expect(highlight.isHighlighted)
        #expect(highlight.trackingDepth == 1)

        highlight.pointerInside = false
        highlight.menuDidBeginTracking()
        highlight.menuDidEndTracking()
        #expect(highlight.isHighlighted)
        #expect(highlight.trackingDepth == 1)

        highlight.menuDidEndTracking()
        #expect(highlight.isHighlighted == false)
        #expect(highlight.trackingDepth == 0)
    }

    @Test("first window placement stays medium sized on large and small displays")
    func firstWindowPlacementCapsItsContentSize() {
        #expect(
            TodoAgentMainWindowPlacement.preferredWorkspaceWidth == 854
        )
        #expect(
            TodoAgentMainWindowPlacement.preferredContentSize.width
                - TodoAgentUI.sidebarIdealWidth
                == TodoAgentMainWindowPlacement.preferredWorkspaceWidth
        )
        #expect(TodoAgentMainWindowPlacement.contentSize(
            for: CGRect(x: 0, y: 0, width: 2_048, height: 1_260)
        ) == CGSize(width: 1_114, height: 820))

        #expect(TodoAgentMainWindowPlacement.contentSize(
            for: CGRect(x: 0, y: 0, width: 900, height: 650)
        ) == CGSize(width: 900, height: 560))

        #expect(TodoAgentMainWindowPlacement.windowOrigin(
            for: CGSize(width: 1_114, height: 848),
            in: CGRect(x: 0, y: 40, width: 2_048, height: 1_220)
        ) == CGPoint(x: 467, y: 412))
    }

    @Test("default window reserves the fixed board width beside TodoAgent")
    func defaultWindowAndAssistantShareWorkspaceWidth() {
        let detailWidth = TodoAgentMainWindowPlacement.preferredWorkspaceWidth
        let assistantWidth = MainWorkspaceLayoutPolicy.assistantWidth(
            availableWidth: detailWidth
        )
        #expect(assistantWidth == 284)
        #expect(
            detailWidth - assistantWidth - MainWorkspaceLayoutPolicy.dividerWidth
                == MainWorkspaceLayoutPolicy.defaultBoardWidth
        )
    }

    @Test("opening TodoAgent creates and selects one default conversation")
    func openingAssistantCreatesDefaultSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.openAssistant())

        #expect(state.inspectorPresented)
        let sessions = try await repository.assistantSessions(includeArchived: false)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(state.assistant.selectedSessionID == session.id)

        #expect(await state.openAssistant())
        #expect(try await repository.assistantSessions(includeArchived: false).count == 1)
    }

    @Test("showing TodoAgent at launch also provisions one default conversation")
    func visibleAssistantAtLaunchCreatesDefaultSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository, inspectorPresented: true)

        await state.load()

        let sessions = try await repository.assistantSessions(includeArchived: false)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(state.assistant.selectedSessionID == session.id)
    }

    @Test("an unconfigured TodoAgent opens recovery without creating a conversation")
    func unconfiguredAssistantDoesNotCreateSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)
        #expect(state.assistant.canUseAssistant == false)

        #expect(await state.openNewAssistantConversation() == false)

        #expect(state.inspectorPresented)
        #expect(try await repository.assistantSessions(includeArchived: false).isEmpty)
        #expect(state.assistant.selectedSessionID == nil)
    }

    @Test("a ready TodoAgent creates and selects exactly one conversation")
    func readyAssistantCreatesOneSelectedSession() async throws {
        let repository = AssistantTestRepository()
        let state = AppState(repository: repository)
        await state.load()
        #expect(state.assistant.canUseAssistant)

        #expect(await state.openNewAssistantConversation())

        let sessions = try await repository.assistantSessions(includeArchived: false)
        let session = try #require(sessions.first)
        #expect(state.inspectorPresented)
        #expect(sessions.count == 1)
        #expect(state.assistant.selectedSessionID == session.id)
    }

    @Test("the total tasks composer creates without forcing a list")
    func totalTasksCreationHasNoListContext() async {
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        await state.load()
        state.selection = .smart(.tasks)

        #expect(await state.createTask(title: "收件箱任务"))

        #expect(await repository.taskCreateCalls().first?.listID == nil)
    }

    @Test("Today and All Tasks keep independent composer drafts")
    func myDayAndAllTasksComposerDraftsAreIsolated() {
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        let myDayComposer = workspace.composerState(for: .myDay)
        let allTasksComposer = workspace.composerState(for: .allTasks)

        myDayComposer.draft = "今天处理"
        allTasksComposer.draft = "稍后规划"

        #expect(myDayComposer !== allTasksComposer)
        #expect(workspace.composerState(for: .myDay) === myDayComposer)
        #expect(workspace.composerState(for: .allTasks) === allTasksComposer)
        #expect(myDayComposer.draft == "今天处理")
        #expect(allTasksComposer.draft == "稍后规划")
    }

    @Test("only the Today composer assigns today's execution date")
    func inlineAddTaskDestinationDateSemantics() throws {
        let today = try #require(LocalDay(rawValue: "2026-08-16"))
        let listID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000506"))
        let myDay = InlineAddTaskDestination.myDay
        let allTasks = InlineAddTaskDestination.allTasks
        let list = InlineAddTaskDestination.list(listID)

        #expect(myDay.listID == nil)
        #expect(myDay.executionDate(today: today) == today)
        #expect(allTasks.listID == nil)
        #expect(allTasks.executionDate(today: today) == nil)
        #expect(list.listID == listID)
        #expect(list.executionDate(today: today) == nil)
    }

    @Test("creating a list persists it and selects the new destination")
    func creatingListSelectsIt() async throws {
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        await state.load()

        #expect(await state.createList(name: "  工作  "))

        let list = try #require(state.lists.first)
        #expect(list.name == "工作")
        #expect(state.selection == .list(list.id))
        #expect(await repository.listCreateNames() == ["工作"])
    }

    @Test("an empty list name is rejected before reaching the Engine")
    func emptyListNameIsRejected() async {
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)

        #expect(await state.createList(name: "  \n ") == false)
        #expect(await repository.listCreateNames().isEmpty)
    }

    @Test("renaming and deleting a list preserves its canonical tasks")
    func listMutationsPreserveTasks() async throws {
        let listID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000504"))
        let taskID = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000505"))
        let executionDay = try #require(LocalDay(rawValue: "2026-08-10"))
        let list = TodoList(id: listID, name: "原清单", colorName: "blue", repositoryPath: nil)
        let task = TaskItem(
            id: taskID,
            listID: listID,
            title: "保留任务",
            note: "保留备注",
            status: .open,
            executionDate: executionDay,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-10T00:00:00Z"
        )
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [list],
                tasks: [task],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        await state.load()
        state.selection = .list(listID)

        #expect(await state.renameList(listID: listID, name: "  新清单  "))
        #expect(state.lists.first?.name == "新清单")

        #expect(await state.deleteList(listID: listID))
        #expect(state.lists.isEmpty)
        #expect(state.selection == .smart(.tasks))
        let preserved = try #require(state.tasks.first(where: { $0.id == taskID }))
        #expect(preserved.listID == nil)
        #expect(preserved.executionDate == executionDay)
        #expect(preserved.note == "保留备注")
    }

    @Test("an empty user list creates with that list context")
    func emptyUserListCreationKeepsListContext() async {
        let listID = UUID(uuidString: "00000000-0000-4000-8000-000000000501")!
        let list = TodoList(id: listID, name: "空清单", colorName: "blue", repositoryPath: nil)
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot(lists: [list]))
        let state = AppState(repository: repository)
        await state.load()
        state.selection = .list(listID)

        #expect(await state.createTask(title: "清单任务"))

        #expect(await repository.taskCreateCalls().first?.listID == listID)
    }

    @Test("explicit inline list context survives navigation changes")
    func taskCreationUsesCapturedListContext() async throws {
        let capturedListID = UUID(uuidString: "00000000-0000-4000-8000-000000000503")!
        let repository = TaskOpenSpyRepository(snapshot: emptySnapshot())
        let state = AppState(repository: repository)
        state.selection = .smart(.tasks)
        #expect(await state.createTask(title: "保留原清单", listID: capturedListID))

        let calls = await repository.taskCreateCalls()
        let call = try #require(calls.first)
        #expect(calls.count == 1)
        #expect(call.title == "保留原清单")
        #expect(call.listID == capturedListID)
    }

    @Test("opening setup for a task without a Session only presents its sheet")
    func openingTaskSetupDoesNotQueryEngine() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(task: task, session: nil)
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        await Task.yield()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(await repository.sessionLookupCount() == 0)
        #expect(state.errorMessage == nil)
    }

    @Test("opening a task with a Session refreshes it exactly once")
    func openingExistingTaskSessionQueriesEngineOnce() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task)
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        await repository.waitUntilSessionLookup()
        await Task.yield()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(await repository.sessionLookupCount() == 1)
        #expect(state.errorMessage == nil)
    }

    @Test("closing a loading task Session discards a delayed successful lookup")
    func closingSessionDiscardsDelayedSuccess() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        #expect(state.conversation(for: task) == nil)
        await repository.waitUntilSessionLookup()

        state.dismissTaskSession(taskID: task.id)
        #expect(state.presentedSheet == nil)
        #expect(state.isLoadingSession(for: task) == false)
        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.errorMessage == nil)
        #expect(state.conversation(for: task) == nil)
    }

    @Test("closing a loading task Session suppresses a delayed lookup failure")
    func closingSessionSuppressesDelayedFailure() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true,
            lookupFailure: .runtimeUnavailable
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        await repository.waitUntilSessionLookup()

        state.dismissTaskSession(taskID: task.id)
        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.presentedSheet == nil)
        #expect(state.isLoadingSession(for: task) == false)
        #expect(state.errorMessage == nil)
        #expect(state.conversation(for: task) == nil)
    }

    @Test("a successful task Session lookup clears loading and publishes its conversation")
    func completedSessionLookupPublishesConversation() async {
        let task = taskFixture()
        let repository = TaskOpenSpyRepository(
            task: task,
            session: sessionBundleFixture(for: task),
            delaysSessionLookup: true
        )
        let state = AppState(repository: repository)
        await state.load()

        state.openTask(task)
        #expect(state.isLoadingSession(for: task))
        #expect(state.conversation(for: task) == nil)
        await repository.waitUntilSessionLookup()

        await repository.completeDelayedSessionLookup()
        await drainMainActorTasks()

        #expect(state.presentedSheet == .taskSession(task.id))
        #expect(state.isLoadingSession(for: task) == false)
        #expect(state.conversation(for: task)?.sessionID == "task-session")
        #expect(state.errorMessage == nil)
    }

    @Test("legacy turn finish reconciliation is nonblocking coalesced and turn scoped")
    func legacyTurnFinishReconciliationIsIncremental() async throws {
        let task = taskFixture()
        let activeTurn = SessionTurn(
            id: "turn-5",
            sessionID: "task-session",
            ordinal: 5,
            userMessageID: "user-5",
            providerSessionIDBefore: nil,
            providerSessionIDAfter: nil,
            status: .running,
            exitCode: nil,
            finalOutput: nil,
            errorCode: nil,
            errorMessage: nil,
            providerUsageJSON: nil,
            startedAt: "2026-08-11T00:00:00Z",
            endedAt: nil,
            createdAt: "2026-08-11T00:00:00Z"
        )
        let runningBundle = sessionBundleFixture(
            for: task,
            state: .running,
            activeTurn: activeTurn
        )
        let runningTool = timelineTool(
            state: "running",
            sequence: 17,
            turnOrdinal: 5,
            itemOrdinal: 1
        )
        let initialPage = SessionTimelinePage(
            session: runningBundle.session,
            items: [runningTool],
            activeTurn: activeTurn,
            nextSequence: 17,
            nextCursor: SessionTimelineCursor(turnOrdinal: 5, itemOrdinal: 1),
            fidelity: "exact"
        )
        let completedBundle = sessionBundleFixture(for: task)
        let completedPage = SessionTimelinePage(
            session: completedBundle.session,
            items: [
                timelineTool(
                    state: "completed",
                    sequence: 18,
                    turnOrdinal: 5,
                    itemOrdinal: 1
                ),
            ],
            activeTurn: nil,
            nextSequence: 18,
            nextCursor: SessionTimelineCursor(turnOrdinal: 5, itemOrdinal: 1),
            fidelity: "committed"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: runningBundle,
            timelineResponses: [initialPage],
            suspendsTimelineWhenResponsesEmpty: true
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        let finish = SessionTimelineTurnFinishedEvent(
            sessionID: runningBundle.session.id,
            turnID: activeTurn.id,
            fidelity: "committed"
        )
        let event = EngineEvent(
            name: "session.timeline.turn.finished",
            data: try JSONEncoder().encode(finish)
        )

        // Both reducer calls return even though the eventual repository request
        // deliberately remains suspended. The second event replaces the first
        // scheduled reconciliation before either can block event consumption.
        await state.consume(event)
        await state.consume(event)
        await repository.waitUntilTimelineRequestCount(2)

        let requests = await repository.timelineRequestRecords()
        #expect(requests.count == 2)
        #expect(requests[1].afterSequence == 0)
        #expect(
            requests[1].afterCursor
                == SessionTimelineCursor(turnOrdinal: 5, itemOrdinal: -1)
        )

        await repository.releaseTimeline(with: completedPage)
        await repository.waitUntilTimelineResponseCount(2)
        await drainMainActorTasks()
        let transcript = try #require(state.conversation(for: task)?.transcript)
        #expect(toolStates(in: transcript) == [.completed])
    }

    @Test("finish payload items upsert immediately and still reconcile the turn")
    func finishItemsUseFastPath() async throws {
        let task = taskFixture()
        let bundle = sessionBundleFixture(for: task)
        let initialPage = SessionTimelinePage(
            session: bundle.session,
            items: [
                timelineTool(
                    state: "running",
                    sequence: 21,
                    turnOrdinal: 7,
                    itemOrdinal: 1
                ),
            ],
            activeTurn: nil,
            nextSequence: 21,
            nextCursor: SessionTimelineCursor(turnOrdinal: 7, itemOrdinal: 1),
            fidelity: "exact"
        )
        let completedTool = timelineTool(
            state: "completed",
            sequence: 22,
            turnOrdinal: 7,
            itemOrdinal: 1
        )
        let completedPage = SessionTimelinePage(
            session: bundle.session,
            items: [completedTool],
            activeTurn: nil,
            nextSequence: 22,
            nextCursor: SessionTimelineCursor(turnOrdinal: 7, itemOrdinal: 1),
            fidelity: "exact"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: bundle,
            timelineResponses: [initialPage],
            suspendsTimelineWhenResponsesEmpty: true,
            suspendsTimelineTurnWhenResponsesEmpty: true
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        let finish = SessionTimelineTurnFinishedEvent(
            sessionID: bundle.session.id,
            turnID: completedTool.turnID,
            fidelity: "exact",
            items: [completedTool]
        )
        await state.consume(
            EngineEvent(
                name: "session.timeline.turn.finished",
                data: try JSONEncoder().encode(finish)
            )
        )

        // The terminal mutation is visible before the deliberately suspended
        // authoritative turn request is allowed to return.
        let immediateTranscript = try #require(state.conversation(for: task)?.transcript)
        #expect(toolStates(in: immediateTranscript) == [.completed])
        await repository.waitUntilTimelineTurnRequestCount(1)
        #expect(await repository.timelineRequestRecords().count == 1)
        #expect(
            await repository.timelineTurnRequestRecords()
                == [
                    TaskTimelineTurnRequest(
                        sessionID: bundle.session.id,
                        turnID: completedTool.turnID,
                        afterCursor: nil
                    ),
                ]
        )

        await repository.releaseTimelineTurn(with: completedPage)
        await repository.waitUntilTimelineTurnResponseCount(1)
        await drainMainActorTasks()
        let reconciledTranscript = try #require(state.conversation(for: task)?.transcript)
        #expect(toolStates(in: reconciledTranscript) == [.completed])
    }

    @Test("explicit empty finish items recover live parts dropped by the event buffer")
    func emptyFinishItemsStillReconcileTheWholeTurn() async throws {
        let task = taskFixture()
        let bundle = sessionBundleFixture(for: task)
        let turnID = "turn-11"
        let user = SessionTimelineItem(
            id: "user-11",
            sessionID: bundle.session.id,
            turnID: turnID,
            sequence: 40,
            turnOrdinal: 11,
            itemOrdinal: 0,
            kind: "user",
            body: "检查刚才的执行"
        )
        let reasoning = SessionTimelineItem(
            id: "reasoning-11",
            sessionID: bundle.session.id,
            turnID: turnID,
            sequence: 41,
            turnOrdinal: 11,
            itemOrdinal: 1,
            kind: "reasoning",
            body: "先读取状态"
        )
        let tool = timelineTool(
            state: "completed",
            sequence: 42,
            turnOrdinal: 11,
            itemOrdinal: 2
        )
        let answer = SessionTimelineItem(
            id: "assistant-11",
            sessionID: bundle.session.id,
            turnID: turnID,
            sequence: 43,
            turnOrdinal: 11,
            itemOrdinal: 3,
            kind: "assistant_text",
            body: "检查完成"
        )
        let initialPage = SessionTimelinePage(
            session: bundle.session,
            items: [user],
            activeTurn: nil,
            nextSequence: 40,
            nextCursor: SessionTimelineCursor(turnOrdinal: 11, itemOrdinal: 0),
            fidelity: "exact"
        )
        let authoritativeTurnStart = SessionTimelinePage(
            session: bundle.session,
            items: [user, reasoning],
            activeTurn: nil,
            nextSequence: 41,
            nextCursor: SessionTimelineCursor(turnOrdinal: 11, itemOrdinal: 1),
            hasMore: true,
            fidelity: "exact"
        )
        let authoritativeTurnEnd = SessionTimelinePage(
            session: bundle.session,
            items: [tool, answer],
            activeTurn: nil,
            nextSequence: 43,
            nextCursor: SessionTimelineCursor(turnOrdinal: 11, itemOrdinal: 3),
            fidelity: "exact"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: bundle,
            timelineResponses: [initialPage],
            timelineTurnResponses: [authoritativeTurnStart, authoritativeTurnEnd]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        let finish = SessionTimelineTurnFinishedEvent(
            sessionID: bundle.session.id,
            turnID: turnID,
            fidelity: "exact",
            items: []
        )
        await state.consume(
            EngineEvent(
                name: "session.timeline.turn.finished",
                data: try JSONEncoder().encode(finish)
            )
        )
        await repository.waitUntilTimelineTurnResponseCount(2)
        await drainMainActorTasks()

        #expect(await repository.timelineRequestRecords().count == 1)
        #expect(
            await repository.timelineTurnRequestRecords()
                == [
                    TaskTimelineTurnRequest(
                        sessionID: bundle.session.id,
                        turnID: turnID,
                        afterCursor: nil
                    ),
                    TaskTimelineTurnRequest(
                        sessionID: bundle.session.id,
                        turnID: turnID,
                        afterCursor: SessionTimelineCursor(turnOrdinal: 11, itemOrdinal: 1)
                    ),
                ]
        )
        let transcript = try #require(state.conversation(for: task)?.transcript)
        let turn = try #require(transcript.items.compactMap { item -> ChatTurnItem? in
            guard case let .turn(turn) = item else { return nil }
            return turn.turnID == turnID ? turn : nil
        }.first)
        #expect(turn.userMessages.map(\.body) == ["检查刚才的执行"])
        #expect(turn.assistant?.body == "检查完成")
        let activity = try #require(turn.activity)
        let recoveredReasoning = activity.items.contains { item in
            guard case let .reasoning(reasoning) = item else { return false }
            return reasoning.body == "先读取状态"
        }
        let recoveredTool = activity.items.contains { item in
            guard case let .tool(tool) = item else { return false }
            return tool.state == .completed
        }
        #expect(recoveredReasoning)
        #expect(recoveredTool)
    }

    @Test("an older finished turn authority cannot clear a newly started task turn")
    func finishedTurnReconcilePreservesNewActiveTurn() async throws {
        let task = taskFixture()
        let idleBundle = sessionBundleFixture(for: task)
        let turnAUser = SessionTimelineItem(
            id: "user-a",
            sessionID: idleBundle.session.id,
            turnID: "turn-12",
            sequence: 50,
            turnOrdinal: 12,
            itemOrdinal: 0,
            kind: "user",
            body: "第一轮"
        )
        let initialPage = SessionTimelinePage(
            session: idleBundle.session,
            items: [turnAUser],
            activeTurn: nil,
            nextSequence: 50,
            nextCursor: SessionTimelineCursor(turnOrdinal: 12, itemOrdinal: 0),
            fidelity: "exact"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: idleBundle,
            timelineResponses: [initialPage],
            suspendsTimelineTurnWhenResponsesEmpty: true
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        let finishA = SessionTimelineTurnFinishedEvent(
            sessionID: idleBundle.session.id,
            turnID: turnAUser.turnID,
            fidelity: "exact",
            items: []
        )
        await state.consume(EngineEvent(
            name: "session.timeline.turn.finished",
            data: try JSONEncoder().encode(finishA)
        ))
        await repository.waitUntilTimelineTurnRequestCount(1)

        let activeTurnB = SessionTurn(
            id: "turn-13",
            sessionID: idleBundle.session.id,
            ordinal: 13,
            userMessageID: "user-b",
            providerSessionIDBefore: nil,
            providerSessionIDAfter: nil,
            status: .running,
            exitCode: nil,
            finalOutput: nil,
            errorCode: nil,
            errorMessage: nil,
            providerUsageJSON: nil,
            startedAt: "2026-08-11T00:01:00Z",
            endedAt: nil,
            createdAt: "2026-08-11T00:01:00Z"
        )
        let runningBundle = sessionBundleFixture(
            for: task,
            state: .running,
            activeTurn: activeTurnB
        )
        await state.consume(EngineEvent(
            name: "session.turn.started",
            data: try JSONEncoder().encode(runningBundle)
        ))
        let turnBUser = SessionTimelineItem(
            id: "user-b",
            sessionID: idleBundle.session.id,
            turnID: activeTurnB.id,
            sequence: 51,
            turnOrdinal: 13,
            itemOrdinal: 0,
            kind: "user",
            body: "第二轮"
        )
        await state.consume(EngineEvent(
            name: "session.timeline.item.appended",
            data: try JSONEncoder().encode(turnBUser)
        ))

        let turnAAnswer = SessionTimelineItem(
            id: "answer-a",
            sessionID: idleBundle.session.id,
            turnID: turnAUser.turnID,
            sequence: 52,
            turnOrdinal: 12,
            itemOrdinal: 1,
            kind: "assistant_text",
            body: "第一轮权威结果"
        )
        let staleAuthorityA = SessionTimelinePage(
            session: idleBundle.session,
            items: [turnAUser, turnAAnswer],
            activeTurn: nil,
            nextSequence: 52,
            nextCursor: SessionTimelineCursor(turnOrdinal: 12, itemOrdinal: 1),
            fidelity: "exact"
        )
        await repository.releaseTimelineTurn(with: staleAuthorityA)
        await repository.waitUntilTimelineTurnResponseCount(1)
        await drainMainActorTasks()

        let conversation = try #require(state.conversation(for: task))
        #expect(conversation.state == .running)
        #expect(conversation.transcript.isRunning)
        let turns = conversation.transcript.items.compactMap { item -> ChatTurnItem? in
            guard case let .turn(turn) = item else { return nil }
            return turn
        }
        #expect(turns.map(\.turnID) == [turnAUser.turnID, activeTurnB.id])
        #expect(turns.first?.assistant?.body == "第一轮权威结果")
        #expect(turns.last?.isRunning == true)
        #expect(turns.last?.userMessages.first?.body == "第二轮")
    }

    @Test(
        "degraded or unknown finish fidelity reconciles the current turn",
        arguments: ["failed", "future-fidelity"]
    )
    func nonAuthoritativeFinishFidelityReconciles(fidelity: String) async throws {
        let task = taskFixture()
        let bundle = sessionBundleFixture(for: task)
        let tool = timelineTool(
            state: "running",
            sequence: 31,
            turnOrdinal: 9,
            itemOrdinal: 1
        )
        let initialPage = SessionTimelinePage(
            session: bundle.session,
            items: [tool],
            activeTurn: nil,
            nextSequence: 31,
            nextCursor: SessionTimelineCursor(turnOrdinal: 9, itemOrdinal: 1),
            fidelity: "exact"
        )
        let completedTool = timelineTool(
            state: "completed",
            sequence: 32,
            turnOrdinal: 9,
            itemOrdinal: 1
        )
        let completedPage = SessionTimelinePage(
            session: bundle.session,
            items: [completedTool],
            activeTurn: nil,
            nextSequence: 32,
            nextCursor: SessionTimelineCursor(turnOrdinal: 9, itemOrdinal: 1),
            fidelity: "exact"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: bundle,
            timelineResponses: [initialPage],
            suspendsTimelineWhenResponsesEmpty: true,
            suspendsTimelineTurnWhenResponsesEmpty: true
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        let finish = SessionTimelineTurnFinishedEvent(
            sessionID: bundle.session.id,
            turnID: tool.turnID,
            fidelity: fidelity,
            items: [completedTool]
        )
        await state.consume(
            EngineEvent(
                name: "session.timeline.turn.finished",
                data: try JSONEncoder().encode(finish)
            )
        )
        let immediateTranscript = try #require(state.conversation(for: task)?.transcript)
        #expect(toolStates(in: immediateTranscript) == [.running])
        await repository.waitUntilTimelineTurnRequestCount(1)
        #expect(await repository.timelineRequestRecords().count == 1)

        await repository.releaseTimelineTurn(with: completedPage)
        await repository.waitUntilTimelineTurnResponseCount(1)
        await drainMainActorTasks()
        let reconciledTranscript = try #require(state.conversation(for: task)?.transcript)
        #expect(toolStates(in: reconciledTranscript) == [.completed])
    }

    @Test("normal task send hydrates from the cached timeline cursor")
    func taskSendUsesCachedTimelineCursor() async throws {
        let task = taskFixture()
        let bundle = sessionBundleFixture(for: task)
        let initialPage = SessionTimelinePage(
            session: bundle.session,
            items: [],
            activeTurn: nil,
            nextSequence: 42,
            nextCursor: SessionTimelineCursor(turnOrdinal: 3, itemOrdinal: 9),
            fidelity: "exact"
        )
        let incrementalPage = SessionTimelinePage(
            session: bundle.session,
            items: [],
            activeTurn: nil,
            nextSequence: 43,
            nextCursor: SessionTimelineCursor(turnOrdinal: 4, itemOrdinal: 0),
            fidelity: "exact"
        )
        let repository = TaskOpenSpyRepository(
            task: task,
            session: bundle,
            timelineResponses: [initialPage, incrementalPage]
        )
        let state = AppState(repository: repository)
        await state.load()
        state.openTask(task)
        await repository.waitUntilTimelineRequestCount(1)
        await drainMainActorTasks()

        #expect(await state.sendToSession(task, text: "继续"))

        let requests = await repository.timelineRequestRecords()
        #expect(requests.count == 2)
        #expect(requests[1].afterSequence == 42)
        #expect(
            requests[1].afterCursor
                == SessionTimelineCursor(turnOrdinal: 3, itemOrdinal: 9)
        )
    }

    @Test("Gemini connection test uses the selected model")
    func geminiConnectionTest() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()

        let result = try await state.testGeminiConnection(model: "gemini-3.6-flash")

        #expect(result.ok)
        #expect(result.model == "gemini-3.6-flash")
        #expect(result.displayName == "Gemini Demo")
    }

    @Test("shared AppState starts the Engine only once across windows")
    func loadIsSingleFlight() async {
        let repository = AssistantTestRepository(suspendLoad: true)
        let state = AppState(repository: repository)

        let first = Task { await state.load() }
        await repository.waitUntilLoadStarts()
        let second = Task { await state.load() }
        first.cancel()
        await Task.yield()

        #expect(state.loadState == .loading)
        await repository.releaseLoad()
        await second.value
        await first.value
        await state.load()

        #expect(await repository.loadCount() == 1)
        #expect(state.loadState == .loaded)
    }

    @Test("tasks only transition between open and completed")
    func completionLifecycle() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(task.status == .open)
        #expect(await state.setCompleted(task, completed: true))
        let completed = try #require(state.task(id: task.id))
        #expect(completed.status == .completed)
        #expect(await state.setCompleted(completed, completed: false))
        #expect(state.task(id: task.id)?.status == .open)
    }

    @Test("a task binds one runtime and working directory")
    func sessionConfiguration() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(state.session(for: task) == nil)
        #expect(await state.startSession(task, runtime: .kiro, workspace: "/tmp/project"))
        let session = try #require(state.session(for: task))
        #expect(session.runtimeKind == .kiro)
        #expect(session.workingDirectory == "/tmp/project")
        #expect(session.providerEngine == nil)
    }

    @Test("starting a task Session stays empty until the user sends")
    func taskSessionStartsWithoutAutomaticTurn() async throws {
        let repository = DemoRepository()
        let state = AppState(repository: repository)
        await state.load()
        let task = try #require(state.tasks.first)

        #expect(await state.startSession(task, runtime: .codex, workspace: "/tmp/project"))

        let created = try #require(try await repository.session(taskID: task.id))
        #expect(created.messages.isEmpty)
        #expect(created.activeTurn == nil)
        #expect(created.session.state == .idle)
        #expect(state.conversation(for: task)?.entries.isEmpty == true)

        #expect(await state.sendToSession(task, text: "现在开始执行"))
        let sent = try #require(try await repository.session(taskID: task.id))
        #expect(sent.messages.map(\.body) == ["现在开始执行"])
        #expect(state.conversation(for: task)?.entries.map(\.body) == ["现在开始执行"])
    }

    @Test("composer sends into the bound logical session")
    func sessionMessage() async throws {
        let state = AppState(repository: DemoRepository())
        await state.load()
        let task = try #require(state.tasks.first)
        #expect(await state.startSession(task, runtime: .codex, workspace: "/tmp/project"))
        #expect(await state.sendToSession(task, text: "继续检查测试"))
        let conversation = try #require(state.conversation(for: task))
        #expect(conversation.entries.last?.role == .user)
        #expect(conversation.entries.last?.body == "继续检查测试")
    }

    @Test("same-sequence CLI deltas replace the durable message projection")
    func sameSequenceCLIDeltaStaysLive() {
        let task = taskFixture()
        let session = sessionBundleFixture(for: task).session
        let first = SessionMessage(
            id: "agent-message",
            sessionID: session.id,
            turnID: "turn-1",
            sequence: 2,
            clientMessageID: nil,
            role: .agent,
            kind: "text",
            body: "第一段",
            payloadJSON: nil,
            createdAt: "2026-08-09T00:00:00Z",
            updatedAt: "2026-08-09T00:00:01Z"
        )
        let updated = SessionMessage(
            id: first.id,
            sessionID: first.sessionID,
            turnID: first.turnID,
            sequence: first.sequence,
            clientMessageID: nil,
            role: .agent,
            kind: "text",
            body: "第一段，第二段",
            payloadJSON: nil,
            createdAt: first.createdAt,
            updatedAt: "2026-08-09T00:00:02Z"
        )
        let initial = SessionBundle(session: session, messages: [first], activeTurn: nil)

        let merged = initial.merging(message: updated)

        #expect(merged.messages.count == 1)
        #expect(merged.messages.first?.id == first.id)
        #expect(merged.messages.first?.sequence == 2)
        #expect(merged.messages.first?.body == "第一段，第二段")
    }

    @Test("projection separates completion from active session state")
    func projectionCounts() {
        let now = Date(timeIntervalSince1970: 1_786_080_000)
        let task = TaskItem(id: UUID(), listID: nil, title: "任务", note: "", status: .open, executionDate: LocalDay(now), dueDate: nil, completedAt: nil, createdAt: now, updatedAt: "")
        let projection = TaskProjection(tasks: [task], now: now)
        let session = TaskSessionDescriptor(id: UUID().uuidString, taskID: task.id, runtimeKind: .claude, workingDirectory: "/tmp", providerSessionID: nil, providerEngine: nil, state: .running, lastAgentSequence: 3, lastReadSequence: 2, lastErrorCode: nil, lastErrorMessage: nil, createdAt: "", updatedAt: "")

        #expect(projection.count(for: .myDay, sessions: [session]) == 1)
        #expect(projection.count(for: .running, sessions: [session]) == 1)
        #expect(projection.count(for: .done, sessions: [session]) == 0)
        #expect(session.hasUnread)
    }

    @Test("embedded workspace switches tasks and collapse keeps the last selection")
    func embeddedWorkspaceSelectionAndCollapse() async {
        let first = taskFixture()
        let second = TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000402")!,
            listID: nil,
            title: "继续本地 Agent",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [first, second],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        state.taskWorkspacePresenter = workspace
        state.terminalSessions = sessions
        await state.load()

        state.inspectorPresented = true
        workspace.showTaskWorkspace(taskID: first.id)
        #expect(workspace.presentedTaskID == first.id)
        #expect(state.inspectorPresented == false)

        state.inspectorPresented = true
        workspace.showTaskWorkspace(taskID: second.id)
        await drainMainActorTasks()
        #expect(workspace.presentedTaskID == second.id)
        #expect(state.inspectorPresented)

        let composerDraft = workspace.composerState(for: .allTasks)
        composerDraft.draft = "切换后仍保留的任务草稿"

        workspace.closeTaskWorkspace(taskID: second.id)
        await drainMainActorTasks()
        #expect(workspace.presentedTaskID == nil)
        #expect(workspace.selectedTaskID == second.id)
        #expect(workspace.contains(taskID: second.id))
        #expect(workspace.composerState(for: .allTasks) === composerDraft)
        #expect(workspace.composerState(for: .allTasks).draft == "切换后仍保留的任务草稿")
        #expect(workspace.closingTaskID == nil)
    }

    @Test("a rapid request back to the mounted task cancels the pending switch")
    func embeddedWorkspaceRapidSwitchBack() async {
        let first = taskFixture()
        let second = TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000403")!,
            listID: nil,
            title: "第二个 Agent",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [first, second],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        state.taskWorkspacePresenter = workspace
        state.terminalSessions = sessions
        await state.load()

        workspace.showTaskWorkspace(taskID: first.id)
        workspace.showTaskWorkspace(taskID: second.id)
        #expect(workspace.pendingTaskID == second.id)
        workspace.showTaskWorkspace(taskID: first.id)
        await drainMainActorTasks()

        #expect(workspace.presentedTaskID == first.id)
        #expect(workspace.pendingTaskID == nil)
    }

    @Test("deleting an outgoing task keeps its pending successor alive")
    func deletingOutgoingWorkspaceKeepsPendingSuccessor() async {
        let first = taskFixture()
        let second = TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000411")!,
            listID: nil,
            title: "继续打开的任务",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-16T00:00:00Z"
        )
        let repository = TaskOpenSpyRepository(
            snapshot: AppSnapshot(
                revision: 1,
                lists: [],
                tasks: [first, second],
                runtimes: [],
                sessions: [],
                messages: []
            )
        )
        let state = AppState(repository: repository)
        let sessions = TerminalSessionRegistry(repository: repository)
        let workspace = TaskWorkspaceCoordinator(state: state, terminalSessions: sessions)
        await state.load()

        workspace.showTaskWorkspace(taskID: first.id)
        workspace.showTaskWorkspace(taskID: second.id)
        #expect(workspace.pendingTaskID == second.id)

        workspace.destroyTaskWorkspace(taskID: first.id)
        await drainMainActorTasks()

        #expect(workspace.pendingTaskID == nil)
        #expect(workspace.presentedTaskID == second.id)
    }

    private func taskFixture() -> TaskItem {
        TaskItem(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000401")!,
            listID: nil,
            title: "配置本地 Agent",
            note: "",
            status: .open,
            dueDate: nil,
            completedAt: nil,
            createdAt: .distantPast,
            updatedAt: "2026-08-09T00:00:00Z"
        )
    }

    private func sessionBundleFixture(
        for task: TaskItem,
        state: SessionState = .idle,
        activeTurn: SessionTurn? = nil
    ) -> SessionBundle {
        SessionBundle(
            session: TaskSessionDescriptor(
                id: "task-session",
                taskID: task.id,
                runtimeKind: .codex,
                workingDirectory: "/tmp/project",
                providerSessionID: "provider-session",
                providerEngine: nil,
                state: state,
                lastAgentSequence: 0,
                lastReadSequence: 0,
                lastErrorCode: nil,
                lastErrorMessage: nil,
                createdAt: "2026-08-09T00:00:00Z",
                updatedAt: "2026-08-09T00:00:00Z"
            ),
            messages: [],
            activeTurn: activeTurn
        )
    }

    private func timelineTool(
        state: String,
        sequence: Int64,
        turnOrdinal: Int64,
        itemOrdinal: Int64
    ) -> SessionTimelineItem {
        SessionTimelineItem(
            id: "tool-call-1",
            sessionID: "task-session",
            turnID: "turn-\(turnOrdinal)",
            sequence: sequence,
            turnOrdinal: turnOrdinal,
            itemOrdinal: itemOrdinal,
            kind: "tool",
            callID: "call-1",
            toolName: "Bash",
            outputText: state == "running" ? nil : "done",
            toolState: state,
            fidelity: state == "running" ? "live" : "committed"
        )
    }

    private func toolStates(in transcript: ChatTranscript) -> [ChatToolState] {
        transcript.items.flatMap { item -> [ChatToolState] in
            guard case let .turn(turn) = item else { return [] }
            return turn.activity?.items.compactMap { activity -> ChatToolState? in
                guard case let .tool(tool) = activity else { return nil }
                return tool.state
            } ?? []
        }
    }

    private func emptySnapshot(lists: [TodoList] = []) -> AppSnapshot {
        AppSnapshot(revision: 1, lists: lists, tasks: [], runtimes: [], sessions: [], messages: [])
    }

    private func drainMainActorTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

private struct TaskCreateCall: Equatable, Sendable {
    let title: String
    let listID: UUID?
}

private struct TaskTimelineRequest: Equatable, Sendable {
    let sessionID: String
    let afterSequence: Int64
    let afterCursor: SessionTimelineCursor?
}

private struct TaskTimelineTurnRequest: Equatable, Sendable {
    let sessionID: String
    let turnID: String
    let afterCursor: SessionTimelineCursor?
}

private actor TaskOpenSpyRepository: AppRepository {
    private var snapshot: AppSnapshot
    private var sessionBundle: SessionBundle?
    private let delaysSessionLookup: Bool
    private let lookupFailure: AppRepositoryError?
    private var timelineResponses: [SessionTimelinePage]
    private var suspendsTimelineWhenResponsesEmpty: Bool
    private var timelineRequests: [TaskTimelineRequest] = []
    private var timelineResponseCount = 0
    private var timelineTurnResponses: [SessionTimelinePage]
    private var suspendsTimelineTurnWhenResponsesEmpty: Bool
    private var timelineTurnRequests: [TaskTimelineTurnRequest] = []
    private var timelineTurnResponseCount = 0
    private var timelineRequestWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var timelineResponseWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var timelineTurnRequestWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var timelineTurnResponseWaiters: [
        (targetCount: Int, continuation: CheckedContinuation<Void, Never>)
    ] = []
    private var sessionLookups = 0
    private var createdListNames: [String] = []
    private var taskCreations: [TaskCreateCall] = []
    private var sessionLookupWaiters: [CheckedContinuation<Void, Never>] = []
    private var delayedSessionLookup: CheckedContinuation<SessionBundle?, any Error>?

    init(
        task: TaskItem,
        session: SessionBundle?,
        delaysSessionLookup: Bool = false,
        lookupFailure: AppRepositoryError? = nil,
        timelineResponses: [SessionTimelinePage] = [],
        suspendsTimelineWhenResponsesEmpty: Bool = false,
        timelineTurnResponses: [SessionTimelinePage] = [],
        suspendsTimelineTurnWhenResponsesEmpty: Bool = false
    ) {
        sessionBundle = session
        self.delaysSessionLookup = delaysSessionLookup
        self.lookupFailure = lookupFailure
        self.timelineResponses = timelineResponses
        self.suspendsTimelineWhenResponsesEmpty = suspendsTimelineWhenResponsesEmpty
        self.timelineTurnResponses = timelineTurnResponses
        self.suspendsTimelineTurnWhenResponsesEmpty = suspendsTimelineTurnWhenResponsesEmpty
        snapshot = AppSnapshot(
            revision: 1,
            lists: [],
            tasks: [task],
            runtimes: [],
            sessions: session.map { [$0.session] } ?? [],
            messages: []
        )
    }

    init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
        sessionBundle = nil
        delaysSessionLookup = false
        lookupFailure = nil
        timelineResponses = []
        suspendsTimelineWhenResponsesEmpty = false
        timelineTurnResponses = []
        suspendsTimelineTurnWhenResponsesEmpty = false
    }

    func load() async throws -> AppSnapshot { snapshot }
    func sync() async throws -> AppSnapshot { snapshot }
    func events() async -> AsyncStream<EngineEvent> { AsyncStream { $0.finish() } }
    func createList(name: String, color: String) async throws -> AppSnapshot {
        createdListNames.append(name)
        snapshot.lists.append(
            TodoList(id: UUID(), name: name, colorName: color, repositoryPath: nil)
        )
        snapshot.revision += 1
        return snapshot
    }
    func renameList(listID: UUID, name: String) async throws -> AppSnapshot {
        guard let index = snapshot.lists.firstIndex(where: { $0.id == listID }) else {
            throw AppRepositoryError.listNotFound
        }
        let existing = snapshot.lists[index]
        snapshot.lists[index] = TodoList(
            id: existing.id,
            name: name,
            colorName: existing.colorName,
            repositoryPath: existing.repositoryPath
        )
        snapshot.revision += 1
        return snapshot
    }
    func deleteList(listID: UUID) async throws -> AppSnapshot {
        guard snapshot.lists.contains(where: { $0.id == listID }) else {
            throw AppRepositoryError.listNotFound
        }
        snapshot.lists.removeAll(where: { $0.id == listID })
        for index in snapshot.tasks.indices where snapshot.tasks[index].listID == listID {
            snapshot.tasks[index].listID = nil
        }
        snapshot.revision += 1
        return snapshot
    }
    func createTask(title: String, note: String, listID: UUID?, executionDate: LocalDay?, dueDate: LocalDay?) async throws -> AppSnapshot {
        taskCreations.append(TaskCreateCall(title: title, listID: listID))
        snapshot.revision += 1
        return snapshot
    }
    func updateTask(taskID: UUID, patch: TaskPatch) async throws -> AppSnapshot {
        if let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) {
            snapshot.tasks[index].apply(patch)
            snapshot.revision += 1
        }
        return snapshot
    }
    func deleteTask(taskID: UUID) async throws -> AppSnapshot {
        snapshot.tasks.removeAll(where: { $0.id == taskID })
        snapshot.revision += 1
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
        return snapshot
    }
    func addTaskAttachments(taskID: UUID, sourcePaths: [String], clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func removeTaskAttachment(taskID: UUID, attachmentID: UUID, clientMutationID: UUID) async throws -> AppSnapshot { snapshot }
    func setCompleted(taskID: UUID, completed: Bool) async throws -> AppSnapshot { snapshot }
    func detectRuntimes() async throws -> AppSnapshot { snapshot }
    func verifyRuntime(_ kind: RuntimeKind) async throws -> AppSnapshot { snapshot }

    func session(taskID: UUID) async throws -> SessionBundle? {
        sessionLookups += 1
        let waiters = sessionLookupWaiters
        sessionLookupWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        if delaysSessionLookup {
            return try await withCheckedThrowingContinuation { continuation in
                delayedSessionLookup = continuation
            }
        }
        if let lookupFailure { throw lookupFailure }
        return sessionBundle
    }

    func createSession(taskID: UUID, runtime: RuntimeKind, workspace: String) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func send(sessionID: String, text: String, clientMessageID: UUID) async throws -> SessionBundle {
        guard let sessionBundle, sessionBundle.session.id == sessionID else {
            throw AppRepositoryError.sessionNotFound
        }
        return sessionBundle
    }
    func history(sessionID: String, after sequence: Int64) async throws -> SessionBundle {
        throw AppRepositoryError.sessionNotFound
    }
    func timeline(
        sessionID: String,
        after sequence: Int64,
        afterCursor: SessionTimelineCursor?
    ) async throws -> SessionTimelinePage? {
        timelineRequests.append(
            TaskTimelineRequest(
                sessionID: sessionID,
                afterSequence: sequence,
                afterCursor: afterCursor
            )
        )
        let readyWaiters = timelineRequestWaiters.filter {
            timelineRequests.count >= $0.targetCount
        }
        timelineRequestWaiters.removeAll {
            timelineRequests.count >= $0.targetCount
        }
        for waiter in readyWaiters { waiter.continuation.resume() }

        while timelineResponses.isEmpty, suspendsTimelineWhenResponsesEmpty {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !timelineResponses.isEmpty else { return nil }
        let response = timelineResponses.removeFirst()
        timelineResponseCount += 1
        let deliveredWaiters = timelineResponseWaiters.filter {
            timelineResponseCount >= $0.targetCount
        }
        timelineResponseWaiters.removeAll {
            timelineResponseCount >= $0.targetCount
        }
        for waiter in deliveredWaiters { waiter.continuation.resume() }
        return response
    }
    func timelineTurn(
        sessionID: String,
        turnID: String,
        afterCursor: SessionTimelineCursor?
    ) async throws -> SessionTimelinePage? {
        timelineTurnRequests.append(
            TaskTimelineTurnRequest(
                sessionID: sessionID,
                turnID: turnID,
                afterCursor: afterCursor
            )
        )
        let readyWaiters = timelineTurnRequestWaiters.filter {
            timelineTurnRequests.count >= $0.targetCount
        }
        timelineTurnRequestWaiters.removeAll {
            timelineTurnRequests.count >= $0.targetCount
        }
        for waiter in readyWaiters { waiter.continuation.resume() }

        while timelineTurnResponses.isEmpty, suspendsTimelineTurnWhenResponsesEmpty {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }
        guard !timelineTurnResponses.isEmpty else { return nil }
        let response = timelineTurnResponses.removeFirst()
        timelineTurnResponseCount += 1
        let deliveredWaiters = timelineTurnResponseWaiters.filter {
            timelineTurnResponseCount >= $0.targetCount
        }
        timelineTurnResponseWaiters.removeAll {
            timelineTurnResponseCount >= $0.targetCount
        }
        for waiter in deliveredWaiters { waiter.continuation.resume() }
        return response
    }
    func markRead(sessionID: String, through sequence: Int64) async throws {}
    func cancelTurn(sessionID: String) async throws {}
    func injectGeminiKey(_ key: String) async throws {}
    func clearGeminiKey() async throws {}
    func testGeminiConnection(model: String) async throws -> GeminiConnectionResult {
        GeminiConnectionResult(ok: true, model: model, displayName: "Gemini Test", version: "test")
    }
    func assistantStatus() async throws -> AssistantStatus {
        AssistantStatus(configured: false, available: false, model: nil, reason: "未配置")
    }
    func assistantSessions(includeArchived: Bool) async throws -> [AssistantSessionDescriptor] { [] }
    func createAssistantSession(title: String?) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func renameAssistantSession(sessionID: String, title: String) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func archiveAssistantSession(sessionID: String) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func assistantHistory(sessionID: String, after sequence: Int64) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func sendAssistantMessage(
        sessionID: String,
        clientMessageID: UUID,
        text: String,
        model: String,
        attachments: [AssistantTextAttachment]
    ) async throws -> AssistantSessionBundle {
        throw AppRepositoryError.assistantSessionNotFound
    }
    func cancelAssistantTurn(sessionID: String) async throws {}
    func shutdown() async {}

    func sessionLookupCount() -> Int { sessionLookups }
    func taskCreateCalls() -> [TaskCreateCall] { taskCreations }
    func listCreateNames() -> [String] { createdListNames }
    func timelineRequestRecords() -> [TaskTimelineRequest] { timelineRequests }
    func timelineTurnRequestRecords() -> [TaskTimelineTurnRequest] { timelineTurnRequests }

    func waitUntilTimelineRequestCount(_ targetCount: Int) async {
        guard timelineRequests.count < targetCount else { return }
        await withCheckedContinuation { continuation in
            timelineRequestWaiters.append((targetCount, continuation))
        }
    }

    func waitUntilTimelineResponseCount(_ targetCount: Int) async {
        guard timelineResponseCount < targetCount else { return }
        await withCheckedContinuation { continuation in
            timelineResponseWaiters.append((targetCount, continuation))
        }
    }

    func waitUntilTimelineTurnRequestCount(_ targetCount: Int) async {
        guard timelineTurnRequests.count < targetCount else { return }
        await withCheckedContinuation { continuation in
            timelineTurnRequestWaiters.append((targetCount, continuation))
        }
    }

    func waitUntilTimelineTurnResponseCount(_ targetCount: Int) async {
        guard timelineTurnResponseCount < targetCount else { return }
        await withCheckedContinuation { continuation in
            timelineTurnResponseWaiters.append((targetCount, continuation))
        }
    }

    func releaseTimeline(with response: SessionTimelinePage) {
        timelineResponses.append(response)
        suspendsTimelineWhenResponsesEmpty = false
    }

    func releaseTimelineTurn(with response: SessionTimelinePage) {
        timelineTurnResponses.append(response)
        suspendsTimelineTurnWhenResponsesEmpty = false
    }

    func completeDelayedSessionLookup() {
        guard let delayedSessionLookup else { return }
        self.delayedSessionLookup = nil
        if let lookupFailure {
            delayedSessionLookup.resume(throwing: lookupFailure)
        } else {
            delayedSessionLookup.resume(returning: sessionBundle)
        }
    }

    func waitUntilSessionLookup() async {
        guard sessionLookups == 0 else { return }
        await withCheckedContinuation { continuation in
            sessionLookupWaiters.append(continuation)
        }
    }
}
