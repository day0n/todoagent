import Darwin
import Foundation

enum ProviderStatusHookCapability: Equatable, Sendable {
    case globalUserConfiguration
    case runScopedSettings
    case unsupported
}

enum ProviderStatusHookHealth: Equatable, Sendable {
    case notInstalled
    case installed
    case installedRequiresProviderReview
    case runScoped
    case unsupported
    case needsRepair(String)
}

struct ProviderStatusHookInspection: Equatable, Sendable {
    let capability: ProviderStatusHookCapability
    let health: ProviderStatusHookHealth
    let configurationPath: String?
}

enum ProviderStatusHookError: LocalizedError, Equatable {
    case unsupportedRuntime(RuntimeKind)
    case runnerNotFound
    case pathMustBeAbsolute
    case symbolicLink(String)
    case invalidFileType(String)
    case wrongOwner(String)
    case multipleHardLinks(String)
    case fileTooLarge(String)
    case malformedConfiguration(String)
    case unsupportedConfigurationVersion(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case let .unsupportedRuntime(runtime):
            "\(runtime.title) 目前没有可安全安装的状态 Hook。"
        case .runnerNotFound:
            "找不到 TodoAgent 随附的 Terminal Runner，请重新安装或从完整 App Bundle 启动。"
        case .pathMustBeAbsolute:
            "状态 Hook 路径必须是绝对路径。"
        case let .symbolicLink(path):
            "为避免修改符号链接目标，已拒绝访问：\(path)"
        case let .invalidFileType(path):
            "状态 Hook 配置不是普通文件或目录：\(path)"
        case let .wrongOwner(path):
            "状态 Hook 配置不属于当前 macOS 账户：\(path)"
        case let .multipleHardLinks(path):
            "状态 Hook 配置存在多个硬链接，已拒绝修改：\(path)"
        case let .fileTooLarge(path):
            "状态 Hook 配置过大，已拒绝修改：\(path)"
        case let .malformedConfiguration(path):
            "无法安全合并现有 Hook 配置，请先修复 JSON：\(path)"
        case let .unsupportedConfigurationVersion(path):
            "现有 Hook 配置版本不受支持，未做任何修改：\(path)"
        case let .systemCall(operation, code):
            "\(operation)失败（errno \(code)）。"
        }
    }
}

/// Installs only user-scoped, provider-supported status hooks. Every provider
/// event is forwarded to the bundled runner over stdin. Outside a TodoAgent
/// run the required authenticated socket environment is absent, so the runner
/// exits successfully without sending anything.
///
/// Existing JSON is merged structurally and backed up before every mutation.
/// Uninstall removes handlers that invoke TodoAgent's stable, account-private
/// wrapper and preserves all unrelated keys, hook groups, and handlers.
struct ProviderStatusHookManager: Sendable {
    static let maximumConfigurationBytes = 1024 * 1024

    let homeDirectoryURL: URL
    let supportDirectoryURL: URL
    let runnerExecutableURL: URL?

    init(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        supportDirectoryURL: URL = GeminiCredentialFileStore.defaultDirectoryURL
            .appendingPathComponent("StatusHooks", isDirectory: true),
        runnerExecutableURL: URL? = ProviderStatusHookManager.locateRunnerExecutable()
    ) {
        self.homeDirectoryURL = homeDirectoryURL
        self.supportDirectoryURL = supportDirectoryURL
        self.runnerExecutableURL = runnerExecutableURL
    }

    func capability(for runtime: RuntimeKind) -> ProviderStatusHookCapability {
        switch runtime {
        case .codex, .cursor: .globalUserConfiguration
        case .claude: .runScopedSettings
        case .kiro: .unsupported
        }
    }

