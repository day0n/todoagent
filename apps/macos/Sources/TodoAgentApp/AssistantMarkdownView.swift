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

    init(markdown: String) {
        blocks = Self.parse(markdown)
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

    init(_ markdown: String) {
        document = AssistantMarkdownDocument(markdown: markdown)
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
            AssistantInlineMarkdownText(text: text)

        case let .heading(level, text):
            AssistantInlineMarkdownText(text: text)
                .font(headingFont(level: level))
                .padding(.top, level == 1 ? 4 : 1)

        case let .unorderedList(items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•")
                            .foregroundStyle(TodoAgentUI.secondaryText)
                        AssistantInlineMarkdownText(text: item)
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
                        AssistantInlineMarkdownText(text: item.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(TodoAgentUI.hairline)
                    .frame(width: 3)
                AssistantInlineMarkdownText(text: text)
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

    init(text: String) {
        value = AssistantMarkdownInlineParser.parse(text)
    }

    var body: some View {
        Text(value)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
