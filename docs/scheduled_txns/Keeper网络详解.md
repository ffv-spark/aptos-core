# Keeper 网络详解

## 1. 什么是 Keeper？

### 1.1 基本概念

**Keeper 是链下的自动化执行节点/机器人，负责监控区块链状态并在满足条件时提交交易。**

```
简单类比：
┌─────────────────────────────────────────┐
│  传统互联网                              │
│  Cron Job / 定时任务服务                 │
│  - 服务器上运行的后台程序                │
│  - 监控时间或条件                        │
│  - 到时自动执行任务                      │
└─────────────────────────────────────────┘
                  ↓ 对应
┌─────────────────────────────────────────┐
│  区块链世界                              │
│  Keeper / Bot / Relayer                 │
│  - 链下运行的程序                        │
│  - 监控链上状态或时间                    │
│  - 满足条件时提交链上交易                │
└─────────────────────────────────────────┘
```

### 1.2 Keeper 的工作原理

#### 架构图

```
┌──────────────────────────────────────────────────────┐
│                   用户层                              │
│  用户钱包 → 注册任务/意图 → 智能合约                  │
└────────────────────┬─────────────────────────────────┘
                     │ 链上记录
                     ↓
┌──────────────────────────────────────────────────────┐
│                 区块链层                              │
│  智能合约存储：                                       │
│  - 任务ID                                            │
│  - 执行条件（时间、价格、状态等）                     │
│  - 执行内容的哈希                                    │
│  - 用户签名/授权证明                                  │
└────────────────────┬─────────────────────────────────┘
                     │ Keeper 监控
                     ↓
┌──────────────────────────────────────────────────────┐
│                 Keeper 层（链下）                     │
│                                                      │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐          │
│  │ Keeper 1 │  │ Keeper 2 │  │ Keeper 3 │ ...      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘          │
│       │             │             │                 │
│       └─────────────┼─────────────┘                 │
│                     │                               │
│       1. 监控链上状态                                │
│       2. 检查执行条件                                │
│       3. 条件满足 → 构造交易                         │
│       4. 提交到区块链                                │
└────────────────────┬─────────────────────────────────┘
                     │ 提交交易
                     ↓
┌──────────────────────────────────────────────────────┐
│                 区块链层                              │
│  智能合约验证：                                       │
│  1. 验证执行条件确实满足                              │
│  2. 验证用户授权有效                                  │
│  3. 执行用户逻辑                                      │
│  4. 奖励 Keeper                                      │
└──────────────────────────────────────────────────────┘
```

### 1.3 实际例子

#### 例子1：定时转账

```typescript
// 链下 Keeper 代码
class TransferKeeper {
  async monitor() {
    // 1. 查询链上所有待执行的定时转账
    const pendingTasks = await contract.getPendingTransfers();

    // 2. 检查哪些任务已到执行时间
    const readyTasks = pendingTasks.filter(task =>
      Date.now() >= task.executeAt
    );

    // 3. 为每个就绪任务构造并提交交易
    for (const task of readyTasks) {
      try {
        // 构造交易（使用用户预签名或链上授权）
        const tx = await this.buildExecutionTx(task);

        // 提交到区块链
        await this.submitTx(tx);

        // 如果成功，Keeper 会获得奖励
      } catch (error) {
        console.log(`Task ${task.id} failed: ${error}`);
      }
    }
  }

  // 持续运行
  async run() {
    while (true) {
      await this.monitor();
      await sleep(1000); // 每秒检查一次
    }
  }
}
```

```move
// 链上智能合约
module keeper_scheduler {
    struct TransferTask has store {
        from: address,
        to: address,
        amount: u64,
        execute_at: u64,
        executed: bool,
    }

    struct TaskRegistry has key {
        tasks: Table<u64, TransferTask>,
        next_id: u64,
    }

    // 用户注册任务
    public fun register_transfer(
        sender: &signer,
        to: address,
        amount: u64,
        execute_at: u64
    ): u64 {
        let registry = borrow_global_mut<TaskRegistry>(@keeper_scheduler);
        let task_id = registry.next_id;

        // 只存储元数据（80 bytes左右）
        table::add(&mut registry.tasks, task_id, TransferTask {
            from: signer::address_of(sender),
            to,
            amount,
            execute_at,
            executed: false,
        });

        registry.next_id = task_id + 1;
        task_id
    }

    // Keeper 执行（使用用户的真实签名交易）
    public entry fun execute_transfer(
        sender: &signer,  // 用户的签名
        task_id: u64
    ) acquires TaskRegistry {
        let registry = borrow_global_mut<TaskRegistry>(@keeper_scheduler);
        let task = table::borrow_mut(&mut registry.tasks, task_id);

        // 验证
        assert!(signer::address_of(sender) == task.from, E_NOT_AUTHORIZED);
        assert!(timestamp::now_seconds() >= task.execute_at, E_TOO_EARLY);
        assert!(!task.executed, E_ALREADY_EXECUTED);

        // 执行转账
        coin::transfer<AptosCoin>(sender, task.to, task.amount);

        // 标记已执行
        task.executed = true;

        // 奖励 Keeper（从任务押金中扣除）
        // reward_keeper(tx_sender);
    }
}
```