    func inspect(runtime: RuntimeKind) -> ProviderStatusHookInspection {
        switch capability(for: runtime) {
        case .runScopedSettings:
            return ProviderStatusHookInspection(
                capability: .runScopedSettings,
                health: .runScoped,
                configurationPath: nil
            )
        case .unsupported:
            return ProviderStatusHookInspection(
                capability: .unsupported,
                health: .unsupported,
                configurationPath: nil
            )
        case .globalUserConfiguration:
            let configURL = configurationURL(for: runtime)
            do {
                guard let runnerExecutableURL else {
                    throw ProviderStatusHookError.runnerNotFound
                }
                try validateRunner(runnerExecutableURL)
                let expectedWrapper = wrapperData(runnerExecutableURL: runnerExecutableURL)
                guard try SecureStatusHookFiles.readIfPresent(wrapperURL(for: runtime)) == expectedWrapper else {
                    return inspection(
                        runtime: runtime,
                        configURL: configURL,
                        health: .needsRepair("TodoAgent Hook 启动器缺失或已变化。")
                    )
                }
                guard let data = try SecureStatusHookFiles.readIfPresent(
                    configURL,
                    maximumBytes: Self.maximumConfigurationBytes
                ) else {
                    return inspection(runtime: runtime, configURL: configURL, health: .notInstalled)
                }
                let document = try decodeDocument(data, runtime: runtime, url: configURL)
                guard containsAllManagedHooks(document, runtime: runtime) else {
                    return inspection(runtime: runtime, configURL: configURL, health: .notInstalled)
                }
                return inspection(
                    runtime: runtime,
                    configURL: configURL,
                    health: runtime == .codex ? .installedRequiresProviderReview : .installed
                )
            } catch {
                return inspection(
                    runtime: runtime,
                    configURL: configURL,
                    health: .needsRepair(error.localizedDescription)
                )
            }
        }
    }

    @discardableResult
    func install(runtime: RuntimeKind) throws -> ProviderStatusHookInspection {
        switch capability(for: runtime) {
        case .unsupported:
            throw ProviderStatusHookError.unsupportedRuntime(runtime)
        case .runScopedSettings:
            return inspect(runtime: runtime)
        case .globalUserConfiguration:
            break
        }

        guard let runnerExecutableURL else { throw ProviderStatusHookError.runnerNotFound }
        try validateRunner(runnerExecutableURL)
        let configURL = configurationURL(for: runtime)
        try SecureStatusHookFiles.ensureDirectory(configURL.deletingLastPathComponent())
        try SecureStatusHookFiles.ensureDirectory(supportDirectoryURL)

        let originalData = try SecureStatusHookFiles.readIfPresent(
            configURL,
            maximumBytes: Self.maximumConfigurationBytes
        )
        var document = try originalData.map {
            try decodeDocument($0, runtime: runtime, url: configURL)
        } ?? emptyDocument(runtime: runtime)
        removeManagedHooks(from: &document, runtime: runtime)
        addManagedHooks(to: &document, runtime: runtime)
        let encoded = try encodeDocument(document, url: configURL)

        // Publish the inert wrapper before any provider configuration can
        // reference it. If this write fails (or the App crashes here), the
        // user's existing global hook document is still untouched. A wrapper
        // left behind after a later config failure is harmless and will be
        // reused by the next install attempt.
        try SecureStatusHookFiles.atomicWrite(
            wrapperData(runnerExecutableURL: runnerExecutableURL),
            to: wrapperURL(for: runtime),
            permissions: 0o700
        )
        if originalData != encoded {
            if let originalData {
                try backup(originalData, runtime: runtime)
            }
            try SecureStatusHookFiles.atomicWrite(encoded, to: configURL, permissions: 0o600)
        }
        return inspect(runtime: runtime)
    }

    func uninstall(runtime: RuntimeKind) throws {
        switch capability(for: runtime) {
        case .unsupported, .runScopedSettings:
            return
        case .globalUserConfiguration:
            break
        }

        let configURL = configurationURL(for: runtime)
        if let originalData = try SecureStatusHookFiles.readIfPresent(
            configURL,
            maximumBytes: Self.maximumConfigurationBytes
        ) {
            var document = try decodeDocument(originalData, runtime: runtime, url: configURL)
            removeManagedHooks(from: &document, runtime: runtime)
            let encoded = try encodeDocument(document, url: configURL)
            if encoded != originalData {
                try backup(originalData, runtime: runtime)
                try SecureStatusHookFiles.atomicWrite(encoded, to: configURL, permissions: 0o600)
            }
        }
        try SecureStatusHookFiles.removeRegularFileIfPresent(wrapperURL(for: runtime))
    }

    private func inspection(
        runtime: RuntimeKind,
        configURL: URL,
        health: ProviderStatusHookHealth
    ) -> ProviderStatusHookInspection {
        ProviderStatusHookInspection(
            capability: capability(for: runtime),
            health: health,
            configurationPath: configURL.path
        )
    }

    private func configurationURL(for runtime: RuntimeKind) -> URL {
        switch runtime {
        case .codex:
            homeDirectoryURL
                .appendingPathComponent(".codex", isDirectory: true)
                .appendingPathComponent("hooks.json")
        case .cursor:
            homeDirectoryURL
                .appendingPathComponent(".cursor", isDirectory: true)
                .appendingPathComponent("hooks.json")
        case .claude, .kiro:
            preconditionFailure("This runtime has no global status hook configuration.")
        }
    }

