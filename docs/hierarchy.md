# 层次结构文档 (Hierarchy)

16×16 Weight-Stationary 脉动阵列矩阵乘法器，自底向上 6 层封装。

## 层次总览

```
Layer 5  matrix_core                         分块矩阵乘法调度器（任意 M×N×K）
         │
Layer 4  ┌─ systolic_array_axis_pingpong    AXI4-Stream + 双缓冲（最终封装，SoC/DMA 集成）
         │    └─ systolic_array_pingpong    双缓冲封装（隐藏加载延迟）
         │         └─ systolic_array_exposed  BRAM 端口外露（ping-pong 中间层）
         ├─ systolic_array_axis              AXI4-Stream 封装（无双缓冲）
         └─ systolic_array                   核心计算引擎（内含 BRAM）
              │
Layer 3  ├── controller                      FSM: IDLE→WEIGHT_LOAD→COMPUTE→READOUT→SERIALIZE→DONE
         ├── address_generator               激活/结果 BRAM 读写地址生成
         ├── act_deserializer                BRAM(标量) → PE阵列(ROWS路并行) 桥接 + 预取
         ├── result_serializer               PE阵列(并行) → BRAM(标量) 捕获 + 串行化
         └── buffer_ram ×2                   双端口 BRAM（激活缓冲 + 结果缓冲）
              │
Layer 2  └── pe_array                        ROWS×COLS PE 网格 + 左边界 skew 移位寄存器
              │
Layer 1  ├── pe          (INT16 基础)        权重驻留 PE，2 级流水 MAC
         ├── pe_dual_int8 (INT8 双发)         16b 打包 2×INT8，吞吐 ×2
         └── pe_int8_sparse (INT8 稀疏)       零值跳过，省功耗
              │
Layer 0  └── mac_unit                        2 级流水乘累加（Stage1 乘法 / Stage2 累加 → DSP48）
```

## 各层说明

### Layer 0 — 算术单元

| 模块 | 文件 | 职责 |
|------|------|------|
| `mac_unit` | `mac_unit.v` | 有符号乘累加，2 级流水线（乘法→累加），映射 DSP48。`enable=0` 冲刷流水线防止残留 psum 泄漏。 |

### Layer 1 — 处理单元（可替换变体）

三个 PE 实现同一权重驻留架构，接口略有差异，按需例化进 `pe_array`。

| 模块 | 文件 | 数据宽度 | 特点 |
|------|------|----------|------|
| `pe` | `pe.sv` | INT16 (DW=16, AW=40) | 基础版，包装 `mac_unit` |
| `pe_dual_int8` | `pe_dual_int8.sv` | INT8×2 (DW=16, AW=24) | 16b 打包双 INT8，单 DSP 双发 |
| `pe_int8_sparse` | `pe_int8_sparse.sv` | INT8 (DW=8, AW=32) | 零值检测跳过乘法，省动态功耗 |

共同结构：
- 权重寄存器：`weight_load=1` 时从 `act_in` 加载，之后驻留
- 激活直通：2 级移位寄存器，匹配 MAC 流水延迟
- 部分和：`psum_in`（上方）→ MAC 累加 → `psum_out`（下方）

### Layer 2 — PE 阵列

| 模块 | 文件 | 职责 |
|------|------|------|
| `pe_array` | `pe_array.sv` | ROWS×COLS 网格。激活左→右（每 PE 延迟 2 周期），部分和上→下。左边界按行做 2×r 周期 skew 对齐。 |

### Layer 3 — 基础设施（systolic_array 内部组件）

| 模块 | 文件 | 职责 |
|------|------|------|
| `controller` | `controller.sv` | 6 状态 FSM，调度权重加载/计算/排空/串行化。计数器驱动状态转移，输出纯组合。 |
| `address_generator` | `address_generator.sv` | COMPUTE 阶段生成激活读地址，SERIALIZE 阶段生成结果写地址。支持 tile 基地址偏移。 |
| `act_deserializer` | `act_deserializer.sv` | PREFETCH 阶段从 BRAM 读 ROWS×K_DEPTH 个激活到 FF 缓冲，COMPUTE 阶段每周期输出 ROWS 路并行。 |
| `result_serializer` | `result_serializer.sv` | READOUT 阶段捕获 COLS 宽并行结果到 ROWS×COLS 缓冲，SERIALIZE 阶段每周期输出 1 个。 |
| `buffer_ram` | `buffer_ram.sv` | 简单双端口 BRAM（1 写 + 1 读），同步读写，read-first 模式。 |

### Layer 4 — 计算引擎封装链

逐层包裹，非平行变体：

```
systolic_array (核心，内含 BRAM)
   │
   ├── systolic_array_exposed   BRAM 端口外露 → 供 ping-pong 插入 MUX
   │      └── systolic_array_pingpong   双组 BRAM (A/B)，计算与加载重叠
   │             └── systolic_array_axis_pingpong   AXI4-Stream + 双缓冲（最终封装）
   │
   └── systolic_array_axis      套 AXI4-Stream 接口（S_AXIS_WEIGHT/ACT, M_AXIS_RESULT）
```

| 模块 | 文件 | 封装目的 |
|------|------|----------|
| `systolic_array` | `systolic_array.sv` | 完整单 tile 计算引擎，内含 controller + pe_array + deserializer + serializer + 2×BRAM |
| `systolic_array_exposed` | `systolic_array_exposed.sv` | 逻辑同上，但 BRAM 移到端口外（中间过渡层，不单独使用） |
| `systolic_array_pingpong` | `systolic_array_pingpong.sv` | 套 exposed + 双组 BRAM + MUX，active 组计算时 inactive 组可预加载 |
| `systolic_array_axis` | `systolic_array_axis.sv` | 套 systolic_array + AXI4-Stream 握手 + beat 计数，对接 SoC 总线（无双缓冲） |
| `systolic_array_axis_pingpong` | `systolic_array_axis_pingpong.sv` | 套 pingpong + AXI4-Stream，最终封装：双缓冲 + 标准接口 |

### Layer 5 — 分块调度器

| 模块 | 文件 | 职责 |
|------|------|------|
| `matrix_core` | `matrix_core.sv` | 三层 tile 循环（M→N→K），调用 systolic_array 计算任意维度 C[M×N]+=A[M×K]×B[K×N]。支持权重跨 K-tile 复用（weight_preloaded）。 |

## 数据流（单 tile）

```
Host → act_bram ──→ act_deserializer ──→ pe_array (左边界 skew)
                                            │
Host → weight_data ──→ pe_array (权重加载)  │
                                            ↓
                                     MAC 计算 (K 周期)
                                            │
pe_array (下边界) ──→ result_serializer ──→ res_bram ──→ Host
                         (READOUT 捕获)     (SERIALIZE 串行写)
```

## 时序（16×16 tile, K=16）

| 阶段 | 周期数 | 说明 |
|------|--------|------|
| WEIGHT_LOAD | 256 | ROWS×COLS=256 个权重串行加载（weight_preloaded=1 时跳过） |
| COMPUTE | 16 | K_DEPTH=16 个激活向量，每周期 1 个 |
| READOUT | 64 | 2×(ROWS+COLS)=64 排空流水线 |
| SERIALIZE | 256 | ROWS×COLS=256 个结果串行写入 BRAM |
| **合计** | **592** | weight_preloaded=1 时 **336** |