#### 工作流程

```
时间轴：
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

T0: 用户注册任务
    用户：调用 register_transfer(to=Bob, amount=100, execute_at=T5)
    链上：存储任务记录（80 bytes）

T1-T4: 等待中
    Keeper：每秒查询 getPendingTransfers()
    Keeper：发现任务但 now < execute_at，继续等待

T5: 时间到达
    Keeper：发现 now >= execute_at
    Keeper：通知用户"该签名执行了"
    用户：签署执行交易
    Keeper：提交用户签名的交易到链上
    链上：验证时间 ✓，验证签名 ✓，执行转账
    链上：奖励 Keeper 一小笔费用

T6: 完成
    链上：标记任务已执行
    Keeper：停止监控此任务
```

### 1.4 Keeper 的关键特性

#### 去中心化

```
多个 Keeper 竞争执行：
┌──────────────────────────────────────┐
│  任务就绪                             │
└──────────────┬───────────────────────┘
               │
      ┌────────┼────────┐
      ↓        ↓        ↓
┌─────────┐ ┌─────────┐ ┌─────────┐
│Keeper 1 │ │Keeper 2 │ │Keeper 3 │
│抢先执行 │ │同时检测 │ │同时检测 │
└────┬────┘ └────┬────┘ └────┬────┘
     │           │           │
     └─────┬─────┴──────┬────┘
           ↓            ↓
      提交交易1     提交交易2
           │            │
           ↓            ↓
      ┌────────────────────┐
      │   区块链验证        │
      │   - 第一个成功 ✓    │
      │   - 其他失败 ✗      │
      │     (已执行)        │
      └────────────────────┘

结果：
- 多个 Keeper 保证可用性
- 竞争保证及时性
- 链上验证保证正确性
- First-come-first-served
```

#### 经济激励

```
Keeper 的收益模型：

成本：
- 服务器运行成本: $50-200/月
- Gas 费用: 每笔交易需要支付 Gas
- 开发和维护: 初期投入

收益：
- 执行奖励: 每次成功执行获得固定奖励
- Gas 补偿: 用户补偿 Keeper 的 Gas 支出
- 优先权: 某些协议给予优先执行权

示例：
任务执行奖励 = 0.01 APT
每天执行 1000 个任务 = 10 APT
月收入 = 300 APT ≈ $2100 (假设 APT=$7)
月成本 = $200 (服务器 + Gas)
月净利 = $1900

激励相容！
```

#### 信任模型

```
用户不需要信任 Keeper：

传统中心化定时任务：
┌─────────────────────────────────┐
│  用户                            │
│  ↓ 必须信任                      │
│  定时服务提供商                  │
│  - 会按时执行？                  │
│  - 不会作恶？                    │
│  - 不会泄露私钥？                │
└─────────────────────────────────┘

Keeper 模式：
┌─────────────────────────────────┐
│  用户                            │
│  ↓ 只需信任链上代码              │
│  智能合约                        │
│  - 代码公开可审计                │
│  - 执行条件链上验证              │
│  - 用户保留签名权                │
│  ↓                              │
│  Keeper（无需信任）              │
│  - 只是个触发器                  │
│  - 不持有用户私钥                │
│  - 不能篡改执行逻辑              │
└─────────────────────────────────┘
```

## 2. 主流 Keeper 网络

### 2.1 Chainlink Keepers (Automation)

```
特点：
- 最成熟的 Keeper 网络
- 去中心化节点网络
- 支持多种执行条件
- 链上注册和管理

工作流程：
1. 用户在 Chainlink Registry 注册 Upkeep
2. Chainlink 节点监控条件
3. 条件满足时，节点执行 performUpkeep()
4. 从用户的 LINK 余额中扣除费用

使用示例：
contract MyContract {
    // Chainlink 会定期调用这个函数
    function checkUpkeep(bytes calldata checkData)
        external view returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp > lastUpdate + interval);
    }

    // 如果 checkUpkeep 返回 true，执行这个
    function performUpkeep(bytes calldata performData) external {
        // 执行定时任务
        doSomething();
    }
}
```

