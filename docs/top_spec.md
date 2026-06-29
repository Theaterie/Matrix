# 顶层 I/O 信号表 (Top-Level Spec)

## 顶层选择指南

| 顶层模块 | 适用场景 |
|----------|----------|
| `systolic_array` | 独立验证 / 教学演示 |
| `systolic_array_pingpong` | 需要隐藏加载延迟，提高吞吐 |
| `systolic_array_axis` | 集成 SoC / 对接 DMA |
| `matrix_core` | 任意维度矩阵乘法（分块调度） |

---

## 全局参数（所有模块共享）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `ROWS` | 16 | PE 阵列行数（= M tile / K tile 尺寸） |
| `COLS` | 16 | PE 阵列列数（= N tile 尺寸） |
| `DATA_WIDTH` | 16 | 输入操作数位宽 |
| `ACCUM_WIDTH` | 40 | 累加器位宽（≥ 2×DATA_WIDTH + log2(Kmax)） |
| `K_DEPTH` | 16 | 每 tile 的 K 维深度（激活向量数） |
| `BUF_ADDR_W` | 8 | BRAM 地址宽度（log2(BUF_DEPTH)） |
| `BUF_DEPTH` | 256 | BRAM 深度 |
| `WT_ADDR_W` | 8 | 权重地址宽度（log2(ROWS×COLS)） |

---

## Layer 5: matrix_core

### 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `DIM_WIDTH` | 16 | 矩阵维度位宽 |
| 其余 | — | 同全局参数 |

### 端口

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `clk` | in | 1 | 系统时钟 |
| `rst_n` | in | 1 | 异步复位，低有效 |
| **命令接口** | | | |
| `start` | in | 1 | 脉冲：启动完整矩阵乘法 |
| `busy` | out | 1 | 计算进行中 |
| `done` | out | 1 | 脉冲：所有 tile 完成 |
| **矩阵维度** | | | |
| `M` | in | DIM_WIDTH | 输出行数 |
| `N` | in | DIM_WIDTH | 输出列数 |
| `K` | in | DIM_WIDTH | 归约维度 |
| **systolic_array 控制** | | | |
| `sa_start` | out | 1 | 脉冲：启动单 tile |
| `sa_busy` | in | 1 | systolic_array 忙 |
| `sa_done` | in | 1 | 脉冲：单 tile 完成 |
| `sa_use_bram_act` | out | 1 | 1=BRAM 路径 |
| `sa_weight_data` | out | DATA_WIDTH | 权重数据 |
| `sa_weight_ready` | in | 1 | 权重就绪 |
| `sa_weight_preloaded` | out | 1 | 1=跳过权重加载 |
| `sa_act_base_addr` | out | BUF_ADDR_W | 激活 BRAM 基地址 |
| `sa_res_base_addr` | out | BUF_ADDR_W | 结果 BRAM 基地址 |
| **外部数据接口** | | | |
| `host_act_wr_en` | in | 1 | 激活 BRAM 写使能 |
| `host_act_wr_addr` | in | BUF_ADDR_W | 激活 BRAM 写地址 |
| `host_act_wr_data` | in | DATA_WIDTH | 激活 BRAM 写数据 |
| `host_weight_data` | in | DATA_WIDTH | 权重数据（WEIGHT_LOAD 期间驱动） |
| `host_weight_req` | out | 1 | 请求下一个权重 |
| `host_res_rd_en` | out | 1 | 结果 BRAM 读使能 |
| `host_res_rd_addr` | out | BUF_ADDR_W | 结果 BRAM 读地址 |
| `host_res_rd_data` | in | ACCUM_WIDTH | 结果 BRAM 读数据 |
| **Tile 地址输出** | | | |
| `tile_m_idx` | out | DIM_WIDTH | 当前 tile 的 M 索引 |
| `tile_n_idx` | out | DIM_WIDTH | 当前 tile 的 N 索引 |
| `tile_k_idx` | out | DIM_WIDTH | 当前 tile 的 K 索引 |
| `tile_new_k` | out | 1 | 脉冲：新 K-tile 开始 |
| `tile_new_mn` | out | 1 | 脉冲：新 (M,N) tile 开始 |
| **调试** | | | |
| `fsm_state` | out | 4 | FSM 状态 |

---

