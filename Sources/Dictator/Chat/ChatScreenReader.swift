import CoreGraphics
import Foundation

/// The `read_screen` tool's implementation.
///
/// Reuses the window-vision machinery built for dictation: grab the top-most
/// window that isn't ours, hand it to the resident model, get prose back.
/// `WindowImageCapture` already resolves the top-most *foreign* window rather
/// than the frontmost app's, which is what makes this work from a chat window
/// that is itself frontmost — without it, the tool would return a description
/// of Dictator.
@MainActor
enum ChatScreenReader {
    private static let systemPrompt = """
    You are looking at a screenshot of a window on the user's Mac. Describe what \
    it shows and transcribe any text that matters, exactly as written. Be factual \
    and specific. Do not guess at anything you cannot see.
    """

    /// nil when there was nothing to capture or the loaded model can't see —
    /// the caller turns that into a sentence for the model.
    static func read(question: String? = nil) async -> String? {
        // Whatever this Mac has — Apple's system model on macOS 27, otherwise a
        // vision-capable MLX model. It used to require the latter specifically.
        guard WindowVisionContext.canReadImages else { return nil }
        guard let image = await WindowImageCapture.captureFocusedWindow() else { return nil }

        let ask = (question?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        }
        let userPrompt = ask.map { "Looking at this window: \($0)" }
            ?? "Describe this window and transcribe the text in it."

        do {
            let description = try await WindowVisionContext.readImage(
                image,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 700
            )
            let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            NSLog("[Dictator] Chat read_screen failed: \(error.localizedDescription)")
            return nil
        }
    }
}
