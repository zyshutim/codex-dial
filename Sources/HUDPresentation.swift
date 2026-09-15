import AppKit
import SwiftUI

enum HUDTiming {
    static let oldValueHold = 0.18
    static let scramble = 0.28
    static let check = 0.18
    static let successHold = 1.5
    static let failureHold = 4.0
}

struct ScrambleGlyph: Equatable {
    let text: String
    let scrambled: Bool
}

enum TextScramble {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/#%+_?")
    static func frame(from: String, to: String, progress: Double) -> [ScrambleGlyph] {
        if progress <= 0 { return from.map { ScrambleGlyph(text: String($0), scrambled: false) } }
        if progress >= 1 { return to.map { ScrambleGlyph(text: String($0), scrambled: false) } }
        let old = Array(from), new = Array(to), count = max(old.count, new.count)
        return (0..<count).map { index in
            let a: Character = index < old.count ? old[index] : " "
            let b: Character = index < new.count ? new[index] : " "
            let offset = Double(index) / Double(max(1, count - 1))
            let start = offset * 0.18
            let finish = 0.4 + offset * 0.6
            if a == b || progress >= finish { return ScrambleGlyph(text: String(b), scrambled: false) }
            if progress < start { return ScrambleGlyph(text: String(a), scrambled: false) }
            let noise = (index * 17 + Int(progress * 24) * 13) % alphabet.count
            return ScrambleGlyph(text: String(alphabet[noise]), scrambled: true)
        }
    }
}

// One presentation survives all phases of an operation. No timers run when hidden.
@MainActor final class HUDPresentation: ObservableObject {
    static let size = NSSize(width: 252, height: 180)
    @Published var digit = "1"
    @Published var model: [ScrambleGlyph] = []
    @Published var effort: [ScrambleGlyph] = []
    @Published var phase: HUDPhase = .switching
    @Published var detail = ""
    @Published var checkProgress: CGFloat = 0
    @Published var sweepProgress: Double = 0
    @Published var accessibleValue = "读取当前档位"
    private(set) var operationID: UUID?
    private var oldVisibleAt: TimeInterval?
    private var task: Task<Void, Never>?
    private var terminalReceived = false
    var onSettled: ((UUID, TimeInterval) -> Void)?

    func dismiss() {
        task?.cancel(); task = nil; operationID = nil
        sweepProgress = 0
    }

    private func titles(_ selection: Selection?, models: [ModelOption]) -> (String, String) {
        guard let selection else { return ("读取当前档位", "—") }
        return (models.first { $0.id == selection.modelID }?.name ?? selection.modelID, selection.effort.label)
    }

    private func text(_ modelText: String, _ effortText: String) {
        model = TextScramble.frame(from: modelText, to: modelText, progress: 1)
        effort = TextScramble.frame(from: effortText, to: effortText, progress: 1)
        accessibleValue = modelText + "，" + effortText
    }

    func receive(_ message: HUDMessage, models: [ModelOption], reduceMotion: Bool) {
        if operationID != message.id {
            dismiss(); operationID = message.id; oldVisibleAt = nil; terminalReceived = false
            digit = message.preset.digit; phase = .switching; checkProgress = 0
            let old = titles(message.previous, models: models)
            text(old.0, old.1)
        }
        detail = message.detail
        if message.previous != nil && oldVisibleAt == nil {
            let old = titles(message.previous, models: models)
            text(old.0, old.1)
            oldVisibleAt = ProcessInfo.processInfo.systemUptime
        }
        guard message.phase != .switching, !terminalReceived else { return }
        terminalReceived = true
        if message.phase == .failure {
            phase = .failure
            if message.previous == nil { text("未读取到当前档位", "—") }
            onSettled?(message.id, HUDTiming.failureHold)
            return
        }
        let target = titles(message.preset.selection, models: models)
        let old = titles(message.previous, models: models)
        task = Task { [weak self] in
            guard let self else { return }
            if !reduceMotion {
                let visibleFor = ProcessInfo.processInfo.systemUptime - (self.oldVisibleAt ?? 0)
                let hold = max(0, HUDTiming.oldValueHold - visibleFor)
                if !(await self.pause(hold)) { return }
                if old != target {
                    let start = ProcessInfo.processInfo.systemUptime
                    while true {
                        guard !Task.isCancelled, self.operationID == message.id else { return }
                        let progress = min(1, (ProcessInfo.processInfo.systemUptime - start) / HUDTiming.scramble)
                        self.sweepProgress = progress
                        self.model = TextScramble.frame(from: old.0, to: target.0, progress: progress)
                        self.effort = TextScramble.frame(from: old.1, to: target.1, progress: progress)
                        if progress >= 1 { break }
                        if !(await self.pause(1.0 / 30)) { return }
                    }
                }
            }
            guard !Task.isCancelled, self.operationID == message.id else { return }
            self.text(target.0, target.1)
            self.phase = .success
            if reduceMotion { self.checkProgress = 1 }
            else {
                withAnimation(.timingCurve(0.215, 0.61, 0.355, 1, duration: HUDTiming.check)) { self.checkProgress = 1 }
                if !(await self.pause(HUDTiming.check)) { return }
            }
            guard self.operationID == message.id else { return }
            self.onSettled?(message.id, HUDTiming.successHold)
        }
    }

