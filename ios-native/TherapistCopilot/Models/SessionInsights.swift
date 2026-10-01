import Foundation

/// Which in-house engine produced a set of insights.
enum InsightEngineKind: String, Codable, Hashable {
    /// Apple's on-device foundation model (iOS 26+, Apple Intelligence devices).
    case onDeviceModel
    /// The built-in rule-based language analysis. Works on every device.
    case classic

    var label: String {
        switch self {
        case .onDeviceModel: return "On-device AI"
        case .classic: return "Classic analysis"
        }
    }
}

/// How the user wants insights generated (Settings).
enum InsightEnginePreference: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Use the on-device model when the device supports it, otherwise classic.
    case automatic
    /// Always use the classic rule-based engine.
    case classicOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .classicOnly: return "Classic only"
        }
    }

    var detail: String {
        switch self {
        case .automatic: return "Uses Apple's on-device model when your iPhone supports it. Falls back to classic analysis."
        case .classicOnly: return "Always uses the built-in rule-based analysis. Fastest and works on every iPhone."
        }
    }
}

struct ThemeInsight: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Short label, e.g. "Sleep", "Work stress".
    var name: String
    /// How many times the theme came up.
    var mentions: Int
    /// A representative sentence from the transcript, if any.
    var quote: String? = nil
}

struct EmotionInsight: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// e.g. "Anxious", "Hopeful".
    var name: String
    /// 0...1 relative intensity across the session.
    var intensity: Double
    var mentions: Int
}

struct KeyMoment: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// Seconds into the recording when the moment happened, if known.
    var time: TimeInterval? = nil
    /// The sentence (or paraphrase) itself.
    var text: String
    /// Why this was picked, e.g. "Strong emotion", "Insight", "Commitment".
    var reason: String
}

enum SuggestionCategory: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Questions to think or journal about.
    case reflection
    /// A concrete exercise or skill to try this week.
    case practice
    /// Something worth raising with the therapist next time.
    case nextSession
    /// Rest, body, routine.
    case selfCare
    /// A recurring pattern noticed across sessions.
    case pattern

    var id: String { rawValue }

    var label: String {
        switch self {
        case .reflection: return "Reflect"
        case .practice: return "Practice"
        case .nextSession: return "Bring to next session"
        case .selfCare: return "Self-care"
        case .pattern: return "Pattern"
        }
    }

    var systemImage: String {
        switch self {
        case .reflection: return "text.bubble"
        case .practice: return "figure.mind.and.body"
        case .nextSession: return "calendar.badge.clock"
        case .selfCare: return "heart.circle"
        case .pattern: return "arrow.triangle.2.circlepath"
        }
    }
}

struct Suggestion: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var category: SuggestionCategory
    /// One line, e.g. "Try a 5-minute wind-down before bed".
    var title: String
    /// One to three sentences of practical detail.
    var detail: String
    /// Why this was suggested, grounded in the transcript, e.g. "You mentioned sleep 6 times."
    var rationale: String
}

/// A thinking pattern (CBT "cognitive distortion") spotted in the transcript,
/// offered gently with a reframe, never as a diagnosis.
struct ThoughtPattern: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    /// e.g. "All-or-nothing thinking".
    var name: String
    /// Plain-language description of the pattern.
    var description: String
    /// The sentence from the transcript that triggered it.
    var quote: String
    /// A gentle alternative way to look at it.
    var reframe: String
}

/// Everything the app derives from one session's transcript.
struct SessionInsights: Codable, Hashable {
    var engine: InsightEngineKind
    var generatedAt: Date = Date()
    /// 2-5 sentence plain-language summary addressed to the user ("You talked about...").
    var overview: String
    /// 3-7 bullets: what was discussed.
    var highlights: [String]
    var themes: [ThemeInsight]
    var emotions: [EmotionInsight]
    var keyMoments: [KeyMoment]
    var thoughtPatterns: [ThoughtPattern]
    var suggestions: [Suggestion]
    /// Commitments found in the transcript (the user can turn them into ActionItems).
    var detectedActionItems: [String]
    var questionsForNextSession: [String]
    /// Sentiment per equal time bucket across the session, each in -1...1. Usually 8 buckets. Empty if no transcript.
    var moodTrajectory: [Double]
    /// -1...1 average sentiment of the whole transcript.
    var overallSentiment: Double
    /// True when language suggesting a crisis (self-harm, suicide) was detected. The UI shows a supportive resources card.
    var needsSupportFlag: Bool

    /// Insights for a session with no usable transcript (audio only).
    static func empty(engine: InsightEngineKind = .classic) -> SessionInsights {
        SessionInsights(
            engine: engine,
            overview: "No transcript was captured for this session, so there is nothing to analyze yet. You can still listen to the recording and write notes.",
            highlights: [],
            themes: [],
            emotions: [],
            keyMoments: [],
            thoughtPatterns: [],
            suggestions: [],
            detectedActionItems: [],
            questionsForNextSession: [],
            moodTrajectory: [],
            overallSentiment: 0,
            needsSupportFlag: false
        )
    }
}
