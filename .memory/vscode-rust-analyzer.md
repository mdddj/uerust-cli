---
name: vscode-rust-analyzer
description: 生成的插件带 .vscode/settings.json，用 rust-analyzer.linkedProjects 指到嵌套 crate；不要用插件根 Cargo.toml workspace。
type: decision
---

## Why

插件根没有 `Cargo.toml`（crate 在 `Source/<小写名>-dylib/`），而 rust-analyzer 只在**打开的工作区根目录**
找 `Cargo.toml`。于是在插件目录里打开 VSCode 时 Rust 文件没有补全、没有错误提示，用户得单独进
`Source/<小写名>-dylib/` 再开一个窗口才正常。

## How to apply

- 生成物带 `.vscode/settings.json`：`"rust-analyzer.linkedProjects": ["Source/<rust_dir>/Cargo.toml"]`
  （JSONC，路径相对插件根）。不要动成「插件根放一个 `Cargo.toml` workspace」——
  cargo workspace 会把 `target/` 挪到插件根，而 `uerust build`（`src/cargo.zig:97`）是去
  `<plugin>/Source/<rust_dir>/target/release/` 找产物的（用的是 `--manifest-path`），路径立刻对不上。
- 文档同步四处：根 README「生成的结构」+ 结构树下的说明、`src/templates.zig` 的 `plugin_readme`
  （「在 VSCode 里开发」一节）、`src/gen.zig`「下一步」第 6 条、
  `src/skills/plugin-manual/SKILL.md` 的 Pitfalls。

## Related

[[generated-agent-skills]]
