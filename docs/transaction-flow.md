# Aptos 交易完整生命周期

本文档详细描述了一笔交易从 RPC 接收到最终写入本地账本的完整执行流程。

## 概览流程图

```
客户端提交交易
    ↓
[1] REST API 接收 (api/src/transactions.rs)
    ↓
[2] Mempool 验证和存储 (mempool/)
    ↓
[3] 【可选】Quorum Store 批次预处理 (consensus/src/quorum_store/)
    ├─ BatchGenerator 创建批次
    ├─ 验证者签名批次（ProofOfStore）
    └─ 批次分发到全网
    ↓
[4] 区块生成和交易选择 (consensus/)
    ├─ Quorum Store 模式: 引用 ProofOfStore
    └─ Direct Mempool 模式: 包含完整交易
    ↓
[5] Move VM 执行交易 (aptos-move/aptos-vm/)
    ├─ Quorum Store: 从 BatchStore 获取完整交易
    └─ Direct Mempool: 直接执行
    ↓
[6] 共识投票和 QC 形成 (consensus/src/round_manager.rs)
    ↓
[7] 区块最终确定 (3-chain 提交)
    ↓
[8] 写入本地账本 (storage/aptosdb/)
    ↓
交易永久存储
```

---

## 阶段 1：RPC 接收交易

### 入口点
**文件**: `api/src/transactions.rs`

**主要端点**:
- **Line 471-500**: `submit_transaction()` - HTTP POST `/v1/transactions`
  - 接受 JSON 或 BCS 编码的 `SignedTransaction`
  - 返回 HTTP 202 (Accepted) 和 `PendingTransaction` 响应

### 处理流程
```
submit_transaction()  (transactions.rs:471)
    ↓
create_internal()  (transactions.rs:1399)
    ↓
context.submit_transaction()  (context.rs:218-226)
    ↓
发送 MempoolClientRequest::SubmitTransaction
```

**关键文件路径**:
- `api/src/transactions.rs:471-500` - REST 端点
- `api/src/context.rs:218-226` - 与 Mempool 通信
- `mempool/src/shared_mempool/types.rs:241-248` - 请求类型定义

---

## 阶段 2：Mempool 验证和存储

### 主要组件
**文件**: `mempool/src/`

### 处理流程

**2.1 接收请求**
```
coordinator.rs:57-135  - coordinator() 事件循环
    ↓
coordinator.rs:175-197 - handle_client_request()
    ↓
tasks.rs:130-166 - process_client_transaction_submission()
```

**2.2 验证交易**
```
tasks.rs:305-405 - process_incoming_transactions()
    ├─ 过滤交易 (line 319-326)
    ├─ 获取账户序列号 (line 336-351)
    └─ 验证序列号 (line 359-394)
    ↓
tasks.rs:472-546 - validate_and_add_transactions()
    ├─ VM 并行验证 (line 491-504)
    └─ 调用 mempool.add_txn() (line 515)
```

**2.3 存储到 Mempool**
```
core_mempool/mempool.rs:289-383 - add_txn()
    ├─ 验证序列号 (line 310-330)
    ├─ 创建 MempoolTransaction (line 333-346)
    └─ transactions.insert() (line 349)
```

### 数据结构
**文件**: `mempool/src/core_mempool/transaction_store.rs`

- **PriorityIndex**: 按 gas 价格排序（用于区块提议）
- **ParkingLotIndex**: 暂存不能立即执行的交易
- **TimelineIndex**: 按时间线组织准备广播的交易
- **TTLIndex**: 跟踪交易过期时间

### 2.4 交易广播机制（节点间复制）

> **重要**：当一笔交易通过 RPC 提交到一个节点并保存到内存池后，**这笔交易会主动广播到其他已连接的节点**，确保整个网络的交易同步。

#### 广播触发机制

**定时广播触发**
**文件**: `mempool/src/shared_mempool/coordinator.rs:119-120`

```rust
(peer, backoff) = scheduled_broadcasts.select_next_some() => {
    tasks::execute_broadcast(peer, backoff, &mut smp, &mut scheduled_broadcasts, executor.clone()).await;
}
```

- 每隔 `shared_mempool_tick_interval_ms`（默认 50ms）自动触发
- 向每个已连接的对等节点广播新交易
- 使用异步调度器管理广播时间

**新节点连接触发**
**文件**: `mempool/src/shared_mempool/coordinator.rs:434-437`

```rust
for peer in &newly_added_upstream {
    debug!(LogSchema::new(LogEntry::NewPeer).peer(peer));
    tasks::execute_broadcast(*peer, false, smp, scheduled_broadcasts, executor.clone())
        .await;
}
```

当有新的上游节点连接时，立即触发一次广播。

#### 广播内容选择

**文件**: `mempool/src/shared_mempool/network.rs:367-571`

`determine_broadcast_batch()` 函数决定向每个节点广播什么交易：

**三种批次类型**：

1. **新交易广播**（Fresh Broadcast）
   ```
   network.rs:492-563
       ├─ 从内存池的 TimelineIndex 读取新交易
       ├─ read_timeline(sender_bucket, old_timeline_id, max_txns)
       ├─ 选择对方节点还没有的交易
       └─ 最多 shared_mempool_batch_size 笔交易（可配置）
   ```

2. **超时重试广播**（Expired Broadcast）
   ```
   network.rs:432-450
       ├─ 检查已发送但未收到 ACK 的批次
       ├─ 超时阈值: shared_mempool_ack_timeout_ms
       └─ 重新广播超时的批次
   ```

3. **失败重试广播**（Retry Broadcast）
   ```
   network.rs:451-489
       ├─ 对方节点返回 retry=true 的批次
       ├─ 通常因为对方内存池已满
       └─ 按退避策略重试
   ```

#### 广播消息格式

**文件**: `mempool/src/shared_mempool/network.rs:581-591`

```rust
// 基本格式
MempoolSyncMsg::BroadcastTransactionsRequest {
    message_id: MempoolMessageId,      // 批次唯一 ID
    transactions: Vec<SignedTransaction>, // 完整交易列表
}

// 包含就绪时间的格式（优化版）
MempoolSyncMsg::BroadcastTransactionsRequestWithReadyTime {
    message_id: MempoolMessageId,
    transactions: Vec<(SignedTransaction, u64, BroadcastPeerPriority)>,
    // u64 是交易在发送方内存池中的就绪时间（毫秒时间戳）
}
```

**发送操作**
**文件**: `mempool/src/shared_mempool/network.rs:593-597`

```rust
self.network_client.send_to_peer(request, peer)
```

使用 DirectSend 协议发送到对等节点。

#### 接收和处理

**接收广播**
**文件**: `mempool/src/shared_mempool/coordinator.rs:352-409`

```rust
Event::Message(peer, message) => {
    match message {
        MempoolSyncMsg::BroadcastTransactionsRequest { message_id, transactions } => {
            handle_transaction_broadcast(
                smp.clone(),
                transactions,
                message_id,
                peer,
                executor.clone()
            );
        }
        ...
    }
}
```

**处理流程**
**文件**: `mempool/src/shared_mempool/tasks.rs:211-252`

```
process_transaction_broadcast()
    ├─ Line 231: process_incoming_transactions()
    │   ├─ 获取账户序列号（并行）
    │   ├─ VM 验证交易（并行）
    │   └─ 调用 mempool.add_txn() 添加到本地内存池
    │
    └─ Line 234-250: 生成并发送 ACK 响应
        ├─ 检查是否有 MempoolIsFull 错误
        ├─ 设置 retry 和 backoff 标志
        └─ 发送 BroadcastTransactionsResponse
```

#### ACK 确认机制

**接收方返回确认**
**文件**: `mempool/src/shared_mempool/tasks.rs:259-279`

```rust
MempoolSyncMsg::BroadcastTransactionsResponse {
    message_id: MempoolMessageId,
    retry: bool,      // 是否需要重试
    backoff: bool,    // 是否需要退避（延长广播间隔）
}
```

**ACK 响应逻辑**：
- **正常情况**：`retry=false, backoff=false` → 发送方从待确认列表移除该批次
- **内存池满**：`retry=true, backoff=true` → 发送方进入退避模式，延长广播间隔
- **超时未收到 ACK**：发送方自动重发该批次

