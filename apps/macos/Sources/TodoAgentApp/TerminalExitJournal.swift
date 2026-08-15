import Darwin
import Dispatch
import Foundation

/// The first locally observed outcome for a terminal run. The record is
/// written before the Engine request so App termination can be bounded without
/// losing the outcome that still needs to be reconciled.
struct TerminalExitRecord: Codable, Equatable, Identifiable, Sendable {
    let taskID: UUID
    let sessionID: String
    let runID: String
    let exitCode: Int32?
    let reason: TerminalRunExitReason
    let errorCode: String?
    let errorMessage: String?

    var id: String { runID }
}

protocol TerminalExitJournaling: Sendable {
    func records() throws -> [TerminalExitRecord]
    func store(_ record: TerminalExitRecord) throws
    func remove(runID: String) throws
}

/// Serializes journal access on a dedicated queue instead of the MainActor.
///
/// The normal terminal-exit path awaits `store` before asking the Engine to
/// commit the same fact. The App-termination deadline uses `enqueueStore` so a
/// wedged filesystem cannot keep AppKit's terminate-later gate open; the same
/// serial queue still preserves record ordering and eventually completes the
/// exact write if the filesystem becomes responsive again.
final class TerminalExitJournalCoordinator: @unchecked Sendable {
    private let journal: any TerminalExitJournaling
    private let queue = DispatchQueue(label: "com.todoagent.terminal-exit-journal")

    init(journal: any TerminalExitJournaling) {
        self.journal = journal
    }

    func records() async throws -> [TerminalExitRecord] {
        try await perform { journal in
            try journal.records()
        }
    }

    func store(_ record: TerminalExitRecord) async throws {
        try await perform { journal in
            try journal.store(record)
        }
    }

    func remove(runID: String) async throws {
        try await perform { journal in
            try journal.remove(runID: runID)
        }
    }

    func enqueueStore(_ record: TerminalExitRecord) {
        queue.async { [journal] in
            try? journal.store(record)
        }
    }

    func enqueueRemove(runID: String) {
        queue.async { [journal] in
            try? journal.remove(runID: runID)
        }
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable (any TerminalExitJournaling) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [journal] in
                continuation.resume(with: Result { try operation(journal) })
            }
        }
    }
}

struct NoopTerminalExitJournal: TerminalExitJournaling {
    func records() throws -> [TerminalExitRecord] { [] }
    func store(_: TerminalExitRecord) throws {}
    func remove(runID _: String) throws {}
}

/// A small, fsync-backed write-ahead journal in Application Support. The
/// coordinator above serializes every read/modify/rename sequence off the
/// MainActor across concurrently ending controllers.
struct TerminalExitJournalStore: TerminalExitJournaling {
    static let fileName = "pending-terminal-exits.json"
    static let maximumFileSize = 256 * 1024
    static let maximumRecordCount = 1_024

    let directoryURL: URL

    init(directoryURL: URL = GeminiCredentialFileStore.defaultDirectoryURL) {
        self.directoryURL = directoryURL
    }

    func records() throws -> [TerminalExitRecord] {
        guard let directory = try openDirectoryIfPresent() else { return [] }
        defer { close(directory) }
        return try readDocument(in: directory).records
    }

    func store(_ record: TerminalExitRecord) throws {
        try validate(record)
        let directory = try openDirectory(createIfNeeded: true)
        defer { close(directory) }

        var document = try readDocument(in: directory)
        if let existing = document.records.first(where: { $0.runID == record.runID }) {
            guard existing == record else {
                throw TerminalExitJournalError.conflictingRecord(record.runID)
            }
            return
        }
        guard document.records.count < Self.maximumRecordCount else {
            throw TerminalExitJournalError.tooManyRecords
        }
        document.records.append(record)
        document.records.sort { $0.runID < $1.runID }
        try write(document, in: directory)
    }

