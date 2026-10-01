import SwiftUI
import Foundation
import UIKit

/// Full-screen recording surface: elapsed time, level meter, live transcript and the
/// pause / stop / cancel controls. Binds to the shared `RecordingCoordinator`.
struct RecordingView: View {
    @Environment(RecordingCoordinator.self) private var recorder

    private let onFinished: (TherapySession) -> Void

    @State private var pulse: Bool = false
    @State private var showCancelDialog: Bool = false
    @State private var showFinishDialog: Bool = false

    init(onFinished: @escaping (TherapySession) -> Void) {
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.horizontal, 24)

            LevelMeterView(level: recorder.level)
                .padding(.horizontal, 32)
                .padding(.top, 22)

            if showsWarningBanner || showsAudioOnlyBanner {
                banners
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            transcriptPanel
                .padding(.horizontal, 20)
                .padding(.top, 14)

            controls
                .padding(.horizontal, 28)
                .padding(.top, 18)

            footer
                .padding(.top, 10)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            updatePulse(for: recorder.state)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: recorder.state) { _, newState in
            updatePulse(for: newState)
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $showCancelDialog,
            titleVisibility: .visible
        ) {
            Button("Discard recording", role: .destructive) {
                recorder.cancel()
            }
            Button("Keep recording", role: .cancel) { }
        } message: {
            Text("The audio and transcript from this session will be deleted. This can't be undone.")
        }
        .confirmationDialog(
            "Finish session?",
            isPresented: $showFinishDialog,
            titleVisibility: .visible
        ) {
            Button("Finish and save") {
                finishSession()
            }
            Button("Keep recording", role: .cancel) { }
        } message: {
            Text("Recording stops and the session is saved on this iPhone. A quick check-in comes next.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                statusDot
                Text(stateLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
            .accessibilityElement(children: .combine)

            Text(Formatters.clock(recorder.elapsed))
                .font(.system(size: 56, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .accessibilityLabel("Elapsed time")
                .accessibilityValue(Formatters.clock(recorder.elapsed))

            if let subtitle = sessionSubtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Always present in the hierarchy so the pulse animation survives pause / resume.
    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 14, height: 14)
            .scaleEffect(pulse ? 1.25 : 0.85)
            .opacity(pulse ? 1.0 : 0.6)
            .accessibilityHidden(true)
    }

    private var dotColor: Color {
        switch recorder.state {
        case .recording: return Color.red
        case .paused: return Color.orange
        case .idle, .preparing, .finishing: return Color.secondary
        }
    }

    private var stateColor: Color {
        switch recorder.state {
        case .recording: return Color.red
        case .paused: return Color.orange
        case .idle, .preparing, .finishing: return Color.secondary
        }
    }

    private var stateLabel: String {
        switch recorder.state {
        case .idle: return "Ready"
        case .preparing: return "Getting ready…"
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .finishing: return "Finishing…"
        }
    }

    private var sessionSubtitle: String? {
        guard let draft = recorder.draft else { return nil }
        let therapist = draft.therapistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if therapist.isEmpty {
            return draft.displayTitle
        }
        return draft.displayTitle + " · with " + therapist
    }

    // MARK: - Banners

    private var showsWarningBanner: Bool {
        guard let warning = recorder.warning else { return false }
        return !warning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only once the recorder has actually started, so the brief "preparing" phase doesn't flash it.
    private var showsAudioOnlyBanner: Bool {
        guard !recorder.transcriptionActive else { return false }
        switch recorder.state {
        case .recording, .paused, .finishing: return true
        case .idle, .preparing: return false
        }
    }

    private var banners: some View {
        VStack(spacing: 8) {
            if let warning = recorder.warning, showsWarningBanner {
                RecordingBanner(text: warning, systemImage: "exclamationmark.triangle.fill", tint: .orange)
            }
            if showsAudioOnlyBanner {
                RecordingBanner(
                    text: "Audio only — live transcription is off for this session",
                    systemImage: "waveform",
                    tint: .gray
                )
            }
        }
    }

    // MARK: - Live transcript

    private var committedText: String {
        recorder.committedSegments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var partialText: String {
        recorder.partialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcriptWordCount: Int {
        recorder.liveTranscript
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
    }

    private var wordCountLabel: String {
        let count = transcriptWordCount
        return count == 1 ? "1 word" : String(count) + " words"
    }

    private var transcriptPlaceholder: String {
        if !recorder.transcriptionActive {
            return "Your words aren't being transcribed this time. The audio is still being saved."
        }
        switch recorder.state {
        case .paused: return "Paused. Tap Resume when you're ready to continue."
        case .preparing: return "Getting the microphone ready…"
        case .idle, .recording, .finishing: return "Listening…"
        }
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Live transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if transcriptWordCount > 0 {
                    Text(wordCountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        transcriptText
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 12)
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                }
                .onChange(of: recorder.liveTranscript) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var transcriptText: Text {
        let committed = committedText
        let partial = partialText
        if committed.isEmpty && partial.isEmpty {
            return Text(transcriptPlaceholder).foregroundStyle(.secondary)
        }
        if committed.isEmpty {
            return Text(partial).foregroundStyle(.secondary)
        }
        if partial.isEmpty {
            return Text(committed)
        }
        return Text(committed) + Text(" ") + Text(partial).foregroundStyle(.secondary)
    }

    // MARK: - Controls

    private var isPaused: Bool {
        recorder.state == .paused
    }

    private var canCancel: Bool {
        switch recorder.state {
        case .preparing, .recording, .paused: return true
        case .idle, .finishing: return false
        }
    }

    private var canStopOrPause: Bool {
        switch recorder.state {
        case .recording, .paused: return true
        case .idle, .preparing, .finishing: return false
        }
    }

    private var controls: some View {
        Group {
            if recorder.state == .finishing {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Finishing up and saving your session…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center) {
                    RecordingControlButton(
                        title: "Cancel",
                        systemImage: "xmark",
                        tint: .secondary,
                        action: { showCancelDialog = true }
                    )
                    .disabled(!canCancel)

                    Spacer()

                    RecordButton(isRecording: true) {
                        showFinishDialog = true
                    }
                    .disabled(!canStopOrPause)
                    .accessibilityLabel("Stop and finish session")

                    Spacer()

                    RecordingControlButton(
                        title: isPaused ? "Resume" : "Pause",
                        systemImage: isPaused ? "play.fill" : "pause.fill",
                        tint: .accentColor,
                        action: { togglePause() }
                    )
                    .disabled(!canStopOrPause)
                }
            }
        }
        .frame(height: 104)
    }

    private var footer: some View {
        Label("Recording continues if you lock your phone.", systemImage: "lock.iphone")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: - Actions

    private func updatePulse(for state: RecordingCoordinator.State) {
        if state == .recording {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                pulse = false
            }
        }
    }

    private func togglePause() {
        switch recorder.state {
        case .recording:
            recorder.pause()
        case .paused:
            recorder.resume()
        case .idle, .preparing, .finishing:
            break
        }
    }

    private func finishSession() {
        Task { @MainActor in
            if let session = await recorder.finish() {
                onFinished(session)
            }
        }
    }
}

// MARK: - Private subviews

/// Compact banner for a non-fatal problem or an informational note.
private struct RecordingBanner: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline)
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Round secondary control with a caption underneath (Cancel, Pause / Resume).
private struct RecordingControlButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title2.weight(.semibold))
                    .frame(width: 58, height: 58)
                    .background(tint.opacity(0.15), in: Circle())
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(tint)
            .frame(width: 72)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