**发送方处理 ACK**
**文件**: `mempool/src/shared_mempool/network.rs:299-357`

```rust
pub fn process_broadcast_ack(
    &self,
    peer: PeerNetworkId,
    message_id: MempoolMessageId,
    retry: bool,
    backoff: bool,
) {
    // Line 316: 从 sent_messages 中移除
    if let Some(sent_timestamp) = sync_state.broadcast_info.sent_messages.remove(&message_id) {
        // 记录 RTT（往返时间）
        counters::shared_mempool_pending_broadcasts(&peer).dec();
    }

    // Line 347-354: 处理重试和退避
    if retry {
        sync_state.broadcast_info.retry_messages.insert(message_id);
    }
    if backoff {
        sync_state.broadcast_info.backoff_mode = true;
    }
}
```

#### 退避控制机制

**退避模式触发条件**：
- 对方内存池已满（`MempoolIsFull`）
- 待确认广播数量超过 `max_broadcasts_per_peer`（默认 10）

**退避效果**：
- 正常间隔：`shared_mempool_tick_interval_ms`（默认 50ms）
- 退避间隔：`shared_mempool_backoff_interval_ms`（默认 1000ms）

**退避恢复**：
- 当对方成功处理广播并返回正常 ACK 后，退避模式关闭

#### 验证者网络的特殊处理

**文件**: `mempool/src/shared_mempool/tasks.rs:784-785`

```rust
*broadcast_within_validator_network.write() =
    !consensus_config.quorum_store_enabled() && !consensus_config.is_dag_enabled()
```

**两种模式**：

| 模式 | 启用条件 | 广播行为 |
|------|---------|---------|
| **内存池广播** | Quorum Store 未启用 | ✅ 验证者之间正常广播交易 |
| **Quorum Store 批处理** | Quorum Store 已启用 | ❌ 验证者之间不通过内存池广播，改用批处理机制（见阶段 3） |

**判断逻辑**
**文件**: `mempool/src/shared_mempool/tasks.rs:141-147`

```rust
let ineligible_for_broadcast =
    smp.network_interface.is_validator() && !smp.broadcast_within_validator_network();
let timeline_state = if ineligible_for_broadcast {
    TimelineState::NonQualified  // 不放入广播时间线
} else {
    TimelineState::NotReady      // 放入广播时间线
};
```

当验证者启用 Quorum Store 时：
- 交易标记为 `NonQualified`，不参与内存池广播
- 交易通过 Quorum Store 的批处理机制传播（见阶段 3.10）

#### 完整广播流程图

```
节点 A                                 节点 B                                 节点 C
  |                                      |                                      |
  | 1. 接收 RPC 提交交易                  |                                      |
  | 2. 验证并保存到内存池                  |                                      |
  | 3. TimelineIndex.insert()            |                                      |
  |                                      |                                      |
  | [定时器触发，每 50ms]                 |                                      |
  | 4. execute_broadcast()               |                                      |
  | 5. determine_broadcast_batch()       |                                      |
  |    ├─ 读取新交易                      |                                      |
  |    └─ 创建 MempoolSyncMsg             |                                      |
  |                                      |                                      |
  |------ BroadcastTransactionsRequest -->| 6. 接收广播消息                       |
  |                                      | 7. process_transaction_broadcast()   |
  |                                      |    ├─ VM 验证                        |
  |                                      |    └─ add_txn() 到本地内存池          |
  |                                      |                                      |
  |<----- BroadcastTransactionsResponse --| 8. 发送 ACK                          |
  | 9. process_broadcast_ack()           |                                      |
  |    └─ 移除 sent_messages             |                                      |
  |                                      |                                      |
  |                                      | [定时器触发，节点 B 广播]              |
  |                                      | 10. execute_broadcast()              |
  |                                      |------ BroadcastTransactionsRequest -->| 11. 接收并处理
  |                                      |                                      |     add_txn()
  |                                      |<----- BroadcastTransactionsResponse --| 12. 发送 ACK
  |                                      |                                      |
  |                                      |                                      |
  | 结果: 交易已在所有节点的内存池中同步     |                                      |
```

#### 性能优化和限制

**并发限制**：
- `max_broadcasts_per_peer`：单个节点最多同时 10 个待确认广播
- 超过限制则等待 ACK 或超时

**批次大小**：
- `shared_mempool_batch_size`：单次广播最多交易数（可配置）
- 平衡网络带宽和延迟

**优先级机制**（全节点）：
```rust
pub enum BroadcastPeerPriority {
    Primary,   // 主要节点：立即广播所有交易
    Failover,  // 备用节点：延迟一段时间后才广播（shared_mempool_failover_delay_ms）
}
```

验证者之间不区分优先级，全部视为 Primary。

**关键文件路径**:
- `mempool/src/shared_mempool/coordinator.rs:57-135` - 主事件循环
- `mempool/src/shared_mempool/coordinator.rs:119-120` - 广播调度
- `mempool/src/shared_mempool/coordinator.rs:352-409` - 接收广播消息
- `mempool/src/shared_mempool/coordinator.rs:434-437` - 新节点触发
- `mempool/src/shared_mempool/tasks.rs:57-123` - 广播执行
- `mempool/src/shared_mempool/tasks.rs:211-252` - 广播接收处理
- `mempool/src/shared_mempool/tasks.rs:259-279` - ACK 生成
- `mempool/src/shared_mempool/tasks.rs:784-785` - 验证者广播控制
- `mempool/src/shared_mempool/network.rs:367-571` - 批次选择逻辑
- `mempool/src/shared_mempool/network.rs:581-597` - 消息发送
- `mempool/src/shared_mempool/network.rs:299-357` - ACK 处理
- `mempool/src/shared_mempool/types.rs:474-482` - BroadcastInfo 数据结构
- `mempool/src/core_mempool/mempool.rs:289-383` - 核心添加逻辑
- `mempool/src/core_mempool/transaction_store.rs:235-369` - 存储操作

---

## 阶段 3（可选）：Quorum Store 批次预处理

> **注意**: 这是一个可选的优化阶段。Aptos 支持两种模式：
> - **Quorum Store 模式**：交易提前批处理和签名（本节描述）
> - **Direct Mempool 模式**：直接从 Mempool 拉取交易（传统方式）

### 什么是 Quorum Store？

Quorum Store 是 Aptos 共识层的关键优化组件，**将交易传播与区块提议解耦**，大幅提升网络效率。

**核心思想**：
- 交易在被打包进区块之前，先组织成批次（Batch）
- 批次由验证者签名确认（ProofOfStore = 2f+1 签名）
- 区块只包含批次的引用（几KB），而非完整交易（几MB）
- 验证者从本地存储获取完整交易执行

### 3.1 核心数据结构

**BatchInfo** - 批次元数据
**文件**: `consensus/consensus-types/src/proof_of_store.rs:25-34`

```rust
pub struct BatchInfo {
    author: PeerId,           // 批次创建者
    batch_id: BatchId,        // 唯一批次 ID（微秒时间戳）
    epoch: u64,               // 所属轮次
    expiration: u64,          // 过期时间
    digest: HashValue,        // 交易内容哈希摘要
    num_txns: u64,           // 包含的交易数量
    num_bytes: u64,          // 批次总字节数
    gas_bucket_start: u64,   // Gas 价格桶起始值
}
```

**ProofOfStore** - 批次存在证明
**文件**: `consensus/consensus-types/src/proof_of_store.rs:320-323`

```rust
pub struct ProofOfStore {
    info: BatchInfo,                      // 批次信息
    multi_signature: AggregateSignature,  // 2f+1 验证者的聚合签名
}
```

### 3.2 批次生成流程

**BatchGenerator** - 持续从 Mempool 创建批次
**文件**: `consensus/src/quorum_store/batch_generator.rs:60-121`

```
BatchGenerator::new() (line 78)
    ├─ 初始化 batch_id（微秒时间戳）(line 87-96)
    ├─ 连接 MempoolProxy (line 110)
    └─ 设置背压控制 (line 116-119)
    ↓
定时任务触发批次拉取
    ↓
MempoolProxy::pull_internal() (utils.rs:110-147)
    ├─ 发送 QuorumStoreRequest::GetBatchRequest
    └─ 从 Mempool 获取高优先级交易
    ↓
BatchGenerator::insert_batch() (line 123-166)
    ├─ 计算批次哈希 (digest)
    ├─ 创建 BatchInfo
    ├─ 持久化到本地数据库
    └─ 签名并广播 SignedBatchInfo
```

