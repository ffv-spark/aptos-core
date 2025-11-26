# Aptos 多框架库升级完整指南

本指南将帮助你一次性升级 `move-stdlib`、`aptos-stdlib`、`aptos-framework` 并同时启用新的 feature flags。

## 📋 前置要求

1. **已安装工具**：
   - Rust 和 Cargo
   - Git
   - Aptos CLI（脚本会自动安装）

2. **权限要求**：
   - 拥有质押池地址（用于提交治理提案）
   - 有足够的投票权重

## 🚀 快速开始（3 步完成）

### 第 1 步：修改配置文件

编辑 `framework-upgrade-config.yaml`，根据你的需求调整：

```yaml
# 1. 选择网络
remote_endpoint: https://fullnode.testnet.aptoslabs.com  # 或 mainnet

# 2. 设置版本号
name: "multi-framework-upgrade-v1.0"

# 3. 选择要启用的 features
update_sequence:
  - Framework:
      bytecode_version: 8  # 根据实际需要调整
  - FeatureFlag:
      enabled:
        - code_dependency_check  # 根据实际需要添加/删除
        - resource_groups
        # ... 更多 features
```

**常用 Feature Flags**：
- `code_dependency_check` - 代码依赖检查
- `treat_friend_as_private` - 将 friend 视为 private
- `resource_groups` - 资源组
- `multisig_accounts` - 多签账户
- `delegation_pools` - 委托池

查看所有可用 features：
```bash
grep -r "pub const" aptos-move/framework/aptos-framework/sources/configs/features.move
```

### 第 2 步：执行升级脚本

```bash
# 完整流程：构建 + 生成 + 验证
./upgrade-framework.sh all
```

这将：
1. ✅ 构建 `aptos-release-builder` 工具
2. ✅ 生成升级脚本到 `./framework-upgrade-output/sources/`
3. ✅ 在测试网上模拟验证

### 第 3 步：提交和投票

```bash
# 设置你的质押池地址
export POOL_ADDRESS=0x你的质押池地址

# 提交提案
./upgrade-framework.sh submit

# 查看提案
aptos governance list-proposals

# 投票（假设提案 ID 是 42）
aptos governance vote \
  --proposal-id 42 \
  --pool-address $POOL_ADDRESS \
  --should-pass true
```

**完成！** 提案通过后会自动执行所有升级步骤。

---

## 🔧 高级用法

### 分步执行

```bash
# 1. 仅构建工具
./upgrade-framework.sh build

# 2. 仅生成脚本
./upgrade-framework.sh generate

# 3. 仅模拟验证
./upgrade-framework.sh simulate

# 4. 仅提交提案
POOL_ADDRESS=0x123 ./upgrade-framework.sh submit
```

### 自定义配置

```bash
# 使用自定义配置文件
RELEASE_CONFIG=my-custom-config.yaml ./upgrade-framework.sh all

# 指定输出目录
OUTPUT_DIR=./my-output ./upgrade-framework.sh all

# 针对主网
NETWORK=mainnet RELEASE_CONFIG=mainnet-config.yaml ./upgrade-framework.sh all
```

### 查看生成的脚本

```bash
ls -lh ./framework-upgrade-output/sources/

# 输出示例：
# 0-move-stdlib.move        - 升级 move-stdlib
# 1-aptos-stdlib.move       - 升级 aptos-stdlib
# 2-aptos-framework.move    - 升级 aptos-framework
# 3-features.move           - 启用 feature flags
```

---

## 📊 执行流程详解

### 多步提案执行链

```
提案通过后的自动执行流程：

1. 脚本 0-move-stdlib.move 执行
   ├─ 升级 move-stdlib 包
   ├─ 批准下一步的执行哈希
   └─ 自动触发下一步

2. 脚本 1-aptos-stdlib.move 执行
   ├─ 验证哈希匹配
   ├─ 升级 aptos-stdlib 包
   └─ 自动触发下一步

3. 脚本 2-aptos-framework.move 执行
   ├─ 验证哈希匹配
   ├─ 升级 aptos-framework 包
   └─ 自动触发下一步

4. 脚本 3-features.move 执行
   ├─ 验证哈希匹配
   ├─ 启用所有 feature flags
   ├─ 触发 reconfigure (epoch 切换)
   └─ 完成升级
```

