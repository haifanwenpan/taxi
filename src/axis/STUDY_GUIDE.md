# Taxi AXI4-Stream (`src/axis`) 详细学习指南

> 本文档针对 `/home/chenye/learning/taxi/src/axis` 目录下的 SystemVerilog AXI4-Stream IP 组件库编写，涵盖模块原理、接口规范、核心设计模式、Vivado 约束以及基于 Cocotb + Verilator 的仿真实验方法。

---

## 1. 概述与环境检查

`taxi/src/axis` 是 **Taxi Transport Library**（由 Alex Forencich / FPGA Ninja 开发，Corundum 开源网卡的下一代基础设施）中的 **AXI4-Stream** 核心组件库。与传统 Verilog 模块最大的不同在于：**全面采用现代 SystemVerilog `interface`（`taxi_axis_if`）和参数检查（`$fatal`）**，并配套了完整的 **Cocotb + `cocotbext-axi` + Verilator** 自动化测试平台。

### 1.1 当前开发环境检查结果

经检查，当前工作区已具备完整的仿真与看波形工具，**无需额外安装工具**即可直接运行所有实验：

| 工具 / 包 | 状态 | 版本 / 路径 | 用途 |
| :--- | :--- | :--- | :--- |
| **Verilator** | 已安装 | `Verilator 5.032` (`/usr/bin/verilator`) | 高速 SystemVerilog 仿真器（默认） |
| **Icarus Verilog** | 已安装 | `/usr/bin/iverilog`, `/usr/bin/vvp` | 备选开源仿真器 |
| **GTKWave** | 已安装 | `/usr/bin/gtkwave` | 查看 `.fst` / `.vcd` 仿真波形 |
| **Python 虚拟环境** | 已配置 | `.venv/bin/python` | 运行 Cocotb 与 Pytest |
| **cocotb** | 已安装 | `2.1.0` | Python 协同仿真框架 |
| **cocotbext-axi** | 已安装 | `0.1.28` | AXI4-Stream BFM（Source / Sink / Bus） |
| **pytest** | 已安装 | `9.2.0` | 批量参数化回归测试运行器 |

---

## 2. 目录结构与依赖管理

```text
src/axis/
├── rtl/                  # SystemVerilog 源码与 .f 文件列表
│   ├── taxi_axis_if.sv   # 核心 AXI4-Stream 接口定义
│   ├── *.sv              # 20 个功能模块
│   └── *.f               # 依赖文件清单（供 Makefile / EDA 工具展开）
├── syn/
│   └── vivado/
│       └── taxi_axis_async_fifo.tcl  # 异步 FIFO 的 Vivado XDC/Tcl 时序约束
├── tb/                   # 17 个模块的 Cocotb 测试平台
│   └── <module_name>/
│       ├── Makefile
│       ├── test_<module_name>.sv     # SV 顶层包装（例化 taxi_axis_if 与 DUT）
│       └── test_<module_name>.py     # Python 测试用例
└── lib/                  # 外部/公共原语库链接（如 taxi_arbiter.sv, taxi_penc.sv）
```

### 关于 `.f` 文件
部分模块依赖 `src/prim/rtl/` 下的基础原语（例如仲裁器 `taxi_arbiter.sv`、优先编码器 `taxi_penc.sv`）。例如 [taxi_axis_switch.f](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_switch.f)：
```text
taxi_axis_switch.sv
taxi_axis_register.sv
taxi_axis_if.sv
../lib/taxi/src/prim/rtl/taxi_arbiter.sv
../lib/taxi/src/prim/rtl/taxi_penc.sv
```
在仿真 `Makefile` 中，通过递归展开 `.f` 并去重来收集全部 `VERILOG_SOURCES`。

---

## 3. 核心基础：SystemVerilog 接口与辅助模块

### 3.1 `taxi_axis_if` ([taxi_axis_if.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_if.sv))

`taxi_axis_if` 封装了 AXI4-Stream 协议的全部信号，并通过参数控制各可选边带信号的使能（`*_EN`）与位宽（`*_W`）：

