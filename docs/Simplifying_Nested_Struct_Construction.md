# 简化嵌套结构构造的实用技巧

> 解决问题：嵌套结构虽然优雅，但构造起来太痛苦！

## 问题演示

### 痛苦的嵌套构造

```move
// 😫 太痛苦了！
let status = Status {
    tag: TAG_COMPLETED,
    processing: option::none(),
    completed: option::some(CompletedData {
        result: compute_result(),
        metadata: CompletionMetadata {
            finished_at: timestamp::now(),
            duration_ms: calculate_duration(),
            final_size: get_size(),
            worker_info: WorkerInfo {
                worker_id: @0x123,
                worker_name: b"worker-1",
                region: b"us-west",
            }
        }
    }),
    failed: option::none(),
};
// 😵 嵌套太多，要疯了！
```

---

## 解决方案汇总

| 方案 | 简洁度 | 灵活性 | 复杂度 | 推荐度 |
|------|-------|--------|--------|--------|
| **构造函数** | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Builder 模式** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **宏风格辅助** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **默认值 + 更新** | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |

---

## 方案 1：构造函数（最简单）⭐⭐⭐⭐⭐

### 核心思想

**为每一层嵌套都提供构造函数，层层封装。**

### 实现

```move
module example::simplified_construction {
    use std::option::{Self, Option};

    // ============ 最内层结构 ============

    struct WorkerInfo has store, drop, copy {
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    }

    /// ✅ 提供简单的构造函数
    public fun new_worker_info(
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>
    ): WorkerInfo {
        WorkerInfo { worker_id, worker_name, region }
    }

    // ============ 中层结构 ============

    struct CompletionMetadata has store {
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_info: WorkerInfo,
    }

    /// ✅ 提供接受内层结构的构造函数
    public fun new_completion_metadata(
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_info: WorkerInfo,  // 已经构造好的
    ): CompletionMetadata {
        CompletionMetadata {
            finished_at,
            duration_ms,
            final_size,
            worker_info,
        }
    }

    /// ✅✅ 更方便：直接接受原始参数
    public fun new_completion_metadata_simple(
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    ): CompletionMetadata {
        CompletionMetadata {
            finished_at,
            duration_ms,
            final_size,
            worker_info: new_worker_info(worker_id, worker_name, region),
        }
    }

    // ============ 外层结构 ============

    struct CompletedData<T: store> has store {
        result: T,
        metadata: CompletionMetadata,
    }

    /// ✅ 方式 1：接受已构造的 metadata
    public fun new_completed_data<T: store>(
        result: T,
        metadata: CompletionMetadata,
    ): CompletedData<T> {
        CompletedData { result, metadata }
    }

    /// ✅✅ 方式 2：接受 metadata 的参数
    public fun new_completed_data_with_metadata<T: store>(
        result: T,
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_info: WorkerInfo,
    ): CompletedData<T> {
        CompletedData {
            result,
            metadata: new_completion_metadata(
                finished_at,
                duration_ms,
                final_size,
                worker_info
            ),
        }
    }

    /// ✅✅✅ 方式 3：完全展开所有参数（最方便）
    public fun new_completed_data_full<T: store>(
        result: T,
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    ): CompletedData<T> {
        CompletedData {
            result,
            metadata: new_completion_metadata_simple(
                finished_at,
                duration_ms,
                final_size,
                worker_id,
                worker_name,
                region
            ),
        }
    }

    // ============ 最外层：Status ============

    const TAG_PENDING: u8 = 0;
    const TAG_PROCESSING: u8 = 1;
    const TAG_COMPLETED: u8 = 2;
    const TAG_FAILED: u8 = 3;

    struct Status<T: store> has store {
        tag: u8,
        processing: Option<ProcessingData>,
        completed: Option<CompletedData<T>>,
        failed: Option<FailedData>,
    }

    /// ✅ 直接接受 CompletedData
    public fun completed<T: store>(data: CompletedData<T>): Status<T> {
        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(data),
            failed: option::none(),
        }
    }

    /// ✅✅ 完全展开版本（一步到位）
    public fun completed_full<T: store>(
        result: T,
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    ): Status<T> {
        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(new_completed_data_full(
                result,
                finished_at,
                duration_ms,
                final_size,
                worker_id,
                worker_name,
                region
            )),
            failed: option::none(),
        }
    }

    // ============ 使用示例 ============

    #[test]
    fun test_construction_comparison() {
        // 😫 方式 1：手动构造（太痛苦）
        let status_manual = Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(CompletedData {
                result: 42u64,
                metadata: CompletionMetadata {
                    finished_at: 1000,
                    duration_ms: 500,
                    final_size: 1024,
                    worker_info: WorkerInfo {
                        worker_id: @0x123,
                        worker_name: b"worker-1",
                        region: b"us-west",
                    }
                }
            }),
            failed: option::none(),
        };

        // 😊 方式 2：层层构造（还可以）
        let worker = new_worker_info(@0x123, b"worker-1", b"us-west");
        let metadata = new_completion_metadata(1000, 500, 1024, worker);
        let data = new_completed_data(42u64, metadata);
        let status_layered = completed(data);

        // 😍 方式 3：一步到位（最爽）
        let status_direct = completed_full(
            42u64,
            1000,
            500,
            1024,
            @0x123,
            b"worker-1",
            b"us-west"
        );

        // 都是等价的
        assert!(status_manual.tag == status_layered.tag, 0);
        assert!(status_layered.tag == status_direct.tag, 1);
    }
}
```

