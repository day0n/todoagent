import SwiftUI

struct TodoAgentInspector: View {
    let state: AppState
    @State private var draft = ""
    @FocusState private var composerFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        let messages = state.messages
        let needsYouCount = state.contextCount(for: .needsYou)
        let reviewCount = state.contextCount(for: .review)
        let runningCount = state.contextCount(for: .running)

        VStack(spacing: 0) {
            HStack(spacing: TodoAgentUI.standardSpacing) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 36, height: 36)
                    .background(.blue.opacity(0.1), in: .circle)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TodoAgent")
                        .font(.title3)
                        .bold()
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("演示会话")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button("新建会话") {}
                        .disabled(true)
                        .help("多会话将在 Engine 接入后开放")
                    Button("会话记录") {}
                        .disabled(true)
                        .help("会话历史将在 Engine 接入后开放")
                    Divider()
                    Button("设置…") { SettingsWindowController.show(tab: .model) }
                } label: {
                    Label("会话操作", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("todoagent.sessionMenu")
            }
            .padding(TodoAgentUI.sectionSpacing)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: TodoAgentUI.sectionSpacing) {
                        ContextSummary(
                            needsYouCount: needsYouCount,
                            reviewCount: reviewCount,
                            runningCount: runningCount
                        )

                        ForEach(messages) { message in
                            let referencedTask = message.taskReference.flatMap { state.task(id: $0) }
                            ChatBubble(
                                message: message,
                                task: referencedTask,
                                openSession: { taskID in
                                    if let task = state.task(id: taskID) {
                                        state.openTask(task)
                                    }
                                }
                            )
                                .id(message.id)
                        }
                    }
                    .padding(TodoAgentUI.sectionSpacing)
                }
                .accessibilityIdentifier("todoagent.messages")
                .onChange(of: messages.count) {
                    if let id = messages.last?.id {
                        if accessibilityReduceMotion {
                            proxy.scrollTo(id, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(spacing: TodoAgentUI.standardSpacing) {
                HStack(alignment: .bottom, spacing: TodoAgentUI.standardSpacing) {
                    Button("添加附件", systemImage: "paperclip") {}
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .disabled(true)
                        .help("真实 Engine 接入后支持图片")
                        .accessibilityLabel("添加附件")
                        .accessibilityHint("当前预览版本暂不可用")
                        .accessibilityIdentifier("todoagent.attachment")

                    TextField("告诉 TodoAgent…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .onSubmit(send)
                        .accessibilityLabel("给 TodoAgent 的消息")
                        .accessibilityIdentifier("todoagent.composer")

                    Button("发送消息", systemImage: "arrow.up.circle.fill", action: send)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .buttonStyle(.plain)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("发送消息")
                        .accessibilityIdentifier("todoagent.send")
                }
                .padding(TodoAgentUI.standardSpacing)
                .background(.background.secondary, in: .rect(cornerRadius: TodoAgentUI.panelRadius))
            }
            .padding(TodoAgentUI.sectionSpacing)
            .background(.ultraThinMaterial)
        }
    }

    private func send() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        draft = ""
        Task { await state.sendChat(value) }
    }
}

private struct ContextSummary: View {
    let needsYouCount: Int
    let reviewCount: Int
    let runningCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            Label("上下文", systemImage: "scope")
                .font(.callout)
                .bold()
                .foregroundStyle(.secondary)

            HStack(spacing: TodoAgentUI.compactSpacing) {
                ContextMetric(value: needsYouCount, label: "需要你", color: .orange)
                ContextMetric(value: reviewCount, label: "待确认", color: .purple)
                ContextMetric(value: runningCount, label: "执行中", color: .blue)
            }
        }
        .padding(TodoAgentUI.standardSpacing)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "当前上下文：需要你 \(needsYouCount) 项，待确认 \(reviewCount) 项，执行中 \(runningCount) 项"
        )
        .accessibilityIdentifier("todoagent.contextSummary")
    }
}

private struct ContextMetric: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.title3.monospacedDigit())
                .bold()
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let task: TaskItem?
    let openSession: (UUID) -> Void

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            Text(message.body)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                .background(
                    message.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                    in: .rect(cornerRadius: TodoAgentUI.panelRadius)
                )
                .accessibilityLabel("\(roleName)：\(message.body)")
                .accessibilityIdentifier("todoagent.message.\(message.id.uuidString)")

            if let task {
                Button {
                    openSession(task.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checklist")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title)
                                .lineLimit(1)
                            Text(task.status.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(TodoAgentUI.standardSpacing)
                    .background(.background, in: .rect(cornerRadius: TodoAgentUI.cardRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                .help("进入任务 Session")
                .accessibilityLabel("关联任务：\(task.title)，状态：\(task.status.title)")
                .accessibilityHint("进入这个任务的本地 Agent Session")
                .accessibilityIdentifier("todoagent.message.\(message.id.uuidString).task")
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    private var roleName: String {
        switch message.role {
        case .user: "你"
        case .todoAgent: "TodoAgent"
        }
    }
}
