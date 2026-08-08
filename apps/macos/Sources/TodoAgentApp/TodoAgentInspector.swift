import SwiftUI

struct TodoAgentInspector: View {
    let state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TodoAgentUI.standardSpacing) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(.blue.opacity(0.1), in: .circle)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TodoAgent").font(.title3.bold())
                    Text("Gemini 助手").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("设置", systemImage: "gearshape") { SettingsWindowController.show(tab: .model) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(TodoAgentUI.sectionSpacing)
            Divider()

            ContentUnavailableView {
                Label("配置 Gemini 后开始", systemImage: "key")
            } description: {
                Text("TodoAgent 助手与任务 Session 相互独立。API Key 只保存在 macOS 钥匙串中；未配置时不影响四个本地 Runtime。")
            } actions: {
                Button("打开 TodoAgent 设置") { SettingsWindowController.show(tab: .model) }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        }
        .accessibilityIdentifier("todoagent.inspector")
    }
}