### 3.3 批次分发和存储

**BatchCoordinator** - 接收并存储远程批次
**文件**: `consensus/src/quorum_store/batch_coordinator.rs:34-47`

```
NetworkListener 接收 Batch (network_listener.rs:18-23)
    ├─ 轮询分发到多个 BatchCoordinator 实例
    ↓
BatchCoordinator::handle_batch()
    ├─ 验证批次签名
    ├─ 持久化到 BatchStore
    └─ 通知 ProofCoordinator
```

**BatchStore** - 内存和持久化存储
**文件**: `consensus/src/quorum_store/batch_store.rs`

```
功能:
├─ 内存缓存：快速访问最近批次
├─ 数据库持久化：长期存储批次数据
├─ 配额管理：控制内存和磁盘使用
└─ 过期清理：删除超时批次
```

### 3.4 证明聚合（Proof Aggregation）

**ProofCoordinator** - 收集签名形成证明
**文件**: `consensus/src/quorum_store/proof_coordinator.rs:38-102`

```
ProofCoordinator 接收 SignedBatchInfo
    ↓
IncrementalProofState::add_signature()
    ├─ 验证签名合法性
    ├─ 累加验证者投票权重
    └─ 检查是否达到 2f+1 阈值
    ↓
当达到 2f+1 投票权重:
    ├─ SignatureAggregator 聚合 BLS 签名
    ├─ 创建 ProofOfStore
    └─ 广播 ProofOfStore 到全网
```

### 3.5 证明管理和提议

**ProofManager** - 管理已证明的批次
**文件**: `consensus/src/quorum_store/proof_manager.rs:30-38`

```
ProofManager 维护 BatchProofQueue
    ├─ 按验证者和优先级排序
    ├─ 响应区块提议者的拉取请求
    └─ 管理背压（防止内存溢出）
    ↓
当提议者需要交易时:
    └─ get_batch_for_proposal()
        ├─ 从队列中选择高优先级批次
        ├─ 返回 ProofOfStore（非完整交易）
        └─ 提议者将 ProofOfStore 打包进区块
```

### 3.6 Payload 类型对比

**文件**: `consensus/consensus-types/src/common.rs:210-220`

```rust
pub enum Payload {
    // Direct Mempool 模式：完整交易
    DirectMempool(Vec<SignedTransaction>),

    // Quorum Store 模式：只有证明引用
    InQuorumStore(ProofWithData),
    InQuorumStoreWithLimit(ProofWithDataWithTxnLimit),

    // 混合模式
    QuorumStoreInlineHybrid(...),
}
```

**区块大小对比**：
- **DirectMempool**: 5000 笔交易 × 300 bytes = ~1.5 MB
- **InQuorumStore**: 5 个批次证明 × 500 bytes = ~2.5 KB
- **节省**: ~600 倍带宽

### 3.7 完整流程图

```
【持续后台运行】
Mempool
  ↓
BatchGenerator 定时拉取交易 (每 100ms)
  ├─ 创建 Batch (1000-5000 txns)
  ├─ 计算 BatchInfo (digest, size)
  └─ 签名并广播 SignedBatchInfo
  ↓
其他验证者接收
  ├─ BatchCoordinator 存储到本地
  ├─ 验证并签名 SignedBatchInfo
  └─ 发送签名给 ProofCoordinator
  ↓
ProofCoordinator 聚合签名
  ├─ 收集 2f+1 签名
  ├─ 创建 ProofOfStore
  └─ 广播 ProofOfStore

【区块提议时】
提议者需要交易
  ↓
从 ProofManager 获取 ProofOfStore
  ↓
创建区块（只包含 ProofOfStore，不含完整交易）
  ↓
广播轻量级区块（几 KB）
  ↓
验证者接收区块
  ├─ 验证 ProofOfStore 签名
  ├─ 从本地 BatchStore 获取完整交易
  └─ 执行交易
```

### 3.8 关键优势

**1. 网络效率提升 100-1000 倍**
```
传统方式: 区块包含完整交易 → 每个验证者都收到完整数据
Quorum Store: 批次提前分发 → 区块只包含小引用
```

**2. 解耦共识和数据传播**
```
传统方式: 提议 → 等待大数据传输 → 执行 → 投票（瓶颈）
Quorum Store: 数据提前分发（异步）+ 快速提议（同步）
```

**3. 拜占庭容错保证**
```
ProofOfStore = 2f+1 签名
→ 确保批次已被多数验证者确认存储
→ 防止恶意提议者引用不存在的批次
```

**4. 动态背压控制**
```rust
pub struct BackPressure {
    pub txn_count: bool,   // 待处理交易过多
    pub proof_count: bool, // 待处理证明过多
}
```
当系统负载高时，自动减缓批次生成速率。

### 3.9 Quorum Store 批处理传播机制详解

> 本节详细说明当启用 Quorum Store 时，交易如何在验证者网络中传播。这与阶段 2.4 的内存池广播机制形成对比。

#### 批处理传播 vs 内存池广播

| 方面 | 内存池广播（阶段 2.4） | Quorum Store 批处理（本节） |
|------|---------------------|------------------------|
| **适用网络** | 全节点网络、未启用 QS 的验证者 | 启用 Quorum Store 的验证者网络 |
| **传播单位** | 单个交易 | 交易批次（1000-5000 笔） |
| **传播协议** | DirectSend P2P | 批次广播 + 签名聚合 |
| **可靠性保证** | ACK 确认 | 2f+1 签名（ProofOfStore） |
| **传播时机** | 实时（50ms 间隔） | 批量（100ms 间隔） |
| **网络效率** | 较低（单笔传播） | 极高（批量传播） |

#### 完整传播流程

##### 阶段 1: 批次创建和初始广播

**文件**: `consensus/src/quorum_store/batch_generator.rs:60-166`

```
验证者 A (BatchGenerator)
    ↓
定时任务触发（每 100ms）
    ↓
MempoolProxy::pull_internal() (utils.rs:110-147)
    ├─ 从本地 Mempool 拉取交易
    ├─ max_txns: 5000（可配置）
    └─ 按 gas 价格优先级排序
    ↓
BatchGenerator::insert_batch() (batch_generator.rs:123-166)
    ├─ Line 130: 计算批次哈希 (digest)
    │   let digest = hash_transactions(&txns)
    ├─ Line 135-144: 创建 BatchInfo
    │   BatchInfo {
    │       author: self.author,
    │       batch_id: self.batch_id.fetch_add(1),
    │       epoch: self.epoch,
    │       expiration: now + batch_expiry_duration,
    │       digest,
    │       num_txns: txns.len(),
    │       num_bytes: txns_bytes,
    │       gas_bucket_start,
    │   }
    ├─ Line 149: 持久化到本地 BatchStore
    │   self.batch_store.save_batch(batch_id, txns)
    └─ Line 157-162: 签名并广播
        ├─ 创建 SignedBatchInfo（包含验证者签名）
        └─ network_sender.broadcast(SignedBatchInfo)
```

**关键点**：
- 验证者 A 不直接发送完整交易，只发送 `BatchInfo` + 签名（约 300 bytes）
- 完整交易先保存到本地 `BatchStore`

##### 阶段 2: 其他验证者接收和存储

**文件**: `consensus/src/quorum_store/batch_coordinator.rs:34-47`

```
验证者 B、C、D... (BatchCoordinator)
    ↓
NetworkListener 接收 SignedBatchInfo (network_listener.rs:18-23)
    ├─ 轮询分发到多个 BatchCoordinator 实例
    └─ 根据 batch_id 分配到对应协调器
    ↓
BatchCoordinator::handle_batch()
    ├─ Step 1: 验证签名
    │   verify_signature(signed_batch_info.author, signed_batch_info.signature)
    │
    ├─ Step 2: 请求完整交易数据
    │   network_sender.request_batch(author, batch_id)
    │   ↓
    │   验证者 A 收到请求
    │   ↓
    │   从本地 BatchStore 读取完整交易
    │   ↓
    │   发送 BatchResponse { batch_id, transactions }
    │
    ├─ Step 3: 接收完整交易
    │   验证交易哈希是否匹配 BatchInfo.digest
    │   if hash(transactions) != batch_info.digest {
    │       reject // 防止恶意节点
    │   }
    │
    ├─ Step 4: 持久化到本地 BatchStore
    │   self.batch_store.save_batch(batch_id, transactions)
    │
    └─ Step 5: 签名并发送给 ProofCoordinator
        ├─ 创建自己的 SignedBatchInfo
        └─ send_to_proof_coordinator(SignedBatchInfo)
```

