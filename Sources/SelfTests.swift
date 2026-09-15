import Foundation
import Carbon
import AppKit

enum SelfTests {
    @MainActor static func run() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            guard value() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            count += 1; print("PASS: \(name)")
        }
        var slots = Preset.emptySlots
        check(slots.map(\.digit).joined() == "1234567890", "ten slots ordered 1–0")
        check(Set(slots.compactMap { $0.hotkey?.code }).count == 10, "ten distinct physical digit keys")
        let appState = AppState(preview: true)
        let savedKeys = appState.presets.map(\.hotkey)
        appState.beginRecording(0)
        check(appState.recorder.slot == nil, "default mode cannot start custom recording")
        appState.setTripleTap(false)
        appState.beginRecording(0)
        check(appState.recorder.slot == 0, "custom mode permits recording")
        appState.recorder.pending = KeyChord.standard(2)
        appState.setTripleTap(true)
        check(appState.recorder.slot == nil && appState.recorder.pending == nil, "mode switch cancels unsaved recording")
        appState.clearShortcut(0)
        check(appState.presets.map(\.hotkey) == savedKeys, "inactive custom mode preserves saved bindings")
        appState.setTripleTap(false)
        check(appState.presets.map(\.hotkey) == savedKeys, "returning to custom restores saved bindings")
        let connectionError = CodexBridge.failureReading(CodexBridge.Failure(message: "test", code: "timeout"))
        check(connectionError.message == "Codex 响应超时", "timeout is distinguished from missing session")
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "!", charactersIgnoringModifiers: "!", isARepeat: false, keyCode: 18) {
            check(KeyChord.from(event).display == "⌃⇧1", "Shift+1 displays physical digit rather than punctuation")
        } else { check(false, "key event fixture created") }
        check(Validation.chord(.standard(0), slot: 0, presets: slots) == nil, "same slot can retain its shortcut")
        check(Validation.chord(.standard(0), slot: 1, presets: slots) != nil, "duplicate shortcut rejected")
        check(Validation.chord(KeyChord(code: 18, modifiers: UInt32(cmdKey), key: "1"), slot: 0, presets: slots) != nil, "Codex Cmd+1 conflict rejected")
        check(Validation.chord(KeyChord(code: 18, modifiers: 0, key: "1"), slot: 0, presets: slots) != nil, "unmodified key rejected")
        check(Validation.chord(KeyChord(code: 18, modifiers: UInt32(cmdKey | optionKey), key: "1"), slot: 0, presets: slots) != nil, "recent-chat shortcut rejected")
        check(Validation.selection(Selection(modelID: "gpt-5.6-luna", effort: .ultra), models: Catalog.preview) != nil, "unsupported effort rejected")
        check(Validation.selection(Selection(modelID: "missing", effort: .high), models: Catalog.preview) != nil, "unknown model rejected")
        check(ControlParser.effort(in: "6 Astra Extra High") == .xhigh, "Extra High does not become High")
        check(ControlParser.effort(in: "6 Astra Ultra") == .ultra, "Ultra recognized")
        check(ControlParser.effort(in: "6 Astra 高") == .high, "Chinese effort recognized")
        check(ControlParser.effort(in: "highlight") == nil, "partial English word is not an effort")
        check(ControlParser.uniqueEffort(in: "6 Astra Extra High") == .xhigh, "single current depth distinguished from options")
        check(ControlParser.uniqueEffort(in: "Light Medium High Extra High Max Ultra") == nil, "entire menu cannot masquerade as current depth")
        check(ControlParser.model(in: "5.6 Sol High", models: Catalog.preview)?.id == "gpt-5.6-sol", "Codex short model label parsed")
        check(ControlParser.model(in: "Select model", models: Catalog.preview) == nil, "placeholder is not a selected model")
        slots[0].selection = Selection(modelID: "gpt-6-astra", effort: .high)
        slots[0].name = "中文预设"
        do {
            let encoded = try JSONEncoder().encode(slots)
            let decoded = try JSONDecoder().decode([Preset].self, from: encoded)
            check(decoded == slots, "presets, Unicode names and shortcuts round-trip")
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodexDial-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = PresetStore(url: folder.appendingPathComponent("presets.json"))
            try store.save(slots)
            let loaded = try store.load()
            check(loaded == slots, "atomic file persistence round-trip")
            try Data("broken".utf8).write(to: store.url)
            do { _ = try store.load(); check(false, "corrupt file must throw") } catch { check(true, "corrupt file preserved, not overwritten") }
            let bytes = try Data(contentsOf: store.url)
            check(String(data: bytes, encoding: .utf8) == "broken", "corrupt file bytes retained")
        } catch { fputs("FAIL: persistence \(error)\n", stderr); exit(1) }
        print("\(count) checks passed. No Codex UI, permissions, or user presets were changed.")
    }
}
