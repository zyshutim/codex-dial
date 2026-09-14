import AppKit
import Carbon

final class HotkeyManager {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var held = Set<Int>()
    private var tripleSlot: Int?
    private var tripleCount = 0
    private var tripleStarted: TimeInterval = 0
    var onPress: ((Int) -> Void)?
    init() {
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return noErr }
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(context).takeUnretainedValue()
            if key.signature == 0x43445844 { manager.handle(Int(key.id), released: GetEventKind(event) == UInt32(kEventHotKeyReleased)) }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    private func handle(_ id: Int, released: Bool) {
        if released { held.remove(id); return }
        guard held.insert(id).inserted else { return } // Holding a key is not three taps.
        guard id >= 100 else { onPress?(id); return }
        let slot = id - 100, now = ProcessInfo.processInfo.systemUptime
        if tripleSlot != slot || now - tripleStarted > 0.9 {
            tripleSlot = slot; tripleCount = 1; tripleStarted = now
        } else { tripleCount += 1 }
        if tripleCount == 3 {
            tripleCount = 0; tripleSlot = nil
            onPress?(slot)
        }
    }
    deinit { unregister(); if let handler { RemoveEventHandler(handler) } }
    func unregister() { refs.forEach { UnregisterEventHotKey($0) }; refs.removeAll(); held.removeAll(); tripleSlot = nil; tripleCount = 0 }
    @discardableResult func register(_ presets: [Preset], tripleTap: Bool = false) -> [Int] {
        unregister()
        var failed: [Int] = []
        for preset in presets {
            let chord = tripleTap ? KeyChord(code: KeyChord.digits[preset.id], modifiers: UInt32(optionKey), key: preset.digit) : preset.hotkey
            guard let key = chord else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: 0x43445844, id: UInt32(preset.id + (tripleTap ? 100 : 0))), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.append(preset.id) }
        }
        return failed
    }
    // Probe while recorder owns the focus. The temporary key is released immediately.
    func available(_ key: KeyChord) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, key.modifiers, EventHotKeyID(signature: 0x43445844, id: 99), GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }
}

@MainActor final class KeyRecorder: ObservableObject {
    @Published var slot: Int?
    @Published var pending: KeyChord?
    @Published var symbols = ""
    @Published var error: String?
    private var monitor: Any?
    func begin(_ id: Int) {
        stop()
        slot = id; pending = nil; symbols = ""; error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.slot != nil else { return event }
            if event.type == .flagsChanged {
                if self.pending == nil { self.symbols = KeyChord.symbols(KeyChord.carbonModifiers(event.modifierFlags)) }
                return event
            }
            if event.keyCode == 53 { self.stop(); return nil }
            if event.isARepeat { return nil }
            self.pending = KeyChord.from(event); self.symbols = ""; self.error = nil
            return nil
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; slot = nil; pending = nil; symbols = ""; error = nil
    }
}
