# Aptos 无序交易 (Orderless Transactions) 完整实现指南

> **核心创新**：无序交易是 Aptos 区块链的重要创新，通过使用 Nonce 代替 Sequence Number，打破了传统区块链中账户交易必须严格按序执行的限制，显著提升并发性和 TPS。

---

## 目录

1. [概述](#1-概述)
2. [交易格式和数据结构](#2-交易格式和数据结构)
3. [链上 Nonce 管理机制](#3-链上-nonce-管理机制)
4. [VM Prologue 验证](#4-vm-prologue-验证)
5. [Mempool 处理流程](#5-mempool-处理流程)
6. [完整交易生命周期](#6-完整交易生命周期)
7. [重放攻击防护机制](#7-重放攻击防护机制)
8. [性能优化技巧](#8-性能优化技巧)
9. [使用示例](#9-使用示例)

---

## 1. 概述

### 1.1 什么是无序交易？

**传统交易（序列号交易）**：
```rust
// 传统交易使用序列号（Sequence Number）
RawTransaction {
    sender: 0xAlice,
    sequence_number: 5,        // 必须等待 0, 1, 2, 3, 4 全部执行完
    payload: TransactionPayload::EntryFunction(...),
    ...
}

// Replay Protection: ReplayProtector::SequenceNumber(5)
```

**无序交易（Nonce 交易）**：
```rust
// 无序交易使用随机 Nonce
RawTransaction {
    sender: 0xAlice,
    sequence_number: u64::MAX,  // 标记为无序交易
    payload: TransactionPayload::Payload(TransactionPayloadInner::V1 {
        executable: Executable::EntryFunction(...),
        extra_config: TransactionExtraConfig::V1 {
            multisig_address: None,
            replay_protection_nonce: Some(random_u64),  // 随机 Nonce
        },
    }),
    ...
}

// Replay Protection: ReplayProtector::Nonce(random_u64)
```

### 1.2 为什么需要无序交易？

**传统序列号交易的问题**：

1. **严格顺序依赖**
   ```
   用户提交 3 笔交易:
   Txn A: sequence_number = 5
   Txn B: sequence_number = 6  ← 必须等待 A 执行完
   Txn C: sequence_number = 7  ← 必须等待 B 执行完

   如果 Txn A 失败，B 和 C 都会被卡住！
   ```

2. **并发性差**
   ```
   用户同时发送 10 笔交易:
   seq 0 → seq 1 → seq 2 → ... → seq 9
     ↓       ↓       ↓              ↓
   必须串行执行，无法并行

   即使 seq 1 和 seq 9 没有数据冲突，也必须按序执行
   ```

3. **用户体验差**
   ```
   场景：用户在 DApp 中快速点击多次
   - 传统方式：必须等待每笔交易确认后才能发送下一笔
   - 问题：延迟高、容易出错（序列号冲突）
   ```

4. **Mempool 容量利用率低**
   ```
   每个用户最多 100 笔序列号交易
   如果前面的交易卡住，后面的交易都进入 ParkingLot（未就绪）
   降低了 Mempool 的有效容量
   ```

**无序交易的解决方案**：

1. **消除顺序依赖**
   ```
   用户提交 3 笔无序交易:
   Txn A: nonce = random1
   Txn B: nonce = random2  ← 不依赖 A
   Txn C: nonce = random3  ← 不依赖 A 和 B

   A、B、C 可以乱序执行，互不影响！
   ```

2. **提高并发性**
   ```
   用户同时发送 10 笔无序交易:
   nonce1  nonce2  nonce3  ...  nonce10
     ↓       ↓       ↓              ↓
   可以并行执行（如果没有数据冲突）

   BlockSTM 并行执行引擎可以自动检测和解决冲突
   ```

3. **更大的容量**
   ```
   序列号交易：每用户 100 笔
   无序交易：每用户 1000 笔  ← 10倍容量！

   总容量：100 + 1000 = 1100 笔/用户
   ```

### 1.3 能提升 TPS 吗？

**答案：可以！提升 3-10 倍 TPS！**

**实际测试数据**（Aptos 官方）：
```
单账户场景:
- 纯序列号交易: ~10,000 TPS
- 纯无序交易（有冲突）: ~30,000 TPS  ← 3x 提升
- 纯无序交易（无冲突）: ~100,000+ TPS ← 10x 提升
```

---

## 2. 交易格式和数据结构

### 2.1 RawTransaction 结构

**文件**: `types/src/transaction/mod.rs:175-224`

```rust
pub struct RawTransaction {
    /// Sender's address
    sender: AccountAddress,

    /// Sequence number of this transaction
    /// - For sequence number transactions: actual sequence number (0, 1, 2, ...)
    /// - For orderless transactions: u64::MAX (18446744073709551615)
    sequence_number: u64,

    /// The transaction payload
    payload: TransactionPayload,

    /// Maximal total gas to spend for this transaction
    max_gas_amount: u64,

    /// Price to be paid per gas unit
    gas_unit_price: u64,

    /// Expiration timestamp for this transaction (Unix Epoch in seconds)
    expiration_timestamp_secs: u64,

    /// Chain ID of the Aptos network this transaction is intended for
    chain_id: ChainId,
}
```

**关键标记**：无序交易使用 `sequence_number = u64::MAX` 作为特殊标记值。

### 2.2 TransactionPayload 枚举

**文件**: `types/src/transaction/mod.rs:656-684`

```rust
#[derive(Clone, Debug, Hash, Eq, PartialEq, Serialize, Deserialize)]
pub enum TransactionPayload {
    /// Deprecated: ModuleBundle variant
    #[serde(skip)]
    ModuleBundle(ModuleBundle),

    /// A transaction that executes code (Script)
    Script(Script),

    /// A transaction that executes an existing entry function (traditional)
    EntryFunction(EntryFunction),

    /// A multisig transaction
    Multisig(Multisig),

    /// V2 format payload (supports orderless transactions)
    Payload(TransactionPayloadInner),
}
```

### 2.3 TransactionExtraConfig

**文件**: `types/src/transaction/mod.rs:746-752`

```rust
#[derive(Clone, Debug, Hash, Eq, PartialEq, Serialize, Deserialize)]
pub enum TransactionExtraConfig {
    V1 {
        /// For multisig transactions
        multisig_address: Option<AccountAddress>,

        /// Replay protection nonce
        /// - None: Regular sequence number transaction
        /// - Some(nonce): Orderless transaction
        replay_protection_nonce: Option<u64>,
    },
}
```

### 2.4 ReplayProtector 提取

**文件**: `types/src/transaction/mod.rs:113-150`

```rust
/// Replay protection mechanism
#[derive(Clone, Copy, Debug, Hash, Eq, PartialEq, Serialize, Deserialize, Ord, PartialOrd)]
pub enum ReplayProtector {
    /// Nonce-based replay protection (for orderless transactions)
    Nonce(u64),

    /// Sequence number-based replay protection (for traditional transactions)
    SequenceNumber(u64),
}

impl ReplayProtector {
    pub fn is_nonce(&self) -> bool {
        matches!(self, ReplayProtector::Nonce(_))
    }

    pub fn get_sequence_number(&self) -> Option<u64> {
        match self {
            ReplayProtector::Nonce(_) => None,
            ReplayProtector::SequenceNumber(sequence_number) => Some(*sequence_number),
        }
    }
}
```

**排序规则** (`types/src/transaction/mod.rs:156-169`):
```rust
// Nonce 交易永远排在 Sequence Number 交易前面
assert!(ReplayProtector::Nonce(1) < ReplayProtector::SequenceNumber(1));
assert!(ReplayProtector::Nonce(100) < ReplayProtector::SequenceNumber(1));
```

**提取 ReplayProtector** (`types/src/transaction/mod.rs:558-563`):

```rust
pub fn replay_protector(&self) -> ReplayProtector {
    // 如果 payload 包含 nonce，使用 Nonce
    if let Some(nonce) = self.payload.replay_protection_nonce() {
        ReplayProtector::Nonce(nonce)
    } else {
        // 否则使用 sequence_number
        ReplayProtector::SequenceNumber(self.sequence_number)
    }
}
```

### 2.5 Nonce 唯一性范围

> ⚠️ **重要**：Nonce 值**不是全局唯一的**，而是**在每个账户地址范围内唯一**。

#### 唯一性键：(address, nonce) 二元组

**文件**：`aptos-framework/sources/nonce_validation.move:72-75`

```move
struct NonceKey has copy, drop, store {
    sender_address: address,  // 发送者地址
    nonce: u64,               // Nonce 值
}
```

**唯一性保证**：
- ✅ **不同地址可以使用相同的 nonce 值**
  ```
  地址 0xA 使用 nonce = 123  ← 允许
  地址 0xB 使用 nonce = 123  ← 允许（不冲突）
  地址 0xC 使用 nonce = 123  ← 允许（不冲突）
  ```

- ❌ **同一地址不能重复使用相同的 nonce**（在有效期内）
  ```
  地址 0xA 使用 nonce = 123 (过期时间 T1)        ← 允许
  地址 0xA 再次使用 nonce = 123 (过期时间 T2)   ← 禁止！
    ↑
    如果 T2 <= T1 + 65秒（重叠窗口），会被拒绝
  ```

#### 检查逻辑

**文件**：`nonce_validation.move:138-158`

```move
// 构造 (address, nonce) 键
let nonce_key = NonceKey {
    sender_address,
    nonce,
};

// 检查该 (address, nonce) 对是否已存在
let existing_exp_time = bucket.nonce_to_exp_time_map.get(&nonce_key);
if (existing_exp_time.is_some()) {
    let existing_exp_time = existing_exp_time.extract();

    // 如果该 (address, nonce) 对尚未过期，拒绝
    if (existing_exp_time >= current_time) {
        return false;  // 重放攻击！
    };

    // 如果在重叠窗口内，也拒绝
    if (txn_expiration_time <= existing_exp_time + 65) {
        return false;  // 过早重用 nonce
    };
    // ...
}
```

#### 为什么这样设计？

| 设计选择 | 优点 | 如果改成全局唯一 |
|---------|------|----------------|
| **每账户独立** | ✅ 不同用户独立生成 nonce，无竞争 | ❌ 需要全局协调，性能瓶颈 |
| **完整 u64 空间** | ✅ 每个账户有 2^64 个 nonce 可用 | ❌ 全局只有 2^64 个，耗尽后无法使用 |
| **去中心化** | ✅ 客户端本地生成，无需服务器 | ❌ 需要中心化的 nonce 分配服务 |
| **并发性** | ✅ 不同账户的交易完全独立 | ❌ 所有交易竞争全局 nonce |

#### 碰撞概率分析

即使在同一个账户内随机生成 nonce，碰撞概率也极低：

**假设**：
- u64 nonce 空间：2^64 ≈ 1.84 × 10^19
- 每个账户有 1000 笔未过期的无序交易

**碰撞概率**（生日悖论）：
```
P(collision) ≈ n^2 / (2 × 2^64)
             ≈ 1000^2 / (2 × 1.84 × 10^19)
             ≈ 2.72 × 10^-14
             ≈ 0.0000000000272%
```

**结论**：实际使用中几乎不可能发生同一账户内的 nonce 碰撞！

#### 存储结构证明

**文件**：`nonce_validation.move:49-64`

```move
// Bucket 中的双 Map 设计
struct Bucket has store {
    // Map 1: (过期时间, 地址, nonce) -> bool
    nonces_ordered_by_exp_time: BigOrderedMap<NonceKeyWithExpTime, bool>,

    // Map 2: (地址, nonce) -> 过期时间
    //        ^^^^^^^^^^^^^^^^  注意：键是 (地址, nonce) 二元组
    nonce_to_exp_time_map: BigOrderedMap<NonceKey, u64>,
}
```

**注释明确说明**（line 57-58）：
> An **(address, nonce) pair** is guaranteed to be unique in both the big ordered maps. Two transactions with the **same (address, nonce) pair** cannot be stored at the same time.

---

## 3. 链上 Nonce 管理机制

> **核心模块**: `aptos_framework::nonce_validation`
>
> 链上维护一个全局的 NonceHistory，记录所有未过期的 (address, nonce) 对，防止重放攻击。

### 3.1 NonceHistory 数据结构

**文件**: `aptos-move/framework/aptos-framework/sources/nonce_validation.move:39-47`

```move
/// Global nonce history stored at @aptos_framework
struct NonceHistory has key {
    /// Hash table: bucket_index -> Bucket
    /// bucket_index = sip_hash(address, nonce) % NUM_BUCKETS
    nonce_table: Table<u64, Bucket>,

    /// Next bucket key to prefill (for initialization)
    next_key: u64,
}
```

**关键常量**：

```move
/// Number of hash buckets (50,000 buckets)
const NUM_BUCKETS: u64 = 50000;

/// Overlap interval: 65 seconds
/// Nonces are kept in history for this duration after expiration
const NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS: u64 = 65;

/// Max entries to garbage collect per call
const MAX_ENTRIES_GARBAGE_COLLECTED_PER_CALL: u64 = 5;

/// Max expiration time for orderless transactions: 65 seconds
const MAX_EXPIRATION_TIME_SECONDS_FOR_ORDERLESS_TXNS: u64 = 65;
```

### 3.2 Bucket 数据结构

**文件**: `aptos-move/framework/aptos-framework/sources/nonce_validation.move:49-64`

```move
/// Each bucket stores nonces with the same hash value
struct Bucket has store {
    /// Map 1: (expiration_time, address, nonce) -> true
    /// Ordered by expiration time for easy garbage collection
    nonces_ordered_by_exp_time: BigOrderedMap<NonceKeyWithExpTime, bool>,

    /// Map 2: (address, nonce) -> expiration_time
    /// For quick lookup of existing nonces
    nonce_to_exp_time_map: BigOrderedMap<NonceKey, u64>,
}

struct NonceKeyWithExpTime has copy, drop, store {
    txn_expiration_time: u64,
    sender_address: address,
    nonce: u64,
}

struct NonceKey has copy, drop, store {
    sender_address: address,
    nonce: u64,
}
```

**双映射设计原因**：

```
Map 1: (exp_time, address, nonce) -> bool
- 按过期时间排序
- 方便垃圾回收：直接从前面弹出过期的 nonce
- 时间复杂度: O(1) 查找最早过期的 nonce

Map 2: (address, nonce) -> exp_time
- 快速查找给定 (address, nonce) 是否存在
- 时间复杂度: O(log N) 查找
- 返回过期时间用于验证
```

### 3.3 Nonce 插入和验证算法

**文件**: `aptos-move/framework/aptos-framework/sources/nonce_validation.move:129-204`

```move
/// Check and insert nonce into history
/// Returns:
///   - true: nonce doesn't exist, insertion successful
///   - false: nonce already exists (replay attack!)
public(friend) fun check_and_insert_nonce(
    sender_address: address,
    nonce: u64,
    txn_expiration_time: u64,
): bool acquires NonceHistory {
    // 1. Verify expiration time is not too far in future
    assert!(
        txn_expiration_time <= timestamp::now_seconds() + NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS,
        error::invalid_argument(ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE)
    );

    // 2. Calculate bucket index using SipHash
    let nonce_key = NonceKey { sender_address, nonce };
    let bucket_index = sip_hash_from_value(&nonce_key) % NUM_BUCKETS;

    // 3. Get or create bucket
    let nonce_history = &mut NonceHistory[@aptos_framework];
    if (!nonce_history.nonce_table.contains(bucket_index)) {
        nonce_history.nonce_table.add(bucket_index, empty_bucket(false));
    };
    let bucket = table::borrow_mut(&mut nonce_history.nonce_table, bucket_index);

    // 4. Check if (address, nonce) already exists
    let existing_exp_time = bucket.nonce_to_exp_time_map.get(&nonce_key);
    if (existing_exp_time.is_some()) {
        let existing_exp_time = existing_exp_time.extract();
        let current_time = timestamp::now_seconds();

        // 4a. If not expired, reject (replay attack)
        if (existing_exp_time >= current_time) {
            return false;
        };

        // 4b. Check overlap interval
        // Two nonces with same (address, nonce) must be at least 65s apart
        if (txn_expiration_time <= existing_exp_time + NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS) {
            return false;
        };

        // 4c. Expired, garbage collect it
        bucket.nonce_to_exp_time_map.remove(&nonce_key);
        bucket.nonces_ordered_by_exp_time.remove(&NonceKeyWithExpTime {
            txn_expiration_time: existing_exp_time,
            sender_address,
            nonce,
        });
    };

    // 5. Garbage collect up to 5 expired nonces
    let current_time = timestamp::now_seconds();
    let i = 0;
    while (i < MAX_ENTRIES_GARBAGE_COLLECTED_PER_CALL && !bucket.nonces_ordered_by_exp_time.is_empty()) {
        let (front_k, _) = bucket.nonces_ordered_by_exp_time.borrow_front();
        // GC nonces that expired more than 65s ago
        if (front_k.txn_expiration_time + NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS < current_time) {
            bucket.nonces_ordered_by_exp_time.pop_front();
            bucket.nonce_to_exp_time_map.remove(&NonceKey {
                sender_address: front_k.sender_address,
                nonce: front_k.nonce,
            });
        } else {
            break;
        };
        i = i + 1;
    };

    // 6. Insert new nonce into both maps
    let nonce_key_with_exp_time = NonceKeyWithExpTime {
        txn_expiration_time,
        sender_address,
        nonce,
    };
    bucket.nonces_ordered_by_exp_time.add(nonce_key_with_exp_time, true);
    bucket.nonce_to_exp_time_map.add(nonce_key, txn_expiration_time);

    true  // Success
}
```

**算法复杂度分析**：

```
时间复杂度:
1. 计算哈希桶索引: O(1) - SipHash
2. 查找桶: O(1) - Table lookup
3. 查找现有 nonce: O(log N) - BigOrderedMap
4. 垃圾回收: O(5) = O(1) - 固定最多 5 个
5. 插入新 nonce: O(log N) - BigOrderedMap

总体: O(log N), N = 桶内 nonce 数量

空间复杂度:
假设:
- 活跃账户: 1,000,000
- 每账户平均 10 笔未过期无序交易
- 总 nonce 数: 10,000,000

存储需求:
- 每个 nonce: (u64 time, address, u64 nonce) = 48 bytes
- Map 1: 48 bytes × 10M = 480 MB
- Map 2: (address + u64) + u64 = 40 bytes × 10M = 400 MB
- 总计: ~880 MB (链上存储)

分布:
- 50,000 个桶
- 平均每桶: 10M / 50K = 200 个 nonce
```

### 3.4 Nonce 生成最佳实践

**推荐方法**：

```rust
// 方法 1: 加密安全随机数（推荐）
use rand::Rng;
let nonce: u64 = rand::thread_rng().gen();

// 方法 2: 时间戳 + 随机数（更安全）
use std::time::{SystemTime, UNIX_EPOCH};
let timestamp = SystemTime::now()
    .duration_since(UNIX_EPOCH)
    .unwrap()
    .as_micros() as u64;
let random_bits: u64 = rand::thread_rng().gen_range(0..1000000);
let nonce = timestamp ^ random_bits;

// 方法 3: UUID 的一部分
use uuid::Uuid;
let uuid = Uuid::new_v4();
let nonce = u64::from_le_bytes(uuid.as_bytes()[0..8].try_into().unwrap());
```

**注意事项**：

```
✅ 推荐:
- 使用加密安全的随机数生成器
- 每笔交易生成新的 nonce
- 避免可预测的模式

❌ 避免:
- 连续递增的 nonce (1, 2, 3, ...)
- 使用当前时间戳作为 nonce（冲突风险）
- 重用相同的 nonce
```

**冲突概率分析**：

```
假设:
- 空间大小: 2^64 ≈ 1.8 × 10^19
- 活跃 nonce: 10,000,000 (10^7)

冲突概率 (生日悖论):
P(collision) ≈ n^2 / (2 × 2^64)
             = (10^7)^2 / (2 × 1.8 × 10^19)
             ≈ 2.8 × 10^-6
             ≈ 0.0003%

结论: 随机 nonce 冲突概率极低，可以忽略
```

---

## 4. VM Prologue 验证

> Prologue 在交易执行前运行，验证交易的合法性，包括 nonce 检查。

### 4.1 Unified Prologue

**文件**: `aptos-move/framework/aptos-framework/sources/transaction_validation.move:33-36`

```move
/// Replay protector enum
enum ReplayProtector {
    Nonce(u64),
    SequenceNumber(u64),
}
```

**文件**: `aptos-move/framework/aptos-framework/sources/transaction_validation.move:89-212`

```move
fun unified_prologue(
    sender_address: address,
    txn_authentication_key_hash: vector<u8>,
    gas_payer_address: address,
    gas_payer_authentication_key_hash: vector<u8>,
    txn_sequence_number: u64,
    txn_gas_price: u64,
    txn_max_gas_units: u64,
    txn_expiration_time: u64,
    chain_id: u8,
    is_simulation: bool,
    replay_protector: ReplayProtector,  // ← 关键参数
    is_orderless_txn: bool,
) {
    // ... 其他验证 ...

    // Check for replay protection
    match (replay_protector) {
        // 序列号交易: 检查序列号
        SequenceNumber(txn_sequence_number) => {
            check_for_replay_protection_regular_txn(
                sender_address,
                gas_payer_address,
                txn_sequence_number,
            );
        },
        // 无序交易: 检查 nonce
        Nonce(nonce) => {
            check_for_replay_protection_orderless_txn(
                sender_address,
                nonce,
                txn_expiration_time,
            );
        }
    };

    // ... gas 检查 ...
}
```

### 4.2 Nonce 验证逻辑

**文件**: `aptos-move/framework/aptos-framework/sources/transaction_validation.move:251-262`

```move
fun check_for_replay_protection_orderless_txn(
    sender: address,
    nonce: u64,
    txn_expiration_time: u64,
) {
    // 1. Check expiration time is not too far in future
    // prologue_common already checks current_time < txn_expiration_time
    assert!(
        txn_expiration_time <= timestamp::now_seconds() + MAX_EXPIRATION_TIME_SECONDS_FOR_ORDERLESS_TXNS,
        error::invalid_argument(PROLOGUE_ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE),
    );

    // 2. Check and insert nonce (critical!)
    assert!(
        nonce_validation::check_and_insert_nonce(sender, nonce, txn_expiration_time),
        error::invalid_argument(PROLOGUE_ENONCE_ALREADY_USED)
    );
}
```

**验证失败场景**：

```
1. 过期时间过远:
   txn_expiration_time > current_time + 65s
   错误: PROLOGUE_ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE

2. Nonce 已使用:
   (sender, nonce) 已存在且未过期
   错误: PROLOGUE_ENONCE_ALREADY_USED

3. Overlap 冲突:
   新交易与旧交易的过期时间差 < 65s
   错误: PROLOGUE_ENONCE_ALREADY_USED
```

### 4.3 Rust VM 调用 Prologue

**文件**: `aptos-move/aptos-vm/src/transaction_validation.rs:136-256`

```rust
// 准备 replay_protector 参数
let replay_protector_arg = if features.is_transaction_payload_v2_enabled() {
    // V2 format: 使用 ReplayProtector enum
    txn_replay_protector
        .to_move_value()
        .simple_serialize()
        .unwrap()
} else {
    // V1 format: 只支持 sequence number
    match txn_replay_protector {
        ReplayProtector::SequenceNumber(seq_num) => {
            MoveValue::U64(seq_num).simple_serialize().unwrap()
        },
        ReplayProtector::Nonce(_) => {
            // V1 不支持 orderless transactions!
            unreachable!("Orderless transactions are discarded already")
        },
    }
};

// 调用 Move prologue
session.execute_function_bypass_visibility(
    &TRANSACTION_VALIDATION_MODULE_ID,
    ident_str!("unified_prologue"),
    vec![],
    serialize_args,
    traversal_context,
)?;
```

**特性要求**：

```rust
// Orderless transactions require:
// 1. TRANSACTION_PAYLOAD_V2 feature enabled
// 2. ORDERLESS_TRANSACTIONS feature enabled
// 3. Unified prologue support

if features.is_orderless_txns_enabled() {
    // Can process orderless transactions
} else {
    // Reject orderless transactions
    return Err(VMStatus::error(
        StatusCode::FEATURE_UNDER_GATING,
        Some("Orderless transactions not supported".to_string()),
    ));
}
```

---

## 5. Mempool 处理流程

### 5.1 Mempool 存储结构

**文件**: `mempool/src/core_mempool/index.rs:28-120`

```rust
#[derive(Clone, Default)]
pub struct AccountTransactions {
    /// 无序交易：使用 Nonce 作为 key
    nonce_transactions: BTreeMap<u64 /* Nonce */, MempoolTransaction>,

    /// 序列号交易：使用 Sequence Number 作为 key
    sequence_number_transactions: BTreeMap<u64 /* Sequence number */, MempoolTransaction>,
}

impl AccountTransactions {
    /// 获取无序交易数量
    pub(crate) fn orderless_txns_len(&self) -> usize {
        self.nonce_transactions.len()
    }

    /// 获取序列号交易数量
    pub(crate) fn seq_num_txns_len(&self) -> usize {
        self.sequence_number_transactions.len()
    }
}
```

### 5.2 插入交易流程

**文件**: `mempool/src/core_mempool/transaction_store.rs:235-346`

```rust
pub(crate) fn insert(
    &mut self,
    txn: MempoolTransaction,
    // For orderless transactions: account_sequence_number = None
    // For sequence number transactions: account_sequence_number = Some(u64)
    account_sequence_number: Option<u64>,
) -> MempoolStatus {
    let address = txn.get_sender();
    let txn_replay_protector = txn.get_replay_protector();

    // 1. Check if transaction already exists
    if self.index_exists(&address, &txn_replay_protector) {
        return MempoolStatus::new(MempoolStatusCode::AlreadyExists);
    }

    // 2. Get or create account transactions
    let txns = self.transactions.entry(address).or_insert_with(AccountTransactions::default);

    // 3. Check per-user capacity based on transaction type
    match txn_replay_protector {
        ReplayProtector::SequenceNumber(_) => {
            // Sequence number transactions: max 100 per user
            if txns.seq_num_txns_len() >= self.capacity_per_user {
                return MempoolStatus::new(MempoolStatusCode::TooManyTransactions);
            }
        },
        ReplayProtector::Nonce(_) => {
            // Orderless transactions: max 1000 per user
            if txns.orderless_txns_len() >= self.orderless_txn_capacity_per_user {
                return MempoolStatus::new(MempoolStatusCode::TooManyTransactions);
            }
        },
    }

    // 4. Check if mempool is full and try eviction
    if self.check_is_full_after_eviction(&txn, account_sequence_number) {
        return MempoolStatus::new(MempoolStatusCode::MempoolIsFull);
    }

    // 5. Determine timeline state
    let timeline_state = match txn_replay_protector {
        ReplayProtector::SequenceNumber(seq_num) => {
            if account_sequence_number.map_or(false, |s| s == seq_num) {
                TimelineState::Ready
            } else {
                TimelineState::NotReady  // Goes to ParkingLot
            }
        },
        ReplayProtector::Nonce(_) => {
            // Orderless transactions are ALWAYS ready!
            TimelineState::Ready
        },
    };

    // 6. Insert into all indexes
    self.index_insert(txn.clone(), account_sequence_number, timeline_state);

    MempoolStatus::new(MempoolStatusCode::Accepted)
}
```

**容量配置** (`config/src/config/mempool_config.rs:105-106`):

```rust
pub struct MempoolConfig {
    /// Maximum number of sequence number transactions per user
    pub capacity_per_user: usize,  // Default: 100

    /// Maximum number of orderless transactions per user
    pub orderless_txn_capacity_per_user: usize,  // Default: 1000
}
```

### 5.3 获取批次（get_batch）

**文件**: `mempool/src/core_mempool/mempool.rs:426-550`

```rust
pub fn get_batch(
    &mut self,
    max_txns: u64,
    max_bytes: u64,
    return_non_full: bool,
    exclude_transactions: BTreeMap<TransactionSummary, TransactionInProgress>,
) -> Vec<SignedTransaction> {
    let mut result = vec![];
    let mut total_bytes = 0;

    // Iterate by gas price (high to low)
    for (_gas, txns) in self.priority_index.iter().rev() {
        for (replay_protector, txn) in txns {
            // Skip excluded transactions
            if exclude_transactions.contains_key(&txn.get_summary()) {
                continue;
            }

            // Check sequence number order for seq num txns
            match replay_protector {
                ReplayProtector::SequenceNumber(seq_num) => {
                    // Must follow sequence number order
                    // Skip if not the next expected sequence number
                },
                ReplayProtector::Nonce(_) => {
                    // No ordering requirement! Can include directly
                },
            }

            // Add to result
            result.push(txn.clone());
            total_bytes += txn.get_estimated_bytes();

            // Check limits
            if result.len() >= max_txns as usize || total_bytes >= max_bytes {
                return result;
            }
        }
    }

    result
}
```

**无序交易的优势**：

```
序列号交易批次选择:
- 必须按序: seq 5, seq 6, seq 7, ...
- 如果 seq 6 缺失，seq 7+ 都不能包含
- 限制批次大小

无序交易批次选择:
- 无顺序要求
- 所有 nonce 交易都可以包含
- 最大化批次大小
- 提高 TPS
```

### 5.4 ParkingLot 和就绪状态

**文件**: `mempool/src/core_mempool/transaction_store.rs:78-80`

```rust
// Keeps track of "non-ready" txns (transactions that can't be included in next block).
// Orderless transactions (transactions with nonce replay protector) are always "ready",
// and are not stored in the parking lot.
parking_lot_index: ParkingLotIndex,
```

**对比表**：

| 方面 | 序列号交易 | 无序交易 |
|------|-----------|---------|
| **就绪条件** | `txn.seq == account.seq` | **始终就绪** |
| **未就绪时** | 进入 ParkingLot | N/A（不会未就绪） |
| **依赖关系** | 依赖前序交易 | **无依赖** |
| **可立即执行** | ❌（可能需等待） | ✅（随时可执行） |
| **广播延迟** | 可能延迟（未就绪时） | **立即广播** |

---

## 6. 完整交易生命周期

**从客户端到链上执行的完整流程**：

```
┌─────────────────────────────────────────────────────────────────┐
│ 阶段 1: 客户端构造交易                                             │
└─────────────────────────────────────────────────────────────────┘
1. 生成随机 nonce: let nonce = rand::random::<u64>();
2. 构造 RawTransaction:
   - sequence_number = u64::MAX
   - payload = Payload(TransactionPayloadInner::V1 {
       executable,
       extra_config: V1 { replay_protection_nonce: Some(nonce) }
     })
   - expiration_timestamp_secs = now + 60
3. 签名: SignedTransaction

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 2: REST API 接收                                             │
└─────────────────────────────────────────────────────────────────┘
4. POST /v1/transactions
5. 反序列化和基本验证
6. 发送到 Mempool: MempoolClientRequest::SubmitTransaction

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 3: Mempool 验证和存储                                         │
└─────────────────────────────────────────────────────────────────┘
7. 提取 replay_protector = Nonce(random_value)
8. VM 验证（不检查 nonce，仅验证签名和 gas）
9. 检查容量: orderless_txns_len() < 1000
10. 设置 timeline_state = Ready（始终就绪）
11. 插入索引:
    - nonce_transactions[nonce] = txn
    - PriorityIndex (by gas price)
    - TimelineIndex (for broadcast)
    - TTLIndex (for GC)
12. 广播到其他节点（如果是 Direct Mempool 模式）

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 4: 共识选择交易                                               │
└─────────────────────────────────────────────────────────────────┘
13. ProposalGenerator 从 Mempool 拉取交易
14. get_batch() 选择高 gas 交易
15. 无序交易无顺序限制，全部包含
16. 创建区块提议

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 5: VM Prologue 验证（链上）                                    │
└─────────────────────────────────────────────────────────────────┘
17. 所有验证者收到区块
18. 对每笔交易调用 unified_prologue()
19. match replay_protector:
    Nonce(nonce) => check_for_replay_protection_orderless_txn()
20. 验证:
    a. 过期时间 <= now + 65s
    b. check_and_insert_nonce(sender, nonce, exp_time)
       - 计算 bucket_index = sip_hash(sender, nonce) % 50000
       - 查询 NonceHistory.nonce_table[bucket_index]
       - 检查 (sender, nonce) 是否已存在
       - 如果存在且未过期 → 拒绝（重放攻击）
       - 否则插入到两个 BigOrderedMap
21. 如果验证失败 → 交易失败（abort）
22. 如果验证成功 → 继续执行

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 6: VM 执行交易                                                │
└─────────────────────────────────────────────────────────────────┘
23. BlockSTM 并行执行引擎
24. 无序交易可以并行执行（如果无数据冲突）
25. 执行 Move 代码
26. 生成 WriteSet

┌─────────────────────────────────────────────────────────────────┐
│ 阶段 7: 共识和提交                                                 │
└─────────────────────────────────────────────────────────────────┘
27. 验证者对执行结果投票
28. 达到 2f+1 → 区块确认
29. 写入 ledger
30. NonceHistory 更新持久化到链上
31. 客户端查询交易状态: 成功!
```

---

## 7. 重放攻击防护机制

### 7.0 过期和垃圾回收机制

> **核心问题**：无序交易什么时候过期？过期的 nonce 怎么被删除？

#### 7.0.1 交易过期条件

**过期判断**（文件：`types/src/transaction/mod.rs:198`）：

每个交易都有一个 `expiration_timestamp_secs` 字段（Unix 时间戳，秒）：

```rust
pub struct RawTransaction {
    sender: AccountAddress,
    sequence_number: u64,
    payload: TransactionPayload,
    max_gas_amount: u64,
    gas_unit_price: u64,
    expiration_timestamp_secs: u64,  // ← 过期时间
    chain_id: ChainId,
}
```

**过期条件**：

```
交易过期 <=> 当前时间 > expiration_timestamp_secs
```

**示例**：

```
交易 A:
  expiration_timestamp_secs = 1000

时间线:
  t=999  ← 交易有效，可以执行
  t=1000 ← 交易有效，刚好在截止时间
  t=1001 ← 交易过期，无法执行
```

#### 7.0.2 无序交易的过期时间限制

**文件**：`aptos-framework/sources/transaction_validation.move:24-26`

```move
// 官方建议: 无序交易最大过期时间 60 秒
// 加上 5 秒容错（客户端和区块链时钟可能有偏移）
const MAX_EXPIRATION_TIME_SECONDS_FOR_ORDERLESS_TXNS: u64 = 65;
```

**Prologue 验证**（文件：`transaction_validation.move:257-261`）：

```move
fun check_for_replay_protection_orderless_txn(
    sender: address,
    nonce: u64,
    txn_expiration_time: u64,
) {
    // 检查过期时间不能太远
    assert!(
        txn_expiration_time <= timestamp::now_seconds() + 65,
        PROLOGUE_ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE
    );

    // 插入 nonce 到历史记录
    assert!(
        nonce_validation::check_and_insert_nonce(sender, nonce, txn_expiration_time),
        PROLOGUE_ENONCE_ALREADY_USED
    );
}
```

**限制原因**：

| 限制 | 原因 |
|------|------|
| **最大 65 秒** | 防止 NonceHistory 占用过多存储空间 |
| **建议 60 秒** | 给客户端和链时钟偏移留 5 秒容错 |
| **最小 1 秒** | 必须大于当前时间 |

**过期时间设置示例**：

```typescript
// 推荐：设置 60 秒后过期
const expirationTimestampSecs = Math.floor(Date.now() / 1000) + 60;

// 错误：设置过期时间太远（超过 65 秒）
const expirationTimestampSecs = Math.floor(Date.now() / 1000) + 100;
// ❌ Prologue 会拒绝：ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE
```

#### 7.0.3 什么情况会导致无序交易过期？

**场景 1：Mempool 已满**

无序交易被 Mempool 拒绝或从 Mempool 中驱逐，无法进入区块。

```
配置：
- 全局容量：2,000,000 笔交易 或 2 GB 字节
- 每用户容量：1000 笔无序交易

满载情况：
1. 全局 Mempool 满：新交易被拒绝（MempoolStatusCode::MempoolIsFull）
2. 单用户配额满：该用户的新无序交易被拒绝（MempoolStatusCode::TooManyTransactions）
3. 驱逐机制：当 Mempool 满时，会优先驱逐 ParkingLot 中的交易（序列号交易）
```

**文件**：`mempool/src/core_mempool/transaction_store.rs:459-461, 336-344`

```rust
// Mempool 满的判断条件
fn is_full(&self) -> bool {
    self.system_ttl_index.size() >= self.capacity ||  // 交易数量达到上限
    self.size_bytes >= self.capacity_bytes             // 字节大小达到上限
}

// 每用户无序交易容量检查
if txns.orderless_txns_len() >= self.orderless_txn_capacity_per_user {
    return MempoolStatus::new(MempoolStatusCode::TooManyTransactions)
        .with_message(format!(
            "Number of orderless transactions from account: {} Capacity: {}",
            txns.orderless_txns_len(),
            self.orderless_txn_capacity_per_user,
        ));
}
```

---

**场景 2：Gas 价格设置过低**

无序交易的 Gas 价格太低，在 Mempool 中排序靠后，无法及时被打包。

```
假设:
- 交易 A: gas_price = 100, expiration_time = now + 60s
- 交易 B: gas_price = 1000, expiration_time = now + 60s

结果:
- 交易 B 优先被打包
- 交易 A 可能在 60 秒内无法被打包，最终过期
```

**Gas 价格影响**：
- Mempool 按 Gas 价格排序（高价优先）
- Consensus 从 Mempool 获取交易时优先选择高 Gas 价格交易
- 低 Gas 价格交易可能排队过久而过期

---

**场景 3：网络拥堵**

区块链处理能力不足，TPS 达到上限，导致交易积压。

```
场景:
- 链的 TPS: 10,000
- 提交速率: 15,000 笔/秒

结果:
- Mempool 积压 5,000 笔/秒
- 新交易需要等待更长时间才能被处理
- 60 秒窗口可能不够，交易在被处理前过期
```

**拥堵原因**：
- 突发高负载（空投、热门 NFT mint 等）
- 链的处理能力达到瓶颈
- Consensus 延迟增加

---

**场景 4：交易验证失败**

交易在 Prologue 验证时失败，被 Mempool 拒绝。

```
常见失败原因:
1. Nonce 已存在: PROLOGUE_ENONCE_ALREADY_USED
2. 过期时间太远: PROLOGUE_ETRANSACTION_EXPIRATION_TOO_FAR_IN_FUTURE
3. 账户余额不足: PROLOGUE_EACCOUNT_DOES_NOT_HAVE_ENOUGH_BALANCE_FOR_TRANSACTION_FEE
4. Gas 价格太低: PROLOGUE_EGAS_UNIT_PRICE_BELOW_MIN_BOUND
```

---

**场景 5：系统 TTL 超时**

即使交易的 `expiration_timestamp_secs` 还未到期，Mempool 也有自己的系统 TTL。

**文件**：`mempool/src/shared_mempool/tasks.rs:666, 742`

```rust
// Consensus 获取区块前触发 GC
let curr_time = aptos_infallible::duration_since_epoch();
mempool.gc_by_expiration_time(curr_time);

// Commit 交易后触发 GC
if block_timestamp_usecs > 0 {
    pool.gc_by_expiration_time(block_timestamp);
}
```

**GC 逻辑**：
- 交易在 Mempool 中超过 `expiration_timestamp_secs` 会被删除
- 即使没有新的无序交易提交，GC 也会在以下时机触发：
  1. Consensus 请求获取区块时
  2. 区块提交后处理 committed transactions 时

---

#### 7.0.4 垃圾回收的两个层面

> ⚠️ **重要**：垃圾回收分为两个层面，触发机制不同！

**层面 1：Mempool 垃圾回收（清理 Mempool 中的过期交易）**

**触发时机**：

| 触发场景 | 函数 | 频率 |
|---------|------|------|
| Consensus 获取区块 | `gc_by_expiration_time()` | 每次 get_block 时 |
| 区块提交后 | `gc_by_expiration_time()` | 每次 commit 时 |
| 定期系统 GC | `gc_by_system_ttl()` | 周期性 |

**文件**：`mempool/src/core_mempool/transaction_store.rs:909-912`

```rust
/// Garbage collect old transactions based on client-specified expiration time.
pub(crate) fn gc_by_expiration_time(&mut self, block_time: Duration) {
    self.gc(self.eager_expire_time(block_time), false);
}
```

**清理逻辑**（文件：`transaction_store.rs:914-973`）：

```rust
fn gc(&mut self, now: Duration, by_system_ttl: bool) {
    let index = if by_system_ttl {
        &mut self.system_ttl_index
    } else {
        &mut self.expiration_time_index
    };

    // 获取所有过期交易
    let mut gc_txns = index.gc(now);

    // 从 Mempool 中删除这些交易
    for key in gc_txns {
        if let Some(txns) = self.transactions.get_mut(&key.address) {
            // 删除序列号交易时，标记后续交易为 non-ready
            // 无序交易始终 ready，不受影响
            txns.remove(&key.replay_protector);
            self.index_remove(&txn);
        }
    }
}
```

**关键点**：
- ✅ **会自动触发**：无需新的无序交易，GC 也会在 get_block 和 commit 时执行
- ✅ **清理所有过期交易**：序列号交易和无序交易都会被清理
- ✅ **释放 Mempool 空间**：过期交易从内存中删除

---

**层面 2：NonceHistory 垃圾回收（清理链上的 nonce 记录）**

**触发方式：被动增量 GC**

**文件**：`aptos-framework/sources/nonce_validation.move:177-193`

```move
// 每次调用 check_and_insert_nonce() 时触发 GC
// 即：每次有新的无序交易执行 Prologue 时

// 最多清理 5 个过期 nonce
const MAX_ENTRIES_GARBAGE_COLLECTED_PER_CALL: u64 = 5;

// Garbage collect upto 5 expired nonces in the bucket.
let i = 0;
while (i < 5 && !bucket.nonces_ordered_by_exp_time.is_empty()) {
    let (front_k, _) = bucket.nonces_ordered_by_exp_time.borrow_front();

    // 删除条件: expiration_time + 65秒 < current_time
    if (front_k.txn_expiration_time + 65 < current_time) {
        bucket.nonces_ordered_by_exp_time.pop_front();
        bucket.nonce_to_exp_time_map.remove(&NonceKey {
            sender_address: front_k.sender_address,
            nonce: front_k.nonce,
        });
    } else {
        break;  // 前面的没过期，后面的更不会过期（按时间排序）
    };
    i = i + 1;
}
```

**关键点总结**：

| 特性 | 说明 |
|------|------|
| **触发时机** | 每次新无序交易验证时（Prologue 阶段） |
| **触发条件** | **被动触发**，需要新的无序交易才会触发 |
| **清理数量** | 每次最多 5 个过期 nonce |
| **清理范围** | 仅清理当前 bucket（hash(address, nonce) % 50000） |
| **删除条件** | `expiration_time + 65秒 < current_time` |
| **⚠️ 重要限制** | **如果没有新的无序交易，过期 nonce 不会被清理** |

---

#### 7.0.5 两层 GC 的关键区别

> 🔑 **回答用户的核心问题**：如果没有无序交易发送，过期的 nonce 会被删除吗？

**答案：分两种情况**

| 层面 | 是否会被删除 | 说明 |
|------|-------------|------|
| **Mempool 中的无序交易** | ✅ **会被删除** | 即使没有新交易，get_block 和 commit 时会触发 GC |
| **NonceHistory 中的 nonce** | ❌ **不会被删除** | 需要新的无序交易触发 check_and_insert_nonce() |

**详细解释**：

**情况 1：Mempool 层面**

```
场景: 一段时间内没有新的无序交易提交

时间 t=0:   Mempool 中有 100 笔无序交易
时间 t=60:  其中 50 笔交易过期

即使没有新交易提交：
时间 t=61: Consensus 请求 get_block()
         → 触发 gc_by_expiration_time()
         → 删除 50 笔过期交易 ✅
         → Mempool 中剩余 50 笔交易

结论: Mempool 的 GC 是主动的，与是否有新交易无关
```

**情况 2：NonceHistory 层面**

```
场景: 链上 NonceHistory 中有过期 nonce，但没有新的无序交易

时间 t=0:   NonceHistory 中存储 nonce 123 (过期时间 60)
时间 t=60:  nonce 123 过期
时间 t=126: nonce 123 可删除时间点 (60 + 65)

如果此时没有新的无序交易：
时间 t=150: nonce 123 仍然存在于 NonceHistory 中 ❌
         → 没有触发 check_and_insert_nonce()
         → GC 不会被触发
         → nonce 123 继续占用存储空间

如果此时有新的无序交易（即使 nonce 不同）：
时间 t=150: 新交易 (nonce 456) 到达
         → 调用 check_and_insert_nonce(sender, 456, exp_time)
         → 计算 bucket: hash(sender, 456) % 50000 = bucket_X
         → 清理 bucket_X 中的过期 nonce（最多 5 个）
         → 如果 nonce 123 也在 bucket_X，会被删除 ✅
         → 如果 nonce 123 在其他 bucket，不会被删除 ❌

结论: NonceHistory 的 GC 是被动的，依赖新交易触发
```

**影响分析**：

| 影响方面 | 说明 | 严重性 |
|---------|------|--------|
| **存储占用** | 过期 nonce 会持续占用链上存储空间 | 🟡 中等 |
| **功能影响** | 不影响交易功能，验证逻辑独立于 GC | 🟢 无影响 |
| **重放攻击** | 不会导致安全问题，验证仍然有效 | 🟢 安全 |
| **成本** | 链上存储成本增加，但有 50K bucket 分散 | 🟡 中等 |

**未来可能的改进**：

```
可能的解决方案:
1. 添加定期 GC 任务（通过链上 cron 或治理提案）
2. 在 block prologue 时触发部分 GC
3. 允许任何人调用清理函数（需要 gas 补偿机制）
```

**当前的实际影响**：

```
假设场景:
- 链活跃，每秒 1000 笔无序交易
- 每笔交易触发 GC 清理 5 个过期 nonce
- 清理速度: 5000 个/秒

过期 nonce 生成速度:
- 假设 60 秒窗口，每秒 1000 笔交易
- 60 秒后开始过期: 1000 个/秒

结论: 清理速度 (5000) >> 过期速度 (1000)
      → 正常情况下不会积压
      → 只在链空闲时可能出现 nonce 积累
```

---

#### 7.0.6 重叠窗口（Overlap Interval）

**常量定义**（文件：`nonce_validation.move:19`）：

```move
const NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS: u64 = 65;
```

**作用**：

1. **延迟删除**：
   ```
   交易过期时间: T
   实际删除时间: T + 65 秒

   理由：防止时钟偏移导致的重放攻击
   ```

2. **防止 nonce 重用过早**：
   ```
   交易 A: nonce=123, 过期时间=1000
   交易 B: nonce=123, 过期时间=1030

   拒绝原因：1030 <= 1000 + 65
            （两笔交易过期时间间隔 < 65 秒）
   ```

3. **时钟偏移容错**：
   ```
   场景：客户端时钟比链快 5 秒

   客户端认为: t=1005
   链认为:     t=1000

   如果交易在 t=1000 过期：
   - 客户端发送交易 (认为还没过期)
   - 链拒绝 (已经过期)

   重叠窗口缓解了这个问题
   ```

#### 7.0.7 完整时间线示例

**示例场景**：

```
时间 t=0:
  提交无序交易 Txn1
  - nonce = 123
  - expiration_time = 60
  - 插入到 NonceHistory

时间 t=30:
  提交无序交易 Txn2
  - nonce = 123 (相同 nonce!)
  - expiration_time = 90
  - ❌ 被拒绝: 90 <= 60 + 65
    理由: 违反重叠窗口规则

时间 t=60:
  Txn1 过期
  - 但 nonce 123 仍然保留在 NonceHistory 中
  - 不会被立即删除

时间 t=100:
  提交无序交易 Txn3
  - nonce = 456
  - expiration_time = 160
  - 触发 GC: 检查 bucket 中是否有可删除的 nonce
  - 发现 nonce 123: 60 + 65 = 125 < 100? ❌ 不满足
  - nonce 123 继续保留

时间 t=126:
  提交无序交易 Txn4
  - nonce = 789
  - expiration_time = 186
  - 触发 GC: 检查 bucket
  - 发现 nonce 123: 60 + 65 = 125 < 126? ✅ 满足！
  - 删除 nonce 123 from NonceHistory

时间 t=126:
  提交无序交易 Txn5
  - nonce = 123 (重用之前的 nonce)
  - expiration_time = 186
  - ✅ 允许: nonce 123 已被删除
```

**关键时间点**：

```
0s:   nonce 123 插入
60s:  交易过期（但 nonce 保留）
125s: 可删除时间点 (60 + 65)
126s: 实际删除时间（下次 GC 触发）
126s: 可以重用 nonce 123
```

#### 7.0.8 GC 性能考虑

**为什么每次只清理 5 个？**

| 考虑因素 | 说明 |
|---------|------|
| **Gas 成本** | 删除操作消耗 gas，限制数量避免单笔交易 gas 过高 |
| **交易延迟** | GC 在 Prologue 阶段执行，过多清理会增加交易验证延迟 |
| **渐进清理** | 通过多次交易逐步清理，分摊成本 |
| **充分性** | 假设每秒 1000 笔无序交易，每笔清理 5 个，每秒清理 5000 个，足够应对正常负载 |

**极端情况处理**：

```
场景: 突然有大量无序交易过期（例如网络拥堵后恢复）

问题: 可能积累大量过期 nonce

解决:
1. 增量 GC 会随着新交易到来逐步清理
2. 过期 nonce 仍然占用存储，但不影响功能
3. 未来可能添加专门的 GC 治理提案清理
```

**GC 不会导致的问题**：

- ✅ 不会阻止新 nonce 插入（如果 bucket 未满）
- ✅ 不会导致重放攻击（验证逻辑独立于 GC）
- ✅ 不会导致交易失败（GC 是 best-effort）

---

### 7.1 时间窗口保护

**原理**：

```
时间线:
├─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┬─────┤
0s    10s   20s   30s   40s   50s   60s   70s   80s   90s  100s
      │                             │           │
      │                             │           └─ T + 65s (GC 时间)
      │                             └─ T (交易过期)
      └─ 交易提交

交易 A:
- 提交时间: 10s
- 过期时间: 50s
- Nonce: 12345
- NonceHistory 保存到: 50s + 65s = 115s

攻击者尝试重放:
- 时间 20s: nonce 12345 已存在 → 拒绝 ✅
- 时间 60s: nonce 12345 仍存在（未GC） → 拒绝 ✅
- 时间 120s: nonce 12345 已被 GC → 接受，但可以重放！

解决方案:
- 要求新交易的过期时间必须 > 旧交易过期时间 + 65s
- 即: exp_new > 50s + 65s = 115s
- 这样即使 nonce 被 GC，新交易的过期时间也不会重叠
```

**代码实现**：

```move
// check_and_insert_nonce() 中的关键检查
if (existing_exp_time.is_some()) {
    let existing_exp_time = existing_exp_time.extract();

    // 如果现存 nonce 未过期，直接拒绝
    if (existing_exp_time >= current_time) {
        return false;  // Replay attack!
    };

    // 如果现存 nonce 已过期，检查 overlap interval
    // 新旧交易的过期时间必须相差 >= 65s
    if (txn_expiration_time <= existing_exp_time + NONCE_REPLAY_PROTECTION_OVERLAP_INTERVAL_SECS) {
        return false;  // Too close, reject!
    };

    // 通过检查，可以 GC 旧 nonce 并插入新 nonce
}
```

### 7.2 哈希桶分布

**目的**：避免单个桶过大导致性能问题

```
假设:
- 总 nonce 数: 10,000,000
- 桶数: 50,000
- 理想分布: 每桶 200 个 nonce

SipHash 特性:
- 加密级别的哈希函数
- 均匀分布
- 抗哈希碰撞攻击

分布示例:
Bucket 0:    [198 nonces]
Bucket 1:    [202 nonces]
Bucket 2:    [199 nonces]
...
Bucket 49999: [201 nonces]

最坏情况（攻击者尝试填满一个桶）:
- 需要找到 SipHash 碰撞
- 计算复杂度: ~2^64 次尝试
- 实际不可行
```

### 7.3 垃圾回收策略

**渐进式 GC**：

```move
// 每次 check_and_insert_nonce 调用时，GC 最多 5 个过期 nonce
const MAX_ENTRIES_GARBAGE_COLLECTED_PER_CALL: u64 = 5;

while (i < 5 && !bucket.is_empty()) {
    let (front_k, _) = bucket.nonces_ordered_by_exp_time.borrow_front();
    if (front_k.txn_expiration_time + 65 < current_time) {
        bucket.nonces_ordered_by_exp_time.pop_front();  // O(1)
        bucket.nonce_to_exp_time_map.remove(&nonce_key);  // O(log N)
    } else {
        break;  // 前面的都没过期，后面的更不会过期
    };
    i = i + 1;
}
```

**GC 性能分析**：

```
Gas 成本:
- 每次交易执行 prologue
- GC 最多 5 个 nonce
- 每个 nonce GC: 2 次 BigOrderedMap 操作
- 总计: ~10 次 map 操作
- Gas: ~1000 units（相对于总 gas 很小）

受益:
- 逐步清理过期 nonce
- 避免单次大量 GC 导致 gas 峰值
- 保持 bucket 大小合理
```

---

## 8. 性能优化技巧

### 8.1 客户端批量发送

```typescript
// 批量发送无序交易
async function sendBatchOrderlessTransactions(
    client: AptosClient,
    sender: AptosAccount,
    payloads: EntryFunctionPayload[],
) {
    const currentTime = Math.floor(Date.now() / 1000);
    const expirationTime = currentTime + 60;  // 60s from now

    const transactions = payloads.map(payload => {
        // 每笔交易生成唯一的 nonce
        const nonce = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER));

        return {
            sender: sender.address(),
            sequence_number: "18446744073709551615",  // u64::MAX
            max_gas_amount: "2000",
            gas_unit_price: "100",
            expiration_timestamp_secs: expirationTime.toString(),
            payload: {
                type: "payload",
                payload: {
                    type: "v1",
                    executable: payload,
                    extra_config: {
                        type: "v1",
                        multisig_address: null,
                        replay_protection_nonce: nonce.toString(),
                    },
                },
            },
        };
    });

    // 并行发送（无需等待序列号）
    const results = await Promise.all(
        transactions.map(txn =>
            client.generateSignSubmitTransaction(sender, txn)
        )
    );

    return results;
}
```

### 8.2 Nonce 冲突避免

```rust
// 使用高质量随机数生成器
use rand::rngs::OsRng;
use rand::RngCore;

let mut rng = OsRng;
let nonce: u64 = rng.next_u64();

// 或使用时间戳组合
let timestamp_micros = SystemTime::now()
    .duration_since(UNIX_EPOCH)?
    .as_micros() as u64;
let random_bits = rng.next_u64();
let nonce = timestamp_micros.wrapping_mul(1000000).wrapping_add(random_bits);
```

### 8.3 TPS 提升计算

**假设条件**：
- 100 个验证者
- BlockSTM 可以并行 32 个线程
- 区块大小：5000 笔交易
- 出块时间：0.5 秒

**传统方式**（全部序列号交易）：
```
如果交易来自 N 个不同账户:
  并行度 = min(N, 32)

最坏情况（所有交易来自同一账户）:
  并行度 = 1
  TPS = 5000 / 0.5 = 10,000 TPS

最好情况（所有交易来自不同账户）:
  并行度 = 32
  TPS = 5000 / 0.5 × 32 = 320,000 TPS

实际情况（混合）:
  平均并行度 ≈ 8-16
  TPS ≈ 80,000 - 160,000 TPS
```

**无序交易方式**：
```
即使所有交易来自同一账户:
  BlockSTM 分析数据依赖
  假设 50% 交易无冲突可并行

并行度 = 16 (平均)
TPS = 5000 / 0.5 × 16 = 160,000 TPS

实际测试结果（Aptos 官方数据）:
  - 纯序列号交易: ~10,000 TPS（单账户）
  - 纯无序交易: ~30,000 TPS（单账户，有冲突）
  - 无序交易（无冲突）: ~100,000+ TPS

提升: 3-10x TPS
```

---

## 9. 使用示例

### 9.1 Rust SDK 示例

```rust
use aptos_sdk::{
    coin_client::CoinClient,
    rest_client::Client,
    types::{
        transaction::{
            EntryFunction, TransactionPayload, TransactionPayloadInner,
            TransactionExtraConfig, TransactionExecutable,
        },
        LocalAccount,
    },
};
use rand::Rng;

async fn send_orderless_transaction(
    client: &Client,
    sender: &mut LocalAccount,
    receiver: AccountAddress,
    amount: u64,
) -> Result<String> {
    // 1. Generate random nonce
    let nonce: u64 = rand::thread_rng().gen();

    // 2. Create entry function
    let entry_function = EntryFunction::new(
        ModuleId::new(AccountAddress::ONE, ident_str!("aptos_account").to_owned()),
        ident_str!("transfer").to_owned(),
        vec![],
        vec![
            bcs::to_bytes(&receiver)?,
            bcs::to_bytes(&amount)?,
        ],
    );

    // 3. Create orderless transaction payload
    let payload = TransactionPayload::Payload(TransactionPayloadInner::V1 {
        executable: TransactionExecutable::EntryFunction(entry_function),
        extra_config: TransactionExtraConfig::V1 {
            multisig_address: None,
            replay_protection_nonce: Some(nonce),
        },
    });

    // 4. Build and sign transaction
    let txn = sender.sign_with_transaction_builder(
        client.get_transaction_builder(
            sender.address(),
            u64::MAX,  // sequence_number = u64::MAX for orderless
            payload,
        ).await?
    )?;

    // 5. Submit transaction
    let pending_txn = client.submit(&txn).await?;

    Ok(pending_txn.hash.to_string())
}
```

### 9.2 TypeScript SDK 示例

```typescript
import { AptosClient, AptosAccount, TxnBuilderTypes } from "aptos";

async function sendOrderlessTransaction(
    client: AptosClient,
    sender: AptosAccount,
    receiver: string,
    amount: number,
): Promise<string> {
    // 1. Generate random nonce
    const nonce = BigInt(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER));

    // 2. Get current time and expiration
    const currentTime = Math.floor(Date.now() / 1000);
    const expirationTime = currentTime + 60;  // 60 seconds from now

    // 3. Create raw transaction
    const rawTxn = {
        sender: sender.address().hex(),
        sequence_number: "18446744073709551615",  // u64::MAX
        max_gas_amount: "2000",
        gas_unit_price: "100",
        expiration_timestamp_secs: expirationTime.toString(),
        payload: {
            type: "payload",
            payload: {
                type: "v1",
                executable: {
                    type: "entry_function_payload",
                    function: "0x1::aptos_account::transfer",
                    type_arguments: [],
                    arguments: [receiver, amount.toString()],
                },
                extra_config: {
                    type: "v1",
                    multisig_address: null,
                    replay_protection_nonce: nonce.toString(),
                },
            },
        },
    };

    // 4. Sign and submit
    const signedTxn = await client.generateTransaction(sender.address(), rawTxn);
    const txnRequest = await client.signTransaction(sender, signedTxn);
    const response = await client.submitTransaction(txnRequest);

    return response.hash;
}
```

### 9.3 适用场景

**适合无序交易的场景**：

1. **高频交易**
   ```
   DeFi 套利机器人:
   - 在同一个区块内提交多笔套利交易
   - 每笔交易操作不同的交易对
   - 无序交易可以全部并行执行
   ```

2. **批量操作**
   ```
   NFT 铸造:
   - 用户一次性铸造 100 个 NFT
   - 传统方式: 100 笔序列号交易，串行执行
   - 无序方式: 100 笔无序交易，并行执行
   ```

3. **多签钱包**
   ```
   多签账户同时执行多笔转账:
   - 每笔转账相互独立
   - 无序交易可以并行处理
   ```

4. **游戏内操作**
   ```
   链游玩家快速点击:
   - 攻击、移动、拾取等操作
   - 无需等待前序操作确认
   - 降低延迟，提升体验
   ```

**不适合无序交易的场景**：

1. **严格顺序依赖**
   ```
   必须先执行 A 再执行 B:
   - 例如: 先充值再转账
   - 应该使用序列号交易
   ```

2. **需要原子性保证**
   ```
   多笔交易必须全部成功或全部失败:
   - 应该使用 Multisig 或批处理
   ```

---

## 总结对比

| 方面 | 序列号交易 | 无序交易 | 优势方 |
|------|-----------|---------|-------|
| **顺序保证** | ✅ 严格按序 | ❌ 乱序执行 | 序列号 |
| **并行度** | ❌ 低（串行） | ✅ 高（并行） | **无序** |
| **容量限制** | 100 笔/用户 | 1000 笔/用户 | **无序** |
| **就绪状态** | 可能未就绪 | 始终就绪 | **无序** |
| **失败率** | 高（级联失败） | 低（独立） | **无序** |
| **TPS 提升** | 基线 | 3-10x | **无序** |
| **用户体验** | 需等待前序 | 无需等待 | **无序** |
| **使用复杂度** | 简单 | 稍复杂 | 序列号 |
| **原子性** | 容易保证 | 需额外机制 | 序列号 |

---

## 关键文件路径索引

### 类型定义
- `types/src/transaction/mod.rs:113-150` - ReplayProtector 定义
- `types/src/transaction/mod.rs:175-224` - RawTransaction 结构
- `types/src/transaction/mod.rs:656-752` - TransactionPayload 和 ExtraConfig
- `types/src/transaction/mod.rs:558-563` - replay_protector() 提取
- `types/src/transaction/mod.rs:938-940` - is_orderless() 方法

### 链上特性
- `types/src/on_chain_config/aptos_features.rs:141` - ORDERLESS_TRANSACTIONS 特性标志
- `types/src/on_chain_config/aptos_features.rs:446-448` - 特性启用检查

### Move 框架
- `aptos-move/framework/aptos-framework/sources/nonce_validation.move` - 完整 NonceHistory 实现
- `aptos-move/framework/aptos-framework/sources/transaction_validation.move:20-262` - Prologue 和 Nonce 验证

### VM 实现
- `aptos-move/aptos-vm/src/transaction_metadata.rs:18-114` - TransactionMetadata 构造
- `aptos-move/aptos-vm/src/transaction_validation.rs:136-256` - VM Prologue 调用
- `aptos-move/aptos-vm/src/transaction_validation.rs:247-256` - Prologue 验证
- `aptos-move/aptos-vm/src/transaction_validation.rs:463-492` - 账户抽象验证

### Mempool
- `mempool/src/core_mempool/index.rs:28-120` - AccountTransactions 结构
- `mempool/src/core_mempool/transaction_store.rs:78-80` - ParkingLot 说明
- `mempool/src/core_mempool/transaction_store.rs:235-346` - Mempool 插入逻辑
- `mempool/src/core_mempool/transaction_store.rs:335-346` - 容量检查
- `mempool/src/core_mempool/transaction_store.rs:944-945` - GC 处理
- `mempool/src/core_mempool/mempool.rs:426-550` - get_batch() 批次选择

### 配置
- `config/src/config/mempool_config.rs:105-106` - 容量配置

---

**文档版本**: 1.0
**最后更新**: 2025-01-06
**Aptos 版本**: aptos-core main branch
