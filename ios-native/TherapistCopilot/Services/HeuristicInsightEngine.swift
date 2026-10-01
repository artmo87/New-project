import Foundation
import NaturalLanguage

/// The "Classic" insight engine: a rule- and lexicon-based analysis of a session transcript
/// built on Apple's NaturalLanguage framework (sentence/word tokenization, lemmas, sentiment).
/// It is a pure value type with no state, never touches the network, and works on every iPhone.
/// Safe to call from any thread (InsightsService runs it off the main actor).
struct HeuristicInsightEngine {

    /// Pure function: analyzes the session's transcript. `history` = other sessions (newest first)
    /// used for cross-session "pattern" suggestions and recurring-theme detection.
    func analyze(_ session: TherapySession, history: [TherapySession]) -> SessionInsights {
        // Step 14 runs on the raw transcript so that very short sentences are never skipped.
        let needsSupport = HeuristicInsightEngine.detectCrisisLanguage(in: session.transcriptText)

        // Step 1: sentences.
        var sentences = HeuristicInsightEngine.buildSentences(from: session.segments)
        guard !sentences.isEmpty else {
            // Step 15: no usable transcript. The support flag is still honoured for safety.
            var empty = SessionInsights.empty(engine: .classic)
            empty.needsSupportFlag = needsSupport
            return empty
        }

        // Steps 2–3: lemmas and sentiment.
        let corpus = Corpus(sentences: sentences)
        HeuristicInsightEngine.assignLemmas(to: &sentences, corpus: corpus)
        HeuristicInsightEngine.assignSentiment(to: &sentences, corpus: corpus)

        // Keyword signals per sentence (themes, emotions, thinking patterns, commitments, insight phrases).
        let lexiconIndex = LexiconIndex()
        let signals = sentences.map { lexiconIndex.signals(for: $0) }

        // Steps 4–9.
        let themes = HeuristicInsightEngine.selectThemes(sentences: sentences, signals: signals)
        let emotions = HeuristicInsightEngine.selectEmotions(signals: signals)
        let thoughtPatterns = HeuristicInsightEngine.detectThoughtPatterns(sentences: sentences, signals: signals)
        let actionItems = HeuristicInsightEngine.detectActionItems(sentences: sentences, signals: signals)
        let keyMoments = HeuristicInsightEngine.selectKeyMoments(sentences: sentences, signals: signals)
        let highlights = HeuristicInsightEngine.selectHighlights(sentences: sentences, signals: signals)

        // Steps 10–11.
        let sentiments = sentences.map { $0.sentiment }
        let trajectory = HeuristicInsightEngine.moodTrajectory(sentences: sentences, duration: session.duration)
        let overall = HeuristicInsightEngine.rounded(HeuristicInsightEngine.clamp(HeuristicInsightEngine.mean(sentiments)))
        let trend = HeuristicInsightEngine.trend(of: sentiments)
        let overview = HeuristicInsightEngine.composeOverview(
            session: session,
            themes: themes,
            emotions: emotions,
            trend: trend,
            commitmentCount: actionItems.count,
            thoughtPatternCount: thoughtPatterns.count
        )

        // Steps 12–13.
        let suggestions = HeuristicInsightEngine.buildSuggestions(
            themes: themes,
            emotions: emotions,
            thoughtPatterns: thoughtPatterns,
            session: session,
            history: history,
            sentenceCount: sentences.count,
            commitmentCount: actionItems.count
        )
        let questions = HeuristicInsightEngine.nextSessionQuestions(themes: themes, thoughtPatterns: thoughtPatterns)

        return SessionInsights(
            engine: .classic,
            generatedAt: Date(),
            overview: overview,
            highlights: highlights,
            themes: themes.map { $0.insight },
            emotions: emotions.map { $0.insight },
            keyMoments: keyMoments,
            thoughtPatterns: thoughtPatterns,
            suggestions: suggestions,
            detectedActionItems: actionItems,
            questionsForNextSession: questions,
            moodTrajectory: trajectory,
            overallSentiment: overall,
            needsSupportFlag: needsSupport
        )
    }
}

// MARK: - Private types

extension HeuristicInsightEngine {

    /// One sentence of the transcript with everything the pipeline derives from it.
    private struct Sentence {
        let index: Int
        /// Cleaned display text (whitespace collapsed, quotes normalized).
        let text: String
        /// " word word word " — lower-cased, punctuation removed, padded with spaces for phrase matching.
        let padded: String
        /// Lower-cased surface words from `padded`.
        let surfaceWords: [String]
        /// Seconds into the recording.
        let start: TimeInterval
        /// Lower-cased word tokens from NLTokenizer.
        let tokens: [String]
        /// Lemma per word (lower-cased), falling back to the token.
        var lemmas: [String]
        /// Lemmas minus stop words and fillers; used for scoring.
        var contentLemmas: [String]
        /// Count per distinct word form (tokens ∪ lemmas ∪ surface words, max of the counts).
        var wordCounts: [String: Int]
        /// Distinct surface words (fast pre-check for phrase matching).
        var surfaceWordSet: Set<String>
        /// -1...1
        var sentiment: Double

        init(index: Int, text: String, padded: String, surfaceWords: [String], start: TimeInterval, tokens: [String]) {
            self.index = index
            self.text = text
            self.padded = padded
            self.surfaceWords = surfaceWords
            self.start = start
            self.tokens = tokens
            self.lemmas = []
            self.contentLemmas = []
            self.wordCounts = [:]
            self.surfaceWordSet = Set(surfaceWords)
            self.sentiment = 0
        }

        var wordCount: Int { tokens.count }

