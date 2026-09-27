import AppKit
import SwiftUI

/// The editable text area shown under the HUD capsule in Live typing mode.
/// Dictated chunks are first inserted as a "⋯" placeholder at the caret and replaced once transcribed,
/// so the user can keep moving the caret and typing while transcription runs.
@MainActor
final class LiveEditorController: NSObject, NSTextViewDelegate {
    static let placeholderKey = NSAttributedString.Key("SimpleWhisperPlaceholder")
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 560
    private static let inset = NSSize(width: 10, height: 8)
    private static let placeholderGlyph = "⋯"

    let scrollView: NSScrollView
    let textView: NSTextView
    private(set) var size = CGSize(width: minWidth, height: 36)
    /// Called after the preferred size changed.
    var onSizeChange: (CGSize) -> Void = { _ in }
    var inkColor: NSColor = .labelColor { didSet { applyColors() } }

    override init() {
        scrollView = NSTextView.scrollableTextView()
        textView = scrollView.documentView as! NSTextView
        super.init()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = Self.inset
        textView.delegate = self
        applyColors()
    }

    private var normalAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: inkColor]
    }

    private func applyColors() {
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        textView.typingAttributes = normalAttributes
        textView.selectedTextAttributes = [.backgroundColor: inkColor.withAlphaComponent(0.22)]
    }

    func reset() {
        textView.isEditable = true
        textView.string = ""
        textView.undoManager?.removeAllActions()
        textView.typingAttributes = normalAttributes
        updateSize()
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Editor text without pending placeholders.
    var text: String {
        guard let storage = textView.textStorage else { return textView.string }
        let result = NSMutableString(string: storage.string)
        for range in placeholderRanges().reversed() { result.replaceCharacters(in: range, with: "") }
        return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasPendingChunks: Bool { !placeholderRanges().isEmpty }

    /// Inserts a placeholder at the caret (replacing any selection) and returns its id.
    func insertPlaceholder() -> String {
        let id = UUID().uuidString
        var attributes = normalAttributes
        attributes[.foregroundColor] = inkColor.withAlphaComponent(0.45)
        attributes[Self.placeholderKey] = id
        let range = textView.selectedRange()
        let before = (textView.string as NSString).substring(to: range.location)
        let glyph = (before.last.map { !$0.isWhitespace } ?? false) ? " " + Self.placeholderGlyph : Self.placeholderGlyph
        replace(range, with: NSAttributedString(string: glyph, attributes: attributes), caretAfter: true)
        return id
    }

    /// Replaces the placeholder with the transcribed chunk, fixing spacing and capitalisation.
    func resolve(_ id: String, with chunk: String) {
        guard let range = placeholderRange(id) else { return }
        let storage = textView.string as NSString
        let before = storage.substring(to: range.location)
        let after = storage.substring(from: NSMaxRange(range))
        let fitted = Self.fit(chunk, before: before, after: after)
        replace(range, with: NSAttributedString(string: fitted, attributes: normalAttributes), caretAfter: false)
    }

    func drop(_ id: String) { resolve(id, with: "") }

    /// Shows a provisional transcription inside the placeholder (greyed, still replaceable).
    func preview(_ id: String, with chunk: String) {
        guard let range = placeholderRange(id) else { return }
        let storage = textView.string as NSString
        let before = storage.substring(to: range.location)
        let after = storage.substring(from: NSMaxRange(range))
        var fitted = Self.fit(chunk, before: before, after: after)
        if fitted.trimmingCharacters(in: .whitespaces).isEmpty { fitted = (before.last.map { !$0.isWhitespace } ?? false) ? " " + Self.placeholderGlyph : Self.placeholderGlyph }
        var attributes = normalAttributes
        attributes[.foregroundColor] = inkColor.withAlphaComponent(0.5)
        attributes[Self.placeholderKey] = id
        replace(range, with: NSAttributedString(string: fitted, attributes: attributes), caretAfter: false)
    }

    // MARK: Text surgery

    private func replace(_ range: NSRange, with string: NSAttributedString, caretAfter: Bool) {
        guard let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: string.string) else { return }
        storage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        let delta = string.length - range.length
        if caretAfter {
            textView.setSelectedRange(NSRange(location: range.location + string.length, length: 0))
        } else if selection.location >= NSMaxRange(range) {
            textView.setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
        } else if selection.location > range.location {
            textView.setSelectedRange(NSRange(location: range.location + string.length, length: 0))
        }
        textView.typingAttributes = normalAttributes
        textView.scrollRangeToVisible(textView.selectedRange())
        updateSize()
    }

    private func placeholderRanges() -> [NSRange] {
        guard let storage = textView.textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(Self.placeholderKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        return ranges
    }

    private func placeholderRange(_ id: String) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(Self.placeholderKey, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value as? String == id { found = range; stop.pointee = true }
        }
        return found
    }

    /// Adds the spaces and case a chunk needs to read naturally between `before` and `after`.
    nonisolated static func fit(_ chunk: String, before: String, after: String) -> String {
        var text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let previous = before.last { !$0.isWhitespace }
        let afterNewline = before.reversed().prefix { $0.isWhitespace }.contains("\n")
        let sentenceStart = previous == nil || afterNewline || ".!?".contains(previous!)
        if sentenceStart {
            text = text.prefix(1).uppercased() + text.dropFirst()
        } else if shouldLowercase(text) {
            text = text.prefix(1).lowercased() + text.dropFirst()
        }
        let next = after.first { !$0.isWhitespace }
        // Mid-sentence insert: drop the full stop the model added at the end of the chunk.
        if let next, (next.isLetter && next.isLowercase) || ",.;:!?".contains(next), text.hasSuffix("."), !text.hasSuffix("..") {
            text.removeLast()
        }
        let startsWithPunctuation = text.first.map { ",.;:!?)".contains($0) } ?? false
        if let last = before.last, !last.isWhitespace, !startsWithPunctuation, last != "(" {
            text = " " + text
        }
        if let first = after.first, !first.isWhitespace, !",.;:!?)".contains(first) {
            text += " "
        }
        return text
    }

    /// Lowercase a leading capital only for ordinary words ("Kot" → "kot"), not "I", "PR" or "Claude".
    nonisolated private static func shouldLowercase(_ text: String) -> Bool {
        let word = text.prefix { $0.isLetter }
        guard let first = word.first, first.isUppercase else { return false }
        if word == "I" { return false }
        if word.count > 1, word.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return !properNouns.contains(String(word))
    }

    /// Filled from the vocabulary so dictated names keep their capital letter.
    nonisolated(unsafe) static var properNouns: Set<String> = []

    // MARK: Size

    func textDidChange(_ notification: Notification) { updateSize() }

    private func updateSize() {
        let font = textView.font ?? .systemFont(ofSize: 14)
        let lines = textView.string.components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(max(ceil(longest) + Self.inset.width * 2 + 24, Self.minWidth), Self.maxWidth)
        textView.textContainer?.containerSize = NSSize(width: width - Self.inset.width * 2, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        var used: CGFloat = 18
        if let container = textView.textContainer, let manager = textView.layoutManager {
            manager.ensureLayout(for: container)
            used = max(manager.usedRect(for: container).height, 18)
        }
        let screenHeight = (NSScreen.main?.visibleFrame.height ?? 800)
        let height = min(ceil(used) + Self.inset.height * 2, screenHeight * 0.45)
        let newSize = CGSize(width: width, height: height)
        guard abs(newSize.width - size.width) > 0.5 || abs(newSize.height - size.height) > 0.5 else { return }
        size = newSize
        onSizeChange(newSize)
    }
}

struct LiveEditorView: NSViewRepresentable {
    let controller: LiveEditorController
    func makeNSView(context: Context) -> NSScrollView { controller.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
