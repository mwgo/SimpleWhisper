import AppKit

/// Shown when there is no text field to paste into: the result stays in the clipboard and is
/// presented in an editable text view, fully selected.
@MainActor
final class ResultWindowController: NSObject {
    private var window: NSWindow?
    private var textView: NSTextView?

    func show(text: String) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SimpleWhisper"
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]

            let scroll = NSTextView.scrollableTextView()
            let textView = scroll.documentView as! NSTextView
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 14)
            textView.textContainerInset = NSSize(width: 12, height: 12)
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.allowsUndo = true
            self.textView = textView

            let hint = NSTextField(labelWithString: "No text field was active, so the text was not pasted. It is in the clipboard; edit it here if needed.")
            hint.font = .systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 2

            let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
            copyButton.bezelStyle = .rounded
            let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
            closeButton.bezelStyle = .rounded
            closeButton.keyEquivalent = "\u{1b}"
            copyButton.keyEquivalent = "\r"

            let buttons = NSStackView(views: [NSView(), closeButton, copyButton])
            buttons.orientation = .horizontal
            buttons.spacing = 8
            let stack = NSStackView(views: [scroll, hint, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
            stack.translatesAutoresizingMaskIntoConstraints = false
            hint.setContentHuggingPriority(.required, for: .vertical)
            buttons.setContentHuggingPriority(.required, for: .vertical)

            let content = NSView()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
                hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            ])
            window.contentView = content
            window.center()
            self.window = window
        }
        textView?.string = text
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(textView)
        textView?.selectAll(nil)
    }

    @objc private func copyText() {
        guard let textView else { return }
        let selected = textView.selectedRange().length > 0 ? (textView.string as NSString).substring(with: textView.selectedRange()) : textView.string
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(selected, forType: .string)
    }

    @objc private func closeWindow() {
        window?.orderOut(nil)
    }

    var windowNumber: Int { window?.windowNumber ?? 0 }
}
