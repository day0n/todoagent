import AppKit
import Darwin
import SwiftUI

extension Notification.Name {
    static let todoAgentNewTask = Notification.Name("TodoAgent.newTask")
    static let todoAgentNewAssistantConversation = Notification.Name("TodoAgent.newAssistantConversation")
    static let todoAgentToggleInspector = Notification.Name("TodoAgent.toggleInspector")
}

@main
struct TodoAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        guard CommandLine.arguments.dropFirst() == ["--verify-packaged-resources"] else { return }
        do {
            guard GhosttyBundledResources.resolve() != nil else {
                throw GhosttyTerminalError.resourcesMissing
            }
            _ = try GhosttyRuntime.shared.requireApp()
            FileHandle.standardOutput.write(Data("TodoAgent packaged Ghostty resources OK\n".utf8))
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(
                Data("TodoAgent packaged resource verification failed: \(error.localizedDescription)\n".utf8)
            )
            Darwin.exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        Window("TodoAgent", id: TodoAgentMainWindow.sceneID) {
            ContentView(
                state: AppContainer.shared.state,
                taskWorkspace: AppContainer.shared.taskWorkspace
            )
                .frame(
                    minWidth: TodoAgentMainWindowPlacement.minimumContentSize.width,
                    minHeight: TodoAgentMainWindowPlacement.minimumContentSize.height
                )
                .background(TodoAgentMainWindowMarker())
        }
        .defaultSize(
            width: TodoAgentMainWindowPlacement.preferredContentSize.width,
            height: TodoAgentMainWindowPlacement.preferredContentSize.height
        )
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { SettingsWindowController.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("任务") {
                Button("新建任务") {
                    NotificationCenter.default.post(name: .todoAgentNewTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("新建 TodoAgent 对话") {
                    NotificationCenter.default.post(
                        name: .todoAgentNewAssistantConversation,
                        object: nil
                    )
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("显示或隐藏 TodoAgent") {
                    NotificationCenter.default.post(name: .todoAgentToggleInspector, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Button("收起任务工作区") {
                    AppContainer.shared.taskWorkspace.collapseActiveWorkspace()
                }
                .keyboardShortcut("[", modifiers: .command)

            }

            CommandMenu("终端") {
                Button("聚焦终端") {
                    AppContainer.shared.taskWorkspace.focusActiveTerminal()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("查找…") { NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: NSFindPanelAction.showFindPanel.rawValue) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("复制") { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("粘贴") { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: .command)

                Divider()

                Button("放大字体") { AppContainer.shared.taskWorkspace.performTerminalAction("increase_font_size:1") }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小字体") { AppContainer.shared.taskWorkspace.performTerminalAction("decrease_font_size:1") }
                    .keyboardShortcut("-", modifiers: .command)
                Button("还原字体大小") { AppContainer.shared.taskWorkspace.performTerminalAction("reset_font_size") }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        MenuBarExtra("TodoAgent 今日任务", systemImage: "checklist") {
            TodayMenuBarView(state: AppContainer.shared.state)
        }
        .menuBarExtraStyle(.window)
    }
}
