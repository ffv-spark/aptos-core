# 多枚举变体转换指南（通用方案）

> 适用于：有 3 个或更多 variant 的 enum

## 原始问题

**2 个 variant**：可以用 `bool` （上一个文档）
**3+ 个 variant**：必须用 `u8` tag

---

## 通用转换模式

### 示例：复杂的 Enum

```move
// 原始 enum (4 个 variants)
enum Status<T: store> has store {
    Pending,                              // 无数据
    Processing { worker_id: address },     // 1 个字段
    Completed { result: T },               // 泛型数据
    Failed { error: vector<u8>, retry_count: u64 },  // 多个字段
}
```

---

## 推荐方案：u8 Tag + 多个 Option

### 完整实现

```move
module example::status {
    use std::option::{Self, Option};
    use std::vector;

    /// Variant tags (常量定义)
    const TAG_PENDING: u8 = 0;
    const TAG_PROCESSING: u8 = 1;
    const TAG_COMPLETED: u8 = 2;
    const TAG_FAILED: u8 = 3;

    /// Error codes
    const E_INVALID_VARIANT: u64 = 1;
    const E_NOT_PENDING: u64 = 2;
    const E_NOT_PROCESSING: u64 = 3;
    const E_NOT_COMPLETED: u64 = 4;
    const E_NOT_FAILED: u64 = 5;

    /// Status struct (替代 enum)
    struct Status<T: store> has store {
        /// Variant discriminator
        tag: u8,

        /// Data for Processing variant
        worker_id: Option<address>,

        /// Data for Completed variant
        result: Option<T>,

        /// Data for Failed variant
        error: Option<vector<u8>>,
        retry_count: Option<u64>,
    }

    // ==================== Constructors ====================

    /// Create Pending status
    public fun pending<T: store>(): Status<T> {
        Status {
            tag: TAG_PENDING,
            worker_id: option::none(),
            result: option::none(),
            error: option::none(),
            retry_count: option::none(),
        }
    }

    /// Create Processing status
    public fun processing<T: store>(worker_id: address): Status<T> {
        Status {
            tag: TAG_PROCESSING,
            worker_id: option::some(worker_id),
            result: option::none(),
            error: option::none(),
            retry_count: option::none(),
        }
    }

    /// Create Completed status
    public fun completed<T: store>(result: T): Status<T> {
        Status {
            tag: TAG_COMPLETED,
            worker_id: option::none(),
            result: option::some(result),
            error: option::none(),
            retry_count: option::none(),
        }
    }

    /// Create Failed status
    public fun failed<T: store>(error: vector<u8>, retry_count: u64): Status<T> {
        Status {
            tag: TAG_FAILED,
            worker_id: option::none(),
            result: option::none(),
            error: option::some(error),
            retry_count: option::some(retry_count),
        }
    }

    // ==================== Variant Checks ====================

    /// Check if status is Pending
    public fun is_pending<T: store>(status: &Status<T>): bool {
        status.tag == TAG_PENDING
    }

    /// Check if status is Processing
    public fun is_processing<T: store>(status: &Status<T>): bool {
        status.tag == TAG_PROCESSING
    }

    /// Check if status is Completed
    public fun is_completed<T: store>(status: &Status<T>): bool {
        status.tag == TAG_COMPLETED
    }

    /// Check if status is Failed
    public fun is_failed<T: store>(status: &Status<T>): bool {
        status.tag == TAG_FAILED
    }

    // ==================== Accessors ====================

    /// Get worker_id (Processing variant only)
    public fun get_worker_id<T: store>(status: &Status<T>): address {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);
        *option::borrow(&status.worker_id)
    }

    /// Borrow result (Completed variant only)
    public fun borrow_result<T: store>(status: &Status<T>): &T {
        assert!(status.tag == TAG_COMPLETED, E_NOT_COMPLETED);
        option::borrow(&status.result)
    }

    /// Get error message (Failed variant only)
    public fun get_error<T: store>(status: &Status<T>): vector<u8> {
        assert!(status.tag == TAG_FAILED, E_NOT_FAILED);
        *option::borrow(&status.error)
    }

    /// Get retry count (Failed variant only)
    public fun get_retry_count<T: store>(status: &Status<T>): u64 {
        assert!(status.tag == TAG_FAILED, E_NOT_FAILED);
        *option::borrow(&status.retry_count)
    }

    // ==================== Pattern Matching Helper ====================

    /// Match-like function (模拟模式匹配)
    public fun match<T: store, R>(
        status: &Status<T>,
        on_pending: || R,
        on_processing: |address| R,
        on_completed: |&T| R,
        on_failed: |vector<u8>, u64| R,
    ): R {
        if (status.tag == TAG_PENDING) {
            on_pending()
        } else if (status.tag == TAG_PROCESSING) {
            on_processing(*option::borrow(&status.worker_id))
        } else if (status.tag == TAG_COMPLETED) {
            on_completed(option::borrow(&status.result))
        } else if (status.tag == TAG_FAILED) {
            on_failed(
                *option::borrow(&status.error),
                *option::borrow(&status.retry_count)
            )
        } else {
            abort E_INVALID_VARIANT
        }
    }

    // ==================== State Transitions ====================

    /// Transition from Pending to Processing
    public fun start_processing<T: store>(
        status: &mut Status<T>,
        worker_id: address
    ) {
        assert!(status.tag == TAG_PENDING, E_NOT_PENDING);

        // Clear old data (虽然都是 none)
        // Update to Processing
        status.tag = TAG_PROCESSING;
        status.worker_id = option::some(worker_id);
    }

    /// Transition from Processing to Completed
    public fun mark_completed<T: store>(
        status: &mut Status<T>,
        result: T
    ) {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);

        // Clear Processing data
        status.worker_id = option::none();

        // Set Completed data
        status.tag = TAG_COMPLETED;
        status.result = option::some(result);
    }

    /// Transition from Processing to Failed
    public fun mark_failed<T: store>(
        status: &mut Status<T>,
        error: vector<u8>,
        retry_count: u64
    ) {
        assert!(status.tag == TAG_PROCESSING, E_NOT_PROCESSING);

        // Clear Processing data
        status.worker_id = option::none();

        // Set Failed data
        status.tag = TAG_FAILED;
        status.error = option::some(error);
        status.retry_count = option::some(retry_count);
    }

    // ==================== Destructors ====================

    /// Destroy and extract result (Completed only)
    public fun destroy_completed<T: store>(status: Status<T>): T {
        let Status {
            tag,
            worker_id,
            result,
            error,
            retry_count
        } = status;

        assert!(tag == TAG_COMPLETED, E_NOT_COMPLETED);

        // Clean up other fields
        option::destroy_none(worker_id);
        option::destroy_none(error);
        option::destroy_none(retry_count);

        // Extract result
        option::destroy_some(result)
    }

    /// Destroy Failed status and get error info
    public fun destroy_failed<T: store>(status: Status<T>): (vector<u8>, u64) {
        let Status {
            tag,
            worker_id,
            result,
            error,
            retry_count
        } = status;

        assert!(tag == TAG_FAILED, E_NOT_FAILED);

        option::destroy_none(worker_id);
        option::destroy_none(result);

        (option::destroy_some(error), option::destroy_some(retry_count))
    }

    // ==================== Tests ====================

    #[test]
    fun test_status_flow() {
        // Start as pending
        let status = pending<u64>();
        assert!(is_pending(&status), 0);

        // Start processing
        let worker = @0x123;
        start_processing(&mut status, worker);
        assert!(is_processing(&status), 1);
        assert!(get_worker_id(&status) == worker, 2);

        // Complete
        mark_completed(&mut status, 999);
        assert!(is_completed(&status), 3);
        assert!(*borrow_result(&status) == 999, 4);

        // Destroy
        let result = destroy_completed(status);
        assert!(result == 999, 5);
    }

    #[test]
    fun test_failure_path() {
        let status = pending<u64>();

        // Start and fail
        start_processing(&mut status, @0x456);
        mark_failed(&mut status, b"network error", 3);

        assert!(is_failed(&status), 0);
        assert!(get_error(&status) == b"network error", 1);
        assert!(get_retry_count(&status) == 3, 2);

        let (err, count) = destroy_failed(status);
        assert!(err == b"network error", 3);
        assert!(count == 3, 4);
    }

    #[test]
    fun test_match_function() {
        let status = completed<u64>(42);

        let result = match(&status,
            || 0,                           // pending
            |_worker| 1,                    // processing
            |result| *result * 2,           // completed
            |_err, _count| 3                // failed
        );

        assert!(result == 84, 0);

        let _ = destroy_completed(status);
    }
}
```