    func remove(runID: String) throws {
        guard let directory = try openDirectoryIfPresent() else { return }
        defer { close(directory) }

        var document = try readDocument(in: directory)
        let originalCount = document.records.count
        document.records.removeAll { $0.runID == runID }
        guard document.records.count != originalCount else { return }
        if document.records.isEmpty {
            try validateExistingJournal(in: directory)
            let result = Self.fileName.withCString { unlinkat(directory, $0, 0) }
            guard result == 0 || errno == ENOENT else {
                throw TerminalExitJournalError.systemCall("删除终端退出日志", errno)
            }
            try syncDirectory(directory)
        } else {
            try write(document, in: directory)
        }
    }

    private func readDocument(in directory: Int32) throws -> TerminalExitJournalDocument {
        let descriptor = Self.fileName.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0 {
            if errno == ENOENT { return TerminalExitJournalDocument(version: 1, records: []) }
            if errno == ELOOP { throw TerminalExitJournalError.symbolicLink }
            throw TerminalExitJournalError.systemCall("读取终端退出日志", errno)
        }
        defer { close(descriptor) }

        let status = try validatedJournalStatus(descriptor)
        guard status.st_size <= Self.maximumFileSize else {
            throw TerminalExitJournalError.fileTooLarge
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
                throw TerminalExitJournalError.systemCall("读取终端退出日志", errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileSize else {
                throw TerminalExitJournalError.fileTooLarge
            }
        }

        let document: TerminalExitJournalDocument
        do {
            document = try JSONDecoder().decode(TerminalExitJournalDocument.self, from: data)
        } catch {
            throw TerminalExitJournalError.corruptedData
        }
        guard document.version == 1 else {
            throw TerminalExitJournalError.unsupportedVersion(document.version)
        }
        guard document.records.count <= Self.maximumRecordCount else {
            throw TerminalExitJournalError.tooManyRecords
        }
        var runIDs = Set<String>()
        for record in document.records {
            try validate(record)
            guard runIDs.insert(record.runID).inserted else {
                throw TerminalExitJournalError.corruptedData
            }
        }
        return document
    }

    private func write(_ document: TerminalExitJournalDocument, in directory: Int32) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= Self.maximumFileSize else {
            throw TerminalExitJournalError.fileTooLarge
        }
        try validateExistingJournal(in: directory)

        let temporaryName = ".pending-terminal-exits.\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else {
            throw TerminalExitJournalError.systemCall("创建终端退出临时日志", errno)
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
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw TerminalExitJournalError.systemCall("写入终端退出日志", errno)
                }
                written += count
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw TerminalExitJournalError.systemCall("设置终端退出日志权限", errno)
        }
        guard fsync(descriptor) == 0 else {
            throw TerminalExitJournalError.systemCall("同步终端退出日志", errno)
        }
        let renameResult = temporaryName.withCString { temporaryPath in
            Self.fileName.withCString { destinationPath in
                renameat(directory, temporaryPath, directory, destinationPath)
            }
        }
        guard renameResult == 0 else {
            throw TerminalExitJournalError.systemCall("替换终端退出日志", errno)
        }
        shouldRemoveTemporaryFile = false
        try syncDirectory(directory)
    }

    private func openDirectory(createIfNeeded: Bool) throws -> Int32 {
        if createIfNeeded {
            try createDirectoryHierarchy()
        }
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { try throwDirectoryOpenError(errno) }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else {
                throw TerminalExitJournalError.systemCall("检查终端退出日志目录", errno)
            }
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw TerminalExitJournalError.invalidFileType
            }
            guard status.st_uid == geteuid() else { throw TerminalExitJournalError.wrongOwner }
            guard fchmod(descriptor, 0o700) == 0 else {
                throw TerminalExitJournalError.systemCall("设置终端退出日志目录权限", errno)
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
                throw TerminalExitJournalError.systemCall("检查终端退出日志目录", errno)
            }
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw TerminalExitJournalError.invalidFileType
            }
            guard status.st_uid == geteuid() else { throw TerminalExitJournalError.wrongOwner }
            guard status.st_mode & mode_t(0o077) == 0 else {
                throw TerminalExitJournalError.insecurePermissions
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateExistingJournal(in directory: Int32) throws {
        var status = stat()
        let result = Self.fileName.withCString {
            fstatat(directory, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            if errno == ENOENT { return }
            throw TerminalExitJournalError.systemCall("检查终端退出日志", errno)
        }
        try validateJournalStatus(status)
    }

    private func validatedJournalStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw TerminalExitJournalError.systemCall("检查终端退出日志", errno)
        }
        try validateJournalStatus(status)
        return status
    }

    private func validateJournalStatus(_ status: stat) throws {
        if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
            throw TerminalExitJournalError.symbolicLink
        }
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw TerminalExitJournalError.invalidFileType
        }
        guard status.st_uid == geteuid() else { throw TerminalExitJournalError.wrongOwner }
        guard status.st_nlink == 1 else { throw TerminalExitJournalError.multipleHardLinks }
        guard status.st_mode & mode_t(0o077) == 0 else {
            throw TerminalExitJournalError.insecurePermissions
        }
    }

    private func validate(_ record: TerminalExitRecord) throws {
        guard UUID(uuidString: record.sessionID) != nil,
              UUID(uuidString: record.runID) != nil,
              record.errorCode?.utf8.count ?? 0 <= 1_024,
              record.errorMessage?.utf8.count ?? 0 <= 16 * 1_024
        else {
            throw TerminalExitJournalError.corruptedData
        }
    }

    private func createDirectoryHierarchy() throws {
        guard directoryURL.path.hasPrefix("/") else {
            throw TerminalExitJournalError.invalidFileType
        }
        let components = directoryURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            let result = current.path.withCString { Darwin.mkdir($0, 0o700) }
            if result == 0 { continue }
            guard errno == EEXIST else {
                throw TerminalExitJournalError.systemCall("创建终端退出日志目录", errno)
            }
            var status = stat()
            guard lstat(current.path, &status) == 0 else {
                throw TerminalExitJournalError.systemCall("检查终端退出日志目录", errno)
            }
            if (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) {
                throw TerminalExitJournalError.symbolicLink
            }
            guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw TerminalExitJournalError.invalidFileType
            }
        }
    }

    private func syncDirectory(_ descriptor: Int32) throws {
        if fsync(descriptor) != 0, errno != EINVAL {
            throw TerminalExitJournalError.systemCall("同步终端退出日志目录", errno)
        }
    }

    private func throwDirectoryOpenError(_ code: Int32) throws -> Never {
        if code == ELOOP { throw TerminalExitJournalError.symbolicLink }
        if code == ENOTDIR { throw TerminalExitJournalError.invalidFileType }
        throw TerminalExitJournalError.systemCall("打开终端退出日志目录", code)
    }
}