**文件**: `consensus/src/quorum_store/batch_store.rs`

```rust
pub struct BatchStore {
    // 内存缓存：最近的批次
    batches: RwLock<LruCache<BatchId, Vec<SignedTransaction>>>,

    // 持久化存储
    db: Arc<dyn QuorumStoreDB>,

    // 配额管理
    memory_quota: AtomicU64,
    disk_quota: AtomicU64,
}
```

**存储操作**：
1. **内存缓存**：快速访问最近 1000 个批次
2. **数据库持久化**：长期存储，防止内存溢出
3. **配额控制**：内存超限时写入磁盘
4. **过期清理**：定期删除过期批次

##### 阶段 3: 签名聚合形成证明

**文件**: `consensus/src/quorum_store/proof_coordinator.rs:38-102`

```
ProofCoordinator (通常运行在每个验证者上)
    ↓
接收来自本地和其他验证者的 SignedBatchInfo
    ↓
IncrementalProofState::add_signature() (proof_coordinator.rs:60-85)
    ├─ Line 65: 验证签名合法性
    │   if !verify_signature(signed_batch_info) {
    │       return Err("Invalid signature");
    │   }
    │
    ├─ Line 70: 累加验证者投票权重
    │   let author_stake = validator_set.get_stake(author);
    │   accumulated_stake += author_stake;
    │
    ├─ Line 75: 检查是否达到 2f+1 阈值
    │   let quorum_threshold = total_stake * 2 / 3 + 1;
    │   if accumulated_stake >= quorum_threshold {
    │       // 达到法定人数
    │   }
    │
    └─ Line 80-85: 聚合签名
        ├─ SignatureAggregator::add(signature)
        └─ aggregate_signature = SignatureAggregator::finish()
    ↓
达到 2f+1 投票权重后
    ↓
proof_coordinator.rs:87-102 - 创建并广播 ProofOfStore
    ├─ Line 90: 创建 ProofOfStore
    │   ProofOfStore {
    │       info: batch_info,
    │       multi_signature: aggregate_signature,  // BLS 聚合签名
    │   }
    │
    └─ Line 98: 广播到全网
        network_sender.broadcast(ProofOfStore)
```

**BLS 聚合签名的优势**：
- **签名前**：100 个验证者 × 96 bytes/签名 = 9.6 KB
- **签名后**：1 个聚合签名 = 96 bytes
- **压缩比**：100:1

##### 阶段 4: ProofOfStore 分发和管理

**文件**: `consensus/src/quorum_store/proof_manager.rs:30-87`

```
所有验证者接收 ProofOfStore
    ↓
ProofManager::receive_proof() (proof_manager.rs:45-70)
    ├─ Line 50: 验证聚合签名
    │   verify_multi_signature(
    │       proof.multi_signature,
    │       proof.info.digest,
    │       validator_set
    │   )
    │
    ├─ Line 58: 检查本地是否有对应批次数据
    │   if !batch_store.exists(proof.info.batch_id) {
    │       // 请求缺失的批次数据
    │       request_missing_batch(proof.info.author, proof.info.batch_id);
    │   }
    │
    └─ Line 65: 插入到证明队列
        proof_queue.insert(proof)
    ↓
ProofManager::get_batch_for_proposal() (proof_manager.rs:72-87)
    ├─ 区块提议者调用此方法
    ├─ 从队列中选择高优先级证明
    ├─ 按验证者和 gas 价格排序
    └─ 返回 ProofOfStore（不包含完整交易）
```

**ProofManager 的队列结构**:

```rust
pub struct BatchProofQueue {
    // 按验证者分组
    batches_by_author: HashMap<PeerId, VecDeque<ProofOfStore>>,

    // 按 gas 价格排序
    batches_by_gas_bucket: BTreeMap<u64, Vec<ProofOfStore>>,

    // 背压控制
    back_pressure: BackPressure,
}
```

#### 与区块提议的集成

当验证者成为区块提议者时：

**文件**: `consensus/src/liveness/proposal_generator.rs:653-673`

```
proposal_generator.rs - generate_proposal_inner()
    ↓
Line 653: 从 PayloadClient 拉取负载
    payload_client.pull_payload(max_size, max_txns)
    ↓
【Quorum Store 模式】
payload_client = QuorumStoreClient
    ↓
QuorumStoreClient::pull_payload()
    ├─ 调用 proof_manager.get_batch_for_proposal()
    ├─ 获取多个 ProofOfStore（根据区块大小限制）
    └─ 返回 Payload::InQuorumStore(proofs)
    ↓
BlockData 包含 ProofOfStore（不包含完整交易）
    ├─ block_size = proofs.len() × ~500 bytes
    └─ 例如: 10 个证明 = ~5 KB（而非 15 MB）
    ↓
广播区块提议（网络负载极小）
```

#### 验证者执行时获取完整交易

**文件**: `consensus/src/block_storage/block_store.rs:491`

```
验证者接收区块提议
    ↓
block_store.rs:413 - insert_block()
    ↓
block_store.rs:491 - pipeline_builder.build_for_consensus()
    ↓
【如果区块包含 ProofOfStore】
pipeline_builder.rs - prepare 阶段
    ├─ 提取区块中的所有 ProofOfStore
    ├─ 遍历每个 ProofOfStore
    └─ 从本地 BatchStore 获取完整交易
        ↓
        batch_store.get_batch(proof.info.batch_id)
        ↓
        if batch_exists {
            return transactions  // 直接从本地获取
        } else {
            // 缺失批次数据（罕见情况）
            request_batch_from_peer(proof.info.author, batch_id)
            wait_for_batch()
            return transactions
        }
    ↓
获取所有完整交易后
    ↓
execute 阶段 - 推测性执行交易
    ↓
投票（包含状态认证器）
```

**关键点**：
- 验证者在执行前已经有完整交易（在阶段 2 已存储）
- 从本地读取，无需网络请求
- 如果缺失，可向原作者请求（容错机制）

#### 完整传播流程图

