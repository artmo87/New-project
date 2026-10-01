import Foundation
import Observation
import LocalAuthentication

/// Locks the app behind Face ID / Touch ID / the device passcode when it leaves the foreground.
@MainActor
@Observable
final class AppLock {

    /// True while the lock screen should cover the app.
    private(set) var isLocked: Bool = false
    /// True while the system authentication prompt is up.
    private(set) var isAuthenticating: Bool = false
    /// A short, friendly explanation of why the last unlock didn't go through.
    var lastError: String? = nil

    init() {}

    /// "Face ID" / "Touch ID" when biometrics are set up on this iPhone, otherwise "Passcode".
    nonisolated static var biometryName: String {
        let context = LAContext()
        var error: NSError?
        let biometricsReady = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        if biometricsReady {
            switch context.biometryType {
            case .faceID:
                return "Face ID"
            case .touchID:
                return "Touch ID"
            default:
                break
            }
        }
        return "Passcode"
    }

    /// Whether the device can authenticate its owner at all (a passcode is set).
    nonisolated static var canAuthenticate: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Call when the scene goes to the background / inactive and app lock is enabled.
    func lock() {
        isLocked = true
        lastError = nil
    }

    /// Prompts with `.deviceOwnerAuthentication`; on success `isLocked` becomes false.
    /// Safe to call repeatedly: a second call while a prompt is already up does nothing.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &availabilityError) else {
            handleUnavailable(availabilityError)
            return
        }

        let outcome: Result<Bool, Error> = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your sessions and notes.") { success, error in
                if let error = error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(success))
                }
            }
        }

        switch outcome {
        case .success(let succeeded):
            if succeeded {
                isLocked = false
                lastError = nil
            } else {
                isLocked = true
                lastError = "That didn't go through. Tap Unlock to try again."
            }
        case .failure(let error):
            isLocked = true
            lastError = AppLock.friendlyMessage(for: error)
        }
    }

    // MARK: - Private

    /// Handles the case where the device cannot evaluate the policy at all.
    private func handleUnavailable(_ error: NSError?) {
        if let error = error, let laError = error as? LAError, laError.code == .passcodeNotSet {
            // CONTRACT NOTE: with no passcode on the iPhone there is nothing to authenticate
            // against, so keeping the app locked would lock the user out of their own data for
            // good. The lock is lifted and the situation is explained instead.
            isLocked = false
            lastError = "Your iPhone has no passcode, so there's nothing to unlock with. App lock is off until you add a passcode in Settings → Face ID & Passcode."
            return
        }
        isLocked = true
        if let error = error {
            lastError = AppLock.friendlyMessage(for: error)
        } else {
            lastError = "Unlocking isn't available right now. Tap Unlock to try again."
        }
    }

    private nonisolated static func friendlyMessage(for error: Error) -> String {
        guard let laError = error as? LAError else {
            return "Something went wrong while unlocking. Tap Unlock to try again."
        }
        switch laError.code {
        case .userCancel:
            return "Unlock was cancelled. Tap Unlock when you're ready."
        case .appCancel, .systemCancel:
            return "Unlock was interrupted. Tap Unlock to try again."
        case .authenticationFailed:
            return "That didn't match. Tap Unlock to try again."
        case .biometryLockout:
            return "\(biometryName) is paused after too many tries. Tap Unlock and use your passcode."
        case .passcodeNotSet:
            return "Your iPhone has no passcode, so there's nothing to unlock with. Add one in Settings → Face ID & Passcode."
        case .biometryNotEnrolled, .biometryNotAvailable:
            return "Face ID or Touch ID isn't set up, so your passcode is used instead. Tap Unlock to continue."
        case .userFallback:
            return "Tap Unlock and enter your passcode to continue."
        case .notInteractive, .invalidContext:
            return "The unlock prompt couldn't be shown just now. Tap Unlock to try again."
        default:
            return "Something went wrong while unlocking. Tap Unlock to try again."
        }
    }
}
