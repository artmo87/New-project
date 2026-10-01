import Foundation

/// Who said a given transcript segment. Assigned manually by the user (on-device
/// speech recognition does not identify speakers).
enum Speaker: String, Codable, CaseIterable, Identifiable, Hashable {
    case unknown
    case me
    case therapist

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unknown: return "Unassigned"
        case .me: return "Me"
        case .therapist: return "Therapist"
        }
    }

    /// Cycles unknown -> me -> therapist -> unknown.
    var next: Speaker {
        switch self {
        case .unknown: return .me
        case .me: return .therapist
        case .therapist: return .unknown
        }
    }
}

/// One committed piece of transcript with its position in the recording.
struct TranscriptSegment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Seconds from the start of the recording.
    var start: TimeInterval
    /// Seconds from the start of the recording.
    var end: TimeInterval
    var text: String
    var speaker: Speaker = .unknown
}

/// A commitment / homework item connected to a session.
struct ActionItem: Identifiable, Codable, Hashable {
    enum Source: String, Codable, Hashable {
        /// Found automatically in the transcript.
        case detected
        /// Typed by the user.
        case manual
        /// Added from a suggestion card.
        case suggestion
    }

    var id: UUID = UUID()
    var text: String
    var isDone: Bool = false
    var source: Source = .manual
    var createdAt: Date = Date()
}

/// A recorded therapy session and everything derived from it.
struct TherapySession: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var title: String = ""
    var therapistName: String = ""
    /// Recorded duration in seconds (excludes paused time).
    var duration: TimeInterval = 0
    /// File name inside the Recordings directory, e.g. "<uuid>.m4a". nil when no audio was kept.
    var audioFileName: String? = nil
    var segments: [TranscriptSegment] = []
    /// 1...10 mood check-in before the session.
    var moodBefore: Int? = nil
    /// 1...10 mood check-in right after the session.
    var moodAfter: Int? = nil
    var notes: String = ""
    var insights: SessionInsights? = nil
    var actionItems: [ActionItem] = []
    var nextSessionQuestions: [String] = []
    var tags: [String] = []
    /// BCP-47 identifier of the recognition locale used, e.g. "en-US".
    var transcriptLanguage: String = "en-US"

    // MARK: Derived

    var transcriptText: String {
        segments.map { $0.text }.joined(separator: " ")
    }

    var wordCount: Int {
        transcriptText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    var hasTranscript: Bool {
        segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "Session · " + createdAt.formatted(date: .abbreviated, time: .omitted)
    }

    /// moodAfter - moodBefore when both are present.
    var moodChange: Int? {
        guard let before = moodBefore, let after = moodAfter else { return nil }
        return after - before
    }

    var openActionItems: [ActionItem] {
        actionItems.filter { !$0.isDone }
    }
}

/// A short reflection written between sessions.
struct JournalEntry: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    /// 1...10 mood at the time of writing.
    var mood: Int? = nil
    var text: String
}
