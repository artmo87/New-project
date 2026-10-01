import SwiftUI
import Foundation
import Observation
import Charts
import UIKit

/// The landing screen: greeting, the big record button, a look back at the last session,
/// what is waiting for the next one, and a small mood chart.
struct HomeView: View {
    @Environment(SessionStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(RecordingCoordinator.self) private var recorder

    @State private var showPreSession = false
    /// Draft handed over by the pre-session sheet; the recorder starts once the sheet is gone.
    @State private var pendingDraft: TherapySession? = nil
    /// Finished session handed over by the recording cover; the post-session sheet opens once the cover is gone.
    @State private var pendingFinishedSession: TherapySession? = nil
    @State private var finishedSession: TherapySession? = nil
    /// True while the full-screen recording cover is on screen.
    @State private var isRecordingCoverShown = false

    init() {}

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    recordSection

                    if let loadError = store.loadError {
                        loadErrorCard(loadError)
                    }

                    if store.sessions.isEmpty {
                        emptyStateCard
                    } else {
                        if let last = store.sessions.first {
                            lastSessionCard(last)
                        }
                        upNextCard
                        moodChartCard
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Home")
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { sessionID in
                SessionDetailView(sessionID: sessionID)
            }
        }
        .sheet(isPresented: $showPreSession, onDismiss: { beginPendingRecording() }) {
            PreSessionSheet { draft in
                startRecording(draft)
            }
            .overlay { PresentedLockCover() }
        }
        .fullScreenCover(isPresented: recordingCoverBinding, onDismiss: { handleRecordingCoverDismissed() }) {
            RecordingView { finished in
                pendingFinishedSession = finished
            }
            .onAppear {
                isRecordingCoverShown = true
            }
            .overlay { PresentedLockCover() }
        }
        .sheet(item: $finishedSession) { session in
            PostSessionView(session: session) {
                finishedSession = nil
            }
            .interactiveDismissDisabled()
            .overlay { PresentedLockCover() }
        }
        .alert("Couldn't start recording", isPresented: startErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recorder.errorMessage ?? "Something went wrong while starting the recording. Please try again.")
        }
    }

    // MARK: - Presentation plumbing

    /// The recording cover is up whenever the coordinator is doing anything at all.
    private var recordingCoverBinding: Binding<Bool> {
        Binding(
            get: { recorder.state != .idle },
            set: { _ in }
        )
    }

    /// The start-up error alert waits until the recording cover has fully gone away.
    private var startErrorBinding: Binding<Bool> {
        Binding(
            get: { recorder.errorMessage != nil && !isRecordingCoverShown },
            set: { isPresented in
                if !isPresented {
                    recorder.errorMessage = nil
                }
            }
        )
    }

    /// Called by the pre-session sheet. The sheet dismisses itself; recording begins in `onDismiss`
    /// so the full-screen cover never tries to appear while the sheet is still animating away.
    private func startRecording(_ draft: TherapySession) {
        pendingDraft = draft
        showPreSession = false
    }

    private func beginPendingRecording() {
        guard let draft = pendingDraft else { return }
        pendingDraft = nil
        let audioURL = store.newAudioURL(for: draft.id)
        let locale = settings.recognitionLocale
        let onDeviceOnly = settings.onDeviceRecognitionOnly
        Task {
            await recorder.start(draft: draft, audioURL: audioURL, locale: locale, onDeviceOnly: onDeviceOnly)
        }
    }

    private func handleRecordingCoverDismissed() {
        isRecordingCoverShown = false
        if let session = pendingFinishedSession {
            pendingFinishedSession = nil
            finishedSession = session
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting)
                .font(.largeTitle.weight(.bold))
            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Hello"
        }
    }

    // MARK: - Record

    private var recordSection: some View {
        VStack(spacing: 12) {
            RecordButton(isRecording: false) {
                showPreSession = true
            }
            Text("Start a session")
                .font(.headline)
            Text("Recording and transcription happen on this iPhone. Nothing is uploaded.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Last session

    private func lastSessionCard(_ session: TherapySession) -> some View {
        CardView(title: "Last session", systemImage: "clock.arrow.circlepath") {
            NavigationLink(value: session.id) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.displayTitle)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }

                    Text(sessionMetaLine(session))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    moodRow(for: session)
                    themesRow(for: session)
                    statusRow(for: session)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func sessionMetaLine(_ session: TherapySession) -> String {
        var parts: [String] = [Formatters.relative(session.createdAt)]
        if session.duration > 0 {
            parts.append(Formatters.durationWords(session.duration))
        }
        let therapist = session.therapistName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !therapist.isEmpty {
            parts.append("with \(therapist)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func moodRow(for session: TherapySession) -> some View {
        HStack(spacing: 8) {
            if let before = session.moodBefore, let after = session.moodAfter {
                Text(MoodScale.emoji(for: before))
                Text("\(before)")
                    .foregroundStyle(.primary)
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(MoodScale.emoji(for: after))
                Text("\(after)")
                    .foregroundStyle(.primary)
                if let change = session.moodChange, change != 0 {
                    Text(change > 0 ? "+\(change)" : "\(change)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MoodScale.color(for: after))
                }
                Text("mood before and after")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let after = session.moodAfter {
                Text(MoodScale.emoji(for: after))
                Text("Felt \(MoodScale.label(for: after).lowercased()) afterwards (\(after)/10)")
                    .foregroundStyle(.secondary)
            } else if let before = session.moodBefore {
                Text(MoodScale.emoji(for: before))
                Text("Felt \(MoodScale.label(for: before).lowercased()) going in (\(before)/10)")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "face.smiling")
                    .foregroundStyle(.secondary)
                Text("No mood check-in for this one")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func themesRow(for session: TherapySession) -> some View {
        if let insights = session.insights, !insights.themes.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(insights.themes.prefix(3))) { theme in
                    ChipView(theme.name)
                }
            }
        }
    }

    private func statusRow(for session: TherapySession) -> some View {
        HStack(spacing: 12) {
            Label(openItemsText(count: session.openActionItems.count), systemImage: "checklist")
            if !session.hasTranscript {
                Label("Audio only", systemImage: "waveform")
            } else if session.insights == nil {
                Label("Insights not generated yet", systemImage: "sparkles")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func openItemsText(count: Int) -> String {
        switch count {
        case 0: return "No open commitments"
        case 1: return "1 open commitment"
        default: return "\(count) open commitments"
        }
    }

    // MARK: - Up next

    private var upNextCard: some View {
        let items = Array(store.openActionItems.prefix(3))
        let questions = Array(store.pendingQuestions.prefix(2))
        return CardView(title: "Up next", systemImage: "arrow.forward.circle") {
            if items.isEmpty && questions.isEmpty {
                Text("Nothing is waiting for you right now. Commitments and questions from your sessions will show up here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { entry in
                        actionItemRow(entry)
                    }
                    if !questions.isEmpty {
                        if !items.isEmpty {
                            Divider()
                        }
                        Text("Questions to bring")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(questions) { question in
                            questionRow(question)
                        }
                    }
                }
            }
        }
    }

    private func actionItemRow(_ entry: OpenActionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    store.setActionItemDone(sessionID: entry.sessionID, itemID: entry.item.id, isDone: !entry.item.isDone)
                }
            } label: {
                Image(systemName: entry.item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(entry.item.isDone ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.item.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text("From \(entry.sessionTitle) · \(Formatters.relative(entry.sessionDate))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func questionRow(_ question: PendingQuestion) -> some View {
        NavigationLink(value: question.sessionID) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "questionmark.bubble")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(question.question)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text("From \(question.sessionTitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mood chart

    /// After-session mood for the last ten sessions, oldest first. `id` is the position
    /// among those ten so gaps (sessions without a check-in) keep their spacing.
    private var moodPoints: [MoodPoint] {
        let recent = Array(store.sessions.prefix(10).reversed())
        var points: [MoodPoint] = []
        for (index, session) in recent.enumerated() {
            if let mood = session.moodAfter {
                points.append(MoodPoint(id: index, mood: mood, date: session.createdAt))
            }
        }
        return points
    }

    @ViewBuilder
    private var moodChartCard: some View {
        let points = moodPoints
        if points.count >= 2 {
            CardView(title: "Mood over time", systemImage: "chart.line.uptrend.xyaxis") {
                VStack(alignment: .leading, spacing: 8) {
                    Chart(points) { point in
                        LineMark(
                            x: .value("Session", point.id),
                            y: .value("Mood", point.mood)
                        )
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .foregroundStyle(Color.accentColor)

                        PointMark(
                            x: .value("Session", point.id),
                            y: .value("Mood", point.mood)
                        )
                        .symbolSize(60)
                        .foregroundStyle(Color.accentColor)
                    }
                    .chartYScale(domain: 1...10)
                    .chartXAxis(.hidden)
                    .chartYAxis {
                        AxisMarks(values: [1, 5, 10])
                    }
                    .frame(height: 140)
                    .accessibilityLabel("Mood after each session")
                    .accessibilityValue(moodChartAccessibilityValue(points))

                    Text(moodChartCaption(points))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func moodChartCaption(_ points: [MoodPoint]) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        let base = "How you felt after each of your last \(points.count) sessions, oldest to newest."
        let difference = last.mood - first.mood
        if difference >= 2 {
            return base + " The trend is gently upward."
        }
        if difference <= -2 {
            return base + " It has dipped lately. That might be worth mentioning next time."
        }
        return base
    }

    private func moodChartAccessibilityValue(_ points: [MoodPoint]) -> String {
        points.map { "\(Formatters.shortDate($0.date)): \($0.mood) out of 10" }.joined(separator: ", ")
    }

    // MARK: - Empty and error states

    private var emptyStateCard: some View {
        CardView(title: "After your first session", systemImage: "sparkles") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tap the record button when your session starts. When you stop, here is what you'll get:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                featureRow(
                    systemImage: "text.quote",
                    title: "A written transcript",
                    detail: "Searchable, editable and time-stamped, created on this iPhone while you talk."
                )
                featureRow(
                    systemImage: "list.bullet.rectangle",
                    title: "A plain-language summary",
                    detail: "Themes, emotions and the moments that mattered, in a few short lines."
                )
                featureRow(
                    systemImage: "lightbulb",
                    title: "Gentle suggestions",
                    detail: "Small things to try during the week and questions to bring next time."
                )
                featureRow(
                    systemImage: "checklist",
                    title: "Your commitments, remembered",
                    detail: "Things you said you'd try are collected here so nothing slips away."
                )
            }
        }
    }

    private func featureRow(systemImage: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadErrorCard(_ message: String) -> some View {
        CardView(title: "Something needs attention", systemImage: "exclamationmark.triangle") {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Supporting types

private struct MoodPoint: Identifiable {
    let id: Int
    let mood: Int
    let date: Date
}

/// Lock cover for presented sheets and covers. The app-level lock screen is an overlay on the
/// root view, which sits underneath anything presented on top of it, so every presentation
/// carries its own cover. Renders nothing while the app is unlocked.
private struct PresentedLockCover: View {
    @Environment(AppLock.self) private var appLock

    var body: some View {
        if appLock.isLocked {
            lockedContent
        }
    }

    private var lockedContent: some View {
        ZStack {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea()
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Locked")
                    .font(.title3.weight(.semibold))
                if let error = appLock.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button {
                    Task {
                        await appLock.unlock()
                    }
                } label: {
                    Text("Unlock with \(AppLock.biometryName)")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appLock.isAuthenticating)
            }
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
    }
}
