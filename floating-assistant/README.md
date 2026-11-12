# 悬浮助手

Windows 桌面右侧把手。点击展开，按 Esc 或点击右上角箭头收起。截图插件启用时会提供「桌面截图」面板。点击「开始截图」后浮窗会临时隐藏，框选完成后面板显示 PNG 保存路径。

## 在 DSH 中加载

在仓库根目录将两个本地包添加到 Windows 桌面使用的 profile。以下以 `desktop` 为例。

```powershell
$capture = (Resolve-Path ./capture).Path.Replace('\', '/')
$assistant = (Resolve-Path ./floating-assistant).Path.Replace('\', '/')
dsh plugin --profile desktop add "link:$capture" "link:$assistant"
```

在该 profile 的 `package.json` 中，把 `@local/dsh-screenshot` 和 `@local/dsh-floating-assistant` 加入 `dsh.profile.bundles`。保留已有的 bundle，每个包只列一次。重启使用该 profile 的 DSH 后，点击显示器右侧的把手。通过浮窗内的设置切换显示器、启停面板或选择默认面板。

## 贡献面板

通过 Cordis 注入 `floatingAssistant`，调用 `register(pluginId, declarations, handlers)`。注册返回卸载函数，可以直接作为注入回调的清理函数。可选接入可参考 [截图插件](../capture/index.js)，宿主启用后由 Cordis 加载对应贡献。

处理器接收面板 ID 和用于取消的 `signal`。操作处理器还接收操作 ID 和数据快照附带的 `contextToken`。需要临时隐藏浮窗的操作可声明 `hideWindow: true`，宿主确认隐藏后再执行，并在结束后恢复。数据变化时调用 `invalidate(pluginId, panelId)`。

本版本提供桌面截图面板。通用截图翻译和 GameGuide 当前计划的接口及验收场景见 [需求](REQUIREMENTS.md)。
