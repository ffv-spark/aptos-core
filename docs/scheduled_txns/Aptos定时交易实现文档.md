# Aptos 定时交易系统实现文档

## 1. 实现概览

本文档详细描述 Aptos 定时交易系统的实现细节,包括各个组件的代码实现、数据流转和关键算法。

## 2. Move 框架层实现

### 2.1 scheduled_txns 模块

#### 2.1.1 文件位置
`aptos-move/framework/aptos-framework/sources/scheduled_transactions/scheduled_txns.move`

#### 2.1.2 核心数据结构

##### ScheduledTransaction
```move
struct ScheduledTransaction has copy, drop, store {
    sender_addr: address,          // 32 字节
    scheduled_time_ms: u64,        // UTC 时间戳(毫秒)
    max_gas_amount: u64,           // 最大 gas 数量
    gas_unit_price: u64,           // gas 单价
    expiry_delta: u64,             // 过期时间增量
    f: ScheduledFunction           // 调度函数
}
```

**说明**:
- `expiry_delta`: 如果为 0,永不过期;否则在 `scheduled_time + expiry_delta` 后过期
- `f`: 封装用户函数的枚举类型

##### ScheduledFunction
```move
enum ScheduledFunction has copy, store, drop {
    V1(|| has copy + store + drop),
    V1WithAuthToken(
        |&signer, ScheduledTxnAuthToken| has copy + store + drop,
        ScheduledTxnAuthToken
    ),
}
```

**说明**:
- `V1`: 简单闭包,不需要授权
- `V1WithAuthToken`: 带授权令牌的闭包,支持重新调度和批量取消

##### ScheduleMapKey
```move
struct ScheduleMapKey has copy, drop, store {
    time: u64,              // UTC 时间戳(毫秒)
    gas_priority: u64,      // U64_MAX - gas_unit_price
    txn_id: u256            // SHA3-256 哈希
}
```

**排序逻辑**:
1. 首先按 `time` 升序排序
2. 然后按 `gas_priority` 升序排序(实际上是 gas_unit_price 降序)
3. 最后按 `txn_id` 排序(确保唯一性)

##### ScheduleQueue
```move
struct ScheduleQueue has key {
    schedule_map: BigOrderedMap<ScheduleMapKey, Empty>,
    txn_table: Table<u256, ScheduledTransaction>
}
```

**设计理由**:
- `schedule_map`: 使用 BigOrderedMap 提供有序访问,值为 Empty 减少存储
- `txn_table`: 使用 txn_id 作为键,避免在 map 中存储大型交易对象

##### ScheduledTxnAuthToken
```move
struct ScheduledTxnAuthToken has copy, drop, store {
    allow_rescheduling: bool,     // 是否允许用户函数重新调度
    expiration_time: u64,         // 令牌过期时间
    authorization_num: u64        // 授权号
}
```

#### 2.1.3 关键函数实现

##### insert() - 交易调度
```move
public fun insert(
    sender: &signer,
    txn: ScheduledTransaction
): ScheduleMapKey
```

**实现步骤**:

1. **状态检查**:
```move
let aux_data = borrow_global<AuxiliaryData>(@aptos_framework);
assert!(
    (aux_data.module_status == ScheduledTxnsModuleStatus::Active),
    error::unavailable(EUNAVAILABLE)
);
```

2. **签名者验证**:
```move
assert!(
    signer::address_of(sender) == txn.sender_addr,
    error::permission_denied(EINVALID_SIGNER)
);
```

3. **时间验证**:
```move
let block_time_ms = timestamp::now_microseconds() / 1000;
assert!(txn_time > block_time_ms, error::invalid_argument(EINVALID_TIME));
```

4. **Gas 参数验证**:
```move
assert!(
    txn.gas_unit_price >= MIN_GAS_UNIT_PRICE,
    error::invalid_argument(ELOW_GAS_UNIT_PRICE)
);
assert!(
    txn.max_gas_amount >= MIN_GAS_AMOUNT,
    error::invalid_argument(ETOO_LOW_GAS_AMOUNT)
);
```

5. **授权令牌验证**(如果适用):
```move
match (txn.f) {
    ScheduledFunction::V1(_f) => { },
    ScheduledFunction::V1WithAuthToken(_f, auth_token) => {
        validate_auth_token(txn.sender_addr, txn_time, &auth_token);
    }
};
```

6. **交易 ID 生成**:
```move
let txn_bytes = bcs::to_bytes(&txn);
assert!(
    txn_bytes.length() < MAX_SCHED_TXN_SIZE,
    error::invalid_argument(ETXN_TOO_LARGE)
);
let hash = sha3_256(txn_bytes);
let txn_id = hash_to_u256(hash);
```

