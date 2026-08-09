import Foundation
import Testing
@testable import TodoAgentApp

struct AssistantTextAttachmentTests {
    @Test("loads UTF-8 txt and markdown without exposing their paths")
    func loadsSupportedTextFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let textURL = directory.appending(path: "notes.txt")
        let markdownURL = directory.appending(path: "plan.md")
        try Data("plain text".utf8).write(to: textURL)
        try Data("# 计划".utf8).write(to: markdownURL)

        let attachments = try AssistantTextAttachmentLoader.load(urls: [textURL, markdownURL])

        #expect(attachments.map(\.name) == ["notes.txt", "plan.md"])
        #expect(attachments.map(\.mediaType) == ["text/plain", "text/markdown"])
        #expect(attachments.map(\.content) == ["plain text", "# 计划"])
    }

    @Test("rejects non UTF-8 and oversized text files with a clear reason")
    func rejectsInvalidFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidURL = directory.appending(path: "invalid.txt")
        try Data([0xFF, 0xFE, 0x00]).write(to: invalidURL)
        #expect(throws: AssistantTextAttachmentLoadingError.invalidUTF8("invalid.txt")) {
            try AssistantTextAttachmentLoader.load(urls: [invalidURL])
        }

        let largeURL = directory.appending(path: "large.md")
        try Data(repeating: 0x61, count: AssistantTextAttachmentLimits.maximumFileBytes + 1).write(to: largeURL)
        #expect(throws: AssistantTextAttachmentLoadingError.fileTooLarge("large.md")) {
            try AssistantTextAttachmentLoader.load(urls: [largeURL])
        }

        let binaryControlURL = directory.appending(path: "control.txt")
        try Data([0x41, 0x01, 0x42]).write(to: binaryControlURL)
        #expect(throws: AssistantTextAttachmentLoadingError.unsupportedControlCharacters("control.txt")) {
            try AssistantTextAttachmentLoader.load(urls: [binaryControlURL])
        }
    }

    @Test("selection enforces the combined count and byte limits")
    func selectionLimits() throws {
        let attachment = AssistantTextAttachment(
            name: "a.txt",
            mediaType: "text/plain",
            content: "a",
            byteCount: 1
        )
        #expect(throws: AssistantTextAttachmentLoadingError.tooManyFiles(5)) {
            try AssistantTextAttachmentSelection.appending(
                [attachment, attachment],
                to: [attachment, attachment, attachment]
            )
        }

        let large = AssistantTextAttachment(
            name: "large.txt",
            mediaType: "text/plain",
            content: "",
            byteCount: AssistantTextAttachmentLimits.maximumTotalBytes
        )
        #expect(throws: AssistantTextAttachmentLoadingError.totalTooLarge) {
            try AssistantTextAttachmentSelection.appending([attachment], to: [large])
        }
    }

    @Test("message payload exposes only persisted attachment summaries")
    func decodesAttachmentSummaries() {
        let payload = #"{"attachments":[{"name":"plan.md","mediaType":"text/markdown","byteCount":42}]}"#
        let message = AssistantMessage(
            id: "message",
            sessionID: "session",
            sequence: 1,
            role: .user,
            body: "请处理",
            payloadJSON: payload
        )

        #expect(message.textAttachments == [
            AssistantAttachmentSummary(name: "plan.md", mediaType: "text/markdown", byteCount: 42),
        ])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "todoagent-attachment-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
