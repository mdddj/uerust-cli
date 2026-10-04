---
name: generated-agent-skills
description: uerust new 会往插件目录里生成两个 .agent/skills；正文在 src/skills/，用 @embedFile 嵌进二进制。
type: decision
---

## Why

`uerust new` 除了 `.uplugin` / C++ / Rust crate，还要带出两个 skill，放在输出目录（插件根，通常就是它自己的 git 仓库根）下的 `.agent/skills/`：

- `rust-ue-plugin` —— 通用「Rust 核心 + UE5 插件」流程（14 步 + 坑清单 + 验收）
- `<插件小写名>-plugin` —— 这个插件自己的维护手册（分层地图、uerust build、FFI 两侧同步、验证、不变量）

omp 的 agents provider 按 `<项目根>/.agent[s]/skills/<名字>/SKILL.md` 发现 skill，**不递归**（`omp://skills.md`）。
目录名必须等于 frontmatter 的 `name`；这两个 skill 是给「在插件目录里开工的 agent」用的，
要让它们覆盖整个 UE 项目，得把 `.agent/` 拷到项目根。

## How to apply

- 正文不写进 Zig 字符串：`src/skills/rust-ue-plugin/SKILL.md`（全局 skill 的逐字快照）、
  `src/skills/plugin-manual/SKILL.md`（模板，占位符照旧 `@@PLUGIN@@` / `@@LOWER@@` / `@@RUST_DIR@@` / `@@LIB@@`）；
  `src/templates.zig` 里 `@embedFile("skills/...")` 引用。
- 全局 skill 更新后同步快照：
  `cp ~/.pi/agent/pi-hermes-memory/skills/rust-ue-plugin/SKILL.md src/skills/rust-ue-plugin/SKILL.md`
- 文档四处同步（原三处 + 生成物 README）：
  根 `README.md` 的「生成的结构 / 生成出来的 skill / 改模板」、
  `src/templates.zig` 的 `plugin_readme`、`src/gen.zig` 结尾的「下一步」打印。
- 本机 Zig 是 0.17，`Build` 结构体没有 `args` 字段了；`build.zig` 用
  `if (comptime @hasField(std.Build, "args"))` 兼容 0.16/0.17（0.17 上 `zig build run` 不转发参数）。

## Related

[[ue-plugin-registration]]