7. **创建键并插入**:
```move
let key = ScheduleMapKey {
    time: txn_time,
    gas_priority: U64_MAX - txn.gas_unit_price,
    txn_id
};
queue.schedule_map.add(key, Empty {});
queue.txn_table.add(key.txn_id, txn);
```

8. **收取押金**:
```move
primary_fungible_store::transfer(
    sender,
    address_to_object<Metadata>(@aptos_fungible_asset),
    gas_deposit_store_addr,
    txn.max_gas_amount * txn.gas_unit_price,
);
```

9. **发出事件**:
```move
event::emit(TransactionScheduledEvent {
    block_time_ms,
    scheduled_txn_hash: txn_id,
    sender_addr: txn.sender_addr,
    scheduled_time_ms: txn.scheduled_time_ms,
    max_gas_amount: txn.max_gas_amount,
    gas_unit_price: txn.gas_unit_price,
    auth_required: auth_required
});
```

##### get_ready_transactions() - 获取就绪交易
```move
fun get_ready_transactions(
    block_timestamp_ms: u64
): vector<ScheduledTransactionInfoWithKey>
```

**实现步骤**:

1. **清理已执行的交易**:
```move
remove_txns();
```

2. **检查模块状态**:
```move
let aux_data = borrow_global<AuxiliaryData>(@aptos_framework);
if (aux_data.module_status != ScheduledTxnsModuleStatus::Active) {
    return vector::empty<ScheduledTransactionInfoWithKey>();
};
```

3. **遍历并收集就绪交易**:
```move
let iter = queue.schedule_map.new_begin_iter();
while ((count < limit) && !iter.iter_is_end(&queue.schedule_map)) {
    let key = iter.iter_borrow_key();
    if (key.time > block_timestamp_ms) {
        break;  // 后续所有交易都未就绪
    };
    let txn = queue.txn_table.borrow(key.txn_id);

    // 收集交易信息(过期检查在执行时进行)
    let scheduled_txn_info_with_key = ScheduledTransactionInfoWithKey {
        sender_addr: txn.sender_addr,
        max_gas_amount: txn.max_gas_amount,
        gas_unit_price: txn.gas_unit_price,
        block_timestamp_ms,
        key: *key
    };

    scheduled_txns.push_back(scheduled_txn_info_with_key);
    count = count + 1;
    iter = iter.iter_next(&queue.schedule_map);
};
```

**关键点**:
- 利用 BigOrderedMap 的有序性,可以在遇到未来时间时立即终止
- 每个区块最多返回 GET_READY_TRANSACTIONS_LIMIT (100) 个交易
- 过期检查延迟到执行阶段,避免在此处序列化

##### cancel_with_key() - 取消交易
```move
public fun cancel_with_key(sender: &signer, key: ScheduleMapKey)
```

**实现步骤**:

1. **时间窗口检查**:
```move
let curr_time_ms = timestamp::now_microseconds() / 1000;
assert!(
    (curr_time_ms < key.time) &&
    ((key.time - curr_time_ms) > CANCEL_DELTA_DEFAULT),
    error::invalid_argument(ECANCEL_TOO_LATE)
);
```

2. **交易存在性检查**:
```move
let queue = borrow_global<ScheduleQueue>(@aptos_framework);
if (!queue.schedule_map.contains(&key) ||
    !queue.txn_table.contains(key.txn_id)) {
    return  // 可能已执行
};
```

3. **权限验证**:
```move
let txn = queue.txn_table.borrow(key.txn_id);
let sender_addr = signer::address_of(sender);
assert!(
    sender_addr == txn.sender_addr,
    error::permission_denied(EINVALID_SIGNER)
);
```

4. **执行取消**:
```move
let deposit_amt = txn.max_gas_amount * txn.gas_unit_price;
cancel_internal(sender_addr, key, deposit_amt);
```

5. **发出事件**:
```move
event::emit(TransactionCancelledEvent {
    scheduled_txn_time: key.time,
    scheduled_txn_hash: key.txn_id,
    sender_addr
});
```

##### cancel_all() - 批量取消
```move
public entry fun cancel_all(sender: &signer)
```

**实现**:
```move
public entry fun cancel_all(sender: &signer) acquires AuxiliaryData {
    // 检查模块状态
    let aux_data = borrow_global<AuxiliaryData>(@aptos_framework);
    assert!(
        (aux_data.module_status == ScheduledTxnsModuleStatus::Active),
        error::unavailable(EUNAVAILABLE)
    );

    let sender_addr = signer::address_of(sender);

    // 增加授权号,使所有现有授权令牌失效
    increment_auth_num(sender_addr);
}
```