---

## 内存布局分析

### 原始 Enum 内存（VERSION_7+）

```
Status::Pending
  = [tag: u16]
  = 2 bytes

Status::Processing { worker_id }
  = [tag: u16][worker_id: address]
  = 2 + 32 = 34 bytes

Status::Completed { result: u64 }
  = [tag: u16][result: u64]
  = 2 + 8 = 10 bytes

Status::Failed { error, retry_count }
  = [tag: u16][error: vector<u8>][retry_count: u64]
  = 2 + (vec) + 8 ≈ 50+ bytes
```

**特点**：只占用当前 variant 的大小

### Struct 模拟内存

```
Status<u64> {
    tag: u8,                      // 1 byte
    worker_id: Option<address>,   // 1 + 32 = 33 bytes
    result: Option<u64>,          // 1 + 8 = 9 bytes
    error: Option<vector<u8>>,    // 1 + (vec ptr) ≈ 9 bytes
    retry_count: Option<u64>,     // 1 + 8 = 9 bytes
}

总计：1 + 33 + 9 + 9 + 9 = 61 bytes (固定)
```

**特点**：所有 variant 的字段都占用空间

**内存对比**：
- Pending: 2 bytes (enum) vs 61 bytes (struct) = **30.5x 浪费**
- Completed: 10 bytes (enum) vs 61 bytes (struct) = **6.1x 浪费**
- Failed: ~50 bytes (enum) vs 61 bytes (struct) = **1.2x 浪费**