## Layer 4: systolic_array (核心计算引擎)

### 端口

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `clk` | in | 1 | 系统时钟 |
| `rst_n` | in | 1 | 异步复位，低有效 |
| **控制** | | | |
| `start` | in | 1 | 脉冲：启动 tile 计算 |
| `weight_preloaded` | in | 1 | 1=权重已加载，跳过 WEIGHT_LOAD |
| `prefetch_start` | in | 1 | 脉冲：提前启动 BRAM 预取 |
| `busy` | out | 1 | 计算进行中 |
| `done` | out | 1 | 脉冲：tile 完成 |
| **权重输入**（WEIGHT_LOAD 阶段串行） | | | |
| `weight_data` | in | DATA_WIDTH | 权重值 |
| `weight_ready` | out | 1 | 就绪接收权重 |
| **激活输入** | | | |
| `use_bram_act` | in | 1 | 1=BRAM 路径，0=外部直通（测试） |
| `act_data` | in | DATA_WIDTH×ROWS | 每行一个激活（unpacked） |
| `act_valid` | in | 1 | 激活有效 |
| **激活 BRAM 写端口**（host 预加载） | | | |
| `act_wr_en` | in | 1 | 写使能 |
| `act_wr_addr` | in | BUF_ADDR_W | 写地址 |
| `act_wr_data` | in | DATA_WIDTH | 写数据 |
| **结果输出**（调试/监测） | | | |
| `result_data` | out | ACCUM_WIDTH×COLS | 每列一个结果（unpacked） |
| `result_valid` | out | 1 | 结果有效 |
| **结果 BRAM 读端口**（host 读取） | | | |
| `res_rd_en` | in | 1 | 读使能 |
| `res_rd_addr` | in | BUF_ADDR_W | 读地址 |
| `res_rd_data` | out | ACCUM_WIDTH | 读数据 |
| **Tile 基地址** | | | |
| `act_base_addr` | in | BUF_ADDR_W | 激活缓冲基地址 |
| `res_base_addr` | in | BUF_ADDR_W | 结果缓冲基地址 |

---

## Layer 4: systolic_array_pingpong (双缓冲封装)

在 `systolic_array` 基础上新增的端口：

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `auto_swap` | in | 1 | 1=done 后自动切换 active buffer |
| `buf_sel` | out | 1 | 当前 active buffer（0=A, 1=B） |
| **激活写入 → inactive buffer** | | | |
| `host_act_wr_en` | in | 1 | 写使能 |
| `host_act_wr_addr` | in | BUF_ADDR_W | 写地址 |
| `host_act_wr_data` | in | DATA_WIDTH | 写数据 |
| `host_act_base_addr` | in | BUF_ADDR_W | 下一 tile 激活基地址 |
| **结果读取 ← active result BRAM** | | | |
| `host_res_rd_en` | in | 1 | 读使能 |
| `host_res_rd_addr` | in | BUF_ADDR_W | 读地址 |
| `host_res_rd_data` | out | ACCUM_WIDTH | 读数据 |

> 其余端口（clk, rst_n, start, weight_*, busy, done, act_data, result_data 等）与 `systolic_array` 相同。
> 注意：不含 `act_wr_*` / `res_rd_*` 端口，这些被替换为 `host_*` 端口并经 MUX 路由到 active/inactive buffer。

---

## Layer 4: systolic_array_axis (AXI4-Stream 封装)

### AXI4-Stream 接口

| 接口 | 方向 | 信号 | 说明 |
|------|------|------|------|
| **S_AXIS_WEIGHT** | Slave | `s_axis_weight_tvalid/tready/tdata/tlast` | 权重流（WEIGHT_LOAD 期间） |
| **S_AXIS_ACT** | Slave | `s_axis_act_tvalid/tready/tdata/tlast` | 激活流（写入 act_bram） |
| **M_AXIS_RESULT** | Master | `m_axis_result_tvalid/tready/tdata/tlast` | 结果流（SERIALIZE 期间） |

