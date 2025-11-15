# Rustfmt 工具链配置说明

## 问题描述

在 aptos-core 项目中，`rustfmt.toml` 使用了一些不稳定版本才支持的配置项，但 `rust-toolchain.toml` 指定的是稳定版本（1.89.0）。直接运行 `cargo fmt` 会报错。

## 为什么这样设计？

这是一种常见且推荐的 Rust 项目配置模式，将不同的工具职责分离：

### 1. 稳定工具链用于编译

**文件**: `rust-toolchain.toml`

```toml
[toolchain]
channel = "1.89.0"

# 注意：我们没有在工具链中指定 rustfmt，因为我们依赖 nightly 版本的 rustfmt
# 并在 CI/CD 中验证格式
components = ["cargo", "clippy", "rustc", "rust-docs", "rust-std"]
```

**作用**:
- 保证所有开发者使用相同的稳定 Rust 版本编译代码
- 确保编译行为的一致性和可预测性
- 避免 nightly 版本不稳定导致的编译问题

### 2. Nightly Rustfmt 用于格式化

**文件**: `rustfmt.toml`

```toml
combine_control_expr = false
edition = "2024"
style_edition = "2021"
imports_granularity = "Crate"      # 需要 nightly
format_macro_matchers = true       # 需要 nightly
group_imports = "One"              # 需要 nightly
hex_literal_case = "Upper"
match_block_trailing_comma = true
newline_style = "Unix"
overflow_delimited_expr = true
reorder_impl_items = true          # 需要 nightly
use_field_init_shorthand = true
```

**作用**:
- 使用更先进的格式化选项
- rustfmt 的不稳定特性只影响代码格式，不影响编译后的二进制文件
- 可以安全地使用 nightly rustfmt 而不影响代码稳定性

## 关键理解

**Rustfmt 的不稳定特性是安全的**：
- Rustfmt 只改变代码的格式（空格、换行、导入顺序等）
- 不影响代码的语义和编译后的结果
- 即使 nightly rustfmt 有 bug，最坏的情况也只是格式不理想，不会导致代码无法编译或运行错误

**编译的稳定性至关重要**：
- 编译器的不稳定版本可能产生不同的二进制代码
- 可能有未发现的 bug 导致编译失败或运行时错误
- 因此生产环境必须使用稳定版本编译

## 正确使用方式

### 格式化代码（使用 nightly）

```bash
# 检查格式
cargo +nightly fmt --check

# 自动格式化
cargo +nightly fmt
```

### 编译和测试（使用稳定版本）

```bash
# 正常编译（自动使用 rust-toolchain.toml 指定的版本）
cargo build

# 运行测试
cargo test

# 运行 clippy
cargo clippy
```

## 首次安装 Nightly Rustfmt

如果遇到 `'cargo-fmt' is not installed` 错误，需要安装 nightly rustfmt：

```bash
# 安装 nightly 工具链的 rustfmt 组件
rustup component add --toolchain nightly rustfmt
```

## CI/CD 配置

在持续集成环境中，项目会：

1. 使用 nightly rustfmt 检查代码格式
2. 使用稳定版本（1.89.0）编译和测试
3. 确保两者都通过才能合并代码

## 总结

| 工具 | 版本 | 用途 | 稳定性要求 |
|------|------|------|-----------|
| rustc | 1.89.0 (stable) | 编译代码 | ⚠️ 关键 - 必须稳定 |
| cargo | 1.89.0 (stable) | 构建管理 | ⚠️ 关键 - 必须稳定 |
| clippy | 1.89.0 (stable) | 代码检查 | ⚠️ 关键 - 必须稳定 |
| rustfmt | nightly | 代码格式化 | ✅ 安全 - 可用 nightly |

这种配置方式：
- ✅ 保证编译的稳定性和一致性
- ✅ 提供最佳的代码格式化体验
- ✅ 是 Rust 社区的最佳实践
- ✅ 被广泛应用于大型 Rust 项目中

## 参考

- [Rustfmt Unstable Features](https://rust-lang.github.io/rustfmt/?version=master)
- [Rustup Toolchain Override](https://rust-lang.github.io/rustup/overrides.html)
