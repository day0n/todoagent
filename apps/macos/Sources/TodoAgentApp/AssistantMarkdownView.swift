import Foundation
import SwiftUI

/// A small, deterministic Markdown projection tailored to the narrow assistant
/// rail. Foundation parses inline emphasis, links, strike-through, and code;
/// this layer preserves the block structure that a single SwiftUI `Text` loses.
struct AssistantMarkdownDocument: Equatable, Sendable {
    enum Block: Equatable, Sendable {
        case paragraph(String)
        case heading(level: Int, text: String)
        case unorderedList([String])
        case orderedList([(number: Int, text: String)])
        case quote(String)
        case code(language: String?, body: String)
        case divider

        static func == (lhs: Block, rhs: Block) -> Bool {
            switch (lhs, rhs) {
            case let (.paragraph(left), .paragraph(right)):
                left == right
            case let (.heading(leftLevel, left), .heading(rightLevel, right)):
                leftLevel == rightLevel && left == right
            case let (.unorderedList(left), .unorderedList(right)):
                left == right
            case let (.orderedList(left), .orderedList(right)):
                left.map { "\($0.number):\($0.text)" } == right.map { "\($0.number):\($0.text)" }
            case let (.quote(left), .quote(right)):
                left == right
            case let (.code(leftLanguage, left), .code(rightLanguage, right)):
                leftLanguage == rightLanguage && left == right
            case (.divider, .divider):
                true
            default:
                false
            }
        }
    }

    let blocks: [Block]
    private let inlineValues: [String: AttributedString]

    init(markdown: String) {
        let parsedBlocks = Self.parse(markdown)
        blocks = parsedBlocks
        inlineValues = Self.prepareInlineValues(in: parsedBlocks)
    }

    func inlineValue(for source: String) -> AttributedString {
        inlineValues[source] ?? AttributedString(source)
    }

    private static func prepareInlineValues(in blocks: [Block]) -> [String: AttributedString] {
        var values: [String: AttributedString] = [:]
        func prepare(_ source: String) {
            guard values[source] == nil else { return }
            values[source] = AssistantMarkdownInlineParser.parse(source)
        }
        for block in blocks {
            switch block {
            case let .paragraph(text), let .heading(_, text), let .quote(text):
                prepare(text)
            case let .unorderedList(items):
                for item in items { prepare(item) }
            case let .orderedList(items):
                for item in items { prepare(item.text) }
            case .code, .divider:
                break
            }
        }
        return values
    }

    private static func parse(_ markdown: String) -> [Block] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let languageValue = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    if candidate.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        break
                    }
                    codeLines.append(candidate)
                    index += 1
                }
                blocks.append(
                    .code(
                        language: languageValue.isEmpty ? nil : languageValue,
                        body: codeLines.joined(separator: "\n")
                    )
                )
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst())
                            .trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = unorderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = unorderedItem(
                          from: lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if let item = orderedItem(from: trimmed) {
                flushParagraph()
                var items = [item]
                index += 1
                while index < lines.count,
                      let next = orderedItem(
                          from: lines[index].trimmingCharacters(in: .whitespaces)
                      ) {
                    items.append(next)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            paragraph.append(line)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1 ... 6).contains(hashes) else { return nil }
        let remainder = line.dropFirst(hashes)
        guard remainder.first == " " else { return nil }
        return (
            min(hashes, 3),
            String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
    }

    private static func unorderedItem(from line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    private static func orderedItem(from line: String) -> (number: Int, text: String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let remainder = line.dropFirst(digits.count)
        guard remainder.hasPrefix(". ") || remainder.hasPrefix(") ") else { return nil }
        return (number, String(remainder.dropFirst(2)))
    }

    private static func isDivider(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let marker = compact.first else { return false }
        return ["-", "*", "_"].contains(String(marker))
            && compact.allSatisfy { $0 == marker }
    }
}

struct AssistantMarkdownView: View {
    let document: AssistantMarkdownDocument

    init(document: AssistantMarkdownDocument) {
        self.document = document
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: AssistantMarkdownDocument.Block) -> some View {
        switch block {
        case let .paragraph(text):
            AssistantInlineMarkdownText(value: document.inlineValue(for: text))

        case let .heading(level, text):
            AssistantInlineMarkdownText(value: document.inlineValue(for: text))
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 4 : 1)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .foregroundStyle(TodoAgentUI.secondaryText)
                        AssistantInlineMarkdownText(value: document.inlineValue(for: item))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(item.number).")
                            .monospacedDigit()
                            .foregroundStyle(TodoAgentUI.secondaryText)
                            .frame(minWidth: 20, alignment: .trailing)
                        AssistantInlineMarkdownText(value: document.inlineValue(for: item.text))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(TodoAgentUI.hairline)
                    .frame(width: 3)
                AssistantInlineMarkdownText(value: document.inlineValue(for: text))
                    .foregroundStyle(TodoAgentUI.secondaryText)
            }

        case let .code(language, body):
            VStack(alignment: .leading, spacing: 5) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TodoAgentUI.secondaryText)
                }
                ScrollView(.horizontal) {
                    Text(body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .scrollIndicators(.hidden)
                .background(TodoAgentUI.selectionBackground, in: .rect(cornerRadius: 8))
            }

        case .divider:
            Divider()
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .headline
        case 2: .callout.weight(.semibold)
        default: .callout.weight(.medium)
        }
    }
}

