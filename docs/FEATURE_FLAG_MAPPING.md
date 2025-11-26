# Feature Flag 命名映射完全指南

## 🎯 核心问题：YAML 中应该写什么？

当你在代码中定义了一个新的 Feature Flag，在 YAML 配置文件中应该写**Rust 枚举的 snake_case 形式**。

---

## 📊 三层命名映射关系

每个 Feature Flag 在三个地方有不同的命名：

```
Move 定义 (SCREAMING_SNAKE_CASE)
    ↓
Rust 枚举 (PascalCase)
    ↓ [serde 自动转换]
YAML 配置 (snake_case) ← 这是你要写的！
```

---

## 🔍 完整映射示例

### 示例 1：`CODE_DEPENDENCY_CHECK`

| 层级 | 文件位置 | 命名 | 说明 |
|------|---------|------|------|
| **Move 定义** | `move-stdlib/sources/configs/features.move:41` | `CODE_DEPENDENCY_CHECK: u64 = 1` | 常量定义 |
| **Rust 枚举** | `aptos-release-builder/src/components/feature_flags.rs:55` | `CodeDependencyCheck` | 枚举变体 |
| **YAML 配置** | `framework-upgrade-config.yaml` | `code_dependency_check` | ✅ 你要写的 |

**YAML 中写法**：
```yaml
enabled:
  - code_dependency_check  # ✅ 正确
```

**错误写法**：
```yaml
enabled:
  - CODE_DEPENDENCY_CHECK  # ❌ 错误（Move 常量名）
  - CodeDependencyCheck    # ❌ 错误（Rust 枚举名）
```

---

### 示例 2：`MODULE_EVENT`

| 层级 | 命名 |
|------|------|
| Move 定义 | `const MODULE_EVENT: u64 = 26;` |
| Rust 枚举 | `ModuleEvent` |
| YAML 配置 | `module_event` ✅ |

```yaml
enabled:
  - module_event  # ✅ 正确
```

---

### 示例 3：`VM_BINARY_FORMAT_V6`

| 层级 | 命名 |
|------|------|
| Move 定义 | `const VM_BINARY_FORMAT_V6: u64 = 5;` |
| Rust 枚举 | `VMBinaryFormatV6` |
| YAML 配置 | `vm_binary_format_v6` ✅ |

```yaml
enabled:
  - vm_binary_format_v6  # ✅ 正确
```

---

### 示例 4：`BLS12_381_STRUCTURES`

| 层级 | 命名 |
|------|------|
| Move 定义 | `const BLS12_381_STRUCTURES: u64 = 13;` |
| Rust 枚举 | `Bls12381Structures` |
| YAML 配置 | `bls12381_structures` ✅ |

```yaml
enabled:
  - bls12381_structures  # ✅ 正确
```

---

## 🔄 命名转换规则

### 从 Move 常量 → YAML 配置

1. **Move 常量**：`SCREAMING_SNAKE_CASE`
2. **转换步骤**：
   - 去掉下划线
   - 转为小写
   - 每个单词首字母大写（得到 PascalCase）
   - 再转回 snake_case

**示例**：
```
Move:     MODULE_EVENT_MIGRATION
         ↓
PascalCase: ModuleEventMigration (Rust 枚举)
         ↓
snake_case: module_event_migration (YAML 配置)
```

### 从 Rust 枚举 → YAML 配置

这个更简单，直接用工具转换：

```bash
# 在项目根目录执行
python3 << 'EOF'
import re

def pascal_to_snake(name):
    # 处理连续大写字母（如 VM, API）
    s1 = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
    # 处理大写字母后跟小写字母
    s2 = re.sub('([a-z0-9])([A-Z])', r'\1_\2', s1)
    return s2.lower()

# 测试转换
test_cases = [
    "CodeDependencyCheck",
    "VMBinaryFormatV6",
    "Bls12381Structures",
    "ModuleEventMigration",
]

for case in test_cases:
    print(f"{case:40} -> {pascal_to_snake(case)}")
EOF
```

**输出**：
```
CodeDependencyCheck                      -> code_dependency_check
VMBinaryFormatV6                         -> vm_binary_format_v6
Bls12381Structures                       -> bls12381_structures
ModuleEventMigration                     -> module_event_migration
```

---

## 📝 实际操作步骤

### 场景：你想启用某个 Feature

**步骤 1**：找到 Rust 枚举名称

```bash
grep -n "pub enum FeatureFlag" -A 200 \
  aptos-move/aptos-release-builder/src/components/feature_flags.rs | \
  grep -E "^\s+[A-Z]"
```

**输出示例**：
```rust
CodeDependencyCheck,
ModuleEvent,
VMBinaryFormatV8,
Bls12381Structures,
...
```

**步骤 2**：转换为 snake_case

手动转换或使用工具：
- `CodeDependencyCheck` → `code_dependency_check`
- `ModuleEvent` → `module_event`
- `VMBinaryFormatV8` → `vm_binary_format_v8`
- `Bls12381Structures` → `bls12381_structures`

**步骤 3**：写入 YAML

```yaml
- FeatureFlag:
    enabled:
      - code_dependency_check
      - module_event
      - vm_binary_format_v8
      - bls12381_structures
```

---

## 🛠️ 快速查找工具

### 工具 1：列出所有可用的 YAML 名称

