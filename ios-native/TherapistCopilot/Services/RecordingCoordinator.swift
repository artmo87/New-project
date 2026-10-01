import Foundation
import Observation
import AVFoundation

/// Runs `work` on the main actor. The transcriber and recorder deliver their callbacks on the
/// main thread by contract, so this normally runs synchronously (which keeps segment order
/// intact); if a callback ever arrives elsewhere it hops instead.
private func recordingHopToMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated {
            work()
        }
    } else {
        Task { @MainActor in
            work()
        }
    }
}

/// Latest metering values, written from the audio render thread and read on main.
private final class RecordingLevelMeter {
    private let lock = NSLock()
    private var storedElapsed: TimeInterval = 0
    private var storedLevel: Float = 0

    func update(elapsed: TimeInterval, level: Float) {
        lock.lock()
        storedElapsed = elapsed
        storedLevel = level
        lock.unlock()
    }

    func read() -> (elapsed: TimeInterval, level: Float) {
        lock.lock()
        defer { lock.unlock() }
        return (storedElapsed, storedLevel)
    }

    func reset() {
        update(elapsed: 0, level: 0)
    }
}

/// The state machine the recording UI binds to. Owns an `AudioRecorder` and an optional
/// `LiveTranscriber` and glues them together.
@MainActor
@Observable
final class RecordingCoordinator {
    enum State: Equatable { case idle, preparing, recording, paused, finishing }

    private(set) var state: State = .idle
    /// Updated ~10x/s from a Timer while recording.
    private(set) var elapsed: TimeInterval = 0
    /// 0...1 smoothed microphone level.
    private(set) var level: Float = 0
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

    @ObservationIgnored private var recorder: AudioRecorder?
    @ObservationIgnored private var transcriber: LiveTranscriber?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var audioURL: URL?
    @ObservationIgnored private var locale: Locale = Locale(identifier: "en-US")
    /// Bumped by every `start()` and `cancel()` so an abandoned `start()` stops after its await.
    @ObservationIgnored private var startToken: Int = 0
    /// Why transcription is off for this recording (nil when it is on); restored after interruptions.
    @ObservationIgnored private var transcriptionWarning: String?
    @ObservationIgnored private var pausedByInterruption = false
    private let meter = RecordingLevelMeter()

    init() {}

    // MARK: Derived

