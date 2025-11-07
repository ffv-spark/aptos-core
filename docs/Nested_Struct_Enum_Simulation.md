# 使用结构体嵌套模拟 Enum（最优雅方案）

> 适用于：追求代码可读性和类型清晰度的场景

## 核心思想

**将每个 variant 定义为独立的 struct，然后用 Option 包装在主 struct 中。**

这种方法相比直接使用 Option 包装基础类型有以下优势：
- ✅ **更好的类型组织**：每个 variant 的数据结构清晰
- ✅ **更易维护**：variant 字段变更只需修改对应 struct
- ✅ **更好的文档**：每个 variant struct 可以有独立的文档注释
- ✅ **未来迁移容易**：结构与 enum 更接近

---

## 方案对比

### 原始 Enum（VERSION_7+）

```move
enum Status<T: store> has store {
    Pending,
    Processing { worker_id: address, started_at: u64 },
    Completed { result: T, finished_at: u64 },
    Failed { error: vector<u8>, retry_count: u64 },
}
```

---

### 方案 A：直接 Option（之前的方案）

```move
struct Status<T: store> has store {
    tag: u8,

    // 所有字段平铺
    worker_id: Option<address>,
    started_at: Option<u64>,
    result: Option<T>,
    finished_at: Option<u64>,
    error: Option<vector<u8>>,
    retry_count: Option<u64>,
}
```

**缺点**：
- ❌ 字段平铺，不清楚哪些字段属于哪个 variant
- ❌ 添加字段时容易出错
- ❌ 难以理解每个 variant 的完整结构

---

### 方案 B：结构体嵌套（推荐）⭐

```move
/// Processing variant 的数据
struct ProcessingData has store {
    worker_id: address,
    started_at: u64,
}

/// Completed variant 的数据
struct CompletedData<T: store> has store {
    result: T,
    finished_at: u64,
}

/// Failed variant 的数据
struct FailedData has store {
    error: vector<u8>,
    retry_count: u64,
}

/// 主 Status struct
struct Status<T: store> has store {
    tag: u8,

    // 每个 variant 的数据作为一个整体
    processing: Option<ProcessingData>,
    completed: Option<CompletedData<T>>,
    failed: Option<FailedData>,
}
```

**优点**：
- ✅ **结构清晰**：每个 variant 的数据组织在一起
- ✅ **易于维护**：修改 Processing 数据只需改 ProcessingData
- ✅ **类型安全**：编译器帮助检查字段访问
- ✅ **文档友好**：可以为每个 variant struct 写文档

---

## 完整实现示例

### 1. 定义 Variant Structs

