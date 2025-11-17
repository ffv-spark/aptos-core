# 多框架库升级 - 快速开始

## 🚀 30秒快速开始

```bash
# 1. 生成升级脚本
./upgrade-framework.sh all

# 2. 提交提案
export POOL_ADDRESS=0x你的质押池地址
./upgrade-framework.sh submit

# 3. 投票
aptos governance vote --proposal-id <ID> --should-pass true
```

**完成！** 提案通过后会自动升级所有框架。

---

## 📁 重要文件

| 文件 | 用途 |
|------|------|
| `framework-upgrade-config.yaml` | 升级配置（修改这个文件来定制升级）|
| `upgrade-framework.sh` | 自动化脚本（一键执行所有步骤）|
| `FRAMEWORK_UPGRADE_GUIDE.md` | 完整操作指南 |
| `FEATURE_FLAGS_REFERENCE.md` | 所有 150+ feature flags 列表 |
| `FEATURE_FLAG_MAPPING.md` | 命名映射规则（Move→Rust→YAML）|
| `list-available-features.sh` | 列出所有可用 features（YAML 格式）|

---

## ❓ 常见问题快速解答

### Q1: YAML 中应该写什么格式的 feature flag？

**A: 使用 snake_case 格式！**

```yaml
# ✅ 正确
enabled:
  - code_dependency_check
  - module_event
  - vm_binary_format_v8

# ❌ 错误
enabled:
  - CODE_DEPENDENCY_CHECK  # Move 常量名
  - ModuleEvent            # Rust 枚举名
```

**快速获取列表**：
```bash
./list-available-features.sh
```

---

### Q2: 如何查看所有可用的 feature flags？

**方法 1**：运行脚本
```bash
./list-available-features.sh
```

**方法 2**：查看文档
```bash
cat FEATURE_FLAGS_REFERENCE.md
```

**方法 3**：查看源码
```bash
cat aptos-move/aptos-release-builder/src/components/feature_flags.rs
```

---

### Q3: 升级会不会影响现有合约？

**A: 不会！**
- ✅ 现有合约继续正常运行
- ✅ 只有新部署的合约使用新字节码
- ✅ Feature flags 只影响启用后的新行为

---

### Q4: Gas 限制会不会不够？

**A: 不需要担心！**

Aptos 有两套 gas 限制：
- 普通交易：2B gas
- 治理交易：20B gas（**自动使用**）

治理提案**自动**使用高限制，无需手动调整。

---

### Q5: 如何验证升级成功？

```bash
# 查看提案状态
aptos governance show-proposal --proposal-id <ID>

# 查看 feature flags
curl https://fullnode.testnet.aptoslabs.com/v1/accounts/0x1/resource/0x1::features::Features
```

---

## 🎯 命名转换速查表

| Move 常量 | Rust 枚举 | YAML 配置 |
|-----------|-----------|-----------|
| `CODE_DEPENDENCY_CHECK` | `CodeDependencyCheck` | `code_dependency_check` ✅ |
| `MODULE_EVENT` | `ModuleEvent` | `module_event` ✅ |
| `VM_BINARY_FORMAT_V8` | `VMBinaryFormatV8` | `vm_binary_format_v8` ✅ |
| `BLS12_381_STRUCTURES` | `Bls12381Structures` | `bls12381_structures` ✅ |

**记住**：YAML 中永远使用 **snake_case**！

---

## 📝 修改配置示例

编辑 `framework-upgrade-config.yaml`：

```yaml
update_sequence:
  - Framework:
      bytecode_version: 8  # 修改字节码版本

  - FeatureFlag:
      enabled:
        # 添加你需要的 features（从 list-available-features.sh 复制）
        - code_dependency_check
        - module_event
        - vm_binary_format_v8

      disabled:
        # 禁用不需要的 features
        - collect_and_distribute_gas_fees
```

---

## 🔧 分步执行

```bash
# 只构建工具
./upgrade-framework.sh build

# 只生成脚本
./upgrade-framework.sh generate

# 只模拟验证
./upgrade-framework.sh simulate

# 只提交提案
POOL_ADDRESS=0x123 ./upgrade-framework.sh submit
```

---

## 📚 详细文档

需要更多信息？查看：

1. **操作指南**：`FRAMEWORK_UPGRADE_GUIDE.md`
2. **Feature 列表**：`FEATURE_FLAGS_REFERENCE.md`
3. **命名规则**：`FEATURE_FLAG_MAPPING.md`

---

## ⚠️ 重要提醒

1. ✅ **总是先在测试网测试**
2. ✅ **仔细检查生成的脚本**
3. ✅ **确保有足够的投票权重**
4. ✅ **与社区充分沟通**

---

## 🎉 就这么简单！

三条命令完成多框架库升级：

```bash
./upgrade-framework.sh all
POOL_ADDRESS=0x你的地址 ./upgrade-framework.sh submit
aptos governance vote --proposal-id <ID> --should-pass true
```

有问题？查看详细文档或运行 `./upgrade-framework.sh help`