| 信号 | 位宽 | 使能参数 | 含义 |
| :--- | :--- | :--- | :--- |
| `tdata` | `DATA_W` (默认 8) | 始终使能 | 主数据负载 |
| `tkeep` | `KEEP_W` (`(DATA_W+7)/8`) | `KEEP_EN` (`KEEP_W > 1`) | 字节有效指示（指示哪些字节属于有效包数据） |
| `tstrb` | `KEEP_W` | `STRB_EN` (默认 0) | 位置字节指示（区分数据字节与空字节） |
| `tlast` | `1` | `LAST_EN` (默认 1) | 帧/数据包边界（最后一拍拉高） |
| `tid` | `ID_W` (默认 8) | `ID_EN` (默认 0) | 数据流标识符（源端 ID） |
| `tdest` | `DEST_W` (默认 8) | `DEST_EN` (默认 0) | 路由目的地 ID |
| `tuser` | `USER_W` (默认 1) | `USER_EN` (默认 0) | 用户自定义边带信号（常用于坏包标志 `bad_frame` 等） |
| `tvalid` | `1` | 始终使能 | 主端（Source）数据有效 |
| `tready` | `1` | 始终使能 | 从端（Sink）准备好接收 |

**三种 `modport`**：
- `src`：数据发送端（`tvalid` 及负载为 `output`，`tready` 为 `input`）。
- `snk`：数据接收端（`tvalid` 及负载为 `input`，`tready` 为 `output`）。
- `mon`：只读监视端（所有信号均为 `input`）。

**设计亮点**：每个下游模块内部都会通过 `s_axis.DATA_W`、`s_axis.KEEP_EN && m_axis.KEEP_EN` 等方式自动提取接口参数，并在编译/Elaboration 阶段用 `$fatal` 检查端口位宽是否匹配，避免传统端口连线中隐蔽的位宽截断 Bug。

### 3.2 辅助连接与端接模块

| 模块 | 文件 | 功能 |
| :--- | :--- | :--- |
| `taxi_axis_tie` | [taxi_axis_tie.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_tie.sv) | 纯组合直连两个 `taxi_axis_if`，并在两边使能不一致时自动赋默认值（如 `tkeep='1`、`tlast=1'b1`、`tid='0`） |
| `taxi_axis_null_src` | [taxi_axis_null_src.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_null_src.sv) | 空源端，恒定输出 `tvalid = 1'b0` |
| `taxi_axis_null_snk` | [taxi_axis_null_snk.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_null_snk.sv) | 空宿端，恒定输出 `tready = 1'b1`（丢弃所有输入数据） |

---

## 4. 时序切分与流水线模块

在高速 FPGA 设计中，直接将上游的 `tvalid` / `tdata` 与下游的 `tready` 组合相连会导致关键路径过长。`taxi` 提供了三种寄存器切片选择。

### 4.1 `taxi_axis_register` ([taxi_axis_register.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_register.sv))

通过 `REG_TYPE` 参数选择三种工作模式：

1. **`REG_TYPE = 0`（Bypass 旁路）**：纯组合直连，零延迟，不切分时序。
2. **`REG_TYPE = 1`（Simple Buffer 简单寄存器）**：
   - 仅有一组输出寄存器 `m_axis_*_reg`。
   - `s_axis_tready_early = !m_axis_tvalid_next`，即只有当输出寄存器空或即将被下游取走时才拉高 `s_axis.tready`。
   - **缺点**：无法背靠背全速接收，每两拍插入至少一个气泡周期（最大吞吐率 50%）。适用于低带宽控制面或面积极度敏感场景。
3. **`REG_TYPE = 2`（Skid Buffer 滑移缓冲，默认推荐）**：
   - **核心原理**：除了主输出寄存器 `m_axis_*_reg` 外，额外增加一组临时缓冲寄存器 `temp_m_axis_*_reg`。
   - **时序特性**：`s_axis.tready`、`m_axis.tvalid` 和 `m_axis.tdata` **全部由寄存器直接驱动**，彻底切断前向和后向组合路径，同时实现 **0 气泡、100% 满吞吐率**。
   - **工作流程**：
     - 正常情况下，输入直接存入 `m_axis_*_reg`（`store_axis_input_to_output`）。
     - 当下游突然反压（`m_axis.tready == 0`），而本周期 `s_axis.tready` 仍为 1 且上游发来新数据时，将数据暂存到 `temp_m_axis_*_reg`（`store_axis_input_to_temp`），并在下一拍拉低 `s_axis.tready`。
     - 当下游恢复 `m_axis.tready == 1` 时，将 `temp` 中的数据倒回 `m_axis_*_reg`（`store_axis_temp_to_output`）。