---

## 方案 2：Builder 模式（最灵活）⭐⭐⭐⭐

### 核心思想

**使用 Builder 结构，支持链式调用和可选参数。**

### 实现

```move
module example::builder_pattern {
    use std::option::{Self, Option};

    // ============ Builder 结构 ============

    struct StatusBuilder<T: store> has drop {
        result: Option<T>,
        finished_at: Option<u64>,
        duration_ms: Option<u64>,
        final_size: Option<u64>,
        worker_id: Option<address>,
        worker_name: Option<vector<u8>>,
        region: Option<vector<u8>>,
    }

    /// 创建 builder
    public fun builder<T: store>(): StatusBuilder<T> {
        StatusBuilder {
            result: option::none(),
            finished_at: option::none(),
            duration_ms: option::none(),
            final_size: option::none(),
            worker_id: option::none(),
            worker_name: option::none(),
            region: option::none(),
        }
    }

    /// 链式设置方法
    public fun with_result<T: store>(
        builder: &mut StatusBuilder<T>,
        result: T
    ): &mut StatusBuilder<T> {
        builder.result = option::some(result);
        builder
    }

    public fun with_finished_at<T: store>(
        builder: &mut StatusBuilder<T>,
        finished_at: u64
    ): &mut StatusBuilder<T> {
        builder.finished_at = option::some(finished_at);
        builder
    }

    public fun with_duration<T: store>(
        builder: &mut StatusBuilder<T>,
        duration_ms: u64
    ): &mut StatusBuilder<T> {
        builder.duration_ms = option::some(duration_ms);
        builder
    }

    public fun with_size<T: store>(
        builder: &mut StatusBuilder<T>,
        final_size: u64
    ): &mut StatusBuilder<T> {
        builder.final_size = option::some(final_size);
        builder
    }

    public fun with_worker<T: store>(
        builder: &mut StatusBuilder<T>,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>
    ): &mut StatusBuilder<T> {
        builder.worker_id = option::some(worker_id);
        builder.worker_name = option::some(worker_name);
        builder.region = option::some(region);
        builder
    }

    /// 构建最终的 Status
    public fun build<T: store>(builder: StatusBuilder<T>): Status<T> {
        // 提取所有字段（使用 expect 确保必填字段存在）
        let result = option::extract(&mut builder.result);
        let finished_at = option::destroy_with_default(
            builder.finished_at,
            timestamp::now()  // 默认值
        );
        let duration_ms = option::destroy_with_default(builder.duration_ms, 0);
        let final_size = option::destroy_with_default(builder.final_size, 0);

        // Worker info 是可选的
        let worker_info = if (option::is_some(&builder.worker_id)) {
            option::some(WorkerInfo {
                worker_id: option::destroy_some(builder.worker_id),
                worker_name: option::destroy_some(builder.worker_name),
                region: option::destroy_some(builder.region),
            })
        } else {
            option::destroy_none(builder.worker_id);
            option::destroy_none(builder.worker_name);
            option::destroy_none(builder.region);
            option::none()
        };

        // 构造最终的 Status
        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(CompletedData {
                result,
                metadata: CompletionMetadata {
                    finished_at,
                    duration_ms,
                    final_size,
                    worker_info,
                }
            }),
            failed: option::none(),
        }
    }

    // ============ 使用示例 ============

    #[test]
    fun test_builder_pattern() {
        // 😍 链式调用，非常优雅
        let mut builder = builder<u64>();

        let status = with_result(&mut builder, 42)
            .with_finished_at(1000)
            .with_duration(500)
            .with_size(1024)
            .with_worker(@0x123, b"worker-1", b"us-west");

        let status = build(builder);

        // ✅ 也可以只设置必需字段
        let mut builder2 = builder<u64>();
        with_result(&mut builder2, 99);
        let status2 = build(builder2);  // 其他字段用默认值
    }
}
```

