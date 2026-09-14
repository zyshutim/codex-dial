import Foundation

enum RPCSelfTest {
    static func run(path: String, threadID: String) {
        let bridge = CodexBridge()
        var finished = false, passed = false, notifications = 0
        bridge.onChange = { notifications += 1 }
        bridge.configure(path: path, threadID: threadID, title: "隔离测试")
        bridge.list { result in
            guard case .success(let targets) = result, targets.contains(where: { $0.id == threadID }) else { finished = true; return }
            bridge.read(models: Catalog.preview) { before in
                guard before.selection == Selection(modelID: "gpt-6-astra", effort: .high) else { finished = true; return }
                bridge.apply(Selection(modelID: "gpt-5.6-sol", effort: .medium), models: Catalog.preview) { result in
                    guard case .success(let after) = result, after.selection == Selection(modelID: "gpt-5.6-sol", effort: .medium) else { finished = true; return }
                    bridge.apply(Selection(modelID: "gpt-6-astra", effort: .high), models: Catalog.preview) { restored in
                        if case .success(let value) = restored { passed = value.selection == before.selection }
                        finished = true
                    }
                }
            }
        }
        let deadline = Date().addingTimeInterval(30)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        bridge.stop()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        print("RPC integration: \(passed ? "PASS" : "FAIL"), notifications=\(notifications)")
        exit(passed ? 0 : 1)
    }
}
