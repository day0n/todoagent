import AppKit
import SwiftUI

/// Shared visual constants for the native preview.
///
/// Keeping these values in one place makes the three-pane interface feel like
/// one product and lets future design passes adjust density consistently.
enum TodoAgentUI {
    static let sidebarIdealWidth: CGFloat = 260
    static let sidebarMaximumWidth: CGFloat = 320
    static let inspectorIdealWidth: CGFloat = 440

    // A quiet, warm-neutral palette keeps the calendar, board, and assistant
    // visually related while still adapting cleanly to dark appearances.
    static let canvasBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.984, green: 0.984, blue: 0.976, alpha: 1),
        dark: NSColor(srgbRed: 0.118, green: 0.118, blue: 0.114, alpha: 1)
    )
    static let sidebarBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.969, green: 0.969, blue: 0.961, alpha: 1),
        dark: NSColor(srgbRed: 0.145, green: 0.145, blue: 0.137, alpha: 1)
    )
    static let surfaceBackground = adaptiveColor(
        light: NSColor(srgbRed: 1, green: 1, blue: 0.996, alpha: 1),
        dark: NSColor(srgbRed: 0.180, green: 0.180, blue: 0.169, alpha: 1)
    )
    static let selectionBackground = adaptiveColor(
        light: NSColor(srgbRed: 0.937, green: 0.933, blue: 0.922, alpha: 1),
        dark: NSColor(srgbRed: 0.231, green: 0.231, blue: 0.216, alpha: 1)
    )
    static let primaryText = adaptiveColor(
        light: NSColor(srgbRed: 0.216, green: 0.208, blue: 0.184, alpha: 1),
        dark: NSColor(srgbRed: 0.941, green: 0.941, blue: 0.925, alpha: 1)
    )
    static let secondaryText = adaptiveColor(
        light: NSColor(srgbRed: 0.471, green: 0.467, blue: 0.455, alpha: 1),
        dark: NSColor(srgbRed: 0.678, green: 0.678, blue: 0.651, alpha: 1)
    )
    static let hairline = adaptiveColor(
        light: NSColor(srgbRed: 0.906, green: 0.906, blue: 0.894, alpha: 1),
        dark: NSColor(srgbRed: 0.286, green: 0.286, blue: 0.271, alpha: 1)
    )
    static let shadowColor = adaptiveColor(
        light: NSColor(white: 0, alpha: 0.10),
        dark: NSColor(white: 0, alpha: 0.28)
    )

    static let boardPadding: CGFloat = 14
    static let boardSpacing: CGFloat = 12
    static let columnMinimumWidth: CGFloat = 270
    static let columnMaximumWidth: CGFloat = 340

    static let panelRadius: CGFloat = 14
    static let cardRadius: CGFloat = 11
    static let cardPadding: CGFloat = 14
    static let compactSpacing: CGFloat = 6
    static let standardSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 14

    static let sidebarFooterGradientHeight: CGFloat = 64
    static let sidebarNavigationTopSpacing: CGFloat = 8
    static let floatingButtonSize: CGFloat = 46
    static let composerRadius: CGFloat = 16

    static let glassHighlight = adaptiveColor(
        light: NSColor(white: 1, alpha: 0.72),
        dark: NSColor(white: 1, alpha: 0.12)
    )

    static let glassShadow = adaptiveColor(
        light: NSColor(white: 0, alpha: 0.12),
        dark: NSColor(white: 0, alpha: 0.34)
    )

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            }
        )
    }
}

extension View {
    /// A restrained native material surface for compact floating controls.
    /// Keep this away from dense task lists so their hierarchy stays quiet.
    func todoAgentGlassSurface(
        cornerRadius: CGFloat,
        elevated: Bool = false
    ) -> some View {
        modifier(
            TodoAgentGlassSurfaceModifier(
                cornerRadius: cornerRadius,
                elevated: elevated
            )
        )
    }
}

private struct TodoAgentGlassSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [TodoAgentUI.glassHighlight, TodoAgentUI.hairline],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(
                color: TodoAgentUI.glassShadow.opacity(elevated ? 1 : 0.45),
                radius: elevated ? 16 : 7,
                y: elevated ? 7 : 2
            )
    }
}

struct TodoAgentWeekStripPresentation: Equatable, Sendable {
    let days: [LocalDay]

