// Adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit

@MainActor
final class GhosttyTerminalSurfaceFactory: TerminalSurfaceFactory {
    func makeSurface(configuration plan: TerminalLaunchPlan) throws -> any TerminalSurfaceSession {
        try GhosttyLaunchPlanValidator.validateWorkingDirectory(plan.workingDirectory)
        let command = try GhosttyCommandBuilder.command(
            executable: plan.executable,
            arguments: plan.arguments
        )
        let configuration = GhosttyTerminalConfiguration(
            command: command,
            workingDirectory: plan.workingDirectory,
            environment: GhosttyTerminalEnvironment.launchEnvironment(base: plan.environment)
        )
        return try GhosttyTerminalSession(configuration: configuration)
    }

    func makeHostSurface(
        workingDirectory: String,
        environment: [String: String]
    ) throws -> any TerminalSurfaceSession {
        let home = TerminalHostDefaults.workingDirectory
        let initialDirectory = TerminalWorkingDirectoryPolicy.isAvailable(home) ? home : workingDirectory
        try GhosttyLaunchPlanValidator.validateWorkingDirectory(initialDirectory)
        let configuration = GhosttyTerminalConfiguration(
            command: try GhosttyCommandBuilder.hostShellCommand(),
            workingDirectory: initialDirectory,
            environment: GhosttyTerminalEnvironment.launchEnvironment(base: environment)
        )
        return try GhosttyTerminalSession(configuration: configuration)
    }
}

@MainActor
final class GhosttyTerminalSession: TerminalSurfaceSession {
    let surfaceView: GhosttySurfaceView
    var onEvent: (@MainActor (TerminalSurfaceEvent) -> Void)?

    var view: NSView { surfaceView }

    init(configuration: GhosttyTerminalConfiguration) throws {
        let app = try GhosttyRuntime.shared.requireApp()
        surfaceView = GhosttySurfaceView(app: app, configuration: configuration)
        surfaceView.onEvent = { [weak self] event in self?.onEvent?(event) }
    }

    func focus() {
        guard let window = surfaceView.window else { return }
        window.makeFirstResponder(surfaceView)
        surfaceView.updateGhosttyFocus()
    }

    func commitComposition() {
        surfaceView.commitComposition()
    }

    func terminate() {
        surfaceView.terminate()
    }

    func close() {
        surfaceView.close()
    }

    func performAction(_ action: String) {
        surfaceView.performBinding(action)
    }

    func sendText(_ text: String) {
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        surfaceView.insertPasted(payload)
    }
}
