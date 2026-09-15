import AppKit
import SwiftUI
import Combine

@main struct CodexDialMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { SelfTests.run(); return }
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--rpc-self-test" {
            RPCSelfTest.run(path: CommandLine.arguments[2], threadID: CommandLine.arguments[3]); return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var hudPanel: HUDPanel?
    private var previewWindow: NSWindow?
    private var hideWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()
    private var state: AppState!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let preview = CommandLine.arguments.contains("--preview") || CommandLine.arguments.contains("--render")
        state = AppState(preview: preview)
        NSApp.setActivationPolicy(preview ? .regular : .accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "dial.medium", accessibilityDescription: "Codex Dial")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self; button.action = #selector(togglePopover)
        }
        popover.contentViewController = NSHostingController(rootView: RootView(state: state))
        popover.contentSize = NSSize(width: 420, height: 730)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        state.onApply = { [weak self] in self?.popover.performClose(nil) }
        state.onOpen = { [weak self] in self?.showPopover() }
        state.$reading.combineLatest(state.$trusted).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }.store(in: &subscriptions)
        state.$hud.compactMap { $0 }.sink { [weak self] message in self?.presentHUD(message) }.store(in: &subscriptions)
        state.$showSettings.sink { [weak self] _ in DispatchQueue.main.async { self?.state.updateHotkeys() } }.store(in: &subscriptions)
        updateStatus(); state.start()
        if CommandLine.arguments.contains("--render") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.renderArtifacts(); NSApp.terminate(nil) }
        } else if preview {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 730), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Codex Dial · 界面预览"
            window.contentView = NSHostingView(rootView: RootView(state: state))
            window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window; NSApp.activate(ignoringOtherApps: true)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showPopover() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { state?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { state?.preview == true }
    private func updateStatus() {
        item.button?.title = " " + state.statusTitle
        item.button?.toolTip = state.reading.detail
        item.button?.setAccessibilityLabel("Codex Dial，\(state.statusTitle)")
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = item.button else { return }
        hudPanel?.orderOut(nil); hideWork?.cancel()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }
    func popoverDidClose(_ notification: Notification) { state.closePanel() }
    private func presentHUD(_ message: HUDMessage) {
        hideWork?.cancel()
        let size = NSSize(width: 265, height: message.phase == .failure ? 142 : 112)
        let panel = hudPanel ?? HUDPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .statusBar
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: SwitchHUD(message: message, model: state.model(message.preset.selection)))
        let anchor = item.button.flatMap { button -> NSRect? in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor?.origin ?? NSEvent.mouseLocation) }) ?? NSScreen.main!
        let bounds = screen.visibleFrame
        let x = min(max((anchor?.midX ?? bounds.maxX - size.width / 2) - size.width / 2, bounds.minX + 12), bounds.maxX - size.width - 12)
        let y = min(anchor?.minY ?? bounds.maxY, bounds.maxY) - size.height - 12
        panel.setFrame(NSRect(x: x, y: max(bounds.minY + 12, y), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless(); hudPanel = panel
        if message.phase != .switching {
            let work = DispatchWorkItem { [weak panel] in panel?.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (message.phase == .failure ? 4 : 0.75), execute: work)
        }
    }
    private func renderArtifacts() {
        guard let index = CommandLine.arguments.firstIndex(of: "--render"), index + 1 < CommandLine.arguments.count else { return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try render(RootView(state: state), size: NSSize(width: 420, height: 730), to: directory.appendingPathComponent("01-presets.png"))
            state.showSettings = true
            try render(ShortcutSettings(state: state, recorder: state.recorder).frame(width: 420, height: 730).background(.regularMaterial), size: NSSize(width: 420, height: 730), to: directory.appendingPathComponent("02-shortcuts.png"))
            state.setTripleTap(false)
            try render(ShortcutSettings(state: state, recorder: state.recorder).frame(width: 420, height: 730).background(.regularMaterial), size: NSSize(width: 420, height: 730), to: directory.appendingPathComponent("05-custom-shortcuts.png"))
            state.beginRecording(0)
            state.recorder.pending = KeyChord.standard(0)
            try render(ShortcutSettings(state: state, recorder: state.recorder).frame(width: 420, height: 730).background(.regularMaterial), size: NSSize(width: 420, height: 730), to: directory.appendingPathComponent("06-recording-dark.png"), dark: true)
            state.recorder.stop()
            try render(PresetEditor(state: state, preset: state.presets[2], dismiss: {}), size: NSSize(width: 370, height: 535), to: directory.appendingPathComponent("03-editor.png"))
            let message = HUDMessage(preset: state.presets[2], phase: .success, detail: "预览切换 · 未改变 Codex")
            try render(SwitchHUD(message: message, model: state.model(message.preset.selection)), size: NSSize(width: 265, height: 112), to: directory.appendingPathComponent("04-switch.png"))
            state.showSettings = false
            state.reading = CodexBridge.failureReading(CodexBridge.Failure(message: "Codex 设置接口已变化，无法确认参数兼容，尚未更改会话。", code: "incompatible"))
            try render(RootView(state: state), size: NSSize(width: 420, height: 730), to: directory.appendingPathComponent("07-error-dark.png"), dark: true)
            print("Rendered seven UI previews to \(directory.path)")
        } catch { fputs("Render failed: \(error)\n", stderr) }
    }
    private func render<V: View>(_ view: V, size: NSSize, to url: URL, dark: Bool = false) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
