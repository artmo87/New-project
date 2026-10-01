import Foundation

/// Turns sessions and journal entries into Markdown / plain text for sharing.
/// Everything is generated locally; nothing is uploaded anywhere.
enum SessionExporter {

    // MARK: - Public

    /// Full Markdown report: header, mood, overview, highlights, themes, emotions, key moments,
    /// thought patterns, action items, suggestions, questions, notes, then the timestamped transcript.
    static func markdown(for session: TherapySession) -> String {
        report(for: session, includeFooter: true).joined(separator: "\n")
    }

    /// Only the transcript with [mm:ss] timestamps and speaker labels.
    static func transcriptText(for session: TherapySession) -> String {
        let lines = session.segments.compactMap { segment -> String? in
            let text = inline(segment.text)
            if text.isEmpty { return nil }
            return "[\(Formatters.clock(segment.start))] \(speakerPrefix(segment.speaker, bold: false))\(text)"
        }
        if lines.isEmpty {
            return "No transcript was captured for this session."
        }
        return lines.joined(separator: "\n")
    }

    /// All sessions + journal as one Markdown document.
    static func fullExport(sessions: [TherapySession], journal: [JournalEntry]) -> String {
        let orderedSessions = sessions.sorted { $0.createdAt > $1.createdAt }
        let orderedJournal = journal.sorted { $0.createdAt > $1.createdAt }

        var out: [String] = []
        out.append("# Therapist Copilot — full export")
        out.append("")
        out.append("_Exported \(Formatters.dateTime(Date()))._")
        out.append("")

        let openItems = orderedSessions.reduce(0) { $0 + $1.openActionItems.count }
        let totalSeconds = orderedSessions.reduce(0.0) { $0 + $1.duration }
        out.append("- **Sessions:** \(orderedSessions.count)")
        out.append("- **Time recorded:** \(Formatters.durationWords(totalSeconds))")
        out.append("- **Open action items:** \(openItems)")
        out.append("- **Journal entries:** \(orderedJournal.count)")
        out.append("")

        if !orderedSessions.isEmpty {
            out.append("## Sessions at a glance")
            out.append("")
            out.append("| Date | Title | Duration | Mood before → after |")
            out.append("|---|---|---|---|")
            for session in orderedSessions {
                out.append("| \(tableCell(Formatters.dateTime(session.createdAt))) | \(tableCell(session.displayTitle)) | \(Formatters.durationWords(session.duration)) | \(moodArrow(for: session)) |")
            }
            out.append("")
        }

        out.append("---")
        out.append("")

        if orderedSessions.isEmpty {
            out.append("# Sessions")
            out.append("")
            out.append("No sessions have been recorded yet.")
            out.append("")
        } else {
            for (index, session) in orderedSessions.enumerated() {
                out.append(contentsOf: report(for: session, includeFooter: false))
                out.append("")
                if index < orderedSessions.count - 1 {
                    out.append("---")
                    out.append("")
                }
            }
        }

        out.append("---")
        out.append("")
        out.append("# Journal")
        out.append("")
        if orderedJournal.isEmpty {
            out.append("No journal entries yet.")
            out.append("")
        } else {
            for entry in orderedJournal {
                var heading = "## \(Formatters.dateTime(entry.createdAt))"
                if let mood = entry.mood {
                    heading += " — mood \(mood)/10"
                }
                out.append(heading)
                out.append("")
                let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append(text.isEmpty ? "_(empty entry)_" : text)
                out.append("")
            }
        }

        out.append(contentsOf: footerLines())
        return out.joined(separator: "\n")
    }

