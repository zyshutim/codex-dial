import Foundation
import AppKit
import Carbon

enum Effort: String, Codable, CaseIterable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max, ultra
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Light"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }
    var explanation: String {
        switch self {
        case .none, .minimal, .low: return "更快响应，适合简单修改"
        case .medium: return "兼顾响应速度与思考深度"
        case .high: return "深入思考，适合复杂实现"
        case .xhigh: return "更多推理，适合难题与审查"
        case .max: return "最大思考深度，耗时和用量更高"
        case .ultra: return "最高档位，可能启用自动任务委派"
        }
    }
    var aliases: [String] {
        switch self {
        case .none: return ["None", "无"]
        case .minimal: return ["Minimal", "最低", "极低"]
        case .low: return ["Light", "Low", "轻度", "低"]
        case .medium: return ["Medium", "中等", "中"]
        case .high: return ["High", "高"]
        case .xhigh: return ["Extra High", "XHigh", "极高", "超高"]
        case .max: return ["Max", "Maximum", "最大"]
        case .ultra: return ["Ultra", "超强"]
        }
    }
}

struct ModelOption: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let efforts: [Effort]
    let defaultEffort: Effort
    var shortName: String { name.replacingOccurrences(of: "GPT-", with: "").replacingOccurrences(of: "-", with: " ") }
    var aliases: [String] { [id, name, name.replacingOccurrences(of: "-", with: " "), shortName] }
}
struct Selection: Codable, Equatable { var modelID: String; var effort: Effort }