enum AssistantMarkdownInlineParser {
    static func parse(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options))
            ?? AttributedString(text)
    }
}

private struct AssistantInlineMarkdownText: View {
    let value: AttributedString

    var body: some View {
        Text(value)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// Serializes and bounds expensive block + inline Markdown preparation away
/// from the MainActor. Cancelled row tasks are discarded before cache insert,
/// and queued cancelled work exits before parsing.
actor AssistantMarkdownRenderCache {
    static let shared = AssistantMarkdownRenderCache()

    private struct Entry: Sendable {
        let source: String
        let document: AssistantMarkdownDocument
        let sourceByteCount: Int
    }

    private let maximumEntryCount: Int
    private let maximumSourceBytes: Int
    private var entries: [String: Entry] = [:]
    private var leastRecentlyUsedIDs: [String] = []
    private var cachedSourceBytes = 0

    init(
        maximumEntryCount: Int = 16,
        maximumSourceBytes: Int = 4 * 1_048_576
    ) {
        self.maximumEntryCount = max(maximumEntryCount, 1)
        self.maximumSourceBytes = max(maximumSourceBytes, 1)
    }

    func document(id: String, source: String) -> AssistantMarkdownDocument? {
        guard !Task.isCancelled else { return nil }
        if let entry = entries[id], entry.source == source {
            touch(id)
            return entry.document
        }

        let document = AssistantMarkdownDocument(markdown: source)
        guard !Task.isCancelled else { return nil }
        insert(document: document, id: id, source: source)
        return document
    }

    func cacheMetrics() -> (entryCount: Int, sourceBytes: Int) {
        (entries.count, cachedSourceBytes)
    }

    private func insert(document: AssistantMarkdownDocument, id: String, source: String) {
        if let replaced = entries.removeValue(forKey: id) {
            cachedSourceBytes -= replaced.sourceByteCount
        }
        leastRecentlyUsedIDs.removeAll(where: { $0 == id })
        let sourceByteCount = source.utf8.count
        entries[id] = Entry(
            source: source,
            document: document,
            sourceByteCount: sourceByteCount
        )
        leastRecentlyUsedIDs.append(id)
        cachedSourceBytes += sourceByteCount

        while entries.count > maximumEntryCount || cachedSourceBytes > maximumSourceBytes {
            guard let evictedID = leastRecentlyUsedIDs.first else { break }
            leastRecentlyUsedIDs.removeFirst()
            if let evicted = entries.removeValue(forKey: evictedID) {
                cachedSourceBytes -= evicted.sourceByteCount
            }
        }
    }

    private func touch(_ id: String) {
        leastRecentlyUsedIDs.removeAll(where: { $0 == id })
        leastRecentlyUsedIDs.append(id)
    }
}