**工作原理**:
- 不直接删除交易
- 通过增加 authorization_num 使所有授权令牌失效
- 交易在执行时会自动失败并退款
- 这是一种"懒惰取消"策略,避免遍历大量交易

##### remove_txns() - 清理已执行交易
```move
public(friend) fun remove_txns() acquires ToRemoveTbl, ScheduleQueue
```

**实现**:
```move
let to_remove = borrow_global_mut<ToRemoveTbl>(@aptos_framework);
let queue = borrow_global_mut<ScheduleQueue>(@aptos_framework);
let tbl_idx: u16 = 0;

while ((tbl_idx as u64) < TO_REMOVE_PARALLELISM) {
    if (to_remove.remove_tbl.contains(tbl_idx)) {
        let keys = to_remove.remove_tbl.borrow_mut(tbl_idx);

        while (!keys.is_empty()) {
            let key = keys.pop_back();
            if (queue.schedule_map.contains(&key)) {
                // 从两个数据结构中移除
                if (queue.txn_table.contains(key.txn_id)) {
                    queue.txn_table.remove(key.txn_id);
                };
                queue.schedule_map.remove(&key);
            };
        };
    };
    tbl_idx = tbl_idx + 1;
};
```

**设计理由**:
- 使用 TO_REMOVE_PARALLELISM (100) 个槽位
- 每个槽位通过 `txn_id % TO_REMOVE_PARALLELISM` 分配
- 减少并行执行时的冲突

### 2.2 sched_txns_auth_num 模块

#### 2.2.1 文件位置
`aptos-move/framework/aptos-framework/sources/scheduled_transactions/sched_txns_auth_num.move`

#### 2.2.2 数据结构

```move
struct AuthNumData has key {
    auth_num_map: BigOrderedMap<address, u64>
}
```

#### 2.2.3 关键函数

##### get_or_init_auth_num() - 懒惰初始化
```move
public(friend) fun get_or_init_auth_num(addr: address): u64 acquires AuthNumData {
    let data = borrow_global_mut<AuthNumData>(@aptos_framework);
    if (data.auth_num_map.contains(&addr)) {
        *data.auth_num_map.borrow(&addr)
    } else {
        // 懒惰初始化: 从 1 开始
        let initial_auth_num = 1;
        data.auth_num_map.add(addr, initial_auth_num);
        initial_auth_num
    }
}
```

**设计理由**:
- 懒惰初始化减少存储开销
- 只有使用授权令牌的用户才会占用存储
- 从 1 开始便于区分未初始化 (0) 和已初始化状态

##### increment_auth_num() - 增加授权号
```move
public(friend) fun increment_auth_num(addr: address) acquires AuthNumData {
    let data = borrow_global_mut<AuthNumData>(@aptos_framework);

    assert!(
        data.auth_num_map.contains(&addr),
        error::invalid_state(EAUTH_NUM_NOT_FOUND)
    );

    let current_auth_num = *data.auth_num_map.borrow(&addr);
    let new_auth_num = current_auth_num + 1;
    *data.auth_num_map.borrow_mut(&addr) = new_auth_num;
}
```

**使用场景**:
- `cancel_all()`: 用户批量取消所有授权交易
- `handle_key_rotation()`: 密钥轮换时自动失效所有授权

##### handle_key_rotation() - 密钥轮换处理
```move
public(friend) fun handle_key_rotation(addr: address) acquires AuthNumData {
    if (contains_addr(addr)) {
        increment_auth_num(addr);
    }
    // 如果地址不存在,什么都不做
}
```

**集成点**: 在 `account` 模块的密钥轮换函数中调用

### 2.3 user_func_wrapper 模块

#### 2.3.1 文件位置
`aptos-move/framework/aptos-framework/sources/scheduled_transactions/user_func_wrapper.move`

#### 2.3.2 核心函数

##### execute_user_function() - 用户函数执行包装器
```move
fun execute_user_function(
    signer: signer,
    txn_key: ScheduleMapKey,
    block_timestamp_ms: u64
): bool
```

