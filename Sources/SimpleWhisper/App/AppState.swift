import Foundation
import Observation

enum DictationPhase: Equatable {
    case idle
    case recording
    case transcribing
    case processing(String)

    var isActive: Bool { self != .idle }

    var title: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing…"
        case .processing(let prompt): return "Processing · \(prompt)"
        }
    }
}

@Observable
@MainActor
final class AppState {
    var phase: DictationPhase = .idle
    var modelStatus: String = "Model not loaded"
    var isModelLoading = false
    var lastText: String = ""
    var lastLanguage: String? = nil
    var lastError: String? = nil
    var hotkeyError: String? = nil
    var hudAnchor: String? = nil

    var lastSummary: String? {
        guard !lastText.isEmpty else { return nil }
        let words = lastText.split(whereSeparator: { $0.isWhitespace }).count
        let language = lastLanguage?.uppercased() ?? "?"
        return "Last: \(language), \(words) words"
    }
}