```move
module example::status_nested {
    use std::option::{Self, Option};

    // ==================== Variant Data Structures ====================

    /// Data for Processing variant
    ///
    /// Represents a task that is currently being processed.
    struct ProcessingData has store, drop {
        /// ID of the worker processing this task
        worker_id: address,
        /// Unix timestamp when processing started
        started_at: u64,
    }

    /// Data for Completed variant
    ///
    /// Represents a successfully completed task.
    struct CompletedData<T: store> has store {
        /// The result of the computation
        result: T,
        /// Unix timestamp when completed
        finished_at: u64,
    }

    /// Data for Failed variant
    ///
    /// Represents a task that failed during processing.
    struct FailedData has store, drop {
        /// Error message describing the failure
        error: vector<u8>,
        /// Number of times this task has been retried
        retry_count: u64,
    }

    // ==================== Main Status Struct ====================

    /// Variant tags
    const TAG_PENDING: u8 = 0;
    const TAG_PROCESSING: u8 = 1;
    const TAG_COMPLETED: u8 = 2;
    const TAG_FAILED: u8 = 3;

    /// Error codes
    const E_NOT_PENDING: u64 = 1;
    const E_NOT_PROCESSING: u64 = 2;
    const E_NOT_COMPLETED: u64 = 3;
    const E_NOT_FAILED: u64 = 4;
    const E_INVALID_VARIANT: u64 = 5;

    /// Task status (enum simulation using nested structs)
    struct Status<T: store> has store {
        /// Variant discriminator
        tag: u8,

        /// Data for each variant (only one will be Some)
        processing: Option<ProcessingData>,
        completed: Option<CompletedData<T>>,
        failed: Option<FailedData>,
    }

    // ==================== Constructors ====================

    /// Create a Pending status
    public fun pending<T: store>(): Status<T> {
        Status {
            tag: TAG_PENDING,
            processing: option::none(),
            completed: option::none(),
            failed: option::none(),
        }
    }

    /// Create a Processing status
    public fun processing<T: store>(
        worker_id: address,
        started_at: u64
    ): Status<T> {
        Status {
            tag: TAG_PROCESSING,
            processing: option::some(ProcessingData { worker_id, started_at }),
            completed: option::none(),
            failed: option::none(),
        }
    }

    /// Create a Completed status
    public fun completed<T: store>(
        result: T,
        finished_at: u64
    ): Status<T> {
        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(CompletedData { result, finished_at }),
            failed: option::none(),
        }
    }

    /// Create a Failed status
    public fun failed<T: store>(
        error: vector<u8>,
        retry_count: u64
    ): Status<T> {
        Status {
            tag: TAG_FAILED,
            processing: option::none(),
            completed: option::none(),
            failed: option::some(FailedData { error, retry_count }),
        }
    }

    // ==================== Variant Checks ====================

    public fun is_pending<T: store>(status: &Status<T>): bool {
        status.tag == TAG_PENDING
    }

    public fun is_processing<T: store>(status: &Status<T>): bool {
        status.tag == TAG_PROCESSING
    }

    public fun is_completed<T: store>(status: &Status<T>): bool {
        status.tag == TAG_COMPLETED
    }

    public fun is_failed<T: store>(status: &Status<T>): bool {
        status.tag == TAG_FAILED
    }

    // ==================== Accessors (返回整个 variant data) ====================

    /// Borrow Processing data
    public fun borrow_processing<T: store>(status: &Status<T>): &ProcessingData {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);
        option::borrow(&status.processing)
    }

    /// Borrow Completed data
    public fun borrow_completed<T: store>(status: &Status<T>): &CompletedData<T> {
        assert!(status.tag == TAG_COMPLETED, E_NOT_COMPLETED);
        option::borrow(&status.completed)
    }

    /// Borrow Failed data
    public fun borrow_failed<T: store>(status: &Status<T>): &FailedData {
        assert!(status.tag == TAG_FAILED, E_NOT_FAILED);
        option::borrow(&status.failed)
    }

    // ==================== Field Accessors (访问 variant 内的具体字段) ====================

    /// Get worker_id from Processing variant
    public fun processing_worker_id<T: store>(status: &Status<T>): address {
        borrow_processing(status).worker_id
    }

    /// Get started_at from Processing variant
    public fun processing_started_at<T: store>(status: &Status<T>): u64 {
        borrow_processing(status).started_at
    }

    /// Borrow result from Completed variant
    public fun completed_result<T: store>(status: &Status<T>): &T {
        &borrow_completed(status).result
    }

    /// Get finished_at from Completed variant
    public fun completed_finished_at<T: store>(status: &Status<T>): u64 {
        borrow_completed(status).finished_at
    }

    /// Get error from Failed variant
    public fun failed_error<T: store>(status: &Status<T>): vector<u8> {
        borrow_failed(status).error
    }

    /// Get retry_count from Failed variant
    public fun failed_retry_count<T: store>(status: &Status<T>): u64 {
        borrow_failed(status).retry_count
    }

    // ==================== State Transitions ====================

    /// Transition from Pending to Processing
    public fun start_processing<T: store>(
        status: &mut Status<T>,
        worker_id: address,
        started_at: u64
    ) {
        assert!(status.tag == TAG_PENDING, E_NOT_PENDING);

        status.tag = TAG_PROCESSING;
        status.processing = option::some(ProcessingData {
            worker_id,
            started_at,
        });
    }

    /// Transition from Processing to Completed
    public fun mark_completed<T: store>(
        status: &mut Status<T>,
        result: T,
        finished_at: u64
    ) {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);

        // Clear old variant data
        status.processing = option::none();

        // Set new variant data
        status.tag = TAG_COMPLETED;
        status.completed = option::some(CompletedData {
            result,
            finished_at,
        });
    }

    /// Transition from Processing to Failed
    public fun mark_failed<T: store>(
        status: &mut Status<T>,
        error: vector<u8>,
        retry_count: u64
    ) {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);

        // Clear old variant data
        status.processing = option::none();

        // Set new variant data
        status.tag = TAG_FAILED;
        status.failed = option::some(FailedData {
            error,
            retry_count,
        });
    }

    // ==================== Pattern Matching Simulation ====================

    /// Match on status variant
    public fun match<T: store, R>(
        status: &Status<T>,
        on_pending: || R,
        on_processing: |&ProcessingData| R,
        on_completed: |&CompletedData<T>| R,
        on_failed: |&FailedData| R,
    ): R {
        if (status.tag == TAG_PENDING) {
            on_pending()
        } else if (status.tag == TAG_PROCESSING) {
            on_processing(option::borrow(&status.processing))
        } else if (status.tag == TAG_COMPLETED) {
            on_completed(option::borrow(&status.completed))
        } else if (status.tag == TAG_FAILED) {
            on_failed(option::borrow(&status.failed))
        } else {
            abort E_INVALID_VARIANT
        }
    }

    // ==================== Destructors ====================

    /// Destroy Completed status and extract data
    public fun destroy_completed<T: store>(status: Status<T>): (T, u64) {
        let Status {
            tag,
            processing,
            completed,
            failed,
        } = status;

        assert!(tag == TAG_COMPLETED, E_NOT_COMPLETED);

        // Clean up other variants
        option::destroy_none(processing);
        option::destroy_none(failed);

        // Extract completed data
        let CompletedData { result, finished_at } = option::destroy_some(completed);

        (result, finished_at)
    }

    /// Destroy Failed status and extract data
    public fun destroy_failed<T: store>(status: Status<T>): (vector<u8>, u64) {
        let Status {
            tag,
            processing,
            completed,
            failed,
        } = status;

        assert!(tag == TAG_FAILED, E_NOT_FAILED);

        option::destroy_none(processing);
        option::destroy_none(completed);

        let FailedData { error, retry_count } = option::destroy_some(failed);

        (error, retry_count)
    }

    // ==================== Tests ====================

    #[test]
    fun test_status_flow_with_nested_structs() {
        use std::vector;

        // Create pending
        let status = pending<u64>();
        assert!(is_pending(&status), 0);

        // Start processing
        let worker = @0xABCD;
        let start_time = 1000;
        start_processing(&mut status, worker, start_time);

        assert!(is_processing(&status), 1);
        assert!(processing_worker_id(&status) == worker, 2);
        assert!(processing_started_at(&status) == start_time, 3);

        // Complete
        let result = 42;
        let end_time = 2000;
        mark_completed(&mut status, result, end_time);

        assert!(is_completed(&status), 4);
        assert!(*completed_result(&status) == 42, 5);
        assert!(completed_finished_at(&status) == end_time, 6);

        // Destroy
        let (res, time) = destroy_completed(status);
        assert!(res == 42, 7);
        assert!(time == end_time, 8);
    }

    #[test]
    fun test_match_with_nested_structs() {
        let status = completed<u64>(100, 5000);

        let result = match(&status,
            || 0,                                    // pending
            |_data| 1,                              // processing
            |data| data.result * 2,                 // completed
            |_data| 3                               // failed
        );

        assert!(result == 200, 0);

        let _ = destroy_completed(status);
    }

    #[test]
    fun test_accessing_nested_struct_fields() {
        let status = failed<u64>(b"network timeout", 5);

        // 方法 1：通过 variant data struct
        let failed_data = borrow_failed(&status);
        assert!(failed_data.error == b"network timeout", 0);
        assert!(failed_data.retry_count == 5, 1);

        // 方法 2：通过便捷函数
        assert!(failed_error(&status) == b"network timeout", 2);
        assert!(failed_retry_count(&status) == 5, 3);

        let (err, count) = destroy_failed(status);
        assert!(err == b"network timeout", 4);
        assert!(count == 5, 5);
    }
}
```