### 2.2 Gelato Network

```
特点：
- 自动化交易执行
- 支持多链
- 灵活的定价模型
- 简单易用的 SDK

工作流程：
1. 用户通过 Gelato 智能合约注册任务
2. Gelato Executors 监控
3. 执行并收取费用

使用示例：
// 用户合约
contract MyDeFi {
    function harvest() external {
        require(msg.sender == gelatoExecutor);
        // 执行收割逻辑
    }
}

// TypeScript SDK
const gelato = new GelatoOps(chainId);
await gelato.createTask({
    execAddress: myContractAddress,
    execSelector: "harvest()",
    interval: 60 * 60 * 24, // 每天执行
});
```

### 2.3 Keep3r Network

```
特点：
- 由 Yearn Finance 创始人创建
- 面向 DeFi 的 Keeper 网络
- 声誉系统
- 去中心化治理

工作流程：
1. 协议注册需要执行的任务
2. Keepers 执行任务
3. 获得 KP3R token 奖励

使用示例：
contract MyKeepJob {
    // 任何 Keeper 都可以调用
    function work() external {
        require(IKeep3r(keep3r).isKeeper(msg.sender));

        // 执行工作
        doWork();

        // Keeper 获得奖励
        IKeep3r(keep3r).bondedPayment(msg.sender, amount);
    }
}
```

## 3. Keeper vs 链上定时调度

### 3.1 对比表

| 特性 | Keeper 网络 | 链上定时调度 |
|------|------------|-------------|
| **存储需求** | 链上：80 bytes/任务<br>链下：无限 | 链上：500+ bytes/任务 |
| **可扩展性** | ✅ 极强（水平扩展） | ❌ 受限（区块容量） |
| **执行延迟** | ✅ 秒级 | ⚠️ 分钟级（取决于队列） |
| **成本** | ✅ 低（竞争定价） | ❌ 高（链上存储+执行） |
| **灵活性** | ✅ 高（随时升级） | ❌ 低（需要升级合约） |
| **去中心化** | ✅ 多 Keeper 竞争 | ✅ 完全链上 |
| **安全性** | ✅ 链上验证 | ⚠️ 依赖实现 |
| **用户控制** | ✅ 保留签名权 | ⚠️ 取决于实现 |

### 3.2 实际案例

#### Aave V2 的清算机器人

```
问题：需要监控贷款健康度，及时清算

方案选择：
❌ 链上定时调度
   - 需要存储所有贷款位置
   - 每个区块都要检查
   - Gas 成本极高

✅ Keeper 网络（实际使用）
   - Keeper 监控链上状态
   - 发现可清算位置立即执行
   - 获得清算奖励

结果：
- 系统稳定运行多年
- 清算及时（秒级）
- 成本低（只在需要时执行）
```

#### Uniswap V3 的流动性管理

```
问题：用户想在价格超出范围时自动调整流动性

方案选择：
❌ 链上定时调度
   - 需要定期检查价格
   - 无法预测何时需要调整
   - 浪费大量 Gas

✅ Gelato（实际使用）
   - 监控价格和范围
   - 价格超出时自动调整
   - 用户支付执行费用

结果：
- 流动性管理自动化
- 按需执行（不浪费）
- 用户体验好
```

## 4. 如何构建自己的 Keeper

### 4.1 简单的 Keeper 实现

