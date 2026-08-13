import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case runtimes
    case model
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .runtimes: "本机 CLI"
        case .model: "TodoAgent"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .runtimes: "terminal"
        case .model: "sparkles"
        case .about: "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var history: [SettingsTab] = [.general]
    @State private var historyIndex = 0

    private var activeTab: SettingsTab { navigation.selectedTab ?? .general }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .tag(tab)
                }

                Text("0.1.0 Preview")
                    .font(.footnote.monospaced())
                    .foregroundStyle(.tertiary)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .navigationTitle("设置")
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
            .scrollEdgeEffectStyle(.soft, for: .all)
        } detail: {
            settingsDetail
                .navigationTitle(activeTab.title)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex == 0)
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, newValue in
            guard let newValue else { return }
            guard history[safe: historyIndex] != newValue else { return }
            history = Array(history.prefix(historyIndex + 1))
            history.append(newValue)
            historyIndex = history.count - 1
        }
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch activeTab {
        case .general: GeneralSettingsPane()
        case .runtimes: RuntimeSettingsPane(state: AppContainer.shared.state)
        case .model: ModelSettingsPane()
        case .about: AboutSettingsPane()
        }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigation.selectedTab = history[historyIndex]
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        navigation.selectedTab = history[historyIndex]
    }
}

private struct GeneralSettingsPane: View {
    @AppStorage("showAssistantAtLaunch") private var showAssistantAtLaunch = false

    var body: some View {
        settingsForm {
            Section("工作区") {
                Text("本地 Agent 会直接在你选择的目录中启动，不检查 Git 状态，也不会自动提交、合并或清理你的改动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("窗口") {
                Toggle("启动时显示 TodoAgent", isOn: $showAssistantAtLaunch)
            }
        }
    }
}

private struct RuntimeSettingsPane: View {
    @Bindable var state: AppState
    @State private var refreshingKinds: Set<RuntimeKind> = []
    @State private var isRefreshingAll = false
    @State private var actionMessage: String?
    @State private var statusAuthorizationRevision = 0