---

## 高级用法

### 1. 为 Variant Struct 添加方法

```move
/// ProcessingData 的辅助方法
impl ProcessingData {
    /// Calculate elapsed time
    public fun elapsed_since(data: &ProcessingData, current_time: u64): u64 {
        if (current_time >= data.started_at) {
            current_time - data.started_at
        } else {
            0
        }
    }

    /// Check if processing is taking too long
    public fun is_timeout(data: &ProcessingData, current_time: u64, timeout: u64): bool {
        Self::elapsed_since(data, current_time) > timeout
    }
}

// 使用
let processing_data = borrow_processing(&status);
if (ProcessingData::is_timeout(processing_data, now(), 3600)) {
    // Handle timeout
}
```

### 2. 嵌套更复杂的结构

```move
/// Metadata for completed tasks
struct CompletionMetadata has store, drop {
    finished_at: u64,
    duration_ms: u64,
    final_size: u64,
}

/// Completed variant with rich metadata
struct CompletedData<T: store> has store {
    result: T,
    metadata: CompletionMetadata,
}

public fun completed<T: store>(
    result: T,
    finished_at: u64,
    duration_ms: u64,
    final_size: u64
): Status<T> {
    Status {
        tag: TAG_COMPLETED,
        processing: option::none(),
        completed: option::some(CompletedData {
            result,
            metadata: CompletionMetadata {
                finished_at,
                duration_ms,
                final_size,
            }
        }),
        failed: option::none(),
    }
}
```

