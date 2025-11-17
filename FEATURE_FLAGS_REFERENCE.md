# Aptos Feature Flags 完整参考

## 🔍 命名规则

**关键点**：YAML 配置中使用 **snake_case** 命名，Rust 代码中使用 **PascalCase**。

转换规则（通过 `#[serde(rename_all = "snake_case")]` 注解）：
- `CodeDependencyCheck` → `code_dependency_check`
- `MultisigAccounts` → `multisig_accounts`
- `VMBinaryFormatV6` → `vm_binary_format_v6`

---

## 📋 所有可用的 Feature Flags

以下是从 `aptos-move/aptos-release-builder/src/components/feature_flags.rs` 提取的完整列表：

### 代码发布相关
```yaml
- code_dependency_check                          # 包依赖验证
- treat_friend_as_private                        # 将 friend 视为 private
- struct_constructors                            # 结构体构造器
```

### 密码学原语
```yaml
- sha512_and_ripe_md160_natives                  # SHA-512 和 RIPEMD-160 原生函数
- multi_ed25519_pk_validate_v2_natives           # Multi-Ed25519 公钥验证 V2
- blake2b_256_native                             # BLAKE2B-256 哈希函数
- cryptography_algebra_natives                   # 代数密码学原生函数
- bls12381_structures                            # BLS12-381 曲线结构
- bn254_structures                               # BN254 曲线结构
- bulletproofs_natives                           # Bulletproofs 零知识证明
- bulletproofs_batch_natives                     # Bulletproofs 批量验证
- ed25519_pubkey_validate_return_false_wrong_length  # Ed25519 公钥验证错误长度处理
```

### VM 字节码版本
```yaml
- vm_binary_format_v6                            # Move VM 字节码 V6
- vm_binary_format_v7                            # Move VM 字节码 V7
- vm_binary_format_v8                            # Move VM 字节码 V8
- vm_binary_format_v9                            # Move VM 字节码 V9
```

### 资源和存储
```yaml
- resource_groups                                # 资源组
- safer_resource_groups                          # 更安全的资源组
- resource_groups_split_in_vm_change_set         # VM ChangeSet 中分离资源组
- storage_slot_metadata                          # 存储槽元数据
- safer_metadata                                 # 更安全的元数据
- storage_deletion_refund                        # 存储删除退款
- refundable_bytes                               # 可退款字节
```

### 账户和认证
```yaml
- multisig_accounts                              # 多签账户
- single_sender_authenticator                    # 单发送者认证器
- sponsored_automatic_account_creation           # 赞助的自动账户创建
- keyless_accounts                               # 无密钥账户
- keyless_but_zkless_accounts                    # 无 ZK 的无密钥账户
- keyless_accounts_with_passkeys                 # 支持 Passkeys 的无密钥账户
- federated_keyless                              # 联邦无密钥
- webauthn_signature                             # WebAuthn 签名
- permissioned_signer                            # 权限签名者
- account_abstraction                            # 账户抽象
- derivable_account_abstraction                  # 可派生账户抽象
- default_account_resource                       # 默认账户资源
```

### 治理
```yaml
- delegation_pools                               # 委托池
- partial_governance_voting                      # 部分治理投票
- delegation_pool_partial_governance_voting      # 委托池部分治理投票
- delegation_pool_allowlisting                   # 委托池白名单
- commission_change_delegation_pool              # 委托池佣金变更
- operator_beneficiary_change                    # 运营者受益人变更
- periodical_reward_rate_reduction               # 周期性奖励率降低
```

### Gas 和费用
```yaml
- collect_and_distribute_gas_fees                # 收集和分配 gas 费用（已弃用）
- gas_payer_enabled                              # Gas 支付者功能
- fee_payer_account_optional                     # 可选的 fee payer 账户
- charge_invariant_violation                     # 收取不变量违规费用
- emit_fee_statement                             # 发出费用声明
- calculate_transaction_fee_for_distribution     # 计算交易费用分配
- distribute_transaction_fee                     # 分配交易费用
```

### 聚合器和并发
```yaml
- aggregator_v2_api                              # 聚合器 V2 API
- aggregator_v2_delayed_fields                   # 聚合器 V2 延迟字段
- aggregator_v2_is_at_least_api                  # 聚合器 V2 至少值 API
- concurrent_token_v2                            # 并发 Token V2
- concurrent_fungible_assets                     # 并发同质化资产
- concurrent_fungible_balance                    # 并发同质化余额
- default_to_concurrent_fungible_balance         # 默认使用并发同质化余额
```

### 同质化资产（Fungible Assets）
```yaml
- coin_to_fungible_asset_migration               # Coin 到 FA 迁移
- primary_apt_fungible_store_at_user_address     # 用户地址的主 APT FA 存储
- dispatchable_fungible_asset                    # 可调度的同质化资产
- new_accounts_default_to_fa_apt_store           # 新账户默认使用 FA APT 存储
- operations_default_to_fa_apt_store             # 操作默认使用 FA APT 存储
- new_accounts_default_to_fa_store               # 新账户默认使用 FA 存储
```

### 事件和模块
```yaml
- module_event                                   # 模块事件
- module_event_migration                         # 模块事件迁移
```

### 对象和代码部署
```yaml
- object_code_deployment                         # 对象代码部署
- max_object_nesting_check                       # 最大对象嵌套检查
- object_native_derived_address                  # 对象原生派生地址
```

### 多签增强
```yaml
- multisig_v2_enhancement                        # 多签 V2 增强
- abort_if_multisig_payload_mismatch             # 多签负载不匹配时中止
```

### JWK 和共识
```yaml
- jwk_consensus                                  # JWK 共识
- jwk_consensus_per_key_mode                     # JWK 每密钥模式共识
- reconfigure_with_dkg                           # 使用 DKG 重新配置（已弃用）
```