**实现**:
```move
fun execute_user_function(
    signer: signer, txn_key: ScheduleMapKey, block_timestamp_ms: u64
): bool {
    // 1. 获取交易
    let txn_opt = scheduled_txns::get_txn_by_key(txn_key);
    if (txn_opt.is_none()) {
        return false
    };
    let txn = txn_opt.borrow();

    // 2. 检查过期
    if (scheduled_txns::fail_txn_on_expired(txn, txn_key, block_timestamp_ms)) {
        // 过期 - 不执行,但从 txn_table 移除
        scheduled_txns::remove_txn_from_table(
            scheduled_txns::schedule_map_key_txn_id(&txn_key)
        );
        return true
    };

    // 3. 执行用户函数
    if (scheduled_txns::is_scheduled_function_v1(txn)) {
        // 简单闭包 - 直接执行
        let f = scheduled_txns::get_scheduled_function_v1(txn);
        f();
    } else {
        // 带授权令牌的闭包
        if (scheduled_txns::fail_txn_on_invalid_auth_token(
            txn, txn_key, block_timestamp_ms
        )) {
            // 授权失效 - 不执行
        } else {
            // 授权有效 - 执行
            let f = scheduled_txns::get_scheduled_function_v1_with_auth_token(txn);
            let updated_auth_token =
                scheduled_txns::create_updated_auth_token_for_execution(txn);
            f(&signer, updated_auth_token);
        };
    };

    // 4. 从 txn_table 移除(允许存储退款)
    scheduled_txns::remove_txn_from_table(
        scheduled_txns::schedule_map_key_txn_id(&txn_key)
    );
    true
}
```

**设计要点**:

1. **独立模块**: 防止用户函数直接调用 scheduled_txns 的内部函数
2. **重入保护**: 用户函数可以调用 `insert()` 调度新交易,但不能重入当前执行路径
3. **过期处理**: 在执行前检查,避免浪费 gas
4. **授权验证**: 对带授权令牌的交易,验证令牌有效性
5. **存储退款**: 立即从 txn_table 移除以触发存储退款

## 3. VM 执行层实现

### 3.1 交易类型

#### 3.1.1 定时交易标识
文件位置: `aptos-types/src/transaction/scheduled_txn.rs`

```rust
pub struct ScheduledTransactionInfoWithKey {
    pub sender_addr: AccountAddress,
    pub max_gas_amount: u64,
    pub gas_unit_price: u64,
    pub block_timestamp_ms: u64,
    pub key: ScheduleMapKey,
}

pub struct ScheduleMapKey {
    pub time: u64,
    pub gas_priority: u64,
    pub txn_id: U256,
}
```

### 3.2 AptosVM 修改

#### 3.2.1 会话类型

新增三种会话类型用于定时交易:

1. **ScheduledTxnSession**: 定时交易的主会话
2. **ScheduledTxnEpilogueSession**: 定时交易的 epilogue 会话
3. **RespawnedSession**: 重新生成的会话(用于特殊情况)

```rust
// aptos-move/aptos-vm/src/move_vm_ext/session/scheduled_txn_session.rs
pub struct ScheduledTxnSession<'r, 'l> {
    // ... session fields
}

impl<'r, 'l> ScheduledTxnSession<'r, 'l> {
    pub fn execute_scheduled_transaction(
        &mut self,
        sender: AccountAddress,
        txn_key: ScheduleMapKey,
        block_timestamp_ms: u64,
    ) -> Result<(), VMStatus> {
        // 调用 user_func_wrapper::execute_user_function
        // ...
    }
}
```

#### 3.2.2 安全检查

##### 模块发布限制
```rust
// 在验证阶段检查
fn verify_no_module_publishing(txn: &ScheduledTransaction) -> Result<(), VMStatus> {
    // 检查交易 payload
    // 如果是模块发布,返回错误
    match txn.payload() {
        TransactionPayload::ModuleBundle(_) => {
            Err(VMStatus::Error(StatusCode::INVALID_MODULE_PUBLISHER))
        },
        _ => Ok(()),
    }
}
```

##### Gas 限制
```rust
fn validate_gas_params(txn: &ScheduledTransactionInfoWithKey) -> Result<(), VMStatus> {
    if txn.gas_unit_price < MIN_GAS_UNIT_PRICE {
        return Err(VMStatus::Error(StatusCode::GAS_UNIT_PRICE_BELOW_MIN_BOUND));
    }
    if txn.max_gas_amount < MIN_GAS_AMOUNT {
        return Err(VMStatus::Error(StatusCode::MAX_GAS_AMOUNT_BELOW_MIN_BOUND));
    }
    Ok(())
}
```

#### 3.2.3 授权令牌验证

在执行定时交易前的验证:

