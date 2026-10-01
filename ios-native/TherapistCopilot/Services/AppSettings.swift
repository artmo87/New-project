import Foundation
import Observation
import Speech

/// Keys under which the settings live in `UserDefaults.standard`.
private enum SettingsKey {
    static let recognitionLocaleIdentifier = "settings.recognitionLocaleIdentifier"
    static let onDeviceRecognitionOnly = "settings.onDeviceRecognitionOnly"
    static let appLockEnabled = "settings.appLockEnabled"
    static let insightEnginePreference = "settings.insightEnginePreference"
    static let hasAcceptedConsent = "settings.hasAcceptedConsent"
    static let defaultTherapistName = "settings.defaultTherapistName"
    static let keepAudioAfterTranscription = "settings.keepAudioAfterTranscription"
    static let hasSeenOnboarding = "settings.hasSeenOnboarding"
}

/// User preferences. Every property is written to `UserDefaults.standard` the moment it
/// changes, so there is nothing to flush and nothing is lost if the app is closed abruptly.
@Observable
final class AppSettings {

    /// BCP-47 identifier of the speech recognition locale, e.g. "en-US".
    var recognitionLocaleIdentifier: String {
        didSet {
            UserDefaults.standard.set(recognitionLocaleIdentifier, forKey: SettingsKey.recognitionLocaleIdentifier)
        }
    }

    /// When true, recognition requests set `requiresOnDeviceRecognition` and audio never
    /// leaves the iPhone. Default true.
    var onDeviceRecognitionOnly: Bool {
        didSet {
            UserDefaults.standard.set(onDeviceRecognitionOnly, forKey: SettingsKey.onDeviceRecognitionOnly)
        }
    }

    /// Lock the app with Face ID / Touch ID / passcode when it goes to the background. Default false.
    var appLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(appLockEnabled, forKey: SettingsKey.appLockEnabled)
        }
    }

    /// Which insight engine to use. Default `.automatic`.
    var insightEnginePreference: InsightEnginePreference {
        didSet {
            UserDefaults.standard.set(insightEnginePreference.rawValue, forKey: SettingsKey.insightEnginePreference)
        }
    }

    /// Set to true once the consent reminder has been acknowledged. Default false.
    var hasAcceptedConsent: Bool {
        didSet {
            UserDefaults.standard.set(hasAcceptedConsent, forKey: SettingsKey.hasAcceptedConsent)
        }
    }

    /// Prefilled therapist name for new sessions. Default "".
    var defaultTherapistName: String {
        didSet {
            UserDefaults.standard.set(defaultTherapistName, forKey: SettingsKey.defaultTherapistName)
        }
    }

    /// Keep the audio recording after a session has been transcribed. Default true.
    var keepAudioAfterTranscription: Bool {
        didSet {
            UserDefaults.standard.set(keepAudioAfterTranscription, forKey: SettingsKey.keepAudioAfterTranscription)
        }
    }

    /// True once the onboarding pages have been completed. Default false.
    var hasSeenOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasSeenOnboarding, forKey: SettingsKey.hasSeenOnboarding)
        }
    }

    /// Loads every setting from `UserDefaults.standard`, applying defaults for missing values.
    init() {
        let defaults = UserDefaults.standard

        let storedLocale = defaults.string(forKey: SettingsKey.recognitionLocaleIdentifier)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if storedLocale.isEmpty {
            recognitionLocaleIdentifier = AppSettings.defaultRecognitionLocaleIdentifier()
        } else {
            recognitionLocaleIdentifier = storedLocale
        }

        onDeviceRecognitionOnly = AppSettings.bool(forKey: SettingsKey.onDeviceRecognitionOnly, fallback: true, in: defaults)
        appLockEnabled = AppSettings.bool(forKey: SettingsKey.appLockEnabled, fallback: false, in: defaults)

        let rawPreference = defaults.string(forKey: SettingsKey.insightEnginePreference) ?? ""
        insightEnginePreference = InsightEnginePreference(rawValue: rawPreference) ?? .automatic

        hasAcceptedConsent = AppSettings.bool(forKey: SettingsKey.hasAcceptedConsent, fallback: false, in: defaults)
        defaultTherapistName = defaults.string(forKey: SettingsKey.defaultTherapistName) ?? ""
        keepAudioAfterTranscription = AppSettings.bool(forKey: SettingsKey.keepAudioAfterTranscription, fallback: true, in: defaults)
        hasSeenOnboarding = AppSettings.bool(forKey: SettingsKey.hasSeenOnboarding, fallback: false, in: defaults)
    }

    /// The recognition locale as a `Locale`.
    var recognitionLocale: Locale {
        Locale(identifier: recognitionLocaleIdentifier)
    }

    // MARK: - Defaults

    /// Reads a Bool, returning `fallback` when the key has never been written.
    private static func bool(forKey key: String, fallback: Bool, in defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: key) == nil {
            return fallback
        }
        return defaults.bool(forKey: key)
    }

    /// The device locale when speech recognition supports it exactly; otherwise another locale
    /// of the same language; otherwise "en-US".
    private static func defaultRecognitionLocaleIdentifier() -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        let current = Locale.current
        let currentIdentifier = current.identifier(.bcp47)

        if supported.contains(where: { $0.identifier(.bcp47) == currentIdentifier }) {
            return currentIdentifier
        }

        if let languageCode = current.language.languageCode?.identifier, !languageCode.isEmpty {
            let sameLanguage = supported
                .filter { $0.language.languageCode?.identifier == languageCode }
                .map { $0.identifier(.bcp47) }
                .sorted()
            if !sameLanguage.isEmpty {
                let preferred = languageCode == "en" ? "en-US" : "\(languageCode)-\(languageCode.uppercased())"
                if sameLanguage.contains(preferred) {
                    return preferred
                }
                return sameLanguage[0]
            }
        }

        return "en-US"
    }
}