    private func wrapperURL(for runtime: RuntimeKind) -> URL {
        supportDirectoryURL.appendingPathComponent("\(runtime.rawValue)-status-hook-v1")
    }

    private func backup(_ data: Data, runtime: RuntimeKind) throws {
        let directory = supportDirectoryURL
            .appendingPathComponent("Backups", isDirectory: true)
            .appendingPathComponent(runtime.rawValue, isDirectory: true)
        try SecureStatusHookFiles.ensureDirectory(directory)
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1_000)
        let url = directory.appendingPathComponent(
            "\(timestamp)-\(UUID().uuidString)-hooks.json"
        )
        try SecureStatusHookFiles.createExclusive(data, at: url, permissions: 0o600)
    }

    private func emptyDocument(runtime: RuntimeKind) -> [String: Any] {
        switch runtime {
        case .codex: ["hooks": [String: Any]()]
        case .cursor: ["version": 1, "hooks": [String: Any]()]
        case .claude, .kiro: [:]
        }
    }

    private func decodeDocument(
        _ data: Data,
        runtime: RuntimeKind,
        url: URL
    ) throws -> [String: Any] {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        guard var document = value as? [String: Any] else {
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        if runtime == .cursor {
            if let version = document["version"] {
                guard let number = version as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(),
                      number.intValue == 1
                else {
                    throw ProviderStatusHookError.unsupportedConfigurationVersion(url.path)
                }
            } else {
                document["version"] = 1
            }
        }
        if let hooks = document["hooks"], hooks is [String: Any] == false {
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        document["hooks"] = document["hooks"] ?? [String: Any]()
        guard let hooks = document["hooks"] as? [String: Any] else {
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        let managedEvents: [String] = switch runtime {
        case .codex: Self.codexEvents
        case .cursor: Self.cursorEvents
        case .claude, .kiro: []
        }
        guard managedEvents.allSatisfy({ event in
            guard let existing = hooks[event] else { return true }
            return existing is [Any]
        }) else {
            // A future provider schema or a third-party extension owns this
            // event in a shape we do not understand. Refuse to replace it.
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        return document
    }

    private func encodeDocument(_ document: [String: Any], url: URL) throws -> Data {
        guard JSONSerialization.isValidJSONObject(document) else {
            throw ProviderStatusHookError.malformedConfiguration(url.path)
        }
        var data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        guard data.count <= Self.maximumConfigurationBytes else {
            throw ProviderStatusHookError.fileTooLarge(url.path)
        }
        return data
    }

    private func addManagedHooks(to document: inout [String: Any], runtime: RuntimeKind) {
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        switch runtime {
        case .codex:
            for event in Self.codexActiveEvents {
                var groups = hooks[event] as? [Any] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": managedCommand(runtime: runtime),
                        "timeout": 3,
                    ]],
                ])
                hooks[event] = groups
            }
            for event in Self.codexCompletedEvents {
                var groups = hooks[event] as? [Any] ?? []
                groups.append([
                    "hooks": [[
                        "type": "command",
                        "command": managedCommand(runtime: runtime, statusOverride: "completed"),
                        "timeout": 3,
                    ]],
                ])
                hooks[event] = groups
            }
        case .cursor:
            for event in Self.cursorActiveEvents {
                var handlers = hooks[event] as? [Any] ?? []
                handlers.append([
                    "command": managedCommand(runtime: runtime),
                    "timeout": 3,
                ])
                hooks[event] = handlers
            }
            for event in Self.cursorCompletedEvents {
                var handlers = hooks[event] as? [Any] ?? []
                handlers.append([
                    "command": managedCommand(runtime: runtime, statusOverride: "completed"),
                    "timeout": 3,
                ])
                hooks[event] = handlers
            }
        case .claude, .kiro:
            break
        }
        document["hooks"] = hooks
    }

    private func removeManagedHooks(from document: inout [String: Any], runtime: RuntimeKind) {
        guard var hooks = document["hooks"] as? [String: Any] else { return }
        let commands = managedCommands(runtime: runtime)
        switch runtime {
        case .codex:
            for event in Self.codexEvents {
                guard let groups = hooks[event] as? [Any] else { continue }
                let filteredGroups: [Any] = groups.compactMap { groupValue in
                    guard var group = groupValue as? [String: Any],
                          let handlers = group["hooks"] as? [Any]
                    else { return groupValue }
                    let filteredHandlers = handlers.filter { handlerValue in
                        guard let handler = handlerValue as? [String: Any] else { return true }
                        return commands.contains(handler["command"] as? String ?? "") == false
                    }
                    guard filteredHandlers.isEmpty == false else { return nil }
                    group["hooks"] = filteredHandlers
                    return group
                }
                hooks[event] = filteredGroups
            }
        case .cursor:
            for event in Self.cursorEvents {
                guard let handlers = hooks[event] as? [Any] else { continue }
                hooks[event] = handlers.filter { handlerValue in
                    guard let handler = handlerValue as? [String: Any] else { return true }
                    return commands.contains(handler["command"] as? String ?? "") == false
                }
            }
        case .claude, .kiro:
            break
        }
        document["hooks"] = hooks
    }

    private func containsAllManagedHooks(
        _ document: [String: Any],
        runtime: RuntimeKind
    ) -> Bool {
        guard let hooks = document["hooks"] as? [String: Any] else { return false }
        switch runtime {
        case .codex:
            return Self.codexEvents.allSatisfy { event in
                let expectedCommand = Self.codexCompletedEvents.contains(event)
                    ? managedCommand(runtime: runtime, statusOverride: "completed")
                    : managedCommand(runtime: runtime)
                guard let groups = hooks[event] as? [Any] else { return false }
                return groups.contains { groupValue in
                    guard let group = groupValue as? [String: Any],
                          let handlers = group["hooks"] as? [Any]
                    else { return false }
                    return handlers.contains { handlerValue in
                        (handlerValue as? [String: Any])?["command"] as? String == expectedCommand
                    }
                }
            }
        case .cursor:
            return Self.cursorEvents.allSatisfy { event in
                let expectedCommand = Self.cursorCompletedEvents.contains(event)
                    ? managedCommand(runtime: runtime, statusOverride: "completed")
                    : managedCommand(runtime: runtime)
                guard let handlers = hooks[event] as? [Any] else { return false }
                return handlers.contains { handlerValue in
                    (handlerValue as? [String: Any])?["command"] as? String == expectedCommand
                }
            }
        case .claude, .kiro:
            return false
        }
    }

    private func managedCommand(runtime: RuntimeKind, statusOverride: String? = nil) -> String {
        let base = Self.shellQuote(wrapperURL(for: runtime).path)
        guard let statusOverride else { return base }
        return "TODOAGENT_HOOK_STATUS=\(Self.shellQuote(statusOverride)) \(base)"
    }

    private func managedCommands(runtime: RuntimeKind) -> Set<String> {
        [
            managedCommand(runtime: runtime),
            managedCommand(runtime: runtime, statusOverride: "completed"),
        ]
    }

    private func wrapperData(runnerExecutableURL: URL) -> Data {
        let runner = Self.shellQuote(runnerExecutableURL.path)
        return Data(
            "#!/bin/sh\nif [ -x \(runner) ]; then\n  \(runner) hook-event \"${TODOAGENT_HOOK_STATUS:-}\" >/dev/null 2>&1 || :\nfi\nexit 0\n".utf8
        )
    }

    private func validateRunner(_ url: URL) throws {
        guard url.path.hasPrefix("/") else { throw ProviderStatusHookError.pathMustBeAbsolute }
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw ProviderStatusHookError.runnerNotFound }
            throw ProviderStatusHookError.systemCall("检查 Terminal Runner", errno)
        }
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw ProviderStatusHookError.symbolicLink(url.path)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              access(url.path, X_OK) == 0
        else {
            throw ProviderStatusHookError.runnerNotFound
        }
    }

    private static let codexActiveEvents = ["SessionStart", "UserPromptSubmit", "PermissionRequest"]
    private static let codexCompletedEvents = ["Stop", "SessionEnd"]
    private static let codexEvents = codexActiveEvents + codexCompletedEvents

    private static let cursorActiveEvents = ["sessionStart", "beforeSubmitPrompt"]
    private static let cursorCompletedEvents = ["stop", "sessionEnd"]
    private static let cursorEvents = cursorActiveEvents + cursorCompletedEvents

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func locateRunnerExecutable() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("todoagent-terminal-runner"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("todoagent-terminal-runner"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private enum SecureStatusHookFiles {
    static func ensureDirectory(_ url: URL) throws {
        guard url.path.hasPrefix("/") else { throw ProviderStatusHookError.pathMustBeAbsolute }
        try rejectSymlinksInExistingComponents(url)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ProviderStatusHookError.systemCall("创建状态 Hook 目录", errno)
        }
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw ProviderStatusHookError.systemCall("检查状态 Hook 目录", errno)
        }
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw ProviderStatusHookError.symbolicLink(url.path)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
            throw ProviderStatusHookError.invalidFileType(url.path)
        }
        guard status.st_uid == geteuid() else {
            throw ProviderStatusHookError.wrongOwner(url.path)
        }
    }

    static func readIfPresent(
        _ url: URL,
        maximumBytes: Int = ProviderStatusHookManager.maximumConfigurationBytes
    ) throws -> Data? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ProviderStatusHookError.symbolicLink(url.path) }
            throw ProviderStatusHookError.systemCall("读取状态 Hook 文件", errno)
        }
        defer { close(descriptor) }
        let status = try validateRegularFile(descriptor: descriptor, path: url.path)
        guard status.st_size <= maximumBytes else {
            throw ProviderStatusHookError.fileTooLarge(url.path)
        }
        var data = Data()
        data.reserveCapacity(max(0, Int(status.st_size)))
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderStatusHookError.systemCall("读取状态 Hook 文件", errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw ProviderStatusHookError.fileTooLarge(url.path)
            }
        }
        return data
    }

    static func atomicWrite(_ data: Data, to url: URL, permissions: mode_t) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try validateExistingDestination(url)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(
            ".todoagent-status-hook-\(UUID().uuidString).tmp"
        )
        try createExclusive(data, at: temporaryURL, permissions: permissions)
        var shouldRemove = true
        defer {
            if shouldRemove { try? FileManager.default.removeItem(at: temporaryURL) }
        }
        guard rename(temporaryURL.path, url.path) == 0 else {
            throw ProviderStatusHookError.systemCall("替换状态 Hook 文件", errno)
        }
        shouldRemove = false
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func createExclusive(_ data: Data, at url: URL, permissions: mode_t) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, permissions)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw ProviderStatusHookError.symbolicLink(url.path) }
            throw ProviderStatusHookError.systemCall("创建状态 Hook 文件", errno)
        }
        var completed = false
        defer {
            close(descriptor)
            if completed == false { _ = unlink(url.path) }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ProviderStatusHookError.systemCall("写入状态 Hook 文件", errno)
                }
                written += count
            }
        }
        guard fchmod(descriptor, permissions) == 0 else {
            throw ProviderStatusHookError.systemCall("设置状态 Hook 文件权限", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw ProviderStatusHookError.systemCall("同步状态 Hook 文件", errno)
        }
        completed = true
    }

    static func removeRegularFileIfPresent(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw ProviderStatusHookError.systemCall("检查状态 Hook 文件", errno)
        }
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw ProviderStatusHookError.symbolicLink(url.path)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderStatusHookError.invalidFileType(url.path)
        }
        guard status.st_uid == geteuid() else {
            throw ProviderStatusHookError.wrongOwner(url.path)
        }
        guard status.st_nlink == 1 else {
            throw ProviderStatusHookError.multipleHardLinks(url.path)
        }
        guard unlink(url.path) == 0 else {
            throw ProviderStatusHookError.systemCall("删除状态 Hook 文件", errno)
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private static func validateExistingDestination(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { return }
            throw ProviderStatusHookError.systemCall("检查状态 Hook 文件", errno)
        }
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw ProviderStatusHookError.symbolicLink(url.path)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderStatusHookError.invalidFileType(url.path)
        }
        guard status.st_uid == geteuid() else {
            throw ProviderStatusHookError.wrongOwner(url.path)
        }
        guard status.st_nlink == 1 else {
            throw ProviderStatusHookError.multipleHardLinks(url.path)
        }
    }

    private static func validateRegularFile(descriptor: Int32, path: String) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw ProviderStatusHookError.systemCall("检查状态 Hook 文件", errno)
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw ProviderStatusHookError.invalidFileType(path)
        }
        guard status.st_uid == geteuid() else {
            throw ProviderStatusHookError.wrongOwner(path)
        }
        guard status.st_nlink == 1 else {
            throw ProviderStatusHookError.multipleHardLinks(path)
        }
        return status
    }

    private static func rejectSymlinksInExistingComponents(_ url: URL) throws {
        // Preserve the caller's lexical `/private/tmp` spelling. Resolving it
        // to `/tmp` would manufacture a symlink component before we inspect
        // the actual test/product path.
        let components = url.pathComponents
        guard components.first == "/" else { throw ProviderStatusHookError.pathMustBeAbsolute }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var status = stat()
            if lstat(current.path, &status) != 0 {
                if errno == ENOENT { return }
                throw ProviderStatusHookError.systemCall("检查状态 Hook 路径", errno)
            }
            if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw ProviderStatusHookError.symbolicLink(current.path)
            }
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw ProviderStatusHookError.systemCall("打开状态 Hook 目录", errno)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ProviderStatusHookError.systemCall("同步状态 Hook 目录", errno)
        }
    }
}