        mutating func finalizeDerived() {
            var counts: [String: Int] = [:]
            var tokenCounts: [String: Int] = [:]
            for token in tokens { tokenCounts[token, default: 0] += 1 }
            var lemmaCounts: [String: Int] = [:]
            for lemma in lemmas { lemmaCounts[lemma, default: 0] += 1 }
            var surfaceCounts: [String: Int] = [:]
            for word in surfaceWords { surfaceCounts[word, default: 0] += 1 }
            for (word, count) in tokenCounts { counts[word] = max(counts[word] ?? 0, count) }
            for (word, count) in lemmaCounts { counts[word] = max(counts[word] ?? 0, count) }
            for (word, count) in surfaceCounts { counts[word] = max(counts[word] ?? 0, count) }
            wordCounts = counts
            contentLemmas = lemmas.filter { HeuristicInsightEngine.isContentWord($0) }
        }
    }

    /// The whole usable transcript as one string (sentences separated by newlines) so that
    /// language detection and lemmatization run once, plus the end index of every sentence.
    private struct Corpus {
        let fullText: String
        /// End index of sentence i inside `fullText` (exclusive).
        let ends: [String.Index]
        let language: NLLanguage?

        init(sentences: [Sentence]) {
            let joined = sentences.map { $0.text }.joined(separator: "\n")
            var ends: [String.Index] = []
            var cursor = joined.startIndex
            for sentence in sentences {
                let end = joined.utf8.index(cursor, offsetBy: sentence.text.utf8.count)
                ends.append(end)
                if end < joined.endIndex {
                    cursor = joined.utf8.index(after: end)
                } else {
                    cursor = end
                }
            }
            self.fullText = joined
            self.ends = ends
            self.language = NLLanguageRecognizer.dominantLanguage(for: joined)
        }
    }

    /// Keyword hits of one sentence against the lexicon.
    private struct Signals {
        /// Lexicon theme index → mentions in this sentence.
        var themeHits: [Int: Int]
        /// Lexicon emotion index → mentions in this sentence.
        var emotionHits: [Int: Int]
        /// Lexicon distortion rule index → pattern hits in this sentence.
        var distortionHits: [Int: Int]
        var commitmentHits: Int
        var insightHits: Int

        var themeTotal: Int { themeHits.values.reduce(0, +) }
        var hasDistortion: Bool { !distortionHits.isEmpty }
    }

    /// Fast matcher: single words are looked up in the sentence's word forms, multi-word
    /// phrases are searched in the space-padded sentence.
    private struct KeywordIndex {
        private var wordGroups: [String: [Int]] = [:]
        private var phrases: [(phrase: String, firstWord: String, group: Int)] = []

        init(groups: [[String]]) {
            for (groupIndex, keywords) in groups.enumerated() {
                var seen = Set<String>()
                for keyword in keywords {
                    let words = HeuristicInsightEngine.normalizedWords(keyword)
                    guard !words.isEmpty else { continue }
                    let key = words.joined(separator: " ")
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    if words.count == 1 {
                        wordGroups[key, default: []].append(groupIndex)
                    } else {
                        phrases.append((phrase: " " + key + " ", firstWord: words[0], group: groupIndex))
                    }
                }
            }
        }

        /// Group index → number of hits (only groups with at least one hit are present).
        func hits(in sentence: Sentence) -> [Int: Int] {
            var result: [Int: Int] = [:]
            for (word, count) in sentence.wordCounts {
                guard let groups = wordGroups[word] else { continue }
                for group in groups { result[group, default: 0] += count }
            }
            for entry in phrases {
                guard sentence.surfaceWordSet.contains(entry.firstWord) else { continue }
                let occurrences = HeuristicInsightEngine.occurrences(of: entry.phrase, in: sentence.padded)
                if occurrences > 0 { result[entry.group, default: 0] += occurrences }
            }
            return result
        }
    }

    /// All keyword indexes built once per analysis from the lexicon.
    private struct LexiconIndex {
        let themeIndex: KeywordIndex
        let emotionIndex: KeywordIndex
        let distortionIndex: KeywordIndex
        let commitmentIndex: KeywordIndex
        let insightIndex: KeywordIndex

        init() {
            themeIndex = KeywordIndex(groups: TherapyLexicon.themes.map { $0.keywords })
            emotionIndex = KeywordIndex(groups: TherapyLexicon.emotions.map { [$0.name] + $0.keywords })
            distortionIndex = KeywordIndex(groups: TherapyLexicon.distortions.map { $0.patterns })
            commitmentIndex = KeywordIndex(groups: [TherapyLexicon.commitmentPatterns])
            insightIndex = KeywordIndex(groups: [HeuristicInsightEngine.insightPhrases])
        }

        func signals(for sentence: Sentence) -> Signals {
            Signals(
                themeHits: themeIndex.hits(in: sentence),
                emotionHits: emotionIndex.hits(in: sentence),
                distortionHits: distortionIndex.hits(in: sentence),
                commitmentHits: commitmentIndex.hits(in: sentence)[0] ?? 0,
                insightHits: insightIndex.hits(in: sentence)[0] ?? 0
            )
        }
    }

    private struct ThemeMatch {
        let lexiconIndex: Int
        let insight: ThemeInsight
    }

    private struct EmotionMatch {
        let lexiconIndex: Int
        let insight: EmotionInsight
    }

    private enum Trend {
        case lifted
        case dipped
        case steady
    }

    /// Collects suggestions with de-duplication by title and a hard cap.
    private struct SuggestionBuilder {
        private(set) var items: [Suggestion] = []
        private var titleKeys = Set<String>()
        let cap: Int

        init(cap: Int) {
            self.cap = cap
        }

        var isFull: Bool { items.count >= cap }

        mutating func add(_ suggestion: Suggestion) {
            guard !isFull else { return }
            let key = HeuristicInsightEngine.normalizedKey(suggestion.title)
            guard !key.isEmpty, !titleKeys.contains(key) else { return }
            titleKeys.insert(key)
            items.append(suggestion)
        }
    }