```rust
pub fn pre_execution_validation(
    txn_info: &ScheduledTransactionInfoWithKey,
    resolver: &impl AptosMoveResolver,
) -> PreExecutionValidationStatus {
    // 1. 获取交易
    let txn_opt = get_txn_by_key(&txn_info.key, resolver)?;
    let txn = match txn_opt {
        Some(t) => t,
        None => return PreExecutionValidationStatus::AlreadyExecuted,
    };

    // 2. 检查过期
    if is_expired(&txn, &txn_info.key, txn_info.block_timestamp_ms) {
        return PreExecutionValidationStatus::Expired;
    }

    // 3. 检查授权令牌(如果有)
    if has_auth_token(&txn) {
        let auth_token = get_auth_token(&txn);
        let sender_auth_num = get_current_auth_num(txn.sender_addr, resolver)?;

        if auth_token.expiration_time <= txn_info.block_timestamp_ms ||
           auth_token.authorization_num != sender_auth_num {
            return PreExecutionValidationStatus::AuthInvalid;
        }
    }

    PreExecutionValidationStatus::Valid
}
```

### 3.3 Gas 处理

#### 3.3.1 Gas 计量
```rust
// 创建专门的 gas meter
let mut gas_meter = AptosGasMeter::new(
    gas_params,
    storage_gas_params,
    txn_info.max_gas_amount,
    txn_info.gas_unit_price,
    features,
);
```

#### 3.3.2 Gas 退款
```rust
fn calculate_refund(
    txn_info: &ScheduledTransactionInfoWithKey,
    gas_meter: &AptosGasMeter,
) -> u64 {
    let total_deposit = txn_info.max_gas_amount * txn_info.gas_unit_price;
    let gas_used = gas_meter.balance();
    let storage_refund = gas_meter.storage_fee_refund();

    // 退款 = 押金 - 使用的 gas + 存储退款
    total_deposit - gas_used + storage_refund
}
```

## 4. 区块执行层实现

### 4.1 AptosVMBlockExecutorWrapper

#### 4.1.1 定时交易插入点

在区块执行的 prologue 阶段获取并插入定时交易:

```rust
// aptos-move/aptos-vm/src/block_executor/mod.rs

impl AptosVMBlockExecutor for AptosVMBlockExecutorWrapper {
    fn execute_block(
        &self,
        txns: Vec<SignatureVerifiedTransaction>,
        state_view: &impl StateView,
    ) -> Result<BlockOutput, VMStatus> {
        // 1. 获取当前区块时间
        let block_timestamp_ms = get_block_timestamp_ms(state_view)?;

        // 2. 获取就绪的定时交易
        let scheduled_txns = get_ready_scheduled_transactions(
            state_view,
            block_timestamp_ms,
        )?;

        // 3. 合并普通交易和定时交易
        let mut all_txns = txns;
        for scheduled_txn_info in scheduled_txns {
            // 为每个定时交易创建一个特殊的transaction包装
            let wrapped_txn = wrap_scheduled_transaction(scheduled_txn_info);
            all_txns.push(wrapped_txn);
        }

        // 4. 并行执行所有交易
        self.executor.execute_transactions_parallel(all_txns, state_view)
    }
}
```

#### 4.1.2 交易包装

```rust
fn wrap_scheduled_transaction(
    info: ScheduledTransactionInfoWithKey
) -> SignatureVerifiedTransaction {
    // 创建一个特殊的交易,其 payload 包含:
    // 1. sender_addr
    // 2. txn_key
    // 3. block_timestamp_ms

    // 这个交易将调用 user_func_wrapper::execute_user_function
    let payload = create_execute_user_function_payload(
        info.sender_addr,
        info.key,
        info.block_timestamp_ms,
    );

    SignatureVerifiedTransaction::new_scheduled_transaction(
        info.sender_addr,
        payload,
        info.max_gas_amount,
        info.gas_unit_price,
    )
}
```

### 4.2 并行执行

#### 4.2.1 依赖检测

定时交易与普通交易可以并行执行,除非:
- 它们访问相同的资源
- 它们修改相同的 delayed fields
- 定时交易之间有相同的 sender(可能修改 auth_num)

#### 4.2.2 ToRemoveTbl 并行化

```rust
// 每个定时交易执行完成后
pub fn mark_for_removal(txn_id: U256) {
    // 计算槽位索引
    let slot_idx = (txn_id % TO_REMOVE_PARALLELISM as U256) as u16;

    // 添加到对应槽位(减少竞争)
    let mut to_remove = TO_REMOVE_TBL.lock();
    to_remove[slot_idx].push(txn_key);
}
```

## 5. 存储层实现

