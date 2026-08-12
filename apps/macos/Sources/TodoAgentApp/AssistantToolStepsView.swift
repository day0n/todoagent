import SwiftUI

struct AssistantToolStepPresentation: Equatable, Sendable {
    let title: String
    let technicalName: String
    let systemImage: String
    let state: AssistantToolState

    init(tool: AssistantToolActivity) {
        technicalName = tool.name
        state = tool.state
        systemImage = switch tool.state {
        case .running: "circle"
        case .completed: "circle.fill"
        case .failed: "exclamationmark.circle"
        }

        let action = Self.action(for: tool.name)
        title = switch tool.state {
        case .running: action.running
        case .completed: action.completed
        case .failed: action.failed
        }
    }

    private static func action(for name: String) -> (running: String, completed: String, failed: String) {
        switch name {
        case "create_tasks":
            ("正在创建任务", "已创建任务", "创建任务时遇到问题")
        case "find_related":
            ("正在查找相关任务", "已检查相关任务", "查找相关任务时遇到问题")
        case "update_task":
            ("正在更新任务", "已更新任务", "更新任务时遇到问题")
        case "delete_task":
            ("正在删除任务", "已删除任务", "删除任务时遇到问题")
        case "list_state":
            ("正在读取任务", "已读取任务", "读取任务时遇到问题")
        case "list_lists":
            ("正在读取清单", "已读取清单", "读取清单时遇到问题")
        default:
            ("正在调用工具", "已完成工具调用", "工具调用时遇到问题")
        }
    }
}

struct AssistantToolGroupPresentation: Equatable, Sendable {
    let title: String
    let accessibilityValue: String

    init(group: AssistantToolGroup) {
        let failedCount = group.tools.count(where: { $0.state == .failed })
        if group.isRunning {
            title = "正在处理 · \(group.tools.count) 个步骤"
            accessibilityValue = "正在处理"
        } else if failedCount > 0 {
            title = "\(group.tools.count) 个步骤 · \(failedCount) 项未完成"
            accessibilityValue = "有失败步骤"
        } else {
            title = "\(group.tools.count) 个步骤"
            accessibilityValue = "已完成"
        }
    }
}

struct AssistantToolGroupDisclosureState: Equatable, Sendable {
    private(set) var manuallyExpanded = false
    private(set) var expandedToolIDs: Set<String> = []

    func isExpanded(isRunning: Bool) -> Bool {
        isRunning || manuallyExpanded
    }

    mutating func toggleGroup(isRunning: Bool) {
        guard !isRunning else { return }
        manuallyExpanded.toggle()
        if !manuallyExpanded {
            expandedToolIDs.removeAll()
        }
    }

    mutating func toggleTool(_ toolID: String) {
        if expandedToolIDs.contains(toolID) {
            expandedToolIDs.remove(toolID)
        } else {
            expandedToolIDs.insert(toolID)
        }
    }

    mutating func finishRunningGroup() {
        manuallyExpanded = false
        expandedToolIDs.removeAll()
    }
}

struct AssistantErrorPresentation: Equatable, Sendable {
    let title: String
    let guidance: String
    let technicalDetails: String?

    init(rawMessage: String) {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if normalized.contains("network")
            || normalized.contains("error sending request")
            || normalized.contains("无法连接")
            || normalized.contains("网络")
        {
            title = "连接 Gemini 时遇到网络问题"
            guidance = "请检查网络或代理设置，然后重试。"
            technicalDetails = trimmed.isEmpty ? nil : trimmed
        } else if normalized.contains("timed out")
            || normalized.contains("timeout")
            || normalized.contains("超时")
        {
            title = "Gemini 响应超时"
            guidance = "网络恢复后可以重新发送这条消息。"
            technicalDetails = trimmed.isEmpty ? nil : trimmed
        } else if normalized.contains("api key")
            || normalized.contains("unauthorized")
            || normalized.contains("401")
            || normalized.contains("403")
        {
            title = "Gemini 配置需要检查"
            guidance = "请在设置中确认 API Key 与模型配置。"
            technicalDetails = trimmed.isEmpty ? nil : trimmed
        } else if normalized.contains("cancel") || normalized.contains("停止") {
            title = "本轮已停止"
            guidance = "你可以修改内容后重新发送。"
            technicalDetails = nil
        } else if normalized.contains("limit") || normalized.contains("上限") {
            title = "本轮已达到处理上限"
            guidance = "请缩小任务范围后重新发送。"
            technicalDetails = trimmed.isEmpty ? nil : trimmed
        } else {
            title = "这一步没有完成"
            guidance = Self.isTechnical(trimmed) ? "请稍后重试。" : (trimmed.isEmpty ? "请稍后重试。" : trimmed)
            technicalDetails = Self.isTechnical(trimmed) && !trimmed.isEmpty ? trimmed : nil
        }
    }

    private static func isTechnical(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return normalized.contains("http://")
            || normalized.contains("https://")
            || normalized.contains("provider")
            || normalized.contains("error:")
            || normalized.contains("request")
            || normalized.contains("json")
    }
}

enum AssistantScrollIndicatorPolicy {
    static let coverWidth: CGFloat = 16
    static let hoverZoneWidth: CGFloat = 30

    static func showsIndicators(pointerNearIndicator: Bool) -> Bool {
        pointerNearIndicator
    }

    static func coverOpacity(pointerNearIndicator: Bool) -> Double {
        pointerNearIndicator ? 0 : 0.97
    }
}

struct AssistantToolStepsView: View {
    let group: AssistantToolGroup
    let state: AppState

    @State private var disclosure = AssistantToolGroupDisclosureState()

    private var presentation: AssistantToolGroupPresentation {
        AssistantToolGroupPresentation(group: group)
    }