    /// Phrases that usually mark a moment of insight (step 8).
    private static let insightPhrases: [String] = [
        "i realized", "i realised", "i've realized", "i've realised", "i think the reason",
        "i noticed", "it makes sense", "i never thought", "now i see", "i'm starting to see",
        "i understand now", "that explains", "i figured out", "i learned", "it hit me", "i get it now"
    ]
}

// MARK: - Steps 1–3: sentences, lemmas, sentiment

extension HeuristicInsightEngine {

    /// Step 1. Splits every segment into sentences, keeps each sentence's time (the segment start,
    /// offset proportionally within the segment) and drops sentences with fewer than 3 words.
    private static func buildSentences(from segments: [TranscriptSegment]) -> [Sentence] {
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        let wordTokenizer = NLTokenizer(unit: .word)
        var result: [Sentence] = []

        for segment in segments {
            let segmentText = normalizeQuotes(segment.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segmentText.isEmpty else { continue }

            sentenceTokenizer.string = segmentText
            var ranges = sentenceTokenizer.tokens(for: segmentText.startIndex..<segmentText.endIndex)
            if ranges.isEmpty {
                ranges = [segmentText.startIndex..<segmentText.endIndex]
            }
            let segmentLength = max(1, segmentText.count)
            let segmentSpan = max(0, segment.end - segment.start)

            for range in ranges {
                let text = collapseWhitespace(String(segmentText[range]))
                guard !text.isEmpty else { continue }

                wordTokenizer.string = text
                let tokens = wordTokenizer.tokens(for: text.startIndex..<text.endIndex)
                    .map { String(text[$0]).lowercased() }
                    .filter { containsLetterOrDigit($0) }
                guard tokens.count >= 3 else { continue }

                let offset = segmentText.distance(from: segmentText.startIndex, to: range.lowerBound)
                let fraction = Double(offset) / Double(segmentLength)
                let start = max(0, segment.start + segmentSpan * fraction)
                let surfaceWords = normalizedWords(text)
                let padded = " " + surfaceWords.joined(separator: " ") + " "
                result.append(Sentence(
                    index: result.count,
                    text: text,
                    padded: padded,
                    surfaceWords: surfaceWords,
                    start: start,
                    tokens: tokens
                ))
            }
        }
        return result
    }

    /// Step 2. Lemmatizes the whole corpus in one pass and assigns lemmas to sentences.
    private static func assignLemmas(to sentences: inout [Sentence], corpus: Corpus) {
        let text = corpus.fullText
        let whole = text.startIndex..<text.endIndex
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = text
        if let language = corpus.language {
            tagger.setLanguage(language, range: whole)
        }

        var lemmas: [[String]] = Array(repeating: [], count: sentences.count)
        var pointer = 0
        let lastIndex = sentences.count - 1
        let ends = corpus.ends

        tagger.enumerateTags(in: whole, unit: .word, scheme: .lemma, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            while pointer < lastIndex && range.lowerBound >= ends[pointer] {
                pointer += 1
            }
            let surface = normalizeQuotes(String(text[range]).lowercased())
            var lemma = surface
            if let value = tag?.rawValue {
                let normalized = normalizeQuotes(value.lowercased()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty {
                    lemma = normalized
                }
            }
            if containsLetterOrDigit(lemma) {
                lemmas[pointer].append(lemma)
            }
            return true
        }

        for i in sentences.indices {
            sentences[i].lemmas = lemmas[i].isEmpty ? sentences[i].tokens : lemmas[i]
            sentences[i].finalizeDerived()
        }
    }

    /// Step 3. Sentiment per sentence via NLTagger; falls back to lexicon counts when the
    /// language is unsupported or the tagger has nothing to say.
    private static func assignSentiment(to sentences: inout [Sentence], corpus: Corpus) {
        var taggerSupported = true
        if let language = corpus.language {
            taggerSupported = NLTagger.availableTagSchemes(for: .paragraph, language: language).contains(.sentimentScore)
        }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])

        for i in sentences.indices {
            var score: Double? = nil
            if taggerSupported {
                // Each sentence is scored on its own, with the language detected on the whole corpus
                // (short sentences are unreliable for language detection).
                let text = sentences[i].text
                tagger.string = text
                if let language = corpus.language {
                    tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
                }
                let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
                if let raw = tag?.rawValue, let value = Double(raw), value.isFinite, value != 0 {
                    score = value
                }
            }
            let fallback = lexiconSentiment(of: sentences[i])
            sentences[i].sentiment = clamp(score ?? fallback)
        }
    }

    /// (positive − negative) / (content words + 1), clamped to −1…1.
    private static func lexiconSentiment(of sentence: Sentence) -> Double {
        var positive = 0
        var negative = 0
        for (word, count) in sentence.wordCounts {
            if TherapyLexicon.positiveWords.contains(word) { positive += count }
            if TherapyLexicon.negativeWords.contains(word) { negative += count }
        }
        let total = sentence.contentLemmas.count
        return clamp(Double(positive - negative) / Double(total + 1))
    }
}

// MARK: - Steps 4–7: themes, emotions, thought patterns, commitments

extension HeuristicInsightEngine {

