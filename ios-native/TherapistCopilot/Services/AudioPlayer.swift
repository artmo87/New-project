import AVFoundation
import Foundation
import Observation

/// Plays back a session recording. Owned by `SessionDetailView` (not in the environment).
@MainActor
@Observable
final class AudioPlayer {
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded: Bool = false

    /// Playback speed: 1.0, 1.25, 1.5 or 2.0. Applies live, even while playing.
    var rate: Float {
        get { playbackRate }
        set {
            let clamped = min(2.0, max(0.5, newValue))
            playbackRate = clamped
            player?.rate = clamped
        }
    }

    private var playbackRate: Float = 1.0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    init() {}

    // MARK: - Loading

    /// Creates an `AVAudioPlayer` for `url` with variable rate enabled and prepares it.
    /// Also switches the audio session to `.playback`. Throws if the file can't be opened.
    func load(url: URL) throws {
        tearDownPlayback()
        player = nil
        isLoaded = false
        duration = 0

        let session = AVAudioSession.sharedInstance()
        // Best effort: playback still works with the previous session configuration.
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.enableRate = true
        _ = newPlayer.prepareToPlay()
        newPlayer.rate = playbackRate
        player = newPlayer
        duration = newPlayer.duration
        currentTime = 0
        isLoaded = true
    }

    // MARK: - Transport

    func play() {
        guard let player = player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        player.rate = playbackRate
        if player.play() {
            isPlaying = true
            startTimer()
        } else {
            isPlaying = false
            stopTimer()
        }
    }

    func pause() {
        guard let player = player else { return }
        player.pause()
        isPlaying = false
        stopTimer()
        currentTime = player.currentTime
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Jumps to `time` (clamped to 0...duration). Works while playing or paused.
    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Moves forward (positive) or back (negative) by `seconds`.
    func skip(by seconds: TimeInterval) {
        let now: TimeInterval
        if let player = player, player.isPlaying {
            now = player.currentTime
        } else {
            now = currentTime
        }
        seek(to: now + seconds)
    }

    /// Stops playback, invalidates the timer and deactivates the audio session. The file stays loaded.
    func stop() {
        tearDownPlayback()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Private

    private func tearDownPlayback() {
        stopTimer()
        if let player = player {
            player.stop()
            player.currentTime = 0
        }
        isPlaying = false
        currentTime = 0
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] timer in
            guard self != nil else {
                timer.invalidate()
                return
            }
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player = player else {
            stopTimer()
            isPlaying = false
            return
        }

        if player.isPlaying {
            currentTime = player.currentTime
            return
        }

        guard isPlaying else { return }

        // The player stopped on its own: it reached the end (AVAudioPlayer rewinds to 0)
        // or the system paused it (a call, another app taking over audio).
        isPlaying = false
        stopTimer()
        let finished = player.currentTime <= 0.01 || currentTime >= duration - 0.1
        if finished {
            player.currentTime = 0
            currentTime = 0
        } else {
            currentTime = player.currentTime
        }
    }
}
