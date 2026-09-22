import Foundation
import AppKit

struct RPCTarget: Identifiable {
    var id: String
    var title: String
    var latestMessage: String? = nil
    var messageTime: Double? = nil
}

final class CodexBridge {
    static let bundleID = "com.openai.codex"
    struct Failure: LocalizedError {
        let message: String
        var code: String = "request_failed"
        var errorDescription: String? { message }
        var title: String {
            switch code {
            case "session_missing": return "未识别到当前会话"
            case "permission": return "需要辅助功能权限"
            case "disconnected": return "Codex 连接已断开"
            case "owner_missing": return "会话连接不可用"
            case "timeout": return "Codex 响应超时"
            case "state_timeout": return "档位读取超时"
            case "incompatible": return "Codex 接口不兼容"
            case "unconfirmed": return "切换结果待确认"
            case "not_applied": return "档位未应用"
            default: return "操作未完成"
            }
        }
    }
    static func failureReading(_ error: Error) -> Reading {
        Reading(selection: nil, message: (error as? Failure)?.title ?? "操作未完成", detail: error.localizedDescription)
    }
    let queue = DispatchQueue(label: "CodexDial.rpc")
    var onChange: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var path = "desktop"
    private var resolvedThreadID = ""
    private var threadID = ""
    private var title = ""
    private var confirmedThreadID = ""
    private var confirmedSelection: Selection?
    private var generation = 0
    private var nextID = 0
    private let condition = NSCondition()
    private var replies: [Int: [String: Any]] = [:]
    private var ended = false
    private var startupError = ""
    private var transportStage = "启动传输进程"
    private var appPath = ""