    /// Step 4.
    private static func selectThemes(sentences: [Sentence], signals: [Signals]) -> [ThemeMatch] {
        let lexiconThemes = TherapyLexicon.themes
        guard !lexiconThemes.isEmpty else { return [] }

        var totals = [Int](repeating: 0, count: lexiconThemes.count)
        for sentenceSignals in signals {
            for (themeIndex, count) in sentenceSignals.themeHits where themeIndex < totals.count {
                totals[themeIndex] += count
            }
        }

        var candidates: [(index: Int, mentions: Int)] = []
        for (index, mentions) in totals.enumerated() where mentions > 0 {
            candidates.append((index: index, mentions: mentions))
        }
        guard !candidates.isEmpty else { return [] }

        candidates.sort { a, b in
            if a.mentions != b.mentions { return a.mentions > b.mentions }
            return a.index < b.index
        }
        var kept = candidates.filter { $0.mentions >= 2 }
        if kept.isEmpty {
            kept = Array(candidates.prefix(3))
        }
        kept = Array(kept.prefix(6))

        return kept.map { candidate in
            let quote = representativeQuote(themeIndex: candidate.index, sentences: sentences, signals: signals)
            let insight = ThemeInsight(
                name: capitalizedFirst(lexiconThemes[candidate.index].name),
                mentions: candidate.mentions,
                quote: quote
            )
            return ThemeMatch(lexiconIndex: candidate.index, insight: insight)
        }
    }

    /// The shortest sentence with at least 6 words that mentions the theme; otherwise the first
    /// sentence that mentions it at all.
    private static func representativeQuote(themeIndex: Int, sentences: [Sentence], signals: [Signals]) -> String? {
        var best: Sentence? = nil
        var firstHit: Sentence? = nil
        for (i, sentence) in sentences.enumerated() {
            guard (signals[i].themeHits[themeIndex] ?? 0) > 0 else { continue }
            if firstHit == nil { firstHit = sentence }
            guard sentence.wordCount >= 6 else { continue }
            if let current = best {
                if sentence.wordCount < current.wordCount { best = sentence }
            } else {
                best = sentence
            }
        }
        guard let chosen = best ?? firstHit else { return nil }
        return cleanQuote(truncated(chosen.text, to: 220))
    }

    /// Step 5.
    private static func selectEmotions(signals: [Signals]) -> [EmotionMatch] {
        let lexiconEmotions = TherapyLexicon.emotions
        guard !lexiconEmotions.isEmpty else { return [] }

        var totals = [Int](repeating: 0, count: lexiconEmotions.count)
        for sentenceSignals in signals {
            for (emotionIndex, count) in sentenceSignals.emotionHits where emotionIndex < totals.count {
                totals[emotionIndex] += count
            }
        }

        var candidates: [(index: Int, mentions: Int)] = []
        for (index, mentions) in totals.enumerated() where mentions >= 1 {
            candidates.append((index: index, mentions: mentions))
        }
        guard !candidates.isEmpty else { return [] }

        candidates.sort { a, b in
            if a.mentions != b.mentions { return a.mentions > b.mentions }
            return a.index < b.index
        }
        let kept = Array(candidates.prefix(6))
        let maxMentions = Double(max(1, kept[0].mentions))

        return kept.map { candidate in
            let intensity = (Double(candidate.mentions) / maxMentions * 100).rounded() / 100
            let insight = EmotionInsight(
                name: capitalizedFirst(lexiconEmotions[candidate.index].name),
                intensity: min(1, max(0, intensity)),
                mentions: candidate.mentions
            )
            return EmotionMatch(lexiconIndex: candidate.index, insight: insight)
        }
    }

    /// Step 6. For each distortion rule, the first sentence containing one of its patterns
    /// (preferring a sentence not already used by another rule). Max 4.
    private static func detectThoughtPatterns(sentences: [Sentence], signals: [Signals]) -> [ThoughtPattern] {
        var result: [ThoughtPattern] = []
        var usedSentences = Set<Int>()

        for (ruleIndex, rule) in TherapyLexicon.distortions.enumerated() {
            guard result.count < 4 else { break }
            var hitIndices: [Int] = []
            for (i, sentenceSignals) in signals.enumerated() where (sentenceSignals.distortionHits[ruleIndex] ?? 0) > 0 {
                hitIndices.append(i)
            }
            guard let chosen = hitIndices.first(where: { !usedSentences.contains($0) }) ?? hitIndices.first else { continue }
            usedSentences.insert(chosen)
            result.append(ThoughtPattern(
                name: rule.name,
                description: rule.description,
                quote: cleanQuote(truncated(sentences[chosen].text, to: 220)),
                reframe: rule.reframe
            ))
        }
        return result
    }

    /// Step 7. Sentences containing a commitment pattern, cleaned and de-duplicated. Max 8.
    private static func detectActionItems(sentences: [Sentence], signals: [Signals]) -> [String] {
        var seen = Set<String>()
        var items: [String] = []
        for (i, sentence) in sentences.enumerated() where signals[i].commitmentHits > 0 {
            let item = actionItemText(from: sentence.text)
            guard item.count >= 8 else { continue }
            let key = normalizedKey(item)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            items.append(item)
            if items.count >= 8 { break }
        }
        return items
    }

    private static func actionItemText(from text: String) -> String {
        var cleaned = cleanQuote(text)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: "))
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return capitalizedFirst(truncated(cleaned, to: 200))
    }
}

// MARK: - Steps 8–11: key moments, highlights, mood trajectory, overview

extension HeuristicInsightEngine {