    private func pause(_ seconds: Double) async -> Bool {
        do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)); return !Task.isCancelled }
        catch { return false }
    }

    // Deterministic frames for visual previews; this never reaches the Codex bridge.
    func previewFrame(from: Selection, to: Selection, preset: Preset, elapsed: Double, models: [ModelOption]) {
        dismiss(); digit = preset.digit
        let old = titles(from, models: models), next = titles(to, models: models)
        let progress = (elapsed - HUDTiming.oldValueHold) / HUDTiming.scramble
        sweepProgress = min(1, max(0, progress))
        model = TextScramble.frame(from: old.0, to: next.0, progress: progress)
        effort = TextScramble.frame(from: old.1, to: next.1, progress: progress)
        phase = progress >= 1 ? .success : .switching
        checkProgress = min(1, max(0, (elapsed - HUDTiming.oldValueHold - HUDTiming.scramble) / HUDTiming.check))
        accessibleValue = next.0 + "，" + next.1
    }
}

// Draw only during the existing text transition; no separate timer or idle loop.
private struct SweepBackground: View {
    let progress: Double
    var body: some View {
        Canvas { context, size in
            guard progress > 0, progress < 1 else { return }
            let center = -60 + (size.width + 120) * progress
            let envelope = sin(progress * .pi)
            let tint = DialStyle.accent
            let glow = Path(CGRect(origin: .zero, size: size))
            context.fill(glow, with: .linearGradient(
                Gradient(colors: [.clear, tint.opacity(0.13 * envelope), .clear]),
                startPoint: CGPoint(x: center - 85, y: 0),
                endPoint: CGPoint(x: center + 85, y: 0)))
            let symbols = Array(".:+*/01")
            for row in 0..<10 {
                for column in 0..<18 {
                    guard (row * 13 + column * 7) % 5 == 0 else { continue }
                    let x = CGFloat(column) * 15 + 7
                    let y = CGFloat(row) * 18 + 9
                    let proximity = max(0, 1 - abs(x - center) / 65)
                    // Keep the model and effort area quiet; texture lives at the edges.
                    let quiet = x > 28 && x < size.width - 28 && y > 45 && y < 118
                    let opacity = proximity * envelope * (quiet ? 0.05 : 0.25)
                    let index = (row * 3 + column + Int(progress * 12)) % symbols.count
                    context.draw(Text(String(symbols[index]))
                        .font(.system(size: 9, weight: .regular, design: .monospaced))
                        .foregroundColor(tint.opacity(opacity)), at: CGPoint(x: x, y: y))
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct SuccessCheck: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.16, y: rect.height * 0.52))
            path.addLine(to: CGPoint(x: rect.width * 0.40, y: rect.height * 0.76))
            path.addLine(to: CGPoint(x: rect.width * 0.85, y: rect.height * 0.24))
        }
    }
}

struct SwitchHUD: View {
    @ObservedObject var presentation: HUDPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var successColor: Color { Color(nsColor: .systemGreen) }
    private func line(_ glyphs: [ScrambleGlyph], size: CGFloat, secondary: Bool = false) -> some View {
        glyphs.reduce(Text("")) { result, glyph in
            result + Text(glyph.text).foregroundColor(glyph.scrambled ? DialStyle.accent : secondary ? .secondary : .primary)
        }.font(.system(size: size, weight: .medium, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.65).frame(maxWidth: .infinity)
    }
    var body: some View {
        VStack(spacing: 0) {
            Text("档位 \(presentation.digit)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.bottom, 16)
            line(presentation.model, size: 20).frame(height: 26)
            line(presentation.effort, size: 12, secondary: true).frame(height: 20).padding(.top, 2)
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if presentation.phase == .success {
                    SuccessCheck().trim(from: 0, to: presentation.checkProgress)
                        .stroke(successColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .frame(width: 17, height: 17)
                    Text("已切换").foregroundStyle(successColor)
                } else if presentation.phase == .failure {
                    Image(systemName: "xmark").foregroundStyle(Color(nsColor: .systemRed))
                    Text("切换未确认").foregroundStyle(Color(nsColor: .systemRed))
                } else {
                    if !reduceMotion { ProgressView().controlSize(.mini) }
                    Text("切换中").foregroundStyle(.secondary)
                }
            }.font(.system(size: 11, weight: .medium)).frame(height: 20)
            if presentation.phase == .failure {
                Text(presentation.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                    .help(presentation.detail).padding(.top, 5)
            }
        }.padding(.horizontal, 20).padding(.vertical, 20)
            .frame(width: HUDPresentation.size.width, height: HUDPresentation.size.height)
            .background {
                if !reduceMotion {
                    SweepBackground(progress: presentation.sweepProgress)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(DialStyle.border, lineWidth: 0.5))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("档位 \(presentation.digit)，\(presentation.accessibleValue)，\(presentation.phase == .success ? "已切换" : presentation.phase == .failure ? presentation.detail : "切换中")")
    }
}
