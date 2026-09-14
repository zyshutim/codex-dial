import AppKit
import ApplicationServices

struct DesktopFocus: Equatable {
    let id: String
    let title: String
    let candidateTitles: [String]
    static func capture() throws -> DesktopFocus {
        guard AXIsProcessTrusted() else { throw CodexBridge.Failure(message: "自动跟随需要辅助功能权限，请在系统设置中允许 Codex Dial。") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CodexBridge.bundleID)
        guard let app = apps.first(where: { $0.isActive }) ?? apps.first else { throw CodexBridge.Failure(message: "请先打开 Codex。") }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard front == CodexBridge.bundleID || front == Bundle.main.bundleIdentifier else { throw CodexBridge.Failure(message: "切回 Codex 后读取当前窗口。") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        _ = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        func value(_ node: AXUIElement, _ attr: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(node, attr as CFString, &result) == .success ? result : nil
        }
        func element(_ node: AXUIElement, _ attr: String) -> AXUIElement? {
            guard let raw = value(node, attr), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return (raw as! AXUIElement)
        }
        func text(_ node: AXUIElement, _ attr: String) -> String {
            let raw = value(node, attr)
            return (raw as? URL)?.absoluteString ?? raw as? String ?? ""
        }
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute) else { throw CodexBridge.Failure(message: "未找到 Codex 当前窗口。") }
        _ = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let title = text(window, kAXTitleAttribute)
        let pattern = "(?:local|thread|threads|conversation|conversations)/([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?:[/?#]|$)"
        let regex = try NSRegularExpression(pattern: pattern)
        func routeID(_ node: AXUIElement) -> String? {
            for attr in ["AXURL", kAXDocumentAttribute] {
                let string = text(node, attr).removingPercentEncoding ?? text(node, attr)
                if let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)), let range = Range(match.range(at: 1), in: string) { return String(string[range]).lowercased() }
            }
            return nil
        }
        // A focused composer/panel takes precedence over the main page route.
        var focus = element(root, kAXFocusedUIElementAttribute)
        for _ in 0..<45 {
            guard let node = focus else { break }
            if let id = routeID(node) { return DesktopFocus(id: id, title: title, candidateTitles: []) }
            if CFEqual(node, window) { break }
            focus = element(node, kAXParentAttribute)
        }
        var pending = [window], cursor = 0, visited = 0, pageIDs = Set<String>(), currentIDs = Set<String>(), titles = Set<String>()
        let deadline = Date().addingTimeInterval(2)
        while cursor < pending.count, visited < 2400, Date() < deadline {
            let node = pending[cursor]
            cursor += 1; visited += 1
            let role = text(node, kAXRoleAttribute)
            let current = text(node, "AXARIACurrent").lowercased()
            let isCurrent = ["page", "true"].contains(current)
            if role == "AXWindow" || role == "AXWebArea", let id = routeID(node) { pageIDs.insert(id) }
            if isCurrent {
                if let id = routeID(node) { currentIDs.insert(id) }
                var labels = [node], count = 0
                labels.append(contentsOf: value(node, "AXTitleUIElements") as? [AXUIElement] ?? [])
                while let item = labels.popLast(), count < 40 {
                    count += 1
                    for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                        let label = text(item, attr).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !label.isEmpty && label.count <= 256 { titles.insert(label) }
                    }
                    if let id = routeID(item) { currentIDs.insert(id) }
                    if !["AXTextArea", "AXTextField"].contains(text(item, kAXRoleAttribute)) {
                        labels.append(contentsOf: value(item, kAXChildrenAttribute) as? [AXUIElement] ?? [])
                    }
                }
            }
            if !["AXTextArea", "AXTextField", "AXStaticText"].contains(role) {
                pending.append(contentsOf: value(node, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
        }
        guard currentIDs.count <= 1 else { throw CodexBridge.Failure(message: "页面标记了多个当前会话，暂不切换。") }
        if let id = currentIDs.first { return DesktopFocus(id: id, title: title, candidateTitles: []) }
        guard pageIDs.count <= 1 else { throw CodexBridge.Failure(message: "无法确定当前会话面板，请先点击目标会话输入框。") }
        if let id = pageIDs.first { return DesktopFocus(id: id, title: title, candidateTitles: []) }
        return DesktopFocus(id: "", title: title, candidateTitles: titles.sorted())
    }
}
