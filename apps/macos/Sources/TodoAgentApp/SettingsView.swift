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
        case .runtimes: RuntimeSettingsPane()
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
    @AppStorage("confirmDirtyRepositories") private var confirmDirtyRepositories = true
    @AppStorage("showInspectorAtLaunch") private var showInspectorAtLaunch = true

    var body: some View {
        settingsForm {
            Section("工作区") {
                Toggle("在脏工作区执行前二次确认", isOn: $confirmDirtyRepositories)
                Text("TodoAgent 不会自动提交、合并或清理你的改动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("窗口") {
                Toggle("启动时显示 TodoAgent", isOn: $showInspectorAtLaunch)
            }
        }
    }
}

private struct RuntimeSettingsPane: View {
    var body: some View {
        settingsForm {
            Section("支持的 CLI") {
                runtimeRow(name: "Codex", symbol: "c.square.fill")
                runtimeRow(name: "Claude Code", symbol: "sparkle")
                runtimeRow(name: "Cursor Agent", symbol: "cursorarrow.rays")
                runtimeRow(name: "Kiro CLI", symbol: "terminal")
            }
            Section {
                Text("可用性由 Rust Engine 启动时真实检测；未安装或未登录的 Runtime 不会影响其他 Runtime。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func runtimeRow(name: String, symbol: String) -> some View {
        LabeledContent {
            Label("启动时检测", systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
        } label: {
            Label(name, systemImage: symbol)
        }
    }
}

private struct ModelSettingsPane: View {
    @AppStorage("geminiModel") private var model = "gemini-3.6-flash"
    @State private var apiKey = ""
    @State private var status = ""

    var body: some View {
        settingsForm {
            Section("Gemini") {
                TextField("模型", text: $model)
                SecureField("API Key", text: $apiKey)
                Text("API Key 只会保存到 macOS Keychain，不写入数据库、环境变量或日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("保存到钥匙串") { save() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("移除", role: .destructive) { remove() }
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task {
            status = ((try? KeychainStore.loadGeminiKey()) ?? nil) == nil ? "尚未配置" : "已保存"
        }
    }

    private func save() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.saveGeminiKey(key)
            Task {
                do { try await AppContainer.shared.state.injectGeminiKey(key); status = "已保存并注入 Engine"; apiKey = "" }
                catch { status = error.localizedDescription }
            }
        } catch { status = error.localizedDescription }
    }

    private func remove() {
        do { try KeychainStore.deleteGeminiKey(); status = "已移除"; apiKey = "" }
        catch { status = error.localizedDescription }
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
                LabeledContent("Engine", value: "Rust sidecar · IPC v2")
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