    /// Step 8. score = |sentiment| × 2 + themeHits × 0.5 + commitment 1.5 + distortion 1.0 + insight 1.5.
    /// Top 5 in time order.
    private static func selectKeyMoments(sentences: [Sentence], signals: [Signals]) -> [KeyMoment] {
        struct Scored {
            let index: Int
            let score: Double
            let reason: String
        }

        var scored: [Scored] = []
        for (i, sentence) in sentences.enumerated() {
            let sentenceSignals = signals[i]
            let emotion = abs(sentence.sentiment) * 2
            let theme = Double(sentenceSignals.themeTotal) * 0.5
            let commitment: Double = sentenceSignals.commitmentHits > 0 ? 1.5 : 0
            let distortion: Double = sentenceSignals.hasDistortion ? 1.0 : 0
            let insight: Double = sentenceSignals.insightHits > 0 ? 1.5 : 0
            let score = emotion + theme + commitment + distortion + insight
            guard score >= 1.0 else { continue }

            // Reason = the largest contribution; ties go to the more specific reason.
            var reason = "Core theme"
            var best = theme
            if emotion >= best && emotion > 0 { best = emotion; reason = "Strong emotion" }
            if distortion >= best && distortion > 0 { best = distortion; reason = "Thinking pattern" }
            if commitment >= best && commitment > 0 { best = commitment; reason = "Commitment" }
            if insight >= best && insight > 0 { best = insight; reason = "Insight" }
            if reason == "Strong emotion" && abs(sentence.sentiment) < 0.5 && theme > 0 {
                reason = "Core theme"
            }
            scored.append(Scored(index: i, score: score, reason: reason))
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        let top = scored.prefix(5).sorted { $0.index < $1.index }
        return top.map { entry in
            KeyMoment(
                time: sentences[entry.index].start,
                text: cleanQuote(truncated(sentences[entry.index].text, to: 220)),
                reason: entry.reason
            )
        }
    }

    /// Step 9. TextRank-lite extractive highlights: frequency of content lemmas (normalized),
    /// sentence score = Σ freq / √len + 0.3 for the first/last 10 % + theme bonus.
    /// Top 5 distinct sentences in time order, each ≤ 180 characters.
    private static func selectHighlights(sentences: [Sentence], signals: [Signals]) -> [String] {
        var frequency: [String: Int] = [:]
        for sentence in sentences {
            for lemma in sentence.contentLemmas { frequency[lemma, default: 0] += 1 }
        }
        let maxFrequency = Double(max(1, frequency.values.max() ?? 1))
        let count = sentences.count
        let edge = max(1, Int(Double(count) * 0.1))

        struct Candidate {
            let index: Int
            let score: Double
            let lemmaSet: Set<String>
        }

        func rankedCandidates(minimumWords: Int) -> [Candidate] {
            var result: [Candidate] = []
            for (i, sentence) in sentences.enumerated() {
                guard sentence.wordCount >= minimumWords, !sentence.contentLemmas.isEmpty else { continue }
                var sum = 0.0
                for lemma in sentence.contentLemmas {
                    sum += Double(frequency[lemma] ?? 0) / maxFrequency
                }
                var score = sum / sqrt(Double(max(1, sentence.wordCount)))
                if i < edge || i >= count - edge { score += 0.3 }
                score += 0.25 * Double(min(signals[i].themeTotal, 4))
                result.append(Candidate(index: i, score: score, lemmaSet: Set(sentence.contentLemmas)))
            }
            result.sort { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.index < b.index
            }
            return result
        }

        var ranked = rankedCandidates(minimumWords: 6)
        if ranked.isEmpty {
            ranked = rankedCandidates(minimumWords: 3)
        }

        var picked: [Candidate] = []
        var seenKeys = Set<String>()
        for candidate in ranked {
            if picked.count >= 5 { break }
            let key = normalizedKey(sentences[candidate.index].text)
            if seenKeys.contains(key) { continue }
            if picked.contains(where: { jaccard($0.lemmaSet, candidate.lemmaSet) > 0.6 }) { continue }
            seenKeys.insert(key)
            picked.append(candidate)
        }

        return picked
            .sorted { $0.index < $1.index }
            .map { cleanQuote(truncated(sentences[$0.index].text, to: 180)) }
    }

    /// Step 11. Mean sentiment in 8 equal time buckets; empty buckets are linearly interpolated
    /// between their filled neighbours (edges copy the nearest filled bucket).
    private static func moodTrajectory(sentences: [Sentence], duration: TimeInterval) -> [Double] {
        let bucketCount = 8
        let lastStart = sentences.map { $0.start }.max() ?? 0
        let total: Double = duration > 0 ? duration : lastStart + 1

        var sums = [Double](repeating: 0, count: bucketCount)
        var counts = [Int](repeating: 0, count: bucketCount)
        for sentence in sentences {
            let fraction = total > 0 ? sentence.start / total : 0
            let bucket = min(bucketCount - 1, max(0, Int(fraction * Double(bucketCount))))
            sums[bucket] += sentence.sentiment
            counts[bucket] += 1
        }

        var values: [Double?] = []
        for i in 0..<bucketCount {
            values.append(counts[i] > 0 ? sums[i] / Double(counts[i]) : nil)
        }
        let filled = (0..<bucketCount).filter { values[$0] != nil }
        guard !filled.isEmpty else { return [Double](repeating: 0, count: bucketCount) }

        var result = [Double](repeating: 0, count: bucketCount)
        for i in 0..<bucketCount {
            if let value = values[i] {
                result[i] = value
                continue
            }
            let left = filled.last(where: { $0 < i })
            let right = filled.first(where: { $0 > i })
            if let l = left, let r = right, let leftValue = values[l], let rightValue = values[r] {
                let t = Double(i - l) / Double(r - l)
                result[i] = leftValue + (rightValue - leftValue) * t
            } else if let l = left, let leftValue = values[l] {
                result[i] = leftValue
            } else if let r = right, let rightValue = values[r] {
                result[i] = rightValue
            }
        }
        return result.map { rounded(clamp($0)) }
    }

    /// Compares the first quarter of sentences with the last quarter.
    private static func trend(of sentiments: [Double]) -> Trend {
        guard sentiments.count >= 2 else { return .steady }
        let quarter = max(1, sentiments.count / 4)
        let first = mean(Array(sentiments.prefix(quarter)))
        let last = mean(Array(sentiments.suffix(quarter)))
        let delta = last - first
        if delta > 0.15 { return .lifted }
        if delta < -0.15 { return .dipped }
        return .steady
    }

    /// Step 10. Two to four plain sentences addressed to the user.
    private static func composeOverview(
        session: TherapySession,
        themes: [ThemeMatch],
        emotions: [EmotionMatch],
        trend: Trend,
        commitmentCount: Int,
        thoughtPatternCount: Int
    ) -> String {
        var parts: [String] = []

        // 1. Duration + main themes.
        let opening = durationPhrase(session.duration)
        let themeNames = themes.prefix(3).map { lowercasedFirst($0.insight.name) }
        if themeNames.isEmpty {
            parts.append("\(opening) no single topic stood out — you moved between a few different things.")
        } else {
            parts.append("\(opening) you mainly talked about \(joinList(themeNames)).")
        }

        // 2. Dominant emotions + sentiment trend.
        let trendText: String
        switch trend {
        case .lifted: trendText = "the tone lifted toward the end"
        case .dipped: trendText = "the tone dipped toward the end"
        case .steady: trendText = "the tone stayed fairly steady throughout"
        }
        let emotionNames = emotions.prefix(3).map { lowercasedFirst($0.insight.name) }
        if emotionNames.isEmpty {
            parts.append(capitalizedFirst(trendText) + ".")
        } else if emotionNames.count == 1 {
            parts.append("Feeling \(emotionNames[0]) came through most clearly, and \(trendText).")
        } else {
            parts.append("\(capitalizedFirst(joinList(emotionNames))) came through most often, and \(trendText).")
        }

        // 3. Commitments.
        switch commitmentCount {
        case 0:
            parts.append("No specific commitments came up this time, and that's okay.")
        case 1:
            parts.append("You made one commitment to follow up on before next time.")
        default:
            parts.append("You made \(commitmentCount) commitments to follow up on before next time.")
        }

        // 4. Mood check-in, or thinking patterns when there is no mood pair.
        if let before = session.moodBefore, let after = session.moodAfter {
            if after > before {
                parts.append("Your mood check-in went from \(before) to \(after) out of 10.")
            } else if after < before {
                parts.append("Your mood check-in went from \(before) to \(after) out of 10 — sessions that stir things up can feel like that.")
            } else {
                parts.append("Your mood check-in stayed at \(before) out of 10 before and after.")
            }
        } else if thoughtPatternCount == 1 {
            parts.append("One thinking pattern worth a gentle second look also showed up.")
        } else if thoughtPatternCount > 1 {
            parts.append("A few thinking patterns worth a gentle second look also showed up.")
        }

        return parts.joined(separator: " ")
    }

    private static func durationPhrase(_ duration: TimeInterval) -> String {
        guard duration > 0 else { return "In this session" }
        let minutes = Int((duration / 60).rounded())
        if minutes >= 1 {
            return "In this \(minutes)-minute session"
        }
        return "In this short session"
    }
}

// MARK: - Steps 12–14: suggestions, questions, support flag

extension HeuristicInsightEngine {

