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
[3] 区块提议者从 Mempool 选择交易 (consensus/)
    ↓
[4] Move VM 执行交易 (aptos-move/aptos-vm/)
    ↓
[5] 共识投票和 QC 形成 (consensus/src/round_manager.rs)
    ↓
[6] 区块最终确定 (3-chain 提交)
    ↓
[7] 写入本地账本 (storage/aptosdb/)
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

## 阶段 3：区块生成和交易选择

### 3.1 区块提议触发
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:387-475 - on_new_round()
    ├─ 检查是否是当前轮次的提议者 (line 433)
    └─ 生成并发送提议 (line 450-476)
    ↓
round_manager.rs:478-511 - generate_and_send_proposal()
```

### 3.2 从 Mempool 选择交易
**文件**: `consensus/src/liveness/proposal_generator.rs`

```
proposal_generator.rs:497-557 - generate_proposal()
    ↓
proposal_generator.rs:559-687 - generate_proposal_inner()
    ├─ 获取父区块 (line 577-578)
    ├─ 计算最大区块大小（含背压）(line 606-614)
    └─ 从 PayloadClient 拉取交易 (line 653-673)
```

### 3.3 Mempool 批量获取
**文件**: `mempool/src/core_mempool/mempool.rs`

```
mempool.rs:426-550 - get_batch()
    ├─ 按 gas 价格优先级迭代 (line 450)
    ├─ 遵守序列号顺序 (line 460-498)
    ├─ 过滤已排除的交易 (line 455-457)
    └─ 累积字节直到达到限制 (line 521-529)
```

### 3.4 区块数据构建
**文件**: `consensus/src/liveness/proposal_generator.rs`

```
proposal_generator.rs:535-554 - 构建 BlockData
    └─ 创建带有交易负载的提议
    ↓
round_manager.rs:630-654 - generate_proposal()
    ├─ 使用 SafetyRules 签名 (line 641)
    └─ 包装为 ProposalMsg (line 653)
    ↓
network.rs:404-409 - broadcast_proposal()
    └─ 广播到所有验证者
```

**关键文件路径**:
- `consensus/src/round_manager.rs:387-511` - 提议生成
- `consensus/src/liveness/proposal_generator.rs:497-687` - 生成逻辑
- `mempool/src/core_mempool/mempool.rs:426-550` - 交易选择
- `consensus/src/quorum_store/utils.rs:97-148` - Mempool 代理
- `consensus/src/network.rs:404-409` - 网络广播

---

## 阶段 4：Move VM 执行交易

### 4.1 区块执行入口
**文件**: `aptos-move/aptos-vm/src/aptos_vm.rs`

```
aptos_vm.rs:2948-2995 - AptosVMBlockExecutor::execute_block_with_config()
    ↓
block_executor/mod.rs:584-605 - execute_block()
    └─ 使用共享的 rayon 线程池
```

### 4.2 并行执行引擎
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

### 4.3 单个交易执行
**文件**: `aptos-move/aptos-vm/src/block_executor/vm_wrapper.rs`

```
vm_wrapper.rs:45-114 - AptosExecutorTask::execute_transaction()
    ├─ 从状态视图创建解析器
    └─ 调用 vm.execute_single_transaction()
    ↓
aptos_vm.rs:2778-2927 - AptosVM::execute_single_transaction()
    └─ 根据交易类型分发
```

### 4.4 用户交易执行
**文件**: `aptos-move/aptos-vm/src/aptos_vm.rs`

```
aptos_vm.rs:2152-2174 - execute_user_transaction()
    ↓
aptos_vm.rs:1920-2055 - execute_user_transaction_impl()
    ├─ Prologue: 验证签名和账户状态
    ├─ Payload: 执行 Move 代码
    └─ Epilogue: 处理 gas 和费用
```

### 4.5 Move 代码执行
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

## 阶段 5：共识层处理

### 5.1 提议处理
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

### 5.2 区块存储
**文件**: `consensus/src/block_storage/block_store.rs`

```
block_store.rs:413-449 - insert_block()
    ├─ 添加区块到内存树
    └─ 维护父子关系
```

### 5.3 投票处理
**文件**: `consensus/src/round_manager.rs`

```
round_manager.rs:1659-1678 - process_vote_msg()
    ↓
round_manager.rs:1684-1734 - process_vote()
    ↓
round_manager.rs:1736-1815+ - process_vote_reception_result()
```

### 5.4 QC（Quorum Certificate）聚合
**文件**: `consensus/src/pending_votes.rs`

```
pending_votes.rs - PendingVotes::insert_vote()
    ├─ 添加投票到集合
    ├─ 聚合签名
    └─ 当收集到 2f+1 投票时形成 QC
    ↓
返回 VoteReceptionResult::NewQuorumCertificate
```

### 5.5 证书处理和新轮次
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

## 阶段 6：区块最终确定（3-Chain 提交）

### 6.1 最终性检测
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

### 6.2 执行管道
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

## 阶段 7：写入本地账本

### 7.1 账本更新
**文件**: `consensus/src/pipeline/pipeline_builder.rs`

```
pipeline_builder.rs:815-862 - ledger_update()
    └─ 调用 executor.ledger_update(block_id, parent_id)
    ├─ 计算执行后的状态
    ├─ 生成 TransactionInfo（包含累加器哈希）
    └─ 创建状态检查点
```

### 7.2 预提交
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

### 7.3 多线程数据库提交
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

### 7.4 最终提交
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

### 7.5 后提交操作
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
  | [等待下一轮]
  ↓
提议者被选中 (consensus/src/round_manager.rs:387)
  |
  | 生成提议
  ↓
从 Mempool 拉取交易 (consensus/src/liveness/proposal_generator.rs:497)
  |
  | BlockData + 签名
  ↓
广播提议 (consensus/src/network.rs:404)
  |
  | 所有验证者接收
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
  ↓
交易永久存储 ✓
```

---

## 关键设计特性

### 1. 并行执行（BlockSTM）
- 使用 MVHashMap 进行版本化状态跟踪
- 自动依赖检测和重新执行
- 回退到串行执行机制

### 2. 背压机制
- 链健康回退（低验证者参与度）
- 管道背压（待处理区块）
- 执行背压（慢区块执行时间）

### 3. 3-Chain 提交规则
- 区块 B 在有 2 个已认证后继时提交
- 提供拜占庭容错的最终性保证

### 4. 原子性保证
- 使用 RocksDB 批量写入确保一致性
- 预提交 + 提交两阶段写入
- 事务累加器用于加密证明

### 5. 性能优化
- 多线程并行数据库写入
- 模块缓存以加快执行
- Gas 价格优先级队列
- 推测执行和验证

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
