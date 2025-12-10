# Aptos 定时交易系统设计文档

## 1. 概述

### 1.1 目的
Aptos 定时交易(Scheduled Transactions)系统旨在提供一种去中心化的方式来调度和执行未来的交易，无需依赖外部的 cron 服务或中心化调度器。

### 1.2 核心特性
- **时间触发**: 允许用户调度在未来特定时间执行的交易
- **Gas 预付**: 用户在调度时预付 gas 费用
- **优先级排序**: 基于 gas 价格的优先级排序机制
- **安全机制**: 包括授权令牌、重入保护、模块发布限制等
- **灵活取消**: 支持单个取消和批量取消
- **状态管理**: 支持暂停、关闭和重新初始化

## 2. 架构设计

### 2.1 整体架构

定时交易系统采用分层架构，包含以下主要层次：

```
┌─────────────────────────────────────────────────────────┐
│              用户层 (User Layer)                         │
│   - 交易调度 API                                         │
│   - 交易取消接口                                         │
│   - 查询接口                                             │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│          Move 框架层 (Framework Layer)                   │
│   - scheduled_txns: 核心调度逻辑                         │
│   - sched_txns_auth_num: 授权号管理                      │
│   - user_func_wrapper: 用户函数执行包装器                │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│       区块执行层 (Block Execution Layer)                 │
│   - 区块中插入定时交易                                    │
│   - 并行执行协调                                         │
│   - 交易输出处理                                         │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│           VM 执行层 (VM Layer)                           │
│   - 交易验证                                             │
│   - Gas 计量                                             │
│   - 重入保护                                             │
│   - 模块发布限制                                         │
└──────────────────────┬──────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────┐
│           存储层 (Storage Layer)                         │
│   - 状态存储                                             │
│   - 交易队列                                             │
│   - 授权号映射                                           │
└─────────────────────────────────────────────────────────┘
```

### 2.2 核心组件

#### 2.2.1 调度队列 (ScheduleQueue)
- **数据结构**:
  - `schedule_map`: BigOrderedMap<ScheduleMapKey, Empty>
  - `txn_table`: Table<u256, ScheduledTransaction>

- **排序规则**: `{time, gas_priority, txn_id}`
  - 首先按调度时间升序排序
  - 其次按 gas 优先级排序 (gas_priority = U64_MAX - gas_unit_price)
  - 最后按交易 ID 排序

#### 2.2.2 交易键 (ScheduleMapKey)
```move
struct ScheduleMapKey has copy, drop, store {
    time: u64,              // UTC 时间戳 (毫秒)
    gas_priority: u64,      // U64_MAX - gas_unit_price
    txn_id: u256            // SHA3-256 哈希
}
```

#### 2.2.3 定时交易 (ScheduledTransaction)
```move
struct ScheduledTransaction has copy, drop, store {
    sender_addr: address,
    scheduled_time_ms: u64,
    max_gas_amount: u64,
    gas_unit_price: u64,
    expiry_delta: u64,
    f: ScheduledFunction
}
```

#### 2.2.4 定时函数类型
- **V1**: 无授权令牌的简单闭包 `|| has copy + store + drop`
- **V1WithAuthToken**: 带授权令牌的闭包 `|&signer, ScheduledTxnAuthToken| has copy + store + drop`

## 3. 核心流程

### 3.1 交易调度流程

```
1. 用户调用 insert() 函数
   ↓
2. 验证检查:
   - 模块状态为 Active
   - sender 与 txn.sender_addr 匹配
   - 调度时间在未来
   - gas_unit_price >= MIN_GAS_UNIT_PRICE
   - max_gas_amount >= MIN_GAS_AMOUNT
   - 交易大小 < MAX_SCHED_TXN_SIZE
   ↓
3. 如果有授权令牌,验证:
   - 当前时间 <= expiration_time
   - scheduled_time <= expiration_time
   - authorization_num == sender_auth_num
   ↓
4. 计算交易 ID (SHA3-256)
   ↓
5. 创建 ScheduleMapKey
   ↓
6. 插入到 schedule_map 和 txn_table
   ↓
7. 收取押金 (max_gas_amount * gas_unit_price)
   ↓
8. 发出 TransactionScheduledEvent 事件
   ↓
9. 返回 ScheduleMapKey 给用户
```