### 5.1 BigOrderedMap

#### 5.1.1 特性
- B+ 树实现
- 支持有序遍历
- 固定大小的键值对

#### 5.1.2 使用模式

```move
// 初始化
let schedule_map = big_ordered_map::new_with_reusable();

// 添加
schedule_map.add(key, Empty {});

// 遍历(有序)
let iter = schedule_map.new_begin_iter();
while (!iter.iter_is_end(&schedule_map)) {
    let key = iter.iter_borrow_key();
    // 处理 key
    iter = iter.iter_next(&schedule_map);
};

// 删除
schedule_map.remove(&key);
```

### 5.2 Table

#### 5.2.1 txn_table 使用

```move
// 添加
txn_table.add(txn_id, txn);

// 查询
if (txn_table.contains(txn_id)) {
    let txn = txn_table.borrow(txn_id);
    // 使用 txn
};

// 删除
txn_table.remove(txn_id);
```

#### 5.2.2 ToRemoveTbl 使用

```move
// 初始化时创建所有槽位
let remove_tbl = table::new<u16, vector<ScheduleMapKey>>();
let i: u16 = 0;
while ((i as u64) < TO_REMOVE_PARALLELISM) {
    remove_tbl.add(i, vector::empty<ScheduleMapKey>());
    i = i + 1;
};

// 标记删除
let tbl_idx = ((txn_id % TO_REMOVE_PARALLELISM) as u16);
let keys = remove_tbl.borrow_mut(tbl_idx);
keys.push_back(key);

// 批量清理
while ((tbl_idx as u64) < TO_REMOVE_PARALLELISM) {
    let keys = remove_tbl.borrow_mut(tbl_idx);
    while (!keys.is_empty()) {
        let key = keys.pop_back();
        // 从 schedule_map 和 txn_table 删除
    };
    tbl_idx = tbl_idx + 1;
};
```

## 6. 押金和退款实现

### 6.1 押金存储账户

#### 6.1.1 创建
```move
let owner_addr = DEPOSIT_STORE_OWNER_ADDR;  // @0xb
let (owner_signer, owner_cap) =
    account::create_framework_reserved_account(owner_addr);

// 初始化 fungible store
let metadata = address_to_object<Metadata>(@aptos_fungible_asset);
let deposit_store =
    primary_fungible_store::ensure_primary_store_exists(
        signer::address_of(&owner_signer), metadata
    );
// 升级为并发 store(支持并行操作)
upgrade_store_to_concurrent(&owner_signer, deposit_store);

// 存储 capability
move_to(framework, AuxiliaryData {
    gas_fee_deposit_store_signer_cap: owner_cap,
    module_status: ScheduledTxnsModuleStatus::Active
});
```

### 6.2 押金收取

```move
// 在 insert() 时
primary_fungible_store::transfer(
    sender,                                              // 从用户
    address_to_object<Metadata>(@aptos_fungible_asset),
    gas_deposit_store_addr,                             // 到押金账户
    txn.max_gas_amount * txn.gas_unit_price,           // 金额
);
```

### 6.3 押金退还

```move
// 在 cancel_internal() 或交易执行后
let gas_deposit_store_signer =
    account::create_signer_with_capability(
        &aux_data.gas_fee_deposit_store_signer_cap
    );

primary_fungible_store::transfer(
    &gas_deposit_store_signer,                          // 从押金账户
    address_to_object<Metadata>(@aptos_fungible_asset),
    account_addr,                                        // 到用户
    refund_amount,                                       // 退款金额
);
```

### 6.4 退款金额计算

```move
// 成功执行
let refund = deposit - gas_used + storage_refund;

// 过期或取消
let refund = deposit;  // 全额退还

// 授权失效
let refund = deposit;  // 全额退还
```

## 7. 测试实现

### 7.1 单元测试示例

#### 7.1.1 基本调度测试
```move
#[test(fx = @0x1, user = @0x1234)]
fun test_basic(fx: &signer, user: signer) {
    setup_test_env(fx, &user, curr_mock_time_ms);

    // 创建定时交易
    let state = State { count: 8 };
    let foo = || step(state);
    let txn = new_scheduled_transaction_no_signer(
        user_addr,
        schedule_time1,
        100,  // max_gas_amount
        200,  // gas_unit_price
        EXPIRY_DELTA_DEFAULT,
        foo
    );

    // 插入
    let txn_key = insert(&user, txn);
    assert!(get_num_txns() == 1, 1);

    // 获取就绪交易
    let ready_txns = get_ready_transactions(schedule_time1 + 1000);
    assert!(ready_txns.length() == 1, 2);
}
```

