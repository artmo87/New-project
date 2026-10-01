# Therapist Copilot — Architecture & Implementation Contract

This document is the single source of truth for how the app is structured and
for the **public API of every file**. Every implementation agent must follow it
exactly so that files written in parallel compile together. If you believe a
signature here is wrong or missing, implement it as written anyway and add a
one-line `// CONTRACT NOTE:` comment explaining what you think should change.

## Product

"Therapist Copilot" is a native SwiftUI iPhone app that:

1. Records a therapy session (long-form, keeps recording with the screen locked).
2. Transcribes it **on-device** with Apple's Speech framework (no network).
3. Produces a session summary, themes, emotions, key moments, thought patterns,
   detected commitments, suggestions, and questions for the next session.
4. Keeps everything on the device: audio files + one JSON store in the app's
   Documents directory. **There is no networking code anywhere in the app.**

Two in-house insight engines:
- `HeuristicInsightEngine` ("Classic") — rule/lexicon-based, uses the
  NaturalLanguage framework (sentence/word tokenization, lemma, sentiment).
  Always available, always runs.
- `FoundationModelsInsightEngine` ("On-device AI") — Apple's on-device
  foundation model (iOS 26+, Apple Intelligence devices). Enriches overview,
  highlights, suggestions and questions. Compiled only under
  `#if canImport(FoundationModels)` and guarded by `@available(iOS 26.0, *)`.
  Falls back to Classic on any error.

## Build facts (do not fight these)

- Xcode project with a file-system-synchronized root folder `TherapistCopilot/`:
  **every file placed under `TherapistCopilot/` is automatically compiled/bundled.**
  Do not put docs or stray files there.
- Deployment target **iOS 17.0**, `SWIFT_VERSION = 5.0` (Swift 5 language mode,
  so concurrency issues are warnings, not errors). Do NOT rely on Swift 6-only
  syntax. Avoid `nonisolated(unsafe)`.
- Frameworks are auto-linked by `import`. Allowed imports: SwiftUI, Foundation,
  AVFoundation, Speech, NaturalLanguage, Charts, LocalAuthentication, Combine,
  UIKit (only where unavoidable), Observation, FoundationModels (only inside
  `#if canImport(FoundationModels)`).
- No third-party packages. No `URLSession`, no network of any kind.
- Use the iOS 17 `@Observable` macro (import Observation / SwiftUI) for
  observable classes — **not** `ObservableObject`/`@Published`.
- Prefer `Task`/`async` over Combine.
- Every file must compile on its own with the imports it declares. Don't assume
  another file's `import` is visible.
- Model types (`TherapySession`, `TranscriptSegment`, `ActionItem`,
  `JournalEntry`, `Speaker`, `SessionInsights`, `ThemeInsight`,
  `EmotionInsight`, `KeyMoment`, `Suggestion`, `SuggestionCategory`,
  `ThoughtPattern`, `InsightEngineKind`, `InsightEnginePreference`) are ALREADY
  WRITTEN in `TherapistCopilot/Models/`. Read them; do not redefine or modify them.
- Only use SwiftUI APIs available on iOS 17: `NavigationStack`, `TabView`,
  `List`, `Form`, `ShareLink`, `ContentUnavailableView`, `.sensoryFeedback`,
  `Chart`/`LineMark`/`BarMark`/`RuleMark`, `.scrollPosition`, `@Bindable`,
  `.onChange(of:) { old, new in }` (two-parameter form), `Text(timerInterval:)`.
  Do NOT use iOS 18+/26-only SwiftUI (no `.glassEffect`, no `Tab(...)` builder
  API, no `@Entry`, no `.presentationSizing`, no `MeshGradient`).

## Directory layout

```
TherapistCopilot/
  TherapistCopilotApp.swift          @main, environment wiring, app lock overlay
  Info.plist                         (exists) mic/speech/FaceID strings, background audio
  Assets.xcassets/                   (exists) AppIcon, AccentColor
  Models/
    TherapySession.swift             (exists)
    SessionInsights.swift            (exists)
  Services/
    AppSettings.swift
    SessionStore.swift
    PermissionsManager.swift
    AudioRecorder.swift
    LiveTranscriber.swift
    RecordingCoordinator.swift
    AudioPlayer.swift
    TherapyLexicon.swift
    HeuristicInsightEngine.swift
    FoundationModelsInsightEngine.swift
    InsightsService.swift
    SessionExporter.swift
    AppLock.swift
  Views/
    RootView.swift
    Home/HomeView.swift
    Recording/PreSessionSheet.swift
    Recording/RecordingView.swift
    Recording/PostSessionView.swift
    Sessions/SessionListView.swift
    Sessions/SessionDetailView.swift
    Sessions/SummaryTab.swift
    Sessions/TranscriptTab.swift
    Sessions/SuggestionsTab.swift
    Sessions/NotesTab.swift
    Sessions/AudioPlayerBar.swift
    Prepare/PrepareView.swift
    Settings/SettingsView.swift
    Shared/Components.swift
    Shared/Formatters.swift
```

## Environment wiring (how views get services)