struct KeyChord: Codable, Equatable {
    var code: UInt32
    var modifiers: UInt32
    var key: String
    var display: String { Self.symbols(modifiers) + key }
    static let digits: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    static func standard(_ slot: Int) -> KeyChord {
        .init(code: digits[slot], modifiers: UInt32(controlKey | shiftKey), key: String((slot + 1) % 10))
    }
    static func symbols(_ modifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
    static func from(_ event: NSEvent) -> KeyChord {
        let names: [UInt16: String] = [36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        let digit = digits.firstIndex(of: UInt32(event.keyCode)).map { String(($0 + 1) % 10) }
        return .init(code: UInt32(event.keyCode), modifiers: carbonModifiers(event.modifierFlags), key: digit ?? names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
    }
    func sameKeys(as other: KeyChord) -> Bool { code == other.code && modifiers == other.modifiers }
}

struct Preset: Codable, Identifiable, Equatable {
    var id: Int
    var name: String
    var selection: Selection?
    var hotkey: KeyChord?
    var digit: String { String((id + 1) % 10) }
    var title: String { name.isEmpty ? "档位 \(digit)" : name }
    static var emptySlots: [Preset] {
        (0..<10).map { Preset(id: $0, name: "", selection: nil, hotkey: .standard($0)) }
    }
}

enum Validation {
    static func chord(_ chord: KeyChord, slot: Int, presets: [Preset]) -> String? {
        guard chord.modifiers & UInt32(cmdKey | controlKey) != 0 else { return "至少包含 Control 或 Command，避免覆盖正常输入。" }
        if let duplicate = presets.first(where: { $0.id != slot && $0.hotkey?.sameKeys(as: chord) == true }) {
            return "与档位 \(duplicate.digit) 重复，换一个组合。"
        }
        if chord.modifiers == UInt32(cmdKey) { return "增加一个修饰键，避免覆盖 Codex 或系统操作。" }
        if chord.modifiers == UInt32(cmdKey | optionKey), KeyChord.digits.prefix(6).contains(chord.code) {
            return "Codex 已用这个快捷键切换最近会话。"
        }
        if chord.modifiers == UInt32(controlKey), KeyChord.digits.prefix(3).contains(chord.code) {
            return "Codex 已用这个快捷键切换 Chat / Work / Codex。"
        }
        if chord.modifiers == UInt32(controlKey | shiftKey) && [46,9,2,5].contains(chord.code) {
            return "与 Codex 的模型、语音或审查快捷键冲突。"
        }
        return nil
    }
    static func selection(_ selection: Selection, models: [ModelOption]) -> String? {
        guard let model = models.first(where: { $0.id == selection.modelID }) else { return "这个模型不在本机模型列表中，重新选择一个模型。" }
        return model.efforts.contains(selection.effort) ? nil : "这个模型不支持所选思考深度。"
    }
}

struct Catalog {
    static func load() -> [ModelOption] {
        struct Cache: Decodable { var models: [Entry] }
        struct Level: Decodable { var effort: String }
        struct Entry: Decodable {
            var slug: String; var display_name: String; var supported_reasoning_levels: [Level]
            var default_reasoning_level: String; var visibility: String?
        }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.models.filter { $0.visibility == "list" }.compactMap {
            let levels = $0.supported_reasoning_levels.compactMap { Effort(rawValue: $0.effort) }
            guard !levels.isEmpty else { return nil }
            return ModelOption(id: $0.slug, name: $0.display_name, efforts: levels, defaultEffort: Effort(rawValue: $0.default_reasoning_level) ?? levels[0])
        }
    }
    static let preview = [
        ModelOption(id: "gpt-6-astra", name: "GPT-6-Astra", efforts: [.low,.medium,.high,.xhigh,.max,.ultra], defaultEffort: .medium),
        ModelOption(id: "gpt-5.6-sol", name: "GPT-5.6-Sol", efforts: [.low,.medium,.high,.xhigh,.max,.ultra], defaultEffort: .low),
        ModelOption(id: "gpt-5.6-terra", name: "GPT-5.6-Terra", efforts: [.low,.medium,.high,.xhigh,.max,.ultra], defaultEffort: .medium),
        ModelOption(id: "gpt-5.6-luna", name: "GPT-5.6-Luna", efforts: [.low,.medium,.high,.xhigh,.max], defaultEffort: .medium)
    ]
}

struct PresetStore {
    let url: URL
    static var user: PresetStore {
        .init(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CodexDial/presets.json"))
    }
    func load() throws -> [Preset] {
        guard FileManager.default.fileExists(atPath: url.path) else { return Preset.emptySlots }
        let saved = try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url))
        guard saved.count == 10, Set(saved.map(\.id)) == Set(0..<10) else { throw StoreError.invalid }
        let sorted = saved.sorted { $0.id < $1.id }
        for preset in sorted {
            if let chord = preset.hotkey, Validation.chord(chord, slot: preset.id, presets: sorted) != nil { throw StoreError.invalid }
        }
        return sorted
    }
    func save(_ presets: [Preset]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(presets).write(to: url, options: .atomic)
    }
    enum StoreError: Error { case invalid }
}

struct Reading: Equatable {
    var selection: Selection?
    var message: String
    var detail: String
    var connected = false
    static let waiting = Reading(selection: nil, message: "等待 Codex", detail: "打开 Codex 会话后读取当前档位")
}

enum ControlParser {
    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func model(in text: String, models: [ModelOption]) -> ModelOption? {
        let value = normalized(text)
        return models.sorted { $0.name.count > $1.name.count }.first { model in
            model.aliases.contains { value.contains(normalized($0)) }
        }
    }
    static func effort(in text: String) -> Effort? {
        let value = normalized(text)
        for effort in [Effort.xhigh, .ultra, .max, .medium, .minimal, .none, .low, .high] {
            for alias in effort.aliases {
                let escaped = NSRegularExpression.escapedPattern(for: normalized(alias))
                if value.range(of: "(?<![a-z])" + escaped + "(?![a-z])", options: .regularExpression) != nil { return effort }
            }
        }
        return nil
    }
    static func uniqueEffort(in text: String) -> Effort? {
        var value = normalized(text)
        var matches = Set<Effort>()
        for effort in [Effort.xhigh, .ultra, .max, .medium, .minimal, .none, .low, .high] {
            for alias in effort.aliases.sorted(by: { $0.count > $1.count }) {
                let pattern = "(?<![a-z])" + NSRegularExpression.escapedPattern(for: normalized(alias)) + "(?![a-z])"
                if value.range(of: pattern, options: .regularExpression) != nil {
                    matches.insert(effort)
                    value = value.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
                }
            }
        }
        return matches.count == 1 ? matches.first : nil
    }
}
