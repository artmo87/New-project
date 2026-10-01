import SwiftUI
import Foundation
import AVFoundation
import UIKit

/// The short check-in shown before a recording starts: an optional title and therapist name,
/// a mood check-in, the language the live transcript will use, and a consent reminder.
/// "Start recording" builds a draft `TherapySession`, hands it to `onStart` and dismisses.
struct PreSessionSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private let onStart: (TherapySession) -> Void

    @State private var title: String = ""
    @State private var therapistName: String = ""
    @State private var moodBefore: Int? = nil
    @State private var rememberTherapist: Bool = false
    @State private var didPrepare: Bool = false
    @State private var onDeviceSupported: Bool = false
    @State private var microphoneDenied: Bool = false

    init(onStart: @escaping (TherapySession) -> Void) {
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                moodSection
                transcriptionSection
                consentSection
                startSection
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear { prepare() }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section {
            TextField("Session title (optional)", text: $title)
                .textInputAutocapitalization(.sentences)
            TextField("Therapist's name (optional)", text: $therapistName)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
            if showsRememberToggle {
                Toggle("Remember this name for next time", isOn: $rememberTherapist)
            }
        } header: {
            Text("About this session")
        } footer: {
            Text("Leave the title empty and the session will be named by its date.")
        }
    }

    private var moodSection: some View {
        Section {
            MoodSlider(title: "How do you feel right now?", mood: $moodBefore)
                .padding(.vertical, 4)
        } footer: {
            Text("Optional. Checking in before and after helps you see what a session changes for you.")
        }
    }

    private var transcriptionSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Label("Language", systemImage: "globe")
                Spacer(minLength: 12)
                Text(languageName)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            HStack(alignment: .firstTextBaseline) {
                Label("Transcription", systemImage: transcriptionModeSymbol)
                Spacer(minLength: 12)
                Text(transcriptionModeName)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            if microphoneDenied {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Microphone access is off for this app, so recording can't start yet.")
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                            Link("Turn it on in Settings", destination: settingsURL)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("Transcript")
        } footer: {
            Text(transcriptionFootnote)
        }
    }

    private var consentSection: some View {
        Section {
            Label {
                Text("Tell your therapist you're recording")
            } icon: {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(Color.accentColor)
            }
        } footer: {
            Text("Recording a conversation usually needs everyone's agreement, and the rules differ from place to place. Please ask your therapist first. Everything you record stays on this iPhone.")
        }
    }

    private var startSection: some View {
        Section {
            Button { start() } label: {
                HStack {
                    Spacer()
                    Label("Start recording", systemImage: "record.circle")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityHint("Starts recording the session")
        } footer: {
            Text("Recording keeps going if you lock your phone. You can pause or stop at any time.")
        }
    }

    // MARK: - Derived text

    private var languageName: String {
        Locale.current.localizedString(forIdentifier: settings.recognitionLocaleIdentifier)
            ?? settings.recognitionLocaleIdentifier
    }

    private var transcriptionModeName: String {
        if onDeviceSupported {
            return "On this iPhone"
        }
        if settings.onDeviceRecognitionOnly {
            return "Audio only"
        }
        return "Apple speech servers"
    }

    private var transcriptionModeSymbol: String {
        if onDeviceSupported {
            return "lock.shield"
        }
        if settings.onDeviceRecognitionOnly {
            return "waveform"
        }
        return "cloud"
    }

    private var transcriptionFootnote: String {
        if onDeviceSupported {
            return "On-device transcription available. Your words are transcribed on this iPhone and never leave it."
        }
        if settings.onDeviceRecognitionOnly {
            return "On-device transcription is not available for this language — the session will be recorded as audio only unless you allow Apple server recognition in Settings."
        }
        return "On-device transcription is not available for this language. Because you allowed it in Settings, the audio is sent to Apple's speech servers to be transcribed."
    }

    private var showsRememberToggle: Bool {
        let typed = therapistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = settings.defaultTherapistName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !typed.isEmpty && typed != current
    }

    // MARK: - Actions

    /// Prefills the therapist name and caches the capability checks once per presentation.
    private func prepare() {
        guard !didPrepare else { return }
        didPrepare = true
        if therapistName.isEmpty {
            therapistName = settings.defaultTherapistName
        }
        onDeviceSupported = LiveTranscriber.supportsOnDevice(settings.recognitionLocale)
        microphoneDenied = AVAudioApplication.shared.recordPermission == .denied
    }

    private func start() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTherapist = therapistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if rememberTherapist && !trimmedTherapist.isEmpty {
            settings.defaultTherapistName = trimmedTherapist
        }
        let draft = TherapySession(
            title: trimmedTitle,
            therapistName: trimmedTherapist,
            moodBefore: moodBefore,
            transcriptLanguage: settings.recognitionLocaleIdentifier
        )
        onStart(draft)
        dismiss()
    }
}