    /// Step 12. Priority order: cross-session patterns, one suggestion per top theme, the
    /// strongest emotion, thinking-pattern reframes, two general suggestions; then the list is
    /// topped up with the remaining theme/emotion/pattern suggestions. Cap 10, de-duped by title.
    private static func buildSuggestions(
        themes: [ThemeMatch],
        emotions: [EmotionMatch],
        thoughtPatterns: [ThoughtPattern],
        session: TherapySession,
        history: [TherapySession],
        sentenceCount: Int,
        commitmentCount: Int
    ) -> [Suggestion] {
        var builder = SuggestionBuilder(cap: 10)
        let lexiconThemes = TherapyLexicon.themes

        func themeSuggestion(_ match: ThemeMatch, slot: Int) -> Suggestion? {
            guard match.lexiconIndex < lexiconThemes.count else { return nil }
            let list = lexiconThemes[match.lexiconIndex].suggestions
            guard slot < list.count else { return nil }
            return instantiate(list[slot], n: match.insight.mentions, theme: lowercasedFirst(match.insight.name))
        }

        // Cross-session patterns first: they are the most specific thing we can say.
        for suggestion in patternSuggestions(themes: themes, session: session, history: history) {
            builder.add(suggestion)
        }

        // One lexicon suggestion for each of the top three themes.
        for match in themes.prefix(3) {
            if let suggestion = themeSuggestion(match, slot: 0) { builder.add(suggestion) }
        }

        // The strongest emotion.
        if let first = emotions.first {
            builder.add(emotionSuggestion(for: first.insight))
        }

        // Thinking patterns, offered as reflections with the reframe.
        for pattern in thoughtPatterns.prefix(2) {
            builder.add(reflectionSuggestion(for: pattern))
        }

        // Two always-relevant general suggestions, rotated deterministically per transcript.
        let general = TherapyLexicon.generalSuggestions
        if !general.isEmpty {
            let offset = sentenceCount % general.count
            let fallbackTheme = themes.first.map { lowercasedFirst($0.insight.name) } ?? "what you talked about"
            for k in 0..<min(2, general.count) {
                let base = general[(offset + k) % general.count]
                builder.add(instantiate(base, n: commitmentCount, theme: fallbackTheme))
            }
        }

        // Top up with whatever is left, in order of usefulness.
        for match in themes.dropFirst(3) {
            if let suggestion = themeSuggestion(match, slot: 0) { builder.add(suggestion) }
        }
        if emotions.count > 1 {
            builder.add(emotionSuggestion(for: emotions[1].insight))
        }
        for pattern in thoughtPatterns.dropFirst(2) {
            builder.add(reflectionSuggestion(for: pattern))
        }
        for match in themes {
            if let suggestion = themeSuggestion(match, slot: 1) { builder.add(suggestion) }
        }

        return builder.items
    }