private struct TerminalExitJournalDocument: Codable {
    let version: Int
    var records: [TerminalExitRecord]
}

enum TerminalExitJournalError: LocalizedError, Equatable {
    case symbolicLink
    case invalidFileType
    case wrongOwner
    case multipleHardLinks
    case insecurePermissions
    case fileTooLarge
    case tooManyRecords
    case corruptedData
    case unsupportedVersion(Int)
    case conflictingRecord(String)
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .symbolicLink: "终端退出日志路径是符号链接，已拒绝访问。"
        case .invalidFileType: "终端退出日志路径不是安全的普通文件或目录。"
        case .wrongOwner: "终端退出日志不属于当前 macOS 账户，已拒绝访问。"
        case .multipleHardLinks: "终端退出日志存在额外硬链接，已拒绝访问。"
        case .insecurePermissions: "终端退出日志权限过宽，已拒绝访问。"
        case .fileTooLarge: "终端退出日志异常过大，已拒绝访问。"
        case .tooManyRecords: "终端退出日志记录过多，已拒绝继续写入。"
        case .corruptedData: "终端退出日志已损坏，无法解析。"
        case let .unsupportedVersion(version): "终端退出日志版本不受支持（\(version)）。"
        case let .conflictingRecord(runID): "终端 Run \(runID) 已有不同的退出结果。"
        case let .systemCall(operation, code): "\(operation)失败（errno \(code)）。"
        }
    }
}
