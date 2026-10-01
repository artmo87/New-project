import SwiftUI
import Observation

/// The four main areas of the app.
enum AppTab: Hashable, CaseIterable {
    case home
    case sessions
    case prepare
    case settings

    var title: String {
        switch self {
        case .home: return "Home"
        case .sessions: return "Sessions"
        case .prepare: return "Prepare"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .sessions: return "list.bullet.rectangle"
        case .prepare: return "checklist"
        case .settings: return "gearshape"
        }
    }
}

/// Shows the onboarding pages the first time, then the main tab bar.
struct RootView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab: AppTab = .home

    init() {}

    var body: some View {
        ZStack {
            if settings.hasSeenOnboarding {
                MainTabView(selection: $selectedTab)
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: settings.hasSeenOnboarding)
    }
}

// MARK: - Main tabs

private struct MainTabView: View {
    @Binding var selection: AppTab

    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem {
                    Label(AppTab.home.title, systemImage: AppTab.home.systemImage)
                }
                .tag(AppTab.home)

            SessionListView()
                .tabItem {
                    Label(AppTab.sessions.title, systemImage: AppTab.sessions.systemImage)
                }
                .tag(AppTab.sessions)

            PrepareView()
                .tabItem {
                    Label(AppTab.prepare.title, systemImage: AppTab.prepare.systemImage)
                }
                .tag(AppTab.prepare)

            SettingsView()
                .tabItem {
                    Label(AppTab.settings.title, systemImage: AppTab.settings.systemImage)
                }
                .tag(AppTab.settings)
        }
    }
}

// MARK: - Onboarding

private struct OnboardingPage: Identifiable {
    let id: Int
    let systemImage: String
    let title: String
    let message: String
}

/// Three short pages: what the app does, where the data lives, and a consent reminder.
private struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @State private var pageIndex = 0

    private static let pages: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            systemImage: "waveform.and.mic",
            title: "Your sessions, remembered",
            message: "Record a therapy session and get a written transcript, a short summary of what came up, the moments that mattered, and gentle suggestions for the week ahead."
        ),
        OnboardingPage(
            id: 1,
            systemImage: "lock.shield",
            title: "Everything stays on your iPhone",
            message: "Recording, transcription and analysis all happen on this device. Nothing is uploaded, there are no accounts, and the app never connects to the internet. Your sessions are yours alone."
        ),
        OnboardingPage(
            id: 2,
            systemImage: "person.2.wave.2",
            title: "A word about consent",
            message: "Please let your therapist know you'd like to record and make sure they're comfortable with it. Recording laws differ from place to place, so it's up to you to follow the rules where you are.\n\nWhat you read here is meant for reflection. It isn't medical advice and doesn't replace your therapist."
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $pageIndex) {
                ForEach(OnboardingView.pages) { page in
                    OnboardingPageView(page: page)
                        .tag(page.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            VStack(spacing: 12) {
                Button {
                    advance()
                } label: {
                    Text(isLastPage ? "Get started" : "Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text(isLastPage
                     ? "You can read these notes again any time in Settings."
                     : "No account, no internet. Everything stays on this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
    }

    private var isLastPage: Bool {
        pageIndex >= OnboardingView.pages.count - 1
    }

    private func advance() {
        if isLastPage {
            settings.hasAcceptedConsent = true
            settings.hasSeenOnboarding = true
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                pageIndex += 1
            }
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)

            Image(systemName: page.systemImage)
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 128, height: 128)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.title.weight(.bold))
                    .multilineTextAlignment(.center)

                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 40)
    }
}
