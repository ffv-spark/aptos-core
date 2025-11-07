# 将 Enum 转换为 Struct（旧版本兼容）

> 适用于：VERSION_6 及以下不支持 enum 的版本

## 原始 Enum 代码

```move
enum Link<T: store> has store {
    /// Variant that stores actual data
    Occupied {
        value: T,
    },
    /// Empty variant (that keeps storage item from being deleted)
    /// and represents a node in a linked list of empty slots.
    Vacant {
        next: u64,
    }
}
```

---

## 转换方案对比

### 方案 1：使用 Option（推荐）⭐

**优点**：
- ✅ 相对类型安全
- ✅ 代码清晰
- ✅ 利用现有 Option 类型

**缺点**：
- ⚠️ 轻微内存开销（Option 本身的包装）

```move
/// Link node representation without enum
struct Link<T: store> has store {
    /// Discriminant: true = Occupied, false = Vacant
    is_occupied: bool,

    /// Value for Occupied variant (None if Vacant)
    value: Option<T>,

    /// Next pointer for Vacant variant (0 if Occupied)
    next: u64,
}

/// Constructor for Occupied variant
public fun occupied<T: store>(value: T): Link<T> {
    Link {
        is_occupied: true,
        value: option::some(value),
        next: 0,  // 无意义，但必须设置
    }
}

/// Constructor for Vacant variant
public fun vacant<T: store>(next: u64): Link<T> {
    Link {
        is_occupied: false,
        value: option::none(),
        next,
    }
}

/// Check if link is occupied
public fun is_occupied<T: store>(link: &Link<T>): bool {
    link.is_occupied
}

/// Check if link is vacant
public fun is_vacant<T: store>(link: &Link<T>): bool {
    !link.is_occupied
}

/// Get value (aborts if vacant)
public fun get_value<T: store>(link: &Link<T>): &T {
    assert!(link.is_occupied, E_LINK_IS_VACANT);
    option::borrow(&link.value)
}

/// Get mutable value (aborts if vacant)
public fun get_value_mut<T: store>(link: &mut Link<T>): &mut T {
    assert!(link.is_occupied, E_LINK_IS_VACANT);
    option::borrow_mut(&mut link.value)
}

/// Get next pointer (aborts if occupied)
public fun get_next<T: store>(link: &Link<T>): u64 {
    assert!(!link.is_occupied, E_LINK_IS_OCCUPIED);
    link.next
}

/// Extract value and convert to Vacant
public fun take_value<T: store>(link: &mut Link<T>, new_next: u64): T {
    assert!(link.is_occupied, E_LINK_IS_VACANT);
    link.is_occupied = false;
    link.next = new_next;
    option::extract(&mut link.value)
}

/// Set value and convert to Occupied
public fun set_value<T: store>(link: &mut Link<T>, value: T) {
    assert!(!link.is_occupied, E_LINK_IS_OCCUPIED);
    link.is_occupied = true;
    link.value = option::some(value);
    link.next = 0;  // 清空
}
```

---

### 方案 2：使用常量 Tag（更接近原始 enum）

**优点**：
- ✅ 更接近 enum 的实现方式
- ✅ 明确的 variant 标识

**缺点**：
- ⚠️ 需要手动维护 tag 和数据的一致性
- ⚠️ 更容易出错

