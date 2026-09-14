<p align="center"><img src="Assets/AppIcon.png" width="160" alt="Codex Dial joystick icon"></p>

# Codex Dial

一个 macOS 菜单栏小工具，用十个档位快捷切换本机 Codex 会话的模型和思考深度。

## 安装与使用

从 Releases 下载 ZIP，解压后将 Codex Dial.app 放入「应用程序」。

- Apple Silicon Mac，macOS 14 或更新版本。
- 已安装并登录 Codex 桌面端。
- 需要系统提供 /usr/bin/python3，Python 组件只使用标准库。
- 在系统设置中允许 Codex Dial 使用辅助功能。
- 当前使用 ad-hoc 签名，未经过开发者签名和公证。可信来源的安装包若被 Gatekeeper 拦截，可在「系统设置 → 隐私与安全性」选择「仍要打开」。

打开 App 后配置档位。默认按住 **Option**，在 **0.9 秒内连按三次同一数字**：
111 对应档位 1，依此类推，000 对应档位 0。长按不计数；只在 Codex 前台注册快捷键。
Option + 数字的前两次也会被拦截。设置中可关闭三连按，恢复可自定义的组合键。

## 当前会话识别

启动默认自动跟随。切档或点击重新读取时，调用 Codex 默认的 **⌘⌥L「复制深层链接」**，从 codex://threads/<UUID> 取得会话 ID，再通过本地桌面 IPC 更新模型和思考深度。

- Codex 的复制深层链接快捷键需保持 ⌘⌥L。
- 保存并恢复可读取的剪贴板类型；检测到其他复制内容时不覆盖。剪贴板历史软件仍可能记录链接。
- 写入前再次读取链接；窗口或会话变化时中止。
- 后台不会定时复制链接，菜单栏显示最近一次读取或切换的档位。
- 自动识别失败时可在目标列表固定会话；固定模式不会跟随窗口。
- 同一窗口内主会话与侧边会话的焦点行为尚未验证。

会话列表展示最近 100 个会话的最新用户或助手消息，按消息时间倒序排列，保留标题和时间。只读本机元数据和日志，不修改会话数据库。

## 范围与状态

这是个人便利工具，与 OpenAI 无官方关联。

手动绑定后的档位切换已获原使用者确认可用。0.4.8 引入的深度链接自动识别和 0.4.9 图标版已编译，未进行真实 Codex 自动切换测试。跨版本、跨机器兼容性未验证。

桌面 IPC 是未公开协议，Codex 更新后可能需要适配。当前仅支持本机 local 会话。更新针对后续轮次，不会替换正在生成的模型请求；不发送提示词、不停止生成、不改变权限或 Codex 安装包。

档位保存在 ~/Library/Application Support/CodexDial/presets.json，不包含在仓库和安装包中。

## 构建

需要 Xcode Command Line Tools：

```sh
bash build.sh
```

可通过 CODEXDIAL_BUILD_DIR 和 CODEXDIAL_APP_DIR 指定构建、App 输出目录。
重新生成图标尺寸：

```sh
bash make-icon.sh
```

源码为 Swift / AppKit / SwiftUI；桌面 IPC 适配器为 Python 标准库实现。
