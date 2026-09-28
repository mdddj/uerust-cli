# uerust

UE5 ⇄ Rust 插件脚手架。把 `.uplugin`、`Build.cs`、cbindgen 配置、dlopen 样板这些固定步骤收成一条命令。

## 装

```bash
cd ~/dev/uerust-cli
zig build -Doptimize=ReleaseSafe
ln -sf "$PWD/zig-out/bin/uerust" /opt/homebrew/bin/uerust
```

要求 Zig **0.16 或更新**。0.15 及以下编译不过（std API 大改，见下面"Zig 0.16 注意"）。

## 用

```bash
uerust new UEHtml2Md          # → ./UEHtml2Md/
cd UEHtml2Md
uerust build .                # cargo build --release，库拷到 Binaries/Mac/
uerust doctor                 # 环境自检，出问题先跑这个
```

然后把 `UEHtml2Md/` 放进 UE 项目的 `Plugins/` 下，重新生成项目文件、编译。蓝图里搜 **Fetch Markdown From Url**。

`uerust new` 参数：

- `--out <目录>`：生成到别处，默认 `.`
- `--force`：目标目录已存在时也照样写

## uerust doctor

回一个问题：**这台机器现在能不能编译 Rust 写 UE 插件。** 只看机器环境，不看具体项目。

```
Rust
  [OK] cargo            /Users/ldd/.cargo/bin/cargo  (cargo 1.98.0)
  [OK] rustc            rustc 1.98.0
  [OK] rustup shim      13/13 个软链全部可解析
  [OK] PATH             /Users/ldd/.cargo/bin 在 PATH 里
  [ !] cargo 别名      ~/.zshrc 里有 alias cargo=…

Unreal Engine
  [OK] UE_5.8           5.8.3  /Users/Shared/Epic Games/UE_5.8
  [X!] UE_5.7           缺 Engine/Build/Build.version  安装残缺

宿主工具
  [OK] Xcode            Xcode 27.0
  [OK] zig              0.16.0

CI Runner
  [ !] 工具链隔离  actions-runner 共用你的 ~/.cargo 和 ~/.rustup
```

有 `[X!]` 就退出码 1（可进 CI），`[ !]` 只警告。

几项是专门为踩过的坑加的：

- **rustup shim 完整性**：`~/.cargo/bin` 里那批是相对软链，全指向同目录的 `rustup`。
  本体一丢 13 个全断，cargo 从机器上"消失"，但 toolchain 完好 —— 光看 `~/.rustup` 是查不出来的。
- **cargo 别名**：`alias cargo=...` 会盖住真命令，报出来的是 `command not found: mbx` 这种看不懂的错。
- **CI runner 工具链隔离**：本机有 GitHub Actions 自托管 runner 时，它和本地用户共用
  `~/.cargo` / `~/.rustup`，CI 跑 `rustup toolchain install/default` 会直接改你本地工具链。
  检查项读的是**两个真正生效的位置**：`~/actions-runner/.path`（PATH）和 launchd plist
  的 `EnvironmentVariables`（CARGO_HOME / RUSTUP_HOME）。
  ⚠️ `~/actions-runner/.env` 在服务模式下**不被读取**（runsvc.sh 只认 `.path`）——
  只改 `.env` 等于没改，这个坑踩过一次。

## 生成的结构

```
UEHtml2Md/
  UEHtml2Md.uplugin
  README.md                     插件自己的说明
  Source/
    UEHtml2Md/                  C++ 侧
      UEHtml2Md.Build.cs             三平台分支，include 路径 + staging
      Public/UEHtml2Md.h             模块：dlopen + GetDllExport 取函数表
      Private/UEHtml2Md.cpp
      Public/UEHtml2MdLibrary.h      蓝图异步节点
      Private/UEHtml2MdLibrary.cpp
    uehtml2md-dylib/            Rust 侧
      Cargo.toml                     crate-type = ["cdylib"]
      build.rs                       cargo build 时跑 cbindgen
      src/lib.rs                     业务逻辑 + 3 个 no_mangle 导出
      include/UEHtml2Md_ffi.h        cbindgen 产物
  Binaries/Mac/libuehtml2md_dylib.dylib
```

