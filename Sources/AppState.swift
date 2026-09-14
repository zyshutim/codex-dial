import AppKit
import SwiftUI
import ApplicationServices


enum HUDPhase: Equatable { case switching, success, failure }
struct HUDMessage: Equatable {
    var preset: Preset
    var phase: HUDPhase
    var detail: String
}

@MainActor final class AppState: ObservableObject {
    @Published var presets: [Preset] = Preset.emptySlots
    @Published var models: [ModelOption] = []
    @Published var reading: Reading = .waiting
    @Published var busy = false
    @Published var error: String?
    @Published var hotkeyFailures: [Int] = []
    @Published var hud: HUDMessage?
    @Published var showSettings = false
    @Published var trusted = true
    @Published var showConnection = false
    @Published var socketPath = "desktop"
    @Published var targetID = ""
    @Published var targets: [RPCTarget] = []
    @Published var connectionError: String?
    @Published var listing = false
    @Published var shortcutsArmed = true
    @Published var tripleTapEnabled = true
    private var revision = 0
    private var connectedSocketPath = "desktop"
    let preview: Bool
    let recorder = KeyRecorder()
    let hotkeys = HotkeyManager()
    private let bridge = CodexBridge()
    private let store: PresetStore
    private var timer: Timer?
    private var refreshing = false
    private var observation: NSObjectProtocol?
    private var loadFailed = false
    var onApply: (() -> Void)?
    var onEdit: ((Int) -> Void)?
    var onOpen: (() -> Void)?