### 3.2 交易执行流程

```
1. 在区块执行阶段调用 get_ready_transactions()
   ↓
2. 移除已标记的交易 (remove_txns)
   ↓
3. 检查模块状态 (必须为 Active)
   ↓
4. 遍历 schedule_map (按时间排序):
   - 如果 key.time > block_timestamp_ms,终止
   - 收集最多 GET_READY_TRANSACTIONS_LIMIT (100) 个交易
   ↓
5. 对每个就绪交易:
   a. user_func_wrapper::execute_user_function()
   b. 获取交易 (get_txn_by_key)
   c. 检查是否过期 (fail_txn_on_expired)
   d. 如果有授权令牌:
      - 检查令牌有效性 (fail_txn_on_invalid_auth_token)
      - 创建更新的令牌 (create_updated_auth_token_for_execution)
   e. 执行用户函数
   f. 从 txn_table 中移除
   g. 标记从 schedule_map 移除 (mark_txn_to_remove)
   ↓
6. 在下一个区块的 prologue 中清理 schedule_map
```

### 3.3 交易取消流程

#### 3.3.1 单个取消 (cancel_with_key)
```
1. 检查模块状态为 Active
   ↓
2. 验证取消时间合法:
   - curr_time < key.time
   - (key.time - curr_time) > CANCEL_DELTA_DEFAULT (10秒)
   ↓
3. 验证交易存在
   ↓
4. 验证 sender 匹配
   ↓
5. 调用 cancel_internal:
   - 从 schedule_map 移除
   - 从 txn_table 移除
   - 退还押金
   ↓
6. 发出 TransactionCancelledEvent 事件
```

#### 3.3.2 批量取消 (cancel_all)
```
1. 检查模块状态为 Active
   ↓
2. 增加 sender 的 authorization_num
   ↓
3. 所有带授权令牌的交易在执行时会失败:
   - auth_token.authorization_num != sender_auth_num
```

## 4. 安全机制

### 4.1 授权令牌 (Authorization Token)

#### 4.1.1 目的
- 防止未授权的重新调度
- 支持批量取消(通过增加 auth_num)
- 提供时间窗口控制

#### 4.1.2 结构
```move
struct ScheduledTxnAuthToken has copy, drop, store {
    allow_rescheduling: bool,     // 是否允许重新调度
    expiration_time: u64,         // 过期时间
    authorization_num: u64        // 授权号
}
```

#### 4.1.3 验证规则
- 当前时间 <= expiration_time
- scheduled_time <= expiration_time
- authorization_num == sender 当前的 auth_num

### 4.2 重入保护

**问题**: 用户函数在执行时可能尝试调度新的交易,导致重入问题。

**解决方案**:
- 使用独立的 `user_func_wrapper` 模块
- 将用户函数执行与调度逻辑分离
- 防止在同一调用栈中重新进入 scheduled_txns 模块的关键函数

### 4.3 模块发布限制

**限制**: 定时交易中禁止发布或升级 Move 模块。

**原因**:
- 防止恶意代码延迟执行
- 避免模块版本管理复杂性
- 保护网络安全

### 4.4 Gas 预付和退款

#### 4.4.1 押金收取
- 在调度时收取: `max_gas_amount * gas_unit_price`
- 存储在框架账户的 fungible store 中
- 使用 SignerCapability 管理

#### 4.4.2 退款机制
- **成功执行**: 退还未使用的 gas + 存储退款
- **过期/取消**: 全额退还押金
- **授权失败**: 全额退还押金

### 4.5 并发控制

#### 4.5.1 ToRemoveTbl 设计
- 使用 Table<u16, vector<ScheduleMapKey>>
- 提供 TO_REMOVE_PARALLELISM (100) 个槽位
- 通过 txn_id hash 分配槽位
- 减少并发执行时的序列化冲突

#### 4.5.2 txn_table 即时删除
- 从 schedule_map 延迟删除(下一个区块)
- 从 txn_table 立即删除(执行后)
- 目的: 启用正确的存储 gas 退款