## 和博客那版比，改掉了什么

| 博客 | 这里 | 为什么 |
|---|---|---|
| `crate-type = ["dylib"]` | `["cdylib"]` | `dylib` 是给 Rust 之间动态链接用的，跨语言 ABI 边界必须 `cdylib` |
| 无 free 函数 | `uerust_free_string` | 原来每次调用泄漏一块 Rust 堆内存 |
| `reqwest::blocking` 直接调 | 线程池 + 回主线程广播 | 在 GameThread 上同步联网 = 网络一慢就掉帧 |
| `PublicAdditionalLibraries` 链 dylib | 不链接，全走 `GetDllHandle` | Windows 就不用 `.dll.lib` import 库了，三平台一份逻辑 |
| `include/` 得先手动建 | `build.rs` 里 `create_dir_all` | cbindgen 的 `write_to_file` 不会建父目录，首次 build 会 panic |
| `${PluginDir}` | `$(BinaryOutputDir)` / `PluginDirectory` | UBT 宏写法 |

## Zig 0.16 注意

0.16 的 std 做了 IO 重写，网上绝大多数教程写的都是 0.13/0.14 的 API。这个项目里用到的实际写法：

```zig
// 入口签名变了：不是 pub fn main() !void
pub fn main(init: std.process.Init) !void {
    const io = init.io;                          // 所有文件操作都要显式传它
    const arena = init.arena.allocator();        // 进程级分配器，退出自动清
    var args = init.minimal.args.iterate();      // 不是 std.process.args()
}

// std.fs 废弃了，全在 std.Io 下
const cwd = std.Io.Dir.cwd();
try cwd.createDirPath(io, "a/b");                       // 旧名 makePath
try cwd.writeFile(io, .{ .sub_path = "a/b/c", .data = "..." });
var d = try cwd.openDir(io, "x", .{ .iterate = true }); // 迭代必须显式开
var f = try cwd.openFile(io, "x", .{});

// 打印
var buf: [4096]u8 = undefined;
var w = std.Io.File.stdout().writer(io, &buf);
try w.interface.print("v={d}\n", .{1});

// 起子进程
var child = try std.process.spawn(io, .{ .argv = &argv });
const term = try std.process.Child.wait(&child, io);

// 分配器：GeneralPurposeAllocator 没了，叫 DebugAllocator
var gpa: std.heap.DebugAllocator(.{}) = .init;

// std.ArrayList 现在就是 unmanaged
var list: std.ArrayList(u8) = .empty;
try list.append(gpa, 'x');        // 要传 allocator
```

另外：**多行字符串字面量里不能有真实制表符**（只能空格），编译器会报 `string literal contains invalid byte: '\t'`。

## cargo 定位

`uerust build` 不假设 `~/.cargo/bin/cargo` 能用（rustup 的 shim 断链时它就是个死链）。它按顺序试：

1. `$CARGO_HOME/bin/cargo`
2. `~/.cargo/bin/cargo`
3. `~/.rustup/toolchains/stable-<host-triple>/bin/cargo`
4. 扫 `~/.rustup/toolchains/*/bin/cargo`
5. PATH 里的 `cargo`

每个都是**真的 spawn 一次**来判定可用，不是靠 `access()`。绝对路径的候选会把所在 bin 目录插到子进程 `PATH` 最前面 —— cargo 是靠 PATH 找同目录的 `rustc` 的。

## 改模板

模板全在 `src/templates.zig`，用 `@@PLUGIN@@` / `@@LOWER@@` / `@@UPPER@@` / `@@RUST_DIR@@` / `@@LIB@@` 当占位符。

**故意不用 `std.fmt` 的 `{}`**：模板正文（尤其 `.cs`）里全是花括号，用它得逐个转义成 `{{` `}}`。现在是单趟扫描字符串替换，见 `gen.zig` 的 `render()`。