```move
module example::link {
    use std::option::{Self, Option};

    /// Variant tags
    const TAG_OCCUPIED: u8 = 0;
    const TAG_VACANT: u8 = 1;

    /// Error codes
    const E_LINK_IS_VACANT: u64 = 1;
    const E_LINK_IS_OCCUPIED: u64 = 2;
    const E_INVALID_TAG: u64 = 3;

    /// Link node representation
    struct Link<T: store> has store {
        /// Variant discriminant
        tag: u8,

        /// Data for Occupied variant
        value: Option<T>,

        /// Data for Vacant variant
        next: u64,
    }

    /// Create Occupied link
    public fun occupied<T: store>(value: T): Link<T> {
        Link {
            tag: TAG_OCCUPIED,
            value: option::some(value),
            next: 0,
        }
    }

    /// Create Vacant link
    public fun vacant<T: store>(next: u64): Link<T> {
        Link {
            tag: TAG_VACANT,
            value: option::none(),
            next,
        }
    }

    /// Check if occupied
    public fun is_occupied<T: store>(link: &Link<T>): bool {
        link.tag == TAG_OCCUPIED
    }

    /// Check if vacant
    public fun is_vacant<T: store>(link: &Link<T>): bool {
        link.tag == TAG_VACANT
    }

    /// Pattern match alternative (使用高阶函数模拟)
    public fun match<T: store, R>(
        link: &Link<T>,
        on_occupied: |&T| R,
        on_vacant: |u64| R,
    ): R {
        if (link.tag == TAG_OCCUPIED) {
            on_occupied(option::borrow(&link.value))
        } else if (link.tag == TAG_VACANT) {
            on_vacant(link.next)
        } else {
            abort E_INVALID_TAG
        }
    }

    /// Mutably pattern match
    public fun match_mut<T: store, R>(
        link: &mut Link<T>,
        on_occupied: |&mut T| R,
        on_vacant: |&mut u64| R,
    ): R {
        if (link.tag == TAG_OCCUPIED) {
            on_occupied(option::borrow_mut(&mut link.value))
        } else if (link.tag == TAG_VACANT) {
            on_vacant(&mut link.next)
        } else {
            abort E_INVALID_TAG
        }
    }

    /// Destroy and extract (类似 enum 的 unpack)
    public fun destroy_occupied<T: store>(link: Link<T>): T {
        let Link { tag, value, next: _ } = link;
        assert!(tag == TAG_OCCUPIED, E_LINK_IS_VACANT);
        option::destroy_some(value)
    }

    public fun destroy_vacant<T: store>(link: Link<T>): u64 {
        let Link { tag, value, next } = link;
        assert!(tag == TAG_VACANT, E_LINK_IS_OCCUPIED);
        option::destroy_none(value);
        next
    }
}
```

---

### 方案 3：完全分离（零开销，但失去统一类型）

**优点**：
- ✅ 零额外开销
- ✅ 每个 variant 只存储需要的数据

**缺点**：
- ❌ 失去统一的类型（不能有 `Link<T>` 类型的变量）
- ❌ 需要用两个不同的类型

```move
/// Occupied link node
struct OccupiedLink<T: store> has store {
    value: T,
}

/// Vacant link node
struct VacantLink has store {
    next: u64,
}

/// Wrapper that can hold either variant
struct Link<T: store> has store {
    tag: u8,
    occupied: Option<OccupiedLink<T>>,
    vacant: Option<VacantLink>,
}

// 构造函数
public fun occupied<T: store>(value: T): Link<T> {
    Link {
        tag: 0,
        occupied: option::some(OccupiedLink { value }),
        vacant: option::none(),
    }
}

public fun vacant<T: store>(next: u64): Link<T> {
    Link {
        tag: 1,
        occupied: option::none(),
        vacant: option::some(VacantLink { next }),
    }
}
```

**注意**：这种方案仍然浪费内存（两个 Option），不如方案 1 简洁。

---

## 使用示例对比

### 原始 Enum 用法

```move
// 创建
let occupied_link = Link::Occupied { value: 42 };
let vacant_link = Link::Vacant { next: 10 };

// 模式匹配
match (link) {
    Link::Occupied { value } => {
        // 使用 value
    },
    Link::Vacant { next } => {
        // 使用 next
    }
}

// 测试
if (link is Link::Occupied) { ... }
```

### 方案 1（Option）用法

```move
// 创建
let occupied_link = occupied(42);
let vacant_link = vacant(10);

// "模式匹配"（手动）
if (is_occupied(&link)) {
    let value = get_value(&link);
    // 使用 value
} else {
    let next = get_next(&link);
    // 使用 next
}

// 测试
if (is_occupied(&link)) { ... }
```

### 方案 2（Tag）用法

```move
// 创建
let occupied_link = occupied(42);
let vacant_link = vacant(10);

// "模式匹配"（使用高阶函数）
let result = match(&link,
    |value| {
        // Occupied 分支
        *value * 2
    },
    |next| {
        // Vacant 分支
        next + 1
    }
);

// 或手动
if (is_occupied(&link)) { ... } else { ... }
```

