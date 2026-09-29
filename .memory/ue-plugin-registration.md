---
name: ue-plugin-registration
description: 生成的插件接进 UE 项目的三种放法，以及 .uproject 里怎么写。
type: decision
---

## Why

`<项目>/Plugins/<名>/<名>.uplugin` 会被 UE 自动发现，`.uproject` 不是必需的；
写进 `.uproject` 只是显式启用（团队/CI 同步状态）。插件放项目之外还有第三条路：
`.uproject` 的 `AdditionalPluginDirectories`（UE 4.24+，路径相对 `.uproject`）。

已在 UE 5.8 源码里核对过两处结论：

- `Runtime/Projects/Private/ProjectDescriptor.cpp:148` 读 `AdditionalPluginDirectories`；
  同文件 `:163` 在 `RequiresCookedData()` 时把它清空 —— 出包必须把插件搬回 `Plugins/`。
- `Programs/UnrealBuildTool/Configuration/Descriptors/PluginReferenceDescriptor.cs`
  的 `.uproject` 条目字段是 `Name` / `Enabled` / `Optional` / `PlatformAllowList` 等。

## How to apply

文档写三处，改一处就三处同步：

1. 根 `README.md` 的「接进 UE 项目」一节（A 项目内 / B .uproject / C 外部目录 + 生效顺序 + 故障表）
2. `src/templates.zig` 的 `plugin_readme`（生成出来的插件 README）
3. `src/gen.zig` 里 `new` 结尾打印的「下一步」，要直接把 `"Plugins": [ ... ]` 片段贴出来

Mac 上重新生成项目文件的命令：
`"$UE/Engine/Build/BatchFiles/Mac/GenerateProjectFiles.sh" -project="$PWD/MyGame.uproject" -game`

## Related

[[uerust-unreal-bridge-choices]]
