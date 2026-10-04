---
name: "rust-ue-plugin"
description: "制作「Rust 核心 + UE5 插件」（uerust / cdylib / cbindgen / dlopen）时用：分层设计、FFI 约定、友好层封装、零资产最小示例、三层可复跑验证。"
version: 1
created: "2026-10-04"
updated: "2026-10-04"
---
## When to Use
当用户要写 UE5 插件且核心逻辑用 Rust 实现（uerust 脚手架、cdylib + C ABI + dlopen），或要把算法/状态机（背包、网格、寻路、战斗结算、序列化）用 Rust 写进 UE 项目时用。也适用于给已有 uerust 插件加功能层（DataAsset 内容层、组件宿主、UMG 界面）。边界：纯蓝图/纯 C++ 插件、纯编辑器工具不适用。

## Procedure
1. 骨架：uerust new <PluginName> --out <项目>/Plugins（产出 .uplugin + Source/<Name> C++ 模块 + Source/<name>-dylib Rust cdylib + cbindgen build.rs）。改完 Rust 必须跑 uerust build <插件目录>（cargo build --release + 拷到 Binaries/<平台>/，否则编辑器 dlopen 失败）。
2. Rust crate：crate-type = ["cdylib", "rlib"]（rlib 供 tests/benches 链接）；依赖保持精简；[profile.release] lto = true。
3. 分层：core（纯逻辑，正常 Rust 类型）→ algo（可选）→ ffi（薄壳，只做类型转换与错误映射）。core 里禁止裸指针 / Rc<RefCell> / 跨结构体借用；一律 ID 间接寻址（slotmap 之类）；错误用 thiserror 枚举 + 稳定错误码（只增不改）；core 不用 panic 表达失败。
4. FFI 约定一次定死并写进 docs/API.md：i32 = 0 成功 / 正数错误码；i64 = ≥0 结果（句柄、计数）/ <0 = -错误码；句柄用 u64（0 = 无，活跃 key 永不为 0）；数组两段式（cap=0 先查数量，缓冲不足返回 BufferTooSmall）；Rust 分配的字符串/字节配 free 函数；每个入口 catch_unwind 拦住 panic + 线程本地 last_error；句柄按单线程使用并写明。
5. ABI 单一事实来源：cbindgen 生成 include/*.h；C++ 侧函数指针类型一律用 decltype(&uerust_xxx)，Rust 改签名 → C++ 编译期报错，免手抄 typedef。验证：nm -gU <dylib> | grep <前缀> 数符号。
6. UE 低层桥接：模块 StartupModule 里 IPluginManager → Binaries/<平台>/<库名> → GetDllHandle → GetDllExport；再加一个 UObject 句柄类（UPROPERTY 持裸指针，BeginDestroy 调 free 函数），蓝图用 Create Xxx 拿。
7. 友好层（必须交付，别只给裸句柄）：内容定义=UDataAsset 子类（名称/描述/图标/数值/规则字段，子类化即扩展）；宿主=UActorComponent（一个组件=一个实例：自动建/释放句柄、注册内容、暴露操作与查询节点、bReady + 中文日志）；视图=USTRUCT（句柄+定义+实例状态拼好，UI 直接遍历）；批量内容=FTableRowBase 行结构 + DataTable（可直接 Import JSON/CSV）。
8. 注册顺序=存档键：DefId 由注册顺序决定 → 注册前按资产名/行名等**稳定键排序**，使 DefId 与“数组摆放顺序”无关；把「行名/资产名 = 逻辑名，改名 = 撕存档」写进头注释；注册前夹取越界字段（否则一次失败会让后面所有 DefId 前移）。
9. 最小使用示例（必须交付且零资产可跑）：一个可拖进关卡、Play 就有可见效果（屏幕/日志输出网格或结果）的演示 Actor，内置示例数据；README 写「5 分钟看到效果」+ 三行接入（Create Widget / 组件挂载）；UI 做成纯 C++、零资产依赖（缺图标画占位、字体用引擎默认），别要求用户先做美术资产。
10. UI 层：自绘 + 可测状态机；交互拆成 BlueprintPure 纯函数（坐标↔格子、落点计算）与可驱动函数（BeginDragAtItem / UpdateDragCursor / DropOnThisGrid / CancelDrag），鼠标键盘事件只做搬运；Slate 相关操作用 FSlateApplicationBase::IsInitialized() 闸门，保证无头环境只跑数据与状态机。
11. 验证三层都要，且要能一条命令复跑：① Rust cargo test（单元+集成+proptest）+ cargo bench 定性能门禁 + cargo llvm-cov ≥85% 行覆盖；② 独立 C 程序 dlopen 真实 dylib 跑 ABI 冒烟（tools/ffi_smoke）；③ UE 无头命令集行为测试（UnrealEditor-Cmd <proj> -run=pythonscript -script=... -EnablePlugins=PythonScriptPlugin -unattended -nosplash），脚本放 tools/ue_headless/ + run.sh 全跑。
12. 每次改动后的固定动作：Build.sh <Target> <Platform> Development -project=<uproject> -waitmutex → touch 改动过的 .cpp 强制重编译（拿“真的编译过”的证据，而不是 up to date）→ 跑全部套件 → 把实测数字写进 docs/TEST_REPORT.md。
13. 交付三件套：README（构建步骤 + 最快示例 + 常用操作表）、docs/API.md（分层图、错误码表、C ABI 表、友好层与 UI 节点、性能指标）、docs/TEST_REPORT.md（实测数字 + 已知边界）。
14. 提交前自检：git status --porcelain --untracked-files=all 无意外项；git check-ignore -v 核对 target/ Binaries/ Intermediate/ 与测试产物都被忽略；确认远端仓库可见性（PUBLIC/PRIVATE）符合预期。

## Pitfalls
- UMG 是 Engine 的私有依赖、不传递：公开头文件里派生 UUserWidget 时，必须把 "UMG" 加进 Build.cs 的 PublicDependencyModuleNames；只补 include 路径会编译过、链接失败。
- 无头命令集没有 Slate 应用与视口：Slate 构造、绘制、真实鼠标键盘只能在 PIE 肉眼验证 —— 代码里必须做闸门，别把「无头测试通过」当成「视觉效果没问题」。
- 快照/网络包不含内容定义：DefId = 注册顺序，恢复前必须按同样顺序注册同一批定义；这条要同时写进 API 文档、函数注释和错误码（CorruptSnapshot）。
- 多对象几何判定：两个“新落点”是否互相重叠，不能用“剔除忽略项后的占用掩码”推出来（本次真实 bug：位图分支漏检，debug 断言炸、release 静默写坏不变式）。涉及多对象时单独判交，并写等价性测试（快路径 vs 参考实现逐组合比对）。
- 加速路径要有阈值与回退：例如 ≤64 格用 u64 位图、更大走逐格扫描；两条路径必须语义一致，且用参数化测试锁住（尺寸、旋转、忽略项三种维度）。
- 原子性用“验证先行”实现：校验阶段只读（越界/重叠/规则/引用），提交阶段调用“不可能失败”的内部写入（place_validated 这类）；失败零副作用的断言方式 = 操作前后序列化字节完全一致。
- 不要留 demo 资产/临时脚本：验证脚本放 tools/ 并入库，生成物（*_out.txt、构建目录）进 .gitignore；演示用 Actor 在头文件里注明“示例，可删”。
- 子代理并行改代码时坚持单写者：一组文件只有一个代理改，测试/文档/UI 分片；否则合并冲突与半成品树（编译不过）难以收拾。

## Verification
1. ./tools/ffi_smoke/run.sh 通过：真实 dylib dlopen 成功、自检报告 0 失败、手动驱动返回码正确、last_error 文本可读。
2. ./tools/ue_headless/run.sh 全部套件 pass/0 fail；且每次改动后 touch+Build.sh 显示真实编译动作（不是 up to date）。
3. Rust：cargo test 全绿、cargo bench 性能门禁达标（如单次查询 ≤500ns）、cargo llvm-cov --summary-only 行覆盖 ≥85%。
4. 零资产示例可用：把演示 Actor 拖进新关卡 Play，屏幕/日志输出与文档描述一致；没有图标资产也不报错。
5. 仓库状态干净：git status --porcelain 无输出；git check-ignore -v 覆盖 target/、Binaries/、Intermediate/、测试产物。