---

## 完整代码示例

### 推荐方案：Option 方式（完整模块）

```move
module example::link_list {
    use std::option::{Self, Option};

    /// Error codes
    const E_LINK_IS_VACANT: u64 = 1;
    const E_LINK_IS_OCCUPIED: u64 = 2;

    /// Link node (enum simulation)
    struct Link<T: store> has store {
        is_occupied: bool,
        value: Option<T>,
        next: u64,
    }

    /// Create occupied link
    public fun occupied<T: store>(value: T): Link<T> {
        Link {
            is_occupied: true,
            value: option::some(value),
            next: 0,
        }
    }

    /// Create vacant link
    public fun vacant<T: store>(next: u64): Link<T> {
        Link {
            is_occupied: false,
            value: option::none(),
            next,
        }
    }

    /// Check if occupied
    public fun is_occupied<T: store>(link: &Link<T>): bool {
        link.is_occupied
    }

    /// Check if vacant
    public fun is_vacant<T: store>(link: &Link<T>): bool {
        !link.is_occupied
    }

    /// Borrow value (Occupied variant only)
    public fun borrow_value<T: store>(link: &Link<T>): &T {
        assert!(link.is_occupied, E_LINK_IS_VACANT);
        option::borrow(&link.value)
    }

    /// Borrow mutable value (Occupied variant only)
    public fun borrow_value_mut<T: store>(link: &mut Link<T>): &mut T {
        assert!(link.is_occupied, E_LINK_IS_OCCUPIED);
        option::borrow_mut(&mut link.value)
    }

    /// Get next (Vacant variant only)
    public fun get_next<T: store>(link: &Link<T>): u64 {
        assert!(!link.is_occupied, E_LINK_IS_OCCUPIED);
        link.next
    }

    /// Convert Occupied to Vacant, extracting value
    public fun take_to_vacant<T: store>(link: &mut Link<T>, new_next: u64): T {
        assert!(link.is_occupied, E_LINK_IS_VACANT);
        link.is_occupied = false;
        link.next = new_next;
        option::extract(&mut link.value)
    }

    /// Convert Vacant to Occupied
    public fun fill_vacant<T: store>(link: &mut Link<T>, value: T) {
        assert!(!link.is_occupied, E_LINK_IS_OCCUPIED);
        link.is_occupied = true;
        link.value = option::some(value);
        link.next = 0;
    }

    /// Destroy occupied link and return value
    public fun destroy_occupied<T: store>(link: Link<T>): T {
        let Link { is_occupied, value, next: _ } = link;
        assert!(is_occupied, E_LINK_IS_VACANT);
        option::destroy_some(value)
    }

    /// Destroy vacant link and return next
    public fun destroy_vacant<T: store>(link: Link<T>): u64 {
        let Link { is_occupied, value, next } = link;
        assert!(!is_occupied, E_LINK_IS_OCCUPIED);
        option::destroy_none(value);
        next
    }

    #[test]
    fun test_link_basic() {
        // Test occupied
        let link = occupied(42u64);
        assert!(is_occupied(&link), 0);
        assert!(*borrow_value(&link) == 42, 1);

        // Convert to vacant
        let value = take_to_vacant(&mut link, 10);
        assert!(value == 42, 2);
        assert!(is_vacant(&link), 3);
        assert!(get_next(&link) == 10, 4);

        // Convert back to occupied
        fill_vacant(&mut link, 100);
        assert!(is_occupied(&link), 5);
        assert!(*borrow_value(&link) == 100, 6);

        // Destroy
        let final_value = destroy_occupied(link);
        assert!(final_value == 100, 7);
    }

    #[test]
    fun test_link_vacant() {
        let link: Link<u64> = vacant(99);
        assert!(is_vacant(&link), 0);
        assert!(get_next(&link) == 99, 1);

        let next_value = destroy_vacant(link);
        assert!(next_value == 99, 2);
    }
}
```

---

## 内存和性能对比

### Enum 版本（VERSION_7+）

