import SwiftUI

struct ContentView: View {
    @State private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: AppState) {
        _state = State(initialValue: state)
    }

    init(repository: any AppRepository) {
        _state = State(initialValue: AppState(repository: repository))
    }

    var body: some View {
        @Bindable var state = state

        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(
                    min: 230,
                    ideal: TodoAgentUI.sidebarIdealWidth,
                    max: TodoAgentUI.sidebarMaximumWidth
                )
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                BoardView(state: state)

                if !state.inspectorPresented {
                    AssistantFloatingButton {
                        state.openAssistant()
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
        }
        .navigationSplitViewStyle(.balanced)
        .tint(TodoAgentUI.primaryText)
        .disabled(state.loadState == .loading)
        .inspector(isPresented: $state.inspectorPresented) {
            TodoAgentInspector(state: state) {
                state.inspectorPresented = false
            }
                .inspectorColumnWidth(
                    min: 380,
                    ideal: TodoAgentUI.inspectorIdealWidth,
                    max: 560
                )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    state.presentNewTask()
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .help("新建任务 ⌘N")
                .accessibilityIdentifier("toolbar.new-task")

                Button {
                    Task { await state.openNewAssistantConversation() }
                } label: {
                    Label("新建 TodoAgent 对话", systemImage: "plus.bubble")
                }
                .disabled(state.assistant.isManagingSession)
                .help("新建 TodoAgent 对话 ⇧⌘O")
                .accessibilityIdentifier("toolbar.new-assistant-session")

                Button {
                    state.toggleAssistant()
                } label: {
                    Label("TodoAgent", systemImage: "sidebar.right")
                }
                .help(state.inspectorPresented ? "收起 TodoAgent ⌥⌘I" : "打开 TodoAgent ⌥⌘I")
                .accessibilityIdentifier("toolbar.todoagent")
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: state.inspectorPresented)
        .task { await state.load() }
        .sheet(item: $state.presentedSheet) { destination in
            sheet(destination)
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewTask)) { _ in
            state.presentNewTask()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentToggleInspector)) { _ in
            state.toggleAssistant()
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentNewAssistantConversation)) { _ in
            Task { await state.openNewAssistantConversation() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .todoAgentCancelCurrent)) { _ in
            state.presentedSheet = nil
        }
        .overlay {
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
        .alert("操作未完成", isPresented: errorPresented) {
            Button("好", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "请稍后再试。")
        }
    }

    @ViewBuilder
    private func sheet(_ destination: AppSheet) -> some View {
        switch destination {
        case .newTask:
            NewTaskSheet(state: state, initialListID: state.pendingNewTaskListID)
        case let .taskSession(taskID):
            TaskDestinationSheet(taskID: taskID, state: state)
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } }
        )
    }
}

private struct AssistantFloatingButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(TodoAgentUI.primaryText)
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

private struct NewTaskSheet: View {
    let state: AppState
    private let initialListID: UUID?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var hasDueDate = true
    @State private var dueDate = Date.now
    @State private var isSaving = false

    init(state: AppState, initialListID: UUID?) {
        self.state = state
        self.initialListID = initialListID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建任务")
                .font(.title2.bold())

            TextField("要完成什么？", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("task.title-field")

            Toggle("设置日期", isOn: $hasDueDate)

            if hasDueDate {
                DatePicker("日期", selection: $dueDate, displayedComponents: .date)
                    .datePickerStyle(.field)
            }

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                    .accessibilityIdentifier("task.save")
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func save() {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSaving else { return }
        isSaving = true
        Task {
            if await state.createTask(
                title: value,
                listID: initialListID,
                dueDate: hasDueDate ? dueDate : nil
            ) {
                dismiss()
            } else {
                isSaving = false
            }
        }
    }
}

private struct TaskDestinationSheet: View {
    let taskID: UUID
    let state: AppState

    var body: some View {
        if let task = state.task(id: taskID) {
            TaskConversationSheet(task: task, state: state)
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
    func createTask(title: String, note: String, listID: UUID?, dueDate: Date?) async throws -> AppSnapshot { snapshot }
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
