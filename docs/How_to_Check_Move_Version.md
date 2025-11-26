# 如何查看 Move 虚拟机版本

## 快速回答

当前 Aptos Core 使用的 Move 字节码版本信息：

- **当前最大版本**: VERSION_9
- **默认编译版本**: VERSION_8
- **最小支持版本**: VERSION_5
- **Move 2.3 默认版本**: VERSION_9

---

## 详细说明

### 1. 字节码格式版本

Move 的版本主要通过 **字节码格式版本号** 来标识，而不是传统的软件版本号（如 v1.2.3）。

#### 版本常量定义位置

**文件**: `third_party/move/move-binary-format/src/file_format_common.rs`

```rust
/// 版本 1: 初始版本
pub const VERSION_1: u32 = 1;

/// 版本 2: 相比版本 1 的变更
/// + 函数可见性存储在单独的字节中
/// + flags 字节现在只包含 is_native 信息
/// + 新增 "friend" 和 "script" 函数可见性修饰符
/// + 模块的 friend 列表
pub const VERSION_2: u32 = 2;

/// 版本 3: 相比版本 2 的变更
/// + phantom 类型参数
pub const VERSION_3: u32 = 3;

/// 版本 4: 相比版本 3 的变更
/// + vector 操作的字节码
pub const VERSION_4: u32 = 4;

/// 版本 5: 相比版本 4 的变更
/// +/- script 和 public(script) 验证现在是适配器特定的
/// + 元数据
pub const VERSION_5: u32 = 5;

/// 版本 6: 相比版本 5 的变更
/// + u16, u32, u256 整数类型
/// + 对应的 Ld, Cast 字节码
pub const VERSION_6: u32 = 6;

/// 版本 7: 相比版本 6 的变更
/// + 访问说明符（读/写集）
/// + 枚举类型
pub const VERSION_7: u32 = 7;

/// 版本 8: 相比版本 7 的变更  ⭐ 当前默认版本
/// + 闭包指令
pub const VERSION_8: u32 = 8;

/// 版本 9: 相比版本 8 的变更  ⭐ 最新版本
/// + 有符号整数
/// + 允许标识符中使用 '$'
pub const VERSION_9: u32 = 9;

// 当前最大版本
pub const VERSION_MAX: u32 = VERSION_9;

// 默认编译版本（编译器默认使用）
pub const VERSION_DEFAULT: u32 = VERSION_8;

// Move 2.0 默认版本
pub const VERSION_DEFAULT_LANG_V2: u32 = VERSION_8;

// Move 2.3 默认版本
pub const VERSION_DEFAULT_LANG_V2_3: u32 = VERSION_9;

// 支持的最低版本
pub const VERSION_MIN: u32 = VERSION_5;

// Aptos 特定的字节码版本掩码
pub const APTOS_BYTECODE_VERSION_MASK: u32 = 0x0A000000;
```

---

## 查看版本的方法

### 方法 1: 查看源代码常量（推荐）

```bash
# 查看字节码版本定义
grep "pub const VERSION" third_party/move/move-binary-format/src/file_format_common.rs

# 输出示例：
# pub const VERSION_1: u32 = 1;
# pub const VERSION_2: u32 = 2;
# ...
# pub const VERSION_MAX: u32 = VERSION_9;
# pub const VERSION_DEFAULT: u32 = VERSION_8;
```

### 方法 2: 查看编译后的模块版本

```bash
# 使用 aptos CLI 查看已部署模块的版本
aptos move view --function-id 0x1::account::create_account --bytecode

# 或者使用 move-disassembler
cargo run -p move-disassembler -- \
    --bytecode <compiled_module.mv> \
    --verbose
```

### 方法 3: 查看 Cargo 包版本

```bash
# 查看 Move binary format 包版本
cat third_party/move/move-binary-format/Cargo.toml | grep version

# 输出:
# version = "0.0.3"
```

**注意**: Cargo 包版本（0.0.3）与字节码格式版本（VERSION_8/9）是不同的概念。

### 方法 4: 检查 Git 历史

```bash
# 查看 Move 相关的最近提交
git log --oneline third_party/move/ | head -10

# 查看特定版本功能的引入
git log --grep="signed integer" --oneline third_party/move/
git log --grep="closure" --oneline third_party/move/
```

### 方法 5: 运行时查询

在 Move 代码中，可以通过编译器特性查询版本：

```move
// Move 2.0+ 支持编译时特性检查
#[cfg(feature = "version_9")]
module example::version_check {
    // 仅在 VERSION_9 下编译
}
```

---

## 版本对照表

| 版本号 | 主要特性 | 引入时间 | 状态 |
|--------|---------|---------|------|
| VERSION_1 | 初始版本 | 最早 | 已淘汰 |
| VERSION_2 | Friend 可见性 | - | 已淘汰 |
| VERSION_3 | Phantom 类型参数 | - | 已淘汰 |
| VERSION_4 | Vector 操作字节码 | - | 已淘汰 |
| VERSION_5 | 元数据支持 | - | ✅ 最低支持 |
| VERSION_6 | u16/u32/u256 类型 | - | ✅ 支持 |
| VERSION_7 | 枚举类型 + 访问说明符 | - | ✅ 支持 |
| VERSION_8 | 闭包指令 | - | ⭐ 当前默认 |
| VERSION_9 | 有符号整数 + $ 标识符 | - | ⭐ 最新版本 |

