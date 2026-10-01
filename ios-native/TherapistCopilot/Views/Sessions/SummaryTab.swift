import SwiftUI
import Charts
import Foundation
import UIKit

/// The "Summary" tab of a session: overview, highlights, themes, emotions, the mood
/// trajectory across the session, key moments, thinking patterns, the action-item
/// checklist and the commitments that were detected in the transcript.
struct SummaryTab: View {
    let sessionID: UUID
    let player: AudioPlayer

    @Environment(SessionStore.self) private var store
    @Environment(InsightsService.self) private var insights
    @Environment(AppSettings.self) private var settings

    @State private var newItemText: String = ""
    @State private var isGenerating: Bool = false

    init(sessionID: UUID, player: AudioPlayer) {
        self.sessionID = sessionID
        self.player = player
    }

    var body: some View {
        ScrollView {
            if let session = store.session(id: sessionID) {
                VStack(alignment: .leading, spacing: 16) {
                    if let generated = session.insights {
                        analysisCards(session: session, generated: generated)
                        commitmentCards(session: session, generated: generated)
                    } else {
                        notGeneratedCard(session: session)
                        actionItemsCard(session: session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                ContentUnavailableView(
                    "Session not found",
                    systemImage: "questionmark.folder",
                    description: Text("This session is no longer available.")
                )
                .padding(.top, 40)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Card groups

    @ViewBuilder
    private func analysisCards(session: TherapySession, generated: SessionInsights) -> some View {
        overviewCard(generated)
        if !generated.highlights.isEmpty {
            highlightsCard(generated)
        }
        if !generated.themes.isEmpty {
            themesCard(generated)
        }
        if !generated.emotions.isEmpty {
            emotionsCard(generated)
        }
        if generated.moodTrajectory.count >= 2 {
            trajectoryCard(generated)
        }
        if !generated.keyMoments.isEmpty {
            keyMomentsCard(generated, hasAudio: store.audioURL(for: session) != nil)
        }
        if !generated.thoughtPatterns.isEmpty {
            thoughtPatternsCard(generated)
        }
    }

    @ViewBuilder
    private func commitmentCards(session: TherapySession, generated: SessionInsights) -> some View {
        let pending = pendingCommitments(session: session, generated: generated)
        actionItemsCard(session: session)
        if !pending.isEmpty {
            detectedCommitmentsCard(pending)
        }
    }

    // MARK: - Not generated yet

    private func notGeneratedCard(session: TherapySession) -> some View {
        CardView(title: "Insights", systemImage: "sparkles") {
            Text("Insights haven't been generated yet.")
                .font(.body)

            if session.hasTranscript {
                Text("Generating takes a few seconds and happens entirely on your iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("This session has no transcript, so there isn't much to analyze. You can still listen back and keep notes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if isGenerating {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(insights.statusText.isEmpty ? "Working on it…" : insights.statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                Button("Generate insights") {
                    Task { await generate(session) }
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
    }

    @MainActor
    private func generate(_ session: TherapySession) async {
        guard !isGenerating else { return }
        isGenerating = true
        defer { isGenerating = false }

        let history = store.sessions.filter { $0.id != session.id }
        let result = await insights.generate(
            for: session,
            history: history,
            preference: settings.insightEnginePreference
        )

        store.modify(session.id) { stored in
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
    }

    // MARK: - Overview

    private func overviewCard(_ generated: SessionInsights) -> some View {
        CardView(title: "Overview", systemImage: "text.alignleft") {
            Text(generated.overview)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ChipView(generated.engine.label, systemImage: engineIcon(generated.engine))
                Text("Generated " + Formatters.relative(generated.generatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func engineIcon(_ engine: InsightEngineKind) -> String {
        switch engine {
        case .onDeviceModel: return "sparkles"
        case .classic: return "text.magnifyingglass"
        }
    }

    // MARK: - Highlights

    private func highlightsCard(_ generated: SessionInsights) -> some View {
        CardView(title: "Highlights", systemImage: "list.bullet") {
            ForEach(Array(generated.highlights.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .font(.body.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                    Text(line)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Themes

    private func themesCard(_ generated: SessionInsights) -> some View {
        CardView(title: "Themes", systemImage: "tag") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(generated.themes) { theme in
                    ChipView(theme.name + " · " + String(theme.mentions))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let quote = generated.themes.first?.quote, !quote.isEmpty {
                Text("“" + quote + "”")
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Text("The number shows how often each topic came up.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Emotions

    private func emotionsCard(_ generated: SessionInsights) -> some View {
        CardView(title: "Emotions", systemImage: "heart") {
            ForEach(generated.emotions) { emotion in
                emotionRow(emotion)
            }
            Text("Based on the feeling words you used. Longer bars came up more often.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func emotionRow(_ emotion: EmotionInsight) -> some View {
        let intensity = CGFloat(min(1.0, max(0.0, emotion.intensity)))
        let barWidth: CGFloat = 150
        return HStack(spacing: 10) {
            Text(emotion.name)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: 88, alignment: .leading)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(8, intensity * barWidth))
            }
            .frame(width: barWidth, height: 8)

            Text(String(emotion.mentions) + "×")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(emotion.name + ", mentioned " + String(emotion.mentions) + " times")
    }

    // MARK: - Mood trajectory

    private func trajectoryCard(_ generated: SessionInsights) -> some View {
        let points = generated.moodTrajectory.enumerated().map { pair in
            TrajectoryPoint(id: pair.offset, value: min(1.0, max(-1.0, pair.element)))
        }
        return CardView(title: "Mood across the session", systemImage: "waveform.path.ecg") {
            Chart {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("Part", point.id),
                        yStart: .value("Neutral", 0.0),
                        yEnd: .value("Tone", point.value)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                    .interpolationMethod(.monotone)

                    LineMark(
                        x: .value("Part", point.id),
                        y: .value("Tone", point.value)
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                }

                RuleMark(y: .value("Neutral", 0.0))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
            .chartYScale(domain: -1.0...1.0)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 120)
            .accessibilityLabel("Mood across the session")

            HStack {
                Text("Start")
                Spacer()
                Text("→")
                Spacer()
                Text("End")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text(toneSummary(generated))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func toneSummary(_ generated: SessionInsights) -> String {
        let overall = generated.overallSentiment
        var opening: String
        if overall > 0.25 {
            opening = "Overall the tone leaned positive"
        } else if overall > 0.05 {
            opening = "Overall the tone was gently positive"
        } else if overall < -0.25 {
            opening = "Overall the tone was heavy — hard sessions are often the useful ones"
        } else if overall < -0.05 {
            opening = "Overall the tone was a little low"
        } else {
            opening = "Overall the tone was fairly balanced"
        }

        let trajectory = generated.moodTrajectory
        guard trajectory.count >= 2 else {
            opening += "."
            return opening
        }

        let half = trajectory.count / 2
        let firstSlice = trajectory.prefix(half)
        let lastSlice = trajectory.suffix(trajectory.count - half)
        let firstMean = firstSlice.reduce(0.0, +) / Double(max(1, firstSlice.count))
        let lastMean = lastSlice.reduce(0.0, +) / Double(max(1, lastSlice.count))
        let delta = lastMean - firstMean

        if delta > 0.15 {
            return opening + ", and it lifted toward the end."
        } else if delta < -0.15 {
            return opening + ", and it dipped toward the end."
        } else {
            return opening + ", and stayed fairly steady throughout."
        }
    }

    // MARK: - Key moments

    private func keyMomentsCard(_ generated: SessionInsights, hasAudio: Bool) -> some View {
        CardView(title: "Key moments", systemImage: "star") {
            if !hasAudio && generated.keyMoments.contains(where: { $0.time != nil }) {
                Text("Times are shown for reference; the recording isn't available to play.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(generated.keyMoments) { moment in
                keyMomentRow(moment, hasAudio: hasAudio)
                if moment.id != generated.keyMoments.last?.id {
                    Divider()
                }
            }
        }
    }

    @MainActor
    private func keyMomentRow(_ moment: KeyMoment, hasAudio: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if let time = moment.time {
                Button {
                    guard hasAudio else { return }
                    player.seek(to: time)
                    player.play()
                } label: {
                    Text("[" + Formatters.clock(time) + "]")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(hasAudio ? Color.accentColor : Color.secondary)
                .disabled(!hasAudio)
                .accessibilityLabel("Play from " + Formatters.clock(time))
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(moment.reason, systemImage: reasonIcon(moment.reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(moment.text)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func reasonIcon(_ reason: String) -> String {
        switch reason.lowercased() {
        case "strong emotion": return "heart.fill"
        case "insight": return "lightbulb"
        case "commitment": return "checkmark.seal"
        case "thinking pattern": return "brain"
        case "core theme": return "tag"
        default: return "star"
        }
    }

    // MARK: - Thought patterns

    private func thoughtPatternsCard(_ generated: SessionInsights) -> some View {
        CardView(title: "Thinking patterns", systemImage: "brain") {
            Text("Habits of thought everyone has from time to time. Worth noticing, not judging.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(generated.thoughtPatterns) { pattern in
                VStack(alignment: .leading, spacing: 6) {
                    Text(pattern.name)
                        .font(.headline)
                    if !pattern.description.isEmpty {
                        Text(pattern.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("“" + pattern.quote + "”")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 2)
                        Text("Another way to see it: " + pattern.reframe)
                            .font(.subheadline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if pattern.id != generated.thoughtPatterns.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: - Action items

    private func actionItemsCard(session: TherapySession) -> some View {
        let openCount = session.actionItems.filter { !$0.isDone }.count
        let doneCount = session.actionItems.count - openCount
        return CardView(title: "Action items", systemImage: "checklist") {
            if session.actionItems.isEmpty {
                Text("Nothing here yet. Add something you'd like to try before next session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(session.actionItems) { item in
                actionItemRow(item)
            }

            Divider()

            HStack(spacing: 10) {
                TextField("Add a commitment…", text: $newItemText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit { addTypedItem() }
                Button {
                    addTypedItem()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(newItemText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Add commitment")
            }

            if !session.actionItems.isEmpty {
                Text(String(openCount) + " open · " + String(doneCount) + " done")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @MainActor
    private func actionItemRow(_ item: ActionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                toggle(item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isDone ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.text)
                    .font(.body)
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(sourceLabel(item.source))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            Button(role: .destructive) {
                remove(item)
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.red)
            .accessibilityLabel("Delete commitment")
        }
        .padding(.vertical, 2)
    }

    private func sourceLabel(_ source: ActionItem.Source) -> String {
        switch source {
        case .detected: return "Heard in the session"
        case .manual: return "Added by you"
        case .suggestion: return "From a suggestion"
        }
    }

    @MainActor
    private func toggle(_ item: ActionItem) {
        store.modify(sessionID) { stored in
            if let index = stored.actionItems.firstIndex(where: { $0.id == item.id }) {
                stored.actionItems[index].isDone.toggle()
            }
        }
    }

    @MainActor
    private func remove(_ item: ActionItem) {
        store.modify(sessionID) { stored in
            stored.actionItems.removeAll { $0.id == item.id }
        }
    }

    @MainActor
    private func addTypedItem() {
        let text = newItemText
        newItemText = ""
        addItem(text: text, source: .manual)
    }

    @MainActor
    private func addItem(text: String, source: ActionItem.Source) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = normalizedCommitment(trimmed)
        store.modify(sessionID) { stored in
            let alreadyThere = stored.actionItems.contains { normalizedCommitment($0.text) == key }
            if !alreadyThere {
                stored.actionItems.append(ActionItem(text: trimmed, source: source))
            }
        }
    }

    // MARK: - Detected commitments

    private func pendingCommitments(session: TherapySession, generated: SessionInsights) -> [String] {
        let existing = Set(session.actionItems.map { normalizedCommitment($0.text) })
        var seen = Set<String>()
        var result: [String] = []
        for text in generated.detectedActionItems {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizedCommitment(trimmed)
            if trimmed.isEmpty || existing.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    private func detectedCommitmentsCard(_ pending: [String]) -> some View {
        CardView(title: "Detected commitments", systemImage: "wand.and.stars") {
            Text("These sounded like things you said you'd do. Add the ones you want to keep track of.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(Array(pending.enumerated()), id: \.offset) { _, text in
                HStack(alignment: .top, spacing: 10) {
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Add") {
                        addItem(text: text, source: .detected)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Helpers

/// One bucket of the mood trajectory, for the chart.
private struct TrajectoryPoint: Identifiable {
    let id: Int
    let value: Double
}

/// Lower-cased, whitespace-trimmed text used to tell whether a commitment is already in the list.
private func normalizedCommitment(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}
