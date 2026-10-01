import SwiftUI
import Foundation
import Observation

/// Compact playback controls for a session recording: skip back / play-pause / skip
/// forward, a scrubber with time labels and a playback-speed menu. The bar loads the
/// audio file when it appears and stops playback when it leaves the screen.
struct AudioPlayerBar: View {
    private static let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
    private static let skipInterval: TimeInterval = 15

    @Environment(SessionStore.self) private var store

    private let player: AudioPlayer
    private let session: TherapySession

    @State private var loadFailed = false
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    init(player: AudioPlayer, session: TherapySession) {
        self.player = player
        self.session = session
    }

    var body: some View {
        CardView {
            if loadFailed {
                failedContent
            } else {
                controls
            }
        }
        .padding(.horizontal)
        .onAppear {
            loadIfNeeded()
        }
        .onDisappear {
            player.stop()
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 32) {
                Spacer(minLength: 0)

                Button {
                    player.skip(by: -AudioPlayerBar.skipInterval)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Back 15 seconds")

                Button {
                    player.toggle()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Color.white)
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Button {
                    player.skip(by: AudioPlayerBar.skipInterval)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Forward 15 seconds")

                Spacer(minLength: 0)
            }
            .disabled(!player.isLoaded)

            Slider(
                value: sliderBinding,
                in: 0...sliderUpperBound,
                onEditingChanged: { editing in
                    scrubbingChanged(editing)
                }
            )
            .disabled(!player.isLoaded)
            .accessibilityLabel("Playback position")
            .accessibilityValue(Formatters.clock(displayedTime))

            HStack {
                Text(Formatters.clock(displayedTime))
                    .accessibilityLabel("Elapsed \(Formatters.clock(displayedTime))")
                Spacer(minLength: 0)
                rateMenu
                Spacer(minLength: 0)
                Text(Formatters.clock(player.duration))
                    .accessibilityLabel("Length \(Formatters.clock(player.duration))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private var rateMenu: some View {
        Menu {
            Picker("Playback speed", selection: rateBinding) {
                ForEach(AudioPlayerBar.rates, id: \.self) { rate in
                    Text(AudioPlayerBar.rateLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(AudioPlayerBar.rateLabel(player.rate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        .accessibilityLabel("Playback speed, \(AudioPlayerBar.rateLabel(player.rate))")
    }

    private var failedContent: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("This recording couldn't be opened")
                    .font(.subheadline.weight(.semibold))
                Text("The audio file may be missing or damaged. Your transcript, summary and notes are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") {
                    loadFailed = false
                    loadIfNeeded()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Bindings and derived values

    private var sliderBinding: Binding<TimeInterval> {
        Binding(
            get: { isScrubbing ? scrubTime : player.currentTime },
            set: { newValue in
                scrubTime = newValue
                if !isScrubbing {
                    player.seek(to: newValue)
                }
            }
        )
    }

    private var rateBinding: Binding<Float> {
        Binding(
            get: { player.rate },
            set: { newValue in
                player.rate = newValue
            }
        )
    }

    private var sliderUpperBound: TimeInterval {
        let duration = player.duration
        guard duration.isFinite else { return 1 }
        return max(duration, 1)
    }

    private var displayedTime: TimeInterval {
        isScrubbing ? scrubTime : player.currentTime
    }

    // MARK: - Actions

    private func loadIfNeeded() {
        if player.isLoaded {
            loadFailed = false
            return
        }
        guard let url = store.audioURL(for: session) else {
            loadFailed = true
            return
        }
        do {
            try player.load(url: url)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func scrubbingChanged(_ editing: Bool) {
        if editing {
            scrubTime = player.currentTime
            isScrubbing = true
        } else {
            isScrubbing = false
            player.seek(to: scrubTime)
        }
    }

    private static func rateLabel(_ rate: Float) -> String {
        Double(rate).formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}
