import SwiftUI
import UIKit

/// Small native renderer for the markdown most often returned by agents.
/// Fenced code keeps whitespace and horizontal scrolling without a web view.
struct MarkdownMessage: View {
    let text: String

    private enum Block {
        case paragraph(String)
        case heading(String, Int)
        case code(String, String)
        case quote(String)
        case bullet(String, String)
        case divider
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var language = ""
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                result.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                if inCode {
                    result.append(.code(code.joined(separator: "\n"), language))
                    code.removeAll()
                } else {
                    language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            if trimmed.isEmpty { flushParagraph(); continue }
            let headingLevel = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingLevel), trimmed.dropFirst(headingLevel).first == " " {
                flushParagraph()
                result.append(.heading(String(trimmed.dropFirst(headingLevel + 1)), headingLevel))
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                result.append(.quote(String(trimmed.dropFirst(2))))
            } else if ["---", "***", "___"].contains(trimmed) {
                flushParagraph()
                result.append(.divider)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                result.append(.bullet("•", String(trimmed.dropFirst(2))))
            } else if let range = trimmed.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flushParagraph()
                result.append(.bullet(String(trimmed[range]).trimmingCharacters(in: .whitespaces), String(trimmed[range.upperBound...])))
            } else { paragraph.append(line) }
        }
        flushParagraph()
        if inCode { result.append(.code(code.joined(separator: "\n"), language)) }
        return result
    }

    var body: some View {
        let content = blocks
        let containsOnlyParagraphs = content.allSatisfy { block in
            if case .paragraph = block { return true }
            return false
        }

        Group {
            if containsOnlyParagraphs {
                inline(text).font(.body.leading(.tight))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(content.enumerated()), id: \.offset) { _, block in
                        switch block {
                        case .paragraph(let value):
                            inline(value).font(.body.leading(.tight))
                        case .heading(let value, let level):
                            inline(value)
                                .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                                .padding(.top, 4)
                        case .quote(let value):
                            inline(value).font(.body.leading(.tight)).italic().foregroundStyle(.secondary)
                        case .bullet(let prefix, let value):
                            HStack(alignment: .firstTextBaseline, spacing: 9) {
                                Text(prefix).font(.body.leading(.tight)).foregroundStyle(.secondary).frame(minWidth: 13, alignment: .leading)
                                inline(value).font(.body.leading(.tight))
                            }
                        case .code(let value, let language):
                            CodeBlock(text: value, language: language)
                        case .divider:
                            Divider().padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ value: String) -> Text {
        if let attributed = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(value)
    }
}

private struct CodeBlock: View {
    let text: String
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !language.isEmpty {
                Text(language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(8)
        .background(Color(uiColor: .secondarySystemBackground))
        .contextMenu {
            Button("Copy Code", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
    }
}