### 3. 共享字段的处理

如果多个 variant 共享某些字段，可以提取到外层：

```move
struct Status<T: store> has store {
    tag: u8,

    // 所有 variant 共享的字段
    task_id: u64,
    created_at: u64,

    // Variant-specific data
    processing: Option<ProcessingData>,
    completed: Option<CompletedData<T>>,
    failed: Option<FailedData>,
}
```

---

## 对比各种方案

### 内存占用对比

假设 `T = u64`：

#### 方案 A：直接 Option

```
Status<u64> {
    tag: u8,                    // 1 byte
    worker_id: Option<address>, // 33 bytes
    started_at: Option<u64>,    // 9 bytes
    result: Option<u64>,        // 9 bytes
    finished_at: Option<u64>,   // 9 bytes
    error: Option<vector<u8>>,  // 9 bytes
    retry_count: Option<u64>,   // 9 bytes
}
总计: 79 bytes
```

#### 方案 B：嵌套 Struct

```
ProcessingData {
    worker_id: address,         // 32 bytes
    started_at: u64,            // 8 bytes
}                               // = 40 bytes

CompletedData<u64> {
    result: u64,                // 8 bytes
    finished_at: u64,           // 8 bytes
}                               // = 16 bytes

FailedData {
    error: vector<u8>,          // ~8 bytes (ptr)
    retry_count: u64,           // 8 bytes
}                               // = 16 bytes

Status<u64> {
    tag: u8,                            // 1 byte
    processing: Option<ProcessingData>, // 1 + 40 = 41 bytes
    completed: Option<CompletedData>,   // 1 + 16 = 17 bytes
    failed: Option<FailedData>,         // 1 + 16 = 17 bytes
}
总计: 76 bytes
```

**结论**：嵌套 struct **略微节省内存**（76 vs 79 bytes），但差异不大。

### 代码质量对比

| 维度 | 直接 Option | 嵌套 Struct |
|------|------------|------------|
| **可读性** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **可维护性** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **类型安全** | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **扩展性** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **文档友好** | ⭐⭐ | ⭐⭐⭐⭐⭐ |
| **内存效率** | ⭐⭐⭐ | ⭐⭐⭐ |
| **实现复杂度** | ⭐⭐⭐⭐ | ⭐⭐⭐ |

---

## 真实世界例子

### 例子 1：链表节点（您的 Link 例子）

```move
/// Occupied node data
struct OccupiedData<T: store> has store {
    value: T,
}

/// Vacant node data
struct VacantData has store {
    next: u64,
}

/// Link node
struct Link<T: store> has store {
    tag: u8,  // 0 = Occupied, 1 = Vacant
    occupied: Option<OccupiedData<T>>,
    vacant: Option<VacantData>,
}

public fun occupied<T: store>(value: T): Link<T> {
    Link {
        tag: 0,
        occupied: option::some(OccupiedData { value }),
        vacant: option::none(),
    }
}

public fun vacant<T: store>(next: u64): Link<T> {
    Link {
        tag: 1,
        occupied: option::none(),
        vacant: option::some(VacantData { next }),
    }
}
```

### 例子 2：交易结果

```move
/// Success result data
struct SuccessResult has store, drop {
    output: vector<u8>,
    gas_used: u64,
    events: u64,  // event count
}

/// Error result data
struct ErrorResult has store, drop {
    error_code: u64,
    error_message: vector<u8>,
    gas_used: u64,
}

/// Transaction result
struct TxResult has store {
    tag: u8,
    success: Option<SuccessResult>,
    error: Option<ErrorResult>,
}
```

### 例子 3：复杂的订单状态