```
时间线 →

验证者 A (作者)                      验证者 B                        验证者 C                        验证者 D
    |                                  |                               |                               |
    | [定时任务，每 100ms]               |                               |                               |
    | 1. 从 Mempool 拉取交易             |                               |                               |
    |    (5000 笔，约 1.5 MB)            |                               |                               |
    |                                  |                               |                               |
    | 2. 计算批次哈希                    |                               |                               |
    |    digest = hash(txns)           |                               |                               |
    |                                  |                               |                               |
    | 3. 保存到本地 BatchStore           |                               |                               |
    |    batch_store.save()            |                               |                               |
    |                                  |                               |                               |
    | 4. 创建并签名 BatchInfo            |                               |                               |
    |    SignedBatchInfo (300 bytes)   |                               |                               |
    |                                  |                               |                               |
    |-------- broadcast SignedBatchInfo -------->| 5. 接收 BatchInfo            |                               |
    |                                  | 6. 验证签名                    |                               |
    |                                  |                               |                               |
    |<------- request_batch ----------|                               |                               |
    | 7. 发送完整交易                   |                               |                               |
    |-------- BatchResponse (1.5 MB) ---->| 8. 验证哈希匹配                |                               |
    |                                  | 9. 保存到 BatchStore           |                               |
    |                                  | 10. 签名 BatchInfo             |                               |
    |                                  |                               |                               |
    |<-------- SignedBatchInfo --------|                               |                               |
    | 11. 收集签名                      |                               |                               |
    |                                  |                               |                               |
    |-------- broadcast SignedBatchInfo ------------------------>| 12. 接收 BatchInfo             |
    |                                  |                               | 13. 请求完整交易                |
    |<------- request_batch --------------------------------------|                               |
    |-------- BatchResponse (1.5 MB) --------------------------->| 14. 保存到 BatchStore           |
    |                                  |                               | 15. 签名 BatchInfo             |
    |<-------- SignedBatchInfo -----------------------------------| 16. 发送签名                   |
    |                                  |                               |                               |
    |-------- broadcast SignedBatchInfo ---------------------------------------------->| 17. 类似流程
    |                                  |                               |                               |    ...
    | [ProofCoordinator 运行]           |                               |                               |
    | 18. 收集到 2f+1 签名              |                               |                               |
    |     (假设 4 个验证者，需要 3 个)    |                               |                               |
    |                                  |                               |                               |
    | 19. 聚合 BLS 签名                 |                               |                               |
    |     multi_sig = aggregate([A,B,C])                              |                               |
    |                                  |                               |                               |
    | 20. 创建 ProofOfStore            |                               |                               |
    |     (BatchInfo + 聚合签名, 500 bytes)                            |                               |
    |                                  |                               |                               |
    |-------- broadcast ProofOfStore -------->| 21. 接收证明                 | -------------------------->| 22. 接收证明
    |                                  | 22. 验证聚合签名                | 23. 验证聚合签名                | 24. 验证聚合签名
    |                                  | 23. 插入 ProofQueue            | 24. 插入 ProofQueue            | 25. 插入 ProofQueue
    |                                  |                               |                               |
    |                                  |                               |                               |
    | [等待成为区块提议者]               |                               |                               |
    |                                  | [验证者 B 成为提议者]           |                               |
    |                                  |                               |                               |
    |                                  | 25. 拉取 ProofOfStore          |                               |
    |                                  |     proof_manager.get()       |                               |
    |                                  |                               |                               |
    |                                  | 26. 创建区块提议                |                               |
    |                                  |     BlockData {               |                               |
    |                                  |       payload: InQuorumStore([proof]),                          |
    |                                  |     }  // 约 5 KB             |                               |
    |                                  |                               |                               |
    |<-------- broadcast Block --------|                               |                               |
    | 27. 接收区块                      |                               | <--------------------------| 28. 接收区块
    | 28. 从 BatchStore 读取交易         |                               | 29. 从 BatchStore 读取交易      | 30. 从 BatchStore 读取交易
    |     get_batch(proof.batch_id)    |                               |     (本地读取，无网络开销)       |     (本地读取，无网络开销)
    |                                  |                               |                               |
    | 29. 执行交易                      |                               | 30. 执行交易                   | 31. 执行交易
    | 30. 对执行结果投票                 |                               | 31. 对执行结果投票              | 32. 对执行结果投票
    |                                  |                               |                               |
    |                                  | [收集 2f+1 投票，形成 QC]       |                               |
    |                                  |                               |                               |
    | 结果: 交易已通过批处理机制高效传播，所有验证者都有完整数据                                            |
```

#### 传播机制的关键特性

**1. 两阶段传播**
```
阶段 1: BatchInfo 传播（元数据，小数据）
    └─ 所有验证者快速知道批次存在

阶段 2: 完整交易拉取（按需，点对点）
    └─ 验证者主动从作者拉取完整数据
```

**2. 防止重复传播**
```
传统内存池广播:
    交易 A → 节点 1 → 节点 2 → 节点 3
    交易 A → 节点 4 → 节点 2 (重复)
    每笔交易传播多次

Quorum Store:
    批次 B (5000 笔交易)
    → 作者 A 持久化
    → 其他节点按需拉取（每个节点只拉取一次）
    → 批次不再重复传播
```

**3. 带宽对比分析**

**场景**: 100 个验证者，每个区块 5000 笔交易，每笔 300 bytes

**传统 Direct Mempool 模式**:
```
阶段 1: 内存池广播（阶段 2.4）
    └─ 5000 笔 × 300 bytes × 100 验证者 = 150 MB

阶段 2: 区块提议广播
    └─ 1.5 MB × 100 验证者 = 150 MB

总带宽: 300 MB
```

**Quorum Store 模式**:
```
阶段 1: BatchInfo 广播
    └─ 300 bytes × 100 验证者 = 30 KB

阶段 2: 完整交易拉取（点对点）
    └─ 1.5 MB × 99 验证者 = 148.5 MB
    (作者本地已有，无需拉取)

阶段 3: ProofOfStore 广播
    └─ 500 bytes × 100 验证者 = 50 KB

阶段 4: 区块提议广播
    └─ 5 KB × 100 验证者 = 500 KB
    (只包含 ProofOfStore，不包含完整交易)

总带宽: 149.08 MB

节省: (300 - 149.08) / 300 = 50.3%
```

**实际优化更显著**，因为：
- 批次可复用于多个区块
- 区块提议带宽从 150 MB 降至 500 KB（300 倍）

**4. 容错机制**

```
情况 1: 验证者收到 ProofOfStore 但缺失批次数据
    └─ 从批次作者请求 (request_batch)
    └─ 如果作者不响应，从其他已有该批次的验证者请求

情况 2: 批次作者下线
    └─ ProofOfStore = 2f+1 签名，确保至少 2f+1 个验证者有数据
    └─ 从任意持有该批次的验证者获取

情况 3: 批次过期
    └─ 定期清理过期批次（expiration 字段）
    └─ 过期批次不会被提议进区块
```

**5. 与内存池广播的协同**

```
全节点网络 (FullNode):
    ├─ 使用内存池广播（阶段 2.4）
    └─ 不参与 Quorum Store

验证者网络 (Validator):
    ├─ 如果启用 Quorum Store:
    │   └─ 不使用内存池广播
    │   └─ 使用批处理机制（本节）
    │
    └─ 如果未启用 Quorum Store:
        └─ 使用内存池广播（阶段 2.4）

混合场景:
    客户端提交到全节点
    ↓
    全节点内存池广播
    ↓
    交易到达验证者
    ↓
    验证者通过 Quorum Store 批处理传播
```

#### 性能数据

**延迟对比**:
```
内存池广播:
    └─ 50ms 间隔 → 交易快速到达所有节点

Quorum Store:
    └─ 100ms 批次生成 + 网络传播 + 签名聚合
    └─ 总延迟: 200-500ms
    └─ 但区块提议更快（轻量级区块）
```

**吞吐量对比**:
```
内存池广播:
    └─ 受限于网络带宽（大量重复传输）
    └─ 实测: ~1000-2000 TPS

Quorum Store:
    └─ 批量传播 + 解耦数据传播和共识
    └─ 实测: ~10000-30000 TPS
```

**资源消耗**:
```
BatchStore 磁盘使用:
    └─ 批次过期后自动清理
    └─ 配额管理（max_batch_store_size）
    └─ 典型: 每个验证者 10-50 GB

网络带宽节省:
    └─ 区块提议: 300-1000 倍
    └─ 总体: 50-80%
```

### 3.10 关键文件路径

| 组件 | 文件路径 | 作用 |
|------|---------|------|
| Batch Generator | `consensus/src/quorum_store/batch_generator.rs:60-121` | 创建交易批次 |
| Batch Coordinator | `consensus/src/quorum_store/batch_coordinator.rs:34-47` | 接收和存储批次 |
| Batch Store | `consensus/src/quorum_store/batch_store.rs` | 批次存储管理 |
| Proof Coordinator | `consensus/src/quorum_store/proof_coordinator.rs:38-102` | 签名聚合 |
| Proof Manager | `consensus/src/quorum_store/proof_manager.rs:30-38` | 证明队列管理 |
| Network Listener | `consensus/src/quorum_store/network_listener.rs:18-23` | 网络消息路由 |
| Quorum Store Coordinator | `consensus/src/quorum_store/quorum_store_coordinator.rs:24-31` | 总协调器 |
| BatchInfo | `consensus/consensus-types/src/proof_of_store.rs:25-34` | 批次元数据 |
| ProofOfStore | `consensus/consensus-types/src/proof_of_store.rs:320-323` | 批次证明 |
| Payload Types | `consensus/consensus-types/src/common.rs:210-220` | 负载类型 |
| Mempool Proxy | `consensus/src/quorum_store/utils.rs:97-148` | Mempool 通信 |

---

## 阶段 4：区块生成和交易选择

