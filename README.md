# DSH Plugins

DeepSeek Harness（DSH）插件集合，包含 Windows 桌面截图、悬浮助手和规划中的游戏助手。

## 插件列表

| 插件 | 当前状态 | 功能 |
| --- | --- | --- |
| [桌面截图](capture/)（`@local/dsh-screenshot`） | 已实现，包版本 `1.0.0` | Windows 多显示器框选截图、标注和 PNG 导出，支持 Agent 调用与全局快捷键。 |
| [悬浮助手](floating-assistant/)（`@local/dsh-floating-assistant`） | 首个可运行版本 `0.1.0` | Windows 右侧浮窗、插件面板、默认面板和显示器设置，已接入桌面截图。 |
| [GameGuide 游戏助手](gameguide/REQUIREMENTS.md) | 需求设计阶段，仓库内只有需求文档 | 计划支持游戏截图翻译、攻略问答、游玩进度记录和按当前局面计算行动方案。 |

## 桌面截图

- Agent 可调用 `screenshot`，打开覆盖所有显示器的截图遮罩。用户框选并确认后，工具返回 PNG 路径和选区坐标。
- 在 Windows 上按 `Ctrl+Alt+A` 可手动启动截图，完成后自动将图片复制到剪贴板。
- 框选后可添加标注、撤销标注、另存为 PNG 或取消截图。
- 截图在本机通过 PowerShell 和 .NET 完成，无需外部服务。

## GameGuide 游戏助手（规划中）

- 框选游戏画面，通过 OCR 提取文字并展示对照译文，也可结合截图和攻略资料询问任务的下一步。
- 按游戏和游玩档案保存已确认的进度、目标和行动项，并从对话中整理可复用的攻略。
- 让 Agent 按当前数据和玩家约束编写、运行脚本，例如计算《潜水员戴夫》的备菜组合，或比较《纪元 1800》的产能和航线方案。

详细范围和首版验收条件见 [GameGuide 需求文档](gameguide/REQUIREMENTS.md)。
