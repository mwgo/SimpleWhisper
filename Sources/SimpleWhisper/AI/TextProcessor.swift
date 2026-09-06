import Foundation

enum ProcessingError: LocalizedError {
    case unavailable(String)
    case commandFailed(String)
    case timeout
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return "Apple Intelligence unavailable: \(reason)"
        case .commandFailed(let message): return "Command failed: \(message)"
        case .timeout: return "The AI command timed out."
        case .emptyOutput: return "The AI returned no text."
        }
    }
}

protocol TextProcessor {
    func process(text: String, instructions: String) async throws -> String
}

enum PromptProvider: String, Codable, CaseIterable, Identifiable {
    case appleFoundationModels
    case shell

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appleFoundationModels: return "Apple Intelligence (on-device, no Polish)"
        case .shell: return "Shell command (e.g. claude -p)"
        }
    }
}

struct NamedPrompt: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var instructions: String
    var provider: PromptProvider = .shell
    /// Shell template. `{prompt}` (or `$SW_PROMPT`) receives the instructions, `{tools}` the tool flags
    /// (none, or web tools when allowed in Settings › AI); the text arrives on stdin.
    var shellCommand: String = NamedPrompt.defaultShellCommand

    static let defaultShellCommand = "claude -p --no-session-persistence --model haiku --setting-sources \"\" --disable-slash-commands {tools} --system-prompt {prompt}"
    /// Command mode edits real text, so it defaults to a stronger (slower) model.
    static let defaultCommandShellCommand = "claude -p --no-session-persistence --model opus --setting-sources \"\" --disable-slash-commands {tools} --system-prompt {prompt}"

    init(id: UUID = UUID(), name: String, instructions: String, provider: PromptProvider = .shell, shellCommand: String = NamedPrompt.defaultShellCommand) {
        self.id = id
        self.name = name
        self.instructions = instructions
        self.provider = provider
        self.shellCommand = shellCommand
    }

    static let defaults: [NamedPrompt] = [
        NamedPrompt(name: "Clean up", instructions: "Clean up this dictated text: remove filler words and false starts, fix punctuation and capitalization, keep the meaning and wording otherwise unchanged."),
        NamedPrompt(name: "Formal email", instructions: "Rewrite this dictated text as a short, polite, formal email body. Keep all facts. Do not add a subject line or signature."),
        NamedPrompt(name: "Bullet points", instructions: "Turn this dictated text into concise bullet points, one idea per bullet. Keep all facts."),
        NamedPrompt(name: "Translate to English", instructions: "Translate this text into natural English. Output only the translation."),
    ]
}

enum PromptComposer {
    static func instructions(for prompt: NamedPrompt, vocabulary: [VocabularyTerm], hasMacros: Bool, wantMarkdown: Bool = false) -> String {
        var lines: [String] = [prompt.instructions.trimmingCharacters(in: .whitespacesAndNewlines)]
        lines.append("")
        lines.append("Rules:")
        lines.append("- The input is speech-to-text dictation and may mix Polish and English. Keep the original language unless the task above says to translate.")
        if !vocabulary.isEmpty {
            let terms = vocabulary.map(\.text).joined(separator: ", ")
            lines.append("- Preserve these terms exactly as written: \(terms).")
        }
        if hasMacros {
            lines.append("- Keep every ⟦MACRO:…⟧ placeholder verbatim and in place; it will be replaced later.")
        }
        if wantMarkdown {
            lines.append("- Format the result as well-structured Markdown (headings, lists, emphasis, code blocks where appropriate). It will be displayed rendered.")
        }
        lines.append("- Output only the resulting text. No preamble, no explanations, no quotes around it.")
        return lines.joined(separator: "\n")
    }
}


/// Builds the system instructions for command mode: apply a spoken instruction to selected text.
enum CommandComposer {
    static func instructions(spoken: String, vocabulary: [VocabularyTerm], wantMarkdown: Bool = false) -> String {
        var lines: [String] = [
            "You are a text-editing tool. The user selected a piece of text in an editor and dictated an instruction.",
            "Apply the instruction to the text you receive on input and return ONLY the resulting text.",
            "",
            "Instruction (dictated, may be Polish or English, may contain speech-recognition errors): \(spoken)",
            "",
            "Rules:",
            "- Output only the transformed text, nothing else: no preamble, no explanation, no code fences unless the instruction asks for them.",
            "- Keep the language of the text unless the instruction says to translate.",
            "- Preserve code, identifiers, URLs and formatting that the instruction does not ask to change.",
        ]
        if !vocabulary.isEmpty {
            lines.append("- Preserve these terms exactly: \(vocabulary.map(\.text).joined(separator: ", ")).")
        }
        if wantMarkdown {
            lines.append("- Format the result as well-structured Markdown; it will be displayed rendered, not pasted into an editor.")
        }
        return lines.joined(separator: "\n")
    }
}


/// System instructions for "assistant mode": a dictated question with no selected text.
enum AssistantComposer {
    static func instructions(vocabulary: [VocabularyTerm]) -> String {
        var lines: [String] = [
            "You are a concise assistant. The user dictated a request (Polish or English, possibly with speech-recognition errors) and there is no selected text to edit.",
            "Answer the request directly and helpfully.",
            "",
            "Rules:",
            "- Reply in the language of the request unless asked otherwise.",
            "- Format the answer as a well-structured Markdown document (headings, lists, tables, code blocks where they help). It will be displayed rendered.",
            "- Be concise; no preamble like \"Sure\" or \"Here is\".",
        ]
        if !vocabulary.isEmpty {
            lines.append("- Preserve these terms exactly: \(vocabulary.map(\.text).joined(separator: ", ")).")
        }
        return lines.joined(separator: "\n")
    }
}
