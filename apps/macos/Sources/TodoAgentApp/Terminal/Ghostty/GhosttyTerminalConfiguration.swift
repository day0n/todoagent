import Foundation

/// Immutable inputs used to create one Ghostty PTY surface.
///
/// `command` is Ghostty's command string. It is built only from the Engine's
/// verified runner executable and descriptor argv, with POSIX shell quoting.
struct GhosttyTerminalConfiguration: Sendable, Equatable {
    let command: String
    let workingDirectory: String
    let environment: [String: String]
    let fontSize: Float?
    let waitAfterCommand: Bool

    init(
        command: String,
        workingDirectory: String,
        environment: [String: String] = [:],
        fontSize: Float? = nil,
        waitAfterCommand: Bool = false
    ) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.fontSize = fontSize
        self.waitAfterCommand = waitAfterCommand
    }
}

enum TerminalWorkingDirectoryPolicy {
    static func isAvailable(
        _ path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard NSString(string: path).isAbsolutePath else { return false }
        let storedURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: storedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        // Engine launch validation deliberately rejects a stored cwd whose
        // final path component is a symlink. Keep the workbench availability
        // state and the last pre-Surface check on exactly the same policy so a
        // resume button can never lead only to an Engine/runner rejection.
        return storedURL.resolvingSymlinksInPath().standardizedFileURL.path == storedURL.path
    }
}

enum GhosttyLaunchPlanValidator {
    static func validateWorkingDirectory(_ path: String) throws {
        guard NSString(string: path).isAbsolutePath else {
            throw GhosttyTerminalError.invalidLaunchPlan
        }
        guard TerminalWorkingDirectoryPolicy.isAvailable(path) else {
            throw GhosttyTerminalError.workingDirectoryUnavailable(path)
        }
    }
}

enum GhosttyCommandBuilder {
    static func command(executable: String, arguments: [String]) throws -> String {
        guard executable.hasPrefix("/"),
              URL(fileURLWithPath: executable).lastPathComponent == "todoagent-terminal-runner",
              arguments.count == 2,
              arguments[0] == "--descriptor",
              arguments[1].hasPrefix("/"),
              !executable.contains("\0"),
              !arguments.contains(where: { $0.contains("\0") })
        else { throw GhosttyTerminalError.invalidLaunchPlan }
        return ([executable] + arguments).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum GhosttyTerminalError: LocalizedError, Equatable {
    case resourcesMissing
    case initializationFailed
    case configurationFailed
    case appCreationFailed
    case invalidLaunchPlan
    case workingDirectoryUnavailable(String)
    case surfaceCreationFailed

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            "Ghostty runtime resources are missing. Run ./scripts/setup-ghostty.sh."
        case .initializationFailed:
            "Ghostty initialization failed."
        case .configurationFailed:
            "Ghostty configuration could not be created."
        case .appCreationFailed:
            "Ghostty application state could not be created."
        case .invalidLaunchPlan:
            "The terminal launch plan is invalid."
        case let .workingDirectoryUnavailable(path):
            "原工作目录已被移动或删除：\(path)"
        case .surfaceCreationFailed:
            "Ghostty could not create a terminal surface."
        }
    }
}
