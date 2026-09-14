import SwiftUI
import AppKit

enum DialStyle {
    static let accent = Color(nsColor: NSColor(name: "DialAccent", dynamicProvider: { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.97, green: 0.60, blue: 0.40, alpha: 1)
            : NSColor(srgbRed: 0.73, green: 0.29, blue: 0.16, alpha: 1)
    }))
    static let quiet = Color.primary.opacity(0.045)
    static let border = Color.primary.opacity(0.08)
}

struct Keycap: View {
    let text: String
    var large = false
    var body: some View {
        Text(text).font(.system(size: large ? 19 : 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary).padding(.horizontal, large ? 16 : 7).padding(.vertical, large ? 9 : 4)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: large ? 10 : 5))
            .overlay(RoundedRectangle(cornerRadius: large ? 10 : 5).strokeBorder(DialStyle.border, lineWidth: 0.5))
    }
}

struct DialButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(prominent ? Color(red: 0.73, green: 0.29, blue: 0.16) : DialStyle.quiet, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct RootView: View {
    @ObservedObject var state: AppState
    @State private var editing: Int?
    var body: some View {
        Group {
            if state.showConnection { connection }
            else if state.showSettings { ShortcutSettings(state: state, recorder: state.recorder) }
            else { main }
        }
        .frame(width: 420, height: 730)
        .background(.regularMaterial)
        .tint(DialStyle.accent)
        .onAppear { state.onEdit = { editing = $0 } }
    }
    private var main: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "dial.medium").font(.system(size: 18, weight: .medium)).foregroundStyle(DialStyle.accent)
                Text("Codex Dial").font(.system(size: 16, weight: .semibold))
                Spacer()
                if state.preview { Text("预览").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(5).background(DialStyle.quiet, in: Capsule()) }
                Button { state.reloadModels() } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(.plain).help("重新读取模型与当前档位").accessibilityLabel("重新读取")
            }.padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 17)
            currentCard.padding(.horizontal, 18)
            HStack {
                Text("我的档位").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("点击编辑 · 右侧切换").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 24).padding(.top, 21).padding(.bottom, 8)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(state.presets) { preset in
                        PresetRow(preset: preset, current: state.reading.selection, subtitle: state.label(preset.selection), busy: state.busy, shortcutLabel: state.tripleTapEnabled ? "⌥ " + String(repeating: preset.digit, count: 3) : nil,
                                  edit: { editing = preset.id }, apply: { state.apply(preset.id) })
                            .popover(isPresented: Binding(get: { editing == preset.id }, set: { if !$0 { editing = nil } }), arrowEdge: .leading) {
                                PresetEditor(state: state, preset: preset, dismiss: { editing = nil })
                            }
                    }
                }.padding(.horizontal, 12)
            }.scrollIndicators(.hidden)
            if let error = state.error { InlineError(message: error).padding(.horizontal, 20).padding(.top, 7) }
            if !state.hotkeyFailures.isEmpty {
                InlineError(message: "档位 \(state.hotkeyFailures.map { String(($0 + 1) % 10) }.joined(separator: "、")) 的快捷键被占用，在设置中更换。").padding(.horizontal, 20)
            }
            Text(state.shortcutStatus)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 8)
            Divider().padding(.top, 12)
            HStack {
                Button {
                    state.showSettings = true; state.updateHotkeys()
                } label: { Label("快捷键设置", systemImage: "keyboard").padding(.vertical, 10) }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                Spacer()
                Button("目标会话") { state.showConnection = true; state.updateHotkeys() }
                    .buttonStyle(.plain).font(.system(size: 12))
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power").frame(width: 30, height: 30) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("退出 Codex Dial").accessibilityLabel("退出 Codex Dial")
            }.padding(.horizontal, 22).padding(.vertical, 8)
        }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("目标会话").font(.headline)
                Spacer()
                Button("完成") { state.showConnection = false; state.updateHotkeys() }.disabled(state.listing)
            }
            Text(state.targetID.isEmpty ? "自动跟随当前 Codex 窗口" : "已固定目标，不跟随窗口")
                .font(.callout).foregroundStyle(.secondary)
            Button("自动跟随当前窗口") { state.followWindow() }
                .buttonStyle(DialButtonStyle(prominent: true)).disabled(state.busy)
            Button("打开辅助功能设置") { state.openPrivacySettings() }.buttonStyle(DialButtonStyle())
            Text("切换时自动调用 Codex 的「复制深层链接」（⌘⌥L）来识别当前会话，并恢复剪贴板。模型和深度通过桌面内部接口切换。")
                .font(.caption).foregroundStyle(.secondary)
            Button(state.listing ? "读取中…" : "刷新会话列表") { state.connectAndList() }
                .buttonStyle(DialButtonStyle()).disabled(state.listing || state.busy)
            if let error = state.connectionError { InlineError(message: error) }
            Divider()
            Text("或固定到一个会话").font(.subheadline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.targets) { target in
                        Button { state.bindTarget(target.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.latestMessage ?? "最新消息暂未读取").lineLimit(2)
                                    HStack {
                                        Text(target.title).lineLimit(1)
                                        Spacer()
                                        if let stamp = target.messageTime {
                                            Text(Date(timeIntervalSince1970: stamp), format: .dateTime.month().day().hour().minute())
                                        }
                                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                                    Text(target.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if state.targetID == target.id { Image(systemName: "checkmark") }
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(DialStyle.quiet, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(state.busy)
                    }
                }
            }
            Toggle("启用档位快捷键", isOn: $state.shortcutsArmed)
                .onChange(of: state.shortcutsArmed) { _, _ in state.updateHotkeys() }
            Text(state.targetID.isEmpty ? "快捷键只在 Codex 前台生效，目标随窗口变化。" : "已固定目标：切到其他窗口仍会修改这里选中的会话。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(22).onAppear { state.connectAndList() }
    }
    private var currentCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Circle().fill(state.reading.selection == nil ? Color.secondary : DialStyle.accent).frame(width: 5, height: 5)
                Text(state.reading.message).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let active = state.presets.first(where: { $0.selection != nil && $0.selection == state.reading.selection }) {
                    Text("档位 \(active.digit)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
            }
            if let selection = state.reading.selection {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.model(selection)?.shortName ?? selection.modelID).font(.system(size: 23, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    Text(selection.effort.label).font(.system(size: 12, weight: .medium)).foregroundStyle(DialStyle.accent)
                        .padding(.horizontal, 10).padding(.vertical, 5).background(DialStyle.accent.opacity(0.08), in: Capsule())
                }
            } else {
                Text(state.reading.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Button("目标会话") { state.showConnection = true; state.updateHotkeys() }.buttonStyle(DialButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(DialStyle.quiet, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PresetRow: View {
    let preset: Preset
    let current: Selection?
    let subtitle: String
    let busy: Bool
    var shortcutLabel: String? = nil
    let edit: () -> Void
    let apply: () -> Void
    @State private var hovered = false
    private var selected: Bool { preset.selection != nil && preset.selection == current }
    var body: some View {
        HStack(spacing: 0) {
            Button(action: edit) {
                HStack(spacing: 12) {
                    Text(preset.digit).font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? DialStyle.accent : Color.secondary)
                        .frame(width: 30, height: 32)
                        .background(selected ? DialStyle.accent.opacity(0.1) : DialStyle.quiet, in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.selection == nil ? "设置档位 \(preset.digit)" : preset.title)
                            .font(.system(size: 12, weight: preset.selection == nil ? .regular : .medium))
                            .foregroundStyle(preset.selection == nil ? Color.secondary : Color.primary)
                        if preset.selection != nil { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    if let shortcutLabel { Keycap(text: shortcutLabel) } else if let hotkey = preset.hotkey { Keycap(text: hotkey.display) }
                }.padding(.leading, 10).padding(.trailing, 6).frame(height: 42).contentShape(Rectangle())
            }.buttonStyle(.plain).help("编辑档位 \(preset.digit)").accessibilityLabel("编辑档位 \(preset.digit)，\(preset.title)，\(subtitle)")
            if preset.selection != nil {
                Button(action: apply) {
                    Image(systemName: selected ? "checkmark" : "arrow.up.right")
                        .font(.system(size: 11, weight: .medium)).frame(width: 34, height: 42)
                        .foregroundStyle(selected ? DialStyle.accent : Color.secondary)
                }.buttonStyle(.plain).disabled(busy).help("切换到档位 \(preset.digit)")
                    .accessibilityLabel("切换到档位 \(preset.digit)")
            } else {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(.tertiary).frame(width: 34, height: 42).allowsHitTesting(false)
            }
        }
        .background(selected ? DialStyle.accent.opacity(0.045) : hovered ? DialStyle.quiet : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
    }
}

struct PresetEditor: View {
    @ObservedObject var state: AppState
    @State var preset: Preset
    let dismiss: () -> Void
    @State private var modelID = ""
    @State private var effort: Effort = .medium
    @State private var error: String?
    @State private var confirmClear = false
    @FocusState private var nameFocused: Bool
    private var model: ModelOption? { state.models.first { $0.id == modelID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("编辑档位 \(preset.digit)").font(.system(size: 15, weight: .semibold))
                Spacer()
                if let key = preset.hotkey { Keycap(text: key.display) }
            }.padding(.bottom, 20)
            Text("名称").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.bottom, 7).onTapGesture { nameFocused = true }
            TextField("例如：深入思考", text: $preset.name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityLabel("档位名称").onChange(of: preset.name) { _, value in if value.count > 32 { preset.name = String(value.prefix(32)) } }
                .padding(.bottom, 20)
            HStack {
                Text("模型").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text("来自本机 Codex").font(.system(size: 10)).foregroundStyle(.tertiary)
            }.padding(.bottom, 8)
            if state.models.isEmpty {
                Text("没有读取到模型列表。先打开 Codex，再点击主面板的重新读取。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(state.models) { option in
                            Button {
                                modelID = option.id
                                if !option.efforts.contains(effort) { effort = option.defaultEffort }
                            } label: {
                                HStack {
                                    Text(option.shortName).font(.system(size: 13, weight: modelID == option.id ? .medium : .regular))
                                    Spacer()
                                    if modelID == option.id { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DialStyle.accent) }
                                }.padding(.horizontal, 12).frame(height: 37)
                                    .background(modelID == option.id ? DialStyle.quiet : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(modelID == option.id ? .isSelected : [])
                        }
                    }
                }.frame(height: min(CGFloat(state.models.count) * 39, 235)).scrollIndicators(.hidden)
            }
            Divider().padding(.vertical, 18)
            HStack {
                Text("思考深度").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(effort.label).font(.system(size: 11, weight: .medium)).foregroundStyle(DialStyle.accent)
            }.padding(.bottom, 11)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model?.efforts ?? []) { level in
                    Button { effort = level } label: {
                        Text(level.label).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity).frame(height: 34)
                            .background(effort == level ? DialStyle.accent.opacity(0.10) : DialStyle.quiet, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(effort == level ? DialStyle.accent : Color.secondary)
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(effort == level ? DialStyle.accent.opacity(0.35) : .clear, lineWidth: 1))
                    }.buttonStyle(.plain).accessibilityLabel("思考深度 \(level.label)").accessibilityAddTraits(effort == level ? .isSelected : [])
                }
            }
            Text(effort.explanation).font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 10).frame(height: 30, alignment: .top)
            if let error { InlineError(message: error).padding(.bottom, 8) }
            HStack {
                if preset.selection != nil {
                    Button("清空") { confirmClear = true }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", action: dismiss).buttonStyle(DialButtonStyle()).keyboardShortcut(.cancelAction)
                Button("保存档位") {
                    preset.selection = Selection(modelID: modelID, effort: effort)
                    if state.save(preset) { dismiss() } else { error = state.error }
                }.buttonStyle(DialButtonStyle(prominent: true)).disabled(model == nil).keyboardShortcut(.defaultAction)
            }.padding(.top, 15)
        }.padding(22).frame(width: 370).background(.regularMaterial).tint(DialStyle.accent)
            .confirmationDialog("清空档位 \(preset.digit)？快捷键绑定会保留。", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("清空档位", role: .destructive) {
                    var cleared = preset; cleared.selection = nil; cleared.name = ""
                    if state.save(cleared) { dismiss() } else { error = state.error }
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear {
                let selection = preset.selection ?? state.reading.selection
                modelID = selection?.modelID ?? state.models.first?.id ?? ""
                effort = selection?.effort ?? model?.defaultEffort ?? .medium
                nameFocused = true
            }
    }
}

struct InlineError: View {
    let message: String
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").padding(.top, 1)
            Text(message).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed))
    }
}

struct ShortcutSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var recorder: KeyRecorder
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    recorder.stop(); state.showSettings = false; state.updateHotkeys()
                } label: { Image(systemName: "chevron.left").frame(width: 28, height: 28) }.buttonStyle(.plain).accessibilityLabel("返回档位")
                Text("快捷键").font(.system(size: 17, weight: .semibold))
                Spacer()
                Image(systemName: "keyboard").font(.system(size: 21)).foregroundStyle(.secondary)
            }.padding(.bottom, 14)
            Toggle("Option + 数字连按三次", isOn: Binding(get: { state.tripleTapEnabled }, set: { state.setTripleTap($0) }))
                .font(.system(size: 12)).padding(.bottom, 8)
            Text(state.tripleTapEnabled ? "按住 ⌥，0.9 秒内连按三次同一数字。下面的单次组合键暂不生效，关闭此开关即可恢复。" : "当前使用下方保存的单次组合键。")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 12)
            Text("点击按键框，按下新组合。").font(.system(size: 13, weight: .medium)).padding(.bottom, 5)
            Text("按键会实时显示，确认保存后生效。\n只在 Codex 位于前台时响应。Esc 取消录入。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3).padding(.bottom, 18)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(state.presets) { preset in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 10) {
                                Text(preset.digit).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).frame(width: 19)
                                Text(preset.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                Button { state.beginRecording(preset.id) } label: {
                                    Text(recordingText(preset)).font(.system(size: 13, weight: .medium, design: .monospaced))
                                        .frame(minWidth: 103, minHeight: 34)
                                        .foregroundStyle(recorder.slot == preset.id ? DialStyle.accent : Color.primary)
                                        .background(recorder.slot == preset.id ? DialStyle.accent.opacity(0.06) : DialStyle.quiet, in: RoundedRectangle(cornerRadius: 7))
                                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(recorder.slot == preset.id ? DialStyle.accent.opacity(0.7) : DialStyle.border, lineWidth: recorder.slot == preset.id ? 1.5 : 0.5))
                                }.buttonStyle(.plain).accessibilityLabel("录入档位 \(preset.digit) 的快捷键").accessibilityValue(recordingText(preset))
                            }
                            if recorder.slot == preset.id {
                                if let error = recorder.error { InlineError(message: error) }
                                HStack(spacing: 8) {
                                    Button("清除绑定") { state.clearShortcut(preset.id) }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("取消") { recorder.stop() }.buttonStyle(DialButtonStyle())
                                    Button("确认保存") { state.saveShortcut(slot: preset.id) }.buttonStyle(DialButtonStyle(prominent: true)).disabled(recorder.pending == nil)
                                }
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 4).background(recorder.slot == preset.id ? DialStyle.quiet : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }.scrollIndicators(.hidden)
            Divider().padding(.vertical, 14)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text("默认 ⌃⇧ + 1–0。会检查重复与系统占用；Codex 自定义快捷键也需避免重叠。")
            }.font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(22)
        .onDisappear { recorder.stop() }
    }
    private func recordingText(_ preset: Preset) -> String {
        guard recorder.slot == preset.id else { return preset.hotkey?.display ?? "未绑定" }
        if let pending = recorder.pending { return pending.display }
        return recorder.symbols.isEmpty ? "按下组合键…" : recorder.symbols + "…"
    }
}

struct SwitchHUD: View {
    let message: HUDMessage
    let model: ModelOption?
    private var color: Color { message.phase == .failure ? Color(nsColor: .systemRed) : DialStyle.accent }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(message.preset.digit)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(color).frame(width: 29, height: 29)
                .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    if message.phase == .switching { ProgressView().controlSize(.small) }
                    else { Image(systemName: message.phase == .success ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(color) }
                    Text(message.phase == .switching ? "正在切换" : message.phase == .success ? message.preset.title : "切换未完成")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(model?.shortName ?? message.preset.selection?.modelID ?? "未设置")
                    .font(.system(size: 17, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
                Text(message.preset.selection?.effort.label ?? "—")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(color).lineLimit(1)
                if message.phase == .failure {
                    Text(message.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(16).frame(width: 265, height: message.phase == .failure ? 142 : 112, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(DialStyle.border, lineWidth: 0.5))
            .accessibilityElement(children: .combine)
    }
}
