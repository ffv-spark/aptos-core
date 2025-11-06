# Move 语言版本升级指南

> 最后更新：2025-11-06
> 适用范围：Aptos Core 项目中的 Move VM 升级

## 目录

1. [概述](#概述)
2. [升级前准备](#升级前准备)
3. [升级步骤](#升级步骤)
4. [验证和测试](#验证和测试)
5. [回滚计划](#回滚计划)
6. [常见问题](#常见问题)

---

## 概述

### 升级不仅仅是更新虚拟机代码

**重要提示**：升级 Move 语言版本**不仅仅是**更新虚拟机代码。一个完整的升级涉及多个层次的修改：

```
升级范围
├── 1. 核心 Move VM (third_party/move/)
│   ├── 字节码格式更新
│   ├── 解释器逻辑
│   ├── 类型系统
│   └── 验证器
│
├── 2. Aptos VM 适配层 (aptos-move/aptos-vm/)
│   ├── VM 接口适配
│   ├── Session 管理
│   └── 错误处理
│
├── 3. 原生函数扩展 (aptos-move/framework/)
│   ├── 原生函数签名
│   ├── 原生函数实现
│   └── Gas 计量
│
├── 4. 编译器和工具链
│   ├── Move 编译器
│   ├── 字节码验证器
│   └── 调试工具
│
├── 5. Aptos Framework
│   ├── 标准库更新
│   ├── 系统模块
│   └── 接口兼容性
│
├── 6. Gas 调度表
│   ├── 新指令的 Gas 成本
│   ├── Gas 特性版本
│   └── 向后兼容性
│
└── 7. 链上治理和特性门控
    ├── 特性标志
    ├── 版本控制
    └── 软分叉机制
```

### 升级影响范围

| 组件 | 是否必须升级 | 影响程度 | 向后兼容性要求 |
|------|-------------|---------|---------------|
| Move VM 运行时 | ✅ 是 | 高 | 必须兼容旧字节码 |
| Aptos VM 适配器 | ✅ 是 | 高 | 接口保持稳定 |
| Move 编译器 | ✅ 是 | 高 | 支持多版本编译 |
| 原生函数 | ⚠️ 视情况 | 中 | 保持签名兼容 |
| Framework | ⚠️ 视情况 | 中 | 渐进式更新 |
| Gas 调度表 | ⚠️ 视情况 | 中 | 通过特性门控 |
| 工具链 | ❌ 可选 | 低 | 独立更新 |

---

## 升级前准备

### 1. 环境准备

```bash
# 1.1 备份当前工作分支
git checkout main
git pull origin main
git checkout -b backup/pre-move-upgrade-$(date +%Y%m%d)
git push origin backup/pre-move-upgrade-$(date +%Y%m%d)

# 1.2 创建升级工作分支
git checkout -b feature/move-vm-upgrade-to-vX.Y.Z

# 1.3 确保本地环境干净
git status
cargo clean

# 1.4 记录当前版本信息
cd third_party/move
git log -1 --oneline > /tmp/move_vm_version_before.txt
cd ../..
```

### 2. 了解目标版本

```bash
# 2.1 查看 Move 仓库的版本发布
# 访问 https://github.com/move-language/move
# 或者 Aptos 使用的 Move fork

# 2.2 阅读 CHANGELOG 和发布说明
# 重点关注：
# - Breaking changes
# - 新增字节码指令
# - 类型系统变更
# - API 变更
```

### 3. 依赖分析

```bash
# 3.1 分析当前依赖
grep -r "move-vm" Cargo.toml
grep -r "move-core-types" Cargo.toml
grep -r "move-binary-format" Cargo.toml

# 3.2 检查 workspace 依赖
cat Cargo.toml | grep -A 50 "\[workspace.dependencies\]"

# 3.3 识别直接依赖 Move VM 的组件
find . -name "Cargo.toml" -exec grep -l "move-vm-runtime" {} \;
```

### 4. 创建测试基准

```bash
# 4.1 运行完整测试套件并记录结果
cargo test --workspace > /tmp/test_results_before.log 2>&1

# 4.2 运行性能基准测试
cargo bench --workspace > /tmp/bench_results_before.log 2>&1

# 4.3 运行 Move VM 特定测试
cd third_party/move/move-vm
cargo test --all-features > /tmp/move_vm_tests_before.log 2>&1
cd ../../..

# 4.4 运行端到端测试
cargo test -p aptos-e2e-tests > /tmp/e2e_tests_before.log 2>&1
```

---

## 升级步骤

### 步骤 1：更新核心 Move VM 代码

#### 1.1 更新 Move 源代码

**方式 A：如果 Move 是独立维护的 fork**

```bash
# 1. 进入 Move 目录
cd third_party/move

# 2. 添加上游 Move 仓库（如果还没有）
git remote add upstream https://github.com/move-language/move.git
# 或 Aptos 的 Move fork
git remote add upstream https://github.com/aptos-labs/move.git

# 3. 获取最新代码
git fetch upstream

# 4. 查看可用的版本标签
git tag -l | grep -E "v[0-9]+\.[0-9]+\.[0-9]+"

# 5. 检出目标版本到新分支
git checkout -b upgrade-to-vX.Y.Z upstream/vX.Y.Z

# 6. 或者合并特定的提交
git merge upstream/main --no-commit

# 7. 返回主仓库
cd ../..
```

**方式 B：如果 Move 代码直接集成到 Aptos 仓库**

```bash
# 1. 识别需要更新的文件
cd third_party/move

# 2. 手动下载并替换核心文件
# 或者使用 patch 文件
wget https://github.com/move-language/move/archive/refs/tags/vX.Y.Z.tar.gz
tar -xzf vX.Y.Z.tar.gz

# 3. 比较差异
diff -r move-vX.Y.Z/move-vm/ move-vm/

# 4. 选择性地应用更改
# 重点关注：
# - move-vm/runtime/src/interpreter.rs
# - move-vm/runtime/src/loader/
# - move-vm/types/src/
# - move-binary-format/src/

cd ../..
```

#### 1.2 更新字节码格式定义

如果字节码格式有变更：

```bash
# 文件: third_party/move/move-binary-format/src/file_format.rs

# 检查新增的字节码指令
# 例如：
# pub enum Bytecode {
#     // ... 现有指令
#     NewInstruction,  // <-- 新增
# }
```

**需要同步更新的文件**：

```
third_party/move/move-binary-format/src/
├── file_format.rs           # 字节码定义
├── serializer.rs            # 序列化
├── deserializer.rs          # 反序列化
├── check_bounds.rs          # 边界检查
└── file_format_common.rs    # 通用定义

third_party/move/move-vm/runtime/src/
├── interpreter.rs           # 解释器执行逻辑
└── loader/modules.rs        # 模块加载
```

#### 1.3 更新解释器

```bash
# 文件: third_party/move/move-vm/runtime/src/interpreter.rs

# 在 execute_instruction 方法中添加新指令的处理逻辑
# 例如：
```

```rust
// 示例：添加新指令处理
fn execute_instruction(
    &mut self,
    instruction: &Bytecode,
    // ...
) -> PartialVMResult<()> {
    match instruction {
        // ... 现有指令处理

        // 新增指令处理
        Bytecode::NewInstruction => {
            // 1. 从操作数栈弹出参数
            // 2. 执行指令逻辑
            // 3. 将结果压入栈
            // 4. Gas 计量
        }

        // ...
    }
}
```

#### 1.4 编译验证

```bash
# 编译 Move VM
cd third_party/move/move-vm
cargo build --all-features
cargo test --all-features

# 检查编译警告和错误
cargo clippy --all-features -- -D warnings

cd ../../..
```

---

### 步骤 2：更新 Aptos VM 适配层

#### 2.1 更新 VM 接口适配

```bash
# 文件: aptos-move/aptos-vm/src/aptos_vm.rs
```

**检查点**：

```rust
// 1. 检查 MoveVM 接口变更
// 如果 MoveVM::execute_loaded_function 签名改变

// 旧版本:
// MoveVM::execute_loaded_function(
//     function,
//     args,
//     data_cache,
//     gas_meter,
// )

// 新版本可能:
// MoveVM::execute_loaded_function(
//     function,
//     args,
//     data_cache,
//     gas_meter,
//     traversal_context,  // 新增参数
//     extensions,         // 新增参数
// )

// 2. 更新调用代码
impl AptosVM {
    fn execute_function_inner(...) {
        // 适配新接口
    }
}
```

#### 2.2 更新 Session 管理

```bash
# 文件: aptos-move/aptos-vm/src/move_vm_ext/session/mod.rs
```

```rust
// 检查 SessionExt 是否需要新的扩展上下文
impl<'r, R> SessionExt<'r, R> {
    pub fn new(...) -> Self {
        // 如果 Move VM 添加了新的上下文要求
        // 需要在这里初始化
    }
}
```

#### 2.3 更新错误处理

```bash
# 文件: aptos-move/aptos-vm/src/errors.rs
```

```rust
// 如果 Move VM 引入了新的错误类型
// 需要添加转换逻辑

// 例如：
pub fn convert_vm_error(...) -> VMStatus {
    match vm_error.status_code() {
        // ... 现有错误处理
        StatusCode::NEW_ERROR_TYPE => {
            // 新错误类型的处理
        }
    }
}
```

#### 2.4 编译验证

```bash
# 编译 Aptos VM
cargo build -p aptos-vm
cargo test -p aptos-vm

# 运行集成测试
cargo test -p aptos-vm --test integration_tests
```

---

### 步骤 3：更新原生函数

#### 3.1 检查原生函数接口变更

```bash
# 文件: aptos-move/framework/src/natives/
```

```rust
// 原生函数签名可能的变更

// 旧版本:
// pub fn native_function(
//     context: &mut NativeContext,
//     ty_args: Vec<Type>,
//     args: VecDeque<Value>,
// ) -> PartialVMResult<NativeResult>

// 新版本可能:
// pub fn native_function(
//     context: &mut SafeNativeContext,  // 类型变更
//     ty_args: Vec<Type>,
//     args: VecDeque<Value>,
// ) -> SafeNativeResult<SmallVec<[Value; 1]>>  // 返回类型变更
```

#### 3.2 更新原生函数实现

需要更新的模块：

```
aptos-move/framework/src/natives/
├── account.rs
├── aggregator_natives/
├── code.rs
├── cryptography/
├── event.rs
├── object.rs
├── randomness.rs
├── state_storage.rs
├── table.rs
└── transaction_context.rs
```

**示例更新**：

```rust
// 文件: aptos-move/framework/src/natives/event.rs

// 如果 NativeContext API 改变
pub fn native_emit_event(
    context: &mut NativeContext,  // 或 SafeNativeContext
    ty_args: Vec<Type>,
    mut args: VecDeque<Value>,
) -> PartialVMResult<NativeResult> {
    // 更新实现以匹配新 API

    // 1. 参数提取方式可能改变
    // 2. Gas 计量方式可能改变
    // 3. 返回值构造可能改变
}
```

#### 3.3 更新原生函数注册

```bash
# 文件: aptos-move/aptos-vm/src/natives.rs
```

```rust
pub fn aptos_natives(
    gas_params: NativeGasParameters,
    config: NativeConfig,
) -> NativeFunctionTable {
    // 检查注册方式是否改变
    // 例如：从 Vec 改为 BTreeMap

    // 如果有新的原生函数模块
    move_stdlib_natives(gas_params.move_stdlib)
        .into_iter()
        .chain(framework_natives(gas_params.aptos_framework))
        .chain(new_native_module(gas_params.new_module))  // 新增
        .collect()
}
```

---

### 步骤 4：更新 Gas 调度表

#### 4.1 添加新指令的 Gas 成本

```bash
# 文件: aptos-move/aptos-gas-schedule/src/aptos.rs
```

```rust
// 如果有新的字节码指令
pub struct InstructionGasParameters {
    // ... 现有指令

    // 新增指令
    pub new_instruction: InternalGas,
}

impl InstructionGasParameters {
    pub fn charge_for_instruction(&self, instr: &Bytecode) -> InternalGas {
        match instr {
            // ... 现有指令
            Bytecode::NewInstruction => self.new_instruction,
        }
    }
}
```

#### 4.2 更新 Gas 特性版本

```bash
# 文件: aptos-move/aptos-gas-schedule/src/gas_feature_versions.rs
# （如果该文件存在）
```

```rust
// 添加新的 Gas 特性版本
pub const RELEASE_V1_XX: u64 = XX;  // 新版本号

// 在新版本中启用新特性
pub fn get_gas_feature_version(features: &Features) -> u64 {
    // 根据链上特性标志返回版本
}
```

#### 4.3 Gas 参数表更新

```bash
# 文件: aptos-move/aptos-gas-schedule/src/gas_schedule.rs
```

创建新的 Gas 调度表版本：

```rust
// 示例
pub fn initial_gas_schedule_vXX() -> GasScheduleV2 {
    GasScheduleV2 {
        feature_version: XX,
        entries: vec![
            // ... 所有指令的 Gas 成本
            (
                "instr.new_instruction",
                GasUnits::new(100),  // 新指令成本
            ),
        ],
    }
}
```

---

### 步骤 5：更新 Aptos Framework

#### 5.1 检查标准库兼容性

```bash
# 进入 framework 目录
cd aptos-move/framework

# 检查是否有使用新语言特性的模块
find move-stdlib/sources -name "*.move"
find aptos-stdlib/sources -name "*.move"
find aptos-framework/sources -name "*.move"
```

#### 5.2 编译 Framework

```bash
# 编译所有 Move 模块
cargo run -p aptos-framework -- release

# 检查编译输出
# 如果有错误，可能需要：
# 1. 更新模块语法以适配新版本
# 2. 或者等待语言特性稳定后再使用
```

#### 5.3 更新系统模块

如果核心系统模块需要更新：

```bash
# 文件: aptos-move/framework/aptos-framework/sources/
# 重点关注：
# - account.move
# - transaction_validation.move
# - coin.move
# - timestamp.move
```

#### 5.4 生成新的 Framework 包

```bash
# 重新生成编译后的 Framework
cargo run -p aptos-framework -- release

# 验证生成的字节码
ls -lh aptos-move/framework/aptos-framework/releases/
```

---

### 步骤 6：更新编译器和验证器

#### 6.1 更新 Move 编译器

```bash
# 文件: third_party/move/move-compiler/
```

如果编译器有更新：
- 新的语法支持
- 新的类型检查规则
- 新的优化

#### 6.2 更新字节码验证器

```bash
# 文件: third_party/move/move-bytecode-verifier/
```

验证器可能需要：
- 支持新的字节码指令
- 新的类型规则
- 新的安全检查

#### 6.3 编译验证

```bash
cd third_party/move/move-compiler
cargo build --all-features
cargo test --all-features

cd ../move-bytecode-verifier
cargo build --all-features
cargo test --all-features

cd ../../..
```

---

### 步骤 7：实现特性门控

#### 7.1 添加特性标志

```bash
# 文件: aptos-types/src/on_chain_config/features.rs
```

```rust
// 添加新的特性标志用于控制新版本 Move VM

pub enum FeatureFlag {
    // ... 现有特性

    MOVE_VM_V2_ENABLED,  // 新增
    NEW_BYTECODE_INSTRUCTION_ENABLED,
}

impl Features {
    pub fn is_move_vm_v2_enabled(&self) -> bool {
        self.is_enabled(FeatureFlag::MOVE_VM_V2_ENABLED)
    }
}
```

#### 7.2 在代码中使用特性门控

```rust
// 文件: aptos-move/aptos-vm/src/aptos_vm.rs

impl AptosVM {
    fn execute_with_feature_gating(&self, ...) {
        let features = self.get_features();

        if features.is_move_vm_v2_enabled() {
            // 使用新版本逻辑
            self.execute_with_v2(...)
        } else {
            // 使用旧版本逻辑
            self.execute_with_v1(...)
        }
    }
}
```

#### 7.3 设置特性激活条件

```bash
# 文件: aptos-move/aptos-vm/src/aptos_vm.rs 或配置文件
```

特性激活策略：
1. **测试网优先**：先在测试网激活
2. **渐进式激活**：通过治理提案逐步激活
3. **回滚机制**：保留禁用特性的能力

---

### 步骤 8：更新测试

#### 8.1 添加向后兼容性测试

```rust
// 文件: aptos-move/aptos-vm/tests/compatibility_tests.rs

#[test]
fn test_old_bytecode_compatibility() {
    // 1. 加载旧版本编译的字节码
    let old_bytecode = load_legacy_bytecode();

    // 2. 在新 VM 上执行
    let result = new_vm.execute(old_bytecode);

    // 3. 验证结果一致
    assert!(result.is_ok());
}
```

#### 8.2 添加新特性测试

```rust
#[test]
fn test_new_instruction() {
    // 测试新指令的功能
    let bytecode = compile_with_new_instruction();
    let result = vm.execute(bytecode);
    assert_eq!(result, expected);
}
```

#### 8.3 添加性能回归测试

```rust
// 文件: aptos-move/aptos-vm-benchmarks/benches/vm_benchmarks.rs

#[bench]
fn bench_new_vm_vs_old_vm(b: &mut Bencher) {
    // 比较新旧 VM 性能
}
```

---

## 验证和测试

### 1. 单元测试

```bash
# 1.1 运行 Move VM 测试
cd third_party/move/move-vm
cargo test --all-features
cd ../../..

# 1.2 运行 Aptos VM 测试
cargo test -p aptos-vm --all-features

# 1.3 运行原生函数测试
cargo test -p aptos-framework

# 1.4 运行 Gas 测试
cargo test -p aptos-gas-meter
cargo test -p aptos-gas-schedule
```

### 2. 集成测试

```bash
# 2.1 端到端测试
cargo test -p aptos-e2e-tests

# 2.2 事务性测试
cargo test -p aptos-transactional-test-harness

# 2.3 模拟测试
cargo test -p aptos-transaction-simulation
```

### 3. 性能测试

```bash
# 3.1 运行性能基准
cargo bench -p aptos-vm-benchmarks

# 3.2 对比升级前后性能
diff /tmp/bench_results_before.log <(cargo bench -p aptos-vm-benchmarks)

# 3.3 运行压力测试
cargo run -p aptos-transaction-benchmarks
```

### 4. 兼容性测试

```bash
# 4.1 加载旧版本字节码测试
cargo test -p aptos-vm test_legacy_bytecode

# 4.2 跨版本测试
# 使用旧版本编译的 Framework 在新 VM 上运行

# 4.3 回归测试
cargo test --workspace -- --ignored  # 运行标记为 ignored 的测试
```

### 5. 人工验证

#### 5.1 本地测试网验证

```bash
# 启动本地测试网
cargo run -p aptos-node -- --test

# 部署测试合约
aptos move publish --package-dir examples/hello_blockchain

# 执行交易
aptos move run --function-id 0x1::hello_blockchain::set_message

# 检查结果
aptos account list --account 0x1
```

#### 5.2 Devnet 验证

```bash
# 1. 部署到 Devnet
aptos init --network devnet

# 2. 部署更新后的 Framework
# （需要治理权限）

# 3. 运行端到端测试
./scripts/run_devnet_tests.sh

# 4. 监控错误率
# 检查 Devnet 的错误日志和指标
```

#### 5.3 功能验证清单

- [ ] 基本交易执行
- [ ] 模块发布
- [ ] 模块升级
- [ ] 脚本执行
- [ ] 入口函数调用
- [ ] 视图函数调用
- [ ] 事件发射
- [ ] Gas 计量准确性
- [ ] 错误处理正确性
- [ ] 并行执行正确性

---

## 回滚计划

### 1. 代码回滚

```bash
# 1.1 回滚到升级前的版本
git checkout backup/pre-move-upgrade-YYYYMMDD

# 1.2 或者回滚特定文件
git checkout HEAD~N -- third_party/move/

# 1.3 重新编译
cargo clean
cargo build --workspace
```

### 2. 链上回滚

#### 2.1 禁用特性标志

```rust
// 通过治理提案禁用新特性
// 不需要代码变更，只需要链上投票
```

#### 2.2 紧急停止

```bash
# 如果发现严重问题
# 1. 通知验证者停止生产区块
# 2. 评估影响范围
# 3. 准备修复或回滚
# 4. 协调重启
```

### 3. 数据迁移回滚

```bash
# 如果状态格式有变更
# 需要准备反向迁移脚本

# 备份关键状态
aptos db backup ...

# 如需回滚，恢复备份
aptos db restore ...
```

---

## 常见问题

### Q1: 升级是否需要硬分叉？

**答**：取决于变更的性质：

- **不需要硬分叉**：
  - 新增可选特性（通过特性门控）
  - 优化现有逻辑（不改变结果）
  - 修复不影响共识的 bug

- **需要软分叉**：
  - 添加新的字节码指令（旧节点忽略）
  - 添加新的原生函数（旧节点不调用）

- **需要硬分叉**：
  - 修改现有指令的语义
  - 修改 Gas 计算规则（影响共识）
  - 修改序列化格式

### Q2: 如何保证向后兼容性？

**答**：多层次保证：

1. **字节码层**：
   ```rust
   // 保留旧指令，新指令使用新的操作码
   pub enum Bytecode {
       OldInstruction,      // 保留
       NewInstruction,      // 新增
   }
   ```

2. **版本标记**：
   ```rust
   // 模块携带版本信息
   pub struct CompiledModule {
       version: u32,  // 编译时的语言版本
       // ...
   }
   ```

3. **特性门控**：
   ```rust
   if module.version >= 2 && features.is_enabled(...) {
       // 使用新逻辑
   } else {
       // 使用旧逻辑
   }
   ```

### Q3: 升级过程中发现问题怎么办？

**答**：分阶段处理：

1. **开发阶段**：回滚代码，修复后重新开始
2. **测试网阶段**：
   - 评估影响范围
   - 如果严重，重置测试网
   - 修复后重新部署
3. **主网阶段**：
   - 立即禁用特性标志
   - 如果禁用不够，准备紧急补丁
   - 协调治理投票回滚

### Q4: 如何估算升级所需时间？

**答**：参考时间表（实际时间因具体变更而异）：

| 阶段 | 预计时间 | 备注 |
|------|---------|------|
| 准备和分析 | 1-2 周 | 理解变更，准备环境 |
| 代码更新 | 2-4 周 | 核心 VM + 适配层 |
| 测试和修复 | 2-3 周 | 单元测试 + 集成测试 |
| Devnet 验证 | 1-2 周 | 真实环境测试 |
| Testnet 验证 | 2-4 周 | 社区测试 |
| 治理和激活 | 2-4 周 | 提案、投票、激活 |
| **总计** | **10-19 周** | **约 2.5-5 个月** |

### Q5: 需要哪些团队协作？

**答**：跨团队协作：

1. **VM 团队**：核心 Move VM 更新
2. **Framework 团队**：标准库和系统模块
3. **工具链团队**：编译器、CLI 工具
4. **测试团队**：测试用例、性能测试
5. **DevOps 团队**：部署、监控
6. **社区团队**：文档、沟通

### Q6: 如何测试 Gas 成本的正确性？

**答**：多种方法验证：

```bash
# 1. 单元测试
cargo test -p aptos-gas-schedule

# 2. 基准测试
cargo bench -p aptos-gas-calibration

# 3. 真实交易对比
# 记录升级前的 Gas 使用
# 升级后执行相同交易对比

# 4. Gas profiling
cargo run -p aptos-gas-profiling -- \
    --module 0x1::account \
    --function create_account
```

---

## 附录

### A. 关键文件清单

#### Move VM 核心文件

```
third_party/move/
├── move-vm/runtime/src/
│   ├── interpreter.rs          # ⭐ 字节码解释器
│   ├── move_vm.rs              # ⭐ VM 主接口
│   ├── loader/modules.rs       # ⭐ 模块加载
│   └── data_cache.rs           # 数据缓存
├── move-vm/types/src/
│   ├── values/                 # 值表示
│   └── gas.rs                  # Gas 接口
├── move-binary-format/src/
│   ├── file_format.rs          # ⭐ 字节码格式
│   ├── serializer.rs           # 序列化
│   └── deserializer.rs         # 反序列化
├── move-bytecode-verifier/src/
│   └── verifier.rs             # 字节码验证
└── move-compiler/src/
    └── compiler.rs             # 编译器
```

#### Aptos 适配层文件

```
aptos-move/
├── aptos-vm/src/
│   ├── aptos_vm.rs             # ⭐ 主 VM 实现
│   ├── move_vm_ext/
│   │   ├── session/mod.rs      # ⭐ Session 管理
│   │   └── vm.rs               # MoveVmExt
│   ├── data_cache.rs           # ⭐ 存储适配器
│   └── natives.rs              # ⭐ 原生函数注册
├── framework/src/natives/      # ⭐ 原生函数实现
├── aptos-gas-schedule/src/
│   ├── aptos.rs                # ⭐ Gas 参数
│   └── gas_schedule.rs         # Gas 调度表
└── aptos-gas-meter/src/
    └── lib.rs                  # ⭐ Gas 计量器
```

### B. 测试命令速查

```bash
# 快速测试（编译检查）
cargo check --workspace

# Move VM 测试
cargo test -p move-vm-runtime
cargo test -p move-vm-types

# Aptos VM 测试
cargo test -p aptos-vm

# 端到端测试
cargo test -p aptos-e2e-tests

# 性能测试
cargo bench -p aptos-vm-benchmarks

# 完整测试套件
cargo test --workspace --all-features

# 特定功能测试
cargo test -p aptos-vm test_transaction_execution
```

### C. 版本控制最佳实践

```bash
# 1. 使用语义化版本
# MAJOR.MINOR.PATCH
# MAJOR: 不兼容的 API 变更
# MINOR: 向后兼容的功能添加
# PATCH: 向后兼容的 bug 修复

# 2. Git 标签
git tag -a v2.0.0 -m "Move VM upgrade to version 2.0"
git push origin v2.0.0

# 3. 变更日志
# 维护 CHANGELOG.md 记录所有变更

# 4. 版本分支策略
# main: 稳定版本
# develop: 开发版本
# feature/move-upgrade-vX.Y.Z: 升级分支
```

### D. 参考资源

- **Move 语言官方文档**: https://move-language.github.io/move/
- **Aptos Move 文档**: https://aptos.dev/move/move-on-aptos/
- **Move VM 源代码**: https://github.com/move-language/move
- **Aptos Core 源代码**: https://github.com/aptos-labs/aptos-core
- **Gas 调度表文档**: aptos-move/aptos-gas-schedule/README.md

---

*本文档提供了 Move 语言版本升级的完整指南。实际升级过程中应根据具体情况调整步骤和时间表。*