> **注意**: 如果启用了 Quorum Store，区块中包含 ProofOfStore；否则包含完整交易。

### 4.1 区块提议触发
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:387-475 - on_new_round()
    ├─ 检查是否是当前轮次的提议者 (line 433)
    └─ 生成并发送提议 (line 450-476)
    ↓
round_manager.rs:478-511 - generate_and_send_proposal()
```

### 4.2 从 Mempool/Quorum Store 选择交易
**文件**: `consensus/src/liveness/proposal_generator.rs`

```
proposal_generator.rs:497-557 - generate_proposal()
    ↓
proposal_generator.rs:559-687 - generate_proposal_inner()
    ├─ 获取父区块 (line 577-578)
    ├─ 计算最大区块大小（含背压）(line 606-614)
    └─ 从 PayloadClient 拉取交易/证明 (line 653-673)
        ├─ Quorum Store 模式: 拉取 ProofOfStore
        └─ Direct Mempool 模式: 拉取完整交易
```

### 4.3 Mempool 批量获取（Direct Mempool 模式）
**文件**: `mempool/src/core_mempool/mempool.rs`

```
mempool.rs:426-550 - get_batch()
    ├─ 按 gas 价格优先级迭代 (line 450)
    ├─ 遵守序列号顺序 (line 460-498)
    ├─ 过滤已排除的交易 (line 455-457)
    └─ 累积字节直到达到限制 (line 521-529)
```

### 4.4 区块数据构建
**文件**: `consensus/src/liveness/proposal_generator.rs`

```
proposal_generator.rs:535-554 - 构建 BlockData
    ├─ Quorum Store: BlockData 包含 ProofOfStore（几 KB）
    └─ Direct Mempool: BlockData 包含完整交易（几 MB）
    ↓
round_manager.rs:630-654 - generate_proposal()
    ├─ 使用 SafetyRules 签名 (line 641)
    └─ 包装为 ProposalMsg (line 653)
    ↓
network.rs:404-409 - broadcast_proposal()
    └─ 广播到所有验证者（Quorum Store 模式下带宽节省显著）
```

**关键文件路径**:
- `consensus/src/round_manager.rs:387-511` - 提议生成
- `consensus/src/liveness/proposal_generator.rs:497-687` - 生成逻辑
- `mempool/src/core_mempool/mempool.rs:426-550` - 交易选择（Direct 模式）
- `consensus/src/quorum_store/proof_manager.rs:30-38` - 证明选择（Quorum Store 模式）
- `consensus/src/network.rs:404-409` - 网络广播

---

## 阶段 5：Move VM 执行交易

> **重要**:
> - **所有验证者都要执行交易**，不仅仅是提议者！
> - 每个验证者在投票之前推测性执行区块中的所有交易
> - 验证者对执行结果（状态认证器）进行投票，而不仅仅是交易顺序
> - 如果区块包含 ProofOfStore，验证者先从本地 BatchStore 获取完整交易

### 5.1 区块执行入口
**文件**: `aptos-move/aptos-vm/src/aptos_vm.rs`

```
aptos_vm.rs:2948-2995 - AptosVMBlockExecutor::execute_block_with_config()
    ↓
block_executor/mod.rs:584-605 - execute_block()
    └─ 使用共享的 rayon 线程池
```

### 5.2 并行执行引擎
**文件**: `aptos-move/block-executor/src/executor.rs`

```
executor.rs:2492-2610 - BlockExecutor::execute_block()
    ├─ 尝试并行执行 (BlockSTM v2/v1) (line 2501-2523)
    └─ 失败则回退到串行执行 (line 2544-2590)
    ↓
executor.rs:1669-1810 - execute_transactions_parallel_v2()
    ├─ 创建调度器和工作线程
    └─ 生成 rayon 线程池任务
```

### 5.3 单个交易执行
**文件**: `aptos-move/aptos-vm/src/block_executor/vm_wrapper.rs`

```
vm_wrapper.rs:45-114 - AptosExecutorTask::execute_transaction()
    ├─ 从状态视图创建解析器
    └─ 调用 vm.execute_single_transaction()
    ↓
aptos_vm.rs:2778-2927 - AptosVM::execute_single_transaction()
    └─ 根据交易类型分发
```

### 5.4 用户交易执行
**文件**: `aptos-move/aptos-vm/src/aptos_vm.rs`

```
aptos_vm.rs:2152-2174 - execute_user_transaction()
    ↓
aptos_vm.rs:1920-2055 - execute_user_transaction_impl()
    ├─ Prologue: 验证签名和账户状态
    ├─ Payload: 执行 Move 代码
    └─ Epilogue: 处理 gas 和费用
```

### 5.5 Move 代码执行
**文件**: `aptos-move/aptos-vm/src/move_vm_ext/session/mod.rs`

```
session/mod.rs:108 - execute_function_bypass_visibility()
    ↓
session/mod.rs:139 - execute_loaded_function()
    ↓
调用 MoveVM::execute_loaded_function()
    └─ 执行 Move 字节码
```

### 5.6 推测执行和投票机制（重要）

**所有验证者都执行交易的完整流程**：

#### 执行和投票流程

**文件**: `consensus/src/round_manager.rs`

```
验证者接收区块提议
    ↓
round_manager.rs:1344 - process_verified_proposal()
    ├─ 检查区块合法性
    └─ 调用 create_vote()
    ↓
round_manager.rs:1325 - create_vote()
    └─ 调用 vote_block()
    ↓
round_manager.rs:1462 - vote_block()
    ├─ 调用 block_store.insert_block()  【关键：这里执行交易】
    ├─ 检查投票规则（SafetyRules）
    └─ 创建包含状态认证器的投票
    ↓
block_store.rs:413 - insert_block()
    └─ insert_block_inner()
    ↓
block_store.rs:491 - insert_block_inner()
    └─ pipeline_builder.build_for_consensus()  【构建执行管道】
        ├─ 推测性执行所有交易
        ├─ 计算执行后的状态哈希（状态认证器）
        └─ 不提交到持久化存储（无外部效应）
    ↓
验证者对区块和执行结果投票
    ├─ 投票包含：区块哈希 + 状态认证器
    └─ 发送给下一轮的领导者
```

#### 关键概念

**1. 推测执行（Speculative Execution）**

```
定义：在交易最终提交之前就执行它们
特点：
├─ 所有验证者并行执行相同的交易
├─ 执行结果存储在内存中（不写入磁盘）
├─ 如果区块未被提交，执行结果被丢弃
└─ 如果区块被提交，执行结果被持久化
```

**代码位置**: `consensus/src/block_storage/block_store.rs:491`
```rust
pipeline_builder.build_for_consensus(
    &pipelined_block,
    parent_block.pipeline_futs()?,
    callback,
);  // 构建执行管道，推测性执行交易
```

**2. 状态认证器（State Authenticator）**

```
定义：执行后数据库状态的加密哈希
作用：
├─ 所有诚实验证者应计算出相同的状态哈希
├─ 投票时包含状态哈希
├─ 防止非确定性执行导致的分叉
└─ 客户端可用 QC 验证读取的状态
```

**投票包含**:
- 区块哈希（交易顺序的承诺）
- 状态认证器（执行结果的承诺）
- 验证者签名

#### 为什么所有验证者都要执行？

从 `consensus/README.md:23` 的说明：

> "A validator receives the proposed block and checks their voting rules to determine if it should vote for certifying this block. **If the validator intends to vote for this block, it executes the block's transactions speculatively and without external effect.** This results in the computation of an authenticator for the database that results from the execution of the block."

**核心原因**（`consensus/README.md:31`）：

> "We make the protocol more resistant to non-determinism bugs, by having validators collectively sign the resulting state of a block rather than just the sequence of transactions."

**优势对比**：

| 方面 | 传统 BFT（只对交易顺序投票） | Aptos BFT（对执行结果投票） |
|------|------------------------|----------------------|
| 非确定性执行 | ❌ 可能导致分叉 | ✅ 提前发现并拒绝 |
| 状态验证 | ❌ 需要额外机制 | ✅ QC 直接验证状态 |
| 执行错误 | ❌ 提交后才发现 | ✅ 投票前就发现 |
| 客户端读取 | ❌ 需要信任单个节点 | ✅ 可用 QC 验证 |

#### 性能影响和优化

**潜在问题**：所有验证者都执行，计算量增加

**Aptos 的优化**：

1. **BlockSTM 并行执行**
   - 使用多线程并行执行交易
   - 自动依赖检测和冲突解决
   - 利用多核 CPU

2. **管道化处理**
   ```
   Round N:   执行 → 投票 → 等待 QC
   Round N+1:       执行 → 投票 → 等待 QC
   Round N+2:             执行 → 投票 → 等待 QC
   ```
   不同区块的阶段可以并行进行

3. **推测执行**
   - 不等提交，立即执行下一个区块
   - 减少延迟

4. **高性能硬件**
   - 验证者通常配备强大的硬件
   - 多核 CPU、大内存、高速存储

#### 执行失败处理

```
验证者执行交易失败的情况：
├─ Gas 不足
├─ 交易执行错误
├─ 状态冲突
└─ VM 错误