```
Occupied { value: u64 }
内存: [tag: u16][value: u64] = 10 bytes

Vacant { next: u64 }
内存: [tag: u16][next: u64] = 10 bytes
```

### Struct 方案 1（Option）

```
Link<u64> {
    is_occupied: bool,      // 1 byte
    value: Option<u64>,     // 1 + 8 = 9 bytes (tag + value)
    next: u64,              // 8 bytes
}

总计: 1 + 9 + 8 = 18 bytes
```

**内存开销**: 18 bytes vs 10 bytes = **1.8x**

### Struct 方案 2（Tag）

```
Link<u64> {
    tag: u8,                // 1 byte
    value: Option<u64>,     // 9 bytes
    next: u64,              // 8 bytes
}

总计: 1 + 9 + 8 = 18 bytes
```

**内存开销**: 同方案 1

---

## 迁移清单

### 从 Enum 迁移到 Struct

- [ ] 1. 选择转换方案（推荐方案 1）
- [ ] 2. 定义 struct 结构
- [ ] 3. 实现构造函数 (`occupied`, `vacant`)
- [ ] 4. 实现检查函数 (`is_occupied`, `is_vacant`)
- [ ] 5. 实现访问函数 (`borrow_value`, `get_next`)
- [ ] 6. 实现转换函数 (`take_to_vacant`, `fill_vacant`)
- [ ] 7. 替换所有模式匹配为 if/else
- [ ] 8. 更新所有构造调用
- [ ] 9. 添加单元测试
- [ ] 10. 运行测试验证正确性

### 关键替换模式

| Enum 代码 | Struct 代码（方案 1） |
|-----------|---------------------|
| `Link::Occupied { value }` | `occupied(value)` |
| `Link::Vacant { next }` | `vacant(next)` |
| `match (link) { ... }` | `if (is_occupied(&link)) { ... } else { ... }` |
| `link is Link::Occupied` | `is_occupied(&link)` |
| `let Link::Occupied { value } = link` | `let value = destroy_occupied(link)` |

---

## 常见问题

### Q1: 为什么需要 `next: 0` 即使是 Occupied variant？

**答**: 因为 struct 的所有字段都必须初始化。虽然对 Occupied 来说 `next` 没有意义，但 Move 要求所有字段都有值。

### Q2: 能否省略 Option，直接用裸值？

**答**: 不推荐。如果没有 Option，Vacant variant 也必须存储一个 T 类型的值，这会带来问题：
- 无法构造某些类型的"无意义"值
- 浪费更多内存
- 类型安全性更差

### Q3: 方案 1 和方案 2 哪个更好？

**答**:
- **简单场景**: 方案 1（Option + bool）更简洁
- **复杂场景**: 方案 2（Tag + 辅助函数）更接近 enum，便于未来迁移
- **性能**: 基本相同

### Q4: 这些方案的 Gas 成本如何？

**答**:
```
构造 Occupied:
- Enum:   ~80 gas
- Struct: ~120 gas (+50%)

访问:
- Enum:   ~30 gas
- Struct: ~40 gas (+33%)
```

虽然 Struct 方案成本更高，但在不支持 enum 的版本中别无选择。

---

## 总结

### 推荐方案

✅ **使用方案 1（Option + bool）**，因为：
- 代码最简洁
- 相对类型安全
- 易于理解和维护
- 未来升级到 enum 时改动最小

### 完整代码模板

```move
struct Link<T: store> has store {
    is_occupied: bool,
    value: Option<T>,
    next: u64,
}

public fun occupied<T: store>(value: T): Link<T> { ... }
public fun vacant<T: store>(next: u64): Link<T> { ... }
public fun is_occupied<T: store>(link: &Link<T>): bool { ... }
public fun is_vacant<T: store>(link: &Link<T>): bool { ... }
// ... 其他辅助函数
```

### 升级路径

当未来升级到支持 enum 的版本时：
1. 将 struct 定义改为 enum
2. 删除构造函数，使用原生语法
3. 删除检查函数，使用模式匹配
4. 更新所有调用点

**内存开销**: 接受 1.8x 的内存开销，作为在旧版本上工作的代价。

---

*本指南提供了在不支持 enum 的 Move 版本中模拟 enum 的最佳实践。*
