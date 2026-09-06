import AppKit
import WebKit

/// Shown when there is no text field to paste into. Markdown-looking text is rendered; the source
/// stays editable behind a Rendered/Source switch. Nothing is copied automatically (use Copy).
@MainActor
final class ResultWindowController: NSObject, WKNavigationDelegate {
    private var window: NSWindow?
    private var textView: NSTextView?
    private var scrollView: NSScrollView?
    private var webView: WKWebView?
    private var modeControl: NSSegmentedControl?
    private var hint: NSTextField?
    private var sourceText = ""
    private var isMarkdown = false

    func show(text: String) {
        buildWindowIfNeeded()
        sourceText = text
        isMarkdown = MarkdownRenderer.looksLikeMarkdown(text)
        modeControl?.isHidden = !isMarkdown
        modeControl?.selectedSegment = 0
        hint?.stringValue = isMarkdown
            ? "Rendered as Markdown; switch to Source to edit. Copy puts the source in the clipboard."
            : "Nothing was pasted. Edit the text here and use Copy when you need it."
        applyMode()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyMode() {
        guard let textView else { return }
        let rendered = isMarkdown && modeControl?.selectedSegment == 0
        webView?.isHidden = !rendered
        scrollView?.isHidden = rendered
        if rendered {
            webView?.loadHTMLString(MarkdownRenderer.html(from: sourceText), baseURL: nil)
        } else {
            textView.textStorage?.setAttributedString(NSAttributedString(string: sourceText, attributes: [
                .font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
            ]))
            textView.isEditable = true
            window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0, let textView, textView.isEditable {
            sourceText = textView.string   // leaving Source: keep edits
        }
        applyMode()
    }

    @objc private func copyText() {
        guard let textView else { return }
        let text = textView.isEditable ? textView.string : sourceText
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @objc private func closeWindow() {
        window?.orderOut(nil)
    }

    var windowNumber: Int { window?.windowNumber ?? 0 }

    /// Open links in the default browser instead of navigating inside the result view.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
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
        textView.isSelectable = true
        self.textView = textView
        self.scrollView = scroll

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        self.webView = webView

        let pages = NSView()
        pages.translatesAutoresizingMaskIntoConstraints = false
        for view in [scroll, webView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pages.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pages.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pages.trailingAnchor),
                view.topAnchor.constraint(equalTo: pages.topAnchor),
                view.bottomAnchor.constraint(equalTo: pages.bottomAnchor),
            ])
        }
        webView.wantsLayer = true
        webView.layer?.cornerRadius = 6
        webView.layer?.masksToBounds = true

        let mode = NSSegmentedControl(labels: ["Rendered", "Source"], trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        mode.selectedSegment = 0
        mode.controlSize = .small
        self.modeControl = mode

        let hint = NSTextField(wrappingLabelWithString: "")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.isSelectable = false
        self.hint = hint

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyText))
        copyButton.bezelStyle = .rounded
        let closeButton = NSButton(title: "Close", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\u{1b}"

        let bottom = NSStackView(views: [mode, NSView(), closeButton, copyButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        let stack = NSStackView(views: [pages, hint, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        hint.setContentHuggingPriority(.required, for: .vertical)
        bottom.setContentHuggingPriority(.required, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            pages.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            bottom.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        window.contentView = content
        // Remember size and position between launches.
        let frameName = "SimpleWhisperResultWindow"
        if !window.setFrameUsingName(frameName) { window.center() }
        window.setFrameAutosaveName(frameName)
        self.window = window
    }
}