处理方式：
├─ 验证者拒绝投票给该区块
├─ 该区块无法获得 2f+1 投票
├─ 无法形成 QC
└─ 该区块被丢弃，进入下一轮
```

#### 与其他区块链对比

**以太坊（PoW/PoS）**：
```
矿工/提议者：执行交易 → 提议区块
其他节点：   接收区块 → 验证交易 → 同步状态
```
问题：执行和验证是异步的，可能产生分叉

**Aptos（AptosBFT）**：
```
所有验证者：并行执行 → 对结果投票 → 形成 QC
```
优势：执行结果在投票前就达成共识

**关键文件路径**:
- `consensus/src/round_manager.rs:1344-1505` - 投票和执行入口
- `consensus/src/block_storage/block_store.rs:413-517` - 区块插入和执行
- `aptos-move/aptos-vm/src/aptos_vm.rs:2778-2927` - 单交易执行
- `aptos-move/aptos-vm/src/aptos_vm.rs:1920-2055` - 用户交易实现
- `aptos-move/block-executor/src/executor.rs:1669-2610` - 并行执行
- `aptos-move/aptos-vm/src/block_executor/vm_wrapper.rs:45-114` - 执行器适配器
- `aptos-move/aptos-vm/src/move_vm_ext/session/mod.rs:108-139` - Session 执行
- `consensus/README.md:22-31` - 共识协议说明

---

## 阶段 6：共识层处理

### 6.1 提议处理
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:688-727 - process_proposal_msg()
    ├─ 接收提议并同步到正确的轮次
    └─ 调用 process_proposal()
    ↓
round_manager.rs:1073-1172+ - process_proposal()
    ├─ 验证提议者合法性 (line 1157-1162)
    ├─ 验证区块大小和交易计数 (line 1128-1155)
    └─ 应用交易过滤规则 (line 1164-1172)
```

### 6.2 区块存储
**文件**: `consensus/src/block_storage/block_store.rs`

```
block_store.rs:413-449 - insert_block()
    ├─ 添加区块到内存树
    └─ 维护父子关系
```

### 6.3 投票处理
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:1659-1678 - process_vote_msg()
    ↓
round_manager.rs:1684-1734 - process_vote()
    ↓
round_manager.rs:1736-1815+ - process_vote_reception_result()
```

### 6.4 QC（Quorum Certificate）聚合
**文件**: `consensus/src/pending_votes.rs`

```
pending_votes.rs - PendingVotes::insert_vote()
    ├─ 添加投票到集合
    ├─ 聚合签名
    └─ 当收集到 2f+1 投票时形成 QC
    ↓
返回 VoteReceptionResult::NewQuorumCertificate
```

### 6.5 证书处理和新轮次
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:1055-1065 - process_certificates()
    ├─ 检测轮次推进
    └─ 调用 round_state.process_certificates()
    ↓
liveness/round_state.rs:246-292 - process_certificates()
    └─ 生成 NewRoundEvent
    ↓
round_manager.rs:300-476 - process_new_round_event()
    └─ 如果是提议者则触发新提议
```

**关键文件路径**:
- `consensus/src/round_manager.rs:688-1172` - 提议处理
- `consensus/src/round_manager.rs:1659-1815` - 投票处理
- `consensus/src/pending_votes.rs` - 投票聚合
- `consensus/src/block_storage/block_store.rs:413-449` - 区块存储
- `consensus/consensus-types/src/quorum_cert.rs:18-107` - QC 结构

---

## 阶段 7：区块最终确定（3-Chain 提交）

### 7.1 最终性检测
**文件**: `consensus/src/block_storage/block_store.rs`

Aptos 使用 **3-chain 提交规则**：
- 当一个区块有 2 个已认证的后继区块时，该区块被提交

```
block_store.rs:313-351 - send_for_execution()
    ├─ 确保区块比 ordered_root 更新 (line 323-326)
    ├─ 获取从 ordered_root 到要提交区块的路径 (line 328-330)
    ├─ 更新 ordered_root (line 339)
    ├─ 插入 ordered certificate (line 342)
    └─ 发送区块到执行客户端以排序和提交 (line 345-348)
```

### 7.2 执行管道
**文件**: `consensus/src/pipeline/pipeline_builder.rs`

```
pipeline_builder.rs 关键阶段:
    ├─ prepare (准备交易)
    ├─ execute (执行交易)
    ├─ ledger_update (更新账本状态)
    ├─ pre_commit (预提交到存储)
    └─ commit_ledger (最终提交)
```

**关键文件路径**:
- `consensus/src/block_storage/block_store.rs:313-351` - 最终性检测
- `consensus/src/pipeline/pipeline_builder.rs:119-220` - 执行管道
- `consensus/src/state_computer.rs:52-265` - 执行代理

---

## 阶段 8：写入本地账本

### 8.1 账本更新
**文件**: `consensus/src/pipeline/pipeline_builder.rs`

```
pipeline_builder.rs:815-862 - ledger_update()
    └─ 调用 executor.ledger_update(block_id, parent_id)
    ├─ 计算执行后的状态
    ├─ 生成 TransactionInfo（包含累加器哈希）
    └─ 创建状态检查点
```

### 8.2 预提交
**文件**: `execution/executor/src/block_executor/mod.rs`

```
block_executor/mod.rs:132-140 - pre_commit_block()
    ↓
execution/executor/src/workflow/do_ledger_update.rs:24-54
    ├─ 计算事件和写集哈希 (line 34)
    └─ 创建交易累加器 (line 45-46)
    ↓
storage/aptosdb/src/db/aptosdb_writer.rs:44-76 - pre_commit_ledger()
    └─ 调用 calculate_and_commit_ledger_and_state_kv()
```

### 8.3 多线程数据库提交
**文件**: `storage/aptosdb/src/db/aptosdb_writer.rs`

```
aptosdb_writer.rs:263-322 - calculate_and_commit_ledger_and_state_kv()
并行提交:
    ├─ 事件数据库 (line 277-283)
    ├─ 写集 (line 285-288) → write_set_db.rs:113-146
    ├─ 交易数据 (line 291-298) → transaction_db.rs:85-126
    ├─ 辅助信息 (line 300-305)
    ├─ 状态 KV 更新 (line 306-309)
    └─ 交易信息和累加器 (line 311-317)
```

### 8.4 最终提交
**文件**: `storage/aptosdb/src/db/aptosdb_writer.rs`

```
aptosdb_writer.rs:78-112 - commit_ledger()
    ├─ 获取并检查提交范围 (line 95)
    ├─ 验证并写入 LedgerInfo (line 100)
    └─ 执行后提交操作 (line 110)
    ↓
aptosdb_writer.rs:540-601 - check_and_put_ledger_info()
    ├─ 验证版本匹配 (line 550-554)
    ├─ 验证交易累加器根哈希 (line 557-569)
    ├─ 验证 epoch 连续性 (line 572-582)
    ├─ 确保在 epoch 结束时持久化状态检查点 (line 585-594)
    └─ 写入 LedgerInfo 到元数据数据库 (line 599)
```

### 8.5 后提交操作
**文件**: `storage/aptosdb/src/db/aptosdb_writer.rs`

```
aptosdb_writer.rs:603-672 - post_commit()
    ├─ 更新指标并通知订阅者 (line 616-624)
    ├─ 激活修剪器清理旧数据 (line 628-632)
    ├─ 触发索引器索引新数据 (line 636-658)
    └─ 更新内存中的 LedgerInfo 缓存 (line 662-669)
```