### 控制与辅助端口

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `clk`, `rst_n` | in | 1 | 时钟/复位 |
| `start` | in | 1 | 脉冲：启动 tile |
| `busy` | out | 1 | 计算中 |
| `done` | out | 1 | 脉冲：完成 |
| `use_bram_act` | in | 1 | 1=BRAM 路径 |
| `act_data` | in | DATA_WIDTH×ROWS | 直通激活（测试） |
| `act_valid` | in | 1 | 激活有效 |
| `result_data` | out | ACCUM_WIDTH×COLS | 原始结果（调试） |
| `result_valid` | out | 1 | 结果有效 |
| `act_base_addr` | in | BUF_ADDR_W | 激活基地址 |
| `res_base_addr` | in | BUF_ADDR_W | 结果基地址 |

---

## Layer 4: systolic_array_exposed (BRAM 外露，中间层)

> 逻辑与 `systolic_array` 相同，但不在内部例化 `buffer_ram`，改为端口外露。

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| **激活 BRAM 读端口**（→ deserializer） | | | |
| `act_bram_rd_en` | out | 1 | 读使能 |
| `act_bram_rd_addr` | out | BUF_ADDR_W | 读地址 |
| `act_bram_rd_data` | in | DATA_WIDTH | 读数据 |
| **结果 BRAM 写端口**（← serializer） | | | |
| `res_bram_wr_en` | out | 1 | 写使能 |
| `res_bram_wr_addr` | out | BUF_ADDR_W | 写地址 |
| `res_bram_wr_data` | out | ACCUM_WIDTH | 写数据 |
| **结果 BRAM 读端口**（→ 外部读取） | | | |
| `res_bram_rd_en` | in | 1 | 读使能 |
| `res_bram_rd_addr` | in | BUF_ADDR_W | 读地址 |
| `res_bram_rd_data` | out | ACCUM_WIDTH | 读数据 |

> 其余端口（控制、权重、激活直通、结果调试、tile 基地址）与 `systolic_array` 相同。

---

## Layer 3: 内部组件

### controller

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `start` | in | 1 | 启动脉冲 |
| `weight_preloaded` | in | 1 | 权重已加载 |
| `busy` | out | 1 | 计算中 |
| `done` | out | 1 | 完成脉冲 |
| `pe_clear` | out | 1 | 复位累加器（COMPUTE 首周期） |
| `pe_enable` | out | 1 | 流水线使能（低=暂停） |
| `weight_wren` | out | 1 | 权重写使能 |
| `weight_addr` | out | ADDR_WIDTH | 权重目标地址 |
| `phase` | out | 3 | 0=IDLE 1=WEIGHT_LOAD 2=COMPUTE 3=READOUT 4=SERIALIZE 5=DONE |
| `compute_cycle` | out | log2(K)+1 | COMPUTE 内周期计数 |
| `readout_cycle` | out | log2(2(R+C))+1 | READOUT 内周期计数 |
| `serialize_cycle` | out | log2(R×C)+1 | SERIALIZE 内周期计数 |
| `deser_ready` | in | 1 | deserializer 预取完成 |

### address_generator

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `phase` | in | 3 | FSM 阶段 |
| `enable` | in | 1 | 地址计数推进 |
| `act_base_addr` | in | ADDR_WIDTH | 激活基地址 |
| `res_base_addr` | in | ADDR_WIDTH | 结果基地址 |
| `act_rd_addr` | out | ADDR_WIDTH | 激活读地址 |
| `act_rd_en` | out | 1 | 激活读使能 |
| `res_wr_addr` | out | ADDR_WIDTH | 结果写地址 |
| `res_wr_en` | out | 1 | 结果写使能 |
| `act_done` | out | 1 | 激活读取完成脉冲 |
| `res_done` | out | 1 | 结果写入完成脉冲 |

### act_deserializer

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `bram_rd_en` | out | 1 | BRAM 读使能 |
| `bram_rd_addr` | out | ADDR_WIDTH | BRAM 读地址 |
| `bram_rd_data` | in | DATA_WIDTH | BRAM 读数据 |
| `act_data_out` | out | DATA_WIDTH×ROWS | 并行激活输出 |
| `act_valid_out` | out | 1 | 输出有效 |
| `act_base_addr` | in | ADDR_WIDTH | BRAM 基地址 |
| `prefetch_start` | in | 1 | 启动预取脉冲 |
| `stream_en` | in | 1 | COMPUTE 阶段流式输出 |
| `prefetch_done` | out | 1 | 预取完成 |
| `stream_done` | out | 1 | 流式输出完成脉冲 |

