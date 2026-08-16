import SwiftUI

struct SidebarView: View {
    let state: AppState
    @State private var isPresentingNewList = false
    @State private var newListName = ""
    @State private var isCreatingList = false
    @State private var listBeingRenamed: TodoList?
    @State private var renameListName = ""
    @State private var listBeingDeleted: TodoList?
    @State private var isMutatingList = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            SidebarTodayHeader(day: state.currentDay)

            Divider()

            List(selection: $state.selection) {
                Section {
                    navigationRow(.myDay, state: state)
                    navigationRow(.tasks, state: state)
                }

                Section("清单") {
                    ForEach(state.lists) { list in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(color(named: list.colorName))
                                .frame(width: 9, height: 9)
                                .accessibilityHidden(true)
                            Text(list.name)
                            Spacer()
                            let count = state.activeCount(forList: list.id)
                            if count > 0 { countBadge(count) }
                        }
                        .padding(.vertical, 2)
                        .contentShape(.rect)
                        .tag(SidebarSelection.list(list.id))
                        .contextMenu {
                            Button {
                                renameListName = list.name
                                listBeingRenamed = list
                            } label: {
                                Label("重命名清单…", systemImage: "pencil")
                            }
                            .accessibilityIdentifier("sidebar.list.rename")

                            Divider()

                            Button(role: .destructive) {
                                listBeingDeleted = list
                            } label: {
                                Label("删除清单", systemImage: "trash")
                            }
                            .accessibilityIdentifier("sidebar.list.delete")
                        }
                        .disabled(isMutatingList)
                        .accessibilityIdentifier("sidebar.list.\(list.id.uuidString)")
                    }

                    Button {
                        newListName = ""
                        isPresentingNewList = true
                    } label: {
                        Label("新建清单", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isCreatingList)
                    .help("新建清单")
                    .accessibilityIdentifier("sidebar.new-list")
                }

                Section("状态") {
                    navigationRow(.running, state: state)
                    navigationRow(.done, state: state)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(TodoAgentUI.sidebarBackground)
            .padding(.top, TodoAgentUI.sidebarNavigationTopSpacing)
        }
        .background(TodoAgentUI.sidebarBackground)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
        .alert("新建清单", isPresented: $isPresentingNewList) {
            TextField("清单名称", text: $newListName)
            Button("取消", role: .cancel) {}
            Button("创建") {
                let name = newListName
                isCreatingList = true
                Task { @MainActor in
                    _ = await state.createList(name: name)
                    isCreatingList = false
                }
            }
            .disabled(newListName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("创建后会自动进入这个清单。")
        }
        .alert("重命名清单", isPresented: isPresentingRenameList) {
            TextField("清单名称", text: $renameListName)
            Button("取消", role: .cancel) {}
            Button("重命名") {
                guard let list = listBeingRenamed else { return }
                let name = renameListName
                isMutatingList = true
                Task { @MainActor in
                    _ = await state.renameList(listID: list.id, name: name)
                    isMutatingList = false
                }
            }
            .disabled(normalizedRenameListName.isEmpty || normalizedRenameListName.unicodeScalars.count > 200)
        } message: {
            Text("清单中的任务不会改变。")
        }
        .alert("删除清单？", isPresented: isPresentingDeleteList) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let list = listBeingDeleted else { return }
                isMutatingList = true
                Task { @MainActor in
                    _ = await state.deleteList(listID: list.id)
                    isMutatingList = false
                }
            }
        } message: {
            Text("只会删除清单；其中任务仍会保留在“任务”中。")
        }
    }

    private var normalizedRenameListName: String {
        renameListName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isPresentingRenameList: Binding<Bool> {
        Binding(
            get: { listBeingRenamed != nil },
            set: { presented in
                if !presented { listBeingRenamed = nil }
            }
        )
    }

    private var isPresentingDeleteList: Binding<Bool> {
        Binding(
            get: { listBeingDeleted != nil },
            set: { presented in
                if !presented { listBeingDeleted = nil }
            }
        )
    }

    private var sidebarFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text("本机模式")
                .font(.caption)
            Spacer()
            Button { SettingsWindowController.show() } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("设置 ⌘,")
            .accessibilityLabel("打开设置")
            .accessibilityIdentifier("sidebar.settings")
        }
        .foregroundStyle(TodoAgentUI.secondaryText)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(minHeight: TodoAgentUI.sidebarFooterGradientHeight, alignment: .bottom)
        .background {
            LinearGradient(
                colors: [
                    TodoAgentUI.surfaceBackground.opacity(0),
                    TodoAgentUI.surfaceBackground.opacity(0.88),
                    TodoAgentUI.surfaceBackground,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        }
    }

    private func navigationRow(_ view: SmartView, state: AppState) -> some View {
        Label {
            HStack {
                Text(view.title)
                Spacer()
                let count = state.count(for: view)
                if count > 0 { countBadge(count) }
            }
        } icon: {
            Image(systemName: view.symbol)
        }
        .padding(.vertical, 2)
        .tag(SidebarSelection.smart(view))
        .accessibilityIdentifier("sidebar.smart.\(view.rawValue)")
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func color(named name: String) -> Color {
        switch name {
        case "orange": .orange
        case "purple": .purple
        case "green": .green
        default: .blue
        }
    }
}

private struct SidebarTodayHeader: View {
    let day: LocalDay

    private static let weekdayStyle = Date.FormatStyle(
        locale: Locale(identifier: "zh_CN")
    )
    .weekday(.wide)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(day.month)月\(day.day)日")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)

            Text(weekdayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, TodoAgentUI.sectionSpacing)
        .padding(.vertical, TodoAgentUI.standardSpacing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("sidebar.today-header")
    }

    private var weekdayTitle: String {
        day.date(in: .todoAgentLocal)?.formatted(Self.weekdayStyle) ?? ""
    }

    private var accessibilityLabel: String {
        "\(day.year)年\(day.month)月\(day.day)日，\(weekdayTitle)"
    }
}