## 5. 状态管理

### 5.1 模块状态

```move
enum ScheduledTxnsModuleStatus has copy, store, drop {
    Active,              // 活跃状态
    Paused,              // 暂停状态
    ShutdownInProgress,  // 关闭中
    ShutdownComplete     // 关闭完成
}
```

### 5.2 状态转换

```
Active ──pause──> Paused
  │               │
  │              unpause
  │               │
  └───────────────┘
  │
start_shutdown
  │
  ▼
ShutdownInProgress ──continue_shutdown──> ShutdownComplete
  │                                          │
  │                                     re_initialize
  │                                          │
  └──────────────────────────────────────────┘
```

### 5.3 关闭流程

1. **start_shutdown()**: 将状态设为 ShutdownInProgress
2. **continue_shutdown(batch_size)**: 批量取消交易
   - 遍历 schedule_map
   - 每次最多取消 batch_size 个交易
   - 退还所有押金
   - 发出 TransactionFailedEvent(Shutdown)
3. **complete_shutdown()**: 清理并设置状态为 ShutdownComplete
4. **re_initialize()**: 重新激活模块

## 6. 性能优化

### 6.1 BigOrderedMap
- 使用 B+ 树实现
- 支持高效的范围查询
- 固定大小的键和值减少内存碎片

### 6.2 批量处理
- 每个区块最多处理 100 个定时交易
- 关闭时每批最多取消 200 个交易

### 6.3 并行执行
- ToRemoveTbl 设计支持并行标记删除
- 减少对主队列的序列化访问

### 6.4 懒惰删除
- schedule_map 延迟到下一个区块删除
- txn_table 立即删除以支持存储退款

## 7. 限制和约束

### 7.1 系统限制
- 最小 gas_unit_price: 100
- 最小 max_gas_amount: 100
- 最大交易大小: 1MB
- 每区块最多处理: 100 个定时交易
- 取消保护时间: 10秒

### 7.2 功能限制
- 禁止模块发布
- 禁止在过去的时间调度
- 取消需要提前 10 秒以上

### 7.3 用户限制
- 必须预付全部 gas 费用
- 调度时间必须在未来
- 授权令牌必须在有效期内

## 8. 事件

### 8.1 TransactionScheduledEvent
```move
struct TransactionScheduledEvent has drop, store {
    block_time_ms: u64,
    scheduled_txn_hash: u256,
    sender_addr: address,
    scheduled_time_ms: u64,
    max_gas_amount: u64,
    gas_unit_price: u64,
    auth_required: bool
}
```

### 8.2 TransactionCancelledEvent
```move
struct TransactionCancelledEvent has drop, store {
    scheduled_txn_time: u64,
    scheduled_txn_hash: u256,
    sender_addr: address
}
```

### 8.3 TransactionFailedEvent
```move
struct TransactionFailedEvent has drop, store {
    scheduled_txn_time: u64,
    scheduled_txn_hash: u256,
    sender_addr: address,
    cancelled_txn_code: CancelledTxnCode
}

enum CancelledTxnCode has drop, store {
    Shutdown,      // 服务关闭
    Expired,       // 交易过期
    AuthExpired    // 授权过期
}
```

### 8.4 ShutdownEvent
```move
struct ShutdownEvent has drop, store {
    complete: bool
}
```

## 9. 未来改进方向

### 9.1 功能增强
- 支持周期性任务(cron-like)
- 支持条件触发
- 支持更复杂的调度策略
- 支持调度链(一个交易完成后触发下一个)

### 9.2 性能优化
- 更高效的并行执行
- 更好的 gas 估算
- 减少存储开销

### 9.3 用户体验
- 更灵活的取消策略
- 更好的错误处理和反馈
- 支持部分退款
- 查询接口优化

### 9.4 安全增强
- 更细粒度的权限控制
- 审计日志
- 速率限制
- 防 DoS 机制

## 10. 总结

Aptos 定时交易系统提供了一个强大、安全且高效的去中心化交易调度解决方案。通过精心设计的架构和安全机制,它能够满足各种实际应用场景的需求,同时保持了系统的性能和安全性。