---

## 优化方案：使用嵌套 Struct

如果内存是关键考虑因素，可以使用更复杂但内存高效的方案：

```move
/// 为每个 variant 定义独立的 struct
struct ProcessingData has store {
    worker_id: address,
}

struct CompletedData<T: store> has store {
    result: T,
}

struct FailedData has store {
    error: vector<u8>,
    retry_count: u64,
}

/// 主 struct
struct Status<T: store> has store {
    tag: u8,

    // 只有一个会是 Some
    processing: Option<ProcessingData>,
    completed: Option<CompletedData<T>>,
    failed: Option<FailedData>,
}

/// Constructors
public fun pending<T: store>(): Status<T> {
    Status {
        tag: 0,
        processing: option::none(),
        completed: option::none(),
        failed: option::none(),
    }
}

public fun processing<T: store>(worker_id: address): Status<T> {
    Status {
        tag: 1,
        processing: option::some(ProcessingData { worker_id }),
        completed: option::none(),
        failed: option::none(),
    }
}

public fun completed<T: store>(result: T): Status<T> {
    Status {
        tag: 2,
        processing: option::none(),
        completed: option::some(CompletedData { result }),
        failed: option::none(),
    }
}

public fun failed<T: store>(error: vector<u8>, retry_count: u64): Status<T> {
    Status {
        tag: 3,
        processing: option::none(),
        completed: option::none(),
        failed: option::some(FailedData { error, retry_count }),
    }
}
```

**内存占用**：
```
Status<u64> {
    tag: u8,                              // 1 byte
    processing: Option<ProcessingData>,   // 1 + 32 = 33 bytes
    completed: Option<CompletedData<u64>>,// 1 + 8 = 9 bytes
    failed: Option<FailedData>,           // 1 + (vec + u64) ≈ 17 bytes
}

总计：1 + 33 + 9 + 17 = 60 bytes
```

仍然是固定大小，但至少结构更清晰。

---

## 更激进的优化：动态存储

如果内存真的非常关键，可以使用 BCS 序列化：

```move
struct Status has store {
    tag: u8,
    // 所有数据都序列化到这个 vector
    data: vector<u8>,
}

public fun processing(worker_id: address): Status {
    Status {
        tag: 1,
        data: bcs::to_bytes(&worker_id),
    }
}

public fun get_worker_id(status: &Status): address {
    assert!(status.tag == 1, E_NOT_PROCESSING);
    bcs::from_bytes<address>(&status.data)
}
```

**优点**：
- ✅ 内存最优（只存当前 variant 的数据）

**缺点**：
- ❌ 失去类型安全
- ❌ 序列化/反序列化开销大
- ❌ Gas 成本高
- ❌ 容易出错

**不推荐**，除非内存压力极大。

---

## 方案对比总结

| 方案 | 内存 | 类型安全 | Gas 成本 | 复杂度 | 推荐度 |
|------|------|---------|---------|--------|--------|
| **直接 Option** | 最差 (固定) | 中 | 中 | 低 | ⭐⭐⭐ 通用 |
| **嵌套 Struct** | 差 (固定) | 中 | 中 | 中 | ⭐⭐ 可读性好 |
| **BCS 序列化** | 最优 (动态) | 差 | 高 | 高 | ⭐ 特殊场景 |
| **真正的 Enum** | 最优 (动态) | 最好 | 最低 | 最低 | ⭐⭐⭐⭐⭐ 升级后 |