**关键文件路径**:
- `consensus/src/pipeline/pipeline_builder.rs:815-1044` - 管道阶段
- `execution/executor/src/block_executor/mod.rs:116-150` - 执行器接口
- `storage/aptosdb/src/db/aptosdb_writer.rs:44-672` - 数据库写入
- `storage/aptosdb/src/ledger_db/transaction_accumulator_db.rs:108-126` - 累加器
- `storage/aptosdb/src/ledger_db/write_set_db.rs:113-146` - 写集存储
- `storage/aptosdb/src/ledger_db/transaction_db.rs:85-126` - 交易存储

---

## 核心数据结构总结

| 组件 | 数据结构 | 位置 |
|------|----------|------|
| 交易 | SignedTransaction | types/src/transaction/ |
| 区块 | Block, BlockData | consensus/consensus-types/src/block.rs |
| 负载 | Payload (DirectMempool/InQuorumStore) | consensus/consensus-types/src/common.rs:210 |
| 批次信息 | BatchInfo | consensus/consensus-types/src/proof_of_store.rs:25 |
| 批次证明 | ProofOfStore | consensus/consensus-types/src/proof_of_store.rs:320 |
| QC | QuorumCert | consensus/consensus-types/src/quorum_cert.rs |
| 执行输出 | TransactionOutput | types/src/transaction/transaction_output.rs |
| 状态 | WriteSet | types/src/write_set.rs |
| 账本信息 | LedgerInfoWithSignatures | types/src/ledger_info.rs |
| 交易信息 | TransactionInfo | types/src/transaction/transaction_info.rs |

---

## 完整时序图

```
时间轴 →

客户端
  |
  | POST /v1/transactions
  ↓
REST API (api/src/transactions.rs:471)
  |
  | MempoolClientRequest
  ↓
Mempool Coordinator (mempool/src/shared_mempool/coordinator.rs:57)
  |
  | 验证 + 存储
  ↓
Core Mempool (mempool/src/core_mempool/mempool.rs:289)
  |
  | [持续后台运行 - Quorum Store 模式]
  ↓
BatchGenerator 定时拉取交易 (quorum_store/batch_generator.rs:78)
  ├─ 创建 Batch + BatchInfo
  └─ 广播 SignedBatchInfo
  ↓
其他验证者接收批次
  ├─ BatchCoordinator 存储 (quorum_store/batch_coordinator.rs)
  └─ 签名并发送给 ProofCoordinator
  ↓
ProofCoordinator 聚合签名 (quorum_store/proof_coordinator.rs)
  ├─ 收集 2f+1 签名
  └─ 创建并广播 ProofOfStore
  |
  | [等待下一轮提议]
  ↓
提议者被选中 (consensus/src/round_manager.rs:387)
  |
  | 生成提议
  ↓
从 ProofManager/Mempool 拉取 (proposal_generator.rs:497)
  ├─ Quorum Store: 拉取 ProofOfStore（小数据）
  └─ Direct Mempool: 拉取完整交易（大数据）
  |
  | BlockData + 签名
  ↓
广播提议 (consensus/src/network.rs:404)
  |
  | 所有验证者接收（Quorum Store 模式带宽节省显著）
  ↓
【如果是 Quorum Store】从 BatchStore 获取完整交易
  ↓
并行执行交易 (aptos-move/block-executor/src/executor.rs:1669)
  |
  | Move VM 执行
  ↓
执行完成 → 投票 (consensus/src/round_manager.rs:1684)
  |
  | 收集 2f+1 投票
  ↓
形成 QC (consensus/src/pending_votes.rs)
  |
  | 3-chain 检查
  ↓
区块最终确定 (consensus/src/block_storage/block_store.rs:313)
  |
  | 发送到执行管道
  ↓
Ledger Update (consensus/src/pipeline/pipeline_builder.rs:815)
  |
  | 计算状态和累加器
  ↓
Pre-commit (execution/executor/src/block_executor/mod.rs:132)
  |
  | 写入数据库缓冲区
  ↓
Commit Ledger (storage/aptosdb/src/db/aptosdb_writer.rs:78)
  |
  | 原子提交到 RocksDB
  ↓
Post-commit (storage/aptosdb/src/db/aptosdb_writer.rs:603)
  |
  | 通知 + 修剪 + 索引
  |
  | 【Quorum Store】通知清理已提交批次
  ↓
交易永久存储 ✓
```

---

## 关键设计特性

### 1. Quorum Store（交易传播优化）
- **解耦共识和数据传播**：批次提前分发，区块只包含引用
- **网络带宽节省**：100-1000 倍带宽效率提升
- **拜占庭容错**：ProofOfStore = 2f+1 签名确保批次可用性
- **动态背压控制**：根据系统负载调整批次生成速率
- **两种模式**：Quorum Store（高吞吐）/ Direct Mempool（低延迟）

### 2. 并行执行（BlockSTM）
- 使用 MVHashMap 进行版本化状态跟踪
- 自动依赖检测和重新执行
- 回退到串行执行机制

### 3. 背压机制
- 链健康回退（低验证者参与度）
- 管道背压（待处理区块）
- 执行背压（慢区块执行时间）
- Quorum Store 背压（待处理批次和交易数量）

### 4. 3-Chain 提交规则
- 区块 B 在有 2 个已认证后继时提交
- 提供拜占庭容错的最终性保证

### 5. 原子性保证
- 使用 RocksDB 批量写入确保一致性
- 预提交 + 提交两阶段写入
- 事务累加器用于加密证明

### 6. 性能优化
- 多线程并行数据库写入
- 模块缓存以加快执行
- Gas 价格优先级队列
- 推测执行和验证
- Quorum Store 批次预分发

---

## 关键模块索引

### API 层
- `api/src/transactions.rs` - REST API 端点
- `api/src/context.rs` - API 上下文和 Mempool 通信

### Mempool
- `mempool/src/shared_mempool/coordinator.rs` - 主协调器
- `mempool/src/shared_mempool/tasks.rs` - 交易处理任务
- `mempool/src/core_mempool/mempool.rs` - 核心 Mempool 逻辑
- `mempool/src/core_mempool/transaction_store.rs` - 交易存储

### Quorum Store
- `consensus/src/quorum_store/batch_generator.rs` - 批次生成
- `consensus/src/quorum_store/batch_coordinator.rs` - 批次接收协调
- `consensus/src/quorum_store/batch_store.rs` - 批次存储
- `consensus/src/quorum_store/proof_coordinator.rs` - 证明聚合
- `consensus/src/quorum_store/proof_manager.rs` - 证明管理
- `consensus/src/quorum_store/quorum_store_coordinator.rs` - 总协调器
- `consensus/consensus-types/src/proof_of_store.rs` - 批次证明数据结构

### 共识
- `consensus/src/round_manager.rs` - 共识状态机
- `consensus/src/liveness/proposal_generator.rs` - 提议生成
- `consensus/src/block_storage/block_store.rs` - 区块存储
- `consensus/src/pending_votes.rs` - 投票聚合
- `consensus/src/pipeline/pipeline_builder.rs` - 执行管道

### 执行
- `aptos-move/aptos-vm/src/aptos_vm.rs` - AptosVM 主实现
- `aptos-move/block-executor/src/executor.rs` - BlockSTM 并行执行器
- `aptos-move/aptos-vm/src/block_executor/vm_wrapper.rs` - VM 适配器
- `execution/executor/src/block_executor/mod.rs` - 区块执行器

### 存储
- `storage/aptosdb/src/db/aptosdb_writer.rs` - 数据库写入
- `storage/aptosdb/src/ledger_db/transaction_db.rs` - 交易存储
- `storage/aptosdb/src/ledger_db/write_set_db.rs` - 写集存储
- `storage/aptosdb/src/ledger_db/transaction_accumulator_db.rs` - 累加器

---

## 参考资源

- [Aptos 白皮书](https://aptos.dev/papers/aptos-whitepaper)
- [BlockSTM 论文](https://arxiv.org/abs/2203.06871)
- [Aptos 开发者文档](https://aptos.dev/)
- [共识机制详解](consensus/README.md)
