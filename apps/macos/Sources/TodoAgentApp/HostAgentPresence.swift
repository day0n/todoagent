import Darwin
import Foundation

/// Identifies which local CLI is actually running in a task host shell, by
/// asking the kernel what the PTY's foreground process is.
///
/// Opening a task creates a host PTY whose stored `runtimeKind` defaults to
/// Claude. That default is not evidence the user launched Claude, so it must
/// never drive the runtime shown in the UI.
///
/// An earlier version matched substrings in the PTY title and OSC desktop
/// notification text. That reads attacker- and user-controlled content: a task
/// titled "学习 claude code 源码" reaches the terminal title and was detected as
/// Claude even while the shell sat idle. Only the executable path and, for
/// script hosts, the script path are consulted here.
enum HostAgentRuntimeProbe {
    /// Interpreters that are never the Agent themselves. For these the script
    /// path decides, which is how npm-installed CLIs appear.
    private static let scriptHosts: Set<String> = [
        "node", "node.exe", "bun", "deno", "python", "python3", "ruby", "perl",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "env",
    ]

    /// Ordered longest-marker-first so `cursor-agent` is never classified as a
    /// bare `cursor`.
    private static let markers: [(marker: String, kind: RuntimeKind)] = [
        ("cursor-agent", .cursor),
        ("claude-code", .claude),
        ("claude", .claude),
        ("codex", .codex),
        ("cursor", .cursor),
        ("kiro", .kiro),
    ]

    static func detect(
        pid: pid_t,
        executablePath: (pid_t) -> String? = HostAgentRuntimeProbe.executablePath(of:),
        arguments: (pid_t) -> [String]? = HostAgentRuntimeProbe.arguments(of:)
    ) -> RuntimeKind? {
        guard pid > 0, let path = executablePath(pid) else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()

        if scriptHosts.contains(name) == false {
            return kind(forExecutableName: name)
        }

        // A script host tells us nothing on its own. Only absolute paths in its
        // argument vector are inspected, so a plain `vim claude-notes.md` or a
        // prompt mentioning an Agent cannot be mistaken for the Agent running.
        guard let argumentVector = arguments(pid) else { return nil }
        for argument in argumentVector.dropFirst() where argument.hasPrefix("/") {
            if let kind = kind(forScriptPath: argument) { return kind }
        }
        return nil
    }

    /// The executable's own name must match a marker exactly, so an unrelated
    /// binary that merely contains "claude" in its name is not claimed.
    private static func kind(forExecutableName name: String) -> RuntimeKind? {
        markers.first { $0.marker == name }?.kind
    }

    /// A script path matches on whole path components, e.g.
    /// `…/@anthropic-ai/claude-code/cli.js`. Substring matching on the full
    /// path would let a directory such as `~/dev/claude-notes` decide.
    private static func kind(forScriptPath path: String) -> RuntimeKind? {
        let components = path.lowercased().split(separator: "/").map(String.init)
        for (marker, kind) in markers {
            if components.contains(where: { component in
                component == marker || component.hasPrefix(marker + ".")
            }) {
                return kind
            }
        }
        return nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        // Returns `strlen` of the path it wrote, so the count excludes the NUL.
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, Int(length) <= buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Reads the argument vector via `KERN_PROCARGS2`. The layout is a 32-bit
    /// argc, the NUL-padded exec path, then argc NUL-separated arguments.
    static func arguments(of pid: pid_t) -> [String]? {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }

        let count = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard count > 0 else { return nil }

        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        var current: [UInt8] = []
        while index < size, arguments.count < count {
            if buffer[index] == 0 {
                arguments.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return arguments
    }
}