---

## 方案 3：默认值 + 更新模式（最实用）⭐⭐⭐⭐⭐

### 核心思想

**提供默认值构造器，然后提供更新方法。**

### 实现

```move
module example::default_update_pattern {
    use std::option::{Self, Option};

    // ============ 默认值构造 ============

    /// 创建带默认值的 CompletedData
    public fun completed_with_defaults<T: store>(result: T): CompletedData<T> {
        CompletedData {
            result,
            metadata: CompletionMetadata {
                finished_at: 0,
                duration_ms: 0,
                final_size: 0,
                worker_info: default_worker_info(),
            }
        }
    }

    fun default_worker_info(): WorkerInfo {
        WorkerInfo {
            worker_id: @0x0,
            worker_name: b"",
            region: b"",
        }
    }

    // ============ 更新方法 ============

    /// 更新 metadata
    public fun set_metadata<T: store>(
        data: &mut CompletedData<T>,
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
    ) {
        data.metadata.finished_at = finished_at;
        data.metadata.duration_ms = duration_ms;
        data.metadata.final_size = final_size;
    }

    /// 更新 worker info
    public fun set_worker_info<T: store>(
        data: &mut CompletedData<T>,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    ) {
        data.metadata.worker_info = WorkerInfo {
            worker_id,
            worker_name,
            region,
        };
    }

    /// 快速设置所有字段
    public fun set_all<T: store>(
        data: &mut CompletedData<T>,
        finished_at: u64,
        duration_ms: u64,
        final_size: u64,
        worker_id: address,
        worker_name: vector<u8>,
        region: vector<u8>,
    ) {
        set_metadata(data, finished_at, duration_ms, final_size);
        set_worker_info(data, worker_id, worker_name, region);
    }

    // ============ 使用示例 ============

    #[test]
    fun test_default_update() {
        // 😊 先创建默认值
        let mut data = completed_with_defaults(42u64);

        // 😊 然后按需更新
        set_metadata(&mut data, 1000, 500, 1024);
        set_worker_info(&mut data, @0x123, b"worker-1", b"us-west");

        // 或者一次性更新
        let mut data2 = completed_with_defaults(99u64);
        set_all(&mut data2, 2000, 300, 2048, @0x456, b"worker-2", b"eu-west");
    }
}
```

---

## 方案 4：宏风格的辅助函数（最像语法糖）

### 核心思想

**定义类似宏的辅助函数，模拟简化语法。**

### 实现

