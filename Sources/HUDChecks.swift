import AppKit

enum HUDChecks {
    @MainActor static func run() async {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1; print("PASS: \(name)")
        }
        func label(_ glyphs: [ScrambleGlyph]) -> String { glyphs.map(\.text).joined() }
        let old = Selection(modelID: "gpt-5.6-sol", effort: .medium)
        let next = Selection(modelID: "gpt-6-astra", effort: .high)
        var preset = Preset.emptySlots[0]; preset.selection = next
        let modelName = Catalog.preview.first { $0.id == next.modelID }!.name
        let previousName = Catalog.preview.first { $0.id == old.modelID }!.name
        check(label(TextScramble.frame(from: "old", to: "new model", progress: 0)) == "old", "scramble starts with old text")
        check(label(TextScramble.frame(from: "old", to: "new model", progress: 1)) == "new model", "scramble ends with exact target")
        check(TextScramble.frame(from: "old", to: "new model", progress: 0.3).contains { $0.scrambled }, "middle frame contains changing glyphs")
        check(TextScramble.frame(from: "same", to: "same", progress: 0.3).allSatisfy { !$0.scrambled }, "unchanged text stays readable")
        let presentation = HUDPresentation()
        var hold: TimeInterval = 0
        presentation.onSettled = { _, duration in hold = duration }
        var message = HUDMessage(preset: preset, phase: .switching, detail: "", previous: old)
        presentation.receive(message, models: Catalog.preview, reduceMotion: false)
        check(label(presentation.model) == previousName && presentation.phase == .switching, "show verified previous model before success")
        message.phase = .success
        presentation.receive(message, models: Catalog.preview, reduceMotion: false)
        check(presentation.phase == .switching && hold == 0, "do not show check before text settles")
        try? await Task.sleep(nanoseconds: 800_000_000)
        check(label(presentation.model) == modelName && label(presentation.effort) == "High", "success lands on exact configuration")
        check(presentation.checkProgress == 1 && hold == 1.5, "full check then 1.5 second readable hold")
        var failed = HUDMessage(preset: preset, phase: .failure, detail: "timeout", previous: old)
        presentation.receive(failed, models: Catalog.preview, reduceMotion: false)
        check(presentation.phase == .failure && presentation.checkProgress == 0, "failure never shows a green check")
        check(label(presentation.model) == previousName, "failure keeps old configuration")
        failed.detail = "updated diagnostic"
        presentation.receive(failed, models: Catalog.preview, reduceMotion: false)
        check(presentation.detail == "updated diagnostic" && hold == 4, "failure detail can update without losing dismissal")
        var first = HUDMessage(preset: preset, phase: .success, detail: "", previous: old)
        presentation.receive(first, models: Catalog.preview, reduceMotion: false)
        let newer = HUDMessage(preset: preset, phase: .switching, detail: "", previous: old)
        presentation.receive(newer, models: Catalog.preview, reduceMotion: false)
        try? await Task.sleep(nanoseconds: 700_000_000)
        check(presentation.operationID == newer.id && presentation.phase == .switching, "new operation cancels old animation and completion")
        first.id = UUID()
        presentation.receive(first, models: Catalog.preview, reduceMotion: true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(presentation.phase == .success && presentation.checkProgress == 1, "reduced motion has no animated delay")
        presentation.dismiss()
        check(presentation.operationID == nil, "dismiss cancels presentation")
        print("\(count) HUD checks passed. No real Codex operation was performed.")
    }
}
