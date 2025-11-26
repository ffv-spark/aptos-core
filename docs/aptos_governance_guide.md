# Aptos 链上治理完整指南

## 目录
1. [概述](#概述)
2. [提案创建](#提案创建)
3. [投票机制](#投票机制)
4. [提案执行](#提案执行)
5. [多步提案](#多步提案)
6. [常见场景](#常见场景)
7. [故障排查](#故障排查)

---

## 概述

Aptos 链上治理系统允许验证者通过质押池投票来提议和批准网络升级。整个流程包括三个主要阶段：

1. **提案创建** - 任何满足最低质押要求的验证者都可以创建提案
2. **投票** - 验证者使用其质押权重进行投票
3. **提案执行** - 投票通过后，任何人都可以执行提案

### 核心参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `min_voting_threshold` | 10 | 最低投票门槛 |
| `required_proposer_stake` | 100 | 创建提案所需的最低质押量 |
| `voting_duration_secs` | 604800 (7天) | 投票期持续时间 |

### 关键代码位置

- **治理框架**: `aptos-move/framework/aptos-framework/sources/aptos_governance.move`
- **投票模块**: `aptos-move/framework/aptos-framework/sources/voting.move`
- **CLI 工具**: `crates/aptos/src/governance/mod.rs`
- **Gas 版本**: `aptos-move/aptos-gas-schedule/src/ver.rs`

---

## 提案创建

### 1. 前提条件

在创建提案之前，需要满足以下条件：

1. **质押要求**: 质押池的投票权 >= `required_proposer_stake`
2. **锁定期**: 质押锁定期 >= 提案投票期（7天）
3. **委托投票人**: 必须是质押池的委托投票人
4. **准备执行脚本**: 编写并编译 Move 脚本

### 2. 创建提案命令

**单步提案:**
```bash
aptos governance propose \
  --assume-yes \
  --pool-address <STAKE_POOL_ADDRESS> \
  --script-path <PATH_TO_SCRIPT> \
  --metadata-url <METADATA_URL> \
  --metadata-hash <METADATA_HASH>
```

**多步提案:**
```bash
aptos governance propose \
  --assume-yes \
  --pool-address <STAKE_POOL_ADDRESS> \
  --script-path <PATH_TO_SCRIPT> \
  --metadata-url <METADATA_URL> \
  --metadata-hash <METADATA_HASH> \
  --is-multi-step true
```

### 3. 参数说明

| 参数 | 必需 | 说明 |
|------|------|------|
| `--pool-address` | 是 | 用于提议的质押池地址 |
| `--script-path` | 是 | 执行脚本的路径 |
| `--metadata-url` | 是 | 提案元数据 URL（<= 256 字符） |
| `--metadata-hash` | 是 | 元数据的 SHA3-256 哈希（<= 256 字符） |
| `--is-multi-step` | 否 | 是否为多步提案（默认 false） |

### 4. 执行脚本哈希

创建提案时，系统会自动计算执行脚本的 SHA3-256 哈希值，并存储在链上：

```rust
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:451-461
let proposal_id = voting::create_proposal_v2(
    proposer_address,
    @aptos_framework,
    governance_proposal::create_proposal(),
    execution_hash,  // 脚本的 SHA3-256 哈希
    governance_config.min_voting_threshold,
    proposal_expiration,
    early_resolution_vote_threshold,
    proposal_metadata,
    is_multi_step_proposal,
);
```

### 5. 提案元数据

元数据应该是一个 JSON 文件，包含提案的详细信息：

```json
{
  "title": "Enable Transaction Payload V2 and Orderless Transactions",
  "description": "This proposal enables two new features...",
  "discussion_url": "https://github.com/aptos-foundation/AIPs/issues/XXX",
  "source_code_url": "https://github.com/aptos-core/pull/XXXX"
}
```

### 6. 代码示例

**提案创建的核心逻辑** (`aptos-move/framework/aptos-framework/sources/aptos_governance.move:405-487`):

```move
public fun create_proposal_v2_impl(
    proposer: &signer,
    stake_pool: address,
    execution_hash: vector<u8>,
    metadata_location: vector<u8>,
    metadata_hash: vector<u8>,
    is_multi_step_proposal: bool,
): u64 {
    // 1. 验证提议者是委托投票人
    assert!(
        stake::get_delegated_voter(stake_pool) == proposer_address,
        error::invalid_argument(ENOT_DELEGATED_VOTER)
    );

    // 2. 验证质押量是否足够
    assert!(
        stake_balance >= governance_config.required_proposer_stake,
        error::invalid_argument(EINSUFFICIENT_PROPOSER_STAKE),
    );

    // 3. 验证锁定期是否足够长
    assert!(
        stake::get_lockup_secs(stake_pool) >= proposal_expiration,
        error::invalid_argument(EINSUFFICIENT_STAKE_LOCKUP),
    );

    // 4. 创建提案
    let proposal_id = voting::create_proposal_v2(...);

    proposal_id
}
```

---

## 投票机制

### 1. 投票类型

Aptos 支持三种投票方式：

| 投票类型 | 命令 | 说明 |
|---------|------|------|
| 完整投票 | `vote` | 使用质押池的全部投票权 |
| 部分投票 | `partial-vote` | 使用质押池的部分投票权 |
| 批量投票 | `batch-vote` | 使用多个质押池投票 |

### 2. 投票命令

**完整投票:**
```bash
aptos governance vote \
  --proposal-id <PROPOSAL_ID> \
  --pool-address <STAKE_POOL_ADDRESS> \
  --should-pass true
```

**部分投票:**
```bash
aptos governance partial-vote \
  --proposal-id <PROPOSAL_ID> \
  --pool-address <STAKE_POOL_ADDRESS> \
  --voting-power 1000 \
  --should-pass true
```

**批量投票:**
```bash
aptos governance batch-vote \
  --proposal-id <PROPOSAL_ID> \
  --pool-addresses 0x123,0x456,0x789 \
  --should-pass true
```

### 3. 投票权计算

投票权基于质押池在当前 epoch 的投票权重：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:731-742
public fun get_voting_power(pool_address: address): u64 {
    let allow_validator_set_change = staking_config::get_allow_validator_set_change(&staking_config::get());
    if (allow_validator_set_change) {
        let (active, _, pending_active, pending_inactive) = stake::get_stake(pool_address);
        // 投票权 = 所有非 inactive 的质押
        active + pending_active + pending_inactive
    } else {
        stake::get_current_epoch_voting_power(pool_address)
    }
}
```

### 4. 投票限制

- **锁定期要求**: 质押锁定期必须 >= 提案过期时间
- **投票期限制**: 只能在投票期内投票（提案创建后 7 天内）
- **重复投票**: 在部分投票启用前，质押池不能对同一提案投票两次
- **部分投票**: 启用后，质押池可以多次投票，但总投票权不能超过其拥有的投票权

### 5. 投票记录

系统使用两个数据结构跟踪投票：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:99-106
// 旧版本：记录是否已完整投票
struct VotingRecords has key {
    votes: Table<RecordKey, bool>
}

// 新版本：记录已使用的投票权
struct VotingRecordsV2 has key {
    votes: SmartTable<RecordKey, u64>
}
```

### 6. 投票状态

提案有以下几种状态 (`aptos-move/framework/aptos-framework/sources/voting.move`):

| 状态代码 | 状态名称 | 说明 |
|---------|---------|------|
| 0 | `PENDING` | 投票进行中 |
| 1 | `SUCCEEDED` | 投票通过（赞成 > 反对 且达到最低门槛） |
| 2 | `FAILED` | 投票失败 |

### 7. 提前解决

如果超过 50% 的总供应量投票，提案可以提前解决：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:443-449
let total_voting_token_supply = coin::supply<AptosCoin>();
let early_resolution_vote_threshold = option::none<u128>();
if (option::is_some(&total_voting_token_supply)) {
    let total_supply = *option::borrow(&total_voting_token_supply);
    // 50% + 1 避免舍入错误
    early_resolution_vote_threshold = option::some(total_supply / 2 + 1);
};
```

### 8. 查看剩余投票权

```bash
# 使用 view 函数查看
aptos move view \
  --function-id 0x1::aptos_governance::get_remaining_voting_power \
  --args address:<POOL_ADDRESS> u64:<PROPOSAL_ID>
```

---

## 提案执行

### 1. 执行条件

提案必须满足以下所有条件才能执行：

1. **投票期结束**: `current_time > proposal_expiration_secs`
2. **提案通过**: 状态为 `SUCCEEDED` (赞成票 > 反对票 且达到最低门槛)
3. **防闪电贷保护**: 必须在与最后一次投票不同的交易中执行
4. **哈希匹配**: 执行脚本的哈希必须与提案中的 `execution_hash` 匹配

### 2. 执行命令

```bash
aptos governance execute-proposal \
  --proposal-id <PROPOSAL_ID> \
  --script-path <PATH_TO_SCRIPT> \
  --profile <YOUR_PROFILE> \
  --assume-yes
```

或使用已编译的脚本：

```bash
aptos governance execute-proposal \
  --proposal-id <PROPOSAL_ID> \
  --compiled-script-path <PATH_TO_COMPILED_SCRIPT> \
  --profile <YOUR_PROFILE> \
  --assume-yes
```

### 3. 执行权限

**任何人都可以执行已通过的提案**，不需要特殊权限。这是设计上的考虑，确保提案不会因为提议者离线而无法执行。

### 4. resolve() 函数

执行脚本通过调用 `aptos_governance::resolve()` 来获取 framework signer：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:634-641
public fun resolve(
    proposal_id: u64,
    signer_address: address
): signer acquires ApprovedExecutionHashes, GovernanceResponsbility {
    voting::resolve<GovernanceProposal>(@aptos_framework, proposal_id);
    remove_approved_hash(proposal_id);
    get_signer(signer_address)
}
```

**调用流程:**
1. 验证提案状态为 `SUCCEEDED`
2. 标记提案为 `resolved`
3. 移除批准的执行哈希
4. 返回指定地址的 signer（通常是 `@aptos_framework`）

### 5. 执行脚本模板

**基础模板:**
```move
script {
    use aptos_framework::aptos_governance;

    fun main(proposal_id: u64) {
        let framework_signer = aptos_governance::resolve(proposal_id, @aptos_framework);

        // 在这里执行具体的升级操作
        // framework_signer 拥有 @aptos_framework 的权限

        // 如果需要，触发重配置
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

### 6. 重配置机制

某些升级需要触发重配置才能生效：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:685-692
public entry fun reconfigure(aptos_framework: &signer) {
    system_addresses::assert_aptos_framework(aptos_framework);
    if (consensus_config::validator_txn_enabled() && randomness_config::enabled()) {
        reconfiguration_with_dkg::try_start();  // 异步 DKG 重配置
    } else {
        reconfiguration_with_dkg::finish(aptos_framework);  // 立即重配置
    }
}
```

**何时需要重配置:**
- 启用/禁用 feature flags
- 更新 gas schedule
- 修改共识配置
- 升级 framework（可选，但推荐）

**何时不需要重配置:**
- 单纯的数据更新
- 不影响链配置的操作

### 7. 批准执行哈希

对于超过 mempool 大小限制的大型脚本，需要先批准执行哈希：

```bash
aptos governance approve-execution-hash --proposal-id <ID>
```

这会调用：

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:613-630
public fun add_approved_script_hash(proposal_id: u64) {
    let approved_hashes = borrow_global_mut<ApprovedExecutionHashes>(@aptos_framework);

    // 确保提案可以被解决
    let proposal_state = voting::get_proposal_state<GovernanceProposal>(@aptos_framework, proposal_id);
    assert!(proposal_state == PROPOSAL_STATE_SUCCEEDED, error::invalid_argument(EPROPOSAL_NOT_RESOLVABLE_YET));

    let execution_hash = voting::get_execution_hash<GovernanceProposal>(@aptos_framework, proposal_id);

    simple_map::add(&mut approved_hashes.hashes, proposal_id, execution_hash);
}
```

### 8. 防闪电贷保护

系统通过 `resolvable_time` 元数据确保执行不能与最后一次投票在同一交易中：

```move
// aptos-move/framework/aptos-framework/sources/voting.move
let resolvable_time = to_u64(*simple_map::borrow(&proposal.metadata, &utf8(RESOLVABLE_TIME_METADATA_KEY)));
assert!(timestamp::now_seconds() > resolvable_time, error::invalid_state(ERESOLUTION_CANNOT_BE_ATOMIC));
```

---

## 多步提案

### 1. 多步提案概述

多步提案允许将复杂的升级分解为多个步骤，每个步骤可以独立执行和验证。这对于需要特定执行顺序的升级特别有用。

### 2. 创建多步提案

```bash
aptos governance propose \
  --assume-yes \
  --pool-address <STAKE_POOL_ADDRESS> \
  --script-path <STEP1_SCRIPT> \
  --metadata-url <METADATA_URL> \
  --metadata-hash <METADATA_HASH> \
  --is-multi-step true
```

### 3. 多步提案执行

**resolve_multi_step_proposal() 函数:**

```move
// aptos-move/framework/aptos-framework/sources/aptos_governance.move:644-661
public fun resolve_multi_step_proposal(
    proposal_id: u64,
    signer_address: address,
    next_execution_hash: vector<u8>
): signer acquires GovernanceResponsbility, ApprovedExecutionHashes {
    voting::resolve_proposal_v2<GovernanceProposal>(@aptos_framework, proposal_id, next_execution_hash);

    // 如果是最后一步（next_execution_hash 为空）
    if (vector::length(&next_execution_hash) == 0) {
        remove_approved_hash(proposal_id);
    } else {
        // 否则，更新为下一步的哈希
        add_approved_script_hash(proposal_id)
    };

    get_signer(signer_address)
}
```

### 4. 多步执行脚本模板

**第一步（启用 feature flags）:**
```move
script {
    use aptos_framework::aptos_governance;
    use std::features;
    use std::vector;

    fun main(proposal_id: u64, next_execution_hash: vector<u8>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id,
            @aptos_framework,
            next_execution_hash  // 第二步脚本的哈希
        );

        let enable = vector[93u64, 94u64];  // feature flags
        let disable = vector[];
        features::change_feature_flags_for_next_epoch(&framework_signer, enable, disable);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**第二步（升级 framework）:**
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::code;

    fun main(proposal_id: u64, next_execution_hash: vector<u8>, metadata: vector<u8>, code: vector<vector<u8>>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id,
            @aptos_framework,
            next_execution_hash  // 第三步脚本的哈希
        );

        code::publish_package_txn(&framework_signer, metadata, code);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**最后一步（恢复配置）:**
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::gas_schedule;
    use std::vector;

    fun main(proposal_id: u64, gas_schedule_blob: vector<u8>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id,
            @aptos_framework,
            vector::empty<u8>()  // 空 vector 表示这是最后一步
        );

        gas_schedule::set_for_next_epoch(&framework_signer, gas_schedule_blob);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

### 5. 多步提案执行顺序

```bash
# 第一步
aptos governance execute-proposal \
  --proposal-id 123 \
  --script-path ./step1_enable_features.move

# 等待交易确认...

# 第二步
aptos governance execute-proposal \
  --proposal-id 123 \
  --script-path ./step2_upgrade_framework.move

# 等待交易确认...

# 第三步
aptos governance execute-proposal \
  --proposal-id 123 \
  --script-path ./step3_restore_config.move
```

### 6. 多步提案的优势

- **降低风险**: 每一步独立执行和验证
- **灵活性**: 可以在步骤之间暂停和检查
- **依赖管理**: 确保操作按正确顺序执行
- **易于调试**: 如果某一步失败，可以明确知道问题在哪

---

## 常见场景

### 场景 1: 启用新的 Feature Flags

**创建提案脚本** (`enable_features.move`):
```move
script {
    use aptos_framework::aptos_governance;
    use std::features;
    use std::vector;

    fun main(proposal_id: u64) {
        let framework_signer = aptos_governance::resolve(proposal_id, @aptos_framework);

        // 启用 TRANSACTION_PAYLOAD_V2 (93) 和 ORDERLESS_TRANSACTIONS (94)
        let enable = vector[93u64, 94u64];
        let disable = vector[];

        features::change_feature_flags_for_next_epoch(&framework_signer, enable, disable);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**执行流程:**
```bash
# 1. 创建提案
aptos governance propose \
  --pool-address 0x123 \
  --script-path ./enable_features.move \
  --metadata-url "https://github.com/aptos/aips/proposals/feature-flags.json" \
  --metadata-hash "abc123..."

# 2. 投票（7天内）
aptos governance vote \
  --proposal-id 1 \
  --pool-address 0x123 \
  --should-pass true

# 3. 执行（7天后，投票通过）
aptos governance execute-proposal \
  --proposal-id 1 \
  --script-path ./enable_features.move
```

### 场景 2: 升级 Gas Schedule

**创建提案脚本** (`update_gas.move`):
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::gas_schedule;

    fun main(proposal_id: u64, gas_schedule_blob: vector<u8>) {
        let framework_signer = aptos_governance::resolve(proposal_id, @aptos_framework);

        gas_schedule::set_for_next_epoch(&framework_signer, gas_schedule_blob);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**准备 Gas Schedule Blob:**
```bash
# 使用 release-builder 生成
aptos-release-builder generate \
  --output-dir ./output \
  --release-config ./config.yaml
```

### 场景 3: 升级 Framework

**准备工作:**
1. 编译新版本 framework
2. 生成 metadata 和 bytecode
3. 创建升级脚本

**升级脚本** (`upgrade_framework.move`):
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::code;

    fun main(
        proposal_id: u64,
        metadata_serialized: vector<u8>,
        code: vector<vector<u8>>
    ) {
        let framework_signer = aptos_governance::resolve(proposal_id, @aptos_framework);

        code::publish_package_txn(&framework_signer, metadata_serialized, code);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**注意事项:**
- 升级前必须启用所需的 feature flags
- 必须设置正确的 bytecode version
- 建议先在测试网验证

### 场景 4: 完整的多步升级流程

这是一个典型的 framework 升级流程，需要特定的执行顺序：

**步骤 1: 提高 Gas 限制**
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::gas_schedule;

    fun main(proposal_id: u64, next_hash: vector<u8>, high_gas_blob: vector<u8>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id, @aptos_framework, next_hash
        );
        gas_schedule::set_for_next_epoch(&framework_signer, high_gas_blob);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**步骤 2: 启用 Feature Flags**
```move
script {
    use aptos_framework::aptos_governance;
    use std::features;

    fun main(proposal_id: u64, next_hash: vector<u8>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id, @aptos_framework, next_hash
        );
        let enable = vector[93u64, 94u64];
        features::change_feature_flags_for_next_epoch(&framework_signer, enable, vector[]);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**步骤 3: 升级 Framework**
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::code;

    fun main(proposal_id: u64, next_hash: vector<u8>, metadata: vector<u8>, code: vector<vector<u8>>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id, @aptos_framework, next_hash
        );
        code::publish_package_txn(&framework_signer, metadata, code);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

**步骤 4: 恢复 Gas 参数**
```move
script {
    use aptos_framework::aptos_governance;
    use aptos_framework::gas_schedule;
    use std::vector;

    fun main(proposal_id: u64, normal_gas_blob: vector<u8>) {
        let framework_signer = aptos_governance::resolve_multi_step_proposal(
            proposal_id, @aptos_framework, vector::empty<u8>()  // 最后一步
        );
        gas_schedule::set_for_next_epoch(&framework_signer, normal_gas_blob);
        aptos_governance::reconfigure(&framework_signer);
    }
}
```

### 场景 5: 更新治理配置

**更新投票参数:**
```move
script {
    use aptos_framework::aptos_governance;

    fun main(proposal_id: u64) {
        let framework_signer = aptos_governance::resolve(proposal_id, @aptos_framework);

        // 更新治理配置
        // min_voting_threshold: u128
        // required_proposer_stake: u64
        // voting_duration_secs: u64
        aptos_governance::update_governance_config(
            &framework_signer,
            100000,     // 新的最低投票门槛
            1000,       // 新的提议者最低质押
            604800      // 投票期（保持 7 天）
        );
    }
}
```

---

## 故障排查

### 常见错误代码

| 错误代码 | 错误名称 | 原因 | 解决方法 |
|---------|---------|------|---------|
| `0x1` | `EINSUFFICIENT_PROPOSER_STAKE` | 质押量不足 | 增加质押或使用其他质押池 |
| `0x2` | `ENOT_DELEGATED_VOTER` | 不是委托投票人 | 使用正确的账户或更改委托 |
| `0x3` | `EINSUFFICIENT_STAKE_LOCKUP` | 锁定期不足 | 延长锁定期 |
| `0x4` | `EALREADY_VOTED` | 已经投票 | 使用部分投票或等待下个提案 |
| `0x5` | `ENO_VOTING_POWER` | 没有投票权 | 检查质押池状态 |
| `0x6` | `EPROPOSAL_NOT_RESOLVABLE_YET` | 提案还不能执行 | 等待投票期结束或获得更多票 |
| `0x8` | `EPROPOSAL_NOT_RESOLVED_YET` | 提案未解决 | 先执行 resolve |
| `0xF` | `EPROPOSAL_EXPIRED` | 提案已过期 | 无法投票，只能等待执行或失败 |

### 问题 1: 投票失败 - "ENOT_DELEGATED_VOTER"

**症状:**
```
Error: API error: API error Error(VmExecutionFailure):
Transaction failed with error code 0x2 in module 0x1::aptos_governance
```

**原因:**
使用的账户不是指定质押池的委托投票人。

**解决方法:**
```bash
# 1. 查看质押池的委托投票人
aptos move view \
  --function-id 0x1::stake::get_delegated_voter \
  --args address:<STAKE_POOL_ADDRESS>

# 2. 使用正确的账户，或更改委托
aptos stake set-delegated-voter \
  --operator-address <YOUR_ADDRESS>
```

### 问题 2: 执行失败 - "argument length mismatch: expected 6 got 8"

**症状:**
```
ERROR { status_code: UNEXPECTED_VERIFIER_ERROR,
message: "argument length mismatch: expected 6 got 8" }
```

**原因:**
Framework 已升级到使用 8 参数的 `unified_epilogue_v2`，但 `TRANSACTION_PAYLOAD_V2` feature flag 未启用。

**解决方法:**
在升级 framework 之前，先启用 feature flags：
```bash
# 创建多步提案：
# 步骤 1: 启用 feature flags
# 步骤 2: 升级 framework
```

参考代码位置：
- `aptos-move/framework/aptos-framework/sources/transaction_validation.move` (epilogue 函数)
- `types/src/on_chain_config/aptos_features.rs:93-94` (feature flag 定义)

### 问题 3: 执行失败 - "hash mismatch"

**症状:**
```
Transaction execution failed: Hash mismatch
```

**原因:**
执行的脚本与提案中记录的 execution_hash 不匹配。

**解决方法:**
```bash
# 1. 查看提案的 execution_hash
aptos governance show-proposal --proposal-id <ID>

# 2. 计算你的脚本哈希
sha3sum <YOUR_SCRIPT>

# 3. 确保使用完全相同的脚本
```

### 问题 4: 无法执行 - "ERESOLUTION_CANNOT_BE_ATOMIC"

**症状:**
```
Error: Proposal resolution cannot be atomic with the last vote
```

**原因:**
尝试在与最后一次投票相同的交易/区块中执行提案（防闪电贷保护）。

**解决方法:**
```bash
# 等待至少一个区块后再执行
sleep 5
aptos governance execute-proposal --proposal-id <ID> ...
```

### 问题 5: Gas 费用不足

**症状:**
```
Error: Insufficient gas
```

**原因:**
大型升级（如 framework 升级）可能需要很高的 gas。

**解决方法:**
1. 使用多步提案，先临时提高 gas 限制
2. 在执行脚本中增加 gas 参数：
```bash
aptos governance execute-proposal \
  --proposal-id <ID> \
  --max-gas 2000000 \
  --script-path ./script.move
```

### 问题 6: 提案未显示在列表中

**症状:**
`list-proposals` 命令看不到刚创建的提案。

**原因:**
- 节点数据可能被裁剪
- 事件索引延迟

**解决方法:**
```bash
# 直接通过 proposal_id 查看
aptos governance show-proposal --proposal-id <ID>

# 或查询事件
aptos event get-events-by-creation-number \
  --address 0x1 \
  --creation-number <NUMBER>
```

### 问题 7: 测试脚本

**在执行前测试脚本:**

使用模拟工具 (`aptos-move/aptos-release-builder/src/simulate.rs`):

```bash
# 编译 release-builder
cargo build -p aptos-release-builder

# 模拟执行
./target/debug/aptos-release-builder simulate \
  --endpoint https://fullnode.testnet.aptoslabs.com/v1 \
  --script-path ./your_script.move
```

### 调试技巧

1. **使用 `--dry-run` 模拟交易**
```bash
aptos move run-script \
  --script-path ./script.move \
  --dry-run
```

2. **查看详细错误日志**
```bash
aptos governance execute-proposal \
  --proposal-id <ID> \
  --script-path ./script.move \
  --verbose
```

3. **验证提案哈希**
```bash
# 查看提案详情
aptos governance show-proposal --proposal-id <ID>

# 手动验证脚本哈希
python3 << EOF
import hashlib
with open('script.move', 'rb') as f:
    data = f.read()
    hash_value = hashlib.sha3_256(data).hexdigest()
    print(f"Script hash: {hash_value}")
EOF
```

4. **检查链状态**
```bash
# 查看当前 gas feature version
aptos move view \
  --function-id 0x1::gas_schedule::gas_schedule

# 查看启用的 feature flags
aptos move view \
  --function-id 0x1::features::get_enabled_features
```

---

## 附录

### A. 相关代码文件

| 文件路径 | 说明 |
|---------|------|
| `aptos-move/framework/aptos-framework/sources/aptos_governance.move` | 核心治理逻辑 |
| `aptos-move/framework/aptos-framework/sources/voting.move` | 通用投票机制 |
| `aptos-move/framework/aptos-framework/sources/stake.move` | 质押管理 |
| `aptos-move/framework/aptos-framework/sources/gas_schedule.move` | Gas schedule 管理 |
| `aptos-move/framework/aptos-framework/sources/features.move` | Feature flags 管理 |
| `aptos-move/aptos-gas-schedule/src/ver.rs` | Gas feature version 定义 |
| `crates/aptos/src/governance/mod.rs` | CLI 治理工具 |
| `aptos-move/aptos-release-builder/` | 发布构建工具 |

### B. 有用的 View 函数

```bash
# 获取治理配置
aptos move view --function-id 0x1::aptos_governance::get_voting_duration_secs
aptos move view --function-id 0x1::aptos_governance::get_min_voting_threshold
aptos move view --function-id 0x1::aptos_governance::get_required_proposer_stake

# 获取提案状态
aptos move view \
  --function-id 0x1::voting::get_proposal_state \
  --args address:0x1 u64:<PROPOSAL_ID>

# 获取剩余投票权
aptos move view \
  --function-id 0x1::aptos_governance::get_remaining_voting_power \
  --args address:<STAKE_POOL> u64:<PROPOSAL_ID>

# 检查是否已投票
aptos move view \
  --function-id 0x1::aptos_governance::has_entirely_voted \
  --args address:<STAKE_POOL> u64:<PROPOSAL_ID>
```

### C. Gas Feature Version 历史

| Version | Aptos Release | 主要变更 |
|---------|--------------|---------|
| 11 | v1.8 | 初始 gas feature version 系统 |
| 43 | v1.39 | 最新版本（截至本文档） |

参考: `aptos-move/aptos-gas-schedule/src/ver.rs`

### D. 关键 Feature Flags

| Flag ID | 名称 | 说明 |
|---------|------|------|
| 93 | `TRANSACTION_PAYLOAD_V2` | 支持新的交易载荷格式 |
| 94 | `ORDERLESS_TRANSACTIONS` | 支持无序交易（基于 nonce） |

参考: `types/src/on_chain_config/aptos_features.rs`

### E. 联系与支持

- **GitHub Issues**: https://github.com/aptos-labs/aptos-core/issues
- **Aptos Forum**: https://forum.aptoslabs.com/
- **Discord**: https://discord.gg/aptoslabs
- **文档**: https://aptos.dev/

---

**文档版本**: 1.0
**最后更新**: 2025-11-19
**基于代码版本**: aptos-core main branch (commit: 01a7a5ee)
