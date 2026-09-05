import Foundation
import FoundationModels

final class FoundationModelsProcessor: TextProcessor {
    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "Available"
        case .unavailable(let reason):
            return "Unavailable: \(describe(reason))"
        }
    }

    static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "this Mac is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence is turned off in System Settings"
        case .modelNotReady: return "the model is still downloading, try again later"
        @unknown default: return "unknown reason"
        }
    }

    func process(text: String, instructions: String) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw ProcessingError.unavailable(Self.describe(reason))
        }
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response: LanguageModelSession.Response<String>
        do {
            response = try await session.respond(to: text)
        } catch let error as LanguageModelSession.GenerationError {
            if case .unsupportedLanguageOrLocale = error {
                throw ProcessingError.unavailable("Apple Intelligence does not support this language (e.g. Polish). Use a shell-command prompt such as claude -p instead.")
            }
            throw error
        }
        let output = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw ProcessingError.emptyOutput }
        return output
    }
}
