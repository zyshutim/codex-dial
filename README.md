<p align="center"><img src="Assets/AppIcon.png" width="160" alt="Codex Dial joystick icon"></p>

# Codex Dial

一个 macOS 菜单栏小工具，用快捷键切换当前 Codex 会话的模型和思考深度。

模型越来越强，也越来越贵。同一段开发对话里，简单修改和复杂问题常常交替出现，每次都打开官方选择器调整模型和思考深度，很容易打断思路。

Codex Dial 让你提前绑定常用档位，用快捷键快速切换，双手不必离开键盘，输入框里的草稿也会保留，让思路继续。

## 功能

- 保存 10 个“模型 + 思考深度”档位
- 按快捷键时自动识别当前 Codex 窗口里的会话，无需提前手动绑定
- 菜单栏显示上次确认的模型和思考深度，切换成功时给出轻量提示
- 默认按住 **Option**，连续按三次数字：`111` 对应档位 1，`000` 对应档位 0

## 安装

1. 从 [Releases](https://github.com/zyshutim/codex-dial/releases) 下载 ZIP。
2. 解压后把 `Codex Dial.app` 放进“应用程序”。
3. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Codex Dial。
4. 打开 Codex Dial，设置自己的档位。
5. 回到想切换的 Codex 会话，按住 **Option**，连续按三次对应数字即可。每次按键都会重新识别当前会话，切换窗口后也不需要重新绑定。

只在按快捷键时识别目标会话，平时不持续轮询。

如果 macOS 阻止打开，请在“隐私与安全性”中选择“仍要打开”。

## 要求

- Apple Silicon Mac
- macOS 14 或更新版本
- 已安装并登录 Codex 桌面端
- 系统提供 `/usr/bin/python3`
- Codex 的“复制深层链接”快捷键保持为 `⌘⌥L`

## 说明

Codex Dial 是非官方个人工具。它通过 Codex 本地桌面接口更新当前会话的后续轮次设置，不会修改正在生成的请求。

自动识别和桌面接口仍属于实验性功能，Codex 更新后可能需要适配。应用目前使用临时签名，尚未经过 Apple 公证。

## 构建

```sh
bash build.sh
```

构建签名配置见 [签名说明](docs/SIGNING.md)。仅制作本地预览时可使用 `CODEXDIAL_ADHOC=1 bash build.sh`。

发布安装包使用 `bash package.sh`：先构建，再检查隐私信息并生成 ZIP，自动排除 macOS 扩展元数据。构建会在签名前移除调试符号中的本地路径。

源码使用 Swift、AppKit 和 SwiftUI；本地接口适配器使用 Python 标准库。
