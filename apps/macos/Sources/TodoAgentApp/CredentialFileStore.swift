import Darwin
import Foundation

/// Stores the Gemini credential in the current macOS account's Application
/// Support directory. This deliberately avoids Keychain/code-signing coupling
/// for the local preview build. The file is protected by POSIX permissions;
/// users should enable FileVault for encryption at rest.
struct GeminiCredentialFileStore: Sendable {
    static let fileName = "credentials.json"
    static let maximumFileSize = 64 * 1024

    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    static var defaultDirectoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TodoAgent", isDirectory: true)
    }

    func save(_ key: String) throws {
        guard key.isEmpty == false else { throw CredentialFileError.emptyCredential }
        let document = CredentialDocument(version: 1, geminiApiKey: key)
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumFileSize else { throw CredentialFileError.fileTooLarge }

        let directory = try openDirectory(createIfNeeded: true)
        defer { close(directory) }
        try validateExistingCredential(in: directory)

        let temporaryName = ".credentials.\(UUID().uuidString).tmp"
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC
        let descriptor = temporaryName.withCString {
            openat(directory, $0, flags, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw CredentialFileError.systemCall("创建临时凭据文件", errno)
        }

        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                temporaryName.withCString { _ = unlinkat(directory, $0, 0) }
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw CredentialFileError.systemCall("写入凭据文件", errno)
                }
                written += result
            }
        }

        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw CredentialFileError.systemCall("设置凭据文件权限", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw CredentialFileError.systemCall("同步凭据文件", errno)
        }

        let renameResult = temporaryName.withCString { temporaryPath in
            Self.fileName.withCString { destinationPath in
                renameat(directory, temporaryPath, directory, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw CredentialFileError.systemCall("替换凭据文件", errno)
        }
        shouldRemoveTemporaryFile = false
        try syncDirectory(directory)
    }

    func load() throws -> String? {
        guard let directory = try openDirectoryIfPresent() else { return nil }
        defer { close(directory) }

        let descriptor = Self.fileName.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw CredentialFileError.symbolicLink }
            throw CredentialFileError.systemCall("读取凭据文件", errno)
        }
        defer { close(descriptor) }

        let status = try validatedFileStatus(descriptor)
        guard status.st_size <= Self.maximumFileSize else {
            throw CredentialFileError.fileTooLarge
        }

        var data = Data()
        data.reserveCapacity(max(0, Int(status.st_size)))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw CredentialFileError.systemCall("读取凭据文件", errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileSize else {
                throw CredentialFileError.fileTooLarge
            }
        }

        let document: CredentialDocument
        do {
            document = try JSONDecoder().decode(CredentialDocument.self, from: data)
        } catch {
            throw CredentialFileError.corruptedData
        }
        guard document.version == 1 else {
            throw CredentialFileError.unsupportedVersion(document.version)
        }
        guard document.geminiApiKey.isEmpty == false else {
            throw CredentialFileError.corruptedData
        }
        return document.geminiApiKey
    }

    /// Checks for a valid credential file without reading its secret payload.
    /// Settings uses this at launch so the saved-state indicator does not keep
    /// the API key in memory before the user explicitly asks to reveal it.
    func containsCredential() throws -> Bool {
        guard let directory = try openDirectoryIfPresent() else { return false }
        defer { close(directory) }

        var status = stat()
        let result = Self.fileName.withCString {
            fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return false }
            throw CredentialFileError.systemCall("检查凭据文件", errno)
        }
        try validateCredentialStatus(status)
        return true
    }

    func delete() throws -> CredentialFileDeletionOutcome {
        guard let directory = try openDirectoryIfPresent() else { return .notFound }
        defer { close(directory) }

        var status = stat()
        let result = Self.fileName.withCString {
            fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return .notFound }
            throw CredentialFileError.systemCall("检查凭据文件", errno)
        }
        try validateCredentialForDeletion(status)

        let unlinkResult = Self.fileName.withCString { unlinkat(directory, $0, 0) }
        guard unlinkResult == 0 else {
            throw CredentialFileError.systemCall("删除凭据文件", errno)
        }
        try syncDirectory(directory)
        return .removed
    }

    private func openDirectory(createIfNeeded: Bool) throws -> Int32 {
        if createIfNeeded {
            let createResult = directoryURL.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
            if createResult != 0, errno != EEXIST {
                throw CredentialFileError.systemCall("创建凭据目录", errno)
            }
        }

        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        if descriptor < 0 {
            try throwDirectoryOpenError(errno)
        }

        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw CredentialFileError.systemCall("检查凭据目录", errno)
            }
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw CredentialFileError.invalidFileType
            }
            guard status.st_uid == geteuid() else { throw CredentialFileError.wrongOwner }
            guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw CredentialFileError.systemCall("设置凭据目录权限", errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func openDirectoryIfPresent() throws -> Int32? {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            try throwDirectoryOpenError(errno)
        }

        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw CredentialFileError.systemCall("检查凭据目录", errno)
            }
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw CredentialFileError.invalidFileType
            }
            guard status.st_uid == geteuid() else { throw CredentialFileError.wrongOwner }
            let permissions = status.st_mode & mode_t(0o077)
            guard permissions == 0 else {
                throw CredentialFileError.insecurePermissions(UInt16(permissions))
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateExistingCredential(in directory: Int32) throws {
        var status = stat()
        let result = Self.fileName.withCString {
            fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw CredentialFileError.systemCall("检查凭据文件", errno)
        }
        try validateCredentialStatus(status)
    }

    private func validatedFileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw CredentialFileError.systemCall("检查凭据文件", errno)
        }
        try validateCredentialStatus(status)
        return status
    }

    private func validateCredentialStatus(_ status: stat) throws {
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw CredentialFileError.symbolicLink
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CredentialFileError.invalidFileType
        }
        guard status.st_uid == geteuid() else { throw CredentialFileError.wrongOwner }
        guard status.st_nlink == 1 else { throw CredentialFileError.multipleHardLinks }
        let permissions = status.st_mode & mode_t(0o077)
        guard permissions == 0 else {
            throw CredentialFileError.insecurePermissions(UInt16(permissions))
        }
    }

    private func validateCredentialForDeletion(_ status: stat) throws {
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw CredentialFileError.symbolicLink
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CredentialFileError.invalidFileType
        }
        guard status.st_uid == geteuid() else { throw CredentialFileError.wrongOwner }
        guard status.st_nlink == 1 else { throw CredentialFileError.multipleHardLinks }
    }

    private func syncDirectory(_ descriptor: Int32) throws {
        if fsync(descriptor) != 0, errno != EINVAL {
            throw CredentialFileError.systemCall("同步凭据目录", errno)
        }
    }

    private func throwDirectoryOpenError(_ code: Int32) throws -> Never {
        if code == ELOOP { throw CredentialFileError.symbolicLink }
        if code == ENOTDIR {
            var status = stat()
            let result = directoryURL.path.withCString { lstat($0, &status) }
            if result == 0,
               (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw CredentialFileError.symbolicLink
            }
            throw CredentialFileError.invalidFileType
        }
        throw CredentialFileError.systemCall("打开凭据目录", code)
    }
}