`TherapistCopilotApp` creates these once with `@State` and injects them with
`.environment(...)`:

```swift
@State private var store = SessionStore()
@State private var settings = AppSettings()
@State private var recorder = RecordingCoordinator()
@State private var insights = InsightsService()
@State private var appLock = AppLock()
```

Views read them with `@Environment(SessionStore.self) private var store` etc.
`AudioPlayer` is NOT in the environment; `SessionDetailView` owns one with `@State`.

---

## Services — exact public API

### `Services/AppSettings.swift`

```swift
import Foundation
import Observation

@Observable
final class AppSettings {
    // All properties persist to UserDefaults immediately on set (didSet).
    var recognitionLocaleIdentifier: String      // default: Locale.current BCP-47 if speech-supported, else "en-US"
    var onDeviceRecognitionOnly: Bool            // default true. When true, requiresOnDeviceRecognition = true and we never use Apple's servers.
    var appLockEnabled: Bool                     // default false
    var insightEnginePreference: InsightEnginePreference   // default .automatic
    var hasAcceptedConsent: Bool                 // default false; set true after the consent screen
    var defaultTherapistName: String             // default ""
    var keepAudioAfterTranscription: Bool        // default true
    var hasSeenOnboarding: Bool                  // default false

    init()                                        // loads from UserDefaults.standard
    var recognitionLocale: Locale { get }        // Locale(identifier: recognitionLocaleIdentifier)
}
```

### `Services/SessionStore.swift`

```swift
import Foundation
import Observation

@MainActor
@Observable
final class SessionStore {
    /// Newest first. Mutate only through the methods below.
    private(set) var sessions: [TherapySession]
    /// Newest first.
    private(set) var journal: [JournalEntry]
    private(set) var loadError: String?

    init()                                     // loads synchronously from disk

    // Sessions
    func add(_ session: TherapySession)        // inserts, re-sorts newest first, saves
    func update(_ session: TherapySession)     // replaces by id (adds if missing), saves
    func modify(_ id: UUID, _ change: (inout TherapySession) -> Void)   // in-place edit + save
    func delete(_ session: TherapySession)     // removes + deletes its audio file + saves
    func session(id: UUID) -> TherapySession?

    // Journal
    func addJournalEntry(_ entry: JournalEntry)
    func updateJournalEntry(_ entry: JournalEntry)
    func deleteJournalEntry(_ entry: JournalEntry)

    // Danger zone
    func deleteAllData()                       // removes all sessions, journal, audio files

    // Files
    static var documentsDirectory: URL { get }
    static var recordingsDirectory: URL { get }     // Documents/Recordings, created if needed
    func newAudioURL(for sessionID: UUID) -> URL    // recordingsDirectory/<uuid>.m4a
    func audioURL(for session: TherapySession) -> URL?   // nil if no file name or file missing
    func deleteAudio(for session: TherapySession)   // removes file, sets audioFileName = nil, saves
    func audioFileSize(for session: TherapySession) -> Int64?

    // Aggregates used by Prepare/Home (types are TOP-LEVEL structs in this file, not nested)
    var openActionItems: [OpenActionItem] { get }    // all not-done items, newest session first
    var pendingQuestions: [PendingQuestion] { get }  // from sessions' nextSessionQuestions
    var recurringThemes: [RecurringTheme] { get }   // themes appearing in >= 2 sessions, by count desc
    func setActionItemDone(sessionID: UUID, itemID: UUID, isDone: Bool)
    func removeQuestion(sessionID: UUID, question: String)
}
```

Top-level types in the same file:
```swift
struct OpenActionItem: Identifiable, Hashable {
    var id: UUID { item.id }
    var sessionID: UUID
    var sessionTitle: String
    var sessionDate: Date
    var item: ActionItem
}
struct PendingQuestion: Identifiable, Hashable {
    var id: String { sessionID.uuidString + "|" + question }
    var sessionID: UUID
    var sessionTitle: String
    var question: String
}
struct RecurringTheme: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var sessionCount: Int
}
```
and `var recurringThemes: [RecurringTheme]` (replace the tuple form above).

Persistence: one file `Documents/therapist-copilot-store.json` containing a
`Codable` struct `{ sessions, journal, version }`. Write atomically with
`.completeFileProtection`. Saving may be done synchronously (files are small).
Also set `isExcludedFromBackup` = false (default; user may want iCloud backup).

### `Services/PermissionsManager.swift`

```swift
import AVFoundation
import Speech

enum PermissionOutcome: Equatable {
    case granted
    case microphoneDenied
    case speechDenied        // user denied speech recognition; recording can continue audio-only
    case speechRestricted    // device restriction / not available
}

enum PermissionsManager {
    static func requestMicrophone() async -> Bool
    static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus
    /// Requests both. Microphone denial is fatal for recording; speech denial is not.
    static func requestAll() async -> PermissionOutcome
    static var microphoneGranted: Bool { get }    // current status, no prompt
    static var speechGranted: Bool { get }
}
```
Use `AVAudioApplication.requestRecordPermission()` (iOS 17) for the mic.

### `Services/AudioRecorder.swift`

