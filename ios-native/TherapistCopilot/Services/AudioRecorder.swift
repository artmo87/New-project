import AVFoundation
import Foundation

/// Captures microphone audio with `AVAudioEngine`, writes an AAC `.m4a` file through `AVAudioFile`
/// and hands every captured buffer to `onBuffer` so live transcription can run alongside the recording.
///
/// Threading: call `start`, `pause`, `resume` and `stop` from the main thread. The engine tap runs on an
/// audio thread and only touches lock-protected boxes; it never reads `self`. `onInterruption` and
/// `onEngineRestart` are delivered on the main thread; `onBuffer` is delivered on the audio thread.
final class AudioRecorder {

    enum RecorderError: LocalizedError {
        case engineUnavailable
        case fileCreationFailed(String)
        case alreadyRecording

        var errorDescription: String? {
            switch self {
            case .engineUnavailable:
                return "The microphone couldn't be started. Make sure no other app is using it, then try again."
            case .fileCreationFailed(let detail):
                return "The recording file couldn't be created. \(detail)"
            case .alreadyRecording:
                return "A recording is already in progress."
            }
        }
    }

    // MARK: - Callbacks

    /// Called on the audio render thread for every captured buffer.
    /// - elapsed: seconds of *recorded* audio so far (paused time excluded)
    /// - level: 0...1 RMS-based input level for metering
    var onBuffer: ((AVAudioPCMBuffer, TimeInterval, Float) -> Void)? {
        get { bufferHandler.get() }
        set { bufferHandler.set(newValue) }
    }

    /// Called on the main thread when the session is interrupted (began = true) or the
    /// interruption ended (began = false, shouldResume tells whether resuming is advised).
    var onInterruption: ((_ began: Bool, _ shouldResume: Bool) -> Void)?

    /// Called on the main thread after the engine stopped unexpectedly (e.g. route change) and the
    /// recorder restarted it by itself. Informational.
    var onEngineRestart: (() -> Void)?

    // MARK: - State

    /// True while audio is being captured (not paused).
    private(set) var isRecording: Bool = false
    private(set) var isPaused: Bool = false

    /// Seconds of recorded audio, updated from the render thread (read on main for display).
    private(set) var elapsed: TimeInterval {
        get { meter.get().elapsed }
        set { meter.update { $0.elapsed = newValue } }
    }

    // CONTRACT NOTE: `level` is not in the contract's member list for AudioRecorder, but the RecordingCoordinator
    // section says the coordinator copies `recorder.elapsed/level`; it is exposed read-only here so that compiles.
    /// Latest 0...1 input level, updated from the render thread (read on main for display).
    private(set) var level: Float {
        get { meter.get().level }
        set { meter.update { $0.level = newValue } }
    }

    private(set) var fileURL: URL?

    // MARK: - Private storage

    private struct MeterState {
        var elapsed: TimeInterval = 0
        var level: Float = 0
    }

    private var engine = AVAudioEngine()
    private let meter = RecorderLockedValue(MeterState())
    private let bufferHandler = RecorderLockedValue<((AVAudioPCMBuffer, TimeInterval, Float) -> Void)?>(nil)
    /// The open file. The lock is held while writing, so `stop()` waits for an in-flight write before closing it.
    private let fileSlot = RecorderLockedValue<AVAudioFile?>(nil)

    /// True between a successful `start` and `stop`.
    private var isActive = false
    /// True when the recorder paused itself (interruption or lost microphone), not the user.
    private var autoPaused = false
    /// True between an interruption's "began" and "ended" notifications.
    private var interrupted = false
    /// The PCM format the file is written in (the input format at start time).
    private var fileFormat: AVAudioFormat?
    /// The format the current tap was installed with.
    private var tapFormat: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []

    init() {}

