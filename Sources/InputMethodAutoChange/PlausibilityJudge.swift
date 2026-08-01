import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum CandidateLanguage {
    case korean
    case english
}

enum PlausibilityVerdict {
    case plausible
    case implausible
    /// The model couldn't be consulted (Apple Intelligence disabled,
    /// unsupported device, still downloading, etc). Callers should fall back
    /// to the Tier-1 deterministic verdict rather than block on this.
    case unavailable
}

/// Tier 2 of the decision pipeline. Kept behind a protocol so
/// `DecisionEngine`'s branching logic is unit-testable without touching
/// Apple Intelligence or FoundationModels at all.
protocol PlausibilityJudge {
    func judge(candidate: String, language: CandidateLanguage) async -> PlausibilityVerdict
}

#if canImport(FoundationModels)
/// Production `PlausibilityJudge` backed by Apple's on-device Foundation
/// Model. Degrades to `.unavailable` whenever the model isn't usable so the
/// rest of the pipeline can fall back to the Tier-1 verdict — see the plan's
/// flagged risk around on-device Korean-language judgment quality, which
/// should be evaluated empirically before leaning on this heavily for the
/// Korean-target direction.
///
/// Uses the plain string `respond(to:)` form with a strict yes/no prompt
/// rather than a `@Generable` struct: the `@Generable`/`@Guide` macros need
/// their macro plugin resolved via a full Xcode install, which isn't
/// available in a Command Line Tools-only environment. Manual parsing here
/// avoids that dependency; revisit if a `@Generable` verdict type would be
/// more robust once building with full Xcode.
@available(macOS 26.0, *)
final class FoundationModelsJudge: PlausibilityJudge {
    func judge(candidate: String, language: CandidateLanguage) async -> PlausibilityVerdict {
        // Candidates this short carry almost no signal for a yes/no judgment
        // call, and empirically the on-device model tends to wave them
        // through -- reject without spending a model call. Any short string
        // that's actually a real word would already have been caught by the
        // Tier-1 dictionary check, so this never costs us a true positive.
        guard candidate.count >= 3 else {
            return .implausible
        }

        guard case .available = SystemLanguageModel.default.availability else {
            return .unavailable
        }

        let languageName = language == .korean ? "Korean" : "English"
        // Explicit strictness + a forced tie-break toward "no": the model is
        // small and on-device, and a false *accept* here silently replaces
        // text the user actually meant to type, which is far more disruptive
        // than a false reject (worst case: it just doesn't autocorrect).
        // Kept short in both instructions and expected output -- generation
        // time scales with token count, and this is on the critical path of
        // every correction.
        let prompt = """
            Is "\(candidate)" a real, correctly-spelled \(languageName) word or common proper \
            noun? Answer "no" if you are not confident. Reply only yes or no.
            """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(
                to: prompt,
                options: GenerationOptions(maximumResponseTokens: 3)
            )
            let answer = response.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if answer.hasPrefix("yes") { return .plausible }
            if answer.hasPrefix("no") { return .implausible }
            return .unavailable
        } catch {
            return .unavailable
        }
    }
}
#endif
