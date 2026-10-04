---
name: "@@LOWER@@-plugin"
description: "继续开发 @@PLUGIN@@ 插件（Rust 核心 + UE5 dlopen 壳）时用：分层地图、uerust build 流程、FFI 两侧同步改法、编译与验证命令、不能碰的不变量。"
version: 1
---
## When to Use
在 `@@PLUGIN@@` 插件目录里加功能、改 FFI、改蓝图节点、修 bug、写文档时用。只想知道「Rust 核心 + UE5 插件」的通用做法，读同级目录的 `rust-ue-plugin` skill：那是通用 14 步流程，这里是这个插件的具体地图。

## 分层地图
| 层 | 文件 | 职责 |
|---|---|---|
| 插件描述 | `@@PLUGIN@@.uplugin` | 模块声明（Runtime / Default 加载阶段） |
| UE 构建 | `Source/@@PLUGIN@@/@@PLUGIN@@.Build.cs` | include 路径 + 库文件 staging（NonUFS） |
| 低层桥接 | `Source/@@PLUGIN@@/Public/@@PLUGIN@@.h`、`Private/@@PLUGIN@@.cpp` | `StartupModule` 里 `GetDllHandle` + `GetDllExport` 填 `F@@PLUGIN@@Ffi` |
| 蓝图节点 | `Source/@@PLUGIN@@/Public/@@PLUGIN@@Library.h`、`Private/@@PLUGIN@@Library.cpp` | 线程池调 Rust，完成回 GameThread 广播 |
| Rust 实现 | `Source/@@RUST_DIR@@/src/lib.rs` | `imp::` 里正常 Rust 逻辑 + `#[no_mangle] pub extern "C"` 导出 |
| ABI 头 | `Source/@@RUST_DIR@@/include/@@PLUGIN@@_ffi.h` | cbindgen 产物，建议提交进版本库 |
| 产物 | `Binaries/<平台>/lib@@LIB@@.dylib`（Win 是 `@@LIB@@.dll`） | `uerust build .` 拷进来，运行时 dlopen |

## Procedure
1. 只改 Rust：`cd Source/@@RUST_DIR@@ && cargo test`；然后回插件根跑 `uerust build .`，刷新 `Binaries/<平台>/` 里的库。
2. 新增/改 FFI 函数：Rust 侧 `#[no_mangle] pub extern "C"`，参数与返回值只用 C 类型；C++ 侧在 `F@@PLUGIN@@Ffi` 加函数指针成员、在 `@@PLUGIN@@.cpp` 里 `GetDllExport` 取出来、更新 `IsValid()`（缺一个就整体判不可用）。指针类型写 `decltype(&uerust_xxx)`，别手抄 typedef —— Rust 改签名时 C++ 会在编译期报错。
3. 改 C++：编编辑器 target，Mac 上 `"$UE/Engine/Build/BatchFiles/Mac/Build.sh" <项目名>Editor Mac Development -project="<uproject 绝对路径>" -waitmutex`；再 `touch` 改过的 `.cpp` 重编一次，拿到真实编译动作，而不是 up to date。
4. 改了 Rust 必须重新 `uerust build .` 并**重启编辑器**：库是在 `StartupModule` 里 dlopen 的，不重启不会重新加载。
5. 验证：`cargo test` 全绿；编辑器 Output Log 出现 `@@PLUGIN@@: Rust 库就绪 <路径> (版本号)`；蓝图搜 **Fetch Markdown From Url**，接 `OnSuccess` / `OnFail` 跑一次。
6. 文档同步：`README.md`（用法 + 构建步骤）、`docs/API.md`（改了 FFI 就补 C ABI 表与错误语义，函数只增不改旧的）。

## Pitfalls
- 不静态链接：符号全走 `GetDllHandle` / `GetDllExport`，Windows 才不需要 `.dll.lib`；别改成 `PublicAdditionalLibraries`。
- `crate-type` 必须是 `["cdylib"]`；`dylib` 是给 Rust 之间动态链接用的，跨语言边界不行。
- Rust 返回的 `*mut c_char` 必须用配套 free 函数释放（`uerust_free_string`），C++ 侧不能自己 `delete`。
- `reqwest::blocking` 是同步阻塞的，只能在 `Async(EAsyncExecution::ThreadPool, ...)` 里调；线程池回调里不碰任何 UObject，用 `TWeakObjectPtr` 回 GameThread 广播。
- 库必须按 `StagedFileType.NonUFS` staging；打进 `.pak` 后运行时 dlopen 会失败。
- `Binaries/`、`Intermediate/`、`Source/*-dylib/target/` 不进版本库（`.gitignore` 已覆盖），别手滑 `git add -f`。
- 公开头文件里派生 `UUserWidget` 时，`"UMG"` 必须进 Build.cs 的 `PublicDependencyModuleNames`：Engine 私有依赖不传递，只补 include 路径会编译通过但链接失败。
- 无头 / 命令行环境没有 Slate 应用：UI 视觉与真实鼠标键盘只能在 PIE 验证，逻辑要能脱离 Slate 跑（`FSlateApplicationBase::IsInitialized()` 闸门）。
- 在插件目录里打开 VSCode 却没有 Rust 补全/报错：`.vscode/settings.json` 里的 `rust-analyzer.linkedProjects` 被删了或被覆盖了。crate 在 `Source/@@RUST_DIR@@/`，插件根没有 `Cargo.toml`，rust-analyzer 不会自己找到它。别改用「插件根放一个 `Cargo.toml` workspace」的办法：那会把 `target/` 挪到插件根，`uerust build` 找构建产物的路径就对不上了。

## Verification
1. `cd Source/@@RUST_DIR@@ && cargo test` 全绿。
2. `uerust build .` 成功，`Binaries/<平台>/` 下的库文件时间戳是刚才。
3. 编辑器 Output Log 有 `@@PLUGIN@@: Rust 库就绪` 那行，蓝图节点 `OnSuccess` 能拿到结果。
4. 出包前确认 `Build.cs` 里的 `RuntimeDependencies.Add(..., StagedFileType.NonUFS)` 没被改掉。

## 进阶
要加 CI 级别验证（C ABI dlopen 冒烟 / 无头 UE 行为测试），照 `rust-ue-plugin` skill 第 11 步搭 `tools/ffi_smoke/` 与 `tools/ue_headless/`，实测数字写进 `docs/TEST_REPORT.md`。