private struct CredentialDocument: Codable {
    let version: Int
    let geminiApiKey: String
}

@MainActor
enum CredentialStore {
    private static let live = GeminiCredentialFileStore()

    static func saveGeminiKey(_ key: String) throws { try live.save(key) }
    static func loadGeminiKey() throws -> String? { try live.load() }
    static func hasGeminiKey() throws -> Bool { try live.containsCredential() }
    static func deleteGeminiKey() throws -> CredentialFileDeletionOutcome { try live.delete() }
}

enum CredentialFileDeletionOutcome: Equatable {
    case removed
    case notFound
}

enum CredentialFileError: LocalizedError, Equatable {
    case emptyCredential
    case symbolicLink
    case invalidFileType
    case wrongOwner
    case multipleHardLinks
    case insecurePermissions(UInt16)
    case fileTooLarge
    case corruptedData
    case unsupportedVersion(Int)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .emptyCredential:
            "API Key 不能为空。"
        case .symbolicLink:
            "凭据路径是符号链接，已拒绝访问。"
        case .invalidFileType:
            "凭据路径不是安全的普通文件或目录。"
        case .wrongOwner:
            "凭据文件不属于当前 macOS 账户，已拒绝访问。"
        case .multipleHardLinks:
            "凭据文件存在额外硬链接，已拒绝访问。"
        case let .insecurePermissions(permissions):
            "凭据权限过宽（\(String(permissions, radix: 8))），请在设置中移除后重新保存。"
        case .fileTooLarge:
            "凭据文件异常过大，已拒绝读取。"
        case .corruptedData:
            "本地凭据文件已损坏，无法解析。"
        case let .unsupportedVersion(version):
            "本地凭据文件版本不受支持（\(version)）。"
        case let .systemCall(operation, code):
            "\(operation)失败（系统错误 \(code)）。"
        }
    }
}