### 4.2 `taxi_axis_pipeline_register` 与 `taxi_axis_pipeline_fifo`

- **`taxi_axis_pipeline_register`** ([taxi_axis_pipeline_register.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_pipeline_register.sv))：通过 `genvar` 串联 `LENGTH` 级 `taxi_axis_register`。用于跨 SLR 或长距离布线时逐级打拍。
- **`taxi_axis_pipeline_fifo`** ([taxi_axis_pipeline_fifo.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_pipeline_fifo.sv))：针对极高频长链路设计。每一级同时对前向信号（`tdata`、`tvalid` 等）和后向 `tready` 打拍，末端配一个小型弹性 FIFO 吸收由于 `tready` 延迟返回而多滑入链路中的数据。

---

## 5. FIFO 存储与跨时钟域（CDC）

### 5.1 同步 FIFO：`taxi_axis_fifo` ([taxi_axis_fifo.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_fifo.sv))

`taxi_axis_fifo` 是网络数据包处理中最核心的模块之一，支持普通字节流模式与**数据包帧模式（Frame FIFO）**：

- **基本存储参数**：
  - `DEPTH`：FIFO 深度（单位为字节/word；若 `KEEP_EN=1`，实际周期深度为 `DEPTH / KEEP_W` 并向上取整到 2 的幂）。
  - `RAM_PIPELINE`：RAM 读出流水线级数（默认为 1，配合 BRAM 输出寄存器提升 Fmax）。
  - `OUTPUT_FIFO_EN`：启用小型分布式输出 FIFO，去除 RAM 读使能与流水线时钟使能，进一步优化高频时序。
- **Frame FIFO 模式（`FRAME_FIFO = 1`）**：
  - **Store-and-Forward（存储转发）**：只有当一整个数据包（以 `tlast == 1` 结尾）完整写入 FIFO 后，才更新提交写指针 `wr_ptr_commit_reg`，下游才能开始读取。这保证了**帧内 `m_axis.tvalid` 绝不拉低**（防止 MAC 发送时发生下溢 Underrun）。
  - **异常帧处理**：
    - `DROP_OVERSIZE_FRAME`：若单帧长度超过 FIFO 总深度，自动回滚写指针丢弃该帧。
    - `DROP_BAD_FRAME`：若帧尾 `tuser` 匹配 `USER_BAD_FRAME_VALUE & USER_BAD_FRAME_MASK`（如以太网 FCS 校验错误），直接回滚丢弃，不发往下游。
    - `DROP_WHEN_FULL`：FIFO 满时恒定保持 `s_axis.tready = 1`，直接丢弃新来的整帧（避免反压上游导致线头阻塞 HOL）。
    - `MARK_WHEN_FULL`：非 Frame 模式下，满时不反压而是给当前帧打上坏帧标记。
- **流控与状态**：
  - `PAUSE_EN` / `FRAME_PAUSE`：支持暂停输出（可在当前帧结束后暂停）。
  - `status_depth`、`status_depth_commit`、`status_overflow`、`status_bad_frame`、`status_good_frame`。

### 5.2 异步 FIFO：`taxi_axis_async_fifo` ([taxi_axis_async_fifo.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_async_fifo.sv))