Captures microphone audio with `AVAudioEngine`, writes an AAC `.m4a` file via
`AVAudioFile`, and hands every buffer to a callback for live transcription.

```swift
import AVFoundation

final class AudioRecorder {
    enum RecorderError: LocalizedError { case engineUnavailable, fileCreationFailed(String), alreadyRecording }

    /// Called on the audio render thread for every captured buffer.
    /// - elapsed: seconds of *recorded* audio so far (paused time excluded)
    /// - level: 0...1 RMS-based input level for metering
    var onBuffer: ((AVAudioPCMBuffer, TimeInterval, Float) -> Void)?
    /// Called on the main thread when the session is interrupted (began = true) or the
    /// interruption ended (began = false, shouldResume tells whether resuming is advised).
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?
    /// Called on the main thread if the engine stopped unexpectedly (e.g. route change). The
    /// recorder tries to restart itself first; this is informational.
    var onEngineRestart: (() -> Void)?

    private(set) var isRecording: Bool            // true while running (not paused)
    private(set) var isPaused: Bool
    /// Seconds of recorded audio, updated from the render thread (read on main for display).
    private(set) var elapsed: TimeInterval
    private(set) var fileURL: URL?

    init()
    /// Configures AVAudioSession (.playAndRecord, mode .default, options [.defaultToSpeaker, .allowBluetooth]),
    /// activates it, creates the file at `url`, installs the tap and starts the engine.
    func start(to url: URL) throws
    func pause()                      // engine.pause(), isPaused = true
    func resume() throws              // engine.start()
    /// Stops the engine, removes the tap, closes the file, deactivates the session.
    /// Returns the final duration in seconds.
    @discardableResult func stop() -> TimeInterval
}
```
Implementation notes: use `inputNode.outputFormat(forBus: 0)`; guard sampleRate > 0
and channelCount > 0. Create `AVAudioFile(forWriting:settings:commonFormat:interleaved:)`
with `AVFormatIDKey: kAudioFormatMPEG4AAC`, `AVSampleRateKey: format.sampleRate`,
`AVNumberOfChannelsKey: format.channelCount`, `AVEncoderBitRateKey: 64_000`,
commonFormat = format.commonFormat, interleaved = format.isInterleaved. Tap buffer size
4096. Compute elapsed from frames written / sampleRate. Observe
`AVAudioSession.interruptionNotification`, `AVAudioSession.routeChangeNotification`,
and `.AVAudioEngineConfigurationChange`. The file must stay valid if the app is
suspended; `UIBackgroundModes` contains `audio` so recording continues when locked.

### `Services/LiveTranscriber.swift`

On-device speech recognition for long sessions using **segment rotation**: a
`SFSpeechAudioBufferRecognitionRequest` is ended and a new one started about every
30–55 s (preferably during a pause in speech), so recognition never degrades on
long recordings and the transcript gets timestamps.

```swift
import Foundation
import Speech
import AVFoundation

/// NOT actor-isolated (so `append` can run on the audio thread). All callbacks are
/// delivered on the main thread; call the non-`append` methods from the main thread.
final class LiveTranscriber {
    enum TranscriberError: LocalizedError {
        case recognizerUnavailable(Locale)
        case onDeviceUnsupported(Locale)
        case notAuthorized
    }

    /// Partial text of the segment currently being recognized. Main thread.
    var onPartial: ((String) -> Void)?
    /// A finished segment. Main thread.
    var onSegment: ((TranscriptSegment) -> Void)?
    /// Non-fatal recognition problem to surface as a banner. Main thread.
    var onWarning: ((String) -> Void)?

    let locale: Locale
    let onDeviceOnly: Bool

    /// Throws if no recognizer exists for the locale, if onDeviceOnly and the locale does not
    /// support on-device recognition, or if speech recognition is not authorized.
    init(locale: Locale, onDeviceOnly: Bool) throws

    /// Begin the first segment at `time` seconds (normally 0).
    func start(at time: TimeInterval)
    /// Thread-safe; call from the audio render thread for each buffer.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Call on the main thread ~10x/second with the recorder's elapsed time and level.
    /// Decides when to rotate segments (elapsed >= 30 s and quiet for > 1 s, or hard cap 55 s).
    func tick(time: TimeInterval, level: Float)
    /// Ends the current segment right now (used on pause). Safe to call repeatedly.
    func rotate(at time: TimeInterval)
    /// Ends audio for the last segment and waits (max 4 s) for its final result.
    func finish(at time: TimeInterval) async

    /// Locales with an SFSpeechRecognizer, sorted by localized name.
    static var supportedLocales: [Locale] { get }
    static func supportsOnDevice(_ locale: Locale) -> Bool
    static func isAvailable(_ locale: Locale) -> Bool
}
```
Implementation notes: `shouldReportPartialResults = true`,
`requiresOnDeviceRecognition = onDeviceOnly`, `addsPunctuation = true`,
`taskHint = .dictation`. Keep the current request behind an `NSLock` so `append`
from the audio thread and rotation on main don't race. Each segment keeps its
own small context object (start time, latest text, committed flag); when the
task reports `isFinal` or an error, commit the best text (ignore empty) exactly
once with `end` = rotation time. Treat the common "no speech detected" error as
a silent empty segment. `SFSpeechRecognizer.queue` defaults to main, so callbacks
arrive on the main thread.

