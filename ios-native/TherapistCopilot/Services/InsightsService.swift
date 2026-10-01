import Foundation
import Observation

/// Runs the insight engines for a session and exposes progress to the UI.
/// Classic (rule-based) analysis always runs; the on-device model enriches it when
/// the user allows it and the device supports it. Never throws.
@MainActor
@Observable
final class InsightsService {
    private(set) var isWorking: Bool = false
    /// e.g. "Analyzing transcript…", "Asking the on-device model…". Empty when idle.
    private(set) var statusText: String = ""

    /// Number of `generate` calls currently in flight (regenerate can overlap a post-session run).
    private var activeJobs: Int = 0

    init() {}

    /// Always runs Classic; then, if preference == .automatic and OnDeviceModelSupport.isAvailable,
    /// tries FoundationModelsInsightEngine.enrich and falls back to Classic on error. Never throws.
    func generate(for session: TherapySession,
                  history: [TherapySession],
                  preference: InsightEnginePreference) async -> SessionInsights {
        beginJob()
        defer { endJob() }

        statusText = "Analyzing transcript…"
        let classic = await Task.detached(priority: .userInitiated) {
            HeuristicInsightEngine().analyze(session, history: history)
        }.value

        guard preference == .automatic,
              session.hasTranscript,
              OnDeviceModelSupport.isAvailable else {
            return classic
        }

        var result = classic
        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            statusText = "Asking the on-device model…"
            let engine = FoundationModelsInsightEngine()
            do {
                result = try await engine.enrich(base: classic, session: session, progress: { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeJobs > 0 else { return }
                        self.statusText = text
                    }
                })
            } catch {
                // Any model problem (unavailable, guardrails, context size, cancellation)
                // means we quietly keep the Classic result.
                result = classic
            }
            #endif
        }
        return result
    }

    // MARK: Job bookkeeping

    private func beginJob() {
        activeJobs += 1
        isWorking = true
    }

    private func endJob() {
        activeJobs = max(0, activeJobs - 1)
        if activeJobs == 0 {
            isWorking = false
            statusText = ""
        }
    }
}