```typescript
import { AptosClient, AptosAccount } from "aptos";

class SimpleKeeper {
  private client: AptosClient;
  private account: AptosAccount;
  private contractAddress: string;

  constructor(nodeUrl: string, privateKey: string, contractAddress: string) {
    this.client = new AptosClient(nodeUrl);
    this.account = new AptosAccount(Buffer.from(privateKey, "hex"));
    this.contractAddress = contractAddress;
  }

  // 查询待执行任务
  async getPendingTasks(): Promise<Task[]> {
    const resource = await this.client.getAccountResource(
      this.contractAddress,
      `${this.contractAddress}::keeper_scheduler::TaskRegistry`
    );

    const tasks = resource.data.tasks;
    const currentTime = Math.floor(Date.now() / 1000);

    // 过滤出已就绪的任务
    return tasks.filter(task =>
      !task.executed &&
      task.execute_at <= currentTime
    );
  }

  // 执行任务
  async executeTask(taskId: number) {
    const payload = {
      type: "entry_function_payload",
      function: `${this.contractAddress}::keeper_scheduler::execute_task`,
      type_arguments: [],
      arguments: [taskId.toString()]
    };

    try {
      const txn = await this.client.generateTransaction(
        this.account.address(),
        payload
      );
      const signedTxn = await this.client.signTransaction(this.account, txn);
      const result = await this.client.submitTransaction(signedTxn);

      console.log(`Task ${taskId} executed: ${result.hash}`);
      return result;
    } catch (error) {
      console.error(`Failed to execute task ${taskId}:`, error);
      throw error;
    }
  }

  // 主循环
  async run() {
    console.log("Keeper started...");

    while (true) {
      try {
        // 1. 查询待执行任务
        const tasks = await this.getPendingTasks();

        if (tasks.length > 0) {
          console.log(`Found ${tasks.length} tasks to execute`);

          // 2. 执行所有就绪任务
          for (const task of tasks) {
            await this.executeTask(task.id);
            // 避免 nonce 冲突，稍微延迟
            await sleep(500);
          }
        }

        // 3. 等待一段时间再检查
        await sleep(5000); // 5秒
      } catch (error) {
        console.error("Keeper error:", error);
        await sleep(10000); // 出错后等待更长时间
      }
    }
  }
}

// 使用
const keeper = new SimpleKeeper(
  "https://fullnode.mainnet.aptoslabs.com",
  "YOUR_PRIVATE_KEY",
  "CONTRACT_ADDRESS"
);

keeper.run();
```

### 4.2 生产级 Keeper 特性

```typescript
class ProductionKeeper extends SimpleKeeper {
  // 1. 多任务并行处理
  async executeBatch(tasks: Task[]) {
    const promises = tasks.map(task => this.executeTask(task.id));
    const results = await Promise.allSettled(promises);

    // 记录成功和失败
    results.forEach((result, i) => {
      if (result.status === 'fulfilled') {
        this.metrics.recordSuccess(tasks[i].id);
      } else {
        this.metrics.recordFailure(tasks[i].id, result.reason);
      }
    });
  }

  // 2. Gas 价格优化
  async estimateGasPrice(): Promise<number> {
    // 根据网络拥堵情况动态调整
    const gasPrice = await this.client.estimateGasPrice();
    return gasPrice;
  }

  // 3. 重试机制
  async executeWithRetry(taskId: number, maxRetries = 3) {
    for (let i = 0; i < maxRetries; i++) {
      try {
        return await this.executeTask(taskId);
      } catch (error) {
        if (i === maxRetries - 1) throw error;
        await sleep(1000 * Math.pow(2, i)); // 指数退避
      }
    }
  }

  // 4. 监控和告警
  setupMonitoring() {
    setInterval(() => {
      // 检查 Keeper 健康状态
      if (this.lastExecutionTime < Date.now() - 60000) {
        this.alert("Keeper may be stuck!");
      }

      // 检查余额
      if (this.balance < MIN_BALANCE) {
        this.alert("Low balance!");
      }
    }, 30000);
  }

  // 5. 利润计算
  shouldExecute(task: Task): boolean {
    const estimatedCost = this.estimateGas() * this.gasPrice;
    const reward = task.reward;

    // 只执行有利可图的任务
    return reward > estimatedCost * 1.2; // 20% 利润率
  }
}
```

## 5. 总结

### Keeper 的优势

```
✅ 可扩展性强
   - 水平扩展（增加 Keeper 节点）
   - 不受区块容量限制
   - 可以支持百万级任务

✅ 成本低
   - 链上存储极小
   - 只在需要时执行
   - 竞争性定价

✅ 灵活性高
   - 支持复杂条件
   - 可以随时升级逻辑
   - 不需要链上升级

✅ 去中心化
   - 多个 Keeper 竞争
   - 没有单点故障
   - 经济激励保证可用性

✅ 用户控制
   - 用户保留签名权
   - 可以随时取消
   - 链上验证保证安全
```

### 为什么是最佳实践

**Keeper 网络 = 区块链的 Cron**

就像传统互联网离不开 Cron 服务一样，区块链生态也需要 Keeper 网络来处理自动化任务。它是对区块链的完美补充，而不是替代。

**关键洞察**：
- 区块链擅长：共识、存储、验证
- Keeper 擅长：监控、触发、执行
- 两者结合：去中心化的自动化系统

这就是为什么所有主流公链和 DeFi 协议都在使用 Keeper 模式，而不是尝试在链上实现所有自动化逻辑。
