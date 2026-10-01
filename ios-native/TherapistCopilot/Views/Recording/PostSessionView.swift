import SwiftUI
import Foundation
import UIKit

/// The three-step wrap-up after a recording: a mood check-in with an optional quick note,
/// a short processing screen while the session is analyzed on this iPhone, and a summary
/// teaser with links to the full session.
struct PostSessionView: View {
    @Environment(SessionStore.self) private var store
    @Environment(InsightsService.self) private var insights
    @Environment(AppSettings.self) private var settings

    private let session: TherapySession
    private let onDone: () -> Void

    /// 0 = check-in, 1 = processing, 2 = summary.
    @State private var step: Int = 0
    @State private var moodAfter: Int?
    @State private var quickNote: String = ""
    @State private var saved: TherapySession?
    @State private var didStoreDraft: Bool = false
    @State private var isProcessing: Bool = false

    init(session: TherapySession, onDone: @escaping () -> Void) {
        self.session = session
        self.onDone = onDone
        self._moodAfter = State(initialValue: session.moodAfter)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case 0:
                    checkInStep
                case 1:
                    processingStep
                default:
                    summaryStep
                }
            }
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if step == 0 {
                        Button("Skip") { continueTapped() }
                    } else if step == 2 {
                        Button("Done", action: onDone)
                    }
                }
            }
            .navigationDestination(for: UUID.self) { sessionID in
                SessionDetailView(sessionID: sessionID)
            }
            .onAppear { storeDraftIfNeeded() }
        }
        .interactiveDismissDisabled(step == 1)
    }

    private var screenTitle: String {
        switch step {
        case 0: return "Quick check-in"
        case 1: return "Working on it"
        default: return "Session summary"
        }
    }

    // MARK: - Step 0: check-in

    private var checkInStep: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session saved to this iPhone")
                            .font(.headline)
                        Text(savedSummaryLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }

            Section {
                MoodSlider(title: "How do you feel now?", mood: $moodAfter)
                    .padding(.vertical, 4)
            } footer: {
                if let before = session.moodBefore {
                    Text("Before the session you were at \(before)/10 (\(MoodScale.label(for: before))).")
                } else {
                    Text("Optional. A quick check-in helps you see how sessions affect you over time.")
                }
            }

            Section {
                TextField("Anything you want to remember? (optional)", text: $quickNote, axis: .vertical)
                    .lineLimit(3...6)
            } header: {
                Text("Quick note")
            } footer: {
                Text("A feeling, a thought, something your therapist said. You can add more later in the session's Notes.")
            }

            Section {
                Button { continueTapped() } label: {
                    HStack {
                        Spacer()
                        Text("Continue")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(continueFootnote)
            }
        }
    }

    private var savedSummaryLine: String {
        let duration = Formatters.durationWords(session.duration)
        if session.hasTranscript {
            let words = session.wordCount
            return duration + " · " + (words == 1 ? "1 word transcribed" : "\(words) words transcribed")
        }
        if session.audioFileName != nil {
            return duration + " · audio only, no transcript"
        }
        return duration
    }

    private var continueFootnote: String {
        if session.hasTranscript {
            return "Next, the app reads through the transcript on this iPhone and writes your summary. Nothing is sent anywhere."
        }
        return "There's no transcript for this session, so there won't be a written summary. You can still listen back and keep notes."
    }

    // MARK: - Step 1: processing

    private var processingStep: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(statusLine)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("This runs entirely on your iPhone and usually takes a few seconds.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private var statusLine: String {
        let status = insights.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return status.isEmpty ? "Preparing your summary…" : status
    }

    // MARK: - Step 2: summary

    private var summaryStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let saved {
                    if let result = saved.insights {
                        if result.needsSupportFlag {
                            SupportResourcesCard()
                        }
                        if saved.hasTranscript {
                            overviewCard(result: result, session: saved)
                        } else {
                            audioOnlyCard
                        }
                    } else {
                        CardView(title: "Saved", systemImage: "checkmark.circle") {
                            Text("Your session is saved. You can create a summary any time from the session page using \"Regenerate insights\".")
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if saved.moodBefore != nil || saved.moodAfter != nil {
                        moodCard(session: saved)
                    }
                    actionButtons(sessionID: saved.id)
                } else {
                    missingSessionView
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }

    private func overviewCard(result: SessionInsights, session: TherapySession) -> some View {
        CardView(title: "Your summary", systemImage: "text.alignleft") {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.overview)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)

                if !result.themes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(result.themes.prefix(3))) { theme in
                                ChipView(theme.name, systemImage: "tag")
                            }
                        }
                    }
                }

                if result.suggestions.count > 0 || session.actionItems.count > 0 || session.nextSessionQuestions.count > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        if result.suggestions.count > 0 {
                            countRow(
                                count: result.suggestions.count,
                                singular: "suggestion for the week",
                                plural: "suggestions for the week",
                                systemImage: "lightbulb"
                            )
                        }
                        if session.actionItems.count > 0 {
                            countRow(
                                count: session.actionItems.count,
                                singular: "commitment spotted",
                                plural: "commitments spotted",
                                systemImage: "checklist"
                            )
                        }
                        if session.nextSessionQuestions.count > 0 {
                            countRow(
                                count: session.nextSessionQuestions.count,
                                singular: "question for next time",
                                plural: "questions for next time",
                                systemImage: "questionmark.bubble"
                            )
                        }
                    }
                    .padding(.top, 2)
                }

                HStack(spacing: 6) {
                    Image(systemName: "cpu")
                    Text("Made with " + result.engine.label + ", on this iPhone")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func countRow(count: Int, singular: String, plural: String, systemImage: String) -> some View {
        Label {
            Text(count == 1 ? "1 " + singular : "\(count) " + plural)
                .font(.subheadline)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(Color.accentColor)
        }
    }

    private var audioOnlyCard: some View {
        CardView(title: "Audio only", systemImage: "waveform") {
            Text("No words were transcribed this time, so there's no written summary. You can still listen back to the recording and write down what you want to remember in the session's Notes.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func moodCard(session: TherapySession) -> some View {
        CardView(title: "Mood check-in", systemImage: "face.smiling") {
            HStack(alignment: .center, spacing: 18) {
                moodColumn(label: "Before", mood: session.moodBefore)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                moodColumn(label: "After", mood: session.moodAfter)
                Spacer(minLength: 0)
                if let change = session.moodChange {
                    Text(moodChangeText(change))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(change >= 0 ? Color.green : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func moodColumn(label: String, mood: Int?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let mood {
                Text(MoodScale.emoji(for: mood))
                    .font(.title2)
                Text("\(mood)/10")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MoodScale.color(for: mood))
            } else {
                Text("—")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func moodChangeText(_ change: Int) -> String {
        if change > 0 {
            return change == 1 ? "Up 1 point" : "Up \(change) points"
        }
        if change < 0 {
            return change == -1 ? "Down 1 point" : "Down \(-change) points"
        }
        return "Steady"
    }

    private func actionButtons(sessionID: UUID) -> some View {
        VStack(spacing: 12) {
            NavigationLink(value: sessionID) {
                HStack {
                    Spacer()
                    Label("Open session", systemImage: "doc.text.magnifyingglass")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button(action: onDone) {
                HStack {
                    Spacer()
                    Text("Done")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private var missingSessionView: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                "Couldn't find the saved session",
                systemImage: "exclamationmark.triangle",
                description: Text("The recording was saved but the session couldn't be read back. Check your Sessions list.")
            )
            Button(action: onDone) {
                HStack {
                    Spacer()
                    Text("Done")
                        .font(.headline)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    /// Puts the recorded session in the store right away so nothing is lost if the sheet is
    /// dismissed before the check-in is finished. `store.add` replaces by id, so the later
    /// save in `process()` simply updates it.
    private func storeDraftIfNeeded() {
        guard !didStoreDraft else { return }
        didStoreDraft = true
        if store.session(id: session.id) == nil {
            store.add(session)
        }
    }

    private func continueTapped() {
        guard !isProcessing else { return }
        isProcessing = true
        step = 1
        Task {
            await process()
        }
    }

    @MainActor
    private func process() async {
        var s = session
        s.moodAfter = moodAfter
        let note = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty {
            let existing = s.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            s.notes = existing.isEmpty ? note : existing + "\n\n" + note
        }
        store.add(s)

        let history = store.sessions.filter { $0.id != s.id }
        let result = await insights.generate(
            for: s,
            history: history,
            preference: settings.insightEnginePreference
        )

        store.modify(s.id) { stored in
            stored.insights = result
            if stored.actionItems.isEmpty {
                stored.actionItems = result.detectedActionItems.map { text in
                    ActionItem(text: text, source: .detected)
                }
            }
            if stored.nextSessionQuestions.isEmpty {
                stored.nextSessionQuestions = result.questionsForNextSession
            }
        }

        // Honour the "keep audio after transcription" setting; audio-only sessions keep
        // their recording since it is all they have.
        if !settings.keepAudioAfterTranscription,
           let stored = store.session(id: s.id),
           stored.hasTranscript,
           stored.audioFileName != nil {
            store.deleteAudio(for: stored)
        }

        saved = store.session(id: s.id)
        isProcessing = false
        step = 2
    }
}