```bash
cd /home/user/aptos-core

# 提取 Rust 枚举并转换为 snake_case
grep -A 200 "pub enum FeatureFlag {" \
  aptos-move/aptos-release-builder/src/components/feature_flags.rs | \
  grep -E "^\s+[A-Z][a-zA-Z0-9]+" | \
  sed 's/,//g' | \
  awk '{print $1}' | \
  python3 -c "
import sys, re
for line in sys.stdin:
    name = line.strip()
    if name:
        s1 = re.sub('(.)([A-Z][a-z]+)', r'\1_\2', name)
        s2 = re.sub('([a-z0-9])([A-Z])', r'\1_\2', s1)
        print('  - ' + s2.lower())
"
```

这会输出所有可用的 YAML 格式的 feature flags：
```yaml
  - code_dependency_check
  - collect_and_distribute_gas_fees
  - treat_friend_as_private
  - sha512_and_ripe_md160_natives
  ...
```

### 工具 2：验证 YAML 中的名称是否正确

```bash
# 检查你的 YAML 配置
cat framework-upgrade-config.yaml | grep -E "^\s+- [a-z_]+" | while read -r line; do
  feature=$(echo "$line" | sed 's/^\s*- //')
  echo "检查: $feature"

  # 在 Rust 源码中查找对应的枚举
  if grep -q "$(echo $feature | python3 -c "
import sys, re
s = sys.stdin.read().strip()
print(''.join(word.capitalize() for word in s.split('_')))
")" aptos-move/aptos-release-builder/src/components/feature_flags.rs; then
    echo "  ✅ 有效"
  else
    echo "  ❌ 无效 - 未找到对应的枚举"
  fi
done
```

---

## 📋 常见错误

### ❌ 错误 1：使用 Move 常量名

```yaml
# 错误
enabled:
  - MODULE_EVENT  # ❌ 这是 Move 常量名

# 正确
enabled:
  - module_event  # ✅ snake_case
```

### ❌ 错误 2：使用 Rust 枚举名

```yaml
# 错误
enabled:
  - ModuleEvent  # ❌ 这是 Rust 枚举名

# 正确
enabled:
  - module_event  # ✅ snake_case
```

### ❌ 错误 3：拼写错误

```yaml
# 错误
enabled:
  - module_events  # ❌ 多了个 's'
  - module-event   # ❌ 用了连字符
  - moduleEvent    # ❌ 用了驼峰命名

# 正确
enabled:
  - module_event   # ✅ 下划线分隔的小写
```

---

## 🎯 完整示例配置

```yaml
---
remote_endpoint: https://fullnode.testnet.aptoslabs.com
name: "my-upgrade"

proposals:
  - name: upgrade
    execution_mode: MultiStep
    update_sequence:
      - Framework:
          bytecode_version: 8

      - FeatureFlag:
          enabled:
            # 从 Move: CODE_DEPENDENCY_CHECK
            # 从 Rust: CodeDependencyCheck
            - code_dependency_check  # ✅ YAML 中写这个

            # 从 Move: MODULE_EVENT
            # 从 Rust: ModuleEvent
            - module_event  # ✅ YAML 中写这个

            # 从 Move: VM_BINARY_FORMAT_V8
            # 从 Rust: VMBinaryFormatV8
            - vm_binary_format_v8  # ✅ YAML 中写这个

            # 从 Move: BLS12_381_STRUCTURES
            # 从 Rust: Bls12381Structures
            - bls12381_structures  # ✅ YAML 中写这个

          disabled: []
```

---

## 🔍 技术原理

### Serde 自动转换

在 Rust 代码中有这个注解：

```rust
#[derive(Clone, Debug, Deserialize, EnumIter, PartialEq, Eq, Serialize, Hash)]
#[serde(rename_all = "snake_case")]  // ← 这里！
pub enum FeatureFlag {
    CodeDependencyCheck,     // 枚举是 PascalCase
    ModuleEvent,
    VMBinaryFormatV8,
}
```

`#[serde(rename_all = "snake_case")]` 告诉 serde：
- **序列化**时：`CodeDependencyCheck` → `"code_dependency_check"`
- **反序列化**时：`"code_dependency_check"` → `CodeDependencyCheck`

所以在 YAML 中必须写 snake_case 形式。

---

## 📚 参考资料

### 相关文件
1. **Move 定义**：`aptos-move/framework/move-stdlib/sources/configs/features.move`
2. **Rust 枚举**：`aptos-move/aptos-release-builder/src/components/feature_flags.rs`
3. **YAML 示例**：`framework-upgrade-config.yaml`
4. **完整列表**：`FEATURE_FLAGS_REFERENCE.md`

### 查看命令
```bash
# 查看 Move 定义
grep "const.*: u64" aptos-move/framework/move-stdlib/sources/configs/features.move

# 查看 Rust 枚举
grep -A 200 "pub enum FeatureFlag" \
  aptos-move/aptos-release-builder/src/components/feature_flags.rs

# 查看实际使用示例
cat aptos-move/aptos-release-builder/data/release.yaml
```

---

## ✅ 快速记忆法

**简单规则**：
1. 看 Rust 枚举名（PascalCase）
2. 把每个大写字母前加下划线
3. 全部转小写
4. 写入 YAML

**示例**：
- `ModuleEvent` → `module_event`
- `VMBinaryFormatV8` → `v_m_binary_format_v8` → `vm_binary_format_v8`（去掉多余下划线）

**最简单的方法**：
直接复制 `FEATURE_FLAGS_REFERENCE.md` 中的名称！所有名称都已经是正确的 snake_case 格式了。

---

## 🎉 总结

**你要在 YAML 中写的是：Rust 枚举的 snake_case 形式**

```
Move 常量名    ❌ 不要用
Rust 枚举名    ❌ 不要用
snake_case    ✅ 就是这个！
```

直接参考 `FEATURE_FLAGS_REFERENCE.md` 复制粘贴即可！