    private var isExpanded: Bool {
        disclosure.isExpanded(isRunning: group.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                disclosure.toggleGroup(isRunning: group.isRunning)
            } label: {
                HStack(spacing: 7) {
                    if group.isRunning {
                        AssistantWaveText(text: presentation.title)
                    } else {
                        Text(presentation.title)
                            .foregroundStyle(group.hasFailure ? Color.orange : TodoAgentUI.secondaryText)
                    }
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TodoAgentUI.secondaryText)
                    Spacer(minLength: 0)
                }
                .font(.callout.weight(.medium))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("工具调用，\(presentation.title)")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityIdentifier("assistant.tool-group.\(group.turnID)")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.tools) { tool in
                        AssistantToolStepRow(
                            tool: tool,
                            state: state,
                            isExpanded: disclosure.expandedToolIDs.contains(tool.id),
                            toggle: { toggle(tool.id) }
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .onChange(of: group.isRunning) { wasRunning, isRunning in
            if wasRunning, !isRunning {
                disclosure.finishRunningGroup()
            }
        }
    }

    private func toggle(_ toolID: String) {
        disclosure.toggleTool(toolID)
    }
}

private struct AssistantToolStepRow: View {
    let tool: AssistantToolActivity
    let state: AppState
    let isExpanded: Bool
    let toggle: () -> Void

    private var presentation: AssistantToolStepPresentation {
        AssistantToolStepPresentation(tool: tool)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(stepColor)
                    .frame(width: 14, height: 18)
                Rectangle()
                    .fill(TodoAgentUI.hairline)
                    .frame(width: 1)
                    .frame(minHeight: isExpanded ? 55 : 20)
            }
            .accessibilityHidden(true)

            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        if tool.state == .running {
                            AssistantWaveText(text: presentation.title)
                        } else {
                            Text(presentation.title)
                                .foregroundStyle(stepColor)
                        }
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TodoAgentUI.secondaryText)
                        Spacer(minLength: 0)
                    }
                    .font(.callout)

                    if isExpanded {
                        AssistantToolTechnicalDetails(tool: tool, state: state)
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(presentation.title)，工具 \(tool.name)")
            .accessibilityValue(isExpanded ? "技术详情已展开" : "技术详情已折叠")
            .accessibilityIdentifier("assistant.tool-step.\(tool.id)")
        }
    }

    private var stepColor: Color {
        switch tool.state {
        case .running: TodoAgentUI.secondaryText
        case .completed: TodoAgentUI.secondaryText
        case .failed: .orange
        }
    }
}

private struct AssistantToolTechnicalDetails: View {
    let tool: AssistantToolActivity
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            LabeledContent("工具") {
                Text(tool.name).fontDesign(.monospaced)
            }
            LabeledContent("调用 ID") {
                Text(tool.toolCallID)
                    .fontDesign(.monospaced)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("状态") {
                Text(stateTitle)
            }

            if !tool.taskReferences.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(tool.taskReferences, id: \.self) { taskID in
                        AssistantToolTaskReferenceButton(taskID: taskID, state: state)
                    }
                }
                .padding(.top, 2)
            }
        }
        .font(.caption2)
        .foregroundStyle(TodoAgentUI.secondaryText)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TodoAgentUI.selectionBackground.opacity(0.56), in: .rect(cornerRadius: 8))
        .textSelection(.enabled)
    }

    private var stateTitle: String {
        switch tool.state {
        case .running: "进行中"
        case .completed: "已完成"
        case .failed: "未完成"
        }
    }
}

private struct AssistantToolTaskReferenceButton: View {
    let taskID: UUID
    let state: AppState

    var body: some View {
        if let task = state.task(id: taskID) {
            Button {
                state.openTask(task)
            } label: {
                Label(task.title, systemImage: "checklist")
                    .font(.caption2)
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct AssistantFriendlyErrorView: View {
    let rawMessage: String
    var dismiss: (() -> Void)?

    @State private var detailsExpanded = false

    private var presentation: AssistantErrorPresentation {
        AssistantErrorPresentation(rawMessage: rawMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.title)
                        .font(.caption.weight(.semibold))
                    Text(presentation.guidance)
                        .font(.caption)
                        .foregroundStyle(TodoAgentUI.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let dismiss {
                    Button("关闭", systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }

            if let technicalDetails = presentation.technicalDetails {
                DisclosureGroup("技术详情", isExpanded: $detailsExpanded) {
                    Text(technicalDetails)
                        .font(.caption2.monospaced())
                        .foregroundStyle(TodoAgentUI.secondaryText)
                        .textSelection(.enabled)
                        .padding(.top, 5)
                }
                .font(.caption2)
                .foregroundStyle(TodoAgentUI.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.orange.opacity(0.065), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.orange.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

struct AssistantWaveText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Text(text)
                .foregroundStyle(TodoAgentUI.secondaryText)
        } else {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.8) / 1.8
                Text(text)
                    .foregroundStyle(TodoAgentUI.secondaryText.opacity(0.34))
                    .overlay {
                        GeometryReader { proxy in
                            LinearGradient(
                                colors: [
                                    .clear,
                                    TodoAgentUI.primaryText.opacity(0.30),
                                    TodoAgentUI.primaryText.opacity(0.94),
                                    TodoAgentUI.primaryText.opacity(0.30),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: max(70, proxy.size.width * 0.75))
                            .offset(
                                x: -max(70, proxy.size.width * 0.75)
                                    + (proxy.size.width + max(70, proxy.size.width * 0.75)) * phase
                            )
                        }
                        .mask(Text(text))
                    }
            }
            .accessibilityLabel(text)
        }
    }
}