```move
module example::macro_style {
    // ============ "宏" 函数 ============

    /// worker! 宏（模拟）
    public fun worker(
        id: address,
        name: vector<u8>,
        region: vector<u8>
    ): WorkerInfo {
        WorkerInfo {
            worker_id: id,
            worker_name: name,
            region,
        }
    }

    /// metadata! 宏（模拟）
    public fun metadata(
        time: u64,
        duration: u64,
        size: u64,
        worker: WorkerInfo
    ): CompletionMetadata {
        CompletionMetadata {
            finished_at: time,
            duration_ms: duration,
            final_size: size,
            worker_info: worker,
        }
    }

    /// completed_data! 宏（模拟）
    public fun completed_data<T: store>(
        result: T,
        meta: CompletionMetadata
    ): CompletedData<T> {
        CompletedData {
            result,
            metadata: meta,
        }
    }

    /// status! 宏（模拟）
    public fun status_completed<T: store>(
        data: CompletedData<T>
    ): Status<T> {
        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(data),
            failed: option::none(),
        }
    }

    // ============ 使用示例 ============

    #[test]
    fun test_macro_style() {
        // 😍 看起来像嵌套的宏调用！
        let status = status_completed(
            completed_data(
                42u64,
                metadata(
                    1000,
                    500,
                    1024,
                    worker(@0x123, b"worker-1", b"us-west")
                )
            )
        );

        // 对比：原始构造
        // let status = Status {
        //     tag: TAG_COMPLETED,
        //     processing: option::none(),
        //     completed: option::some(CompletedData {
        //         result: 42u64,
        //         metadata: CompletionMetadata {
        //             finished_at: 1000,
        //             duration_ms: 500,
        //             final_size: 1024,
        //             worker_info: WorkerInfo {
        //                 worker_id: @0x123,
        //                 worker_name: b"worker-1",
        //                 region: b"us-west",
        //             }
        //         }
        //     }),
        //     failed: option::none(),
        // };
    }
}
```

---

## 方案 5：智能构造器（最自动化）

### 核心思想

**使用 `struct` 参数，让编译器帮你做一些工作。**

### 实现

```move
module example::smart_constructor {
    // ============ 参数结构体 ============

    /// 构造参数（所有字段都是可选的）
    struct CompletedParams<T: store> has drop {
        result: T,
        finished_at: Option<u64>,
        duration_ms: Option<u64>,
        final_size: Option<u64>,
        worker_id: Option<address>,
        worker_name: Option<vector<u8>>,
        region: Option<vector<u8>>,
    }

    /// 创建参数（只需要必填字段）
    public fun params<T: store>(result: T): CompletedParams<T> {
        CompletedParams {
            result,
            finished_at: option::none(),
            duration_ms: option::none(),
            final_size: option::none(),
            worker_id: option::none(),
            worker_name: option::none(),
            region: option::none(),
        }
    }

    /// 从参数构造 Status
    public fun from_params<T: store>(params: CompletedParams<T>): Status<T> {
        let CompletedParams {
            result,
            finished_at,
            duration_ms,
            final_size,
            worker_id,
            worker_name,
            region,
        } = params;

        // 使用默认值
        let finished_at = option::destroy_with_default(finished_at, timestamp::now());
        let duration_ms = option::destroy_with_default(duration_ms, 0);
        let final_size = option::destroy_with_default(final_size, 0);

        let worker_info = if (option::is_some(&worker_id)) {
            WorkerInfo {
                worker_id: option::destroy_some(worker_id),
                worker_name: option::destroy_some(worker_name),
                region: option::destroy_some(region),
            }
        } else {
            option::destroy_none(worker_id);
            option::destroy_none(worker_name);
            option::destroy_none(region);
            default_worker_info()
        };

        Status {
            tag: TAG_COMPLETED,
            processing: option::none(),
            completed: option::some(CompletedData {
                result,
                metadata: CompletionMetadata {
                    finished_at,
                    duration_ms,
                    final_size,
                    worker_info,
                }
            }),
            failed: option::none(),
        }
    }

    // ============ 使用示例 ============

    #[test]
    fun test_smart_constructor() {
        // 😍 只设置需要的字段
        let mut p = params(42u64);
        p.finished_at = option::some(1000);
        p.worker_id = option::some(@0x123);
        p.worker_name = option::some(b"worker-1");
        p.region = option::some(b"us-west");

        let status = from_params(p);
    }
}
```

---

## 实战对比

### 场景：构造一个复杂的 Status

