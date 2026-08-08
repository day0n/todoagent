import AppKit
import SwiftUI

struct TaskConversationSheet: View {
    let task: TaskItem
    let state: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var isSubmitting = false

    var body: some View {
        Group {
            if let session = state.conversation(for: task) {
                conversation(session)
            } else {
                TaskSessionSetupView(task: task, state: state)
            }
        }
        .frame(minWidth: 900, idealWidth: 980, minHeight: 620, idealHeight: 700)
        .accessibilityIdentifier("task.session.\(task.id.uuidString)")
    }

    private func conversation(_ session: TaskConversationSnapshot) -> some View {
        VStack(spacing: 0) {
            header(session)
            Divider()
            sessionMetadata(session)
            Divider()
            transcript(session)
            Divider()
            composer(session)
        }
    }

    private func header(_ session: TaskConversationSnapshot) -> some View {
        HStack(spacing: TodoAgentUI.standardSpacing) {
            Image(systemName: "terminal.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.1), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.title2)
                    .bold()
                    .lineLimit(1)
                Text("\(session.runtime) 本地会话")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            TaskConversationStatus(status: task.status)

            Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("关闭会话")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, TodoAgentUI.sectionSpacing)
    }

    private func sessionMetadata(_ session: TaskConversationSnapshot) -> some View {
        HStack(spacing: 20) {
            Label(session.runtime, systemImage: "cpu")
            Label(session.workspace, systemImage: "folder")
            Label(session.sessionID, systemImage: "number")
                .fontDesign(.monospaced)
            Spacer()
            Label("本机直连", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.runtime) 本地会话，工作目录 \(session.workspace)，Session \(session.sessionID)"
        )
    }

    private func transcript(_ session: TaskConversationSnapshot) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: TodoAgentUI.sectionSpacing) {
                    ForEach(session.entries) { entry in
                        TaskConversationEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.24))
            .onChange(of: session.entries.count) {
                guard let lastID = session.entries.last?.id else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    private func composer(_ session: TaskConversationSnapshot) -> some View {
        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            Label(
                task.status == .needsYou
                    ? "\(session.runtime) 有一条新消息"
                    : "随时向这个本地 Session 继续发送消息",
                systemImage: task.status == .needsYou ? "circle.fill" : "arrow.triangle.2.circlepath"
            )
            .font(.callout)
            .foregroundStyle(task.status == .needsYou ? Color.red : Color.secondary)

            HStack(alignment: .bottom, spacing: TodoAgentUI.standardSpacing) {
                TextField("发送消息给 \(session.runtime)…", text: $draft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .accessibilityIdentifier("task.session.composer")

                Button("发送", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSubmitting
                    )
                    .accessibilityIdentifier("task.session.send")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private func submit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isSubmitting else { return }
        isSubmitting = true

        Task {
            if await state.sendToSession(task, text: value) {
                draft = ""
            }
            isSubmitting = false
        }
    }
}

private struct TaskSessionSetupView: View {
    let task: TaskItem
    let state: AppState

    @Environment(\.dismiss) private var dismiss
    @State private var runtime = "Codex"
    @State private var workspace = ""
    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.title2.bold())
                    Text("创建本地 Agent Session")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", systemImage: "xmark", action: dismiss.callAsFunction)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(24)

            Divider()

            VStack(alignment: .leading, spacing: 24) {
                Label("选择由哪个本地 Agent 执行，以及它可以操作的目录。启动后会直接进入完整聊天记录。", systemImage: "terminal")
                    .font(.headline)

                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
                    GridRow {
                        Text("Runtime")
                            .foregroundStyle(.secondary)
                        Picker("Runtime", selection: $runtime) {
                            Text("Codex").tag("Codex")
                            Text("Claude Code").tag("Claude Code")
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .accessibilityIdentifier("task.session.runtime")
                    }

                    GridRow(alignment: .top) {
                        Text("执行目录")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("选择一个文件夹", text: $workspace)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("task.session.workspace")
                                Button("选择…", action: chooseDirectory)
                                    .accessibilityIdentifier("task.session.choose-workspace")
                            }
                            Text("Agent 将以这个目录作为工作目录，并在其中读取或修改文件。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 520)
                    }
                }

                Spacer()

                HStack {
                    Label("启动后，任务卡只作为这个 Session 的入口。", systemImage: "link")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("启动并进入 Session") {
                        start()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isStarting)
                    .accessibilityIdentifier("task.session.start")
                }
            }
            .padding(32)
            .frame(maxWidth: 760, maxHeight: .infinity)
        }
        .onAppear {
            if workspace.isEmpty { workspace = state.suggestedWorkspace(for: task) }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.title = "选择 Agent 执行目录"
        if panel.runModal() == .OK, let url = panel.url {
            workspace = url.path(percentEncoded: false)
        }
    }

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            _ = await state.startSession(task, runtime: runtime, workspace: workspace)
            isStarting = false
        }
    }
}

private struct TaskConversationStatus: View {
    let status: TaskStatus

    var body: some View {
        Text(status.title)
            .font(.caption)
            .bold()
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.1), in: .capsule)
    }

    private var color: Color {
        switch status {
        case .todo, .done: .secondary
        case .running: .blue
        case .needsYou: .orange
        case .review: .green
        }
    }
}

private struct TaskConversationEntryRow: View {
    let entry: TaskConversationEntry

    var body: some View {
        switch entry.role {
        case .system:
            systemEntry
        case .tool:
            toolEntry
        case .agent, .user:
            messageEntry
        }
    }

    private var systemEntry: some View {
        Label(entry.body, systemImage: "link")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor), in: .capsule)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("系统：\(entry.body)")
    }

    private var toolEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(entry.title ?? "工具调用", systemImage: "terminal")
                .font(.callout)
                .bold()
                .foregroundStyle(.secondary)
            Text(entry.body)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TodoAgentUI.cardPadding)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: TodoAgentUI.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.cardRadius)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("工具调用，\(entry.title ?? "")：\(entry.body)")
    }

    private var messageEntry: some View {
        HStack(alignment: .top) {
            if entry.role == .user { Spacer(minLength: 120) }

            VStack(alignment: .leading, spacing: TodoAgentUI.compactSpacing) {
                if let title = entry.title {
                    Text(title)
                        .font(.callout)
                        .bold()
                }
                Text(entry.body)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .foregroundStyle(entry.role == .user ? Color.white : Color.primary)
            .background(
                entry.role == .user ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
                in: .rect(cornerRadius: TodoAgentUI.panelRadius)
            )

            if entry.role == .agent { Spacer(minLength: 120) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.role == .user ? "你" : "CLI")：\(entry.body)")
    }
}