    var body: some View {
        settingsForm {
            Section {
                ForEach(RuntimeKind.allCases) { kind in
                    runtimeRow(kind)
                }
            } header: {
                HStack {
                    Text("支持的 CLI")
                    Spacer()
                    Button {
                        refreshAll()
                    } label: {
                        if isRefreshingAll {
                            Label("正在检测", systemImage: "hourglass")
                        } else {
                            Label("检测全部", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingAll || !refreshingKinds.isEmpty)
                    .accessibilityIdentifier("settings.runtimes.refresh-all")
                }
            }
            Section {
                Text("TodoAgent 会直接调用你本机已经安装并登录的 CLI。检测、登录和重新验证都由你主动触发；某一个 Runtime 不可用不会影响其他 Runtime。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section("状态集成") {
                ForEach(RuntimeKind.allCases) { kind in
                    statusAuthorizationRow(kind)
                }
                Text("Runner 的启动和退出始终由 0600 本机 Socket 监督。Provider Hook 仅在你授权后启用：Codex/Cursor 会安全合并用户级 hooks.json 并先备份，Claude 仅按 Session 注入临时 --settings；完整卸载只移除 TodoAgent 自己的条目。所有 Hook 都不读取终端输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .id(statusAuthorizationRevision)
    }

    private func runtimeRow(_ kind: RuntimeKind) -> some View {
        let info = state.runtime(kind)
        return HStack(alignment: .top, spacing: 12) {
            RuntimeIconView(kind: kind, fallbackSymbol: runtimeSymbol(kind))
                .frame(width: 28, height: 28)
                .foregroundStyle(statusColor(info?.status))
                .background(statusColor(info?.status).opacity(0.1), in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(kind.title)
                        .font(.body.weight(.medium))
                    Circle()
                        .fill(statusColor(info?.status))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(statusTitle(info))
                        .font(.caption)
                        .foregroundStyle(statusColor(info?.status))
                }
                if let version = info?.version, !version.isEmpty {
                    Text(version)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let path = info?.resolvedPath ?? info?.launchPath, !path.isEmpty {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                if let error = info?.verifyError, !error.isEmpty, info?.status != .ready {
                    Text(userFacingRuntimeError(error, status: info?.status))
                        .font(.caption)
                        .foregroundStyle(info?.status == .error ? .red : .secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            if refreshingKinds.contains(kind) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 4)
            } else {
                if info?.launchPath != nil,
                   info?.status == .authRequired || info?.status == .error {
                    Button("登录…") { openLogin(kind) }
                        .accessibilityIdentifier("settings.runtime.\(kind.rawValue).login")
                }
                Button(info == nil ? "检测" : "重新验证") {
                    verify(kind)
                }
                .accessibilityIdentifier("settings.runtime.\(kind.rawValue).verify")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private func statusAuthorizationRow(_ kind: RuntimeKind) -> some View {
        let authorization = TerminalStatusAuthorization.state(for: kind)
        let presentation = TerminalStatusAuthorization.presentation(for: kind)
        return HStack(alignment: .top, spacing: 12) {
            RuntimeIconView(kind: kind, fallbackSymbol: runtimeSymbol(kind))
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.title)
                Text(presentation.title)
                    .font(.caption)
                    .foregroundStyle(presentation.isHealthy ? .green : .secondary)
                Text(presentation.detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if presentation.canInstall {
                Button(authorization == .enabled ? "重新安装" : authorization == .skipped ? "启用" : "授权…") {
                    enableStatusIntegration(kind)
                }
            }
            if presentation.canUninstall {
                Button("完全卸载…", role: .destructive) {
                    confirmStatusUninstall(kind)
                }
            }
        }
    }

    private func enableStatusIntegration(_ kind: RuntimeKind) {
        do {
            try TerminalStatusAuthorization.enable(for: kind)
            actionMessage = kind == .codex
                ? "Codex Hook 已写入。请在 Codex 中打开 /hooks，检查并信任 TodoAgent Hook。"
                : "已启用 \(kind.title) 状态集成。"
        } catch {
            actionMessage = "无法启用 \(kind.title)：\(error.localizedDescription)"
        }
        statusAuthorizationRevision &+= 1
    }

    private func confirmStatusUninstall(_ kind: RuntimeKind) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "卸载 \(kind.title) 状态集成？"
        alert.informativeText = switch kind {
        case .codex, .cursor:
            "会先备份当前配置，再只删除 TodoAgent 安装的 Hook 和启动器；不会删除或恢复覆盖你后来修改的其他 Hook。"
        case .claude:
            "会撤销授权；之后启动的 Claude Session 不再注入 TodoAgent 临时 --settings。没有修改 ~/.claude/settings.json。"
        case .kiro:
            "会清除 TodoAgent 保存的跳过状态。Kiro 没有安装外部 Hook。"
        }
        alert.addButton(withTitle: "卸载")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try TerminalStatusAuthorization.uninstall(for: kind)
            actionMessage = "已完整卸载 \(kind.title) 状态集成。"
        } catch {
            actionMessage = "无法完整卸载 \(kind.title)：\(error.localizedDescription)"
        }
        statusAuthorizationRevision &+= 1
    }

    private func refreshAll() {
        guard !isRefreshingAll else { return }
        Task { await refreshAllRuntimes() }
    }

    private func refreshAllRuntimes() async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        actionMessage = nil
        defer { isRefreshingAll = false }

        guard await state.detectRuntimes() else {
            actionMessage = state.errorMessage ?? "无法检测本机 CLI。"
            return
        }
        for kind in RuntimeKind.allCases {
            refreshingKinds.insert(kind)
            _ = await state.verifyRuntime(kind)
            refreshingKinds.remove(kind)
        }
        actionMessage = "检测完成。可用的 Runtime 已经可以在任务 Session 中选择。"
    }

    private func verify(_ kind: RuntimeKind) {
        guard !refreshingKinds.contains(kind), !isRefreshingAll else { return }
        refreshingKinds.insert(kind)
        actionMessage = nil
        Task {
            let succeeded = await state.verifyRuntime(kind)
            refreshingKinds.remove(kind)
            actionMessage = succeeded
                ? "已更新 \(kind.title) 的安装、版本和登录状态。"
                : state.errorMessage ?? "无法验证 \(kind.title)。"
        }
    }

    private func openLogin(_ kind: RuntimeKind) {
        let command = loginCommand(kind)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        _ = NSWorkspace.shared.open(terminal)
        actionMessage = "已复制“\(command)”。请在终端中粘贴运行，登录完成后点“重新验证”。"
    }

    private func loginCommand(_ kind: RuntimeKind) -> String {
        switch kind {
        case .codex: "codex login"
        case .claude: "claude auth login"
        case .cursor: "cursor-agent login"
        case .kiro: "kiro-cli login"
        }
    }

    private func runtimeSymbol(_ kind: RuntimeKind) -> String {
        switch kind {
        case .codex: "c.square.fill"
        case .claude: "sparkle"
        case .cursor: "cursorarrow.rays"
        case .kiro: "terminal"
        }
    }

    private func statusTitle(_ info: RuntimeInfo?) -> String {
        guard let info else { return "尚未检测" }
        return switch info.status {
        case .ready: "可用"
        case .authRequired: "需要登录"
        case .detected: "等待验证"
        case .missing: "未安装"
        case .error: "验证失败"
        }
    }

    private func statusColor(_ status: RuntimeAvailability?) -> Color {
        switch status {
        case .ready: .green
        case .authRequired: .orange
        case .error: .red
        case .detected, .missing, nil: .secondary
        }
    }

    private func userFacingRuntimeError(_ error: String, status: RuntimeAvailability?) -> String {
        switch status {
        case .missing: "没有在常用安装目录中找到这个 CLI。安装后请重新检测。"
        case .authRequired: "CLI 已安装，但当前账户尚未登录。"
        default: error
        }
    }
}

/// Owns only the API-key editor's transient presentation state. The persisted
/// key is loaded lazily when the user reveals it and is discarded again when
/// hidden; revealing never turns the persisted value into an editable draft.
@MainActor
@Observable
final class GeminiAPIKeyEditorState {
    @ObservationIgnored private let loadSavedKey: @MainActor () throws -> String?

    private(set) var draftKey: String
    private(set) var isRevealed = false
    private var revealedSavedKey: String?

    init(
        draftKey: String = "",
        loadSavedKey: @escaping @MainActor () throws -> String? = {
            try CredentialStore.loadGeminiKey()
        }
    ) {
        self.draftKey = draftKey
        self.loadSavedKey = loadSavedKey
    }

    var fieldText: String {
        if !draftKey.isEmpty { return draftKey }
        return isRevealed ? revealedSavedKey ?? "" : ""
    }

    var hasDraftKey: Bool {
        !draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var visibilitySystemImage: String {
        isRevealed ? "eye" : "eye.slash"
    }

    func updateFieldText(_ value: String) {
        draftKey = value
        // Once the user edits, the field represents a replacement draft. Do
        // not fall back to the persisted key if the draft becomes empty.
        revealedSavedKey = nil
    }

    func toggleVisibility() throws {
        if isRevealed {
            hide()
            return
        }
        if draftKey.isEmpty {
            revealedSavedKey = try loadSavedKey()
        }
        isRevealed = true
    }

    func hide() {
        isRevealed = false
        revealedSavedKey = nil
    }

    func clearDraftAndHide() {
        draftKey = ""
        hide()
    }
}

private struct ModelSettingsPane: View {
    @State private var model: String
    @State private var savedModel: String
    @State private var keyEditor = GeminiAPIKeyEditorState()
    @State private var hasSavedKey = false
    @State private var connectionState = GeminiConnectionState.idle
    @State private var operationTask: Task<Void, Never>?
    @FocusState private var apiKeyFocused: Bool

    init() {
        let defaultModel = "gemini-3.6-flash"
        let rawModel = UserDefaults.standard.string(forKey: "geminiModel") ?? defaultModel
        let normalizedStoredModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedModel = normalizedStoredModel.isEmpty ? defaultModel : normalizedStoredModel
        if rawModel != storedModel {
            UserDefaults.standard.set(storedModel, forKey: "geminiModel")
        }
        _model = State(initialValue: storedModel)
        _savedModel = State(initialValue: storedModel)
    }

    private var normalizedKey: String {
        keyEditor.draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedModel: String {
        model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canTest: Bool {
        !connectionState.isTesting && !normalizedModel.isEmpty && (!normalizedKey.isEmpty || hasSavedKey)
    }

    private var hasUnsavedChanges: Bool {
        !normalizedKey.isEmpty || normalizedModel != savedModel
    }

    private var canSave: Bool {
        !connectionState.isTesting && !normalizedModel.isEmpty && hasUnsavedChanges
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsForm {
                Section("Gemini") {
                    TextField("模型", text: $model)
                        .textFieldStyle(.plain)
                    HStack(spacing: 8) {
                        apiKeyField

                        Button(action: toggleKeyVisibility) {
                            Image(systemName: keyEditor.visibilitySystemImage)
                                .frame(width: 24, height: 24)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(keyEditor.isRevealed ? "隐藏 API Key" : "显示 API Key")
                        .help(keyEditor.isRevealed ? "隐藏 API Key" : "显示 API Key")
                        .accessibilityIdentifier("settings.gemini.api-key-visibility")
                    }
                    Text("API Key 保存到当前 macOS 账户的 Application Support/TodoAgent/credentials.json，目录权限 0700、文件权限 0600；不会写入数据库、环境变量或日志。这是权限隔离的普通文件，不是加密钥匙串；同一登录账户下的其他进程仍可能读取，建议启用 FileVault。测试连接只读取模型信息，不会生成内容或消耗模型 Token。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    HStack(spacing: 8) {
                        Button {
                            testConnection()
                        } label: {
                            if connectionState.isTesting {
                                Label("正在测试", systemImage: "hourglass")
                            } else {
                                Label("测试连接", systemImage: "bolt.horizontal.circle")
                            }
                        }
                        .disabled(!canTest)
                        Button("移除", role: .destructive) { remove() }
                            .disabled(!hasSavedKey || connectionState.isTesting)
                    }

                    HStack(spacing: 7) {
                        if connectionState.isTesting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: connectionState.symbol)
                                .foregroundStyle(connectionState.color)
                        }
                        Text(connectionState.message(hasSavedKey: hasSavedKey))
                            .font(.caption)
                            .foregroundStyle(connectionState.color)
                            .textSelection(.enabled)
                    }
                }
            }

            Divider()
            HStack {
                if hasUnsavedChanges {
                    Text("有未保存的修改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .task {
            do {
                hasSavedKey = try CredentialStore.hasGeminiKey()
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
        .onChange(of: keyEditor.draftKey) { _, _ in invalidateConnectionAfterEditing() }
        .onChange(of: model) { _, _ in invalidateConnectionAfterEditing() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            keyEditor.hide()
        }
        .onDisappear {
            operationTask?.cancel()
            keyEditor.hide()
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        let prompt = Text(hasSavedKey ? "••••••••••••" : "输入 Gemini API Key")
        if keyEditor.isRevealed {
            TextField("API Key", text: apiKeyText, prompt: prompt)
                .textFieldStyle(.plain)
                .focused($apiKeyFocused)
                .privacySensitive()
                .accessibilityLabel("Gemini API Key")
                .accessibilityIdentifier("settings.gemini.api-key-field")
        } else {
            SecureField("API Key", text: apiKeyText, prompt: prompt)
                .textFieldStyle(.plain)
                .focused($apiKeyFocused)
                .privacySensitive()
                .accessibilityLabel("Gemini API Key")
                .accessibilityIdentifier("settings.gemini.api-key-field")
        }
    }

    private var apiKeyText: Binding<String> {
        Binding(
            get: { keyEditor.fieldText },
            set: { keyEditor.updateFieldText($0) }
        )
    }

    private func toggleKeyVisibility() {
        let restoreFocus = apiKeyFocused
        do {
            try keyEditor.toggleVisibility()
            if keyEditor.isRevealed, keyEditor.fieldText.isEmpty, hasSavedKey {
                // The file may have been removed outside TodoAgent since this
                // pane loaded. Keep the visible state honest without treating
                // the reveal as an edit.
                hasSavedKey = false
            }
        } catch {
            connectionState = .failed(error.localizedDescription)
            return
        }
        guard restoreFocus else { return }
        Task { @MainActor in
            await Task.yield()
            apiKeyFocused = true
        }
    }

    private func invalidateConnectionAfterEditing() {
        guard hasUnsavedChanges else {
            if connectionState == .edited {
                connectionState = hasSavedKey ? .saved : .idle
            }
            return
        }
        operationTask?.cancel()
        operationTask = nil
        connectionState = .edited
    }

    private func save() {
        let key = normalizedKey
        let selectedModel = normalizedModel
        guard !selectedModel.isEmpty else {
            connectionState = .failed("模型不能为空。")
            return
        }
        do {
            if !key.isEmpty {
                try CredentialStore.saveGeminiKey(key)
                hasSavedKey = true
                keyEditor.clearDraftAndHide()
            } else {
                keyEditor.hide()
            }
            UserDefaults.standard.set(selectedModel, forKey: "geminiModel")
            model = selectedModel
            savedModel = selectedModel
            connectionState = hasSavedKey ? .saved : .idle
            operationTask?.cancel()
            guard !key.isEmpty else { return }
            operationTask = Task {
                do {
                    try await AppContainer.shared.state.injectGeminiKey(key)
                    try Task.checkCancellation()
                } catch is CancellationError {
                    return
                } catch {
                    connectionState = .savedEngineSyncFailed(error.localizedDescription)
                }
            }
        } catch { connectionState = .failed(error.localizedDescription) }
    }

    private func remove() {
        do {
            _ = try CredentialStore.deleteGeminiKey()
            hasSavedKey = false
            keyEditor.clearDraftAndHide()
            connectionState = .removed
            operationTask?.cancel()
            operationTask = Task {
                do { try await AppContainer.shared.state.clearGeminiKey() }
                catch is CancellationError { return }
                catch { connectionState = .failed(error.localizedDescription) }
            }
        } catch { connectionState = .failed(error.localizedDescription) }
    }

    private func testConnection() {
        operationTask?.cancel()
        let inputKey = normalizedKey
        let selectedModel = normalizedModel
        operationTask = Task {
            connectionState = .testing
            do {
                let key: String
                if !inputKey.isEmpty {
                    key = inputKey
                } else if let saved = try CredentialStore.loadGeminiKey(), !saved.isEmpty {
                    key = saved
                } else {
                    connectionState = .failed("请先输入或保存 Gemini API Key。")
                    return
                }
                try await AppContainer.shared.state.injectGeminiKey(key)
                try Task.checkCancellation()
                let result = try await AppContainer.shared.state.testGeminiConnection(model: selectedModel)
                try Task.checkCancellation()
                connectionState = .connected(result.displayName, result.version)
            } catch is CancellationError {
                return
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
        }
    }
}

private enum GeminiConnectionState: Equatable {
    case idle
    case edited
    case saved
    case savedEngineSyncFailed(String)
    case testing
    case connected(String, String)
    case failed(String)
    case removed

    var isTesting: Bool { self == .testing }

    var symbol: String {
        switch self {
        case .connected: "checkmark.circle.fill"
        case .failed, .savedEngineSyncFailed:
            "exclamationmark.triangle.fill"
        case .edited: "pencil.circle"
        case .saved: "externaldrive.fill"
        case .removed: "trash"
        case .idle, .testing: "circle.dotted"
        }
    }

    var color: Color {
        switch self {
        case .connected: .green
        case .failed: .red
        case .edited, .savedEngineSyncFailed: .orange
        default: .secondary
        }
    }

    func message(hasSavedKey: Bool) -> String {
        switch self {
        case .idle: hasSavedKey ? "已保存，尚未测试连接" : "尚未配置"
        case .edited: "有未保存的修改"
        case .saved: "已保存，建议测试连接"
        case let .savedEngineSyncFailed(message):
            "已保存到本机，但 Engine 同步失败：\(message)"
        case .testing: "正在验证 API Key 与模型…"
        case let .connected(name, version):
            version.isEmpty ? "连接成功 · \(name)" : "连接成功 · \(name) · \(version)"
        case let .failed(message): message
        case .removed: "已从本地凭据文件和 Engine 内存移除"
        }
    }
}

private struct AboutSettingsPane: View {
    var body: some View {
        settingsForm {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "checklist.checked")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)
                        .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("TodoAgent").font(.largeTitle.bold())
                        Text("0.1.0 Preview (1)").foregroundStyle(.secondary)
                        Text("一个会自己完成任务的待办清单。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("架构") {
                LabeledContent("界面", value: "SwiftUI + AppKit")
                LabeledContent("Engine", value: "Rust sidecar · IPC v4")
                LabeledContent("系统", value: "macOS 26+")
            }
        }
    }
}

@MainActor
private func settingsForm<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    Form(content: content)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