---

## 不同上下文中的版本

### 1. 编译器默认版本

```bash
# Move 1.0 编译器
VERSION_DEFAULT = VERSION_8

# Move 2.0 编译器
VERSION_DEFAULT_LANG_V2 = VERSION_8

# Move 2.3 编译器
VERSION_DEFAULT_LANG_V2_3 = VERSION_9
```

### 2. VM 运行时支持版本

```rust
// VM 支持的版本范围
VERSION_MIN (5) <= 支持的版本 <= VERSION_MAX (9)
```

### 3. 链上配置版本

链上可能通过治理配置最大支持版本：

```rust
// 从链上配置读取最大版本
let max_version = on_chain_config.max_bytecode_version;
```

---

## 常见问题

### Q1: 为什么有多个 "默认" 版本？

**答**: 不同的编译器版本使用不同的默认字节码版本：

- `VERSION_DEFAULT`: Move 1.0 编译器的默认版本
- `VERSION_DEFAULT_LANG_V2`: Move 2.0 编译器的默认版本
- `VERSION_DEFAULT_LANG_V2_3`: Move 2.3 编译器的默认版本

### Q2: 如何指定编译的目标版本？

**答**: 使用编译器选项：

```bash
# 使用 aptos move compile
aptos move compile --bytecode-version 8

# 或在 Move.toml 中配置
[package]
name = "MyPackage"
version = "1.0.0"
bytecode_version = 8
```

### Q3: VERSION_8 和 VERSION_9 有什么区别？

**答**: 主要区别：

**VERSION_9 新增特性**:
- ✅ 有符号整数类型 (i8, i16, i32, i64, i128, i256)
- ✅ 标识符中允许使用 `$` 字符
- ✅ 相关的新字节码指令

**VERSION_8 特性**:
- ✅ 闭包支持
- ✅ 所有 VERSION_7 及以下的特性

### Q4: 如何知道链上运行的是哪个版本？

**答**: 

```bash
# 方法 1: 查询链上配置
aptos move view \
    --function-id 0x1::version::get_max_bytecode_version

# 方法 2: 查看已部署模块的字节码版本
aptos move download \
    --account 0x1 \
    --module account \
    --output account.mv

# 然后反编译查看版本
move-disassembler --bytecode account.mv
```

### Q5: 不同版本的字节码可以共存吗？

**答**: 可以！VM 支持运行多个版本的字节码：

- ✅ VERSION_5 到 VERSION_9 的字节码都可以在同一个链上运行
- ✅ VM 会根据模块头部的版本号来解析字节码
- ✅ 不同版本的模块可以互相调用（如果接口兼容）

---

## 版本特性详解

### VERSION_9 - 有符号整数 (最新)

```move
module example::signed_integers {
    fun use_signed_ints() {
        let x: i64 = -42;
        let y: i128 = -1000;
        let z: i256 = -999999;
    }
}
```

### VERSION_8 - 闭包 (当前默认)

```move
module example::closures {
    fun use_closures() {
        let f = |x: u64| x + 1;
        let result = f(10); // result = 11
    }
}
```

### VERSION_7 - 枚举类型

```move
module example::enums {
    enum Color {
        Red,
        Green,
        Blue,
    }
    
    fun match_color(c: Color): u64 {
        match (c) {
            Color::Red => 1,
            Color::Green => 2,
            Color::Blue => 3,
        }
    }
}
```

### VERSION_6 - 扩展整数类型

```move
module example::extended_ints {
    fun use_u256() {
        let large: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
        let small: u16 = 65535;
    }
}
```

---

## 版本升级检查清单

在升级到新版本之前，检查：

- [ ] 新版本引入了哪些新特性？
- [ ] 是否有破坏性变更？
- [ ] 现有代码是否兼容？
- [ ] Gas 成本是否有变化？
- [ ] 测试网是否已验证？
- [ ] 链上治理是否已批准？

---

## 快速查看命令

```bash
# 1. 查看当前默认版本
grep "VERSION_DEFAULT" \
    third_party/move/move-binary-format/src/file_format_common.rs

# 2. 查看最大支持版本
grep "VERSION_MAX" \
    third_party/move/move-binary-format/src/file_format_common.rs

# 3. 查看版本变更历史
git log --oneline --grep="VERSION" \
    third_party/move/move-binary-format/src/file_format_common.rs

# 4. 检查所有版本常量
grep "pub const VERSION_[0-9]" \
    third_party/move/move-binary-format/src/file_format_common.rs
```

---

## 参考资料

- **Move 字节码规范**: `third_party/move/move-binary-format/src/file_format.rs`
- **版本常量定义**: `third_party/move/move-binary-format/src/file_format_common.rs`
- **Move 语言文档**: https://move-language.github.io/move/
- **Aptos Move 文档**: https://aptos.dev/move/move-on-aptos/

---

*最后更新: 2025-11-06*