    init(selectedDay: LocalDay, calendar: Calendar = .todoAgentLocal) {
        guard let selectedDate = selectedDay.date(in: calendar) else {
            days = [selectedDay]
            return
        }

        let weekday = calendar.component(.weekday, from: selectedDate)
        let daysSinceMonday = (weekday + 5) % 7
        let monday = selectedDay.advanced(by: -daysSinceMonday, calendar: calendar) ?? selectedDay
        days = (0 ..< 7).compactMap { monday.advanced(by: $0, calendar: calendar) }
    }
}

struct TodoAgentWeekStrip: View {
    @Binding var selection: LocalDay
    let today: LocalDay

    private var presentation: TodoAgentWeekStripPresentation {
        TodoAgentWeekStripPresentation(selectedDay: selection)
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(presentation.days, id: \.self) { day in
                Button {
                    selection = day
                } label: {
                    VStack(spacing: 4) {
                        Text(weekdayLabel(for: day))
                            .font(.caption2.weight(.medium))
                        Text("\(day.day)")
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                    .foregroundStyle(day == selection ? Color.white : TodoAgentUI.primaryText)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(
                        day == selection ? Color.accentColor : Color.clear,
                        in: .rect(cornerRadius: 10)
                    )
                    .overlay {
                        if day == today, day != selection {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor.opacity(0.7), lineWidth: 1)
                        }
                    }
                    .contentShape(.rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: day))
                .accessibilityValue(day == selection ? "已选择" : "")
            }
        }
        .padding(5)
        .background(TodoAgentUI.selectionBackground.opacity(0.55), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("本周日期")
    }

    private func weekdayLabel(for day: LocalDay) -> String {
        day.date(in: .todoAgentLocal)?.formatted(.dateTime.weekday(.narrow)) ?? ""
    }

    private func accessibilityLabel(for day: LocalDay) -> String {
        day.date(in: .todoAgentLocal)?.formatted(.dateTime.year().month().day().weekday(.wide))
            ?? day.rawValue
    }
}

struct TodoAgentDatePickerPanel: View {
    let title: String
    let initialDay: LocalDay
    let today: LocalDay
    let onCancel: () -> Void
    let onApply: (LocalDay) -> Void

    @State private var selection: LocalDay

    init(
        title: String,
        initialDay: LocalDay,
        today: LocalDay,
        onCancel: @escaping () -> Void,
        onApply: @escaping (LocalDay) -> Void
    ) {
        self.title = title
        self.initialDay = initialDay
        self.today = today
        self.onCancel = onCancel
        self.onApply = onApply
        _selection = State(initialValue: initialDay)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TodoAgentUI.standardSpacing) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(selectionLabel)
                        .font(.caption)
                        .foregroundStyle(TodoAgentUI.secondaryText)
                }
                Spacer()
                Button("回到今天") { selection = today }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(selection == today)
            }

            TodoAgentWeekStrip(selection: $selection, today: today)

            DatePicker(
                title,
                selection: dateBinding,
                displayedComponents: .date
            )
            .labelsHidden()
            .datePickerStyle(.graphical)

            HStack {
                Spacer()
                Button("取消", role: .cancel, action: onCancel)
                Button("应用") { onApply(selection) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(TodoAgentUI.sectionSpacing)
        .frame(width: 334)
        .environment(\.calendar, Calendar.todoAgentLocal)
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: { selection.date(in: .todoAgentLocal) ?? .now },
            set: { selection = LocalDay($0, calendar: .todoAgentLocal) }
        )
    }

    private var selectionLabel: String {
        selection.date(in: .todoAgentLocal)?.formatted(.dateTime.month().day().weekday(.wide))
            ?? selection.rawValue
    }
}

struct TodoAgentCompactSwitchStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(
                            configuration.isOn
                                ? Color.accentColor
                                : TodoAgentUI.selectionBackground
                        )
                    Circle()
                        .fill(configuration.isOn ? Color.white : TodoAgentUI.secondaryText.opacity(0.72))
                        .padding(3)
                        .shadow(color: TodoAgentUI.shadowColor.opacity(0.45), radius: 2, y: 1)
                }
                .frame(width: 38, height: 22)
                .overlay {
                    Capsule().stroke(TodoAgentUI.hairline, lineWidth: configuration.isOn ? 0 : 1)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: configuration.isOn)
    }
}
