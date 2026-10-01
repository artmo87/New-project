import Foundation
import Speech
import AVFoundation

/// On-device speech recognition for long recordings, built around *segment rotation*.
///
/// A single `SFSpeechAudioBufferRecognitionRequest` degrades on long audio (and server-based
/// recognition is capped at about a minute), so the transcriber ends the current request and
/// starts a fresh one roughly every 30–55 seconds, preferably during a pause in speech. Each
/// finished request becomes one `TranscriptSegment` with a start and end time.
///
/// NOT actor-isolated so that `append` can run on the audio render thread. Every callback is
/// delivered on the main thread; call the non-`append` methods from the main thread.
final class LiveTranscriber {

    enum TranscriberError: LocalizedError {
        case recognizerUnavailable(Locale)
        case onDeviceUnsupported(Locale)
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .recognizerUnavailable(let locale):
                return "Speech recognition isn't available for \(LiveTranscriber.displayName(for: locale)) right now."
            case .onDeviceUnsupported(let locale):
                return "On-device transcription isn't supported for \(LiveTranscriber.displayName(for: locale)) on this iPhone. You can choose another language in Settings."
            case .notAuthorized:
                return "Speech recognition permission hasn't been granted. You can allow it in Settings > Privacy & Security > Speech Recognition."
            }
        }
    }

    // MARK: Callbacks (main thread)

    /// Partial text of the audio that has not been committed to a segment yet. Main thread.
    var onPartial: ((String) -> Void)?
    /// A finished segment. Main thread.
    var onSegment: ((TranscriptSegment) -> Void)?
    /// Non-fatal recognition problem to surface as a banner. Main thread.
    var onWarning: ((String) -> Void)?

    let locale: Locale
    let onDeviceOnly: Bool

    // MARK: Tuning

    private enum Tuning {
        /// Input level (0...1) below which the room counts as quiet.
        static let quietLevel: Float = 0.08
        /// How long it must stay quiet before a soft rotation is allowed.
        static let quietDuration: TimeInterval = 1.0
        /// Rotate at the next quiet moment once a segment is this long.
        static let softRotation: TimeInterval = 30
        /// Rotate no matter what once a segment is this long.
        static let hardRotation: TimeInterval = 55
        /// How long `finish(at:)` waits for the last final result.
        static let finishTimeout: TimeInterval = 4.0
        /// Polling interval while waiting for the last final result.
        static let pollNanoseconds: UInt64 = 100_000_000
        /// Pause before starting a new segment after the recognizer failed on its own.
        static let failureBackoff: TimeInterval = 2.0
        /// Consecutive real failures before the user is told about it.
        static let failuresBeforeWarning = 3
    }

    // MARK: Segment bookkeeping

    /// Everything we know about one recognition request. Main thread only.
    private final class SegmentContext {
        let start: TimeInterval
        var end: TimeInterval
        var latestText = ""
        var committed = false
        var task: SFSpeechRecognitionTask?

        init(start: TimeInterval) {
            self.start = start
            self.end = start
        }
    }

    /// Forwards recognizer availability changes to the main thread.
    private final class AvailabilityObserver: NSObject, SFSpeechRecognizerDelegate {
        var onChange: ((Bool) -> Void)?

        func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
            let handler = onChange
            DispatchQueue.main.async {
                handler?(available)
            }
        }
    }

    private let recognizer: SFSpeechRecognizer
    private let availabilityObserver = AvailabilityObserver()

    // Shared with the audio thread; guarded by `lock`.
    private let lock = NSLock()
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var appendedFrames: Int = 0

    // Main thread only.
    private var currentContext: SegmentContext?
    private var pendingContexts: [SegmentContext] = []
    private var hasStarted = false
    private var isFinished = false
    private var lastTickTime: TimeInterval = 0
    private var quietSince: TimeInterval?
    private var nextSegmentAllowedAt: TimeInterval = 0
    private var consecutiveFailures = 0
    private var lastPublishedPartial = ""

    // MARK: Init

    /// Throws if no recognizer exists for the locale, if `onDeviceOnly` and the locale does not
    /// support on-device recognition, or if speech recognition is not authorized.
    init(locale: Locale, onDeviceOnly: Bool) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError.recognizerUnavailable(locale)
        }
        if onDeviceOnly && !recognizer.supportsOnDeviceRecognition {
            throw TranscriberError.onDeviceUnsupported(locale)
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw TranscriberError.notAuthorized
        }

        recognizer.defaultTaskHint = .dictation
        // Result handlers are delivered on this queue; keeping it on main is what makes every
        // callback of this class a main-thread callback.
        recognizer.queue = OperationQueue.main

        self.locale = locale
        self.onDeviceOnly = onDeviceOnly
        self.recognizer = recognizer

        recognizer.delegate = availabilityObserver
        availabilityObserver.onChange = { [weak self] available in
            guard let self = self, !available, self.hasStarted, !self.isFinished else { return }
            self.onWarning?("Speech recognition became unavailable for a moment. Your audio is still being recorded.")
        }
    }

    deinit {
        for context in pendingContexts {
            context.task?.cancel()
        }
    }

    // MARK: Public API

    /// Begin the first segment at `time` seconds (normally 0).
    func start(at time: TimeInterval) {
        guard !hasStarted else { return }
        hasStarted = true
        isFinished = false
        lastTickTime = time
        quietSince = nil
        nextSegmentAllowedAt = time
        consecutiveFailures = 0
        lastPublishedPartial = ""
        beginSegment(at: time)
    }

    /// Thread-safe; call from the audio render thread for each buffer.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock()
        let request = currentRequest
        if request != nil {
            appendedFrames += Int(buffer.frameLength)
        }
        lock.unlock()
        request?.append(buffer)
    }

    /// Call on the main thread ~10x/second with the recorder's elapsed time and level.
    /// Decides when to rotate segments (elapsed >= 30 s and quiet for > 1 s, or hard cap 55 s).
    func tick(time: TimeInterval, level: Float) {
        guard hasStarted, !isFinished else { return }
        lastTickTime = max(lastTickTime, time)

        if level < Tuning.quietLevel {
            if quietSince == nil {
                quietSince = time
            }
        } else {
            quietSince = nil
        }

        guard let context = currentContext else {
            // The recognizer ended the previous segment on its own; pick up again.
            if time >= nextSegmentAllowedAt {
                beginSegment(at: time)
            }
            return
        }

        let segmentLength = time - context.start
        let quietFor: TimeInterval
        if let since = quietSince {
            quietFor = time - since
        } else {
            quietFor = 0
        }

        if segmentLength >= Tuning.hardRotation
            || (segmentLength >= Tuning.softRotation && quietFor > Tuning.quietDuration) {
            rotate(at: time)
        }
    }

    /// Ends the current segment right now (used on pause). Safe to call repeatedly.
    func rotate(at time: TimeInterval) {
        guard hasStarted, !isFinished else { return }
        lastTickTime = max(lastTickTime, time)
        endCurrentSegment(at: time)
        beginSegment(at: time)
    }

    /// Ends audio for the last segment and waits (max 4 s) for its final result.
    func finish(at time: TimeInterval) async {
        // This method is not main-actor isolated, so every touch of the main-thread state
        // below is hopped onto the main actor explicitly.
        let needsWait = await MainActor.run { () -> Bool in
            self.beginFinishing(at: time)
        }
        guard needsWait else { return }

        let deadline = Date().addingTimeInterval(Tuning.finishTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Tuning.pollNanoseconds)
            let stillWaiting = await MainActor.run { () -> Bool in
                self.hasUncommittedSegments
            }
            if !stillWaiting {
                return
            }
            if Task.isCancelled {
                break
            }
        }

        await MainActor.run {
            self.forceCommitStragglers(at: time)
        }
    }

    // MARK: Static helpers

    /// Locales with an SFSpeechRecognizer, sorted by localized name.
    static var supportedLocales: [Locale] {
        let current = Locale.current
        func name(_ locale: Locale) -> String {
            current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
        return SFSpeechRecognizer.supportedLocales().sorted { lhs, rhs in
            name(lhs).localizedCaseInsensitiveCompare(name(rhs)) == .orderedAscending
        }
    }

    static func supportsOnDevice(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    static func isAvailable(_ locale: Locale) -> Bool {
        SFSpeechRecognizer(locale: locale)?.isAvailable ?? false
    }

    fileprivate static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    // MARK: Segment lifecycle (main thread)

    private func beginSegment(at time: TimeInterval) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDeviceOnly
        request.taskHint = .dictation
        request.addsPunctuation = true

        let context = SegmentContext(start: time)
        pendingContexts.append(context)
        currentContext = context

        lock.lock()
        currentRequest = request
        appendedFrames = 0
        lock.unlock()

        context.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            self.handleResult(result, error: error, for: context)
        }
    }

    /// Detaches the current segment from the audio stream and asks the recognizer for its final result.
    private func endCurrentSegment(at time: TimeInterval) {
        guard let context = currentContext else { return }
        currentContext = nil

        lock.lock()
        let request = currentRequest
        let frames = appendedFrames
        currentRequest = nil
        appendedFrames = 0
        lock.unlock()

        context.end = max(time, context.start)

        if frames == 0 {
            // Nothing was ever appended (for example a rotation while paused): no result can
            // come from this request, so don't wait for one.
            let task = context.task
            commit(context, error: nil)
            task?.cancel()
        } else {
            request?.endAudio()
        }
    }

    /// Runs on the main thread (`recognizer.queue` is the main queue).
    private func handleResult(_ result: SFSpeechRecognitionResult?, error: Error?, for context: SegmentContext) {
        guard !context.committed else { return }

        if let result = result {
            context.latestText = result.bestTranscription.formattedString
            publishPartial()
        }

        let isFinal = result?.isFinal ?? false
        guard isFinal || error != nil else { return }

        if context === currentContext {
            // The recognizer ended this segment by itself (long silence, a server-side limit,
            // or a problem). Detach it so audio stops flowing into it, and let `tick` start
            // the next segment, after a short pause if this was a real failure.
            currentContext = nil
            lock.lock()
            currentRequest = nil
            appendedFrames = 0
            lock.unlock()
            context.end = max(lastTickTime, context.start)

            if let error = error, !LiveTranscriber.isBenign(error) {
                nextSegmentAllowedAt = lastTickTime + Tuning.failureBackoff
            } else {
                nextSegmentAllowedAt = lastTickTime
            }
        }

        commit(context, error: error)
    }

    /// Commits a segment exactly once: emits its best text (if any) and refreshes the partial text.
    private func commit(_ context: SegmentContext, error: Error?) {
        guard !context.committed else { return }
        context.committed = true
        context.task = nil
        pendingContexts.removeAll { $0 === context }

        let text = context.latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            consecutiveFailures = 0
            let end = context.end > context.start ? context.end : max(lastTickTime, context.start)
            onSegment?(TranscriptSegment(start: context.start, end: end, text: text))
        } else if let error = error, !LiveTranscriber.isBenign(error) {
            consecutiveFailures += 1
            if consecutiveFailures >= Tuning.failuresBeforeWarning {
                consecutiveFailures = 0
                onWarning?("Transcription is having trouble right now (\(error.localizedDescription)). Your audio is still being recorded.")
            }
        }

        publishPartial()
    }

    /// Sends the text of every segment that is still waiting for its final result, oldest first,
    /// so the live transcript never loses words between a rotation and the final result.
    private func publishPartial() {
        let text = pendingContexts
            .map { $0.latestText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard text != lastPublishedPartial else { return }
        lastPublishedPartial = text
        onPartial?(text)
    }

    private var hasUncommittedSegments: Bool {
        pendingContexts.contains { !$0.committed }
    }

    private func beginFinishing(at time: TimeInterval) -> Bool {
        guard hasStarted, !isFinished else { return false }
        isFinished = true
        lastTickTime = max(lastTickTime, time)
        endCurrentSegment(at: time)
        return hasUncommittedSegments
    }

    /// After the timeout: keep the best partial text of anything still outstanding and cancel its task.
    private func forceCommitStragglers(at time: TimeInterval) {
        let stragglers = pendingContexts
        for context in stragglers where !context.committed {
            let task = context.task
            if context.end <= context.start {
                context.end = max(time, context.start)
            }
            commit(context, error: nil)
            task?.cancel()
        }
        pendingContexts.removeAll()
    }

    /// "No speech detected" and cancellation are normal ends of a segment, not problems.
    private static func isBenign(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" && (nsError.code == 1110 || nsError.code == 216) {
            return true
        }
        if nsError.domain == "kLSRErrorDomain" && nsError.code == 301 {
            return true
        }
        let message = nsError.localizedDescription.lowercased()
        return message.contains("no speech") || message.contains("cancel")
    }
}