### 签名检查
```yaml
- signature_checker_v2                           # 签名检查器 V2
- signature_checker_v2_script_fix                # 签名检查器 V2 脚本修复
- signer_native_format_fix                       # Signer 原生格式修复
```

### 交易和脚本
```yaml
- transaction_context_extension                  # 交易上下文扩展
- transaction_simulation_enhancement             # 交易模拟增强
- transaction_payload_v2                         # 交易负载 V2
- orderless_transactions                         # 无序交易
- allow_serialized_script_args                   # 允许序列化脚本参数
```

### VM 和编译器特性
```yaml
- limit_max_identifier_length                    # 限制最大标识符长度
- limit_vm_type_size                             # 限制 VM 类型大小
- reject_unstable_bytecode                       # 拒绝不稳定字节码
- reject_unstable_bytecode_for_script            # 脚本拒绝不稳定字节码
- use_compatibility_checker_v2                   # 使用兼容性检查器 V2
- enable_loader_v2                               # 启用加载器 V2
- enable_lazy_loading                            # 启用懒加载
- enable_call_tree_and_instruction_vm_cache      # 启用调用树和指令 VM 缓存
- disallow_user_native                           # 禁止用户原生函数
- disallow_init_module_to_publish_modules        # 禁止 init_module 发布模块
- remove_detailed_error                          # 移除详细错误（已弃用）
```

### Move 语言特性
```yaml
- enable_enum_types                              # 启用枚举类型
- enable_resource_access_control                 # 启用资源访问控制
- enable_function_values                         # 启用函数值
- enable_capture_option                          # 启用捕获选项
- enable_enum_option                             # 启用枚举选项
- enable_framework_for_option                    # 为 Option 启用框架
- enable_trusted_code                            # 启用可信代码
```

### 其他
```yaml
- aptos_std_chain_id_natives                     # Aptos 标准库链 ID 原生函数
- aptos_unique_identifiers                       # Aptos 唯一标识符
- collection_owner                               # 集合所有者
- native_memory_operations                       # 原生内存操作
- monotonically_increasing_counter               # 单调递增计数器
- session_continuation                           # 会话延续
```

---

## 📝 使用示例

### 最小配置
```yaml
update_sequence:
  - FeatureFlag:
      enabled:
        - code_dependency_check
        - resource_groups
      disabled: []
```

### 常用配置（推荐）
```yaml
update_sequence:
  - FeatureFlag:
      enabled:
        # 基础功能
        - code_dependency_check
        - treat_friend_as_private

        # 密码学
        - blake2b_256_native
        - multi_ed25519_pk_validate_v2_natives

        # 资源和存储
        - resource_groups
        - safer_resource_groups

        # 账户
        - multisig_accounts
        - delegation_pools

        # VM
        - vm_binary_format_v8

      disabled: []
```

### 完整升级配置
```yaml
update_sequence:
  - Framework:
      bytecode_version: 8

  - FeatureFlag:
      enabled:
        - code_dependency_check
        - treat_friend_as_private
        - sha512_and_ripe_md160_natives
        - aptos_std_chain_id_natives
        - vm_binary_format_v8
        - multi_ed25519_pk_validate_v2_natives
        - blake2b_256_native
        - resource_groups
        - multisig_accounts
        - delegation_pools
        - cryptography_algebra_natives
        - bls12381_structures
        - module_event
        - aggregator_v2_api
      disabled:
        - collect_and_distribute_gas_fees  # 弃用的功能
```

---

## 🔍 如何查找 Feature Flag

### 方法 1：查看 Rust 定义
```bash
cat aptos-move/aptos-release-builder/src/components/feature_flags.rs | grep -A 1 "pub enum FeatureFlag"
```

### 方法 2：查看 Move 常量
```bash
grep "const.*: u64" aptos-move/framework/move-stdlib/sources/configs/features.move
```

### 方法 3：检查链上当前状态
```bash
# 使用 REST API
curl https://fullnode.testnet.aptoslabs.com/v1/accounts/0x1/resource/0x1::features::Features

# 或使用 CLI
aptos account list --account 0x1 | grep Features
```

---

## ⚠️ 注意事项

1. **命名转换**
   - Rust 枚举：`PascalCase`
   - YAML 配置：`snake_case`
   - 示例：`ModuleEvent` → `module_event`

2. **已弃用的 Features**
   - `collect_and_distribute_gas_fees` - 使用新的费用分配机制
   - `reconfigure_with_dkg` - DKG 重新配置已弃用
   - `remove_detailed_error` - 错误处理已改进

3. **依赖关系**
   某些 features 需要其他 features 先启用：
   - `vm_binary_format_v8` 需要先启用 `vm_binary_format_v7`
   - `aggregator_v2_delayed_fields` 需要 `aggregator_v2_api`

4. **生命周期**
   - **transient**：临时功能，将来会移除
   - **permanent**：永久功能，用于回放兼容性

---

## 🎯 推荐配置

### 对于新链（Testnet/Devnet）
启用所有稳定功能，包括最新的 VM 版本和密码学原语。

### 对于现有链（Mainnet）
谨慎升级，按以下顺序：
1. 先升级框架
2. 启用经过充分测试的 features
3. 观察几个 epoch
4. 逐步启用更多 features

### 对于开发测试
可以启用实验性功能，但注意标记为"已弃用"的功能。

---

## 📚 相关文件

- Feature 定义：`aptos-move/framework/move-stdlib/sources/configs/features.move`
- Rust 枚举：`aptos-move/aptos-release-builder/src/components/feature_flags.rs`
- 示例配置：`aptos-move/aptos-release-builder/data/release.yaml`
