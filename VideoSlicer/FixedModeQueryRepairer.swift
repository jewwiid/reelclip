// Apple Intelligence text repair for Fixed mode. iOS 26+ only — gracefully
// returns nil on older devices so callers can hide the "Repair" affordance.
//
// The Foundation Models framework takes the user's free-form text (which
// often has typos, off-by-one words, weird ordering) and rewrites it into a
// clean phrase that `ClipQueryParser` accepts. We constrain output via
// `@Generable` so the model has a single string field to fill in.

import Foundation
import FoundationModels

@available(iOS 26, *)
@Generable
struct RepairedClipRecipe {
    @Guide(description: "A clean, parseable recipe for the clip planner. Examples: '4 five-second clips cut every 10 seconds', '3 clips of 8 seconds every 15 seconds'. Must include a count (clips), a duration per clip in seconds, and an interval (cut every N seconds).")
    var text: String
}

@available(iOS 26, *)
struct FixedModeQueryRepairer {
    enum RepairError: LocalizedError {
        case modelUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .modelUnavailable(let reason):
                return "Apple Intelligence isn't available: \(reason)"
            }
        }
    }

    /// Returns a clean recipe phrase (or nil if the model declined to
    /// produce one). `nil` is a soft failure — the UI shows a generic
    /// "couldn't repair" hint. A thrown error is a hard failure (model
    /// unavailable, network, etc.).
    func repair(_ raw: String) async throws -> String? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let session = LanguageModelSession(
            instructions: """
            You rewrite free-form video clip recipes into a single clean
            phrase the parser will accept. The parser recognises:
              - clip count (one of: 1, 2, 3, … 50) — keywords "N clips" / "N cuts" / "make N"
              - per-clip duration in seconds (1 to 120) — keywords like "five-second clips" / "8s clips" / "10 sec each"
              - interval in seconds (1 to 300) — keywords like "every 10 seconds" / "with 10s gap" / "10s apart"
            The output is a single short phrase like:
              "4 five-second clips cut every 10 seconds"
              "3 clips of 8 seconds every 15 seconds"
            Keep numbers as digits. Preserve the user's intent. If the
            input is too vague to repair (e.g. just "make clips"), produce
            a sensible default like "3 five-second clips cut every 5 seconds".
            Do not add explanations or any text besides the phrase itself.
            """
        )

        // A recipe is expected to be short. Bound pasted text so an
        // accidental long paste cannot exhaust the on-device context.
        let boundedRaw = String(raw.prefix(1_000))
        let prompt = """
        Rewrite this clip recipe: "\(boundedRaw)"
        """

        let response = try await session.respond(to: prompt, generating: RepairedClipRecipe.self)
        let repaired = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sanity guard: the model might return the same input verbatim if
        // it can't decide what to change. Only return a value if it's
        // different and looks reasonable.
        guard !repaired.isEmpty, repaired != raw.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        return repaired
    }
}