    /// Committed texts + partial, for display.
    var liveTranscript: String {
        let committed = committedSegments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let partial = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return partial }
        if partial.isEmpty { return committed }
        return committed + " " + partial
    }

    // MARK: Start

    /// Requests permissions, configures recorder + transcriber, starts. On failure sets
    /// `errorMessage` and returns to .idle. `audioURL` comes from store.newAudioURL(for:).
    func start(draft: TherapySession, audioURL: URL, locale: Locale, onDeviceOnly: Bool) async {
        guard state == .idle else { return }
        startToken += 1
        let token = startToken

        state = .preparing
        errorMessage = nil
        warning = nil
        transcriptionWarning = nil
        pausedByInterruption = false
        self.draft = draft
        self.audioURL = audioURL
        self.locale = locale
        committedSegments = []
        partialText = ""
        elapsed = 0
        level = 0
        transcriptionActive = false
        meter.reset()

        let outcome = await PermissionsManager.requestAll()
        // The user may have cancelled while the permission prompts were up.
        guard token == startToken, state == .preparing else { return }

        var liveTranscriber: LiveTranscriber? = nil
        switch outcome {
        case .microphoneDenied:
            errorMessage = "Microphone access is needed to record. Enable it in Settings > Privacy > Microphone."
            resetToIdle()
            return
        case .granted:
            do {
                liveTranscriber = try LiveTranscriber(locale: locale, onDeviceOnly: onDeviceOnly)
            } catch {
                transcriptionWarning = "Recording audio only. " + error.localizedDescription
            }
        case .speechDenied:
            transcriptionWarning = "Recording audio only — speech recognition is turned off for this app. You can turn it on in Settings > Privacy & Security > Speech Recognition."
        case .speechRestricted:
            transcriptionWarning = "Recording audio only — speech recognition isn't available on this iPhone right now."
        }

        if let liveTranscriber = liveTranscriber {
            liveTranscriber.onPartial = { [weak self] text in
                recordingHopToMain {
                    self?.partialText = text
                }
            }
            liveTranscriber.onSegment = { [weak self] segment in
                recordingHopToMain {
                    self?.appendSegment(segment)
                }
            }
            liveTranscriber.onWarning = { [weak self] message in
                recordingHopToMain {
                    self?.warning = message
                }
            }
        }

        let recorder = AudioRecorder()
        // Captured as locals: this closure runs on the audio render thread and must not touch `self`.
        let meter = self.meter
        let transcriberForAudio = liveTranscriber
        recorder.onBuffer = { buffer, bufferElapsed, bufferLevel in
            meter.update(elapsed: bufferElapsed, level: bufferLevel)
            transcriberForAudio?.append(buffer)
        }
        recorder.onInterruption = { [weak self] began, shouldResume in
            recordingHopToMain {
                self?.handleInterruption(began: began, shouldResume: shouldResume)
            }
        }
        recorder.onEngineRestart = { [weak self] in
            recordingHopToMain {
                self?.handleEngineRestart()
            }
        }

        // The store creates this folder; making sure costs nothing and a failure surfaces below.
        try? FileManager.default.createDirectory(
            at: audioURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Open the first recognition segment before audio starts flowing so no buffer is missed.
        liveTranscriber?.start(at: 0)

        do {
            try recorder.start(to: audioURL)
        } catch {
            if let liveTranscriber = liveTranscriber {
                discard(liveTranscriber, at: 0)
            }
            errorMessage = "Couldn't start recording. " + error.localizedDescription
            resetToIdle()
            return
        }

        self.recorder = recorder
        self.transcriber = liveTranscriber
        transcriptionActive = liveTranscriber != nil
        warning = transcriptionWarning
        state = .recording
        startTimer()
    }

    // MARK: Pause / resume

    func pause() {
        guard state == .recording, let recorder = recorder else { return }
        recorder.pause()
        let now = recorder.elapsed
        elapsed = now
        transcriber?.rotate(at: now)
        level = 0
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder = recorder else { return }
        do {
            try recorder.resume()
            pausedByInterruption = false
            state = .recording
            warning = transcriptionWarning
        } catch {
            warning = "Couldn't resume recording (" + error.localizedDescription + "). Please try again."
        }
    }

    // MARK: Finish / cancel

    /// Stops recording and transcription, waits for the final segment, and returns the
    /// completed draft with `duration`, `segments`, `audioFileName`, `transcriptLanguage` filled in.
    /// Returns nil if nothing was recording.
    func finish() async -> TherapySession? {
        guard state == .recording || state == .paused,
              let recorder = recorder,
              let draftSession = draft else { return nil }

        state = .finishing
        stopTimer()

        let duration = recorder.stop()
        recorder.onBuffer = nil
        recorder.onInterruption = nil
        recorder.onEngineRestart = nil
        elapsed = duration
        level = 0

        if let transcriber = transcriber {
            await transcriber.finish(at: duration)
            transcriber.onPartial = nil
            transcriber.onSegment = nil
            transcriber.onWarning = nil
        }

        var session = draftSession
        session.duration = duration
        session.segments = committedSegments.sorted { $0.start < $1.start }
        session.transcriptLanguage = locale.identifier(.bcp47)
        if let url = audioURL, FileManager.default.fileExists(atPath: url.path) {
            session.audioFileName = url.lastPathComponent
        } else {
            session.audioFileName = nil
        }

        resetToIdle()
        return session
    }

    /// Stops and deletes the audio file; discards everything.
    func cancel() {
        guard state != .idle, state != .finishing else { return }
        startToken += 1
        stopTimer()

        let url = audioURL
        let stopTime = recorder?.elapsed ?? elapsed

        if let recorder = recorder {
            recorder.stop()
            recorder.onBuffer = nil
            recorder.onInterruption = nil
            recorder.onEngineRestart = nil
        }
        if let transcriber = transcriber {
            discard(transcriber, at: stopTime)
        }
        if let url = url, FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        resetToIdle()
        errorMessage = nil
    }

    // MARK: Timer

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickFromTimer()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickFromTimer() {
        guard let recorder = recorder else { return }
        switch state {
        case .recording:
            let reading = meter.read()
            let rawLevel = min(max(reading.level, 0), 1)
            level = level * 0.6 + rawLevel * 0.4
            elapsed = recorder.elapsed
            transcriber?.tick(time: elapsed, level: level)
        case .paused:
            level = level * 0.6
            elapsed = recorder.elapsed
        case .idle, .preparing, .finishing:
            break
        }
    }

    // MARK: Callbacks

    private func appendSegment(_ segment: TranscriptSegment) {
        guard state != .idle else { return }
        committedSegments.append(segment)
        committedSegments.sort { $0.start < $1.start }
    }

    private func handleInterruption(began: Bool, shouldResume: Bool) {
        if began {
            guard state == .recording else { return }
            pause()
            pausedByInterruption = true
            warning = "Recording paused — a call or another app took over the microphone. Tap Resume when you're ready to continue."
        } else {
            guard state == .paused, pausedByInterruption else { return }
            if shouldResume {
                resume()
            } else {
                pausedByInterruption = false
                warning = "The interruption is over. Tap Resume to keep recording."
            }
        }
    }

    private func handleEngineRestart() {
        guard state == .recording, let recorder = recorder else { return }
        // The input format may have changed with the route, so give the recognizer a fresh request.
        transcriber?.rotate(at: recorder.elapsed)
        warning = "Your audio input changed (for example, headphones were connected or removed). Recording continues."
    }

    // MARK: Cleanup

    /// Silences a transcriber we no longer want results from and lets it wind down its tasks.
    private func discard(_ transcriber: LiveTranscriber, at time: TimeInterval) {
        transcriber.onPartial = nil
        transcriber.onSegment = nil
        transcriber.onWarning = nil
        Task {
            await transcriber.finish(at: time)
        }
    }

    private func resetToIdle() {
        stopTimer()
        recorder = nil
        transcriber = nil
        state = .idle
        elapsed = 0
        level = 0
        committedSegments = []
        partialText = ""
        transcriptionActive = false
        warning = nil
        draft = nil
        audioURL = nil
        transcriptionWarning = nil
        pausedByInterruption = false
        meter.reset()
    }
}
