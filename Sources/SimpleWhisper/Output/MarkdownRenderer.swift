import AppKit
import Foundation
import Markdown

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

    /// Converts Markdown (GFM: tables, task lists, strikethrough) to a self-contained HTML page.
    static func html(from markdown: String) -> String {
        let body = HTMLFormatter.format(markdown)
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>
        :root { color-scheme: light dark; }
        body { font: 14px -apple-system, system-ui, sans-serif; line-height: 1.5; margin: 0; padding: 14px 18px;
               color: #1d1d1f; background: #ffffff; -webkit-text-size-adjust: none; }
        @media (prefers-color-scheme: dark) { body { color: #e6e6e6; background: #1e1f22; } }
        h1,h2,h3,h4 { margin: 0.9em 0 0.4em; line-height: 1.25; } h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h3 { font-size: 1.15em; }
        h1:first-child,h2:first-child,h3:first-child,p:first-child { margin-top: 0; }
        p, ul, ol, pre, table, blockquote { margin: 0.5em 0; }
        ul, ol { padding-left: 1.6em; } li + li { margin-top: 0.15em; }
        code { font: 12.5px ui-monospace, Menlo, monospace; background: rgba(127,127,127,0.16); padding: 1px 5px; border-radius: 4px; }
        pre { background: rgba(127,127,127,0.14); padding: 10px 12px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid rgba(127,127,127,0.5); margin-left: 0; padding: 0.1em 0 0.1em 12px; color: rgba(127,127,127,0.95); }
        table { border-collapse: collapse; width: auto; max-width: 100%; display: block; overflow-x: auto; }
        th, td { border: 1px solid rgba(127,127,127,0.35); padding: 5px 10px; text-align: left; vertical-align: top; }
        th { background: rgba(127,127,127,0.14); font-weight: 600; }
        tr:nth-child(even) td { background: rgba(127,127,127,0.06); }
        a { color: #0a84ff; text-decoration: none; } a:hover { text-decoration: underline; }
        hr { border: 0; border-top: 1px solid rgba(127,127,127,0.35); margin: 1em 0; }
        img { max-width: 100%; }
        input[type=checkbox] { vertical-align: middle; margin-right: 6px; }
        </style></head><body>\(body)</body></html>
        """
    }

}