    deinit {
        removeObservers()
        if isActive {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Lifecycle

    /// Configures AVAudioSession (.playAndRecord, mode .default, options [.defaultToSpeaker, .allowBluetooth]),
    /// activates it, creates the file at `url`, installs the tap and starts the engine.
    func start(to url: URL) throws {
        if isActive { throw RecorderError.alreadyRecording }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            throw RecorderError.engineUnavailable
        }

        let newEngine = AVAudioEngine()
        engine = newEngine
        let inputNode = newEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateSession()
            throw RecorderError.engineUnavailable
        }

        let file: AVAudioFile
        do {
            file = try AudioRecorder.makeFile(at: url, format: format)
        } catch {
            deactivateSession()
            throw RecorderError.fileCreationFailed(error.localizedDescription)
        }

        meter.set(MeterState())
        fileSlot.set(file)
        fileFormat = file.processingFormat
        fileURL = url
        installTap(format: format, fileFormat: file.processingFormat)
        addObservers()
        newEngine.prepare()
        do {
            try newEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            removeObservers()
            tapFormat = nil
            fileSlot.set(nil)
            fileFormat = nil
            fileURL = nil
            try? FileManager.default.removeItem(at: url)
            deactivateSession()
            throw RecorderError.engineUnavailable
        }

        isActive = true
        isRecording = true
        isPaused = false
        autoPaused = false
        interrupted = false
    }

    /// Pauses capture. Paused time is not counted in `elapsed`.
    func pause() {
        guard isActive, !isPaused else { return }
        engine.pause()
        isPaused = true
        isRecording = false
        autoPaused = false
    }

    /// Resumes capture after `pause()` or after an interruption.
    func resume() throws {
        guard isActive, isPaused else { return }
        guard let fileFormat = fileFormat else { throw RecorderError.engineUnavailable }

        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)

