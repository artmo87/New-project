import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Availability wrapper (safe on every iOS version)

/// Wrapper that is safe to reference on any iOS version.
enum OnDeviceModelSupport {
    /// True only on iOS 26+ with Apple Intelligence available right now.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return true
            default:
                return false
            }
            #else
            return false
            #endif
        } else {
            return false
        }
    }

    /// Short user-facing status, e.g. "Available", "Not supported on this iPhone",
    /// "Turn on Apple Intelligence in Settings", "Model is still downloading".
    static var statusDescription: String {
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                return "Available"
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "Not supported on this iPhone"
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in Settings"
                case .modelNotReady:
                    return "Model is still downloading"
                default:
                    return "Unavailable"
                }
            default:
                return "Unavailable"
            }
            #else
            return "Not included in this build"
            #endif
        } else {
            return "Requires iOS 26"
        }
    }
}

#if canImport(FoundationModels)

// MARK: - Structured output

/// What we ask the on-device model to produce in its final, structured pass.
@available(iOS 26.0, *)
@Generable
fileprivate struct ModelDigest {
    @Guide(description: "A warm summary of the session in two to four sentences, addressed to the person as 'you'.")
    var overview: String

    @Guide(description: "Three to six short bullet points about what was discussed, each under 25 words.")
    var highlights: [String]

    @Guide(description: "Three to five gentle, practical suggestions for the coming week, each under 25 words.")
    var suggestions: [String]

    @Guide(description: "Two to four questions worth bringing to the next session, each under 25 words.")
    var questionsForNextSession: [String]

    @Guide(description: "Things the person said they would do or try, paraphrased briefly, each under 25 words. Empty if there were none.")
    var detectedCommitments: [String]
}

// MARK: - Engine

/// Enriches the Classic insights with Apple's on-device foundation model.
/// Only compiled when the FoundationModels framework is present and only usable on iOS 26+.
@available(iOS 26.0, *)
struct FoundationModelsInsightEngine {