### result_serializer

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `parallel_in` | in | DATA_WIDTH×COLS | 并行结果输入 |
| `parallel_valid` | in | 1 | 输入有效 |
| `serial_data` | out | DATA_WIDTH | 串行结果输出 |
| `serial_valid` | out | 1 | 输出有效 |
| `capture_en` | in | 1 | READOUT 阶段捕获使能 |
| `shift_en` | in | 1 | SERIALIZE 阶段移位使能 |
| `done` | out | 1 | 最后一个结果移出脉冲 |

### buffer_ram

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `wr_en` | in | 1 | 写使能（Port A） |
| `wr_addr` | in | ADDR_WIDTH | 写地址 |
| `wr_data` | in | DATA_WIDTH | 写数据 |
| `rd_en` | in | 1 | 读使能（Port B） |
| `rd_addr` | in | ADDR_WIDTH | 读地址 |
| `rd_data` | out | DATA_WIDTH | 读数据（同步，1 周期延迟） |

---

## Layer 2: pe_array

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `act_data_in` | in | DATA_WIDTH×ROWS | 左边界激活（每行一个） |
| `act_valid_in` | in | 1 | 激活有效（广播所有行） |
| `weight_data` | in | DATA_WIDTH | 权重值 |
| `weight_addr` | in | log2(R×C) | 目标 PE 地址 |
| `weight_wren` | in | 1 | 权重写使能 |
| `result_data` | out | ACCUM_WIDTH×COLS | 下边界结果（每列一个） |
| `result_valid` | out | 1 | 结果有效 |
| `clear` | in | 1 | 复位累加器 |
| `enable` | in | 1 | 流水线使能 |

---

## Layer 1: PE 变体

### pe (INT16 基础)

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `act_in` | in | DATA_WIDTH | 左邻居激活 |
| `valid_in` | in | 1 | 激活有效 |
| `act_out` | out | DATA_WIDTH | 右邻居激活（延迟 2 周期） |
| `valid_out` | out | 1 | 延迟有效 |
| `psum_in` | in | ACCUM_WIDTH | 上邻居部分和 |
| `psum_out` | out | ACCUM_WIDTH | 下邻居部分和 |
| `psum_valid` | out | 1 | 部分和有效 |
| `weight_load` | in | 1 | 从 act_in 加载权重 |
| `clear` | in | 1 | 复位累加器 |
| `enable` | in | 1 | 流水线使能 |

### pe_dual_int8 (INT8 双发)

| 差异信号 | 方向 | 位宽 | 说明 |
|----------|------|------|------|
| `act_in` | in | 16 | {INT8_HI, INT8_LO} 打包 |
| `act_out` | out | 16 | 打包直通 |
| `psum_in_lo` | in | ACCUM_WIDTH_LO | 低位流部分和 |
| `psum_in_hi` | in | ACCUM_WIDTH_HI | 高位流部分和 |
| `psum_out_lo` | out | ACCUM_WIDTH_LO | 低位流输出 |
| `psum_out_hi` | out | ACCUM_WIDTH_HI | 高位流输出 |

> 控制端口（weight_load, clear, enable, valid_*）与 `pe` 相同。

### pe_int8_sparse (INT8 稀疏)

| 差异信号 | 方向 | 位宽 | 说明 |
|----------|------|------|------|
| `is_zero_weight` | out | 1 | 权重为零（调试） |
| `skip_cycle` | out | 1 | 当前 MAC 被跳过（调试） |

> 数据/控制端口与 `pe` 相同。参数新增 `SPARSE_ENABLE`、`DUAL_ISSUE`。

---

## Layer 0: mac_unit

| 信号名 | 方向 | 位宽 | 说明 |
|--------|------|------|------|
| `a_in` | in | DATA_WIDTH | 操作数 A（signed） |
| `b_in` | in | DATA_WIDTH | 操作数 B（signed） |
| `acc_in` | in | ACCUM_WIDTH | 上游累加值（signed） |
| `valid_in` | in | 1 | 输入有效 |
| `clear` | in | 1 | 复位累加器（新点积开始） |
| `enable` | in | 1 | 流水线使能（低=冲刷） |
| `acc_out` | out | ACCUM_WIDTH | 累加结果 |
| `valid_out` | out | 1 | 输出有效（对齐 2 周期延迟） |