        let format = engine.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.engineUnavailable
        }

        // The input hardware may have changed while we were paused (headphones, Bluetooth, a call).
        let needsNewTap: Bool
        if let tapFormat = tapFormat {
            needsNewTap = !AudioRecorder.formatsMatch(format, tapFormat)
        } else {
            needsNewTap = true
        }
        if needsNewTap {
            installTap(format: format, fileFormat: fileFormat)
            engine.prepare()
        }

        do {
            try engine.start()
        } catch {
            throw RecorderError.engineUnavailable
        }

        isPaused = false
        isRecording = true
        autoPaused = false
        interrupted = false
    }

    /// Stops the engine, removes the tap, closes the file, deactivates the session.
    /// Returns the final duration in seconds.
    @discardableResult
    func stop() -> TimeInterval {
        guard isActive else { return meter.get().elapsed }

        isActive = false
        isRecording = false
        isPaused = false
        autoPaused = false
        interrupted = false
        removeObservers()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tapFormat = nil

        // Releasing the last reference finalizes the .m4a (writes the header, flushes the encoder).
        fileSlot.set(nil)
        fileFormat = nil

        deactivateSession()
        return meter.get().elapsed
    }

    // MARK: - Tap

    private func installTap(format: AVAudioFormat, fileFormat: AVAudioFormat) {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        tapFormat = format

        // If the microphone format differs from the file's format (e.g. a Bluetooth headset joined
        // mid-session), convert so the file and the transcriber keep seeing one consistent format.
        let converter: AVAudioConverter?
        if AudioRecorder.formatsMatch(format, fileFormat) {
            converter = nil
        } else {
            converter = AVAudioConverter(from: format, to: fileFormat)
        }

        let meter = self.meter
        let bufferHandler = self.bufferHandler
        let fileSlot = self.fileSlot
        let inputSampleRate = format.sampleRate

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            let level = AudioRecorder.inputLevel(of: buffer)
            let seconds = Double(buffer.frameLength) / inputSampleRate
            let elapsedNow = meter.update { (state: inout MeterState) -> TimeInterval in
                state.elapsed += seconds
                state.level = level
                return state.elapsed
            }

            let outgoing: AVAudioPCMBuffer
            if let converter = converter {
                guard let converted = AudioRecorder.convert(buffer, using: converter, to: fileFormat) else { return }
                outgoing = converted
            } else {
                outgoing = buffer
            }

            fileSlot.update { (file: inout AVAudioFile?) -> Void in
                if let file = file {
                    _ = try? file.write(from: outgoing)
                }
            }

            bufferHandler.get()?(outgoing, elapsedNow, level)
        }
    }

    // MARK: - Session notifications

    private func addObservers() {
        removeObservers()
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.ensureEngineRunning()
        })
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.ensureEngineRunning()
        })
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }

    private func handleInterruption(_ note: Notification) {
        guard isActive,
              let info = note.userInfo,
              let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            // The system has already stopped the engine. Remember that we did not choose to pause.
            interrupted = true
            if !isPaused {
                isPaused = true
                isRecording = false
                autoPaused = true
            }
            onInterruption?(true, false)

        case .ended:
            interrupted = false
            let rawOptions = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            // Only advise resuming when the pause was ours, not the user's.
            let shouldResume = options.contains(.shouldResume) && autoPaused
            onInterruption?(false, shouldResume)

        @unknown default:
            break
        }
    }

    /// Called after a route change or an engine configuration change: restarts the engine if it
    /// stopped while we were recording, or offers to resume if the microphone came back.
    private func ensureEngineRunning() {
        guard isActive else { return }
        if isPaused {
            if autoPaused, !interrupted, inputFormatIsUsable() {
                onInterruption?(false, true)
            }
            return
        }
        if engine.isRunning { return }
        restartEngine(attempt: 0)
    }

    private func restartEngine(attempt: Int) {
        guard isActive, !isPaused, !engine.isRunning, let fileFormat = fileFormat else { return }

        try? AVAudioSession.sharedInstance().setActive(true)
        let format = engine.inputNode.outputFormat(forBus: 0)
        if format.sampleRate > 0, format.channelCount > 0 {
            installTap(format: format, fileFormat: fileFormat)
            engine.prepare()
            do {
                try engine.start()
                onEngineRestart?()
                return
            } catch {
                // Fall through to retry.
            }
        }

        if attempt < 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.restartEngine(attempt: attempt + 1)
            }
            return
        }

        // The microphone is gone for now. Behave like an interruption so the owner can pause and explain.
        isPaused = true
        isRecording = false
        autoPaused = true
        onInterruption?(true, false)
    }

    private func inputFormatIsUsable() -> Bool {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Helpers

    private static func makeFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
        // Create the file with a protection class that stays writable while the iPhone is locked.
        _ = fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000
        ]

        do {
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        } catch {
            // Some input configurations reject an explicit bit rate; let the encoder pick one.
            settings.removeValue(forKey: AVEncoderBitRateKey)
            return try AVAudioFile(forWriting: url, settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        }
    }

    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// RMS of channel 0 mapped to 0...1 on a dB curve (-50 dB → 0, 0 dB → 1). Non-float formats give 0.
    private static func inputLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }

        let channelStride = max(1, buffer.stride)
        let samples = channelData[0]
        var sum: Float = 0
        var index = 0
        let end = frameLength * channelStride
        while index < end {
            let sample = samples[index]
            sum += sample * sample
            index += channelStride
        }

        let rms = (sum / Float(frameLength)).squareRoot()
        guard rms > 0, rms.isFinite else { return 0 }
        let decibels = 20 * log10(rms)
        let clamped = min(0, max(-50, decibels))
        return (clamped + 50) / 50
    }

    /// Converts one tap buffer to `format` (sample rate and/or channel count change). nil if nothing came out.
    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let estimated = Double(buffer.frameLength) * ratio
        let capacity = AVAudioFrameCount(estimated.rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        // The input block hands the buffer over exactly once, then reports "no more data for now"
        // so the converter returns what it has without flushing (the stream continues next tap).
        let delivered = RecorderLockedValue(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered.get() {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered.set(true)
            inputStatus.pointee = .haveData
            return buffer
        }

        switch status {
        case .haveData, .inputRanDry:
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// A tiny NSLock-protected box for values shared between the audio thread and the main thread.
private final class RecorderLockedValue<Value> {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