### `Services/RecordingCoordinator.swift`

The state machine the recording UI binds to. Owns an `AudioRecorder` and an
optional `LiveTranscriber` and glues them together.

```swift
import Foundation
import Observation
import AVFoundation

@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable { case idle, preparing, recording, paused, finishing }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0        // updated ~10x/s from a Timer while recording
    private(set) var level: Float = 0                 // 0...1 smoothed
    private(set) var committedSegments: [TranscriptSegment] = []
    private(set) var partialText: String = ""
    /// True when live transcription is running. False → audio-only recording (banner in UI).
    private(set) var transcriptionActive: Bool = false
    /// Human-readable non-fatal problem (e.g. transcription unavailable, interruption).
    var warning: String?
    /// Fatal error that prevented starting; UI shows an alert and returns.
    var errorMessage: String?
    /// The session being recorded (title, therapist, moodBefore set from PreSessionSheet).
    private(set) var draft: TherapySession?

    init()

    /// Requests permissions, configures recorder + transcriber, starts. On failure sets
    /// `errorMessage` and returns to .idle. `audioURL` comes from store.newAudioURL(for:).
    func start(draft: TherapySession, audioURL: URL, locale: Locale, onDeviceOnly: Bool) async
    func pause()
    func resume()
    /// Stops recording and transcription, waits for the final segment, and returns the
    /// completed draft with `duration`, `segments`, `audioFileName`, `transcriptLanguage` filled in.
    /// Returns nil if nothing was recording.
    func finish() async -> TherapySession?
    /// Stops and deletes the audio file; discards everything.
    func cancel()

    var liveTranscript: String { get }   // committed texts + partial, for display
}
```
Interruptions: on began → `pause()` and set `warning`. On ended with
shouldResume → `resume()`. Keep a `Timer.publish`-free approach: a repeating
`Timer.scheduledTimer` (0.1 s) on main that copies recorder.elapsed/level into
the observable properties and calls `transcriber.tick`.

### `Services/AudioPlayer.swift`

```swift
import Foundation
import Observation
import AVFoundation

@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded: Bool = false
    var rate: Float = 1.0                // 1.0, 1.25, 1.5, 2.0; applies live

    init()
    func load(url: URL) throws           // AVAudioPlayer, enableRate = true, prepareToPlay; sets AVAudioSession to .playback
    func play()
    func pause()
    func toggle()
    func seek(to time: TimeInterval)
    func skip(by seconds: TimeInterval)
    func stop()                          // stops, invalidates timer, deactivates session
}
```
Use a 0.2 s `Timer` to update `currentTime`; when the player finishes
(`!player.isPlaying && currentTime >= duration - 0.1`) set `isPlaying = false`.

### `Services/TherapyLexicon.swift`

Pure data (no imports beyond Foundation). All strings lower-case, matched
against lemmatized/lower-cased tokens and against the raw lower-cased sentence
for multi-word phrases.

```swift
import Foundation

enum TherapyLexicon {
    struct Theme { let name: String; let keywords: [String]; let suggestions: [Suggestion]; let questions: [String] }
    struct Emotion { let name: String; let valence: Double /* -1...1 */; let keywords: [String] }
    struct DistortionRule { let name: String; let description: String; let patterns: [String] /* lower-case words/phrases */; let reframe: String }

    static let themes: [Theme]                 // >= 14 themes: Anxiety & worry, Low mood, Sleep, Work & career, Relationships, Family, Self-worth, Anger & irritability, Grief & loss, Trauma & safety, Health & body, Money, Loneliness, Habits & substances, Boundaries, Change & transitions, Identity, Parenting
    static let emotions: [Emotion]             // >= 16: anxious, sad, angry, ashamed, guilty, lonely, overwhelmed, hopeful, calm, proud, grateful, afraid, frustrated, hurt, numb, relieved, confused, exhausted, motivated, jealous
    static let distortions: [DistortionRule]   // >= 8 CBT patterns
    static let commitmentPatterns: [String]    // "i will", "i'll", "i'm going to", "going to try", "try to", "homework", "practice", "before next session", "next week i", "my goal", "commit to", "plan to", "i want to start", "i need to", "i should start"
    static let crisisPatterns: [String]        // self-harm / suicide phrases; conservative but comprehensive
    static let positiveWords: Set<String>, negativeWords: Set<String>   // fallback sentiment lexicon (>= 80 each)
    static let stopWords: Set<String>          // English stop words (>= 120)
    static let fillerWords: Set<String>        // "um", "uh", "like", "you know", "kind of" ...
    static let generalSuggestions: [Suggestion]   // 6-10 always-relevant suggestions (post-session reflection, action-item review, etc.)
    static let supportResources: [(title: String, detail: String)]   // e.g. ("If you are in the US", "Call or text 988 ..."), ("Elsewhere", "Contact local emergency services ..."), ("Tell someone", ...)
}
```
Every `Suggestion` in the lexicon must have a non-empty `rationale` template
that may contain the token `{n}` (replaced by the number of mentions) and
`{theme}`.

