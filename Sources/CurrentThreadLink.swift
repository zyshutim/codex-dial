import AppKit
import ApplicationServices

// Called only on the bridge's serial queue, on an explicit read or preset action.
struct CurrentThreadLink {
    let id: String
    let window: AXUIElement
    let pid: pid_t

    static func focusedWindow(_ pid: pid_t) throws -> AXUIElement {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CodexBridge.Failure(message: "未找到当前 Codex 窗口。", code: "session_missing")
        }
        return value as! AXUIElement
    }

    func checkWindow() throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              CFEqual(try Self.focusedWindow(pid), window) else {
            throw CodexBridge.Failure(message: "当前窗口已改变，已停止切换。", code: "session_missing")
        }
    }

    static func capture() throws -> CurrentThreadLink {
        guard AXIsProcessTrusted() else {
            throw CodexBridge.Failure(message: "请允许 Codex Dial 的辅助功能权限，以获取当前会话链接。", code: "permission")
        }
        // Clicking the menu-bar panel can temporarily activate Dial.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: CodexBridge.bundleID).first {
            app.activate()
            let deadline = Date().addingTimeInterval(0.5)
            while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == CodexBridge.bundleID else {
            throw CodexBridge.Failure(message: "请回到目标 Codex 窗口后切换。", code: "session_missing")
        }
        let pid = app.processIdentifier
        let window = try focusedWindow(pid)
        let pasteboard = NSPasteboard.general
        let originalCount = pasteboard.changeCount
        // Materialize all available types, including images and file URLs.
        var originals: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw CodexBridge.Failure(message: "剪贴板内容暂时无法保存，已停止自动识别。", code: "session_missing")
                }
                copy.setData(data, forType: type)
            }
            originals.append(copy)
        }
        guard pasteboard.changeCount == originalCount else {
            throw CodexBridge.Failure(message: "剪贴板正在变化，请重试。", code: "session_missing")
        }
        let probe = CurrentThreadLink(id: "", window: window, pid: pid)
        try probe.checkWindow()
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 37, keyDown: false) else {
            throw CodexBridge.Failure(message: "无法调用 Codex 的复制会话链接命令。", code: "session_missing")
        }
        down.flags = [.maskCommand, .maskAlternate]
        up.flags = [.maskCommand, .maskAlternate]
        down.postToPid(pid); up.postToPid(pid)
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            if pasteboard.changeCount != originalCount {
                let receivedCount = pasteboard.changeCount
                let text = pasteboard.string(forType: .string) ?? ""
                guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "codex", url.host == "threads",
                      url.pathComponents.count == 2,
                      UUID(uuidString: url.lastPathComponent) != nil,
                      url.query == nil, url.fragment == nil else {
                    // An unrelated copy belongs to the user; never overwrite it.
                    throw CodexBridge.Failure(message: "未收到 Codex 会话链接。请确认「复制深层链接」快捷键为 ⌘⌥L。", code: "session_missing")
                }
                // Restore only if no newer clipboard owner has appeared.
                if pasteboard.changeCount == receivedCount {
                    pasteboard.clearContents()
                    if !originals.isEmpty { pasteboard.writeObjects(originals) }
                }
                try probe.checkWindow()
                return CurrentThreadLink(id: url.lastPathComponent.lowercased(), window: window, pid: pid)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw CodexBridge.Failure(message: "Codex 未返回会话链接。请确认当前已打开会话，且「复制深层链接」快捷键为 ⌘⌥L。", code: "session_missing")
    }
}
