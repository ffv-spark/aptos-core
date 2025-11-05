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

**关键文件路径**:
- `mempool/src/shared_mempool/coordinator.rs:57-135` - 主事件循环
- `mempool/src/shared_mempool/tasks.rs:305-546` - 交易处理
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

### 3.9 关键文件路径

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

> **注意**: 如果区块包含 ProofOfStore，验证者先从本地 BatchStore 获取完整交易，然后执行。

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

**关键文件路径**:
- `aptos-move/aptos-vm/src/aptos_vm.rs:2778-2927` - 单交易执行
- `aptos-move/aptos-vm/src/aptos_vm.rs:1920-2055` - 用户交易实现
- `aptos-move/block-executor/src/executor.rs:1669-2610` - 并行执行
- `aptos-move/aptos-vm/src/block_executor/vm_wrapper.rs:45-114` - 执行器适配器
- `aptos-move/aptos-vm/src/move_vm_ext/session/mod.rs:108-139` - Session 执行

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
