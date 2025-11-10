# Move Native 函数和字节码指令详解

## 目录
- [概述](#概述)
- [两种Native函数类型](#两种native函数类型)
- [#[bytecode_instruction] 详解](#bytecode_instruction-详解)
- [真Native函数详解](#真native函数详解)
- [实现位置](#实现位置)
- [性能对比](#性能对比)
- [使用场景](#使用场景)
- [完整示例](#完整示例)

---

## 概述

Move语言中的 `native` 函数有两种实现方式：

1. **字节码指令函数** - 标记为 `#[bytecode_instruction]`，编译为专用字节码指令
2. **真Native函数** - 直接由Rust代码实现的函数

这两种方式虽然在Move中都声明为 `native`，但实现机制完全不同。

---

## 两种Native函数类型

### 对比表

| 特性 | 字节码指令函数 | 真Native函数 |
|------|---------------|-------------|
| **Move声明** | `#[bytecode_instruction]`<br>`native fun foo()` | `native fun bar()` |
| **编译结果** | 专用字节码指令 | 函数调用指令 |
| **实现位置** | VM字节码解释器 | Rust native函数模块 |
| **性能** | 最优（无调用开销） | 较好（有调用开销） |
| **适用场景** | 核心语言特性 | 复杂逻辑/外部依赖 |
| **例子** | `vector::push_back` | `string::internal_check_utf8` |

### 编译器定义

来源：`move-compiler-v2/legacy-move-compiler/src/shared/mod.rs:883-887`

```rust
pub enum NativeAttribute {
    // It is a fake native function that actually compiles
    // to a bytecode instruction
    BytecodeInstruction,
    NativeInterface,
}
```

**关键点**：`#[bytecode_instruction]` 函数是**"假native函数"**（fake native functions）

---

## #[bytecode_instruction] 详解

### 1. Move声明

文件：`aptos-move/framework/move-stdlib/sources/vector.move`

```move
module std::vector {
    #[bytecode_instruction]
    /// Create an empty vector.
    native public fun empty<Element>(): vector<Element>;

    #[bytecode_instruction]
    /// Return the length of the vector.
    native public fun length<Element>(self: &vector<Element>): u64;

    #[bytecode_instruction]
    /// Add element `e` to the end of the vector `self`.
    native public fun push_back<Element>(self: &mut vector<Element>, e: Element);

    #[bytecode_instruction]
    /// Pop an element from the end of vector `self`.
    native public fun pop_back<Element>(self: &mut vector<Element>): Element;

    #[bytecode_instruction]
    /// Acquire an immutable reference to the `i`th element of the vector `self`.
    native public fun borrow<Element>(self: &vector<Element>, i: u64): &Element;

    #[bytecode_instruction]
    /// Return a mutable reference to the `i`th element in the vector `self`.
    native public fun borrow_mut<Element>(self: &mut vector<Element>, i: u64): &mut Element;

    #[bytecode_instruction]
    /// Destroy the vector `self`. Aborts if `self` is not empty.
    native public fun destroy_empty<Element>(self: vector<Element>);

    #[bytecode_instruction]
    /// Swaps the elements at the `i`th and `j`th indices in the vector `self`.
    native public fun swap<Element>(self: &mut vector<Element>, i: u64, j: u64);
}
```

### 2. 字节码指令定义

文件：`third_party/move/move-binary-format/src/file_format.rs:1366+`

```rust
pub enum Bytecode {
    // ... 其他指令 ...

    #[group = "vector"]
    #[description = r#"
        Return the length of the vector.
    "#]
    #[static_operands = "[elem_ty_idx]"]
    #[semantics = r#"
        stack >> vec_ref
        stack << len(*vec_ref)
    "#]
    #[runtime_check_epilogue = r#"
        elem_ty = instantiate elem_ty
        ty_stack >> ty
        assert ty == &vector<elem_ty> or ty == &mut vector<elem_ty>
        ty_stack << u64
    "#]
    #[gas_type_creation_tier_0 = "elem_ty"]
    VecLen(SignatureIndex),

    #[group = "vector"]
    #[description = "Add an element to the end of the vector."]
    #[static_operands = "[elem_ty_idx]"]
    #[semantics = r#"
        stack >> val
        stack >> vec_ref
        (*vec_ref) << val
    "#]
    #[runtime_check_epilogue = r#"
        ty_stack >> val_ty
        assert val_ty == elem_ty
        ty_stack >> ref_ty
        assert ref_ty == &mut vector<elem_ty>
    "#]
    VecPushBack(SignatureIndex),

    #[group = "vector"]
    #[description = r#"
        Pop an element from the end of vector.
        Aborts if the vector is empty.
    "#]
    #[static_operands = "[elem_ty_idx]"]
    #[semantics = r#"
        stack >> vec_ref
        (*vec_ref) >> val
        stack << val
    "#]
    #[runtime_check_epilogue = r#"
        ty_stack >> ref_ty
        assert ref_ty == &mut vector<elem_ty>
        ty_stack << val_ty
    "#]
    VecPopBack(SignatureIndex),

    #[group = "vector"]
    #[description = r#"
        Acquire an immutable reference to the element at a given index of the vector.
        Abort the execution if the index is out of bounds.
    "#]
    VecImmBorrow(SignatureIndex),

    #[group = "vector"]
    #[description = r#"
        Acquire a mutable reference to the element at a given index of the vector.
        Abort the execution if the index is out of bounds.
    "#]
    VecMutBorrow(SignatureIndex),

    #[group = "vector"]
    VecSwap(SignatureIndex),

    #[group = "vector"]
    #[description = "Create a vector of provided length by providing each element value"]
    VecPack(SignatureIndex, u64),

    #[group = "vector"]
    #[description = r#"
        Destroy the vector and unpack a statically known number of elements onto the stack.
        Abort if the vector does not have a length `n`.
    "#]
    VecUnpack(SignatureIndex, u64),

    // ... 其他指令 ...
}
```

### 3. VM解释器实现

文件：`third_party/move/move-vm/runtime/src/interpreter.rs:2808-2868`

```rust
// 字节码解释器执行循环
match instruction {
    Bytecode::VecLen(si) => {
        // 从操作数栈弹出向量引用
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 获取类型信息
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;

        // Gas计费
        gas_meter.charge_create_ty(ty_count)?;
        gas_meter.charge_vec_len()?;

        // 执行操作：获取向量长度
        let value = vec_ref.len()?;

        // 将结果推入操作数栈
        interpreter.operand_stack.push(value)?;
    },

    Bytecode::VecPushBack(si) => {
        // 弹出元素和向量引用
        let elem = interpreter.operand_stack.pop()?;
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 类型检查和Gas计费
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;
        gas_meter.charge_create_ty(ty_count)?;
        gas_meter.charge_vec_push_back(&elem)?;

        // 执行操作：追加元素
        vec_ref.push_back(elem)?;
    },

    Bytecode::VecPopBack(si) => {
        // 弹出向量引用
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 类型检查和Gas计费
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;
        gas_meter.charge_create_ty(ty_count)?;

        // 执行操作：弹出最后一个元素
        let res = vec_ref.pop();
        gas_meter.charge_vec_pop_back(res.as_ref().ok())?;

        // 将结果推入栈
        interpreter.operand_stack.push(res?)?;
    },

    Bytecode::VecSwap(si) => {
        // 弹出两个索引和向量引用
        let idx2 = interpreter.operand_stack.pop_as::<u64>()? as usize;
        let idx1 = interpreter.operand_stack.pop_as::<u64>()? as usize;
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 类型检查和Gas计费
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;
        gas_meter.charge_create_ty(ty_count)?;
        gas_meter.charge_vec_swap()?;

        // 执行操作：交换两个元素
        vec_ref.swap(idx1, idx2)?;
    },

    Bytecode::VecImmBorrow(si) => {
        // 弹出索引和向量引用
        let idx = interpreter.operand_stack.pop_as::<u64>()? as usize;
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 类型检查和Gas计费
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;
        gas_meter.charge_create_ty(ty_count)?;
        gas_meter.charge_vec_borrow(false)?;

        // 执行操作：借用元素
        let elem = vec_ref.borrow_elem(idx)?;
        interpreter.operand_stack.push(elem)?;
    },

    Bytecode::VecMutBorrow(si) => {
        // 弹出索引和向量引用
        let idx = interpreter.operand_stack.pop_as::<u64>()? as usize;
        let vec_ref = interpreter.operand_stack.pop_as::<VectorRef>()?;

        // 类型检查和Gas计费
        let (_, ty_count) = frame_cache.get_signature_index_type(*si, self)?;
        gas_meter.charge_create_ty(ty_count)?;
        gas_meter.charge_vec_borrow(true)?;

        // 执行操作：可变借用元素
        let elem = vec_ref.borrow_elem(idx)?;
        interpreter.operand_stack.push(elem)?;
    },

    // ... 其他字节码指令 ...
}
```

### 4. 执行流程

```
Move代码:
┌─────────────────────────────────────────┐
│ let mut v = vector::empty<u64>();      │
│ vector::push_back(&mut v, 42);         │
│ let len = vector::length(&v);          │
└─────────────────────────────────────────┘
            ↓ 编译
┌─────────────────────────────────────────┐
│ VecPack(sig_idx, 0)      // empty      │
│ VecPushBack(sig_idx)     // push_back  │
│ VecLen(sig_idx)          // length     │
└─────────────────────────────────────────┘
            ↓ 执行
┌─────────────────────────────────────────┐
│ Interpreter::execute_instruction() {    │
│   match bytecode {                      │
│     VecPack => create_vector(),         │
│     VecPushBack => vec.push(),          │
│     VecLen => vec.len(),                │
│   }                                     │
│ }                                       │
└─────────────────────────────────────────┘
```

---

## 真Native函数详解

### 1. Move声明

文件：`aptos-move/framework/move-stdlib/sources/string.move`

```move
module std::string {
    struct String has copy, drop, store {
        bytes: vector<u8>,
    }

    /// Creates a new string from a sequence of bytes.
    /// Aborts if the bytes do not represent valid utf8.
    public fun utf8(bytes: vector<u8>): String {
        assert!(internal_check_utf8(&bytes), EINVALID_UTF8);
        String{bytes}
    }

    // Native API - 真native函数
    public native fun internal_check_utf8(v: &vector<u8>): bool;
    native fun internal_is_char_boundary(v: &vector<u8>, i: u64): bool;
    native fun internal_sub_string(v: &vector<u8>, i: u64, j: u64): vector<u8>;
    native fun internal_index_of(v: &vector<u8>, r: &vector<u8>): u64;
}
```

### 2. Rust实现

文件：`aptos-move/framework/src/natives/string.rs` (示例)

```rust
use move_binary_format::errors::PartialVMResult;
use move_core_types::gas_algebra::InternalGas;
use move_vm_runtime::native_functions::{NativeContext, NativeFunction};
use move_vm_types::{
    loaded_data::runtime_types::Type,
    natives::function::NativeResult,
    values::Value,
};
use smallvec::smallvec;
use std::collections::VecDeque;

/// Native function: internal_check_utf8
///
/// 检查给定的字节序列是否是有效的UTF-8编码
pub fn native_internal_check_utf8(
    _context: &mut NativeContext,
    _ty_args: Vec<Type>,
    mut arguments: VecDeque<Value>,
) -> PartialVMResult<NativeResult> {
    debug_assert!(_ty_args.is_empty());
    debug_assert!(arguments.len() == 1);

    // 从参数中提取字节向量的引用
    let bytes_ref = pop_arg!(arguments, Vec<u8>);

    // 调用标准库检查UTF-8有效性
    let is_valid = std::str::from_utf8(&bytes_ref).is_ok();

    // 计算Gas消耗（基于字节长度）
    let cost = InternalGas::new(bytes_ref.len() as u64);

    // 返回结果
    Ok(NativeResult::ok(
        cost,
        smallvec![Value::bool(is_valid)]
    ))
}

/// Native function 注册表
pub fn make_all_string_natives() -> Vec<(String, NativeFunction)> {
    vec![
        (
            "internal_check_utf8".to_string(),
            native_internal_check_utf8 as NativeFunction,
        ),
        // ... 其他native函数
    ]
}
```

### 3. 执行流程

```
Move代码:
┌─────────────────────────────────────────┐
│ let s = string::utf8(b"Hello");        │
│   → internal_check_utf8(&bytes)        │
└─────────────────────────────────────────┘
            ↓ 编译
┌─────────────────────────────────────────┐
│ Call internal_check_utf8               │
│   (函数调用指令)                         │
└─────────────────────────────────────────┘
            ↓ 执行
┌─────────────────────────────────────────┐
│ Interpreter::execute_call() {           │
│   if function.is_native() {             │
│     // 查找并调用Rust native函数         │
│     native_functions.call(              │
│       "internal_check_utf8",            │
│       context, ty_args, args            │
│     )                                   │
│   }                                     │
│ }                                       │
└─────────────────────────────────────────┘
            ↓
┌─────────────────────────────────────────┐
│ native_internal_check_utf8() {          │
│   // Rust实现                           │
│   std::str::from_utf8(&bytes).is_ok()  │
│ }                                       │
└─────────────────────────────────────────┘
```

### 4. 其他真Native函数示例

#### 示例1：create_signer (友元原生函数)

文件：`aptos-framework/sources/create_signer.move`

```move
module aptos_framework::create_signer {
    friend aptos_framework::account;
    friend aptos_framework::genesis;
    friend aptos_framework::coin;

    /// 创建一个signer - 只能由友元模块调用
    /// 实现位置：aptos-move/framework/src/natives/create_signer.rs
    public(friend) native fun create_signer(addr: address): signer;
}
```

#### 示例2：mem::swap (友元字节码指令)

文件：`move-stdlib/sources/mem.move`

```move
module std::mem {
    friend std::vector;
    friend std::option;

    /// Swap contents of two passed mutable references.
    ///
    /// 注意：这是 native friend fun 语法
    /// 但标记为字节码指令，所以编译为专用字节码
    native friend fun swap<T>(left: &mut T, right: &mut T);

    /// Replace the value reference points to with the given new value
    friend fun replace<T>(ref: &mut T, new: T): T {
        swap(ref, &mut new);
        new
    }
}
```

---

## 实现位置

### 字节码指令函数的实现

```
1. Move声明
   ↓
   aptos-move/framework/move-stdlib/sources/vector.move

2. 字节码定义
   ↓
   third_party/move/move-binary-format/src/file_format.rs
   pub enum Bytecode { VecPushBack(...), VecLen(...), ... }

3. VM解释器执行
   ↓
   third_party/move/move-vm/runtime/src/interpreter.rs
   match instruction { Bytecode::VecPushBack => { ... } }
```

### 真Native函数的实现

```
1. Move声明
   ↓
   aptos-move/framework/move-stdlib/sources/string.move
   public native fun internal_check_utf8(v: &vector<u8>): bool;

2. Rust实现
   ↓
   aptos-move/framework/src/natives/string.rs
   pub fn native_internal_check_utf8(...) -> NativeResult { ... }

3. Native函数注册
   ↓
   aptos-move/framework/src/natives/mod.rs
   pub fn all_natives(...) -> NativeFunctionTable {
       string::make_all_natives(),
       ...
   }

4. VM调用
   ↓
   third_party/move/move-vm/runtime/src/interpreter.rs
   if function.is_native() {
       native_functions.call(module, function_name, ...)
   }
```

---

## 性能对比

### 调用开销对比

| 操作 | 字节码指令 | 真Native函数 |
|------|-----------|-------------|
| **指令分发** | 1次switch | 1次switch + 函数查找 |
| **函数调用** | 无 | 有（Rust函数调用） |
| **类型检查** | 字节码验证时完成 | 运行时检查 |
| **参数传递** | 直接操作数栈 | 需要打包参数 |
| **总开销** | ~5-10 CPU cycles | ~50-100 CPU cycles |

### 性能测试示例

```move
// 场景：向vector添加1000个元素

// 使用字节码指令 (vector::push_back)
public fun test_bytecode_instruction() {
    let v = vector::empty<u64>();
    let i = 0;
    while (i < 1000) {
        v.push_back(i);  // 直接字节码：VecPushBack
        i = i + 1;
    }
}
// 性能：~10,000 gas

// 假设使用native函数实现
public native fun native_push_back<T>(v: &mut vector<T>, elem: T);

public fun test_native_function() {
    let v = vector::empty<u64>();
    let i = 0;
    while (i < 1000) {
        native_push_back(&mut v, i);  // 函数调用开销
        i = i + 1;
    }
}
// 性能：~15,000 gas (慢50%)
```

---

## 使用场景

### 应该使用 #[bytecode_instruction] 的场景

✅ **核心语言特性**
- 向量操作：empty, length, push_back, pop_back, borrow, swap
- 引用操作：borrow, borrow_mut
- 类型操作：cast, pack, unpack

✅ **高频操作**
- 每个交易可能调用数百次的操作
- 性能关键路径上的操作

✅ **需要VM级别类型安全的操作**
- 需要在字节码验证时进行类型检查
- 涉及泛型类型参数的操作

✅ **与VM状态紧密耦合的操作**
- 操作数栈管理
- 局部变量访问

### 应该使用真Native函数的场景

✅ **复杂业务逻辑**
- 密码学操作：hash, signature verification
- 序列化/反序列化：BCS, JSON
- 字符串处理：UTF-8验证, 子串查找

✅ **外部依赖**
- 需要调用Rust标准库
- 需要使用第三方crate
- 需要访问系统资源

✅ **不频繁调用的操作**
- 初始化函数
- 配置函数
- 一次性操作

✅ **复杂错误处理**
- 需要详细错误信息
- 需要多种失败模式

### 对比示例

```move
// ✅ 正确：vector::push_back 使用字节码指令
#[bytecode_instruction]
native public fun push_back<Element>(self: &mut vector<Element>, e: Element);
// 原因：高频操作，性能关键

// ✅ 正确：string::internal_check_utf8 使用真native
public native fun internal_check_utf8(v: &vector<u8>): bool;
// 原因：复杂逻辑（UTF-8验证），需要Rust标准库

// ✅ 正确：hash::sha2_256 使用真native
public native fun sha2_256(data: vector<u8>): vector<u8>;
// 原因：密码学操作，依赖专业库

// ❌ 错误：不应该把复杂逻辑做成字节码指令
// #[bytecode_instruction]  // 错误！
// native fun complex_business_logic();
// 原因：业务逻辑应该用Move实现或真native函数
```

---

## 完整示例

### 示例1：使用字节码指令实现栈

```move
module example::stack {
    use std::vector;

    struct Stack<T: store> has store {
        items: vector<T>,
    }

    public fun new<T: store>(): Stack<T> {
        Stack {
            items: vector::empty()  // 字节码指令：VecPack
        }
    }

    public fun push<T: store>(self: &mut Stack<T>, item: T) {
        // 字节码指令：VecPushBack
        self.items.push_back(item);
    }

    public fun pop<T: store>(self: &mut Stack<T>): T {
        // 字节码指令：VecPopBack
        self.items.pop_back()
    }

    public fun size<T: store>(self: &Stack<T>): u64 {
        // 字节码指令：VecLen
        self.items.length()
    }

    public fun is_empty<T: store>(self: &Stack<T>): bool {
        // 字节码指令：VecLen
        self.items.length() == 0
    }
}

// 编译后的字节码（简化）：
// push:
//   LdU8 items_field_index
//   MoveField              // 获取 items 字段的引用
//   MoveLoc item           // 加载 item 参数
//   VecPushBack            // 字节码指令！
//   Ret
//
// pop:
//   LdU8 items_field_index
//   MoveField
//   VecPopBack             // 字节码指令！
//   Ret
```

### 示例2：混合使用字节码指令和真Native

```move
module example::secure_storage {
    use std::vector;
    use std::hash;  // 假设有hash模块

    struct SecureData has store {
        encrypted: vector<u8>,
        checksum: vector<u8>,
    }

    /// 存储加密数据
    /// 使用：字节码指令(vector) + 真native(hash)
    public fun store(data: vector<u8>, key: vector<u8>): SecureData {
        // 1. 加密数据（真native函数）
        let encrypted = encrypt_native(data, key);

        // 2. 计算校验和（真native函数）
        let checksum = hash::sha2_256(encrypted);

        // 3. 创建结构体（使用字节码指令操作vector）
        SecureData {
            encrypted,   // vector操作由字节码指令处理
            checksum,    // vector操作由字节码指令处理
        }
    }

    /// 读取加密数据
    public fun load(secure: &SecureData, key: vector<u8>): vector<u8> {
        // 1. 验证校验和（字节码指令 + 真native）
        let computed = hash::sha2_256(secure.encrypted);
        assert!(computed == secure.checksum, 1);

        // 2. 解密数据（真native函数）
        decrypt_native(secure.encrypted, key)
    }

    // 真Native函数声明
    native fun encrypt_native(data: vector<u8>, key: vector<u8>): vector<u8>;
    native fun decrypt_native(data: vector<u8>, key: vector<u8>): vector<u8>;
}
```

### 示例3：友元字节码指令函数

```move
module std::mem {
    friend std::vector;
    friend std::option;

    /// 交换两个可变引用的内容
    /// 注意：虽然声明为 native friend，但实际是字节码指令
    native friend fun swap<T>(left: &mut T, right: &mut T);

    /// 替换值
    friend fun replace<T>(ref: &mut T, new: T): T {
        swap(ref, &mut new);  // 调用字节码指令
        new
    }
}

module std::vector {
    use std::mem;

    /// 反转向量中的元素
    public fun reverse<Element>(self: &mut vector<Element>) {
        let len = self.length();  // 字节码指令：VecLen
        let i = 0;
        while (i < len / 2) {
            // 使用 mem::swap（字节码指令）
            let left = self.borrow_mut(i);        // VecMutBorrow
            let right = self.borrow_mut(len - i - 1);  // VecMutBorrow
            mem::swap(left, right);               // 字节码指令！
            i = i + 1;
        }
    }
}
```

---

## 总结

### 关键要点

1. **`#[bytecode_instruction]` 是性能优化手段**
   - 编译为专用字节码指令
   - 无函数调用开销
   - 适用于核心语言特性

2. **真Native函数提供灵活性**
   - Rust实现复杂逻辑
   - 可以使用外部依赖
   - 适用于业务逻辑和复杂算法

3. **两者可以配合使用**
   - Vector操作用字节码指令（高频）
   - 密码学操作用真native（复杂）
   - 字符串处理混合使用

4. **选择标准**
   - 高频操作 → 字节码指令
   - 复杂逻辑 → 真native
   - 外部依赖 → 真native
   - 核心特性 → 字节码指令

### 架构层次

```
┌─────────────────────────────────────────────────┐
│           Move 源码                              │
│  #[bytecode_instruction]      native fun        │
│  native fun foo()             bar()             │
└─────────────────────────────────────────────────┘
                    ↓ 编译
┌─────────────────────────────────────────────────┐
│           字节码                                  │
│  VecPushBack(idx)            Call bar()         │
│  VecLen(idx)                 (函数调用指令)       │
└─────────────────────────────────────────────────┘
                    ↓ 执行
┌─────────────────────────────────────────────────┐
│           VM 解释器                              │
│  match bytecode {            native_call() {    │
│    VecPushBack => {...}        lookup("bar")    │
│    VecLen => {...}             invoke_rust()    │
│  }                            }                 │
└─────────────────────────────────────────────────┘
```

### 文件索引

**Move声明**：
- `aptos-move/framework/move-stdlib/sources/vector.move:34-69`
- `aptos-move/framework/move-stdlib/sources/string.move:88-91`
- `aptos-move/framework/move-stdlib/sources/mem.move:14`

**字节码定义**：
- `third_party/move/move-binary-format/src/file_format.rs:1366+`
- `third_party/move/move-binary-format/src/file_format.rs:2608-2684`

**VM实现**：
- `third_party/move/move-vm/runtime/src/interpreter.rs:2808-2868`

**编译器定义**：
- `third_party/move/move-compiler-v2/legacy-move-compiler/src/shared/mod.rs:883-912`

---

## 参考资料

- [Move VM源码](https://github.com/move-language/move)
- [Aptos Framework](https://github.com/aptos-labs/aptos-core/tree/main/aptos-move/framework)
- [Move Binary Format](https://github.com/move-language/move/tree/main/language/move-binary-format)
