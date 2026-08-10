import AppKit
import SwiftUI

struct ContentView: View {
    @State private var state: AppState
    @State private var availableContentSize = TodoAgentMainWindowPlacement.preferredContentSize
    @State private var assistantResizeStartWidth: CGFloat?
    @State private var assistantLiveWidth: CGFloat?
    @AppStorage(AssistantPanePreferences.widthKey) private var storedAssistantWidth = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        _state = State(initialValue: state)
    }

    init(repository: any AppRepository) {
        _state = State(initialValue: AppState(repository: repository))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
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
                let assistantContainerWidth = state.inspectorPresented
                    ? assistantWidth + MainWorkspaceLayoutPolicy.dividerWidth
                    : 0

                HStack(spacing: 0) {
                    boardWorkspace
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    ZStack(alignment: .trailing) {
                        if state.inspectorPresented {
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
                                    .frame(width: assistantWidth)
                            }
                            .frame(width: assistantWidth + MainWorkspaceLayoutPolicy.dividerWidth)
                            .transition(
                                .move(edge: .trailing)
                                    .combined(with: .opacity)
                            )
                        }
                    }
                    .frame(width: assistantContainerWidth, alignment: .trailing)
                    .clipped()
                }
                // The divider itself moves while it is being dragged. Keep
                // the gesture in this fixed workspace coordinate space so
                // its translation does not feed back into the next event.
                .coordinateSpace(name: AssistantWorkspaceCoordinateSpace.name)
                .clipped()
                .animation(
                    AssistantWorkspaceMotion.animation(reduceMotion: reduceMotion),
                    value: state.inspectorPresented
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(TodoAgentUI.primaryText)
        .disabled(state.loadState == .loading || state.isPreparingToTerminate)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ContentSizePreferenceKey.self,
                    value: proxy.size
                )
            }
        }
        .onPreferenceChange(ContentSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            availableContentSize = size
        }
        .task { await state.load() }
        .sheet(item: $state.presentedSheet) { destination in
            sheet(destination, availableSize: availableContentSize)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentToggleInspector)) { _ in
            Task { await state.toggleAssistant() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewAssistantConversation)) { _ in
            Task { await state.openNewAssistantConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentCancelCurrent)) { _ in
            if case .taskSession = state.presentedSheet {
                NotificationCenter.default.post(name: .todoAgentRequestTaskSheetClose, object: nil)
            } else {
                state.presentedSheet = nil
            }
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
        ZStack(alignment: .bottomTrailing) {
            BoardView(state: state)

            if !state.inspectorPresented {
                AssistantFloatingButton {
                    Task { await state.openAssistant() }
                }
                .padding(.trailing, 22)
                .padding(.bottom, 24)
                .transition(
                    .scale(scale: 0.88, anchor: .bottomTrailing)
                        .combined(with: .opacity)
                )
            }
        }
        .background(TodoAgentUI.canvasBackground)
        .animation(
            AssistantWorkspaceMotion.animation(reduceMotion: reduceMotion),
            value: state.inspectorPresented
        )
    }

    private var persistedAssistantWidth: CGFloat? {
        storedAssistantWidth > 0 ? CGFloat(storedAssistantWidth) : nil
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

    @ViewBuilder
    private func sheet(_ destination: AppSheet, availableSize: CGSize) -> some View {
        switch destination {
        case let .taskSession(taskID):
            TaskDestinationSheet(
                taskID: taskID,
                state: state,
                availableSize: availableSize
            )
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }
}

enum MainWorkspaceLayout: Equatable, Sendable {
    case boardOnly
    case sideBySide(assistantWidth: CGFloat)
}

enum MainWorkspaceLayoutPolicy {
    static let dividerWidth: CGFloat = 10
    static let assistantMinimumWidth: CGFloat = 260
    static let boardMinimumVisibleWidth = TimelineColumnLayoutPolicy.viewportWidth(
        showingDayCount: 1
    )
    static let defaultBoardWidth = TimelineColumnLayoutPolicy.viewportWidth(
        showingDayCount: 2
    )

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
    // v3 aligns the default divider with the midpoint between timeline days.
    // Once the user drags it, the custom width remains persistent as usual.
    static let widthKey = "assistantPaneWidth.v3"
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
        .accessibilityHint("打开 TodoAgent 对话面板")
        .accessibilityIdentifier("assistant.floating-button")
    }
}

private struct TaskDestinationSheet: View {
    let taskID: UUID
    let state: AppState
    let availableSize: CGSize

    var body: some View {
        if let task = state.task(id: taskID) {
            TaskConversationSheet(
                task: task,
                state: state,
                availableSize: availableSize
            )
        } else {
            ContentUnavailableView(
                "任务已不存在",
                systemImage: "questionmark.folder",
                description: Text("关闭窗口后刷新任务列表。")
            )
            .frame(width: 420, height: 260)
        }
    }
}

private struct ContentSizePreferenceKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
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
