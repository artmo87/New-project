import SwiftUI
import Observation

/// App entry point. Creates every service once, injects them into the environment,
/// and keeps the lock screen on top of everything while the app is locked.
@main
struct TherapistCopilotApp: App {
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = SessionStore()
    @State private var settings = AppSettings()
    @State private var recorder = RecordingCoordinator()
    @State private var insights = InsightsService()
    @State private var appLock = AppLock()

    /// Makes sure the launch-time lock happens exactly once.
    @State private var didHandleLaunch = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(settings)
                .environment(recorder)
                .environment(insights)
                .environment(appLock)
                .overlay {
                    ZStack {
                        if appLock.isLocked {
                            LockScreenView(appLock: appLock)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
                }
                .onAppear {
                    lockAtLaunchIfNeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
        }
    }

    // MARK: - Lock handling

    /// When app lock is on, the app starts locked and immediately asks to unlock.
    private func lockAtLaunchIfNeeded() {
        guard !didHandleLaunch else { return }
        didHandleLaunch = true
        guard settings.appLockEnabled else { return }
        appLock.lock()
        if scenePhase == .active {
            Task {
                await appLock.unlock()
            }
        }
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if appLock.isLocked {
                Task {
                    await appLock.unlock()
                }
            }
        case .inactive, .background:
            if settings.appLockEnabled {
                appLock.lock()
            }
        @unknown default:
            break
        }
    }
}

// MARK: - Lock screen

/// Full-screen cover shown while the app is locked. Hides the content underneath and
/// offers a single button to unlock with Face ID, Touch ID or the device passcode.
private struct LockScreenView: View {
    let appLock: AppLock

    var body: some View {
        ZStack {
            // An opaque base so nothing shows through, with a material finish on top.
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text("Therapist Copilot")
                    .font(.title2.weight(.bold))

                Text("Your sessions and notes are locked.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = appLock.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                Button {
                    Task {
                        await appLock.unlock()
                    }
                } label: {
                    HStack(spacing: 10) {
                        if appLock.isAuthenticating {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: LockScreenView.biometryIcon)
                        }
                        Text("Unlock with \(AppLock.biometryName)")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appLock.isAuthenticating)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }
            .padding()
        }
        .accessibilityAddTraits(.isModal)
    }

    private static var biometryIcon: String {
        switch AppLock.biometryName {
        case "Face ID":
            return "faceid"
        case "Touch ID":
            return "touchid"
        default:
            return "key.fill"
        }
    }
}