---

## 代码生成模板

对于任意 enum，使用以下模板：

```move
// 1. 定义 tag 常量
const TAG_VARIANT_1: u8 = 0;
const TAG_VARIANT_2: u8 = 1;
// ... 最多 256 个

// 2. 定义 struct
struct EnumName<T: store> has store {
    tag: u8,

    // 每个 variant 的字段都包装在 Option 中
    variant1_field1: Option<Type1>,
    variant1_field2: Option<Type2>,

    variant2_field: Option<Type3>,
    // ...
}

// 3. 为每个 variant 提供构造函数
public fun variant1<T: store>(field1: Type1, field2: Type2): EnumName<T> {
    EnumName {
        tag: TAG_VARIANT_1,
        variant1_field1: option::some(field1),
        variant1_field2: option::some(field2),
        variant2_field: option::none(),
        // ... 其他 variant 的字段都是 none
    }
}

// 4. 提供检查函数
public fun is_variant1<T: store>(e: &EnumName<T>): bool {
    e.tag == TAG_VARIANT_1
}

// 5. 提供访问函数
public fun get_field1<T: store>(e: &EnumName<T>): &Type1 {
    assert!(e.tag == TAG_VARIANT_1, ERROR_CODE);
    option::borrow(&e.variant1_field1)
}
```

---

## 实用工具：宏/代码生成

如果您有很多 enum 需要转换，可以写一个脚本自动生成：

```python
# enum_to_struct_generator.py
def generate_struct(enum_name, variants):
    """
    variants = [
        ("Pending", []),
        ("Processing", [("worker_id", "address")]),
        ("Completed", [("result", "T")]),
        ("Failed", [("error", "vector<u8>"), ("retry_count", "u64")]),
    ]
    """
    # 生成 tag 常量
    tags = [f"const TAG_{v[0].upper()}: u8 = {i};" for i, v in enumerate(variants)]

    # 生成 struct 定义
    fields = ["tag: u8,"]
    for variant_name, variant_fields in variants:
        for field_name, field_type in variant_fields:
            fields.append(f"{variant_name.lower()}_{field_name}: Option<{field_type}>,")

    # 生成构造函数
    # ... (省略详细实现)

    return generated_code
```

---

## FAQ

### Q1: tag 用 u8 够用吗？

**答**: 够用！u8 可以表示 0-255，即最多 **256 个 variant**。
- 如果真有超过 256 个 variant，考虑重新设计数据结构
- 或者使用 u16 (最多 65536 个)

### Q2: 所有字段都用 Option 包装，内存浪费严重怎么办？

**答**: 取决于优先级：
- **优先简洁性**: 接受内存浪费，使用推荐方案
- **优先性能**: 使用嵌套 Struct 或 BCS 序列化
- **最优解**: 升级到支持 enum 的版本

### Q3: 能否只为当前 variant 分配字段？

**答**: 不能。Move 的 struct 是静态定义的，所有字段在编译时确定。这正是为什么 enum 需要语言级别支持。

### Q4: 如何确保 tag 和数据的一致性？

**答**:
1. **私有字段**: 不要暴露 struct 的字段
2. **构造函数**: 只通过公共构造函数创建
3. **访问控制**: 所有访问都通过 getter 并检查 tag
4. **单元测试**: 充分测试所有状态转换

---

## 总结

### 对于多个枚举变体

✅ **推荐方案**：u8 tag + 多个 Option 字段

```move
struct EnumSimulation {
    tag: u8,              // 0-255 个 variant
    variant1_fields: Option<...>,
    variant2_fields: Option<...>,
    // ...
}
```

### 权衡

| 维度 | Enum (VERSION_7+) | Struct 模拟 |
|------|------------------|-------------|
| 内存效率 | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| 类型安全 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |
| 开发体验 | ⭐⭐⭐⭐⭐ | ⭐⭐ |
| 可维护性 | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ |

### 迁移建议

1. **短期**: 使用 u8 tag + Option 方案
2. **中期**: 计划升级到支持 enum 的版本
3. **长期**: 迁移到原生 enum

---

*本指南适用于需要在旧版本 Move 中模拟多个枚举变体的场景。*
