import AVFoundation
import Foundation
import Speech

/// The combined result of asking for everything a recording needs.
enum PermissionOutcome: Equatable {
    /// Microphone and speech recognition are both available.
    case granted
    /// Without the microphone nothing can be recorded.
    case microphoneDenied
    /// The user declined speech recognition; recording can continue audio-only.
    case speechDenied
    /// Speech recognition is restricted on this device or not available right now.
    case speechRestricted
}

/// Asks for, and reports on, the microphone and speech-recognition permissions.
/// Nothing here talks to a server: speech recognition itself is configured on-device by `LiveTranscriber`.
enum PermissionsManager {

    /// Prompts for microphone access the first time; afterwards it simply reports the stored answer.
    static func requestMicrophone() async -> Bool {
        if microphoneGranted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Prompts for speech recognition access the first time; afterwards it reports the stored answer.
    static func requestSpeech() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Requests both. Microphone denial is fatal for recording; speech denial is not.
    static func requestAll() async -> PermissionOutcome {
        let microphone = await requestMicrophone()
        guard microphone else { return .microphoneDenied }

        let speech = await requestSpeech()
        switch speech {
        case .authorized:
            return .granted
        case .denied:
            return .speechDenied
        case .restricted:
            return .speechRestricted
        case .notDetermined:
            // The system did not give an answer (for example the prompt was dismissed);
            // the recording can still go ahead without live transcription.
            return .speechDenied
        @unknown default:
            return .speechRestricted
        }
    }

    /// Current microphone status, without showing a prompt.
    static var microphoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Current speech recognition status, without showing a prompt.
    static var speechGranted: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }
}