    /// Writes text to a temporary file and returns its URL (for ShareLink). nil on failure.
    static func temporaryFile(named name: String, contents: String) -> URL? {
        let fileName = sanitizedFileName(name)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName, isDirectory: false)
        do {
            let data = Data(contents.utf8)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Report assembly

    private static func report(for session: TherapySession, includeFooter: Bool) -> [String] {
        var out: [String] = []
        out.append("# \(inline(session.displayTitle))")
        out.append("")
        out.append(contentsOf: headerLines(for: session))
        out.append("")
        out.append(contentsOf: moodLines(for: session))
        out.append("")

        if let insights = session.insights {
            out.append(contentsOf: insightLines(insights, session: session))
        } else {
            out.append("## Insights")
            out.append("")
            if session.hasTranscript {
                out.append("No insights have been generated for this session yet. Open it in Therapist Copilot and tap “Generate insights”.")
            } else {
                out.append("This session was recorded as audio only, so there is no transcript to analyze. You can still listen back and keep notes.")
            }
        }
        out.append("")
        out.append(contentsOf: actionItemLines(for: session))
        out.append("")
        out.append(contentsOf: questionLines(for: session))
        out.append("")
        out.append(contentsOf: notesLines(for: session))
        out.append("")
        out.append(contentsOf: transcriptLines(for: session))

        if includeFooter {
            out.append("")
            out.append(contentsOf: footerLines())
        }
        return out
    }

    private static func headerLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("- **Date:** \(Formatters.dateTime(session.createdAt))")
        out.append("- **Duration:** \(Formatters.durationWords(session.duration))")

        let therapist = inline(session.therapistName)
        if !therapist.isEmpty {
            out.append("- **Therapist:** \(therapist)")
        }

        if session.hasTranscript {
            out.append("- **Transcript:** \(session.wordCount.formatted()) words, \(languageName(session.transcriptLanguage))")
        } else {
            out.append("- **Transcript:** none (audio only)")
        }

        out.append("- **Audio:** \(session.audioFileName == nil ? "not kept" : "kept on this iPhone")")

        let tags = session.tags.map { inline($0) }.filter { !$0.isEmpty }
        if !tags.isEmpty {
            out.append("- **Tags:** \(tags.joined(separator: ", "))")
        }
        return out
    }