#### 7.1.2 授权令牌测试
```move
#[test(fx = @0x1, user = @0x1234)]
fun test_auth_token(fx: &signer, user: signer) {
    setup_test_env(fx, &user, curr_mock_time_micro_s);

    // 初始化授权号
    let sender_auth_num = get_or_init_auth_num(user_addr);

    // 创建授权令牌
    let auth_token = create_mock_auth_token(
        true,              // allow_rescheduling
        expiration_time,
        sender_auth_num
    );

    // 创建带授权令牌的交易
    let txn = new_scheduled_transaction_reuse_auth_token(
        &user,
        auth_token,
        schedule_time,
        1000,
        200,
        EXPIRY_DELTA_DEFAULT,
        foo
    );

    insert(&user, txn);
}
```

#### 7.1.3 取消测试
```move
#[test(fx = @0x1, user = @0x1234)]
fun test_cancel(fx: &signer, user: signer) {
    setup_test_env(fx, &user, curr_mock_time_micro_s);

    // 调度交易
    let txn_key = insert(&user, txn);
    assert!(get_num_txns() == 1, 1);

    // 取消交易
    cancel_with_key(&user, txn_key);
    assert!(get_num_txns() == 0, 2);
}
```

### 7.2 E2E 测试

测试文件: `aptos-move/framework/aptos-framework/tests/test_scheduled_txns.move`

#### 7.2.1 完整流程测试
1. 初始化测试环境
2. 调度多个交易(不同时间和 gas 价格)
3. 推进区块时间
4. 验证交易按正确顺序执行
5. 验证 gas 退款正确

#### 7.2.2 边界条件测试
- 调度到过去的时间(应失败)
- Gas 参数不足(应失败)
- 交易过期
- 授权令牌过期
- 批量取消

## 8. 关键算法

### 8.1 交易 ID 生成

```move
fun hash_to_u256(hash: vector<u8>): u256 {
    assert!(hash.length() == 32, error::internal(EINVALID_HASH_SIZE));
    from_bcs::to_u256(hash)
}

// 使用
let txn_bytes = bcs::to_bytes(&txn);
let hash = sha3_256(txn_bytes);
let txn_id = hash_to_u256(hash);
```

**特性**:
- 使用 SHA3-256 保证唯一性
- BCS 序列化保证确定性
- u256 提供足够的空间避免碰撞

### 8.2 Gas 优先级计算

```move
let gas_priority = U64_MAX - gas_unit_price;
```

**原因**:
- BigOrderedMap 按升序排序
- 我们想要 gas_unit_price 高的优先
- 所以使用 `U64_MAX - gas_unit_price` 转换

**示例**:
- gas_unit_price = 1000 → gas_priority = U64_MAX - 1000(大值)
- gas_unit_price = 100 → gas_priority = U64_MAX - 100(更大值)
- 排序后: 100 的交易在 1000 前面(符合预期)

### 8.3 槽位索引计算

```move
let tbl_idx = ((truncate_to_u64(key.txn_id) % TO_REMOVE_PARALLELISM) as u16);

fun truncate_to_u64(val: u256): u64 {
    let masked = val & MASK_64;  // MASK_64 = 0xffffffffffffffff
    (masked as u64)
}
```

**目的**: 将 txn_id 映射到 100 个槽位之一,实现并行标记删除

## 9. 性能考虑

### 9.1 批量处理限制
- 每区块最多 100 个定时交易
- 避免单个区块耗时过长
- 保持区块时间稳定

### 9.2 存储优化
- schedule_map 值为 Empty(零存储)
- txn_table 使用 txn_id 索引(避免重复)
- BigOrderedMap 使用 reusable 模式(内存重用)

### 9.3 并发优化
- ToRemoveTbl 100 个槽位
- 定时交易与普通交易并行
- 押金账户使用 concurrent store

### 9.4 懒惰策略
- 授权号懒惰初始化
- 交易删除延迟到下一个区块
- cancel_all 使用授权号失效而非物理删除

## 10. 错误处理

### 10.1 错误码

