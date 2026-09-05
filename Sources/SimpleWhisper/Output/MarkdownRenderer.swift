import AppKit
import Foundation

/// Heuristics and rendering for Markdown shown in the result window.
enum MarkdownRenderer {
    /// True when the text contains typical Markdown structure (headings, lists, fences, tables, emphasis, links).
    static func looksLikeMarkdown(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines)
        var strong = 0
        var weak = 0
        var listLines = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { strong += 1 }
            if line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil { strong += 1 }
            if line.range(of: #"^\|.*\|$"#, options: .regularExpression) != nil { strong += 1 }
            if line.range(of: #"^([-*+]|\d+[.)])\s+\S"#, options: .regularExpression) != nil { listLines += 1 }
            if line.hasPrefix("> ") { weak += 1 }
            if line.range(of: #"\*\*[^*]+\*\*|__[^_]+__"#, options: .regularExpression) != nil { weak += 1 }
            if line.range(of: #"\[[^\]]+\]\([^)]+\)"#, options: .regularExpression) != nil { weak += 1 }
            if line.range(of: #"`[^`]+`"#, options: .regularExpression) != nil { weak += 1 }
        }
        if listLines >= 2 { strong += 1 }
        return strong >= 1 || weak >= 2
    }

    /// Renders Markdown into an attributed string with headings, lists, code blocks, quotes, emphasis and links.
    static func render(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return NSAttributedString(string: markdown, attributes: [.font: baseFont, .foregroundColor: NSColor.labelColor])
        }

        let output = NSMutableAttributedString()
        var previousBlockID: Int? = nil
        var orderedCounters: [Int: Int] = [:]

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let blockID = intent?.components.first?.identity

            var font = baseFont
            var color = NSColor.labelColor
            var paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            var prefix = ""
            var isCodeBlock = false

            if let intent {
                for component in intent.components {
                    switch component.kind {
                    case .header(let level):
                        let size: CGFloat = [26, 22, 18, 16, 15, 14][max(0, min(5, level - 1))]
                        font = NSFont.systemFont(ofSize: size, weight: .bold)
                        paragraph.paragraphSpacingBefore = 10
                    case .codeBlock:
                        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
                        isCodeBlock = true
                        paragraph.headIndent = 12
                        paragraph.firstLineHeadIndent = 12
                    case .blockQuote:
                        color = .secondaryLabelColor
                        paragraph.headIndent = 16
                        paragraph.firstLineHeadIndent = 16
                    case .listItem(let ordinal):
                        paragraph.headIndent = 22
                        paragraph.firstLineHeadIndent = 4
                        paragraph.paragraphSpacing = 3
                        if blockID != previousBlockID {
                            let isOrdered = intent.components.contains { if case .orderedList = $0.kind { return true } else { return false } }
                            if isOrdered {
                                let listID = intent.components.first { if case .orderedList = $0.kind { return true } else { return false } }?.identity ?? 0
                                let number = ordinal > 0 ? ordinal : (orderedCounters[listID] ?? 0) + 1
                                orderedCounters[listID] = number
                                prefix = "\(number).  "
                            } else {
                                prefix = "•  "
                            }
                        }
                    default:
                        break
                    }
                }
            }

            if let inline = run.inlinePresentationIntent {
                var traits: NSFontDescriptor.SymbolicTraits = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if inline.contains(.emphasized) { traits.insert(.italic) }
                if !traits.isEmpty, let descriptor = font.fontDescriptor.withSymbolicTraits(traits) as NSFontDescriptor? {
                    font = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
                }
                if inline.contains(.code) {
                    font = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
                }
                if inline.contains(.strikethrough) { /* handled below */ }
            }

            // Block separation: the parser does not keep newlines between blocks.
            if let previousBlockID, previousBlockID != blockID, output.length > 0 {
                output.append(NSAttributedString(string: "\n"))
            }
            previousBlockID = blockID

            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            if isCodeBlock || (run.inlinePresentationIntent?.contains(.code) ?? false) {
                attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            if run.inlinePresentationIntent?.contains(.strikethrough) ?? false {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if !prefix.isEmpty {
                output.append(NSAttributedString(string: prefix, attributes: [.font: baseFont, .foregroundColor: color, .paragraphStyle: paragraph]))
            }
            output.append(NSAttributedString(string: isCodeBlock ? text.trimmingCharacters(in: .newlines) : text, attributes: attributes))
        }
        return output
    }

    private static var baseFont: NSFont { .systemFont(ofSize: 14) }
}
