# 悬浮助手

Windows 桌面右侧把手。点击展开，按 Esc 或点击右上角箭头收起。截图插件启用时会提供「桌面截图」面板。点击「开始截图」后浮窗会临时隐藏，框选完成后面板显示 PNG 保存路径。

## 截图翻译

在浮窗切到「截图翻译」，点击「框选并翻译」，确认选区后即可在浮窗查看简体中文译文和对应原文。Windows 在本机识别文字，DSH 模型接收识别结果并翻译。翻译使用的临时截图会在操作结束后清理，最近一次结果保存在面板内，退出 DSH 时清除。

识别语言默认为 `en-US`。如果常用其他语言，可在 DSH profile 的 `dsh-screenshot` 插件配置中设置 `ocrLanguage`，例如 `ja-JP`，并确保 Windows 已安装对应的 OCR 语言。翻译通常使用 DSH 默认模型，也可通过 `translationModel` 指定已配置的 `provider` 和 `model`，只影响截图翻译。

## 在 DSH 中加载

悬浮助手由 DSH 启动包内的 `DshFloatingAssistant.exe`。它使用 Windows 的 .NET Framework/WPF，安装时无需运行构建脚本。打包需要 Windows 和系统 .NET Framework 自带的 C# 编译器。

退出桌面版 DSH，在仓库根目录打包悬浮助手，再用桌面版附带的 DSH CLI 将本地包添加到 `desktop` profile。保留生成的压缩包，供 profile 后续重装依赖。

```powershell
$capture = (Resolve-Path ./capture).Path.Replace('\', '/')
$package = npm pack ./floating-assistant --silent | Select-Object -Last 1
$assistant = (Resolve-Path $package).Path.Replace('\', '/')
dsh plugin --profile desktop add "link:$capture" "file:$assistant"
```

在该 profile 的 `package.json` 中，把 `@local/dsh-screenshot` 和 `@local/dsh-floating-assistant` 加入 `dsh.profile.bundles`。保留已有的 bundle，每个包只列一次。重启使用该 profile 的 DSH 后，点击显示器右侧的把手。通过浮窗内的设置切换显示器、启停面板或选择默认面板。

## 贡献面板

通过 Cordis 注入 `floatingAssistant`，调用 `register(pluginId, declarations, handlers)`。注册返回卸载函数，可以直接作为注入回调的清理函数。可选接入可参考 [截图插件](../capture/index.js)，宿主启用后由 Cordis 加载对应贡献。

处理器接收面板 ID 和用于取消的 `signal`。操作处理器还接收操作 ID 和数据快照附带的 `contextToken`。需要临时隐藏浮窗的操作可声明 `hideWindow: true`，宿主确认隐藏后再执行，并在结束后恢复。框选等交互结束后可调用 `restoreWindow()` 提前恢复浮窗。数据变化时调用 `invalidate(pluginId, panelId)`。

面板接口及首版验收场景见 [需求](REQUIREMENTS.md)。