**关键点**：
- ✅ 所有步骤**原子性**执行，要么全部成功，要么全部失败
- ✅ 通过执行哈希链确保**不能跳过**或**篡改**步骤
- ✅ **无需手动**执行每一步，系统自动按顺序执行

### Gas 限制说明

**你不需要担心 gas 限制！**

Aptos 有两套独立的 gas 限制：
- **普通交易**：`max_execution_gas` ≈ 2,000,000,000
- **治理交易**：`max_execution_gas_gov` ≈ 20,000,000,000 (10倍)

治理提案自动使用高 gas 限制，无需手动调整。

---

## 🔍 验证升级成功

### 1. 检查框架版本

```bash
# 查询链上配置
aptos node show-validator-config
```

### 2. 检查 Feature Flags

```bash
# 使用 REST API 查询
curl https://fullnode.testnet.aptoslabs.com/v1/accounts/0x1/resource/0x1::features::Features

# 或使用 aptos CLI
aptos account list --account 0x1
```

### 3. 验证提案状态

```bash
# 查看提案详情
aptos governance show-proposal --proposal-id <ID>

# 查看投票记录
aptos governance show-votes --proposal-id <ID>
```

---

## ❓ 常见问题

### Q1: 升级会影响现有合约吗？

A: 不会。框架升级遵循**向后兼容原则**：
- ✅ 现有合约继续正常运行
- ✅ 只有新部署的合约使用新的字节码版本
- ✅ Feature flags 只影响启用后的新行为

### Q2: 升级失败怎么办？

A: 升级脚本内置了验证：
1. 模拟执行阶段会提前发现问题
2. 链上执行前会验证所有前置条件
3. 如果某一步失败，整个提案会回滚

### Q3: 需要多长时间生效？

A: 取决于治理流程：
- **投票期**：通常 3-7 天
- **执行**：提案通过后立即执行
- **生效**：Feature flags 在下一个 epoch 生效（通常 2 小时）

### Q4: 如何回滚升级？

A: 框架升级通常**不可回滚**。因此：
- ⚠️ 务必在测试网充分测试
- ⚠️ 仔细检查生成的脚本
- ⚠️ 确保社区充分讨论

### Q5: 可以只升级部分包吗？

A: 可以，修改 `framework-upgrade-config.yaml`：

```yaml
# 移除 Framework 配置，只升级 features
update_sequence:
  - FeatureFlag:
      enabled:
        - new_feature
```

---

## 📚 参考资料

### 配置示例

**最小配置**（仅升级框架）：
```yaml
---
remote_endpoint: https://fullnode.testnet.aptoslabs.com
name: "framework-only"
proposals:
  - name: upgrade
    execution_mode: MultiStep
    update_sequence:
      - Framework:
          bytecode_version: 8
```

**完整配置**（框架 + features + gas）：
```yaml
---
remote_endpoint: https://fullnode.testnet.aptoslabs.com
name: "full-upgrade"
proposals:
  - name: upgrade
    execution_mode: MultiStep
    update_sequence:
      - Framework:
          bytecode_version: 8
      - FeatureFlag:
          enabled: [resource_groups, multisig_accounts]
          disabled: []
      - Gas:
          old: ~
          new: current
```

### 相关文件

- 配置文件：`framework-upgrade-config.yaml`
- 自动化脚本：`upgrade-framework.sh`
- Release Builder：`aptos-move/aptos-release-builder/`
- 示例输出：`aptos-move/aptos-release-builder/data/example_output/`

### 相关命令

```bash
# 查看工具帮助
./upgrade-framework.sh help

# 查看 aptos CLI 帮助
aptos governance --help

# 编译框架包
cargo build -p aptos-framework

# 运行框架测试
cargo test -p aptos-framework
```

---

## ⚠️ 重要提醒

1. **总是先在测试网测试**
2. **仔细检查生成的脚本**
3. **确保有足够的投票权重**
4. **与社区充分沟通**
5. **准备应急预案**

---

## 🎯 总结

使用本工具，你可以：
- ✅ 一次性升级多个框架库
- ✅ 同时启用多个 feature flags
- ✅ 自动化整个升级流程
- ✅ 安全可靠，原子性执行

**3 个命令完成升级**：
```bash
./upgrade-framework.sh all
POOL_ADDRESS=0x123 ./upgrade-framework.sh submit
aptos governance vote --proposal-id 42 --should-pass true
```

就这么简单！🚀