```move
struct PendingOrderData has store {
    created_at: u64,
    expires_at: u64,
}

struct ConfirmedOrderData has store {
    confirmed_at: u64,
    payment_hash: vector<u8>,
}

struct ShippedOrderData has store {
    shipped_at: u64,
    tracking_number: vector<u8>,
    carrier: vector<u8>,
}

struct DeliveredOrderData has store {
    delivered_at: u64,
    signature: vector<u8>,
}

struct CancelledOrderData has store {
    cancelled_at: u64,
    reason: vector<u8>,
    refund_amount: u64,
}

struct OrderStatus has store {
    tag: u8,
    pending: Option<PendingOrderData>,
    confirmed: Option<ConfirmedOrderData>,
    shipped: Option<ShippedOrderData>,
    delivered: Option<DeliveredOrderData>,
    cancelled: Option<CancelledOrderData>,
}
```

---

## 迁移到真正的 Enum

当升级到支持 enum 的版本时，迁移非常简单：

### 迁移前（嵌套 Struct）

```move
struct ProcessingData has store { ... }
struct CompletedData<T> has store { ... }

struct Status<T: store> has store {
    tag: u8,
    processing: Option<ProcessingData>,
    completed: Option<CompletedData<T>>,
    ...
}
```

### 迁移后（真正的 Enum）

```move
// 复用相同的 data struct！
struct ProcessingData has store { ... }
struct CompletedData<T> has store { ... }

enum Status<T: store> has store {
    Pending,
    Processing(ProcessingData),       // 直接复用
    Completed(CompletedData<T>),      // 直接复用
    Failed(FailedData),
}
```

**优势**：
- ✅ Variant data struct 可以直接复用
- ✅ 只需改主 struct 定义和构造函数
- ✅ 业务逻辑代码改动很小

---

## 最佳实践

### 1. 命名约定

```move
// ✅ 好：清晰的命名
struct ProcessingData has store { ... }
struct CompletedData has store { ... }

// ❌ 不好：模糊的命名
struct Data1 has store { ... }
struct Data2 has store { ... }
```

### 2. 为 Variant Struct 添加文档

```move
/// Data for a task that is currently being processed.
///
/// # Fields
/// * `worker_id` - The address of the worker processing this task
/// * `started_at` - Unix timestamp when processing started
/// * `progress` - Optional progress indicator (0-100)
struct ProcessingData has store {
    worker_id: address,
    started_at: u64,
    progress: Option<u8>,
}
```

### 3. 私有化内部结构

```move
// Variant structs 可以是 module-private
struct ProcessingData has store { ... }
struct CompletedData<T: store> has store { ... }

// 只暴露主 Status struct
public struct Status<T: store> has store { ... }

// 通过构造函数和访问器控制
public fun processing<T>(...): Status<T> { ... }
public fun borrow_processing<T>(...): &ProcessingData { ... }
```

### 4. 提供便捷方法

```move
// 方法 1：访问整个 variant data
public fun borrow_processing<T>(s: &Status<T>): &ProcessingData { ... }

// 方法 2：访问单个字段（更方便）
public fun processing_worker_id<T>(s: &Status<T>): address {
    borrow_processing(s).worker_id
}

// 方法 3：同时提供两种方式，让调用者选择
```

---

## 总结

### 推荐使用嵌套 Struct 的场景

✅ **强烈推荐**：
- Variant 有多个字段（≥2 个）
- 需要清晰的代码结构
- 团队协作的大型项目
- 未来可能迁移到真正的 enum

⚠️ **可选**：
- Variant 只有单个字段
- 小型项目或原型

❌ **不推荐**：
- Variant 无字段（纯标记），用简单的 tag 即可

### 最终对比

| 方案 | 适用场景 | 推荐度 |
|------|---------|--------|
| **直接 bool** | 2 个 variant，字段简单 | ⭐⭐⭐ |
| **直接 u8 + Option** | 多 variant，字段简单 | ⭐⭐⭐ |
| **嵌套 Struct** | 多 variant，字段复杂 | ⭐⭐⭐⭐⭐ |
| **真正的 Enum** | VERSION_7+ | ⭐⭐⭐⭐⭐ |

### 嵌套 Struct 的核心优势

1. **代码组织** - 每个 variant 的数据清晰分组
2. **类型安全** - 编译器帮助检查
3. **易于维护** - 修改局部化
4. **文档友好** - 每个结构可独立文档化
5. **迁移容易** - 升级到 enum 时改动小

---

**结论**：对于复杂的 enum 模拟，**嵌套 Struct 是最优雅的方案**！✨

---

*本指南提供了使用结构体嵌套模拟枚举的最佳实践。*
