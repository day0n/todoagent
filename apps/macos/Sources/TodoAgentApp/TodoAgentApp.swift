import AppKit
import SwiftUI

extension Notification.Name {
    static let todoAgentNewTask = Notification.Name("TodoAgent.newTask")
    static let todoAgentNewAssistantConversation = Notification.Name("TodoAgent.newAssistantConversation")
    static let todoAgentToggleInspector = Notification.Name("TodoAgent.toggleInspector")
    static let todoAgentCancelCurrent = Notification.Name("TodoAgent.cancelCurrent")
}

@main
struct TodoAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: TodoAgentMainWindow.sceneID) {
            ContentView(state: AppContainer.shared.state)
                .frame(minWidth: 980, minHeight: 680)
                .background(TodoAgentMainWindowMarker())
        }
        .defaultSize(width: 1380, height: 860)
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

                Divider()

                Button("取消当前操作") {
                    NotificationCenter.default.post(name: .todoAgentCancelCurrent, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        MenuBarExtra("TodoAgent 今日任务", systemImage: "checklist") {
            TodayMenuBarView(state: AppContainer.shared.state)
        }
        .menuBarExtraStyle(.window)
    }
}