    func configure(path: String, threadID: String, title: String) {
        queue.async {
            if self.path != path { self.disconnect(); self.path = path }
            self.threadID = threadID; self.title = title
        }
    }
    func stop() { queue.async { self.disconnect() } }
    private func disconnect() {
        input?.closeFile(); input = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        condition.lock(); generation += 1; ended = true; replies.removeAll(); condition.broadcast(); condition.unlock()
    }
    private func connect() throws {
        let installedPath = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.bundleURL?.path ?? ""
        if installedPath != appPath { disconnect(); appPath = installedPath }
        if process?.isRunning == true { return }
        guard path == "desktop" || (path.hasPrefix("/") && !path.hasSuffix("/ipc/ipc.sock")) else {
            throw Failure(message: "需要 app-server 的 Unix socket 地址；桌面私有 ipc.sock 不是这个协议。")
        }
        guard let helper = Bundle.main.url(forResource: path == "desktop" ? "desktop_transport" : "rpc_transport", withExtension: "py") else { throw Failure(message: "缺少 RPC 传输组件。") }
        disconnect()
        let p = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [helper.path, path]
        var environment = ProcessInfo.processInfo.environment
        if !appPath.isEmpty { environment["CODEX_APP_PATH"] = appPath }
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = environment
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
        condition.lock(); ended = false; startupError = ""; let epoch = generation; condition.unlock()
        try p.run(); process = p; input = stdin.fileHandleForWriting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let self else { continue }
                    self.condition.lock()
                    let current = self.generation == epoch
                    if current, let id = message["id"] as? Int { self.replies[id] = message; self.condition.broadcast() }
                    if current, message["method"] as? String == "transport/stage" { self.transportStage = message["stage"] as? String ?? "未知阶段" }
                    self.condition.unlock()
                    if current, message["method"] as? String == "thread/settings/updated" {
                        DispatchQueue.main.async { self.onChange?() }
                    }
                }
            }
            let diagnostic = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self else { return }
            self.condition.lock(); if self.generation == epoch {
                self.startupError = String(diagnostic.suffix(1500)); self.ended = true; self.condition.broadcast()
            }; self.condition.unlock()
        }
    }
    private func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        try connect(); nextID += 1; let id = nextID
        var bytes = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]); bytes.append(10)
        do { try input?.write(contentsOf: bytes) }
        catch { disconnect(); throw Failure(message: "连接已断开，请重新读取。", code: "disconnected") }
        let timeout: TimeInterval = method == "desktop/list" ? 15 : 30
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        while replies[id] == nil && !ended && Date() < deadline { _ = condition.wait(until: deadline) }
        let reply = replies.removeValue(forKey: id); let diagnostic = startupError; let stage = transportStage; condition.unlock()
        guard let reply else {
            disconnect()
            if method == "thread/settings/update" {
                throw Failure(message: "未收到切换确认，设置可能已生效。请重新读取；不会重复发送切换。停在：\(stage)。", code: "unconfirmed")
            }
            throw Failure(message: diagnostic.isEmpty ? "超过 \(Int(timeout)) 秒未收到回应，停在：\(stage)。" : "桌面连接启动失败：\(diagnostic)", code: diagnostic.isEmpty ? "timeout" : "disconnected")
        }
        if let error = reply["error"] as? [String: Any] { throw Failure(message: error["message"] as? String ?? "请求失败", code: error["code"] as? String ?? "request_failed") }
        return reply["result"] as? [String: Any] ?? [:]
    }
    private func current(resolveActive: Bool = true) throws -> Reading {
        if !threadID.isEmpty { resolvedThreadID = threadID }
        if path == "desktop" && threadID.isEmpty && resolveActive {
            let focus = try CurrentThreadLink.capture()
            resolvedThreadID = focus.id
            title = String(focus.id.prefix(8))
        }
        guard !resolvedThreadID.isEmpty else { throw Failure(message: "请打开目标 Codex 会话后重新读取。", code: "session_missing") }
        let result = try request("thread/read", ["threadId": resolvedThreadID, "includeTurns": false])
        guard let thread = result["thread"] as? [String: Any],
              let status = thread["status"] as? [String: Any], status["type"] as? String != "notLoaded" else {
            throw Failure(message: "目标会话未在这个服务中加载，已停止切换。", code: "owner_missing")
        }
        guard let model = thread["model"] as? String, let effort = thread["reasoningEffort"] as? String, let value = Effort(rawValue: effort) else {
            throw Failure(message: "Codex 未返回可识别的模型与思考深度，尚未更改会话。", code: "incompatible")
        }
        let selection = Selection(modelID: model, effort: value)
        confirmedThreadID = resolvedThreadID; confirmedSelection = selection
        return Reading(selection: selection, message: "\(threadID.isEmpty ? "上次读取 · 当前窗口" : "固定会话 · " + title)", detail: "上次确认的后续轮次档位。每次切换时重新识别目标。", connected: true)
    }
    func list(completion: @escaping (Result<[RPCTarget], Error>) -> Void) {
        queue.async {
            let result: Result<[RPCTarget], Error> = Result {
                if self.path == "desktop" {
                    let page = try self.request("desktop/list", [:])
                    return (page["data"] as? [[String: Any]] ?? []).compactMap { item in
                        guard let id = item["id"] as? String else { return nil }
                        return RPCTarget(id: id, title: item["title"] as? String ?? id, latestMessage: item["latestMessage"] as? String, messageTime: item["messageTime"] as? Double)
                    }
                }
                var targets: [RPCTarget] = [], cursor: String?
                repeat {
                    var params: [String: Any] = ["limit": 100]
                    if let cursor { params["cursor"] = cursor }
                    let page = try self.request("thread/loaded/list", params)
                    for id in page["data"] as? [String] ?? [] {
                        let thread = try self.request("thread/read", ["threadId": id, "includeTurns": false])["thread"] as? [String: Any]
                        targets.append(RPCTarget(id: id, title: (thread?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id))
                    }
                    cursor = page["nextCursor"] as? String
                } while cursor != nil && targets.count < 500
                return targets
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func read(models: [ModelOption], completion: @escaping (Reading) -> Void) {
        queue.async {
            let result: Reading
            do { result = try self.current() }
            catch { result = Self.failureReading(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func apply(_ selection: Selection, models: [ModelOption], prepared: ((Reading) -> Void)? = nil, completion: @escaping (Result<Reading, Error>) -> Void) {
        queue.async {
            let result: Result<Reading, Error> = Result {
                if let error = Validation.selection(selection, models: models) { throw Failure(message: error) }
                let automatic = self.path == "desktop" && self.threadID.isEmpty
                let focus = automatic ? try CurrentThreadLink.capture() : nil
                if let focus { self.resolvedThreadID = focus.id; self.title = String(focus.id.prefix(8)) }
                let target = self.resolvedThreadID
                guard !target.isEmpty else { throw Failure(message: "请打开目标 Codex 会话后重新读取。", code: "session_missing") }
                if self.path == "desktop" {
                    if self.confirmedThreadID == target, let previous = self.confirmedSelection {
                        let reading = Reading(selection: previous, message: "上次确认 · 当前会话", detail: "使用本地已确认档位。", connected: true)
                        DispatchQueue.main.async { prepared?(reading) }
                    }
                    if let focus {
                        try focus.checkWindow()
                    }
                    _ = try self.request("thread/settings/apply", ["threadId": target, "model": selection.modelID, "effort": selection.effort.rawValue])
                    self.confirmedThreadID = target; self.confirmedSelection = selection
                    return Reading(selection: selection, message: "当前会话", detail: "Codex 已确认后续轮次档位。", connected: true)
                }
                let previous = try self.current(resolveActive: false)
                DispatchQueue.main.async { prepared?(previous) }
                if let focus {
                    // Re-resolve after IPC loading: navigation within the same window
                    // must not silently switch the previously viewed conversation.
                    let latest = try CurrentThreadLink.capture()
                    try focus.checkWindow()
                    guard latest.id == target else { throw Failure(message: "会话已改变，已停止切换。", code: "session_missing") }
                }
                _ = try self.request("thread/settings/update", ["threadId": target, "model": selection.modelID, "effort": selection.effort.rawValue])
                let actual: Reading
                do { actual = try self.current(resolveActive: false) }
                catch { throw Failure(message: "切换已发送，但重新读取失败：\(error.localizedDescription) 设置可能已生效。", code: "unconfirmed") }
                guard self.resolvedThreadID == target, actual.selection == selection else { throw Failure(message: "服务已接受更新，但读回值不一致。请重新读取；设置可能已经改变。", code: "unconfirmed") }
                return actual
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
