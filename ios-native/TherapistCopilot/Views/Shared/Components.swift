import SwiftUI
import Foundation
import UIKit

// MARK: - CardView

/// Rounded card background with padding and an optional title row.
struct CardView<Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let content: Content

    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title, !title.isEmpty {
                HStack(spacing: 8) {
                    if let systemImage, !systemImage.isEmpty {
                        Image(systemName: systemImage)
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                    }
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}

// MARK: - ChipView

/// Small capsule tag.
struct ChipView: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color

    init(_ text: String, systemImage: String? = nil, tint: Color = .accentColor) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage, !systemImage.isEmpty {
                Image(systemName: systemImage)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - MoodSlider

/// 1...10 mood picker with emoji + label; binds an optional Int.
/// When the binding is nil a neutral "Not set" state is shown and the slider waits
/// at the middle; moving (or touching) the slider sets a value, "Skip" clears it.
struct MoodSlider: View {
    private let title: String
    @Binding private var mood: Int?
    @State private var sliderValue: Double

    init(title: String, mood: Binding<Int?>) {
        self.title = title
        self._mood = mood
        self._sliderValue = State(initialValue: Double(MoodSlider.clamp(mood.wrappedValue ?? 5)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if mood == nil {
                    Text("Not set")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Skip") {
                        mood = nil
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .accessibilityHint("Clears the mood you picked")
                }
            }

            HStack(spacing: 14) {
                moodFace
                    .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    if let mood {
                        HStack(spacing: 8) {
                            Text(MoodScale.label(for: mood))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text("\(mood)/10")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(MoodScale.color(for: mood), in: Capsule())
                        }
                        Text("Move the slider to adjust.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("How are you feeling?")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Drag the slider to pick 1 to 10, or leave it blank.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            Slider(value: $sliderValue, in: 1...10, step: 1) {
                Text(title)
            } minimumValueLabel: {
                Text("1")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("10")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                if !editing {
                    commitSliderValue()
                }
            }
            .tint(currentTint)
            .onChange(of: sliderValue) { _, _ in
                commitSliderValue()
            }
            .onChange(of: mood) { _, newValue in
                if let newValue {
                    let target = Double(MoodSlider.clamp(newValue))
                    if sliderValue != target {
                        sliderValue = target
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var moodFace: some View {
        if let mood {
            Text(MoodScale.emoji(for: mood))
                .font(.system(size: 40))
                .accessibilityHidden(true)
        } else {
            Image(systemName: "face.dashed")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var currentTint: Color {
        if let mood {
            return MoodScale.color(for: mood)
        }
        return Color.secondary
    }

    private func commitSliderValue() {
        let value = MoodSlider.clamp(Int(sliderValue.rounded()))
        if mood != value {
            mood = value
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 1), 10)
    }
}

// MARK: - LevelMeterView

/// Horizontal bar meter for mic level 0...1. Bars fill left to right and animate.
struct LevelMeterView: View {
    private static let barCount = 24
    private let level: Float

    init(level: Float) {
        self.level = level
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<LevelMeterView.barCount, id: \.self) { index in
                Capsule()
                    .fill(barColor(for: index).opacity(barOpacity(for: index)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int((displayLevel * 100).rounded())) percent")
    }

    /// Clamped and gently curved so quiet speech is still visible.
    private var displayLevel: Double {
        guard level.isFinite else { return 0 }
        let clamped = Double(min(max(level, 0), 1))
        return pow(clamped, 0.65)
    }

    private func barOpacity(for index: Int) -> Double {
        let filled = displayLevel * Double(LevelMeterView.barCount)
        let amount = min(max(filled - Double(index), 0), 1)
        return 0.18 + 0.82 * amount
    }

    private func barColor(for index: Int) -> Color {
        let position = Double(index) / Double(max(LevelMeterView.barCount - 1, 1))
        if position < 0.7 {
            return Color.accentColor
        }
        if position < 0.9 {
            return Color.orange
        }
        return Color.red
    }
}

// MARK: - RecordButton

/// Big round record button: an 84pt red circle. Shows a microphone when idle and a
/// rounded square (stop glyph) while recording.
struct RecordButton: View {
    private let isRecording: Bool
    private let action: () -> Void

    init(isRecording: Bool, action: @escaping () -> Void) {
        self.isRecording = isRecording
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red)
                    .shadow(color: Color.red.opacity(0.35), radius: 10, x: 0, y: 4)
                Circle()
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 3)
                if isRecording {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .frame(width: 84, height: 84)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.2), value: isRecording)
        }
        .buttonStyle(RecordButtonPressStyle())
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
        .accessibilityAddTraits(.isButton)
    }
}

private struct RecordButtonPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - SectionHeader

/// Section header text styled consistently across screens.
struct SectionHeader: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - SupportResourcesCard

/// Static, calm resources card shown when insights.needsSupportFlag is true.
struct SupportResourcesCard: View {
    init() {}

    private var resources: [(title: String, detail: String)] {
        TherapyLexicon.supportResources
    }

    var body: some View {
        CardView(title: "You deserve support", systemImage: "heart.fill") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Some of what came up in this session sounded really heavy. You don't have to carry it on your own. Reaching out, even in a small way, is a strong next step.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                if resources.isEmpty {
                    Text("If you might be in danger right now, please contact your local emergency number or someone you trust.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(0..<resources.count, id: \.self) { index in
                        resourceRow(at: index)
                    }
                }

                Text("This app can't respond in an emergency, and it isn't a substitute for your therapist or a crisis line.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resourceRow(at index: Int) -> some View {
        let resource = resources[index]
        return VStack(alignment: .leading, spacing: 4) {
            Text(resource.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            Text(resource.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isUnitedStatesRow(resource), let phoneURL = URL(string: "tel://988") {
                Link(destination: phoneURL) {
                    Label("Call or text 988", systemImage: "phone.fill")
                        .font(.subheadline.weight(.medium))
                }
                .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func isUnitedStatesRow(_ resource: (title: String, detail: String)) -> Bool {
        resource.title.contains("US") || resource.detail.contains("988")
    }
}

// MARK: - MoodScale

/// Mood 1...10 → emoji, short label and color helpers.
enum MoodScale {
    static func emoji(for mood: Int) -> String {
        switch clamp(mood) {
        case 1...2: return "😞"
        case 3...4: return "😔"
        case 5...6: return "😐"
        case 7...8: return "🙂"
        default: return "😄"
        }
    }

    static func label(for mood: Int) -> String {
        switch clamp(mood) {
        case 1...2: return "Very low"
        case 3...4: return "Low"
        case 5...6: return "Okay"
        case 7...8: return "Good"
        default: return "Great"
        }
    }

    static func color(for mood: Int) -> Color {
        switch clamp(mood) {
        case 1...2: return Color.red
        case 3...4: return Color.orange
        case 5...6: return Color.yellow
        case 7...8: return Color.green
        default: return Color.teal
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(max(value, 1), 10)
    }
}
