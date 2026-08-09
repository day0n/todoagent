import AppKit
import Foundation
import UniformTypeIdentifiers

enum AssistantTextAttachmentLimits {
    static let maximumCount = 4
    static let maximumFileBytes = 131_072
    static let maximumTotalBytes = 262_144
}

enum AssistantTextAttachmentLoadingError: LocalizedError, Equatable, Sendable {
    case tooManyFiles(Int)
    case unsupportedType(String)
    case fileTooLarge(String)
    case totalTooLarge
    case unreadable(String)
    case invalidUTF8(String)
    case unsupportedControlCharacters(String)

    var errorDescription: String? {
        switch self {
        case let .tooManyFiles(count):
            "一次最多添加 4 个文本附件，当前选择了 \(count) 个。"
        case let .unsupportedType(name):
            "“\(name)”不是支持的文本附件。请选择 .txt 或 .md 文件。"
        case let .fileTooLarge(name):
            "“\(name)”超过 128 KB，请缩小文件后再添加。"
        case .totalTooLarge:
            "附件总大小超过 256 KB，请减少文件后再添加。"
        case let .unreadable(name):
            "无法读取“\(name)”，请确认文件仍然存在且有读取权限。"
        case let .invalidUTF8(name):
            "“\(name)”不是 UTF-8 文本，暂时无法添加。"
        case let .unsupportedControlCharacters(name):
            "“\(name)”包含不支持的二进制控制字符，请另存为普通 UTF-8 文本后再添加。"
        }
    }
}

enum AssistantTextAttachmentLoader {
    static func load(urls: [URL]) throws -> [AssistantTextAttachment] {
        guard urls.count <= AssistantTextAttachmentLimits.maximumCount else {
            throw AssistantTextAttachmentLoadingError.tooManyFiles(urls.count)
        }

        var totalBytes = 0
        var attachments: [AssistantTextAttachment] = []
        attachments.reserveCapacity(urls.count)

        for url in urls {
            let name = url.lastPathComponent
            let extensionName = url.pathExtension.lowercased()
            let mediaType: String
            switch extensionName {
            case "txt": mediaType = "text/plain"
            case "md": mediaType = "text/markdown"
            default: throw AssistantTextAttachmentLoadingError.unsupportedType(name)
            }

            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }

            let data: Data
            do {
                data = try Data(contentsOf: url, options: [.mappedIfSafe])
            } catch {
                throw AssistantTextAttachmentLoadingError.unreadable(name)
            }

            guard data.count <= AssistantTextAttachmentLimits.maximumFileBytes else {
                throw AssistantTextAttachmentLoadingError.fileTooLarge(name)
            }
            totalBytes += data.count
            guard totalBytes <= AssistantTextAttachmentLimits.maximumTotalBytes else {
                throw AssistantTextAttachmentLoadingError.totalTooLarge
            }
            guard var content = String(data: data, encoding: .utf8) else {
                throw AssistantTextAttachmentLoadingError.invalidUTF8(name)
            }
            if content.first == "\u{FEFF}" { content.removeFirst() }
            guard !content.unicodeScalars.contains(where: Self.isUnsupportedControlCharacter) else {
                throw AssistantTextAttachmentLoadingError.unsupportedControlCharacters(name)
            }

            attachments.append(
                AssistantTextAttachment(
                    name: name,
                    mediaType: mediaType,
                    content: content,
                    byteCount: data.count
                )
            )
        }
        return attachments
    }

    /// Keeps attachment requests comfortably below the Engine's 1 MiB NDJSON
    /// boundary. Arbitrary C0 bytes can expand to six-character JSON escapes;
    /// tabs and line endings are the only controls expected in .txt/.md files.
    private static func isUnsupportedControlCharacter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && ![0x09, 0x0A, 0x0D].contains(scalar.value))
            || scalar.value == 0x7F
    }
}

enum AssistantTextAttachmentSelection {
    static func appending(
        _ newAttachments: [AssistantTextAttachment],
        to existing: [AssistantTextAttachment]
    ) throws -> [AssistantTextAttachment] {
        let combined = existing + newAttachments
        guard combined.count <= AssistantTextAttachmentLimits.maximumCount else {
            throw AssistantTextAttachmentLoadingError.tooManyFiles(combined.count)
        }
        guard combined.reduce(0, { $0 + $1.byteCount }) <= AssistantTextAttachmentLimits.maximumTotalBytes else {
            throw AssistantTextAttachmentLoadingError.totalTooLarge
        }
        return combined
    }
}

@MainActor
enum AssistantTextAttachmentPicker {
    static func pick() async throws -> [AssistantTextAttachment]? {
        let panel = NSOpenPanel()
        panel.title = "添加文本附件"
        panel.prompt = "添加"
        panel.message = "选择最多 4 个 UTF-8 编码的 .txt 或 .md 文件。"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = ["txt", "md"].compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        }

        guard await panel.begin() == .OK else { return nil }
        return try AssistantTextAttachmentLoader.load(urls: panel.urls)
    }
}
