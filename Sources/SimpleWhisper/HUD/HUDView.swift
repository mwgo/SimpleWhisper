import SwiftUI
import Observation

enum HUDStage: Equatable {
    /// Microphone is live; bars follow the input level.
    case recording
    /// Speech model is running.
    case transcribing
    /// AI prompt (Claude / Apple Intelligence) is running.
    case processing
    /// Static message (success, error, cancelled).
    case message
}

@Observable
final class HUDModel {
    var text: String = ""
    var detail: String? = nil
    var stage: HUDStage = .message
    /// Recent microphone levels (0…1), newest last. Drives the recording bars.
    var levels: [Double] = Array(repeating: 0, count: HUDModel.barCount)

    static let barCount = 9

    func push(level: Double) {
        levels.removeFirst()
        levels.append(min(max(level, 0), 1))
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: Self.barCount)
    }
}

struct HUDView: View {
    var model: HUDModel
    var onTap: () -> Void

    static let freshGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let ink = Color(red: 0.03, green: 0.18, blue: 0.10)

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 34, height: 18)
            Text(model.text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
            if let detail = model.detail, !detail.isEmpty {
                Text("· \(detail)")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .opacity(0.8)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .opacity(0.7)
        }
        .foregroundStyle(Self.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(Self.freshGreen))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .fixedSize()
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.stage {
        case .recording:
            RecordingBars(levels: model.levels)
        case .transcribing:
            WaveBars()
        case .processing:
            SparkleIndicator()
        case .message:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
        }
    }
}

/// Microphone level bars, newest on the right, like system dictation.
private struct RecordingBars: View {
    var levels: [Double]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let emphasis = 0.6 + 0.4 * Double(index + 1) / Double(levels.count)
                Capsule()
                    .fill(Color(red: 0.75, green: 0.08, blue: 0.10).opacity(0.85))
                    .frame(width: 2.5, height: max(3, 3 + level * emphasis * 15))
            }
        }
        .animation(.easeOut(duration: 0.09), value: levels)
        .frame(height: 18)
    }
}

/// Continuous wave animation while the speech model runs.
private struct WaveBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<7, id: \.self) { index in
                    let phase = time * 4.5 - Double(index) * 0.55
                    let height = 4 + (sin(phase) + 1) / 2 * 12
                    Capsule()
                        .fill(HUDView.ink.opacity(0.85))
                        .frame(width: 2.5, height: height)
                }
            }
        }
        .frame(height: 18)
    }
}

/// Pulsing sparkles while Claude / Apple Intelligence works on the prompt.
private struct SparkleIndicator: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(HUDView.ink.opacity(0.35), lineWidth: 1.5)
                .frame(width: 16, height: 16)
                .scaleEffect(animate ? 1.35 : 0.9)
                .opacity(animate ? 0 : 0.8)
                .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: animate)
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        }
        .onAppear { animate = true }
    }
}