    /// A `.pattern` suggestion for every kept theme that also appears in ≥ 2 of the last 6
    /// history sessions. Max 2, strongest recurrence first.
    private static func patternSuggestions(themes: [ThemeMatch], session: TherapySession, history: [TherapySession]) -> [Suggestion] {
        let window = Array(history.filter { $0.id != session.id }.prefix(6))
        let considered = window.count
        guard considered >= 2 else { return [] }

        var found: [(count: Int, order: Int, suggestion: Suggestion)] = []
        for (order, match) in themes.enumerated() {
            let name = match.insight.name
            let key = normalizedKey(name)
            guard !key.isEmpty else { continue }
            var count = 0
            for past in window {
                guard let pastThemes = past.insights?.themes else { continue }
                if pastThemes.contains(where: { normalizedKey($0.name) == key }) {
                    count += 1
                }
            }
            guard count >= 2 else { continue }

            let detail = "\(name) has come up in \(count) of your last \(considered) sessions. It might be worth asking your therapist whether this deserves a session of its own."
            let rationale = "Found in \(count) of your last \(considered) sessions, and it came up \(times(match.insight.mentions)) today."
            let suggestion = Suggestion(
                category: .pattern,
                title: "\(name) keeps coming back",
                detail: detail,
                rationale: rationale
            )
            found.append((count: count, order: order, suggestion: suggestion))
        }

        found.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.order < b.order
        }
        return found.prefix(2).map { $0.suggestion }
    }

    /// A practical, emotion-specific suggestion.
    private static func emotionSuggestion(for emotion: EmotionInsight) -> Suggestion {
        let rationale = "\(capitalizedFirst(emotion.name)) came through \(times(emotion.mentions)) in this session."
        let name = emotion.name.lowercased()
        switch name {
        case "overwhelmed":
            return Suggestion(
                category: .practice,
                title: "Try a 5-4-3-2-1 grounding check",
                detail: "When things pile up, pause and name five things you can see, four you can hear, three you can touch, two you can smell and one you can taste. It takes a minute and brings your attention back to right now.",
                rationale: rationale
            )
        case "anxious":
            return Suggestion(
                category: .practice,
                title: "Try a daily worry window",
                detail: "Set aside 15 minutes at a fixed time each day to write down what you're worried about. When worries show up outside that window, note them and gently postpone them until then.",
                rationale: rationale
            )
        case "sad":
            return Suggestion(
                category: .selfCare,
                title: "Plan one small, pleasant thing each day",
                detail: "Pick something tiny and doable — a short walk, a song you love, a call with someone easy to be with — and put it in your day on purpose. Mood often follows action rather than the other way round.",
                rationale: rationale
            )
        case "angry", "frustrated":
            return Suggestion(
                category: .practice,
                title: "Pause, name it, then move",
                detail: "When irritation rises, say to yourself what you feel and what you need. Then give the energy somewhere to go — a brisk walk, a flight of stairs, a few slow breaths — before deciding what to do next.",
                rationale: rationale
            )
        case "ashamed", "guilty":
            return Suggestion(
                category: .reflection,
                title: "Write to yourself as a friend would",
                detail: "Take ten minutes to write about what happened as if you were writing to a good friend in the same situation. Notice how different that voice is from the one in your head.",
                rationale: rationale
            )
        case "lonely":
            return Suggestion(
                category: .selfCare,
                title: "Reach out to one person this week",
                detail: "It doesn't need to be a big conversation. A short message, a shared walk or a quick call all count. Choose someone who is easy to be around.",
                rationale: rationale
            )
        case "exhausted":
            return Suggestion(
                category: .selfCare,
                title: "Protect one evening for rest",
                detail: "Pick one evening this week with nothing planned. Keep screens dim, go to bed a little earlier, and treat rest as part of the work rather than a reward for it.",
                rationale: rationale
            )
        case "afraid":
            return Suggestion(
                category: .practice,
                title: "Make a 'what helps when I'm scared' list",
                detail: "Write down three things that have helped you feel safer before — a person, a place, a routine. Keep the list where you'll see it when fear shows up.",
                rationale: rationale
            )
        case "numb":
            return Suggestion(
                category: .practice,
                title: "Do a two-minute sensory check-in",
                detail: "Name five things you can see, four you can hear and three you can touch. Numbness often eases a little when attention comes back to the body, even briefly.",
                rationale: rationale
            )
        case "hurt":
            return Suggestion(
                category: .reflection,
                title: "Write the letter you won't send",
                detail: "Put into words what hurt and what you wish had happened instead. You don't have to send it; getting it out of your head is the point.",
                rationale: rationale
            )
        case "confused":
            return Suggestion(
                category: .reflection,
                title: "Untangle it on paper",
                detail: "Write the situation in three columns: what happened, what you felt, what you want. Confusion often loosens once the pieces are separated.",
                rationale: rationale
            )
        case "hopeful", "motivated":
            return Suggestion(
                category: .reflection,
                title: "Capture what's giving you momentum",
                detail: "Write down what felt hopeful this week and what made it possible. Knowing the ingredients makes them easier to find again on harder days.",
                rationale: rationale
            )
        case "calm", "relieved":
            return Suggestion(
                category: .reflection,
                title: "Notice what helped you settle",
                detail: "Spend a minute on what led to the calmer moments. The more specific you can be, the easier it is to repeat.",
                rationale: rationale
            )
        case "proud", "grateful":
            return Suggestion(
                category: .reflection,
                title: "Savor it for a minute",
                detail: "Take a moment to replay what went well and let it land. Good feelings tend to pass quickly unless we give them a little attention.",
                rationale: rationale
            )
        case "jealous":
            return Suggestion(
                category: .reflection,
                title: "Ask what the envy is pointing at",
                detail: "Jealousy often signals something we want more of. Write down what the other person seems to have, and whether a small step toward it is possible for you.",
                rationale: rationale
            )
        default:
            return Suggestion(
                category: .reflection,
                title: "Give the feeling a name and a place",
                detail: "A few times this week, pause and name what you're feeling and where you notice it in your body. Naming an emotion is a surprisingly good first step toward handling it.",
                rationale: rationale
            )
        }
    }

