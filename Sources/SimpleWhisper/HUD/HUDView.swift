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
    /// Shows the round "run as command" button (recording only).
    var showsCommandButton = false
    /// When false only the animation (and the command button) is shown, no status text.
    var showsText = true
    var theme: HUDTheme = .freshGreen
    /// Incremented on every show() to replay the appear animation.
    var appearance: Int = 0
    /// Incremented when the HUD is about to hide, to play the mirrored disappear animation.
    var dismissal: Int = 0
    /// Success folds away to the right; cancellation folds back to the left.
    var dismissReversed = false
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
    var onCommand: () -> Void = {}
    /// Transparent margin so the ripple can extend beyond the capsule.
    static let outerPadding: CGFloat = 14
    @State private var dropScale: CGFloat = 0.4
    @State private var dropOpacity: Double = 0
    @State private var ripple: CGFloat = 0
    /// Leading while appearing (unfolds to the right), trailing while disappearing (folds away to the right).
    @State private var anchor: UnitPoint = .leading

    static let freshGreen = Color(red: 0.24, green: 0.86, blue: 0.52)
    static let ink = Color(red: 0.03, green: 0.18, blue: 0.10)

    var body: some View {
        HStack(spacing: 10) {
            indicator
                .frame(width: 34, height: 18)
            let showsStatus = model.showsText || model.stage == .message
            if showsStatus {
                Text(model.text)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            // The prompt/detail line is always shown, even in animation-only mode.
            if let detail = model.detail, !detail.isEmpty {
                Text(showsStatus ? "· \(detail)" : detail)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .opacity(0.8)
                    .lineLimit(1)
            }
            if showsStatus || !(model.detail ?? "").isEmpty {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.7)
            }
            if model.showsCommandButton && model.stage == .recording {
                Button(action: onCommand) {
                    ZStack {
                        Circle().fill(model.theme.ink)
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(model.theme.background)
                            .offset(x: 0.5)
                    }
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Run as command on the selected text")
                .padding(.leading, 2)
            }
        }
        .foregroundStyle(model.theme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Capsule().fill(model.theme.background))
        .overlay {
            if model.stage == .transcribing || model.stage == .processing {
                RainbowBorder()
            } else {
                Capsule().strokeBorder(model.theme.border, lineWidth: 1)
            }
        }
        .contentShape(Capsule())
        .onTapGesture(perform: onTap)
        .fixedSize()
        // Smooth width changes when the status text / prompt / stage changes.
        .animation(.easeInOut(duration: 0.25), value: layoutKey)
        // The capsule unfolds from its left edge towards the right, like a drop spreading sideways.
        .scaleEffect(x: dropScale, y: 0.85 + 0.15 * dropScale, anchor: anchor)
        .opacity(dropOpacity)
        .background {
            // Ripple rings following the same left-to-right spread.
            ZStack {
                Capsule().stroke(model.theme.background.opacity(0.55), lineWidth: 2)
                    .scaleEffect(x: 1 + ripple * 0.35, y: 1 + ripple * 0.55, anchor: anchor)
                    .opacity(ripple == 0 ? 0 : (1 - ripple) * 0.8)
                Capsule().stroke(model.theme.background.opacity(0.35), lineWidth: 1.5)
                    .scaleEffect(x: 1 + ripple * 0.18, y: 1 + ripple * 0.3, anchor: anchor)
                    .opacity(ripple == 0 ? 0 : (1 - ripple) * 0.6)
            }
            .allowsHitTesting(false)
        }
        .padding(Self.outerPadding)
        .onAppear(perform: playDropAnimation)
        .onChange(of: model.appearance) { _, _ in playDropAnimation() }
        .onChange(of: model.dismissal) { _, _ in playDismissAnimation() }
    }

    /// Mirror of the appear animation: the capsule folds towards its right edge and a ripple runs the same way.
    /// Anything that changes the capsule's size.
    private var layoutKey: String {
        "\(model.text)|\(model.detail ?? "")|\(model.stage)|\(model.showsCommandButton)|\(model.showsText)"
    }

    private func playDismissAnimation() {
        anchor = model.dismissReversed ? .leading : .trailing
        ripple = 0
        withAnimation(.easeIn(duration: 0.28)) {
            dropScale = 0.06
        }
        withAnimation(.easeIn(duration: 0.22).delay(0.06)) {
            dropOpacity = 0
        }
        withAnimation(.easeOut(duration: 0.45)) {
            ripple = 1
        }
    }

    private func playDropAnimation() {
        anchor = .leading
        dropScale = 0.08
        dropOpacity = 0
        ripple = 0
        withAnimation(.interpolatingSpring(mass: 0.5, stiffness: 170, damping: 11, initialVelocity: 8)) {
            dropScale = 1
        }
        withAnimation(.easeOut(duration: 0.18)) {
            dropOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.75).delay(0.05)) {
            ripple = 1
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.stage {
        case .recording:
            RecordingBars(levels: model.levels, color: model.theme.recordingBars)
        case .transcribing:
            WaveBars(color: model.theme.ink)
        case .processing:
            SparkleIndicator(color: model.theme.ink)
        case .message:
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
        }
    }
}

/// Microphone level bars, newest on the right, like system dictation.
private struct RecordingBars: View {
    var levels: [Double]
    var color: Color

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let emphasis = 0.6 + 0.4 * Double(index + 1) / Double(levels.count)
                Capsule()
                    .fill(color.opacity(0.9))
                    .frame(width: 2.5, height: max(3, 3 + level * emphasis * 15))
            }
        }
        .animation(.easeOut(duration: 0.09), value: levels)
        .frame(height: 18)
    }
}

/// Continuous wave animation while the speech model runs.
private struct WaveBars: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<7, id: \.self) { index in
                    let phase = time * 4.5 - Double(index) * 0.55
                    let height = 4 + (sin(phase) + 1) / 2 * 12
                    Capsule()
                        .fill(color.opacity(0.85))
                        .frame(width: 2.5, height: height)
                }
            }
        }
        .frame(height: 18)
    }
}

/// Pulsing sparkles while Claude / Apple Intelligence works on the prompt.
private struct SparkleIndicator: View {
    var color: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.35), lineWidth: 1.5)
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


/// Slowly rotating multi-colour ring shown while the speech model or the AI is working.
private struct RainbowBorder: View {
    private static let colors: [Color] = [
        Color(red: 1.00, green: 0.35, blue: 0.35), Color(red: 1.00, green: 0.70, blue: 0.20),
        Color(red: 0.55, green: 0.90, blue: 0.35), Color(red: 0.25, green: 0.80, blue: 0.95),
        Color(red: 0.45, green: 0.45, blue: 1.00), Color(red: 0.90, green: 0.40, blue: 0.95),
        Color(red: 1.00, green: 0.35, blue: 0.35),
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let angle = Angle.degrees((seconds * 180).truncatingRemainder(dividingBy: 360))   // one lap every 2 s
            let gradient = AngularGradient(colors: Self.colors, center: .center, angle: angle)
            ZStack {
                Capsule()
                    .strokeBorder(gradient, lineWidth: 2.5)
                    .blur(radius: 3)
                    .opacity(0.8)
                Capsule()
                    .strokeBorder(gradient, lineWidth: 1.8)
            }
        }
        .allowsHitTesting(false)
    }
}