```move
// 目标：创建一个 Completed status，包含所有信息

// ============ 原始方式（最痛苦）😫 ============
let status = Status {
    tag: TAG_COMPLETED,
    processing: option::none(),
    completed: option::some(CompletedData {
        result: 42u64,
        metadata: CompletionMetadata {
            finished_at: 1000,
            duration_ms: 500,
            final_size: 1024,
            worker_info: WorkerInfo {
                worker_id: @0x123,
                worker_name: b"worker-1",
                region: b"us-west",
            }
        }
    }),
    failed: option::none(),
};

// ============ 方案 1：构造函数（简单直接）😊 ============
let status = completed_full(
    42u64,
    1000,
    500,
    1024,
    @0x123,
    b"worker-1",
    b"us-west"
);

// ============ 方案 2：Builder（灵活优雅）😍 ============
let mut builder = builder();
let status = with_result(&mut builder, 42)
    .with_finished_at(1000)
    .with_duration(500)
    .with_size(1024)
    .with_worker(@0x123, b"worker-1", b"us-west");
let status = build(builder);

// ============ 方案 3：默认值 + 更新（实用）😊 ============
let mut data = completed_with_defaults(42u64);
set_all(&mut data, 1000, 500, 1024, @0x123, b"worker-1", b"us-west");
let status = completed(data);

// ============ 方案 4：宏风格（简洁）😍 ============
let status = status_completed(
    completed_data(
        42u64,
        metadata(
            1000, 500, 1024,
            worker(@0x123, b"worker-1", b"us-west")
        )
    )
);
```

---

## 推荐策略

### 根据场景选择

| 场景 | 推荐方案 | 原因 |
|------|---------|------|
| **简单结构，固定参数** | 构造函数 | 最简单直接 |
| **复杂结构，可选参数多** | Builder 模式 | 最灵活 |
| **需要后续修改** | 默认值 + 更新 | 可以分步构造 |
| **追求简洁语法** | 宏风格 | 看起来最简洁 |
| **大量可选字段** | 智能构造器 | 自动处理默认值 |

### 混合使用

```move
// 😍 最佳实践：同时提供多种方式

// 1. 完整参数版本（Builder 内部使用）
fun completed_full(...) -> Status<T>

// 2. 简化版本（常用场景）
fun completed_simple(result: T, finished_at: u64) -> Status<T>

// 3. 默认值版本（最简单）
fun completed_default(result: T) -> Status<T>

// 4. Builder 版本（需要灵活性时）
fun completed_builder() -> StatusBuilder<T>
```

---

## 最终建议

### ✅ 推荐的组合

**提供 3 种接口**：

1. **简单构造函数**（80% 的使用场景）
```move
public fun completed_simple<T>(result: T): Status<T>
```

2. **完整构造函数**（需要所有参数时）
```move
public fun completed_full<T>(
    result: T,
    finished_at: u64,
    duration_ms: u64,
    ...
): Status<T>
```

3. **Builder**（需要可选参数时）
```move
public fun builder<T>(): StatusBuilder<T>
```

### 代码模板

```move
// ========== 推荐的 API 设计 ==========

/// 最简单的版本（用默认值）
public fun completed<T: store>(result: T): Status<T> {
    completed_full(result, timestamp::now(), 0, 0, @0x0, b"", b"")
}

/// 中等复杂度版本（常用参数）
public fun completed_with_time<T: store>(
    result: T,
    finished_at: u64,
    duration_ms: u64
): Status<T> {
    completed_full(result, finished_at, duration_ms, 0, @0x0, b"", b"")
}

/// 完整版本（所有参数）
public fun completed_full<T: store>(
    result: T,
    finished_at: u64,
    duration_ms: u64,
    final_size: u64,
    worker_id: address,
    worker_name: vector<u8>,
    region: vector<u8>,
): Status<T> {
    // 实际构造逻辑
    Status {
        tag: TAG_COMPLETED,
        processing: option::none(),
        completed: option::some(CompletedData {
            result,
            metadata: CompletionMetadata {
                finished_at,
                duration_ms,
                final_size,
                worker_info: WorkerInfo {
                    worker_id,
                    worker_name,
                    region,
                }
            }
        }),
        failed: option::none(),
    }
}

/// Builder 版本（高级用法）
public fun builder<T: store>(): StatusBuilder<T> {
    // Builder 实现
}
```

---

## 总结

### 解决嵌套构造痛点的关键

1. **不要直接暴露嵌套结构**
2. **提供多层次的构造函数**
3. **为常用场景提供快捷方式**
4. **可选参数用 Builder 模式**
5. **给用户选择权（简单 vs 灵活）**

### 最痛苦 → 最优雅

```
😫 手动嵌套构造
  ↓
😐 单个构造函数
  ↓
😊 多层次构造函数
  ↓
😍 Builder + 构造函数组合
```

**关键**：不要让用户直接面对复杂的嵌套！✨

---

*嵌套虽好，但要记得"封装"才是王道！*