    init(preview: Bool = false, store: PresetStore = .user) {
        self.preview = preview; self.store = store
        models = preview ? Catalog.preview : Catalog.load()
        if preview {
            presets[0].name = "轻快"; presets[0].selection = Selection(modelID: "gpt-5.6-luna", effort: .medium)
            presets[1].name = "日常 coding"; presets[1].selection = Selection(modelID: "gpt-5.6-sol", effort: .high)
            presets[2].name = "深入思考"; presets[2].selection = Selection(modelID: "gpt-6-astra", effort: .xhigh)
            reading = Reading(selection: presets[1].selection, message: "界面预览", detail: "演示数据 · 不连接 Codex")
            trusted = true
        } else {
            do { presets = try store.load() }
            catch { loadFailed = true; self.error = "保存的档位文件无法读取。原文件已保留，修复前不会覆盖。" }
            socketPath = "desktop"
            tripleTapEnabled = UserDefaults.standard.object(forKey: "optionTripleTap") as? Bool ?? true
        }
        bridge.onChange = { [weak self] in if self?.targetID.isEmpty == false { self?.refresh() } }
        hotkeys.onPress = { [weak self] id in
            Task { @MainActor in self?.apply(id) }
        }
    }
    func start() {
        guard !preview else { return }
        observation = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateHotkeys(); if self?.targetID.isEmpty == false { self?.refresh() } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: true) { [weak self] _ in
            Task { @MainActor in if self?.targetID.isEmpty == false { self?.refresh() } }
        }
        followWindow()
    }
    func stop() { bridge.stop(); timer?.invalidate(); hotkeys.unregister(); recorder.stop(); if let observation { NSWorkspace.shared.notificationCenter.removeObserver(observation) } }
    func model(_ selection: Selection?) -> ModelOption? { models.first { $0.id == selection?.modelID } }
    func label(_ selection: Selection?) -> String {
        guard let selection else { return "未设置" }
        return "\(model(selection)?.shortName ?? selection.modelID) · \(selection.effort.label)"
    }
    var statusTitle: String {
        if targetID.isEmpty && reading.message == "自动跟随已开启" { return "Dial · 自动跟随" }
        guard let selection = reading.selection else { return "Dial · \(trusted ? (reading.connected ? "档位未读取" : "待连接") : "待授权")" }
        return (targetID.isEmpty ? "" : "固定 · ") + label(selection)
    }
    func refresh() {
        guard !preview, !refreshing, !busy else { return }
        let expectedRevision = revision
        refreshing = true
        bridge.read(models: models) { [weak self] result in
            guard let self else { return }
            self.refreshing = false
            if !self.busy && self.revision == expectedRevision { self.reading = result }
        }
    }
    func reloadModels() { if !preview { models = Catalog.load() }; refresh() }
    func save(_ preset: Preset) -> Bool {
        guard !loadFailed else { return false }
        if let selection = preset.selection, let message = Validation.selection(selection, models: models) { error = message; return false }
        var next = presets; next[preset.id] = preset
        do { if !preview { try store.save(next) }; presets = next; error = nil; updateHotkeys(); return true }
        catch { self.error = "保存失败：\(error.localizedDescription)"; return false }
    }
    func saveShortcut(slot: Int) {
        guard let pending = recorder.pending else { return }
        if let message = Validation.chord(pending, slot: slot, presets: presets) { recorder.error = message; return }
        if !preview && !hotkeys.available(pending) { recorder.error = "这个组合被系统或其他应用占用。"; return }
        var preset = presets[slot]; preset.hotkey = pending
        if save(preset) { recorder.stop() } else { recorder.error = error }
    }
    func clearShortcut(_ slot: Int) { var p = presets[slot]; p.hotkey = nil; if save(p) { recorder.stop() } }
    func updateHotkeys() {
        guard !preview, shortcutsArmed, !showConnection, !showSettings, recorder.slot == nil, !busy,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == CodexBridge.bundleID else {
            hotkeys.unregister(); return
        }
        hotkeyFailures = hotkeys.register(presets, tripleTap: tripleTapEnabled)
    }
    var shortcutStatus: String {
        if !shortcutsArmed { return "快捷键已暂停" }
        if !hotkeyFailures.isEmpty { return "部分快捷键被占用" }
        if busy { return "正在切换档位" }
        if recorder.slot != nil { return "正在录入快捷键" }
        return tripleTapEnabled ? "⌥ + 数字连按三次 · 已启用" : "快捷键已启用 · 回到 Codex 即可使用"
    }
    func closePanel() {
        recorder.stop()
        showSettings = false
        showConnection = false
        updateHotkeys()
    }
    func setTripleTap(_ enabled: Bool) {
        recorder.stop(); tripleTapEnabled = enabled
        if !preview { UserDefaults.standard.set(enabled, forKey: "optionTripleTap") }
        updateHotkeys()
    }
    func beginRecording(_ id: Int) { hotkeys.unregister(); recorder.begin(id) }
    func apply(_ id: Int) {
        guard !busy, (0..<10).contains(id) else { return }
        let preset = presets[id]
        guard let selection = preset.selection else {
            onOpen?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.onEdit?(id) }
            return
        }
        if let message = Validation.selection(selection, models: models) {
            hud = HUDMessage(preset: preset, phase: .failure, detail: message); return
        }
        busy = true; hotkeys.unregister(); onApply?()
        hud = HUDMessage(preset: preset, phase: .switching, detail: "正在更新目标会话…")
        if preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self else { return }
                self.reading = Reading(selection: selection, message: "界面预览", detail: "演示数据 · 不连接 Codex")
                self.busy = false; self.hud = HUDMessage(preset: preset, phase: .success, detail: "预览切换 · 未改变 Codex")
            }
            return
        }
        bridge.apply(selection, models: models) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case .success(let value):
                self.reading = value
                self.hud = HUDMessage(preset: preset, phase: .success, detail: "已更新会话的后续轮次设置")
            case .failure(let failure):
                self.reading = Reading(selection: nil, message: "切换未完成", detail: failure.localizedDescription)
                self.hud = HUDMessage(preset: preset, phase: .failure, detail: failure.localizedDescription)
            }
            self.updateHotkeys()
        }
    }
    func followWindow() {
        guard !busy else { return }
        revision += 1; targetID = ""; shortcutsArmed = true
        bridge.configure(path: "desktop", threadID: "", title: "")
        updateHotkeys()
        reading = Reading(selection: nil, message: "自动跟随已开启", detail: "回到 Codex 按档位快捷键，将自动读取当前会话链接。")
    }
    func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func connectAndList() {
        guard !listing, !busy else { return }
        revision += 1; targets = []
        reading = Reading(selection: nil, message: "连接中", detail: "正在读取服务中的会话")
        socketPath = socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        bridge.configure(path: "desktop", threadID: targetID, title: targets.first(where: { $0.id == targetID })?.title ?? targetID)
        listing = true; connectionError = nil
        bridge.list { [weak self] result in
            guard let self else { return }; self.listing = false
            switch result {
            case .success(let targets):
                self.targets = targets
                self.connectedSocketPath = self.socketPath
                UserDefaults.standard.set(self.socketPath, forKey: "rpcSocketPath")
                self.connectionError = targets.isEmpty ? "服务已连接，但没有已加载的会话。" : nil
            case .failure(let error): self.connectionError = error.localizedDescription
            }
        }
    }
    func bindTarget(_ id: String) {
        guard !busy, let target = targets.first(where: { $0.id == id }) else { return }
        revision += 1; shortcutsArmed = true; targetID = id; updateHotkeys()
        reading = Reading(selection: nil, message: "已绑定 · \(target.title)", detail: "正在读取档位")
        bridge.configure(path: connectedSocketPath, threadID: id, title: target.title)
        refresh()
    }
}