用于 `s_clk` 与 `m_clk` 之间的跨时钟域传输，功能特性与 `taxi_axis_fifo` 完全对齐（同样支持 `FRAME_FIFO`、丢包与暂停）：
- **指针同步**：使用 `bin2gray` 将读写指针转为格雷码，经两级同步器跨时钟域。
- **Frame 模式跨时钟域提交**：通过握手信号 `wr_ptr_update` / `wr_ptr_update_ack` 将提交写指针 `wr_ptr_sync_commit_reg` 安全传递到读时钟域。
- **Vivado 时序约束**：在综合/实现阶段需加载 [taxi_axis_async_fifo.tcl](file:///home/chenye/learning/taxi/src/axis/syn/vivado/taxi_axis_async_fifo.tcl)，它会自动查找所有 `taxi_axis_async_fifo` 实例，设置 `ASYNC_REG TRUE`、`set_max_delay -datapath_only` 以及 `set_bus_skew` 约束。

---

## 6. 位宽转换模块

### 6.1 `taxi_axis_adapter` ([taxi_axis_adapter.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_adapter.sv))

自动根据 `s_axis` 和 `m_axis` 的字节通道数（`S_BYTE_LANES` 与 `M_BYTE_LANES`）生成三种电路之一：
- **相同位宽**：自动 `bypass`。
- **位宽变大（`upsize`，如 8-bit → 64-bit）**：内部用段计数器 `seg_reg` 将多个窄拍拼接为一拍宽数据，最后一拍未填满时通过 `m_axis.tkeep` 精确指示有效字节。
- **位宽变小（`downsize`，如 64-bit → 8-bit）**：将一拍宽数据拆分为多拍窄数据依次输出，并跳过 `tkeep == 0` 的无效尾部字节。

> **注意**：`S_BYTE_SIZE` 必须等于 `M_BYTE_SIZE`（即每个通道的 bit 数必须一致，通常都是 8-bit 字节）。

### 6.2 `taxi_axis_fifo_adapter` 与 `taxi_axis_async_fifo_adapter`

将 FIFO 与 Adapter 合二为一的常用组件，其内部遵循**面积与时序最优原则（`EXPAND_BUS`）**：
- 若为 **Upsize**（窄进宽出）：先经过 `taxi_axis_adapter` 扩宽位宽，再写入宽位宽的 FIFO。
- 若为 **Downsize**（宽进窄出）：先写入宽位宽的 FIFO，读出后再经过 `taxi_axis_adapter` 缩窄位宽。
- 这样 FIFO 始终工作在**较宽的数据位宽（较低的读写频率或更少的控制开销）**下。

---

## 7. 多路复用、路由与交换

| 模块 | 文件 | 拓扑 | 核心机制 |
| :--- | :--- | :--- | :--- |
| `taxi_axis_mux` | [taxi_axis_mux.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_mux.sv) | N → 1 | 由外部 `enable` 与 `select` 控制。**帧级锁存**：一旦开始接收某通道数据包，`select_reg` 会锁定直到该帧 `tlast` 结束，防止数据包交织破坏。 |
| `taxi_axis_arb_mux` | [taxi_axis_arb_mux.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_arb_mux.sv) | N → 1 | 内置 `taxi_arbiter` 仲裁器，支持固定优先级或 Round-Robin（`ARB_ROUND_ROBIN`）。可选 `UPDATE_TID=1` 自动将来源端口号写入输出 `tid`。 |
| `taxi_axis_demux` | [taxi_axis_demux.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_demux.sv) | 1 → M | 支持外部 `select` 控制，或直接开启 `TID_ROUTE` / `TDEST_ROUTE` 根据包首拍的 `tid`/`tdest` 自动路由；支持 `drop` 信号整帧丢弃。 |
| `taxi_axis_switch` | [taxi_axis_switch.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_switch.sv) | N × M | 全功能包交换矩阵。支持 `AUTO_ADDR`（`tdest` 高位作端口号）或 `M_BASE`/`M_TOP` 地址区间路由；支持 `M_CONNECT` 稀疏连接矩阵以节省逻辑；可独立配置输入/输出寄存器类型（`S_REG_TYPE`、`M_REG_TYPE`）。 |
| `taxi_axis_broadcast` | [taxi_axis_broadcast.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_broadcast.sv) | 1 → M | 一对多复制广播。采用 Skid Buffer 结构，等待所有目标端均完成当前拍握手（`m_axis_tvalid_next == 0`）后才接收下一拍，避免单个慢速下游死锁。 |

---

## 8. 帧处理与协议封装

- **`taxi_axis_concat`** ([taxi_axis_concat.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_concat.sv))：帧拼接器。按端口 `0 → S_COUNT-1` 的顺序依次读取各输入接口的一整帧，拼成**单个**输出帧（中间各段的 `tlast` 被屏蔽，仅最后一段的 `tlast` 输出为 1）。常用于“帧头 + 载荷”的组装。
- **`taxi_axis_pad`** ([taxi_axis_pad.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_pad.sv))：最小帧长填充器。若输入帧字节数小于 `cfg_min_pkt_len`，自动在帧尾补 `0` 字节并拉高对应 `tkeep`，直到满足最小长度后才输出 `tlast`。常用于以太网 MAC 发送端满足 64 字节最小帧长要求。
- **`taxi_axis_cobs_encode` / `taxi_axis_cobs_decode`** ([taxi_axis_cobs_encode.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_cobs_encode.sv), [taxi_axis_cobs_decode.sv](file:///home/chenye/learning/taxi/src/axis/rtl/taxi_axis_cobs_decode.sv))：
  - 仅支持 `DATA_W = 8`。
  - 实现 **COBS（Consistent Overhead Byte Stuffing）** 编解码，消除数据流中的所有 `0x00` 字节，并用 `0x00` 作为帧定界符（`APPEND_ZERO = 1`）。
  - 编码器内部使用了 `code_fifo`（深度 256，记录每段非零长度）与 `data_fifo`（暂存数据）双 FIFO 协作，实现单遍流式编码。

---

## 9. 推荐学习路线与动手实验

### 9.1 建议学习顺序（由浅入深）

1. **第一阶段：接口与握手基础**
   - 阅读 `taxi_axis_if.sv` → `taxi_axis_tie.sv` → `taxi_axis_register.sv`（重点精读 `REG_TYPE = 2` Skid Buffer 的状态转移与 `s_axis_tready_early` 公式）。
2. **第二阶段：存储与跨时钟域**
   - 阅读 `taxi_axis_fifo.sv`（对比普通模式与 `FRAME_FIFO` 模式的指针管理） → `taxi_axis_async_fifo.sv` 与 `taxi_axis_async_fifo.tcl`。
3. **第三阶段：数据变换与路由**
   - 阅读 `taxi_axis_adapter.sv` → `taxi_axis_mux.sv` / `taxi_axis_arb_mux.sv` → `taxi_axis_demux.sv` → `taxi_axis_switch.sv`。
4. **第四阶段：综合应用**
   - 阅读 `taxi_axis_concat.sv`、`taxi_axis_pad.sv`、`taxi_axis_cobs_encode.sv`。

### 9.2 动手运行仿真实验

在 `/home/chenye/learning/taxi` 根目录下，使用 `.venv` 中的 `pytest` 运行单个模块的回归测试（以 `taxi_axis_register` 为例）：

```bash
# 1. 运行单个模块的完整参数化测试（使用 Verilator）
.venv/bin/pytest src/axis/tb/taxi_axis_register/test_taxi_axis_register.py -v

# 2. 如果只想跑某一个参数组合，可以用 -k 过滤
.venv/bin/pytest src/axis/tb/taxi_axis_register/test_taxi_axis_register.py -k "DATA_W=8 and REG_TYPE=2" -v
```

### 9.3 生成并查看波形（推荐学习方式）

进入具体测试目录，使用 `make` 开启 `WAVES=1` 生成 `.fst` 波形文件，然后用 `gtkwave` 打开观察握手时序：

```bash
cd /home/chenye/learning/taxi/src/axis/tb/taxi_axis_register

# 激活虚拟环境，编译并运行仿真（生成 dump.fst）
PATH=/home/chenye/learning/taxi/.venv/bin:$PATH make SIM=verilator WAVES=1

# 使用 GTKWave 查看波形
gtkwave dump.fst &
```

> **实验小贴士**：
> - 在 `taxi_axis_register` 波形中，重点观察 `backpressure_inserter`（下游 `m_axis.tready` 周期性拉低）时，`temp_m_axis_tvalid_reg` 是如何接管数据并保持 `m_axis` 零气泡输出的。
> - 在 `taxi_axis_fifo` 波形中，尝试将 `Makefile` 里的 `PARAM_FRAME_FIFO` 改为 `1`，对比帧提交前后 `wr_ptr_reg` 与 `wr_ptr_commit_reg` 的变化。
