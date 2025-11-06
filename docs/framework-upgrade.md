# Aptos Framework 升级完整指南

本文档详细介绍如何在 Aptos 区块链上升级 `aptos_framework` 中的合约，包括添加新合约或修改现有合约。

## 目录

- [概述](#概述)
- [生产环境升级流程](#生产环境升级流程)
  - [1. 编译和准备新框架代码](#1-编译和准备新框架代码)
  - [2. 创建治理提案脚本](#2-创建治理提案脚本)
  - [3. 提交治理提案](#3-提交治理提案)
  - [4. 质押池投票](#4-质押池投票)
  - [5. 执行提案](#5-执行提案)
  - [6. Epoch 切换生效](#6-epoch-切换生效)
- [开发/测试环境快速部署](#开发测试环境快速部署)
  - [方式 1：使用 Testnet 脚本（推荐）](#方式-1使用-testnet-脚本推荐)
  - [方式 2：Genesis 时部署](#方式-2genesis-时部署)
  - [方式 3：直接使用 code::publish_package_txn](#方式-3直接使用-codepublish_package_txn)
- [升级策略说明](#升级策略说明)
- [关键代码文件位置](#关键代码文件位置)
- [大包支持](#大包支持)
- [安全性和去中心化](#安全性和去中心化)

---

## 概述

Aptos Framework 是部署在 `@aptos_framework` (0x1) 地址的核心系统合约集合，包含治理、质押、代币、账户管理等核心功能。由于其重要性，框架升级必须通过**链上治理机制**（AptosGovernance）完成，确保去中心化和安全性。

**核心原则**：
- ✅ 框架账户由链上治理控制，无私钥
- ✅ 所有升级必须通过治理提案和投票
- ✅ 升级脚本的哈希值在提案中锁定，防止篡改
- ✅ 支持兼容性检查，防止破坏性升级
- ✅ 通过 epoch 切换确保全网一致性

---

## 生产环境升级流程

> **注意**：本节介绍 Mainnet 和公共 Testnet 的完整治理流程。如果您在开发或私有测试环境中工作，请参阅[开发/测试环境快速部署](#开发测试环境快速部署)。

### 1. 编译和准备新框架代码

#### 步骤 1.1：修改或添加 Move 模块

在 `aptos-move/framework/aptos-framework/sources/` 目录下添加或修改 Move 合约：

```move
// 示例：添加新模块 new_feature.move
module aptos_framework::new_feature {
    use std::signer;

    struct NewResource has key {
        value: u64,
    }

    public fun initialize(account: &signer, value: u64) {
        move_to(account, NewResource { value });
    }
}
```

#### 步骤 1.2：编译框架代码

```bash
cd aptos-move/framework/aptos-framework

# 编译并保存元数据
aptos move compile --save-metadata \
  --named-addresses aptos_framework=0x1

# 或者使用 Cargo 编译整个框架
cd /path/to/aptos-core
cargo run -p aptos-framework -- release
```

编译输出包括：
- **字节码文件** (`.mv`)：每个模块的编译后代码
- **PackageMetadata**：包含模块列表、依赖关系、升级策略、source digest 等
- **源码和源码映射**（可选）：用于链上验证

**PackageMetadata 结构**（文件：`aptos-framework/sources/code.move:30-49`）：

```move
struct PackageMetadata has copy, drop, store {
    name: String,
    upgrade_policy: UpgradePolicy,       // 升级策略
    upgrade_number: u64,                 // 升级次数（自动分配）
    source_digest: String,               // 源码哈希
    manifest: vector<u8>,                // Move.toml (gzipped)
    modules: vector<ModuleMetadata>,     // 模块列表
    deps: vector<PackageDep>,            // 依赖关系
    extension: Option<Any>               // 扩展字段
}
```

---

### 2. 创建治理提案脚本

#### 步骤 2.1：编写执行脚本

创建 Move script 用于执行框架升级（例如：`upgrade_framework.move`）：

```move
script {
    use std::vector;
    use aptos_framework::aptos_governance;
    use aptos_framework::code;

    fun main(proposal_id: u64) {
        // 1. 解析提案，获取 framework_signer
        // 这会验证提案已通过，并返回具有 @aptos_framework 权限的 signer
        let framework_signer = aptos_governance::resolve(
            proposal_id,
            @aptos_framework
        );

        // 2. 准备包元数据（序列化的 PackageMetadata）
        let metadata_serialized = vector[
            /* PackageMetadata 的 BCS 序列化字节 */
        ];

        // 3. 准备所有模块的字节码
        let code = vector::empty();

        // 添加模块 1 的字节码
        let module1_bytecode = vector[
            161u8, 28u8, 235u8, 11u8, /* ... */
        ];
        vector::push_back(&mut code, module1_bytecode);

        // 添加模块 2 的字节码
        let module2_bytecode = vector[
            161u8, 28u8, 235u8, 11u8, /* ... */
        ];
        vector::push_back(&mut code, module2_bytecode);

        // ... 添加所有需要升级的模块

        // 4. 发布/升级包到 @aptos_framework
        code::publish_package_txn(
            &framework_signer,
            metadata_serialized,
            code
        );

        // 5. 触发重新配置，使更改在下一个 epoch 生效
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**关键函数说明**：

- **`aptos_governance::resolve(proposal_id, @aptos_framework)`**
  文件：`aptos-framework/sources/aptos_governance.move:634-641`
  - 验证提案状态为 `SUCCEEDED`（已通过）
  - 标记提案为 `resolved`
  - 从 `GovernanceResponsbility` 中获取 `@aptos_framework` 的 SignerCapability
  - 返回具有框架权限的 signer

- **`code::publish_package_txn(&signer, metadata, code)`**
  文件：`aptos-framework/sources/code.move:256-259`
  - 反序列化 `metadata_serialized` 得到 `PackageMetadata`
  - 调用 `publish_package()` 执行实际发布/升级

- **`aptos_governance::reconfigure(&signer)`**
  文件：`aptos-framework/sources/aptos_governance.move:685-692`
  - 如果启用了 DKG（Distributed Key Generation），启动 DKG 过程
  - 否则立即结束当前 epoch 并进入新 epoch

#### 步骤 2.2：生成脚本字节码

```bash
# 编译治理提案脚本
aptos move compile-script \
  --script-path upgrade_framework.move \
  --output-file upgrade_framework.mv
```

#### 步骤 2.3：计算脚本哈希

治理提案需要提供执行脚本的哈希值，防止脚本被篡改：

```bash
# 计算脚本哈希（SHA-256）
sha256sum upgrade_framework.mv
# 输出示例：70505204a3f1...
```

---

### 3. 提交治理提案

#### 步骤 3.1：准备提案元数据

创建提案需要准备：
- **metadata_url**：提案详细信息的 URL（例如 GitHub Gist、IPFS）
- **metadata_hash**：元数据内容的哈希值
- **execution_hash**：执行脚本的哈希值（从步骤 2.3 获得）

提案元数据示例（JSON 格式）：

```json
{
  "title": "升级 Aptos Framework - 添加新特性模块",
  "description": "本提案添加 new_feature 模块到 aptos_framework，提供 XXX 功能",
  "discussion_url": "https://github.com/aptos-foundation/AIPs/discussions/xxx",
  "source_code": "https://github.com/aptos-labs/aptos-core/pull/xxx",
  "modules_changed": ["new_feature"],
  "impact": "向后兼容，不影响现有功能"
}
```

#### 步骤 3.2：提交提案

使用 Aptos CLI 提交提案：

```bash
aptos governance propose \
  --assume-yes \
  --pool-address <PROPOSER_STAKE_POOL> \
  --execution-hash <SCRIPT_HASH> \
  --metadata-url "https://..." \
  --metadata-hash <METADATA_HASH>
```

或者通过 Move 函数直接调用（文件：`aptos-framework/sources/aptos_governance.move:370-378`）：

```move
public entry fun create_proposal(
    proposer: &signer,
    stake_pool: address,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
)
```

**提案创建要求**（文件：`aptos-framework/sources/aptos_governance.move:405-435`）：

1. **提案者质押要求**：
   - 质押池必须持有足够的质押量（默认：100 万 APT）
   - 配置位置：`GovernanceConfig.required_proposer_stake`

2. **锁定期要求**：
   - 质押池的锁定期必须 ≥ 提案投票期限
   - 默认投票期限：7 天（604,800 秒）
   - 配置位置：`GovernanceConfig.voting_duration_secs`

3. **投票权委托**：
   - `proposer` 必须是 `stake_pool` 的 `delegated_voter`

**提案创建流程**：

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 验证提案者是 stake_pool 的 delegated_voter              │
│    stake::get_delegated_voter(stake_pool) == proposer       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 检查质押量是否达到最低要求                              │
│    get_voting_power(stake_pool) >= required_proposer_stake  │
│    默认：100,0000 APT                                       │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 检查锁定期是否足够长                                    │
│    stake::get_lockup_secs(pool) >= proposal_expiration      │
│    proposal_expiration = now + voting_duration_secs         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. 创建提案元数据                                          │
│    metadata = {                                             │
│      "metadata_location": metadata_url,                     │
│      "metadata_hash": hash(metadata_content)                │
│    }                                                         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. 调用 voting 模块创建提案                                │
│    voting::create_proposal_v2(                              │
│      proposer, @aptos_framework,                            │
│      GovernanceProposal,                                    │
│      execution_hash,                                        │
│      min_voting_threshold,                                  │
│      proposal_expiration,                                   │
│      early_resolution_threshold,  // 50% + 1 总供应量      │
│      metadata,                                              │
│      is_multi_step = false                                  │
│    )                                                         │
│    返回 proposal_id                                         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. 发出 CreateProposal 事件                                │
│    event::emit(CreateProposal {                             │
│      proposer, stake_pool, proposal_id,                     │
│      execution_hash, proposal_metadata                      │
│    })                                                        │
└─────────────────────────────────────────────────────────────┘
```

提案创建成功后，会返回一个 `proposal_id`，用于后续投票和执行。

---

### 4. 质押池投票

#### 步骤 4.1：投票机制

验证者和质押者使用其质押池对提案进行投票。投票权重基于**当前 epoch 的质押量**。

**投票命令**：

```bash
# 使用全部投票权投票
aptos governance vote \
  --proposal-id <PROPOSAL_ID> \
  --pool-address <STAKE_POOL> \
  --should-pass true

# 使用部分投票权投票（partial voting）
aptos governance vote-partial \
  --proposal-id <PROPOSAL_ID> \
  --pool-address <STAKE_POOL> \
  --voting-power 1000000 \
  --should-pass true
```

**投票流程**（文件：`aptos-framework/sources/aptos_governance.move:539-604`）：

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 验证投票者是 stake_pool 的 delegated_voter              │
│    stake::get_delegated_voter(stake_pool) == voter          │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 验证提案未过期，且质押锁定期足够                        │
│    - now <= proposal_expiration                             │
│    - stake::get_lockup_secs(pool) >= proposal_expiration    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 计算剩余投票权                                          │
│    remaining = get_voting_power(pool) - used_power          │
│    voting_power = min(requested_power, remaining)           │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. 调用 voting 模块记录投票                                │
│    voting::vote<GovernanceProposal>(                        │
│      @aptos_framework, proposal_id,                         │
│      voting_power, should_pass                              │
│    )                                                         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. 更新投票记录                                            │
│    VotingRecordsV2[stake_pool][proposal_id] += voting_power │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. 检查提案是否达到通过条件                                │
│    if (yes_votes >= early_resolution_threshold):            │
│      proposal_state = SUCCEEDED                             │
│      add_approved_script_hash(proposal_id)                  │
└─────────────────────────────────────────────────────────────┘
```

#### 步骤 4.2：投票权计算

投票权基于质押池的**非 inactive 质押量**（文件：`aptos-framework/sources/aptos_governance.move:731-742`）：

```move
public fun get_voting_power(pool_address: address): u64 {
    let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
    // 投票权 = 活跃质押 + 待激活质押 + 待撤销质押
    active + pending_active + pending_inactive
}
```

#### 步骤 4.3：部分投票（Partial Voting）

Aptos 支持**部分投票**，允许质押池分多次投票，或仅使用部分投票权：

- 质押池可以对同一提案投票多次，直到用完全部投票权
- 每次投票会累加到 `VotingRecordsV2` 中
- 如果请求的投票权超过剩余投票权，自动使用全部剩余投票权

**示例**：

```move
// 质押池总投票权：100 万 APT
// 第一次投票：使用 30 万 APT 投 Yes
partial_vote(voter, pool, proposal_id, 300000, true);

// 第二次投票：使用 50 万 APT 投 Yes
partial_vote(voter, pool, proposal_id, 500000, true);

// 剩余投票权：20 万 APT
get_remaining_voting_power(pool, proposal_id) // 返回 200000
```

#### 步骤 4.4：提案通过条件

提案需要满足以下条件之一才能通过：

1. **早期解决（Early Resolution）**：
   - Yes 票 ≥ 总供应量的 50% + 1
   - 提案立即进入 `SUCCEEDED` 状态，无需等待投票期结束

2. **投票期结束**：
   - 投票期结束（`now > proposal_expiration`）
   - Yes 票 ≥ `min_voting_threshold`（默认：5000 万 APT）
   - Yes 票 > No 票

**配置参数**（文件：`aptos-framework/sources/aptos_governance.move:87-91`）：

```move
struct GovernanceConfig has key {
    min_voting_threshold: u128,        // 最低投票阈值（默认：5000 万 APT）
    required_proposer_stake: u64,      // 提案者最低质押（默认：100 万 APT）
    voting_duration_secs: u64,         // 投票期限（默认：7 天）
}
```

---

### 5. 执行提案

#### 步骤 5.1：验证提案可执行

提案必须满足以下条件才能执行：

- 提案状态为 `SUCCEEDED`（已通过）
- 执行脚本哈希与提案中的哈希匹配
- 提案尚未被执行（`resolved = false`）

**查询提案状态**：

```bash
# 查询提案状态
aptos move view \
  --function-id 0x1::voting::get_proposal_state \
  --type-args 0x1::governance_proposal::GovernanceProposal \
  --args address:0x1 u64:<PROPOSAL_ID>

# 返回值：
# 0 = PENDING (等待投票)
# 1 = SUCCEEDED (已通过)
# 2 = FAILED (未通过)
```

#### 步骤 5.2：将执行脚本哈希添加到批准列表

提案通过后，需要将执行脚本哈希添加到 `ApprovedExecutionHashes`：

```bash
aptos governance add-approved-hash \
  --proposal-id <PROPOSAL_ID>
```

这会调用 `aptos_governance::add_approved_script_hash()`（文件：`aptos-framework/sources/aptos_governance.move:613-630`）：

```move
public fun add_approved_script_hash(proposal_id: u64)
    acquires ApprovedExecutionHashes
{
    // 验证提案状态为 SUCCEEDED
    let proposal_state = voting::get_proposal_state<GovernanceProposal>(
        @aptos_framework, proposal_id
    );
    assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, ...);

    // 获取执行哈希并添加到批准列表
    let execution_hash = voting::get_execution_hash<GovernanceProposal>(
        @aptos_framework, proposal_id
    );

    let approved_hashes = &mut borrow_global_mut<ApprovedExecutionHashes>(
        @aptos_framework
    ).hashes;
    simple_map::add(approved_hashes, proposal_id, execution_hash);
}
```

**作用**：
- 批准的哈希值会被 Mempool 识别，允许超大交易绕过大小限制
- 防止恶意提交其他脚本冒充治理提案

#### 步骤 5.3：执行提案

任何人都可以提交交易执行已通过的提案：

```bash
# 执行提案（运行治理脚本）
aptos move run-script \
  --compiled-script-path upgrade_framework.mv \
  --args u64:<PROPOSAL_ID>
```

或者使用专门的治理执行命令：

```bash
aptos governance execute-proposal \
  --proposal-id <PROPOSAL_ID> \
  --script-path upgrade_framework.mv
```

**执行流程**：

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 验证执行脚本哈希是否在批准列表中                        │
│    ApprovedExecutionHashes[proposal_id] == hash(script)     │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 执行脚本的 main() 函数                                  │
│    script::main(proposal_id)                                │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 脚本内部调用 aptos_governance::resolve()                │
│    - 验证 proposal_state == SUCCEEDED                       │
│    - 标记提案为 resolved                                    │
│    - 获取 @aptos_framework 的 SignerCapability              │
│    - 返回 framework_signer                                  │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. 使用 framework_signer 调用 code::publish_package_txn()  │
│    - 反序列化 PackageMetadata                               │
│    - 验证升级策略                                           │
│    - 检查模块兼容性                                         │
│    - 调用 native request_publish()                          │
│    - 更新 PackageRegistry                                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. （可选）脚本调用 aptos_governance::reconfigure()        │
│    - 触发 epoch 切换                                        │
│    - 新框架代码在下一个 epoch 生效                          │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 6. 从批准列表中移除执行哈希                                │
│    remove_approved_hash(proposal_id)                        │
└─────────────────────────────────────────────────────────────┘
```

#### 步骤 5.4：包发布/升级逻辑

`code::publish_package()` 执行核心的包发布/升级逻辑（文件：`aptos-framework/sources/code.move:168-228`）：

```move
public fun publish_package(
    owner: &signer,
    pack: PackageMetadata,
    code: vector<vector<u8>>
) acquires PackageRegistry {
    // 1. 禁止使用 arbitrary 升级策略
    assert!(
        pack.upgrade_policy.policy > upgrade_policy_arbitrary().policy,
        error::invalid_argument(EINCOMPATIBLE_POLICY_DISABLED),
    );

    // 2. 检查依赖包的升级策略
    let allowed_deps = check_dependencies(addr, &pack);

    // 3. 检查模块冲突和升级兼容性
    let module_names = get_module_names(&pack);
    let packages = &borrow_global<PackageRegistry>(addr).packages;

    vector::enumerate_ref(packages, |i, old| {
        if (old.name == pack.name) {
            // 升级现有包：检查兼容性
            check_upgradability(old, &pack, &module_names);
            upgrade_number = old.upgrade_number + 1;
            index = i;
        } else {
            // 新包：检查模块名称不冲突
            check_coexistence(old, &module_names);
        }
    });

    // 4. 分配升级编号
    pack.upgrade_number = upgrade_number;

    // 5. 更新 PackageRegistry
    let packages = &mut borrow_global_mut<PackageRegistry>(addr).packages;
    if (index < len) {
        *vector::borrow_mut(packages, index) = pack  // 更新现有包
    } else {
        vector::push_back(packages, pack)  // 添加新包
    };

    // 6. 调用 native 函数加载模块到 VM
    request_publish_with_allowed_deps(
        addr, module_names, allowed_deps, code, policy
    );
}
```

**兼容性检查**（`check_upgradability`，文件：`code.move:265-279`）：

```move
fun check_upgradability(
    old_pack: &PackageMetadata,
    new_pack: &PackageMetadata,
    new_modules: &vector<String>
) {
    // 1. 检查包不是 immutable
    assert!(
        old_pack.upgrade_policy.policy < upgrade_policy_immutable().policy,
        error::invalid_argument(EUPGRADE_IMMUTABLE)
    );

    // 2. 检查升级策略只能加强，不能减弱
    // arbitrary (0) < compat (1) < immutable (2)
    assert!(
        can_change_upgrade_policy_to(old_pack.upgrade_policy, new_pack.upgrade_policy),
        error::invalid_argument(EUPGRADE_WEAKER_POLICY)
    );

    // 3. 检查所有旧模块仍然存在于新包中（不允许删除模块）
    let old_modules = get_module_names(old_pack);
    vector::for_each_ref(&old_modules, |old_module| {
        assert!(
            vector::contains(new_modules, old_module),
            EMODULE_MISSING
        );
    });
}
```

---

### 6. Epoch 切换生效

#### 步骤 6.1：Reconfiguration 机制

如果治理脚本调用了 `aptos_governance::reconfigure()`，则会触发 epoch 切换（文件：`aptos-framework/sources/aptos_governance.move:685-692`）：

```move
public entry fun reconfigure(aptos_framework: &signer) {
    system_addresses::assert_aptos_framework(aptos_framework);

    if (consensus_config::validator_txn_enabled() && randomness_config::enabled()) {
        // 启用了 DKG（Distributed Key Generation）
        // 启动 DKG 过程，新 epoch 会在 DKG 完成后的 block prologue 中开始
        reconfiguration_with_dkg::try_start();
    } else {
        // 未启用 DKG
        // 立即结束当前 epoch，进入新 epoch
        reconfiguration_with_dkg::finish(aptos_framework);
    }
}
```

#### 步骤 6.2：新代码生效时机

- **立即生效**（无 DKG）：
  - 调用 `reconfigure()` 后，在**当前交易结束时**进入新 epoch
  - 新框架代码从**下一个 epoch** 的第一个交易开始生效

- **延迟生效**（有 DKG）：
  - 调用 `reconfigure()` 启动 DKG 过程
  - DKG 在后台运行（通常需要几个 block）
  - DKG 完成后，在某个 block prologue 中自动进入新 epoch
  - 新框架代码从新 epoch 的第一个交易开始生效

#### 步骤 6.3：验证升级成功

```bash
# 查询 PackageRegistry，验证新包已部署
aptos move view \
  --function-id 0x1::code::get_package_metadata \
  --args address:0x1 string:"AptosFramework"

# 查询 upgrade_number，应该增加了 1
# 查询 modules 列表，应该包含新模块
```

---

## 开发/测试环境快速部署

在开发和测试环境中，完整的治理流程过于繁琐。Aptos 提供了几种快速部署框架更新的方式，绕过治理投票流程，适用于：
- **本地开发环境**（Localnet）
- **私有测试网络**（Private Testnet）
- **开发集群**（Devnet）
- **单元测试和集成测试**

> ⚠️ **警告**：这些方式仅适用于测试环境！在 Mainnet 和公共 Testnet 上，必须使用完整的治理流程。

---

### 方式 1：使用 Testnet 脚本（推荐）

#### 原理

在测试环境中，存在一个特殊的 **`core_resources`** 账户（地址：`0xA550C18`），该账户在 Genesis 时被授予了 **MintCapability**，可以铸造 APT 代币。通过检测该账户是否拥有 MintCapability，系统判断当前是否为测试环境。

**关键函数**（文件：`aptos-framework/sources/aptos_governance.move:721-727`）：

```move
/// 仅在 testnet 中调用，core_resources 账户拥有 mint capability
public fun get_signer_testnet_only(
    core_resources: &signer,
    signer_address: address
): signer acquires GovernanceResponsbility {
    system_addresses::assert_core_resource(core_resources);
    // Core resources 账户仅在 tests/testnets 拥有 mint capability
    assert!(
        aptos_coin::has_mint_capability(core_resources),
        error::unauthenticated(EUNAUTHORIZED)
    );
    get_signer(signer_address)
}
```

**工作流程**：
1. 验证 `core_resources` 账户拥有 MintCapability（确保是测试环境）
2. 直接从 `GovernanceResponsbility` 中获取 `@aptos_framework` 的 SignerCapability
3. 返回具有框架权限的 signer，**无需提案和投票**

#### 步骤 1：编译框架代码

```bash
cd aptos-move/framework/aptos-framework
aptos move compile --save-metadata \
  --named-addresses aptos_framework=0x1
```

#### 步骤 2：生成 Testnet 脚本

使用 Aptos 框架工具生成专用的 testnet 脚本：

```bash
cd aptos-move/aptos-release-builder

# 生成 testnet 升级脚本
cargo run -- generate-proposals \
  --release-config data/release.yaml \
  --output-dir /tmp/testnet-upgrade \
  --testnet

# 这会生成：
# 0-move-stdlib.move
# 1-aptos-stdlib.move
# 2-aptos-framework.move
# 3-aptos-token.move
# 4-aptos-token-objects.move
```

**生成的 testnet 脚本格式**（文件：`aptos-move/framework/src/release_bundle.rs:210-217`）：

```move
script {
    use std::vector;
    use aptos_framework::aptos_governance;
    use aptos_framework::code;

    // ⚠️ 注意：参数是 core_resources，不是 proposal_id
    fun main(core_resources: &signer) {
        // 使用 testnet 专用函数获取 framework_signer
        let framework_signer = aptos_governance::get_signer_testnet_only(
            core_resources,
            @0x1  // @aptos_framework
        );

        // 准备字节码
        let code = vector::empty();
        vector::push_back(&mut code, /* module bytecode */);
        // ...

        // 发布/升级包
        code::publish_package_txn(
            &framework_signer,
            metadata_serialized,
            code
        );
    }
}
```

**与 Mainnet 脚本的对比**：

| 特性 | Testnet 脚本 | Mainnet 脚本 |
|------|-------------|-------------|
| 函数签名 | `fun main(core_resources: &signer)` | `fun main(proposal_id: u64)` |
| 获取 signer | `get_signer_testnet_only(core_resources, @0x1)` | `resolve(proposal_id, @0x1)` |
| 需要提案 | ❌ 不需要 | ✅ 需要 |
| 需要投票 | ❌ 不需要 | ✅ 需要（7 天） |
| 执行者 | core_resources 账户持有者 | 任何人（提案通过后） |
| 安全检查 | MintCapability 检查 | 提案状态验证 |

#### 步骤 3：执行 Testnet 脚本

使用 `core_resources` 账户的私钥签名并执行脚本：

```bash
# 方法 1：使用 aptos CLI
aptos move run-script \
  --compiled-script-path /tmp/testnet-upgrade/2-aptos-framework.mv \
  --private-key-file ~/.aptos/core_resources_key \
  --assume-yes

# 方法 2：使用治理命令（但无需提案）
aptos governance execute-proposal-fast \
  --script-path /tmp/testnet-upgrade/2-aptos-framework.move \
  --core-resources-key ~/.aptos/core_resources_key
```

#### 步骤 4：触发 Reconfiguration（可选）

如果需要立即生效，手动触发 epoch 切换：

```bash
# 使用 core_resources 账户
aptos move run \
  --function-id 0x1::aptos_governance::force_end_epoch_test_only \
  --private-key-file ~/.aptos/core_resources_key \
  --args signer:0x1
```

**函数实现**（文件：`aptos-framework/sources/aptos_governance.move:707-711`）：

```move
public entry fun force_end_epoch_test_only(aptos_framework: &signer)
    acquires GovernanceResponsbility
{
    let core_signer = get_signer_testnet_only(aptos_framework, @0x1);
    system_addresses::assert_aptos_framework(&core_signer);
    reconfiguration_with_dkg::finish(&core_signer);
}
```

#### 优点

- ✅ 最接近生产环境的流程（使用相同的 `code::publish_package_txn()`）
- ✅ 自动生成脚本，减少人为错误
- ✅ 兼容性检查仍然生效，确保升级安全
- ✅ 适用于 Devnet、私有 Testnet、本地测试网络

#### 缺点

- ❌ 需要 `core_resources` 账户的私钥
- ❌ 仅在 Genesis 时配置了 MintCapability 的网络中可用

---

### 方式 2：Genesis 时部署

#### 原理

在创建新的测试链时，直接在 Genesis 过程中部署框架代码，无需任何升级操作。

#### 适用场景

- 启动全新的本地测试网络
- 创建私有开发网络
- 集成测试和端到端测试
- 快速原型开发

#### 步骤 1：修改 Genesis 配置

编辑 `genesis.blob` 生成配置，指定要部署的框架版本：

```yaml
# genesis-config.yaml
chain_id: 4  # Testnet chain ID

# 指定框架版本
framework:
  git_hash: "main"  # 或具体的 commit hash
  bytecode_version: 6

# 验证者配置
validators:
  - name: validator-0
    consensus_pubkey: "..."
    # ...
```

#### 步骤 2：生成 Genesis Blob

```bash
# 使用 aptos-genesis-tool 生成 genesis.blob
aptos-genesis-tool create-genesis \
  --output-dir /tmp/genesis \
  --config-path genesis-config.yaml \
  --framework-path aptos-move/framework

# 生成的文件：
# /tmp/genesis/genesis.blob
# /tmp/genesis/waypoint.txt
```

**Genesis 过程中的框架部署**（文件：`aptos-framework/sources/genesis.move:68-100`）：

```move
fun initialize(
    gas_schedule: vector<u8>,
    chain_id: u8,
    initial_version: u64,
    consensus_config: vector<u8>,
    // ...
) {
    // 1. 创建 @aptos_framework 账户
    let (aptos_framework_account, aptos_framework_signer_cap) =
        account::create_framework_reserved_account(@aptos_framework);

    // 2. 初始化账户配置
    account::initialize(&aptos_framework_account);

    // 3. 将 SignerCapability 交给治理控制
    aptos_governance::store_signer_cap(
        &aptos_framework_account,
        @aptos_framework,
        aptos_framework_signer_cap
    );

    // 4. 部署所有框架模块（在 VM genesis 过程中）
    // ...
}
```

#### 步骤 3：启动测试网络

```bash
# 启动 validator 节点
aptos-node --config validator-0.yaml \
  --genesis-blob /tmp/genesis/genesis.blob
```

#### 优点

- ✅ 最快速的部署方式
- ✅ 完全控制初始状态
- ✅ 适合自动化测试和 CI/CD
- ✅ 无需私钥或治理流程

#### 缺点

- ❌ 仅适用于新链，无法用于已运行的网络
- ❌ 需要重启所有节点
- ❌ 所有链上数据会丢失

---

### 方式 3：直接使用 code::publish_package_txn

#### 原理

如果您拥有 `@aptos_framework` 账户的私钥（仅在本地测试环境中），可以直接调用 `code::publish_package_txn()` 发布更新。

#### 适用场景

- **仅限本地单节点测试**（例如：`aptos node run-local-testnet`）
- 本地开发和调试
- 单元测试

> ⚠️ **警告**：这种方式在多节点网络中不可用，因为 `@aptos_framework` 的私钥在正常情况下不存在（SignerCapability 被治理控制）。

#### 步骤：使用 Aptos CLI

```bash
# 前提：您拥有 @aptos_framework 的私钥（仅在本地测试环境）

# 1. 编译框架
aptos move compile --save-metadata \
  --package-dir aptos-move/framework/aptos-framework \
  --named-addresses aptos_framework=0x1

# 2. 发布到链上
aptos move publish \
  --package-dir aptos-move/framework/aptos-framework \
  --named-addresses aptos_framework=0x1 \
  --private-key-file ~/.aptos/framework_key \
  --assume-yes

# CLI 会自动：
# 1. 序列化 PackageMetadata
# 2. 读取编译后的字节码
# 3. 调用 code::publish_package_txn()
```

#### 使用 Move script

如果需要更细粒度的控制，可以编写自定义 script：

```move
script {
    use std::vector;
    use aptos_framework::code;

    fun main(aptos_framework: &signer) {
        // 准备元数据
        let metadata = /* BCS 序列化的 PackageMetadata */;

        // 准备字节码
        let code = vector::empty();
        vector::push_back(&mut code, /* module1 bytecode */);
        vector::push_back(&mut code, /* module2 bytecode */);

        // 直接发布
        code::publish_package_txn(aptos_framework, metadata, code);
    }
}
```

执行：

```bash
aptos move run-script \
  --compiled-script-path custom_publish.mv \
  --private-key-file ~/.aptos/framework_key
```

#### 优点

- ✅ 最直接的方式
- ✅ 完全控制发布过程
- ✅ 适合单元测试和本地开发

#### 缺点

- ❌ 需要 `@aptos_framework` 私钥（生产环境不存在）
- ❌ 仅适用于本地单节点测试
- ❌ 多节点网络中无法使用

---

### 快速部署方式对比

| 特性 | 方式 1：Testnet 脚本 | 方式 2：Genesis 部署 | 方式 3：直接发布 |
|------|---------------------|---------------------|-----------------|
| **适用环境** | Devnet, 私有 Testnet | 新链启动 | 本地单节点 |
| **需要私钥** | core_resources 私钥 | 无 | aptos_framework 私钥 |
| **是否重启** | ❌ 不需要 | ✅ 需要 | ❌ 不需要 |
| **保留数据** | ✅ 保留 | ❌ 清空 | ✅ 保留 |
| **兼容性检查** | ✅ 启用 | ✅ 启用 | ✅ 启用 |
| **多节点支持** | ✅ 支持 | ✅ 支持 | ❌ 仅单节点 |
| **难度** | 中等 | 简单 | 简单 |
| **推荐度** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |

---

### 环境区分：如何判断当前环境

判断当前是生产环境还是测试环境的方法：

```bash
# 查询 core_resources 账户是否有 MintCapability
aptos move view \
  --function-id 0x1::aptos_coin::has_mint_capability \
  --args address:0xA550C18

# 返回：
# true  -> 测试环境（可以使用快速部署）
# false -> 生产环境（必须走治理流程）
# error -> core_resources 账户不存在（生产环境）
```

或者检查 Chain ID：

```bash
aptos info

# Chain ID 1 = Mainnet（必须走治理流程）
# Chain ID 2 = Testnet（公共测试网，通常需要治理流程）
# Chain ID 4+ = 私有网络（可以使用快速部署）
```

---

### 常见问题

#### Q1：为什么 Testnet 脚本在 Mainnet 上不能用？

A：`get_signer_testnet_only()` 函数会检查 `core_resources` 账户是否拥有 MintCapability。在 Mainnet 上：
- `core_resources` 账户不存在，或
- 该账户没有 MintCapability（在 Genesis 后被销毁）

因此该函数会 abort，脚本执行失败。

#### Q2：如何为本地测试网络配置 core_resources 账户？

A：在 Genesis 配置中添加：

```yaml
# genesis-config.yaml
accounts:
  - address: "0xA550C18"
    balance: 100000000000000  # 100 万 APT
    modules:
      - aptos_framework
      - aptos_coin
```

在 Genesis Move 代码中（文件：`aptos-framework/sources/aptos_coin.move:73-89`）：

```move
public(friend) fun configure_accounts_for_test(
    aptos_framework: &signer,
    core_resources: &signer,
    mint_cap: MintCapability<AptosCoin>,
) {
    // 给 core_resources 账户铸造 APT
    let coins = coin::mint<AptosCoin>(18446744073709551615, &mint_cap);
    coin::deposit<AptosCoin>(signer::address_of(core_resources), coins);

    // 将 MintCapability 存储到 core_resources 账户
    move_to(core_resources, MintCapStore { mint_cap });
}
```

#### Q3：如何在测试环境中模拟完整的治理流程？

A：即使在测试环境中，您也可以选择走完整的治理流程来测试治理机制本身：

```bash
# 1. 生成 Mainnet 风格的脚本（不使用 --testnet 标志）
cargo run -- generate-proposals \
  --release-config data/release.yaml \
  --output-dir /tmp/mainnet-style

# 2. 提交提案（需要质押）
aptos governance propose \
  --pool-address <STAKE_POOL> \
  --script-path /tmp/mainnet-style/2-aptos-framework.move

# 3. 投票、执行（与生产环境相同）
```

这对于测试治理逻辑本身非常有用。

---

## 升级策略说明

Aptos Framework 支持三种升级策略（文件：`aptos-framework/sources/code.move:69-146`）：

### 升级策略枚举

```move
struct UpgradePolicy has store, copy, drop {
    policy: u8
}

// 三种策略：
public fun upgrade_policy_arbitrary(): UpgradePolicy {
    UpgradePolicy { policy: 0 }  // 无限制升级
}

public fun upgrade_policy_compat(): UpgradePolicy {
    UpgradePolicy { policy: 1 }  // 兼容性升级
}

public fun upgrade_policy_immutable(): UpgradePolicy {
    UpgradePolicy { policy: 2 }  // 不可变
}
```

### 策略详细说明

| 策略 | policy 值 | 说明 | 允许的操作 | aptos_framework 是否可用 |
|------|-----------|------|------------|-------------------------|
| **arbitrary** | 0 | 无限制升级，允许任意修改 | - 修改公共函数签名<br>- 修改资源布局<br>- 删除模块<br>- 破坏性更改 | ❌ **已禁用**<br>（line 171-174） |
| **compat** | 1 | 兼容性升级，确保向后兼容 | - 添加新函数<br>- 添加新模块<br>- 修改私有函数<br>- 资源布局保持不变 | ✅ **默认策略** |
| **immutable** | 2 | 不可变，完全禁止升级 | - 无法升级<br>- 包被永久锁定 | ❌ 不推荐 |

### 兼容性检查规则（compat 策略）

当使用 `compat` 策略升级时，VM 会执行以下检查（native 层实现）：

1. **公共函数签名不变**：
   - 现有公共函数的签名不能修改
   - 可以添加新的公共函数
   - 可以修改或删除私有函数

2. **资源布局不变**：
   - 现有资源（`struct T has key`）的字段顺序和类型不能修改
   - 不能删除现有字段
   - 可以在末尾添加新字段（需要使用 `Option` 或默认值）

3. **模块不能删除**：
   - 旧包中的所有模块必须在新包中存在
   - 可以添加新模块

4. **依赖包升级策略**：
   - 依赖包的升级策略不能弱于当前包
   - 例如：`compat` 包不能依赖 `arbitrary` 包（除非在同一地址）

### 策略转换规则

升级策略只能**加强**，不能**减弱**（文件：`code.move:150-152`）：

```move
public fun can_change_upgrade_policy_to(from: UpgradePolicy, to: UpgradePolicy): bool {
    from.policy <= to.policy
}
```

允许的转换：
- ✅ `arbitrary` (0) → `compat` (1)
- ✅ `arbitrary` (0) → `immutable` (2)
- ✅ `compat` (1) → `immutable` (2)
- ❌ `compat` (1) → `arbitrary` (0)  // 禁止
- ❌ `immutable` (2) → `compat` (1)  // 禁止

### aptos_framework 的升级策略

aptos_framework 使用 **`compat`** 策略，确保：
- 升级不会破坏现有链上数据
- 现有合约和应用仍然可以正常运行
- 仅允许添加新功能或修复 bug

**查询当前升级策略**：

```bash
aptos move view \
  --function-id 0x1::code::get_package_metadata \
  --args address:0x1 string:"AptosFramework" \
| jq '.upgrade_policy'

# 返回：{"policy": 1}  // compat
```

---

## 关键代码文件位置

### 1. 代码发布机制

**文件**：`aptos-move/framework/aptos-framework/sources/code.move`

| 函数/结构 | 行号 | 说明 |
|-----------|------|------|
| `PackageRegistry` | 24-27 | 存储在地址上的包注册表 |
| `PackageMetadata` | 30-49 | 包元数据结构 |
| `UpgradePolicy` | 70-72 | 升级策略枚举 |
| `upgrade_policy_arbitrary()` | 133-135 | arbitrary 策略（已禁用） |
| `upgrade_policy_compat()` | 139-141 | compat 策略（默认） |
| `upgrade_policy_immutable()` | 144-146 | immutable 策略 |
| `can_change_upgrade_policy_to()` | 150-152 | 策略转换验证 |
| `publish_package()` | 168-228 | 核心发布逻辑 |
| `publish_package_txn()` | 256-259 | 交易入口函数 |
| `check_upgradability()` | 265-279 | 兼容性检查 |
| `check_dependencies()` | 298-344 | 依赖关系验证 |
| `request_publish_with_allowed_deps()` | 383-389 | native 函数（加载模块） |

### 2. 治理机制

**文件**：`aptos-move/framework/aptos-framework/sources/aptos_governance.move`

| 函数/结构 | 行号 | 说明 |
|-----------|------|------|
| `GovernanceResponsbility` | 81-83 | 存储 framework 的 SignerCapability |
| `GovernanceConfig` | 87-91 | 治理配置（质押要求、投票期限等） |
| `VotingRecordsV2` | 104-106 | 部分投票记录 |
| `ApprovedExecutionHashes` | 110-112 | 批准的执行脚本哈希 |
| `store_signer_cap()` | 191-208 | 存储 SignerCapability |
| `create_proposal()` | 370-378 | 创建提案入口 |
| `create_proposal_v2_impl()` | 405-487 | 创建提案核心逻辑 |
| `vote()` | 515-522 | 投票入口 |
| `vote_internal()` | 539-604 | 投票核心逻辑 |
| `add_approved_script_hash()` | 613-630 | 添加批准哈希 |
| `resolve()` | 634-641 | 执行提案并获取 signer |
| `remove_approved_hash()` | 664-674 | 移除批准哈希 |
| `reconfigure()` | 685-692 | 触发 epoch 切换 |
| `get_voting_power()` | 731-742 | 计算投票权 |
| `get_remaining_voting_power()` | 320-348 | 计算剩余投票权 |

### 3. Genesis 初始化

**文件**：`aptos-move/framework/aptos-framework/sources/genesis.move`

| 函数 | 行号 | 说明 |
|------|------|------|
| `initialize()` | 68-100 | Genesis 初始化，创建 @aptos_framework 账户 |

第 86 行：创建 `@aptos_framework` 账户
第 98 行：将 SignerCapability 交给治理控制

### 4. 治理提案示例

**文件**：`aptos-move/move-examples/governance/sources/governance_update_voting_duration.move`

完整的治理提案脚本示例，展示如何修改治理配置。

**文件**：`aptos-move/aptos-release-builder/data/example_output/`

包含实际的框架升级脚本示例：
- `0-move-stdlib.move`：MoveStdlib 升级脚本
- `2-aptos-framework.move`：AptosFramework 升级脚本
- `5-features.move`：Feature flags 更新脚本

---

## 大包支持

对于超大的框架升级（模块字节码总大小超过交易大小限制），Aptos 提供**分块上传**机制。

### 大包模块

**文件**：`aptos-move/framework/aptos-experimental/sources/large_packages.move`
**文档**：`aptos-move/framework/aptos-experimental/doc/large_packages.md`

**部署地址**：
- Mainnet/Testnet: `0xa29df848eebfe5d981f708c2a5b06d31af2be53bbd8ddc94c8523f4b903f7adb`
- Devnet/Localnet: `0x7` (aptos-experimental)

### 分块上传流程

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 将 PackageMetadata 和字节码分成多个 chunk                │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. 多次调用 large_packages::stage_code_chunk()             │
│    - 每次上传一部分 metadata 和部分模块                     │
│    - 数据存储在 StagingArea 资源中                          │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. 最后一次调用 stage_code_chunk_and_publish_to_account()  │
│    - 上传最后一部分数据                                     │
│    - 自动拼接所有 chunk                                     │
│    - 调用 code::publish_package_txn()                       │
│    - 清理 StagingArea                                       │
└─────────────────────────────────────────────────────────────┘
```

### 使用 Aptos CLI

```bash
# 使用 --chunked-publish 标志自动分块上传
aptos move publish \
  --named-addresses aptos_framework=0x1 \
  --chunked-publish \
  --max-gas 1000000

# CLI 会自动：
# 1. 计算需要多少个 chunk
# 2. 分批调用 stage_code_chunk()
# 3. 最后调用 stage_code_chunk_and_publish_to_account()
```

### 治理提案中使用大包

对于通过治理升级的大包，需要：

1. **将执行脚本哈希添加到批准列表**：
   ```move
   aptos_governance::add_approved_script_hash(proposal_id);
   ```

2. **Mempool 识别批准哈希**：
   - 批准的哈希值会绕过 Mempool 的交易大小限制
   - 文件：`aptos-framework/sources/aptos_governance.move:110-112`

3. **执行提案时可以提交超大交易**：
   ```bash
   # 交易大小可以超过默认限制（通常 64KB）
   aptos governance execute-proposal \
     --proposal-id <PROPOSAL_ID> \
     --script-path large_upgrade_script.mv
   ```

---

## 安全性和去中心化

### 1. 多方治理

- **提案者要求**：必须质押 100 万 APT（默认）
- **投票要求**：需要 5000 万 APT 投票支持（默认）
- **锁定期要求**：质押必须锁定至提案结束

### 2. 防篡改机制

- **脚本哈希锁定**：提案创建时锁定 `execution_hash`
- **批准列表验证**：执行时验证脚本哈希在 `ApprovedExecutionHashes` 中
- **提案状态验证**：确保提案已通过且未被执行

### 3. 兼容性保证

- **compat 策略**：强制兼容性检查，防止破坏性更改
- **依赖验证**：确保依赖包的升级策略足够强
- **模块完整性**：不允许删除现有模块

### 4. 透明性

- **链上元数据**：提案详情公开可查
- **投票记录**：所有投票记录永久存储
- **事件发射**：关键操作发出事件，便于监控

### 5. 时间锁

- **投票期限**：默认 7 天，给社区足够时间审查
- **锁定期要求**：防止短期质押操纵投票

### 6. 无私钥控制

- **SignerCapability 管理**：`@aptos_framework` 的 SignerCapability 存储在链上
- **治理专属访问**：只能通过已通过的提案获取 signer
- **无单点控制**：没有私钥可以直接控制框架账户

---

## 完整示例：升级流程总结

```
┌─────────────────────────────────────────────────────────────┐
│ 第 1 步：开发和编译                                         │
│ - 修改/添加 Move 模块                                       │
│ - aptos move compile --save-metadata                        │
│ - 生成 PackageMetadata 和字节码                             │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 2 步：创建治理脚本                                       │
│ - 编写 script { ... }                                       │
│ - 调用 aptos_governance::resolve()                          │
│ - 调用 code::publish_package_txn()                          │
│ - 调用 aptos_governance::reconfigure()                      │
│ - 编译脚本并计算哈希                                        │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 3 步：提交提案                                           │
│ - aptos governance propose                                  │
│ - 质押要求：100 万 APT                                      │
│ - 提供 execution_hash                                       │
│ - 提供 metadata_url 和 metadata_hash                        │
│ - 返回 proposal_id                                          │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 4 步：社区投票（7 天）                                   │
│ - 验证者和质押者投票                                        │
│ - aptos governance vote --proposal-id X --should-pass true  │
│ - 投票权 = 质押量                                           │
│ - 需要 ≥ 5000 万 APT 支持                                   │
│ - 或 ≥ 50% + 1 总供应量（早期解决）                         │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 5 步：添加批准哈希                                       │
│ - aptos governance add-approved-hash --proposal-id X        │
│ - 允许超大交易绕过 Mempool 限制                             │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 6 步：执行提案                                           │
│ - aptos governance execute-proposal --proposal-id X         │
│ - 验证脚本哈希                                              │
│ - 运行治理脚本                                              │
│ - 升级框架代码                                              │
│ - 触发 reconfiguration                                      │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│ 第 7 步：Epoch 切换                                         │
│ - 新 epoch 开始                                             │
│ - 新框架代码生效                                            │
│ - 验证升级成功                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 参考资源

- **Aptos Governance 模块**：`aptos-framework/sources/aptos_governance.move`
- **代码发布模块**：`aptos-framework/sources/code.move`
- **治理提案示例**：`aptos-move/move-examples/governance/`
- **框架升级脚本示例**：`aptos-move/aptos-release-builder/data/example_output/`
- **大包支持文档**：`aptos-framework/aptos-experimental/doc/large_packages.md`
- **Aptos 官方文档**：https://aptos.dev/concepts/governance
- **AIP (Aptos Improvement Proposals)**：https://github.com/aptos-foundation/AIPs

---

**最后更新**：2025-11-06
