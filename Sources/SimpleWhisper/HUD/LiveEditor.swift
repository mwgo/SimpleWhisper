import AppKit
import SwiftUI

/// The editable text area shown under the HUD capsule in Live typing mode.
/// Dictated text appears at the caret: a chunk's spot is remembered as a position (no marker in the
/// text), shown greyed while previewed and written normally once transcribed, so the user can keep
/// moving the caret and typing while transcription runs.
@MainActor
final class LiveEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 560
    private static let inset = NSSize(width: 10, height: 8)

    let scrollView: NSScrollView
    let textView: NSTextView
    private(set) var size = CGSize(width: minWidth, height: 36)
    /// Called after the preferred size changed.
    var onSizeChange: (CGSize) -> Void = { _ in }
    var inkColor: NSColor = .labelColor { didSet { applyColors() } }
    /// On glass a faint shadow keeps the text readable over bright content behind the HUD.
    var textShadow = false { didSet { applyColors() } }
    /// The user clicked, moved the caret or typed (not our own insertions).
    var onUserEdit: () -> Void = {}
    /// Called after every programmatic change (previews, final chunks), to mirror the text elsewhere.
    var onContentChange: () -> Void = {}
    /// Leading and trailing characters that are only context from the target app (text around its caret), not dictation.
    private var contextLength = 0
    private var suffixLength = 0
    private var programmaticChange = false

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
        textView.textStorage?.delegate = self
        applyColors()
    }

    private var normalAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: inkColor]
        if textShadow {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 2.5
            shadow.shadowOffset = .zero
            attributes[.shadow] = shadow
        }
        return attributes
    }

    private func applyColors() {
        textView.textColor = inkColor
        textView.insertionPointColor = inkColor
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttributes(normalAttributes, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes = normalAttributes
        textView.selectedTextAttributes = [.backgroundColor: inkColor.withAlphaComponent(0.22)]
    }

    func reset() {
        programmaticChange = true
        defer { programmaticChange = false }
        textView.isEditable = true
        textView.string = ""
        anchors = [:]
        contextLength = 0
        suffixLength = 0
        textView.undoManager?.removeAllActions()
        textView.typingAttributes = normalAttributes
        updateSize()
    }

    /// Replaces the whole content (result card), caret at the end.
    func setText(_ text: String) {
        programmaticChange = true
        defer { programmaticChange = false }
        textView.isEditable = true
        anchors = [:]
        contextLength = 0
        suffixLength = 0
        textView.string = text
        textView.textStorage?.setAttributes(normalAttributes, range: NSRange(location: 0, length: (text as NSString).length))
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.typingAttributes = normalAttributes
        updateSize()
    }

    func focus() {
        textView.window?.makeFirstResponder(textView)
    }

    /// Editor text without greyed previews that are still waiting for their final transcription.
    var text: String {
        let result = NSMutableString(string: textView.string)
        for range in anchors.values.sorted(by: { $0.location > $1.location }) where range.length > 0 {
            result.replaceCharacters(in: range, with: "")
        }
        return (result as String).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasPendingChunks: Bool { !anchors.isEmpty }

    /// Surrounds the caret with the target app's text, so chunks get the right spaces and capitalisation;
    /// the context is never part of `dictation`.
    func seedContext(before: String, after: String) {
        guard let storage = textView.textStorage else { return }
        // Pending chunks keep their place inside the dictation while the context around it is replaced.
        let relative = anchors.mapValues { NSRange(location: $0.location - contextLength, length: $0.length) }
        programmaticChange = true
        defer { programmaticChange = false }
        storage.replaceCharacters(in: NSRange(location: storage.length - suffixLength, length: suffixLength),
                                  with: NSAttributedString(string: after, attributes: normalAttributes))
        storage.replaceCharacters(in: NSRange(location: 0, length: contextLength),
                                  with: NSAttributedString(string: before, attributes: normalAttributes))
        contextLength = (before as NSString).length
        suffixLength = (after as NSString).length
        anchors = relative.mapValues { NSRange(location: $0.location + contextLength, length: $0.length) }
        textView.setSelectedRange(NSRange(location: storage.length - suffixLength, length: 0))
    }

    /// Dictated text between the context, previews included, as shown in the target app while dictating.
    var shownDictation: String { between(textView.string as NSString) }

    /// Dictated text between the context without pending previews, with its fitted spaces.
    var dictation: String {
        let result = NSMutableString(string: textView.string)
        for range in anchors.values.sorted(by: { $0.location > $1.location }) where range.length > 0 {
            result.replaceCharacters(in: range, with: "")
        }
        return between(result)
    }

    private func between(_ string: NSString) -> String {
        let start = min(contextLength, string.length)
        return string.substring(with: NSRange(location: start, length: max(0, string.length - suffixLength - start)))
    }

    /// Moves the finished start of the dictation (up to the first chunk still waiting for its final text)
    /// into the context and returns it.
    func takeFinished() -> String {
        let storage = textView.string as NSString
        let end = anchors.values.map(\.location).min() ?? storage.length - suffixLength
        guard end > contextLength else { return "" }
        let finished = storage.substring(with: NSRange(location: contextLength, length: end - contextLength))
        contextLength = end
        return finished
    }

    /// Everything so far was committed in the target app: it becomes context. Chunks whose preview is
    /// already in the app are forgotten; those not shown yet will land at the caret.
    func freeze() {
        contextLength = (textView.string as NSString).length - suffixLength
        anchors = anchors.filter { $0.value.length == 0 }.mapValues { _ in NSRange(location: contextLength, length: 0) }
        textView.setSelectedRange(NSRange(location: contextLength, length: 0))
    }

    /// Marks the caret as the spot where the next dictated chunk lands and returns its id.
    /// Nothing is inserted; a selection is removed so the dictation replaces it.
    func insertPlaceholder() -> String {
        let id = UUID().uuidString
        let selection = textView.selectedRange()
        if selection.length > 0 {
            replace(selection, with: NSAttributedString(string: ""), anchor: nil)
        }
        anchors[id] = NSRange(location: textView.selectedRange().location, length: 0)
        return id
    }

    /// Writes the final transcription at the chunk's spot, fixing spacing and capitalisation.
    func resolve(_ id: String, with chunk: String) {
        guard let range = anchors.removeValue(forKey: id) else { return }
        let fitted = fitted(chunk, replacing: range)
        guard range.length > 0 || !fitted.isEmpty else { return }
        replace(range, with: NSAttributedString(string: fitted, attributes: normalAttributes), anchor: nil)
    }

    func drop(_ id: String) { resolve(id, with: "") }

    /// Shows a provisional transcription at the chunk's spot (greyed, replaced by later previews).
    func preview(_ id: String, with chunk: String) {
        guard let range = anchors[id] else { return }
        let fitted = fitted(chunk, replacing: range)
        var attributes = normalAttributes
        attributes[.foregroundColor] = inkColor.withAlphaComponent(0.5)
        replace(range, with: NSAttributedString(string: fitted, attributes: attributes), anchor: id)
    }

    private func fitted(_ chunk: String, replacing range: NSRange) -> String {
        let storage = textView.string as NSString
        return Self.fit(chunk, before: storage.substring(to: range.location), after: storage.substring(from: NSMaxRange(range)))
    }

    // MARK: Text surgery

    /// Where each pending chunk's text goes: length 0 until its first preview, then the preview's range.
    private var anchors: [String: NSRange] = [:]
    /// The anchor being rewritten by `replace`, which the edit tracking below must leave alone.
    private var rewritingAnchor: String?

    private func replace(_ range: NSRange, with string: NSAttributedString, anchor id: String?) {
        guard let storage = textView.textStorage else { return }
        programmaticChange = true
        rewritingAnchor = id
        defer { programmaticChange = false; rewritingAnchor = nil }
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: range, replacementString: string.string) else { return }
        storage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        if let id { anchors[id] = NSRange(location: range.location, length: string.length) }
        let delta = string.length - range.length
        // A caret at (or after) the chunk's spot moves along, so text appears where the caret is.
        if selection.location >= NSMaxRange(range) {
            textView.setSelectedRange(NSRange(location: selection.location + delta, length: selection.length))
        } else if selection.location > range.location {
            textView.setSelectedRange(NSRange(location: range.location + string.length, length: 0))
        }
        textView.typingAttributes = normalAttributes
        textView.scrollRangeToVisible(textView.selectedRange())
        updateSize()
        onContentChange()
    }

    /// Keeps the pending spots in place while the text before them changes (typing, pasting, other chunks).
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            let start = editedRange.location
            let oldEnd = NSMaxRange(editedRange) - delta
            for (id, anchor) in anchors where id != rewritingAnchor {
                if oldEnd <= anchor.location, !(anchor.length == 0 && start == anchor.location && oldEnd == start) {
                    anchors[id] = NSRange(location: max(0, anchor.location + delta), length: anchor.length)
                } else if start >= NSMaxRange(anchor) {
                    continue
                } else {
                    // An edit inside a preview: keep the spot, resize it with the edit.
                    let location = min(anchor.location, start)
                    anchors[id] = NSRange(location: location, length: max(0, NSMaxRange(anchor) + delta - location))
                }
            }
        }
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

    func textDidChange(_ notification: Notification) {
        updateSize()
        if !programmaticChange { onUserEdit() }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // AppKit copies the attributes of the character before the caret; right after a greyed preview
        // typed or pasted text would come out grey.
        textView.typingAttributes = normalAttributes
        if !programmaticChange { onUserEdit() }
    }

    /// Inserts the clipboard text at the caret (replacing a selection), like ⌘V.
    func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { NSSound.beep(); return }
        focus()
        let range = textView.selectedRange()
        let storage = textView.string as NSString
        var inserted = text
        if let last = storage.substring(to: range.location).last, !last.isWhitespace, last != "(",
           let first = text.first, !first.isWhitespace, !",.;:!?)".contains(first) {
            inserted = " " + inserted
        }
        if let next = storage.substring(from: NSMaxRange(range)).first, !next.isWhitespace, !",.;:!?)".contains(next),
           let end = text.last, !end.isWhitespace {
            inserted += " "
        }
        textView.typingAttributes = normalAttributes
        textView.insertText(inserted, replacementRange: range)
    }

    /// Undoes a scroll made while the frame was still smaller than the text, once everything fits.
    func scrollToTopIfFits() {
        let clip = scrollView.contentView
        guard clip.bounds.origin.y != 0, textView.frame.height <= clip.bounds.height + 1 else { return }
        clip.scroll(to: .zero)
        scrollView.reflectScrolledClipView(clip)
    }

    private func updateSize() {
        let font = textView.font ?? .systemFont(ofSize: 14)
        let lines = textView.string.components(separatedBy: "\n")
        let longest = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let width = min(max(ceil(longest) + Self.inset.width * 2 + 24, Self.minWidth), Self.maxWidth)
        // Measure at the target width, not the text view's current one (it only resizes after the
        // HUD's layout pass, so a fresh card would otherwise be measured as a single long line).
        let padding = (textView.textContainer?.lineFragmentPadding ?? 5) * 2
        let measured = (textView.textStorage ?? NSTextStorage(string: textView.string)).boundingRect(
            with: NSSize(width: width - Self.inset.width * 2 - padding, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let trailingNewline = textView.string.hasSuffix("\n") ? (font.ascender - font.descender + font.leading) : 0
        let used = max(ceil(measured.height + trailingNewline), 18)
        let screenHeight = (NSScreen.main?.visibleFrame.height ?? 800)
        let fullHeight = ceil(used) + Self.inset.height * 2
        let height = min(fullHeight, screenHeight * 0.45)
        if fullHeight <= height {
            DispatchQueue.main.async { [weak self] in self?.scrollToTopIfFits() }
        }
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