| 错误码 | 常量名 | 说明 |
|-------|--------|------|
| 1 | EINVALID_SIGNER | 签名者不匹配 |
| 2 | EINVALID_TIME | 调度时间在过去 |
| 3 | EUNAVAILABLE | 服务不可用 |
| 4 | ELOW_GAS_UNIT_PRICE | Gas 单价过低 |
| 5 | ETOO_LOW_GAS_AMOUNT | Gas 数量过低 |
| 6 | ETXN_TOO_LARGE | 交易过大 |
| 7 | EINVALID_HASH_SIZE | 哈希大小错误 |
| 13 | ECANCEL_TOO_LATE | 取消太晚 |
| 14 | EAUTH_TOKEN_NOT_FOUND | 授权令牌未找到 |
| 15 | EAUTH_TOKEN_EXPIRED | 授权令牌过期 |
| 16 | EAUTH_NUM_MISMATCH | 授权号不匹配 |

### 10.2 错误处理流程

```move
// 验证失败 - 中止交易
assert!(condition, error::invalid_argument(ERROR_CODE));

// 执行失败 - 发出事件并退款
event::emit(TransactionFailedEvent {
    scheduled_txn_time: key.time,
    scheduled_txn_hash: key.txn_id,
    sender_addr,
    cancelled_txn_code: CancelledTxnCode::Expired
});
```

## 11. 部署和升级

### 11.1 初始化

```move
public entry fun initialize(framework: &signer) {
    system_addresses::assert_aptos_framework(framework);

    // 1. 创建押金账户
    let (owner_signer, owner_cap) =
        account::create_framework_reserved_account(DEPOSIT_STORE_OWNER_ADDR);

    // 2. 初始化 fungible store
    let metadata = address_to_object<Metadata>(@aptos_fungible_asset);
    let deposit_store = primary_fungible_store::ensure_primary_store_exists(
        signer::address_of(&owner_signer), metadata
    );
    upgrade_store_to_concurrent(&owner_signer, deposit_store);

    // 3. 存储辅助数据
    move_to(framework, AuxiliaryData {
        gas_fee_deposit_store_signer_cap: owner_cap,
        module_status: ScheduledTxnsModuleStatus::Active
    });

    // 4. 初始化授权号映射
    sched_txns_auth_num::initialize(framework);

    // 5. 初始化队列
    move_to(framework, ScheduleQueue {
        schedule_map: big_ordered_map::new_with_reusable(),
        txn_table: table::new<u256, ScheduledTransaction>()
    });

    // 6. 初始化删除表
    let remove_tbl = table::new<u16, vector<ScheduleMapKey>>();
    let i: u16 = 0;
    while ((i as u64) < TO_REMOVE_PARALLELISM) {
        remove_tbl.add(i, vector::empty<ScheduleMapKey>());
        i = i + 1;
    };
    move_to(framework, ToRemoveTbl { remove_tbl });
}
```

### 11.2 升级注意事项

1. **数据结构兼容性**: 使用 enum 支持版本演进
2. **状态迁移**: 关闭 → 迁移 → 重新初始化
3. **向后兼容**: 保持现有 API 兼容

## 12. 监控和调试

### 12.1 关键指标

1. **交易数量**:
```move
public fun get_num_txns(): u64 acquires ScheduleQueue {
    let queue = borrow_global<ScheduleQueue>(@aptos_framework);
    queue.schedule_map.compute_length()
}
```

2. **模块状态**:
```move
fun get_module_status(): ScheduledTxnsModuleStatus acquires AuxiliaryData {
    let aux_data = borrow_global<AuxiliaryData>(@aptos_framework);
    aux_data.module_status
}
```

### 12.2 调试工具

1. **测试辅助函数**:
```move
#[test_only]
public fun get_ready_transactions_test(
    timestamp: u64
): vector<ScheduledTransactionInfoWithKey>

#[test_only]
public fun mark_txn_to_remove_test(key: ScheduleMapKey)
```

2. **事件监听**: 通过 API 监听各类事件

## 13. 最佳实践

### 13.1 调度交易
- 设置合理的 expiry_delta
- 预留足够的 gas
- 使用授权令牌以支持批量取消

### 13.2 用户函数
- 保持简洁,避免复杂逻辑
- 考虑 gas 限制
- 处理可能的失败情况

### 13.3 取消策略
- 批量取消使用 cancel_all
- 提前取消以避免 CANCEL_DELTA_DEFAULT 限制
- 监听事件确认取消成功

## 14. 总结

Aptos 定时交易系统通过精心设计的多层架构实现了安全、高效的去中心化交易调度。主要特点包括:

1. **安全性**: 授权令牌、重入保护、模块发布限制
2. **高效性**: BigOrderedMap、并行执行、批量处理
3. **灵活性**: 两种函数类型、灵活取消、状态管理
4. **可靠性**: 完善的错误处理、退款机制、测试覆盖

该实现为各类 DeFi 应用、DAO 治理、游戏机制等提供了强大的基础设施支持。
