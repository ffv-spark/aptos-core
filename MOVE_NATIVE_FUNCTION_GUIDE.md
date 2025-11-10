# Move Native Function 实现完整指南

本文档详细说明如何在 Aptos Move 中实现 native function，以 `constant_serialized_size` 为实际案例。

## 目录

1. [架构概览](#架构概览)
2. [Move 端声明](#move-端声明)
3. [Rust 端实现](#rust-端实现)
4. [模块级注册](#模块级注册)
5. [Gas Schedule 配置](#gas-schedule-配置)
6. [关键 API 说明](#关键-api-说明)
7. [完整实现示例](#完整实现示例)
8. [重要注意事项](#重要注意事项)

---

## 架构概览

Native function 由四个核心部分组成：

```
┌──────────────────┐
│  Move 声明层      │  在 .move 文件中声明函数签名
│  (.move 文件)    │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Rust 实现层      │  在 Rust 中实现具体逻辑
│  (natives/*.rs)  │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  模块注册层       │  将实现注册到 Move VM
│  (mod.rs)        │
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│  Gas 参数配置     │  定义 Gas 计费参数
│  (gas_schedule)  │
└──────────────────┘
```

---

## Move 端声明

### 位置
- `aptos-move/framework/move-stdlib/sources/bcs.move`

### 示例代码

```move
module std::bcs {
    use std::option::Option;

    /// 如果类型具有已知的常量序列化大小，返回该大小，否则返回 None
    ///
    /// # 示例
    /// ```
    /// let size = bcs::constant_serialized_size<u64>(); // Some(8)
    /// let size = bcs::constant_serialized_size<vector<u8>>(); // None
    /// ```
    native public fun constant_serialized_size<MoveValue>(): Option<u64>;
}
```

### 关键点

- **`native` 关键字**：标识这是一个 native function
- **泛型参数**：支持类型参数（如 `<MoveValue>`）
- **参数和返回值**：可以有任意类型的参数和返回值
- **只有声明**：没有函数体实现

---

## Rust 端实现

### 位置
- `aptos-move/framework/move-stdlib/src/natives/bcs.rs`

### 完整示例

```rust
// 必要的导入
use aptos_gas_schedule::gas_params::natives::move_stdlib::*;
use aptos_native_interface::{
    safely_pop_arg, RawSafeNative, SafeNativeBuilder, SafeNativeContext,
    SafeNativeError, SafeNativeResult,
};
use move_vm_runtime::native_functions::NativeFunction;
use move_vm_types::{
    loaded_data::runtime_types::Type,
    values::Value,
};
use smallvec::{smallvec, SmallVec};
use std::collections::VecDeque;

/// Native function 实现
///
/// # 参数
/// - context: 上下文，用于 gas 计费和访问 VM 信息
/// - ty_args: 泛型参数列表（对应 Move 中的 <MoveValue>）
/// - args: 函数参数列表（栈式，需反向弹出）
///
/// # 返回值
/// - SafeNativeResult: 包含 SmallVec<Value> 的结果
fn native_constant_serialized_size(
    context: &mut SafeNativeContext,
    mut ty_args: Vec<Type>,
    _args: VecDeque<Value>,
) -> SafeNativeResult<SmallVec<[Value; 1]>> {
    // 1. 断言参数数量（仅在 debug 模式）
    debug_assert!(ty_args.len() == 1);

    // 2. 收取基础 gas 费用
    context.charge(BCS_CONSTANT_SERIALIZED_SIZE_BASE)?;

    // 3. 获取类型参数
    let ty = ty_args.pop().unwrap();

    // 4. 将 Type 转换为 TypeLayout（用于类型分析）
    let ty_layout = context.type_to_type_layout(&ty)?;

    // 5. 执行具体业务逻辑
    let (visited_count, serialized_size_result) = constant_serialized_size(&ty_layout);

    // 6. 根据操作复杂度收取额外 gas
    context.charge(
        BCS_CONSTANT_SERIALIZED_SIZE_PER_TYPE_NODE * NumTypeNodes::new(visited_count)
    )?;

    // 7. 构造返回值
    let enum_option_enabled = context.get_feature_flags().is_enum_option_enabled();
    let result = match serialized_size_result {
        Ok(value) => create_option_u64(enum_option_enabled, value.map(|v| v as u64)),
        Err(_) => {
            // 失败时收取失败费用
            context.charge(BCS_SERIALIZED_SIZE_FAILURE)?;
            return Err(SafeNativeError::Abort {
                abort_code: NFE_BCS_SERIALIZATION_FAILURE,
            });
        },
    };

    // 8. 返回结果（使用 smallvec 宏）
    Ok(smallvec![result])
}

/// 辅助函数：计算类型的常量序列化大小
///
/// # 返回值
/// - (visited_count, result): 访问的类型节点数和计算结果
fn constant_serialized_size(
    ty_layout: &MoveTypeLayout
) -> (u64, PartialVMResult<Option<usize>>) {
    let mut visited_count = 1;

    let bcs_size_result = match ty_layout {
        // 基础类型：有固定大小
        MoveTypeLayout::Bool => bcs::serialized_size(&false).map(Some),
        MoveTypeLayout::U8 => bcs::serialized_size(&0u8).map(Some),
        MoveTypeLayout::U16 => bcs::serialized_size(&0u16).map(Some),
        MoveTypeLayout::U32 => bcs::serialized_size(&0u32).map(Some),
        MoveTypeLayout::U64 => bcs::serialized_size(&0u64).map(Some),
        MoveTypeLayout::U128 => bcs::serialized_size(&0u128).map(Some),
        MoveTypeLayout::U256 => bcs::serialized_size(&int256::U256::ZERO).map(Some),
        MoveTypeLayout::Address => bcs::serialized_size(&AccountAddress::ZERO).map(Some),

        // Signer 的大小是 VM 实现细节，可能改变
        MoveTypeLayout::Signer => Ok(None),

        // Vector 没有常量大小（长度可变）
        MoveTypeLayout::Vector(_) => Ok(None),

        // 枚举和函数类型没有常量大小
        MoveTypeLayout::Struct(
            MoveStructLayout::RuntimeVariants(_) | MoveStructLayout::WithVariants(_)
        ) | MoveTypeLayout::Function => Ok(None),

        // 结构体：递归计算所有字段的大小
        MoveTypeLayout::Struct(MoveStructLayout::Runtime(fields)) => {
            let mut total = Some(0);
            for field in fields {
                let (cur_visited_count, cur) = constant_serialized_size(field);
                visited_count += cur_visited_count;

                match cur {
                    Err(e) => return (visited_count, Err(e)),
                    Ok(Some(cur_value)) => {
                        total = total.map(|v| v + cur_value);
                    },
                    Ok(None) => {
                        // 任一字段没有常量大小，整个结构体就没有
                        total = None;
                        break;
                    },
                }
            }
            Ok(total)
        },

        // Native 类型：递归检查内部类型
        MoveTypeLayout::Native(_, inner) => {
            let (cur_visited_count, cur) = constant_serialized_size(inner);
            visited_count += cur_visited_count;
            match cur {
                Err(e) => return (visited_count, Err(e)),
                Ok(v) => Ok(v),
            }
        },

        // 不应该出现的布局类型
        MoveTypeLayout::Struct(
            MoveStructLayout::WithFields(_) | MoveStructLayout::WithTypes { .. }
        ) => {
            return (
                visited_count,
                Err(PartialVMError::new(StatusCode::VALUE_SERIALIZATION_ERROR)
                    .with_message("Only runtime types expected".to_string())),
            )
        },
    };

    (
        visited_count,
        bcs_size_result.map_err(|e| {
            PartialVMError::new(StatusCode::VALUE_SERIALIZATION_ERROR)
                .with_message(format!("Failed to compute serialized size: {:?}", e))
        }),
    )
}

/// 注册函数：导出所有 native functions
///
/// 这个函数会被模块注册系统调用
pub fn make_all(
    builder: &SafeNativeBuilder,
) -> impl Iterator<Item = (String, NativeFunction)> + '_ {
    let funcs = [
        ("to_bytes", native_to_bytes as RawSafeNative),
        ("serialized_size", native_serialized_size),
        ("constant_serialized_size", native_constant_serialized_size),
    ];

    // 使用 builder 创建命名的 native functions
    builder.make_named_natives(funcs)
}
```

---

## 模块级注册

### 位置
- `aptos-move/framework/move-stdlib/src/natives/mod.rs`

### 代码

```rust
// 1. 声明子模块
pub mod bcs;
pub mod signer;
pub mod vector;
pub mod hash;
// ... 其他模块

use aptos_native_interface::SafeNativeBuilder;
use move_core_types::account_address::AccountAddress;
use move_vm_runtime::native_functions::{make_table_from_iter, NativeFunctionTable};

/// 注册所有 Move 标准库的 native functions
pub fn all_natives(
    move_std_addr: AccountAddress,
    builder: &mut SafeNativeBuilder,
) -> NativeFunctionTable {
    let mut natives = vec![];

    // 定义宏简化注册代码
    macro_rules! add_natives {
        ($module_name:expr, $natives:expr) => {
            natives.extend(
                $natives.map(|(func_name, func)| {
                    ($module_name.to_string(), func_name, func)
                }),
            );
        };
    }

    // 注册各个模块的 native functions
    builder.with_incremental_gas_charging(false, |builder| {
        add_natives!("bcs", bcs::make_all(builder));
        add_natives!("signer", signer::make_all(builder));
        add_natives!("vector", vector::make_all(builder));
        add_natives!("hash", hash::make_all(builder));
        // ... 其他模块
    });

    // 创建并返回 native function 表
    make_table_from_iter(move_std_addr, natives)
}
```

### 框架级注册

对于 Aptos Framework 的 natives（位置：`aptos-move/framework/src/natives/mod.rs`）：

```rust
pub fn all_natives(
    framework_addr: AccountAddress,
    builder: &SafeNativeBuilder,
    inject_create_signer_for_gov_sim: bool,
) -> NativeFunctionTable {
    let mut natives = vec![];

    macro_rules! add_natives_from_module {
        ($module_name:expr, $natives:expr) => {
            natives.extend(
                $natives.map(|(func_name, func)| ($module_name.to_string(), func_name, func)),
            );
        };
    }

    add_natives_from_module!("account", account::make_all(builder));
    add_natives_from_module!("type_info", type_info::make_all(builder));
    add_natives_from_module!("event", event::make_all(builder));
    // ... 其他框架模块

    make_table_from_iter(framework_addr, natives)
}
```

---

## Gas Schedule 配置

### 位置
- `aptos-move/aptos-gas-schedule/src/gas_schedule/move_stdlib.rs`

### Gas 参数定义

```rust
use crate::{
    gas_feature_versions::{RELEASE_V1_18, RELEASE_V1_24},
    gas_schedule::NativeGasParameters,
};
use aptos_gas_algebra::{
    InternalGas, InternalGasPerByte, InternalGasPerTypeNode,
};

crate::gas_schedule::macros::define_gas_parameters!(
    MoveStdlibGasParameters,
    "move_stdlib",
    NativeGasParameters => .move_stdlib,
    [
        // BCS 相关的 gas 参数
        [bcs_to_bytes_per_byte_serialized: InternalGasPerByte,
            "bcs.to_bytes.per_byte_serialized",
            36],

        [bcs_to_bytes_failure: InternalGas,
            "bcs.to_bytes.failure",
            3676],

        [bcs_serialized_size_base: InternalGas,
            { RELEASE_V1_18.. => "bcs.serialized_size.base" },
            735],

        [bcs_serialized_size_per_byte_serialized: InternalGasPerByte,
            { RELEASE_V1_18.. => "bcs.serialized_size.per_byte_serialized" },
            36],

        [bcs_serialized_size_failure: InternalGas,
            { RELEASE_V1_18.. => "bcs.serialized_size.failure" },
            3676],

        // constant_serialized_size 的 gas 参数
        [bcs_constant_serialized_size_base: InternalGas,
            { RELEASE_V1_24.. => "bcs.constant_serialized_size.base" },
            735],

        [bcs_constant_serialized_size_per_type_node: InternalGasPerTypeNode,
            { RELEASE_V1_24.. => "bcs.constant_serialized_size.per_type_node" },
            40],

        // Signer 相关
        [signer_borrow_address_base: InternalGas,
            "signer.borrow_address.base",
            735],

        // 其他参数...
    ]
);
```

### Gas 参数说明

| 参数名 | 类型 | 链上键名 | 初始值 | 说明 |
|--------|------|----------|--------|------|
| `bcs_constant_serialized_size_base` | `InternalGas` | `"bcs.constant_serialized_size.base"` | 735 | 基础固定费用 |
| `bcs_constant_serialized_size_per_type_node` | `InternalGasPerTypeNode` | `"bcs.constant_serialized_size.per_type_node"` | 40 | 每访问一个类型节点的费用 |

### 版本控制

```rust
{ RELEASE_V1_24.. => "bcs.constant_serialized_size.base" }
```

- `RELEASE_V1_24..`：表示从 v1.24 版本开始生效
- 在此之前的版本不会使用这个参数
- 支持版本化的 gas 参数管理

### Gas 计费逻辑

```
总 Gas 费用 = 基础费用 + (每节点费用 × 访问的节点数量)
           = BCS_CONSTANT_SERIALIZED_SIZE_BASE +
             (BCS_CONSTANT_SERIALIZED_SIZE_PER_TYPE_NODE × visited_count)
```

**示例**：
- 简单类型 `u64`：`visited_count = 1`，费用 = `735 + 40 × 1 = 775`
- 包含 10 个字段的结构体：`visited_count ≈ 11`，费用 = `735 + 40 × 11 = 1175`

### Gas 类型说明

| Gas 类型 | 说明 | 使用场景 |
|---------|------|---------|
| `InternalGas` | 固定的 gas 量 | 基础费用、固定操作 |
| `InternalGasPerByte` | 每字节的 gas | 数据序列化、哈希计算 |
| `InternalGasPerArg` | 每参数/每项的 gas | 循环处理、批量操作 |
| `InternalGasPerTypeNode` | 每类型节点的 gas | 类型遍历、递归分析 |
| `InternalGasPerAbstractValueUnit` | 每抽象值单元的 gas | 值比较、深度复制 |

### 宏生成的代码

`define_gas_parameters!` 宏会生成：

```rust
// 1. 参数结构体
pub struct MoveStdlibGasParameters {
    pub bcs_constant_serialized_size_base: InternalGas,
    pub bcs_constant_serialized_size_per_type_node: InternalGasPerTypeNode,
    // ...
}

// 2. 常量（供 native function 使用）
pub mod gas_params {
    pub struct BCS_CONSTANT_SERIALIZED_SIZE_BASE;
    pub struct BCS_CONSTANT_SERIALIZED_SIZE_PER_TYPE_NODE;
    // ...

    // 实现 GasExpression trait，用于计算 gas
    impl GasExpression for BCS_CONSTANT_SERIALIZED_SIZE_BASE {
        fn evaluate(&self, gas_params: &GasParams) -> InternalGas {
            gas_params.move_stdlib.bcs_constant_serialized_size_base
        }
    }
}

// 3. 初始值方法
impl InitialGasSchedule for MoveStdlibGasParameters {
    fn initial() -> Self {
        Self {
            bcs_constant_serialized_size_base: 735.into(),
            bcs_constant_serialized_size_per_type_node: 40.into(),
            // ...
        }
    }
}

// 4. 从链上加载
impl FromOnChainGasSchedule for MoveStdlibGasParameters {
    fn from_on_chain_gas_schedule(
        gas_schedule: &BTreeMap<String, u64>,
        feature_version: u64,
    ) -> Result<Self, String> {
        // 根据 feature_version 从 gas_schedule 映射中加载参数
        // ...
    }
}

// 5. 保存到链上
impl ToOnChainGasSchedule for MoveStdlibGasParameters {
    fn to_on_chain_gas_schedule(&self, feature_version: u64) -> Vec<(String, u64)> {
        // 将参数序列化为 (key, value) 对
        // ...
    }
}
```

---

## 关键 API 说明

### SafeNativeContext 方法

```rust
/// Gas 计费
context.charge(gas_cost)?;

/// 获取类型布局（用于类型分析）
let layout = context.type_to_type_layout(&ty)?;

/// 获取 feature flags
let flags = context.get_feature_flags();
if flags.is_enum_option_enabled() {
    // ...
}

/// 获取其他上下文信息
let extension = context.function_value_extension();
let max_depth = context.max_value_nest_depth();
```

### 参数处理宏

```rust
// 安全地弹出参数（注意：按与 Move 相反的顺序）
let arg1 = safely_pop_arg!(args, u64);
let arg2 = safely_pop_arg!(args, Reference);
let arg3 = safely_pop_arg!(args, VectorRef);
let arg4 = safely_pop_arg!(args, SignerRef);
```

**重要**：参数需要反向弹出！如果 Move 中是 `fun foo(a: u64, b: u64)`，Rust 中要先弹出 `b`，再弹出 `a`。

### 返回值构造

```rust
// 返回单个值
Ok(smallvec![Value::u64(result)])

// 返回多个值
Ok(smallvec![Value::u64(val1), Value::bool(val2)])

// 返回空（unit type）
Ok(smallvec![])

// 返回 Option<u64>（需要根据 feature flag 选择格式）
let enum_option_enabled = context.get_feature_flags().is_enum_option_enabled();
if enum_option_enabled {
    // 新格式：enum Option
    match value {
        Some(v) => Ok(smallvec![Value::struct_(Struct::pack_variant(
            OPTION_SOME_TAG,
            vec![Value::u64(v)]
        ))]),
        None => Ok(smallvec![Value::struct_(Struct::pack_variant(
            OPTION_NONE_TAG,
            vec![]
        ))]),
    }
} else {
    // 旧格式：struct Option { vec: vector<u64> }
    Ok(smallvec![Value::struct_(Struct::pack(vec![
        Value::vector_u64(value)
    ]))])
}

// 返回错误/Abort
Err(SafeNativeError::Abort {
    abort_code: ERROR_CODE
})

// 返回 VM 错误
Err(SafeNativeError::InvariantViolation(
    PartialVMError::new(StatusCode::INTERNAL_TYPE_ERROR)
))
```

### Value 类型构造

```rust
// 基础类型
Value::bool(true)
Value::u8(255)
Value::u64(12345)
Value::u128(99999)
Value::address(AccountAddress::ZERO)

// 复合类型
Value::vector_u8(vec![1, 2, 3])
Value::vector_u64(Some(42))  // 用于 Option<u64>
Value::struct_(Struct::pack(vec![field1, field2]))
Value::struct_(Struct::pack_variant(tag, vec![field1]))
```

---

## 完整实现示例

假设你要实现一个自定义的 native function 模块。

### 示例：实现一个数学工具模块

#### Step 1: Move 声明

创建文件：`sources/math_utils.move`

```move
module std::math_utils {
    /// 计算两个 u64 数字的乘积，溢出时 abort
    native public fun multiply(a: u64, b: u64): u64;

    /// 检查某个类型是否为原始类型
    native public fun is_primitive<T>(): bool;

    /// 计算数组中所有元素的和
    native public fun sum_vector(v: &vector<u64>): u64;
}
```

#### Step 2: Rust 实现

创建文件：`src/natives/math_utils.rs`

```rust
use aptos_gas_schedule::gas_params::natives::move_stdlib::*;
use aptos_native_interface::{
    safely_pop_arg, RawSafeNative, SafeNativeBuilder, SafeNativeContext,
    SafeNativeError, SafeNativeResult,
};
use move_vm_runtime::native_functions::NativeFunction;
use move_vm_types::{
    loaded_data::runtime_types::Type,
    values::{Value, VectorRef},
};
use smallvec::{smallvec, SmallVec};
use std::collections::VecDeque;

// 错误码
const E_OVERFLOW: u64 = 0x010001;

/// 实现 multiply 函数
fn native_multiply(
    context: &mut SafeNativeContext,
    _ty_args: Vec<Type>,
    mut args: VecDeque<Value>,
) -> SafeNativeResult<SmallVec<[Value; 1]>> {
    debug_assert!(args.len() == 2);

    // 反向弹出参数
    let b = safely_pop_arg!(args, u64);
    let a = safely_pop_arg!(args, u64);

    // 收取基础 gas
    context.charge(MATH_MULTIPLY_BASE)?;

    // 执行计算，检查溢出
    let result = a.checked_mul(b).ok_or_else(|| SafeNativeError::Abort {
        abort_code: E_OVERFLOW,
    })?;

    Ok(smallvec![Value::u64(result)])
}

/// 实现 is_primitive 函数
fn native_is_primitive(
    context: &mut SafeNativeContext,
    mut ty_args: Vec<Type>,
    _args: VecDeque<Value>,
) -> SafeNativeResult<SmallVec<[Value; 1]>> {
    debug_assert!(ty_args.len() == 1);

    context.charge(MATH_IS_PRIMITIVE_BASE)?;

    let ty = ty_args.pop().unwrap();
    let layout = context.type_to_type_layout(&ty)?;

    use move_core_types::value::MoveTypeLayout;
    let is_prim = matches!(
        layout,
        MoveTypeLayout::Bool
            | MoveTypeLayout::U8
            | MoveTypeLayout::U16
            | MoveTypeLayout::U32
            | MoveTypeLayout::U64
            | MoveTypeLayout::U128
            | MoveTypeLayout::U256
            | MoveTypeLayout::Address
    );

    Ok(smallvec![Value::bool(is_prim)])
}

/// 实现 sum_vector 函数
fn native_sum_vector(
    context: &mut SafeNativeContext,
    _ty_args: Vec<Type>,
    mut args: VecDeque<Value>,
) -> SafeNativeResult<SmallVec<[Value; 1]>> {
    debug_assert!(args.len() == 1);

    context.charge(MATH_SUM_VECTOR_BASE)?;

    let vec_ref = safely_pop_arg!(args, VectorRef);
    let len = vec_ref.len()?;

    // 根据向量长度收取额外 gas
    context.charge(MATH_SUM_VECTOR_PER_ELEMENT * NumArgs::new(len as u64))?;

    let mut sum: u64 = 0;
    for i in 0..len {
        let elem_ref = vec_ref.borrow_elem(i)?;
        let val = elem_ref.read_ref()?.value_as::<u64>()?;
        sum = sum.checked_add(val).ok_or_else(|| SafeNativeError::Abort {
            abort_code: E_OVERFLOW,
        })?;
    }

    Ok(smallvec![Value::u64(sum)])
}

/// 导出所有 native functions
pub fn make_all(
    builder: &SafeNativeBuilder,
) -> impl Iterator<Item = (String, NativeFunction)> + '_ {
    let natives = [
        ("multiply", native_multiply as RawSafeNative),
        ("is_primitive", native_is_primitive),
        ("sum_vector", native_sum_vector),
    ];
    builder.make_named_natives(natives)
}
```

#### Step 3: 模块注册

编辑文件：`src/natives/mod.rs`

```rust
pub mod bcs;
pub mod signer;
pub mod math_utils;  // 添加新模块
// ...

pub fn all_natives(
    move_std_addr: AccountAddress,
    builder: &mut SafeNativeBuilder,
) -> NativeFunctionTable {
    let mut natives = vec![];

    macro_rules! add_natives {
        ($module_name:expr, $natives:expr) => {
            natives.extend(
                $natives.map(|(func_name, func)| ($module_name.to_string(), func_name, func)),
            );
        };
    }

    builder.with_incremental_gas_charging(false, |builder| {
        add_natives!("bcs", bcs::make_all(builder));
        add_natives!("signer", signer::make_all(builder));
        add_natives!("math_utils", math_utils::make_all(builder));  // 注册新模块
        // ...
    });

    make_table_from_iter(move_std_addr, natives)
}
```

#### Step 4: Gas 参数配置

编辑文件：`aptos-move/aptos-gas-schedule/src/gas_schedule/move_stdlib.rs`

```rust
crate::gas_schedule::macros::define_gas_parameters!(
    MoveStdlibGasParameters,
    "move_stdlib",
    NativeGasParameters => .move_stdlib,
    [
        // ... 现有参数

        // 新增的 math_utils 模块的 gas 参数
        [math_multiply_base: InternalGas,
            { RELEASE_V1_24.. => "math_utils.multiply.base" },
            500],

        [math_is_primitive_base: InternalGas,
            { RELEASE_V1_24.. => "math_utils.is_primitive.base" },
            400],

        [math_sum_vector_base: InternalGas,
            { RELEASE_V1_24.. => "math_utils.sum_vector.base" },
            800],

        [math_sum_vector_per_element: InternalGasPerArg,
            { RELEASE_V1_24.. => "math_utils.sum_vector.per_element" },
            50],
    ]
);
```

---

## 重要注意事项

### 1. 参数顺序

**关键点**：Rust 端需要**反向**弹出参数（栈的 LIFO 特性）

```move
// Move 声明
native fun foo(a: u64, b: u64, c: u64): u64;
```

```rust
// Rust 实现 - 注意顺序！
fn native_foo(
    context: &mut SafeNativeContext,
    _ty_args: Vec<Type>,
    mut args: VecDeque<Value>,
) -> SafeNativeResult<SmallVec<[Value; 1]>> {
    let c = safely_pop_arg!(args, u64);  // 最后一个参数先弹出
    let b = safely_pop_arg!(args, u64);
    let a = safely_pop_arg!(args, u64);  // 第一个参数最后弹出
    // ...
}
```

### 2. Gas 计费

**所有** native function 都必须合理计费：

- 在函数开始时收取基础费用
- 根据操作复杂度收取额外费用
- 失败路径也要收取相应费用

```rust
// ✓ 正确
context.charge(BASE_COST)?;
// ... 执行操作
context.charge(PER_ITEM_COST * NumArgs::new(count))?;

// ✗ 错误 - 忘记计费
// ... 执行操作
```

### 3. 错误处理

使用 `SafeNativeError` 返回错误：

```rust
// Abort（Move 中可捕获）
Err(SafeNativeError::Abort {
    abort_code: ERROR_CODE
})

// VM 错误（不可捕获）
Err(SafeNativeError::InvariantViolation(
    PartialVMError::new(StatusCode::INTERNAL_TYPE_ERROR)
))
```

### 4. 类型安全

- 使用 `safely_pop_arg!` 宏确保类型安全
- 添加 `debug_assert!` 验证参数数量
- 正确处理泛型类型参数

```rust
// ✓ 正确
debug_assert!(ty_args.len() == 1);
debug_assert!(args.len() == 2);
let arg = safely_pop_arg!(args, u64);

// ✗ 错误
let arg = args.pop_back().unwrap().value_as::<u64>()?;  // 不安全
```

### 5. 文档注释

为 Move 函数添加清晰的文档：

```move
/// 计算两个数字的乘积
///
/// # 参数
/// - `a`: 第一个数字
/// - `b`: 第二个数字
///
/// # 返回值
/// 返回 `a * b` 的结果
///
/// # Aborts
/// 如果结果溢出，会 abort，错误码为 `E_OVERFLOW`
///
/// # 示例
/// ```
/// let result = math_utils::multiply(10, 20); // result = 200
/// ```
native public fun multiply(a: u64, b: u64): u64;
```

### 6. Feature Flags

根据链的版本使用不同的行为：

```rust
let flags = context.get_feature_flags();

if flags.is_enum_option_enabled() {
    // 使用新的 enum Option 格式
} else {
    // 使用旧的 struct Option 格式
}

if flags.is_lazy_loading_enabled() {
    // 使用懒加载
}
```

### 7. 性能考虑

- 避免不必要的深拷贝（`read_ref()` 会进行深拷贝）
- 合理设置 gas 参数以反映实际成本
- 使用 `SmallVec` 优化小向量的性能

```rust
// 如果可能，避免读取整个值
let vec_ref = safely_pop_arg!(args, VectorRef);
let len = vec_ref.len()?;  // ✓ 只获取长度

// 而不是
let vec = safely_pop_arg!(args, Vector);
let len = vec.len();  // ✗ 可能已经进行了深拷贝
```

### 8. 测试

为你的 native function 编写完整的测试：

```move
#[test]
fun test_multiply() {
    let result = math_utils::multiply(10, 20);
    assert!(result == 200, 0);
}

#[test]
#[expected_failure(abort_code = 0x010001)]
fun test_multiply_overflow() {
    math_utils::multiply(0xFFFFFFFFFFFFFFFF, 2);
}

#[test]
fun test_is_primitive() {
    assert!(math_utils::is_primitive<u64>() == true, 0);
    assert!(math_utils::is_primitive<vector<u8>>() == false, 1);
}
```

---

## 文件位置总结

| 组件 | 文件路径 | 说明 |
|------|---------|------|
| Move 声明 | `aptos-move/framework/move-stdlib/sources/bcs.move:28` | native function 的 Move 接口 |
| Rust 实现 | `aptos-move/framework/move-stdlib/src/natives/bcs.rs:174-280` | native function 的具体实现 |
| 模块导出 | `aptos-move/framework/move-stdlib/src/natives/bcs.rs:286-296` | `make_all` 函数 |
| 模块注册 | `aptos-move/framework/move-stdlib/src/natives/mod.rs:22-51` | 注册到 Move VM |
| Gas 参数 | `aptos-move/aptos-gas-schedule/src/gas_schedule/move_stdlib.rs:45-46` | Gas 计费参数定义 |
| 框架集成 | `aptos-move/framework/src/natives/mod.rs:42-117` | Aptos Framework 级别的注册 |

---

## 参考资料

### 相关代码示例

- **简单示例**：`signer::borrow_address` - 最简单的 native function
- **类型参数示例**：`bcs::constant_serialized_size` - 使用泛型参数
- **引用参数示例**：`vector::move_range` - 操作引用类型
- **复杂逻辑示例**：`bcs::to_bytes` - 完整的序列化逻辑

### Gas Schedule 流程图

```
┌──────────────────────────────────────┐
│ gas_schedule/move_stdlib.rs         │
│ 定义 Gas 参数及初始值                 │
│ - base: 735                          │
│ - per_type_node: 40                  │
└──────────────┬───────────────────────┘
               │ 宏生成常量
               ▼
┌──────────────────────────────────────┐
│ gas_params::move_stdlib::*           │
│ BCS_CONSTANT_SERIALIZED_SIZE_BASE    │
│ BCS_CONSTANT_SERIALIZED_SIZE_PER...  │
└──────────────┬───────────────────────┘
               │ 导入使用
               ▼
┌──────────────────────────────────────┐
│ natives/bcs.rs                       │
│ native_constant_serialized_size()    │
│ - context.charge(BASE)               │
│ - context.charge(PER_NODE × count)   │
└──────────────────────────────────────┘
```

---

## 完整开发检查清单

实现一个新的 native function 时，确保完成以下步骤：

- [ ] 在 `.move` 文件中添加 `native` 函数声明
- [ ] 添加详细的文档注释（参数、返回值、Aborts、示例）
- [ ] 在 `src/natives/` 中创建或编辑对应的 Rust 文件
- [ ] 实现 native function，确保：
  - [ ] 参数按反向顺序弹出
  - [ ] 收取合理的 gas 费用
  - [ ] 正确处理错误情况
  - [ ] 使用 `debug_assert!` 验证参数
- [ ] 实现 `make_all` 函数导出 natives
- [ ] 在 `mod.rs` 中注册模块
- [ ] 在 gas schedule 中添加 gas 参数
- [ ] 编写单元测试（正常情况 + 边界情况 + 错误情况）
- [ ] 运行测试确保功能正确
- [ ] 检查 gas 参数是否合理
- [ ] 更新相关文档

---

**最后更新**: 2025-11-10
**适用版本**: Aptos Core (基于代码库当前状态)