    /// A `.reflection` suggestion built from a thinking pattern's reframe.
    private static func reflectionSuggestion(for pattern: ThoughtPattern) -> Suggestion {
        Suggestion(
            category: .reflection,
            title: "A gentler take on \(lowercasedFirst(pattern.name))",
            detail: pattern.reframe,
            rationale: "You said: \"\(truncated(pattern.quote, to: 140))\""
        )
    }

    /// Step 13. Theme questions from the lexicon (round-robin, up to 4) + one per thinking
    /// pattern. Cap 6, de-duplicated.
    private static func nextSessionQuestions(themes: [ThemeMatch], thoughtPatterns: [ThoughtPattern]) -> [String] {
        let lexiconThemes = TherapyLexicon.themes
        var result: [String] = []
        var seen = Set<String>()

        func append(_ question: String) {
            let cleaned = cleanQuote(question)
            let key = normalizedKey(cleaned)
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            result.append(cleaned)
        }

        var round = 0
        var moreAvailable = true
        while moreAvailable && result.count < 4 {
            moreAvailable = false
            for match in themes where match.lexiconIndex < lexiconThemes.count {
                let questions = lexiconThemes[match.lexiconIndex].questions
                guard round < questions.count else { continue }
                moreAvailable = true
                if result.count < 4 {
                    append(fill(questions[round], n: match.insight.mentions, theme: lowercasedFirst(match.insight.name)))
                }
            }
            round += 1
        }

        for pattern in thoughtPatterns {
            guard result.count < 6 else { break }
            let trimmed = pattern.quote.trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;: \"'"))
            let short = truncated(trimmed, to: 90)
            guard !short.isEmpty else { continue }
            append("Could we look at the thought '\(short)'?")
        }

        return Array(result.prefix(6))
    }

    /// Step 14. Any crisis pattern in the full lower-cased transcript.
    private static func detectCrisisLanguage(in transcript: String) -> Bool {
        let lower = normalizeQuotes(transcript.lowercased())
        guard !lower.isEmpty else { return false }
        let padded = " " + normalizedWords(lower).joined(separator: " ") + " "
        for pattern in TherapyLexicon.crisisPatterns {
            let normalizedPattern = normalizeQuotes(pattern.lowercased()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPattern.isEmpty else { continue }
            if lower.contains(normalizedPattern) { return true }
            let words = normalizedWords(normalizedPattern)
            if !words.isEmpty && padded.contains(" " + words.joined(separator: " ") + " ") { return true }
        }
        return false
    }
}

// MARK: - Text helpers

extension HeuristicInsightEngine {

    /// Replaces `{n}` / `{n} times` / `{theme}` in a lexicon template.
    private static func fill(_ template: String, n: Int, theme: String) -> String {
        var text = template
        text = text.replacingOccurrences(of: "{n} times", with: times(n))
        text = text.replacingOccurrences(of: "{n}", with: String(n))
        text = text.replacingOccurrences(of: "{theme}", with: theme)
        return text
    }

    /// Copies a lexicon suggestion with a fresh id and filled-in templates.
    private static func instantiate(_ base: Suggestion, n: Int, theme: String) -> Suggestion {
        Suggestion(
            category: base.category,
            title: capitalizedFirst(fill(base.title, n: n, theme: theme)),
            detail: capitalizedFirst(fill(base.detail, n: n, theme: theme)),
            rationale: capitalizedFirst(fill(base.rationale, n: n, theme: theme))
        )
    }

    private static func times(_ n: Int) -> String {
        switch n {
        case 1: return "once"
        case 2: return "twice"
        default: return "\(n) times"
        }
    }

    /// "a", "a and b", "a, b and c".
    private static func joinList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + String(text.dropFirst())
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + String(text.dropFirst())
    }

    /// Strips surrounding quotes and whitespace, capitalizes the first letter.
    private static func cleanQuote(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’«»"))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizedFirst(cleaned)
    }

    /// Cuts at a word boundary and appends an ellipsis when the text is longer than `limit`.
    private static func truncated(_ text: String, to limit: Int) -> String {
        guard limit > 0, text.count > limit else { return text }
        let cut = text.index(text.startIndex, offsetBy: limit)
        var head = String(text[..<cut])
        if let lastSpace = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: lastSpace) > limit / 2 {
            head = String(head[..<lastSpace])
        }
        head = head.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—"))
        return head + "…"
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Curly apostrophes/quotes → straight ones so lexicon phrases like "i'll" match.
    private static func normalizeQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    /// Lower-cased words, keeping apostrophes inside words and dropping all other punctuation.
    private static func normalizedWords(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in normalizeQuotes(text.lowercased()).unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "'" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Canonical form for de-duplication.
    private static func normalizedKey(_ text: String) -> String {
        normalizedWords(text).joined(separator: " ")
    }

    private static func containsLetterOrDigit(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func containsLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// Lemmas that carry meaning: at least two characters, at least one letter, not a stop or filler word.
    private static func isContentWord(_ word: String) -> Bool {
        guard word.count >= 2, containsLetter(word) else { return false }
        if TherapyLexicon.stopWords.contains(word) { return false }
        if TherapyLexicon.fillerWords.contains(word) { return false }
        return true
    }

    /// Number of (possibly space-sharing) occurrences of a padded phrase in a padded sentence.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [], range: searchRange) {
            count += 1
            let next = haystack.index(before: found.upperBound)
            guard next > found.lowerBound, next < haystack.endIndex else { break }
            searchRange = next..<haystack.endIndex
        }
        return count
    }

    private static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let unionCount = a.union(b).count
        guard unionCount > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(unionCount)
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(-1, value))
    }

    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }
}
