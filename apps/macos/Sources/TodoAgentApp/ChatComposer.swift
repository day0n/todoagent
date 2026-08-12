import SwiftUI

struct ChatComposer<AboveContent: View, AccessoryContent: View>: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let placeholder: String
    let isRunning: Bool
    let canSubmit: Bool
    let accessibilityPrefix: String
    let onSubmit: () -> Void
    let onStop: () -> Void
    @ViewBuilder let aboveContent: AboveContent
    @ViewBuilder let accessories: AccessoryContent

    init(
        text: Binding<String>,
        focus: FocusState<Bool>.Binding,
        placeholder: String,
        isRunning: Bool,
        canSubmit: Bool,
        accessibilityPrefix: String,
        onSubmit: @escaping () -> Void,
        onStop: @escaping () -> Void,
        @ViewBuilder aboveContent: () -> AboveContent,
        @ViewBuilder accessories: () -> AccessoryContent
    ) {
        _text = text
        self.focus = focus
        self.placeholder = placeholder
        self.isRunning = isRunning
        self.canSubmit = canSubmit
        self.accessibilityPrefix = accessibilityPrefix
        self.onSubmit = onSubmit
        self.onStop = onStop
        self.aboveContent = aboveContent()
        self.accessories = accessories()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            aboveContent

            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(2 ... 6)
                .textFieldStyle(.plain)
                .focused(focus)
                .onSubmit(onSubmit)
                .accessibilityIdentifier("\(accessibilityPrefix).composer")

            HStack(alignment: .center, spacing: 8) {
                accessories
                Spacer(minLength: 0)
                if isRunning {
                    Button("停止本轮", systemImage: "stop.fill", role: .destructive, action: onStop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(ChatComposerCircleButtonStyle(isEnabled: true))
                        .help("停止本轮")
                        .accessibilityIdentifier("\(accessibilityPrefix).stop")
                } else {
                    Button("发送", systemImage: "arrow.up", action: onSubmit)
                        .labelStyle(.iconOnly)
                        .buttonStyle(ChatComposerCircleButtonStyle(isEnabled: canSubmit))
                        .disabled(!canSubmit)
                        .help("发送")
                        .accessibilityIdentifier("\(accessibilityPrefix).send")
                }
            }
        }
        .padding(13)
        .todoAgentGlassSurface(cornerRadius: TodoAgentUI.composerRadius, elevated: true)
        .overlay {
            RoundedRectangle(cornerRadius: TodoAgentUI.composerRadius)
                .stroke(
                    focus.wrappedValue ? Color.accentColor : TodoAgentUI.hairline,
                    lineWidth: focus.wrappedValue ? 1.5 : 1
                )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(TodoAgentUI.canvasBackground)
    }
}

struct ChatComposerUtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(TodoAgentUI.secondaryText)
            .frame(width: 28, height: 28)
            .background(
                configuration.isPressed ? TodoAgentUI.selectionBackground : .clear,
                in: .circle
            )
            .contentShape(.circle)
    }
}

private struct ChatComposerCircleButtonStyle: ButtonStyle {
    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(
                isEnabled
                    ? Color.black.opacity(configuration.isPressed ? 0.72 : 1)
                    : Color.black.opacity(0.16),
                in: .circle
            )
            .contentShape(.circle)
    }
}
