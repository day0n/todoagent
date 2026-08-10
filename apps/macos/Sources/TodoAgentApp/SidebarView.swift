import SwiftUI

struct SidebarView: View {
    let state: AppState
    @State private var isPresentingNewList = false
    @State private var newListName = ""
    @State private var isCreatingList = false

    var body: some View {
        @Bindable var state = state

        VStack(spacing: 0) {
            SidebarCalendar(selectedDate: $state.selectedDate)

            Divider()

            List(selection: $state.selection) {
                Section {
                    navigationRow(.timeline, state: state)
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
                        .tag(SidebarSelection.list(list.id))
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
        .navigationTitle("TodoAgent")
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

private struct SidebarCalendar: View {
    @Binding var selectedDate: Date
    @State private var visibleMonth = Date.now
    @FocusState private var focusedDate: Date?

    private static let calendar: Calendar = {
        var value = Calendar.todoAgentLocal
        value.locale = Locale(identifier: "zh_CN")
        value.firstWeekday = 2
        return value
    }()

    private static let accessibilityDateStyle = Date.FormatStyle(locale: Locale(identifier: "zh_CN"))
        .year()
        .month()
        .day()
        .weekday()

    private let weekdayTitles = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: TodoAgentUI.standardSpacing) {
            HStack(spacing: 6) {
                Text(monthTitle)
                    .font(.title3)
                    .bold()
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)

                Spacer(minLength: 8)

                calendarButton(
                    "chevron.left",
                    label: "上个月",
                    identifier: "calendar.previous"
                ) {
                    changeMonth(by: -1)
                }

                Button {
                    let today = Self.calendar.startOfDay(for: .now)
                    selectedDate = today
                    visibleMonth = today
                    focusedDate = today
                } label: {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 10, height: 10)
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("回到今天")
                .accessibilityLabel("回到今天")
                .accessibilityIdentifier("calendar.today")

                calendarButton(
                    "chevron.right",
                    label: "下个月",
                    identifier: "calendar.next"
                ) {
                    changeMonth(by: 1)
                }
            }

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(weekdayTitles, id: \.self) { title in
                    Text(title)
                        .font(.caption)
                        .bold()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 20)
                        .accessibilityHidden(true)
                }

                ForEach(days) { day in
                    Button {
                        selectedDate = day.date
                        focusedDate = day.date
                        if !day.isInVisibleMonth {
                            visibleMonth = day.date
                        }
                    } label: {
                        Text(day.number)
                            .font(.callout.monospacedDigit())
                            .bold(day.isSelected)
                            .foregroundStyle(dayTextColor(day))
                            .frame(maxWidth: .infinity, minHeight: 29)
                            .background {
                                if day.isSelected {
                                    Circle().fill(Color.accentColor)
                                } else if day.isToday {
                                    Circle().stroke(Color.accentColor, lineWidth: 1)
                                }
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .focused($focusedDate, equals: day.date)
                    .onMoveCommand(perform: moveSelection)
                    .accessibilityLabel(day.accessibilityLabel)
                    .accessibilityValue(accessibilityValue(for: day))
                    .accessibilityHint("使用方向键移动日期")
                    .accessibilityAddTraits(day.isSelected ? .isSelected : [])
                    .accessibilityIdentifier(day.identifier)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("日期选择")
        }
        .padding(.horizontal, TodoAgentUI.sectionSpacing)
        .padding(.top, TodoAgentUI.standardSpacing)
        .padding(.bottom, TodoAgentUI.standardSpacing)
        .frame(maxWidth: .infinity)
        .onAppear {
            visibleMonth = selectedDate
            focusedDate = selectedDate
        }
        .onChange(of: selectedDate) { _, newValue in
            guard !Self.calendar.isDate(newValue, equalTo: visibleMonth, toGranularity: .month) else { return }
            visibleMonth = newValue
        }
    }

    private var monthTitle: String {
        let components = Self.calendar.dateComponents([.year, .month], from: visibleMonth)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }

    private var days: [SidebarCalendarDay] {
        let calendar = Self.calendar
        guard let monthStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: visibleMonth)
        ) else { return [] }

        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart) else {
            return []
        }

        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return SidebarCalendarDay(
                date: date,
                number: String(calendar.component(.day, from: date)),
                isInVisibleMonth: calendar.isDate(date, equalTo: visibleMonth, toGranularity: .month),
                isSelected: calendar.isDate(date, inSameDayAs: selectedDate),
                isToday: calendar.isDateInToday(date),
                accessibilityLabel: date.formatted(Self.accessibilityDateStyle),
                identifier: dayIdentifier(for: date, calendar: calendar)
            )
        }
    }

    private func dayTextColor(_ day: SidebarCalendarDay) -> Color {
        if day.isSelected { return .white }
        if !day.isInVisibleMonth { return .secondary.opacity(0.45) }
        return .primary
    }

    private func changeMonth(by value: Int) {
        if let date = Self.calendar.date(byAdding: .month, value: value, to: visibleMonth) {
            visibleMonth = date
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let dayOffset: Int
        switch direction {
        case .left: dayOffset = -1
        case .right: dayOffset = 1
        case .up: dayOffset = -7
        case .down: dayOffset = 7
        @unknown default: return
        }

        let origin = focusedDate ?? selectedDate
        guard let target = Self.calendar.date(byAdding: .day, value: dayOffset, to: origin) else { return }
        selectedDate = target
        visibleMonth = target
        focusedDate = target
    }

    private func calendarButton(
        _ symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func accessibilityValue(for day: SidebarCalendarDay) -> String {
        switch (day.isSelected, day.isToday) {
        case (true, true): "已选择，今天"
        case (true, false): "已选择"
        case (false, true): "今天"
        case (false, false): ""
        }
    }

    private func dayIdentifier(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "calendar.day.%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private struct SidebarCalendarDay: Identifiable {
    let date: Date
    let number: String
    let isInVisibleMonth: Bool
    let isSelected: Bool
    let isToday: Bool
    let accessibilityLabel: String
    let identifier: String

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}