    private static func moodLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("## Mood check-in")
        out.append("")
        if session.moodBefore == nil && session.moodAfter == nil {
            out.append("No mood check-in was recorded for this session.")
            return out
        }
        if let before = session.moodBefore {
            out.append("- Before the session: \(before)/10")
        }
        if let after = session.moodAfter {
            var line = "- After the session: \(after)/10"
            if let change = session.moodChange {
                line += " (\(signed(change)))"
            }
            out.append(line)
        }
        return out
    }

    private static func insightLines(_ insights: SessionInsights, session: TherapySession) -> [String] {
        var out: [String] = []

        if insights.needsSupportFlag {
            out.append("> **A note of care.** Some of what came up in this session sounded really heavy. If you are thinking about harming yourself, please reach out right away — to someone you trust, to your therapist, or to your local emergency number (in the US you can call or text 988). You deserve support.")
            out.append("")
        }

        out.append("## Overview")
        out.append("")
        let overview = insights.overview.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(overview.isEmpty ? "No overview is available for this session." : overview)
        out.append("")
        out.append("_Generated with \(insights.engine.label) on \(Formatters.dateTime(insights.generatedAt))._")
        out.append("")

        out.append("## Highlights")
        out.append("")
        let highlights = insights.highlights.map { inline($0) }.filter { !$0.isEmpty }
        if highlights.isEmpty {
            out.append("Nothing stood out strongly enough to list here.")
        } else {
            for highlight in highlights {
                out.append("- \(highlight)")
            }
        }
        out.append("")

        out.append("## Themes")
        out.append("")
        if insights.themes.isEmpty {
            out.append("No clear themes were picked up in this session.")
        } else {
            for theme in insights.themes {
                var line = "- **\(inline(theme.name))** — \(mentionsText(theme.mentions))"
                if let quote = theme.quote {
                    let cleaned = inline(quote)
                    if !cleaned.isEmpty {
                        line += " — “\(cleaned)”"
                    }
                }
                out.append(line)
            }
        }
        out.append("")

        out.append("## Emotions")
        out.append("")
        if insights.emotions.isEmpty {
            out.append("No particular emotions came through in the words used.")
        } else {
            for emotion in insights.emotions {
                let percent = Int((min(1, max(0, emotion.intensity)) * 100).rounded())
                out.append("- \(inline(emotion.name)) — \(percent)% intensity, \(mentionsText(emotion.mentions))")
            }
        }
        out.append("")

        out.append("## Tone over the session")
        out.append("")
        if insights.moodTrajectory.isEmpty {
            out.append("There wasn't enough transcript to follow the tone over time.")
        } else {
            out.append("`\(sparkline(insights.moodTrajectory))`  (start → end; higher means a lighter tone)")
            out.append("")
            out.append("Overall the tone was \(toneDescription(insights.overallSentiment)).")
        }
        out.append("")

        out.append("## Key moments")
        out.append("")
        if insights.keyMoments.isEmpty {
            out.append("No single moment stood out above the rest.")
        } else {
            for moment in insights.keyMoments {
                var line = "- "
                if let time = moment.time {
                    line += "[\(Formatters.clock(time))] "
                }
                line += "**\(inline(moment.reason))** — \(inline(moment.text))"
                out.append(line)
            }
        }
        out.append("")

        out.append("## Thinking patterns")
        out.append("")
        if insights.thoughtPatterns.isEmpty {
            out.append("No particular thinking patterns stood out in this session.")
            out.append("")
        } else {
            out.append("Offered gently, as something to notice — not a label.")
            out.append("")
            for pattern in insights.thoughtPatterns {
                out.append("### \(inline(pattern.name))")
                out.append("")
                out.append(inline(pattern.description))
                out.append("")
                out.append("> “\(inline(pattern.quote))”")
                out.append("")
                out.append("**A gentler way to see it:** \(inline(pattern.reframe))")
                out.append("")
            }
        }

        out.append("## Suggestions")
        out.append("")
        if insights.suggestions.isEmpty {
            out.append("No suggestions this time.")
            out.append("")
        } else {
            for category in SuggestionCategory.allCases {
                let items = insights.suggestions.filter { $0.category == category }
                if items.isEmpty { continue }
                out.append("### \(category.label)")
                out.append("")
                for suggestion in items {
                    out.append("- **\(inline(suggestion.title))** — \(inline(suggestion.detail))")
                    let why = inline(suggestion.rationale)
                    if !why.isEmpty {
                        out.append("  _Why: \(why)_")
                    }
                }
                out.append("")
            }
        }

        let existing = Set(session.actionItems.map { normalized($0.text) })
        let pendingCommitments = insights.detectedActionItems
            .map { inline($0) }
            .filter { !$0.isEmpty && !existing.contains(normalized($0)) }
        if !pendingCommitments.isEmpty {
            out.append("## Commitments heard in the session")
            out.append("")
            out.append("These were picked up from the transcript and have not been added to your action items yet.")
            out.append("")
            for commitment in pendingCommitments {
                out.append("- \(commitment)")
            }
            out.append("")
        }

        return dropTrailingBlankLines(out)
    }

    private static func actionItemLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("## Action items")
        out.append("")
        if session.actionItems.isEmpty {
            out.append("No action items yet.")
            return out
        }
        for item in session.actionItems {
            let text = inline(item.text)
            if text.isEmpty { continue }
            out.append("- [\(item.isDone ? "x" : " ")] \(text)")
        }
        let doneCount = session.actionItems.filter { $0.isDone }.count
        out.append("")
        out.append("_\(doneCount) of \(session.actionItems.count) done._")
        return out
    }

    private static func questionLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("## Questions for next session")
        out.append("")

        let saved = uniqueNonEmpty(session.nextSessionQuestions)
        let savedKeys = Set(saved.map { normalized($0) })
        let suggested = uniqueNonEmpty(session.insights?.questionsForNextSession ?? [])
            .filter { !savedKeys.contains(normalized($0)) }

        if saved.isEmpty && suggested.isEmpty {
            out.append("No questions saved yet.")
            return out
        }

        if !saved.isEmpty {
            for (index, question) in saved.enumerated() {
                out.append("\(index + 1). \(question)")
            }
        } else {
            out.append("You haven't saved any questions yet.")
        }

        if !suggested.isEmpty {
            out.append("")
            out.append("Also suggested by the analysis:")
            out.append("")
            for question in suggested {
                out.append("- \(question)")
            }
        }
        return out
    }

    private static func notesLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("## Notes")
        out.append("")
        let notes = session.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append(notes.isEmpty ? "No notes were written for this session." : notes)
        return out
    }

    private static func transcriptLines(for session: TherapySession) -> [String] {
        var out: [String] = []
        out.append("## Transcript")
        out.append("")

        let lines = session.segments.compactMap { segment -> String? in
            let text = inline(segment.text)
            if text.isEmpty { return nil }
            return "[\(Formatters.clock(segment.start))] \(speakerPrefix(segment.speaker, bold: true))\(text)"
        }

        if lines.isEmpty {
            out.append("No transcript was captured — this session was recorded as audio only.")
            return out
        }

        out.append("_Transcribed on this iPhone. Speaker labels were assigned by hand and may be incomplete._")
        out.append("")
        for (index, line) in lines.enumerated() {
            out.append(line)
            if index < lines.count - 1 {
                out.append("")
            }
        }
        return out
    }

    private static func footerLines() -> [String] {
        [
            "---",
            "",
            "_Exported from Therapist Copilot on \(Formatters.dateTime(Date())). Everything in this document was created on your iPhone — nothing was sent anywhere. It is a personal reflection aid, not medical advice._"
        ]
    }

    // MARK: - Small helpers

    private static func speakerPrefix(_ speaker: Speaker, bold: Bool) -> String {
        let name: String
        switch speaker {
        case .unknown:
            return ""
        case .me:
            name = "Me"
        case .therapist:
            name = "Therapist"
        }
        return bold ? "**\(name):** " : "\(name): "
    }

    /// Collapses a possibly multi-line string into a single trimmed line.
    private static func inline(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Lower-cased, trimmed, without trailing punctuation — for de-duplication.
    private static func normalized(_ text: String) -> String {
        var result = inline(text).lowercased()
        while let last = result.last, last.isPunctuation || last.isWhitespace {
            result.removeLast()
        }
        return result
    }

    private static func uniqueNonEmpty(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let cleaned = inline(item)
            if cleaned.isEmpty { continue }
            let key = normalized(cleaned)
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(cleaned)
        }
        return result
    }

    private static func mentionsText(_ count: Int) -> String {
        count == 1 ? "1 mention" : "\(count) mentions"
    }

    private static func signed(_ value: Int) -> String {
        value > 0 ? "+\(value)" : "\(value)"
    }

    private static func moodArrow(for session: TherapySession) -> String {
        let before = session.moodBefore.map { String($0) } ?? "–"
        let after = session.moodAfter.map { String($0) } ?? "–"
        if session.moodBefore == nil && session.moodAfter == nil {
            return "–"
        }
        return "\(before) → \(after)"
    }

    private static func tableCell(_ text: String) -> String {
        inline(text).replacingOccurrences(of: "|", with: "/")
    }

    private static func languageName(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "unknown language" }
        return Locale.current.localizedString(forIdentifier: trimmed) ?? trimmed
    }

    private static func toneDescription(_ sentiment: Double) -> String {
        if sentiment.isNaN { return "mixed, with ups and downs" }
        if sentiment >= 0.35 { return "mostly light and positive" }
        if sentiment >= 0.1 { return "leaning positive" }
        if sentiment <= -0.35 { return "mostly heavy" }
        if sentiment <= -0.1 { return "leaning heavy" }
        return "mixed, with ups and downs"
    }

    /// Renders values in -1...1 as a row of block characters.
    private static func sparkline(_ values: [Double]) -> String {
        let blocks: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let characters: [Character] = values.map { value in
            let safe = value.isNaN ? 0 : value
            let clamped = min(1.0, max(-1.0, safe))
            let position = (clamped + 1.0) / 2.0 * Double(blocks.count - 1)
            let index = min(blocks.count - 1, max(0, Int(position.rounded())))
            return blocks[index]
        }
        return String(characters)
    }

    private static func dropTrailingBlankLines(_ lines: [String]) -> [String] {
        var result = lines
        while let last = result.last, last.isEmpty {
            result.removeLast()
        }
        return result
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
        var cleaned = String(name.unicodeScalars.map { forbidden.contains($0) ? Character("-") : Character($0) })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        if cleaned.isEmpty {
            return "Therapist Copilot export.md"
        }
        if cleaned.count > 150 {
            let ext = (cleaned as NSString).pathExtension
            let base = String((cleaned as NSString).deletingPathExtension.prefix(140))
            cleaned = ext.isEmpty ? base : base + "." + ext
        }
        return cleaned
    }
}