### `Services/HeuristicInsightEngine.swift`

```swift
import Foundation
import NaturalLanguage

struct HeuristicInsightEngine {
    /// Pure function: analyzes the session's transcript. `history` = other sessions (newest first)
    /// used for cross-session "pattern" suggestions and recurring-theme detection.
    func analyze(_ session: TherapySession, history: [TherapySession]) -> SessionInsights
}
```
Pipeline (must implement all):
1. Build sentences from `session.segments` (NLTokenizer .sentence per segment,
   keep each sentence's segment start time). Drop sentences < 3 words.
2. Tokens per sentence: NLTokenizer .word, lower-cased; lemma via NLTagger
   (.lemma) with fallback to the token; drop stop words & fillers for scoring.
3. Sentiment per sentence: NLTagger(.sentimentScore) on the sentence
   (English-only in practice); if nil/0 and the language isn't supported, fall
   back to lexicon counts (positive − negative)/(total+1) clamped to −1…1.
4. Themes: count keyword matches (lemmas + raw phrase search). Keep themes with
   ≥ 2 mentions (or the top 3 if none reach 2 but any match), max 6, with a
   representative quote (the shortest sentence ≥ 6 words containing a keyword).
5. Emotions: same approach with emotion keywords; intensity = mentions / max
   mentions; keep up to 6 with ≥ 1 mention.
6. Thought patterns: for each DistortionRule, find the first sentence that
   contains any pattern; produce up to 4 `ThoughtPattern`s with the sentence as quote.
7. Detected action items: sentences containing a commitment pattern, cleaned
   (capitalized, trailing punctuation), de-duplicated, max 8.
8. Key moments: score = |sentiment| * 2 + themeHits * 0.5 + commitment bonus 1.5
   + distortion bonus 1.0 + insight-phrase bonus 1.5 ("i realized", "i think the
   reason", "i noticed", "it makes sense", "i never thought"). Top 5 in time
   order; reason strings: "Strong emotion", "Insight", "Commitment", "Thinking pattern", "Core theme".
9. Highlights: extractive — TextRank-lite: word frequency of content lemmas;
   sentence score = sum(freq)/sqrt(len) + 0.3 for sentences in first/last 10% +
   theme bonus; pick top 5 distinct sentences, order by time, trim to ≤ 180 chars,
   prefix nothing (they are the bullets).
10. Overview: 2–4 sentences composed from templates, addressed as "you":
    duration + main themes + dominant emotions + sentiment trend + commitments count.
    Example: "In this 48-minute session you mainly talked about work stress and
    sleep. Anxious and tired came through most often, and the tone lifted toward
    the end. You made 2 commitments for the week."
11. Mood trajectory: split sentences into 8 equal time buckets by `start`;
    mean sentiment per bucket (0 if empty bucket but neighbours interpolated);
    `overallSentiment` = mean over sentences.
12. Suggestions: for each kept theme, take up to 2 suggestions from the lexicon
    (fill `{n}`/`{theme}` in rationale). Add 1–2 emotion-driven suggestions
    (e.g. overwhelmed → grounding), 1 per thought pattern (category .reflection,
    using the reframe), 2 `generalSuggestions`, and `.pattern` suggestions when a
    theme recurs in ≥ 2 history sessions ("Work stress has come up in 3 of your
    last 4 sessions..."). Cap at 10, de-dupe by title.
13. Questions for next session: theme questions from the lexicon (up to 4) +
    one per thought pattern ("Could we look at the thought '...'?") , cap 6.
14. `needsSupportFlag`: any crisisPattern found in the full lower-cased text.
15. If there is no usable transcript, return `SessionInsights.empty()`.

### `Services/FoundationModelsInsightEngine.swift`

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Wrapper that is safe to reference on any iOS version.
enum OnDeviceModelSupport {
    /// True only on iOS 26+ with Apple Intelligence available right now.
    static var isAvailable: Bool { get }
    /// Short user-facing status, e.g. "Available", "Not supported on this iPhone", "Apple Intelligence is off", "Model downloading".
    static var statusDescription: String { get }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
struct FoundationModelsInsightEngine {
    /// Produces an enriched copy of `base` (the Classic insights for the same session):
    /// replaces overview/highlights, merges suggestions (model suggestions first, keep
    /// base's .pattern suggestions), merges questions, and sets engine = .onDeviceModel.
    /// Throws on any model error; the caller falls back to `base`.
    func enrich(base: SessionInsights, session: TherapySession) async throws -> SessionInsights
}
#endif
```
Implementation: chunk the transcript into ~1200-word chunks; for each chunk use a
fresh `LanguageModelSession(instructions:)` and `respond(to:)` to get 3–6 bullet
notes (String). Then one structured call `respond(to:generating:)` with a
`@Generable` struct (overview: String, highlights: [String], suggestions:
[String], questionsForNextSession: [String], detectedCommitments: [String]).
Instructions must say: supportive, non-clinical, second person, never diagnose,
never give medical advice, keep each item short. Map suggestions to
`Suggestion(category: .practice or .reflection by simple keyword check, title: first
sentence, detail: full text, rationale: "Suggested by the on-device model from this
session's transcript.")`. Check availability via `SystemLanguageModel.default.availability`
with a `switch` that has a `default:` branch.

### `Services/InsightsService.swift`

```swift
import Foundation
import Observation

@MainActor
@Observable
final class InsightsService {
    private(set) var isWorking: Bool = false
    private(set) var statusText: String = ""     // "Analyzing transcript…", "Asking on-device model…"

    init()
    /// Always runs Classic; then, if preference == .automatic and OnDeviceModelSupport.isAvailable,
    /// tries FoundationModelsInsightEngine.enrich (off the main actor via Task.detached is fine) and
    /// falls back to Classic on error. Never throws.
    func generate(for session: TherapySession, history: [TherapySession], preference: InsightEnginePreference) async -> SessionInsights
}
```

### `Services/SessionExporter.swift`

```swift
import Foundation

enum SessionExporter {
    /// Full Markdown report: header, mood, overview, highlights, themes, emotions, key moments,
    /// thought patterns, action items, suggestions, questions, notes, then the timestamped transcript.
    static func markdown(for session: TherapySession) -> String
    /// Only the transcript with [mm:ss] timestamps and speaker labels.
    static func transcriptText(for session: TherapySession) -> String
    /// All sessions + journal as one Markdown document.
    static func fullExport(sessions: [TherapySession], journal: [JournalEntry]) -> String
    /// Writes text to a temporary file and returns its URL (for ShareLink). nil on failure.
    static func temporaryFile(named name: String, contents: String) -> URL?
}
```

### `Services/AppLock.swift`

```swift
import Foundation
import Observation
import LocalAuthentication

@MainActor
@Observable
final class AppLock {
    private(set) var isLocked: Bool = false
    private(set) var isAuthenticating: Bool = false
    var lastError: String?

    init()
    static var biometryName: String { get }        // "Face ID" / "Touch ID" / "Passcode"
    static var canAuthenticate: Bool { get }       // LAContext.canEvaluatePolicy(.deviceOwnerAuthentication)
    /// Call when the scene goes to background/inactive if settings.appLockEnabled.
    func lock()
    /// Prompts with .deviceOwnerAuthentication; on success isLocked = false.
    func unlock() async
}
```

---

## Views — exact public API

All views are `struct X: View` with the initializers below. Use the environment
objects listed in "Environment wiring". Keep each view file self-contained
(private subviews inside the same file).

### `Shared/Components.swift` (used everywhere — implement first, exactly)

```swift
import SwiftUI

/// Rounded card background with padding.
struct CardView<Content: View>: View {
    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content)
}
/// Small capsule tag.
struct ChipView: View { init(_ text: String, systemImage: String? = nil, tint: Color = .accentColor) }
/// 1...10 mood picker with emoji + label; binds an optional Int.
struct MoodSlider: View { init(title: String, mood: Binding<Int?>) }
/// Horizontal bar meter for mic level 0...1.
struct LevelMeterView: View { init(level: Float) }
/// Big round record button.
struct RecordButton: View { init(isRecording: Bool, action: @escaping () -> Void) }
/// Section header text styled consistently.
struct SectionHeader: View { init(_ text: String) }
/// Static resources card shown when insights.needsSupportFlag is true.
struct SupportResourcesCard: View { init() }
/// Mood 1...10 → emoji and short label helpers.
enum MoodScale {
    static func emoji(for mood: Int) -> String
    static func label(for mood: Int) -> String
    static func color(for mood: Int) -> Color
}
```

### `Shared/Formatters.swift`

```swift
import Foundation

enum Formatters {
    static func clock(_ seconds: TimeInterval) -> String          // "mm:ss" or "h:mm:ss"
    static func durationWords(_ seconds: TimeInterval) -> String  // "48 min", "1 h 05 min", "45 s"
    static func shortDate(_ date: Date) -> String                 // "Oct 1"
    static func dateTime(_ date: Date) -> String                  // "Oct 1, 2026 at 3:15 PM"
    static func relative(_ date: Date) -> String                  // "2 days ago"
    static func fileSize(_ bytes: Int64) -> String
}
```

### `TherapistCopilotApp.swift`
`@main struct TherapistCopilotApp: App`. Creates the services (see wiring),
shows `RootView()`, observes `scenePhase`: when `.background`/`.inactive` and
`settings.appLockEnabled` → `appLock.lock()`; when `.active` and `appLock.isLocked`
→ `Task { await appLock.unlock() }`. Overlays a lock screen (`LockScreenView`,
private in this file) with an "Unlock" button when `appLock.isLocked`.

### `Views/RootView.swift`
`struct RootView: View { init() }`. If `!settings.hasSeenOnboarding` show
`OnboardingView` (private in this file: 3 short pages — what it does, privacy
"everything stays on your iPhone, no internet", consent reminder "tell your
therapist you're recording; laws differ by place"; button sets
`hasSeenOnboarding = true` and `hasAcceptedConsent = true`). Otherwise a `TabView`
with: Home (`house`), Sessions (`list.bullet.rectangle`), Prepare (`checklist`),
Settings (`gearshape`). Use an enum `AppTab` selection stored with `@State`.

### `Views/Home/HomeView.swift`
`struct HomeView: View { init() }`. NavigationStack. Greeting + date; the big
`RecordButton` opening `PreSessionSheet` as a sheet; a "Last session" card
(mood change, top themes, open items count) linking to `SessionDetailView`;
"Up next" card with up to 3 open action items (toggle done) and up to 2 pending
questions; "Mood over time" mini chart (last 10 sessions moodAfter) when ≥ 2
sessions. Full-screen cover `RecordingView` is presented when
`recorder.state != .idle` (binding derived from state). PreSessionSheet, on
confirm, calls `recorder.start(...)` and the Home view then presents
`RecordingView` full-screen.

### `Views/Recording/PreSessionSheet.swift`
`struct PreSessionSheet: View { init(onStart: @escaping (TherapySession) -> Void) }`.
Form: title (TextField, placeholder "Session title (optional)"), therapist name
(prefilled from settings.defaultTherapistName), `MoodSlider("How do you feel right now?")`,
language row showing `settings.recognitionLocale` name with a note if on-device
isn't supported, consent reminder footer, "Start recording" button → builds
a `TherapySession` draft and calls `onStart`, then dismisses.

### `Views/Recording/RecordingView.swift`
`struct RecordingView: View { init(onFinished: @escaping (TherapySession) -> Void) }`.
Shows elapsed `Formatters.clock(recorder.elapsed)`, `LevelMeterView`, a pulsing
red dot while recording, warning banner (`recorder.warning`), "audio only" banner
when `!recorder.transcriptionActive`, live transcript (ScrollViewReader, auto
scroll to bottom, committed text in primary, partial in secondary), buttons:
Pause/Resume, Stop (confirmation dialog "Finish session?"), Cancel (destructive
confirmation). On Stop → `await recorder.finish()` → `onFinished(session)`.
Keeps the screen awake with `UIApplication.shared.isIdleTimerDisabled` on appear/disappear.

### `Views/Recording/PostSessionView.swift`
`struct PostSessionView: View { init(session: TherapySession, onDone: @escaping () -> Void) }`.
Step 1: `MoodSlider("How do you feel now?")` + optional quick note, "Continue".
Step 2: processing — saves the session to the store (`store.add`), runs
`insights.generate(...)`, stores results in the session (`store.modify`), also
converts `detectedActionItems` into `ActionItem(source: .detected)` and copies
`questionsForNextSession` into `nextSessionQuestions` (if the session has none).
Shows `insights.statusText` with a ProgressView, then a "Done" button that
calls `onDone()`; show a NavigationLink/button "Open session" that pushes
`SessionDetailView(sessionID:)`. Handle the audio-only case gracefully.

### `Views/Sessions/SessionListView.swift`
`struct SessionListView: View { init() }`. NavigationStack, searchable (title,
therapist, transcript, theme names), grouped by month, row shows title, date,
duration, mood emojis, top 2 theme chips, "audio only" badge. Swipe to delete
(confirm). Empty state `ContentUnavailableView`. Row → `SessionDetailView(sessionID:)`.

### `Views/Sessions/SessionDetailView.swift`
`struct SessionDetailView: View { init(sessionID: UUID) }`. Reads the session from
the store (if nil → ContentUnavailableView). Header (editable title via toolbar
"Rename" alert, date, duration, moods). `@State private var player = AudioPlayer()`;
`AudioPlayerBar(player:session:)` if audio exists. Segmented `Picker` for tabs:
Summary / Transcript / Suggestions / Notes → `SummaryTab`, `TranscriptTab`,
`SuggestionsTab`, `NotesTab`. Toolbar menu: Regenerate insights (runs
`insights.generate` and `store.modify`), Share report (`ShareLink(item: markdownURL)`),
Share transcript, Share audio (if any), Delete audio only, Delete session (confirm).
Shows `SupportResourcesCard` at top of Summary when `needsSupportFlag`.

### `Views/Sessions/SummaryTab.swift`
`struct SummaryTab: View { init(sessionID: UUID, player: AudioPlayer) }`.
Overview card; engine badge (`insights.engine.label`); highlights bullets;
themes chips with mention counts; emotions as horizontal bars (intensity);
mood trajectory `Chart` (LineMark over bucket index, y −1…1, with a RuleMark at 0)
when `moodTrajectory.count >= 2`; key moments list (tap → `player.seek(to:)` +
`player.play()` when audio exists); thought patterns cards (name, quote, reframe);
Action items section (checklist with toggle, add new item TextField, delete swipe);
Detected commitments → "Add" buttons that create ActionItems (hide those already added).
If no insights yet: button "Generate insights".

### `Views/Sessions/TranscriptTab.swift`
`struct TranscriptTab: View { init(sessionID: UUID, player: AudioPlayer) }`.
Search field filtering segments; list of segments: timestamp button (seeks
player), speaker chip (tap cycles `speaker.next`, saved via store.modify),
text (editable in an edit sheet per segment), highlight the segment containing
`player.currentTime`. Footer: word count, language. Empty → explanation.

### `Views/Sessions/SuggestionsTab.swift`
`struct SuggestionsTab: View { init(sessionID: UUID) }`.
Grouped by `SuggestionCategory` in CaseIterable order; card shows title, detail,
rationale (italic, secondary). Buttons: "Add to action items" (creates
`ActionItem(source: .suggestion)`, disabled if already there) and, for
`.nextSession`/`.reflection`, "Save as question" (appends to
`nextSessionQuestions`). Questions for next session section with add/delete.

### `Views/Sessions/NotesTab.swift`
`struct NotesTab: View { init(sessionID: UUID) }`. `TextEditor` bound to notes
(save on change via store.modify, debounced is not required), tags editor
(add/remove chips), therapist name field, session stats (word count, audio size).

### `Views/Sessions/AudioPlayerBar.swift`
`struct AudioPlayerBar: View { init(player: AudioPlayer, session: TherapySession) }`.
Loads the audio on appear via `store.audioURL(for:)`; play/pause, −15 s, +15 s,
Slider seek, time labels, rate menu (1×, 1.25×, 1.5×, 2×). Stops player on disappear.

### `Views/Prepare/PrepareView.swift`
`struct PrepareView: View { init() }`. NavigationStack "Prepare". Sections:
"Open commitments" (toggle done; link to session), "Questions to bring"
(delete swipe; add free-form question → attaches to the latest session, or shows
hint if none), "Recurring themes" (`store.recurringThemes`), "Mood trend" Chart
across sessions (moodBefore/moodAfter per session), "Journal" (list + add sheet
with MoodSlider + TextEditor; delete swipe), and "Share prep sheet" `ShareLink`
with a Markdown summary of open items + questions + recent themes.

### `Views/Settings/SettingsView.swift`
`struct SettingsView: View { init() }`. Form sections:
- Transcription: language Picker over `LiveTranscriber.supportedLocales` (show
  "on-device" marker), toggle `onDeviceRecognitionOnly` with footer explaining
  that turning it off sends audio to Apple's speech servers (default on).
- Insights: Picker `insightEnginePreference`; row "On-device AI: {OnDeviceModelSupport.statusDescription}".
- Privacy: toggle `appLockEnabled` (disabled if `!AppLock.canAuthenticate`), toggle `keepAudioAfterTranscription`.
- Defaults: therapist name TextField.
- Data: storage used (sum of audio sizes), "Export everything" ShareLink
  (`SessionExporter.fullExport`), "Delete all data" (destructive, confirm).
- About: version, "How it works" (no internet, where data lives), "Not medical
  advice" disclaimer, "Recording consent" note, support resources.

---

## Behavioral rules

- Never block the main thread with analysis: run `HeuristicInsightEngine.analyze`
  inside `Task.detached` or `await Task { }` off-main from `InsightsService`.
- All user-facing copy: warm, plain, non-clinical. Never say "diagnosis".
- The app must work fully offline and with no Apple Intelligence.
- Deleting a session must delete its audio file.
- Dates shown with `Formatters`.


---

## Swift concurrency cookbook (Swift 5 mode, but isolation violations are still ERRORS)

- A `@MainActor` class's stored properties and methods may only be touched from
  main-actor context. Closures handed to `Timer`, `NotificationCenter`,
  `DispatchQueue`, `AVAudioEngine` taps, `SFSpeechRecognizer` result handlers,
  `LAContext` and similar are **not** main-actor isolated. Inside them, hop first:
  ```swift
  timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.tickFromTimer() }
  }
  ```
  or use `MainActor.assumeIsolated { }` when you *know* you're on main (notifications
  posted on main). Prefer the `Task { @MainActor in }` form.
- Never read `self.someProperty` of a `@MainActor` object inside an audio-thread
  callback. Capture what you need as locals first:
  ```swift
  let transcriber = self.transcriber           // non-isolated class, safe to capture
  recorder.onBuffer = { buffer, _, _ in transcriber?.append(buffer) }
  ```
- Plain (non-isolated) classes like `AudioRecorder` and `LiveTranscriber` deliver
  their callbacks on the main thread via `DispatchQueue.main.async`; the
  coordinator's callback closures then hop with `Task { @MainActor in }` anyway
  (cheap and always correct).
- `@Observable` classes: do not combine with `ObservableObject`. Do not use
  `@Published`. Views use `@Environment(Type.self)` or `@State`/`@Bindable`.
- Async bridging of callback APIs: `await withCheckedContinuation { cont in ... }`
  — resume exactly once.
- `Task.detached` for CPU work (`HeuristicInsightEngine.analyze` is a pure struct
  method, fine to call off-main). Return the value and apply it on main.
- Do not mark closures `@Sendable` yourself; do not use `nonisolated(unsafe)`.
- `AudioRecorder.elapsed`/`level` are written on the audio thread and read on
  main; protect them with an `NSLock` (a tiny `LockedValue<T>` helper is fine).