    enum EngineError: LocalizedError {
        case modelUnavailable
        case transcriptTooShort
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                return "The on-device model isn't available right now."
            case .transcriptTooShort:
                return "The transcript is too short for the on-device model to add anything."
            case .emptyResponse:
                return "The on-device model didn't return anything usable."
            }
        }
    }

    // Tuning. The model's context window is about 4,096 tokens for prompt + answer,
    // so every single call stays comfortably under ~1,500 words of material.
    private static let minimumWords = 30
    private static let singlePassWordLimit = 1500
    private static let chunkWordTarget = 1200
    private static let notesWordLimit = 1400
    private static let retryWordLimit = 700
    private static let maxCondenseRounds = 3

    private static let modelRationale = "Suggested by the on-device model from this session's transcript."

    private static let practiceKeywords = ["try", "practice", "write", "schedule", "breath", "walk", "exercise", "set", "plan"]

    private static let bulletCharacters: Set<Character> = ["-", "•", "*", "–", "—", "·", "◦", "▪"]

    private static let instructions = """
        You are a supportive, non-clinical assistant helping someone reflect on their own therapy session. The person recorded the session themselves and reads your notes privately.
        Write in the second person ("you"), warm and plain, like a thoughtful friend taking notes.
        Never diagnose, never label the person with a condition, never give medical or medication advice, and never judge or criticize the therapist.
        Stay grounded in what was actually said. Do not invent events, names or details.
        Keep each list item under 25 words. Keep the overview to two to four sentences.
        Write in the language of the transcript when it is one you support; otherwise write in English.
        If the text contains thoughts of self-harm or suicide, respond with care: acknowledge it gently and suggest reaching out to a crisis line or someone trusted, without alarm.
        """

    init() {}

    /// Produces an enriched copy of `base` (the Classic insights for the same session):
    /// replaces overview/highlights, merges suggestions (model suggestions first, keep
    /// base's .pattern suggestions), merges questions, and sets engine = .onDeviceModel.
    /// Throws on any model error; the caller falls back to `base`.
    func enrich(base: SessionInsights, session: TherapySession) async throws -> SessionInsights {
        try await enrich(base: base, session: session, progress: nil)
    }

    /// Same as `enrich(base:session:)` but reports short human-readable progress strings
    /// (e.g. "Reading part 2 of 5…"). `progress` may be called from any thread.
    func enrich(base: SessionInsights,
                session: TherapySession,
                progress: ((String) -> Void)?) async throws -> SessionInsights {
        guard OnDeviceModelSupport.isAvailable else { throw EngineError.modelUnavailable }

        let words = Self.transcriptWords(for: session)
        guard words.count >= Self.minimumWords else { throw EngineError.transcriptTooShort }

        let durationPhrase = Self.durationPhrase(for: session)
        let material: String
        let isTranscript: Bool

        if words.count <= Self.singlePassWordLimit {
            // Short enough to hand over in one go.
            material = words.joined(separator: " ")
            isTranscript = true
        } else {
            // Long session: take notes chunk by chunk, then condense if needed.
            let chunks = Self.chunks(of: words, targetSize: Self.chunkWordTarget)
            var notes: [String] = []
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                progress?("Reading part \(index + 1) of \(chunks.count)…")
                let modelSession = LanguageModelSession(instructions: Self.instructions)
                let prompt = Self.notesPrompt(part: index + 1, of: chunks.count, text: chunk.joined(separator: " "))
                let response = try await modelSession.respond(to: prompt)
                let cleaned = Self.cleanedNotes(response.content)
                if !cleaned.isEmpty {
                    notes.append(cleaned)
                }
            }
            guard !notes.isEmpty else { throw EngineError.emptyResponse }
            notes = try await condenseIfNeeded(notes, progress: progress)
            material = notes.joined(separator: "\n")
            isTranscript = false
        }

        progress?("Writing your summary…")
        let digest = try await requestDigest(material: material, isTranscript: isTranscript, durationPhrase: durationPhrase)
        return try Self.merge(digest: digest, into: base)
    }

    // MARK: Model calls

    /// Folds long note collections down until they fit comfortably in one prompt.
    private func condenseIfNeeded(_ notes: [String], progress: ((String) -> Void)?) async throws -> [String] {
        var current = notes
        var rounds = 0
        while Self.totalWordCount(of: current) > Self.notesWordLimit && rounds < Self.maxCondenseRounds {
            rounds += 1
            progress?("Pulling the notes together…")
            let batches = Self.batches(of: current, wordLimit: Self.chunkWordTarget)
            var condensed: [String] = []
            for batch in batches {
                try Task.checkCancellation()
                let modelSession = LanguageModelSession(instructions: Self.instructions)
                let prompt = Self.condensePrompt(text: batch.joined(separator: "\n"))
                let response = try await modelSession.respond(to: prompt)
                let cleaned = Self.cleanedNotes(response.content)
                if !cleaned.isEmpty {
                    condensed.append(cleaned)
                }
            }
            if condensed.isEmpty {
                break
            }
            current = condensed
        }
        if Self.totalWordCount(of: current) > Self.notesWordLimit {
            // Last resort: keep the earliest notes so the prompt still fits.
            let joined = current.joined(separator: "\n")
            current = [Self.truncated(joined, toWords: Self.notesWordLimit)]
        }
        return current
    }

    /// The final structured call. Retries once with less material if the first attempt fails
    /// (most often because the prompt was too long for the model's context window).
    private func requestDigest(material: String, isTranscript: Bool, durationPhrase: String) async throws -> ModelDigest {
        try Task.checkCancellation()
        let prompt = Self.digestPrompt(material: material, isTranscript: isTranscript, durationPhrase: durationPhrase)
        do {
            let modelSession = LanguageModelSession(instructions: Self.instructions)
            let response = try await modelSession.respond(to: prompt, generating: ModelDigest.self)
            return response.content
        } catch {
            guard Self.wordCount(in: material) > Self.retryWordLimit else { throw error }
            try Task.checkCancellation()
            let shorter = Self.truncated(material, toWords: Self.retryWordLimit)
            let retryPrompt = Self.digestPrompt(material: shorter, isTranscript: isTranscript, durationPhrase: durationPhrase)
            let modelSession = LanguageModelSession(instructions: Self.instructions)
            let response = try await modelSession.respond(to: retryPrompt, generating: ModelDigest.self)
            return response.content
        }
    }

    // MARK: Prompts

    private static func notesPrompt(part: Int, of total: Int, text: String) -> String {
        """
        Here is part \(part) of \(total) of a therapy session transcript. Write 3 to 6 concise bullet notes about this part only: the topics that came up, the feelings expressed, any realizations, and anything the person agreed to try. Address the person as "you". Start each note with "- ".

        \(text)
        """
    }

    private static func condensePrompt(text: String) -> String {
        """
        Below are notes taken, in order, from a long therapy session. Condense them into 6 to 8 bullet notes that keep the most important topics, feelings, realizations and commitments. Address the person as "you". Start each note with "- ".

        \(text)
        """
    }

    private static func digestPrompt(material: String, isTranscript: Bool, durationPhrase: String) -> String {
        let source: String
        let label: String
        if isTranscript {
            source = "Here is the transcript of a therapy session\(durationPhrase)."
            label = "Transcript"
        } else {
            source = "Here are notes taken, in order, from a therapy session\(durationPhrase)."
            label = "Notes"
        }
        return """
        \(source) Using only this material, prepare the person's private session digest: a warm overview of two to four sentences addressed to them as "you", three to six highlights of what was discussed, three to five practical suggestions for the coming week, two to four questions worth bringing to the next session, and any commitments they made (leave that list empty if there were none).

        \(label):
        \(material)
        """
    }

    private static func durationPhrase(for session: TherapySession) -> String {
        let minutes = Int((session.duration / 60).rounded())
        guard minutes >= 1 else { return "" }
        return minutes == 1 ? " that lasted about 1 minute" : " that lasted about \(minutes) minutes"
    }

    // MARK: Merging

    private static func merge(digest: ModelDigest, into base: SessionInsights) throws -> SessionInsights {
        let overview = cleanedParagraph(digest.overview)
        let highlights = cleanedList(digest.highlights, cap: 7)
        let suggestionTexts = cleanedList(digest.suggestions, cap: 6)
        let questions = cleanedList(digest.questionsForNextSession, cap: 6).map { asQuestion($0) }
        let commitments = cleanedList(digest.detectedCommitments, cap: 8)

        guard !overview.isEmpty || !highlights.isEmpty || !suggestionTexts.isEmpty || !questions.isEmpty else {
            throw EngineError.emptyResponse
        }

        var result = base
        result.engine = .onDeviceModel
        result.generatedAt = Date()

        if !overview.isEmpty {
            result.overview = overview
        }
        if !highlights.isEmpty {
            result.highlights = highlights
        }

        // Suggestions: model first, then Classic's cross-session patterns, then a few Classic extras.
        let modelSuggestions = suggestionTexts.map { suggestion(from: $0) }
        if modelSuggestions.isEmpty {
            result.suggestions = base.suggestions
        } else {
            var merged: [Suggestion] = []
            for item in modelSuggestions where !hasSimilarTitle(item.title, in: merged) {
                merged.append(item)
            }
            for item in base.suggestions where item.category == .pattern && !hasSimilarTitle(item.title, in: merged) {
                merged.append(item)
            }
            var extras = 0
            for item in base.suggestions where item.category != .pattern {
                if extras >= 3 { break }
                if !hasSimilarTitle(item.title, in: merged) {
                    merged.append(item)
                    extras += 1
                }
            }
            result.suggestions = Array(merged.prefix(10))
        }

        // Questions: model first, then Classic's, without near-duplicates.
        var mergedQuestions: [String] = []
        for question in questions {
            appendUnique(question, to: &mergedQuestions)
        }
        for question in base.questionsForNextSession {
            appendUnique(question, to: &mergedQuestions)
        }
        result.questionsForNextSession = Array(mergedQuestions.prefix(6))

        // Commitments: union of both engines.
        var mergedItems: [String] = []
        for item in commitments {
            appendUnique(item, to: &mergedItems)
        }
        for item in base.detectedActionItems {
            appendUnique(item, to: &mergedItems)
        }
        result.detectedActionItems = Array(mergedItems.prefix(8))

        return result
    }

    private static func suggestion(from text: String) -> Suggestion {
        let lower = text.lowercased()
        let isPractice = practiceKeywords.contains { lower.contains($0) }
        return Suggestion(
            category: isPractice ? .practice : .reflection,
            title: title(for: text),
            detail: text,
            rationale: modelRationale
        )
    }

    /// Text up to the first sentence end, shortened to about 70 characters.
    private static func title(for text: String) -> String {
        var candidate = text
        if let stop = text.firstIndex(where: { $0 == "." || $0 == "!" || $0 == "?" }) {
            candidate = String(text[..<stop])
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.isEmpty {
            candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if candidate.count > 70 {
            let cut = candidate.prefix(70)
            if let lastSpace = cut.lastIndex(of: " ") {
                candidate = String(cut[..<lastSpace]) + "…"
            } else {
                candidate = String(cut) + "…"
            }
        }
        return candidate.isEmpty ? "Suggestion" : candidate
    }

    private static func asQuestion(_ text: String) -> String {
        guard let last = text.last else { return text }
        if last == "?" {
            return text
        }
        if last == "." || last == "!" {
            return String(text.dropLast()) + "?"
        }
        return text + "?"
    }

    private static func hasSimilarTitle(_ title: String, in list: [Suggestion]) -> Bool {
        list.contains { isNearDuplicate($0.title, title) }
    }

    private static func appendUnique(_ item: String, to list: inout [String]) {
        guard !list.contains(where: { isNearDuplicate($0, item) }) else { return }
        list.append(item)
    }

    // MARK: Text helpers

    private static func transcriptWords(for session: TherapySession) -> [String] {
        var pieces: [String] = []
        for segment in session.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch segment.speaker {
            case .unknown:
                pieces.append(text)
            case .me:
                pieces.append("You: " + text)
            case .therapist:
                pieces.append("Therapist: " + text)
            }
        }
        return pieces.joined(separator: "\n")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// Splits words into balanced chunks of roughly `targetSize` words.
    private static func chunks(of words: [String], targetSize: Int) -> [[String]] {
        guard !words.isEmpty, targetSize > 0 else { return [] }
        let chunkCount = max(1, Int((Double(words.count) / Double(targetSize)).rounded(.up)))
        let size = max(1, Int((Double(words.count) / Double(chunkCount)).rounded(.up)))
        var result: [[String]] = []
        var start = 0
        while start < words.count {
            let end = min(start + size, words.count)
            result.append(Array(words[start..<end]))
            start = end
        }
        return result
    }

    /// Groups consecutive notes so each group stays under `wordLimit` words.
    private static func batches(of notes: [String], wordLimit: Int) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        var currentWords = 0
        for note in notes {
            let count = wordCount(in: note)
            if !current.isEmpty && currentWords + count > wordLimit {
                result.append(current)
                current = []
                currentWords = 0
            }
            current.append(note)
            currentWords += count
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    private static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func totalWordCount(of notes: [String]) -> Int {
        notes.reduce(0) { $0 + wordCount(in: $1) }
    }

    private static func truncated(_ text: String, toWords limit: Int) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count > limit else { return text }
        return words.prefix(limit).joined(separator: " ")
    }

    /// Turns a free-form model answer into clean "- " bullet lines.
    private static func cleanedNotes(_ raw: String) -> String {
        let lines = raw.split(whereSeparator: { $0.isNewline }).map(String.init)
        var items: [String] = []
        for line in lines {
            if let item = cleanItem(line) {
                appendUnique(item, to: &items)
            }
        }
        return items.map { "- " + $0 }.joined(separator: "\n")
    }

    private static func cleanedList(_ items: [String], cap: Int) -> [String] {
        var result: [String] = []
        for raw in items {
            if let item = cleanItem(raw) {
                appendUnique(item, to: &result)
            }
            if result.count >= cap {
                break
            }
        }
        return result
    }

    private static func cleanedParagraph(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Trims, strips leading bullets/numbering and collapses whitespace. nil if nothing is left.
    private static func cleanItem(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.first, bulletCharacters.contains(first) {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }
        let leadingDigits = text.prefix(while: { $0.isNumber })
        if !leadingDigits.isEmpty && leadingDigits.count <= 2 {
            let rest = text.dropFirst(leadingDigits.count)
            if let separator = rest.first, separator == "." || separator == ")" {
                text = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard collapsed.count >= 3 else { return nil }
        return collapsed
    }

    private static func contentTokens(_ text: String) -> Set<String> {
        let parts = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
        return Set(parts)
    }

    /// Rough semantic de-duplication: high word overlap, or one item contained in the other.
    private static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let tokensA = contentTokens(a)
        let tokensB = contentTokens(b)
        if tokensA.isEmpty || tokensB.isEmpty {
            return a.lowercased() == b.lowercased()
        }
        let shared = tokensA.intersection(tokensB).count
        let combined = tokensA.union(tokensB).count
        if combined > 0 && Double(shared) / Double(combined) >= 0.6 {
            return true
        }
        let smaller = min(tokensA.count, tokensB.count)
        return smaller >= 4 && shared == smaller
    }
}

#endif
