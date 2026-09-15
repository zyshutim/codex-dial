<p align="center"><img src="Assets/AppIcon.png" width="160" alt="Codex Dial joystick icon"></p>

# Codex Dial

一个 macOS 菜单栏小工具，用快捷键切换当前 Codex 会话的模型和思考深度。

模型越来越强，也越来越贵。同一段开发对话里，简单修改和复杂问题常常交替出现，每次都打开官方选择器调整模型和思考深度，很容易打断思路。

Codex Dial 让你提前绑定常用档位，用快捷键快速切换，双手不必离开键盘，输入框里的草稿也会保留，让思路继续。

## 功能

- 保存 10 个“模型 + 思考深度”档位
- 自动跟随当前 Codex 窗口，也可以手动固定会话
- 菜单栏显示当前档位，切换时给出轻量提示
- 默认按住 **Option**，连续按三次数字：`111` 对应档位 1，`000` 对应档位 0

## 安装

1. 从 [Releases](https://github.com/zyshutim/codex-dial/releases) 下载 ZIP。
2. 解压后把 `Codex Dial.app` 放进“应用程序”。
3. 在“系统设置 → 隐私与安全性 → 辅助功能”中允许 Codex Dial。
4. 打开 Codex Dial，设置自己的档位。

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

源码使用 Swift、AppKit 和 SwiftUI；本地接口适配器使用 Python 标准库。
