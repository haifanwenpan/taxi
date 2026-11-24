# taxi AXI RTL 精读手册

> 本文与同目录的 [README_LEARNING.md](README_LEARNING.md) 分工不同:
> - `README_LEARNING.md` 是**概览 + 地图**, 回答"这个库有什么、每个模块干什么"。
> - **本文是"逐行精读 + 时序推导"**, 回答"这行代码为什么这么写、握手到底在第几拍发生、参数改动会连锁影响什么"。
>
> 阅读本文的前提: 知道 `valid/ready` 是什么, 但**不要求**你写过 AXI。
> 本文所有波形数据都来自本机实跑(见 §1.4), 不是示意图; 凡是"实测"二字, 都可以用 `lab/` 下的 testbench 复现。

---

## 目录

- [§1 学习方法与实验环境](#1-学习方法与实验环境)
- [§2 AXI4 协议: 只讲 RTL 里用得上的部分](#2-axi4-协议只讲-rtl-里用得上的部分)
- [§3 代码骨架: 这个库的六条写法约定](#3-代码骨架这个库的六条写法约定)
- [§4 第一块积木: register 的三种类型](#4-第一块积木register-的三种类型)
- [§5 RAM 系列](#5-ram-系列)
- [§6 FIFO](#6-fifo)
- [§7 Adapter: 位宽转换](#7-adapter位宽转换)
- [§8 Crossbar: 全连接交换](#8-crossbar全连接交换)
- [§9 Interconnect: 共享通路交换](#9-interconnect共享通路交换)
- [§10 Tie / 1s 封装 / 双口 RAM](#10-tie--1s-封装--双口-ram)
- [§11 参数联动速查与踩坑清单](#11-参数联动速查与踩坑清单)
  - [11.7 一份实测记录: 11 行隐式跨层次引用](#117-一份实测记录-11-行隐式跨层次引用-在库里能编过-在你工程里编不过)
- [§12 动手实验](#12-动手实验)
- [附录 A 文件清单与依赖](#附录-a-文件清单与依赖)
- [附录 B 术语表](#附录-b-术语表)

---

## §1 学习方法与实验环境

### 1.1 不要从最大的文件开始读

`rtl/` 下 63 个 `.sv` 共 18432 行, 最大的 `taxi_axi_adapter_wr.sv` 有 906 行。**按行数排序去读是最差的学习路径**: adapter 是"位宽转换 + 突发重打包 + 响应合并"三件事的叠加, 没有前面的积木做铺垫, 读起来就是天书。

推荐顺序(后面的模块只由前面的模块构成):

```
taxi_axi_if.sv            接口: 所有信号的唯一定义处
      │
      ├── taxi_axi_register_wr/rd.sv   寄存器(bypass/simple/skid)   ← 握手基本功
      │        └── taxi_axi_register.sv   (wrapper)
      │
      ├── taxi_axi_ram.sv              最小可用从机(3 态 FSM)
      │
      ├── taxi_axi_fifo_wr/rd.sv       打包 + 指针 + skid
      │        └── taxi_axi_fifo.sv
      │
      ├── taxi_axi_crossbar_addr.sv    地址解码 + 线程追踪   ← 全库最烧脑的 400 行
      │        ├── taxi_axi_crossbar_wr.sv
      │        └── taxi_axi_crossbar_rd.sv
      │
      ├── taxi_axi_adapter_wr/rd.sv    位宽转换(最大最绕)
      │
      └── taxi_axil_*.sv               AXI-Lite 一整套(结构同构, 砍掉突发)
```

**读法建议**: 每读完一个模块, 立刻做两件事 —— (a) 在纸上画出 FSM 和每一拍 valid/ready 的翻转; (b) 把它扔进 verilator 跑一遍, 用 `$display` 打逐拍表格。只看不跑, 握手这块永远学不会, 因为握手的正确性只在**跨拍**关系里体现。

### 1.2 三个层次的"读懂"

| 层次 | 判断标准 | 对应本文的章节 |
|---|---|---|
| L1 能讲清接口 | 说出每个信号属于哪个通道、谁是源谁是宿 | §2, §3 |
| L2 能画出时序 | 给定激励, 写出第 N 拍所有 valid/ready 的值 | §4, §5, §6 |
| L3 能改能扩 | 改一个参数, 预判哪些 `localparam` 会连锁变化、哪里会 `$fatal` | §7, §8, §11 |

本文刻意把 L2 的内容写成**表格**(实测波形), 而不是文字描述 —— 表格能直接和仿真结果对照, 文字不能。

### 1.3 仓库里的测试基础设施

```
src/axi/tb/                 20 个测试目录
  taxi_axi_ram/
    Makefile                  cocotb 标准 makefile + 参数注入
    test_taxi_axi_ram.sv     只例化 interface 和 DUT 的薄壳
    test_taxi_axi_ram.py     cocotb 测试(cocotbext-axi 的 AxiMaster)
```

`tb/taxi_axi_ram/Makefile` 里有两个值得学的技巧:

1. **参数注入**: `export PARAM_DATA_W := 32`, 然后在 verilator 下变成 `-GDATA_W=32`, 在 icarus 下变成 `-P test_taxi_axi_ram.DATA_W=32`。这样一份 testbench 能跑全部位宽组合。
2. **`.f` 文件展开**: Makefile 内嵌了 `process_f_file` / `process_f_files` / `uniq_base` 三个 make 函数, 递归展开依赖清单。因为 taxi 的模块靠 `.f` 声明依赖, 而 cocotb 只认源文件列表。

`tb/taxi_axi_ram/test_taxi_axi_ram.sv` 里有一个**故意的坑**, 值得记:

```systemverilog
taxi_axi_if #(.DATA_W(DATA_W), .ADDR_W(ADDR_W+16), .STRB_W(STRB_W), .ID_W(ID_W)) s_axi();
```

接口的 `ADDR_W` 开成了 `ADDR_W+16`, 比 DUT 的地址宽。这是在验证 §3.4 说的"`$fatal` 只在 DUT 地址宽于接口时才报错, 反过来(接口更宽)是合法的" —— DUT 只解码低 16 位, 高位被忽略。**这是一个免费的负向测试**: 如果哪天有人把比较写成了全宽相等, 这个 TB 会立刻失败。

### 1.4 本机实测环境(重要: 先看这段再敲命令)

本机环境: verilator 5.032, iverilog 12.0, Python 3.14.4, cocotb 2.1.0。

**cocotb 路线在本机跑不通, 有两个硬原因**:

```
$ make SIM=verilator
Makefile.verilator:29: *** cocotb requires Verilator 5.036 or later, but using 5.032.  Stop.

$ make SIM=icarus
../../rtl/taxi_axi_ram.sv:32: syntax error
Errors in port declarations
```

- 前者是 cocotb 2.1.0 的硬门槛(要求 verilator ≥ 5.036), 而 apt 源里只有 5.032。
- 后者是因为 `taxi_axi_ram.sv` 的端口是 `taxi_axi_if.wr_slv s_axi_wr` —— **interface modport 作为端口**, iverilog 不支持。

降级 cocotb 也不行: `cocotb 2.0.1 only supports a maximum Python version of 3.13.`, 而系统只有 Python 3.14。

**本文全部改用 verilator 自带的 SV 仿真能力, 完全绕开 cocotb**:

```bash
cd src/axi/lab
verilator --binary --timing -j 4 -Wno-fatal --top-module tb_axi_ram_trace \
  -o trace ../rtl/taxi_axi_if.sv ../rtl/taxi_axi_ram.sv tb_axi_ram_trace.sv
./obj_dir/trace
```

`--binary --timing` 让 verilator 直接编译 SystemVerilog testbench(含 `initial`、`#delay`、`$display`), 不需要 Python、不需要 cocotb、不需要 Makefile。**这是学 RTL 最省事的路径**, 建议你把它当默认手段; cocotb 留给需要随机化/覆盖率的大型回归。

> ⚠️ 文档里所有 `make SIM=...` 形式的命令都**标注了版本前提**。本机实测用的是 `verilator --binary --timing`, 这条路径已验证可用。

### 1.5 一个必须改掉的坏习惯

```systemverilog
// ❌ 会死循环: awready 是 posedge 后更新的寄存器输出, negedge 等它等于等一个永远不来的沿
@(negedge clk);
while (!s_axi.awready) @(negedge clk);
```

次态在 `always_comb` 算、`always_ff` 在 posedge 打进寄存器, 所以 `awready` 在**一个完整周期内是常量**。在 negedge 上轮询它, 要么立刻通过(如果恰好是 1), 要么永远卡住 —— 作者本人就被这个卡了 300 秒超时。

正确做法是**数握手次数**:

```systemverilog
integer aw_hs = 0;
always @(posedge clk) if (s_axi.awvalid && s_axi.awready) aw_hs = aw_hs + 1;

task automatic send_aw(...);
    int n; n = aw_hs;
    s_axi.awvalid <= 1'b1; ...
    while (aw_hs == n) @(negedge clk);   // 等到"发生过一次握手"
    s_axi.awvalid <= 1'b0;
endtask
```

用计数器还能顺手得到吞吐的量化数据(`accepted=8 at cycle=11` 就是数出来的), §4.5 的对比表就是这么来的。

---

## §2 AXI4 协议: 只讲 RTL 里用得上的部分

### 2.1 五个通道, 两条独立事务流

```
写事务:  AW ──►  W ──►  B          (地址 → 数据 → 响应)
读事务:  AR ──►  R                 (地址 → 数据)

AW/AR: 只走一趟, 携带"这笔突发怎么寻址"
W:     每拍一个 beat, 直到 wlast
B:     每笔突发一个响应
R:     ���拍一个 beat, 直到 rlast
```

关键点: **AW 和 W 没有先后约束**。主机可以先发 W 再发 AW, 甚至交叉。从机必须能同时缓存两者 —— 这就是为什么 `taxi_axi_crossbar_wr.sv` 里有一堆 `w_select_reg` 的"粘住"逻辑(§8.4)。

`taxi_axi_if.sv` 里的信号(261 行, 全库的唯一定义处):

| 通道 | 信号 | 宽度 | 含义 |
|---|---|---|---|
| AW | `awid` | `ID_W` | 事务标签, 响应时原样带回 |
| | `awaddr` | `ADDR_W` | 起始字节地址 |
| | `awlen` | 8 | 突发长度 − 1(0 表示 1 拍) |
| | `awsize` | 3 | 每拍字节数 = `2**awsize` |
| | `awburst` | 2 | `00` FIXED, `01` INCR, `10` WRAP |
| | `awlock` `awcache[3:0]` `awprot[2:0]` `awqos[3:0]` `awregion[3:0]` | | 属性, 多数从机忽略; **`awprot[1]` 是安全位, crossbar 会用它做访问控制**(§8.2) |
| | `awuser` | `AWUSER_W` | 用户自定义, 需 `AWUSER_EN` |
| | `awvalid` / `awready` | 1 | 握手 |
| W | `wdata` `wstrb` `wlast` `wuser` `wvalid` `wready` | | `wstrb` 每 bit 管一个字节,**窄传输靠它定位** |
| B | `bid` `bresp[1:0]` `buser` `bvalid` `bready` | | `bresp`: `00` OKAY, `10` SLVERR, `11` DECERR |
| AR/R | 同 AW/W/B, 无 `awlen` 的应答概念 | | `rresp` 在**每一拍**都出现, 不是只在 last |

### 2.2 握手的三条铁律(决定了所有 FSM 的写法)

1. **`valid` 一旦拉高, 不能因为对方 `ready` 为低而撤销**, 也不能改变 payload。→ 所以源侧要么有寄存器顶住, 要么等对方 ready 才拉 valid。
2. **`ready` 可以依赖 `valid`**(即 `assign ready = valid && ...`), 这是合法的组合路径, 也是 skid buffer 提前一拍给出 ready 的理论依据。
3. **`valid` 不能依赖 `ready`** —— 否则死锁。这条在代码里的体现是: 所有 `*_next` 的赋值语句里, `valid` 的表达式**从不出现对方的 `ready`**; 而 `ready` 的表达式经常出现对方的 `valid`。

对照 `taxi_axi_register_wr.sv:118` 那行, 就看得很清楚:

```systemverilog
wire s_axi_awready_early = m_axi_wr.awready || (!temp_m_axi_awvalid_reg && (!m_axi_awvalid_reg || !s_axi_wr.awvalid));
//     ↑ 源侧 ready                          ↑ 宿侧 ready   ↑ 这个依赖了 valid, 合法
```

`ready` 里出现 `!s_axi_wr.awvalid` 是允许的; 反过来写 `m_axi_awvalid_next = ... && s_axi_wr.awready` 就是死锁。

### 2.3 突发地址推进公式(全库出现最多的一行)

每发一拍, 地址怎么变:

```systemverilog
if (burst != 2'b00)                       // FIXED 不动
    addr_next = addr + (1 << size);       // INCR 和 WRAP 都按 2**size 递进
```

对应 `taxi_axi_ram.sv` 里的原文:

```systemverilog
if (write_burst_reg != 2'b00) begin
    write_addr_next = write_addr_reg + (1 << write_size_reg);
end
```

注意 `write_size_reg` 是被**钳位过**的:

```systemverilog
write_size_next = s_axi_wr.awsize <= 3'($clog2(STRB_W)) ? s_axi_wr.awsize : 3'($clog2(STRB_W));
```

即"主机说每拍 16 字节, 但我只有 4 字节总线, 那就按 4 字节走"。这是**窄传输降级**: 主机本来是整拍传输, 到了窄从机上退化成窄传输。反过来"主机窄、从机宽"要由 adapter 补 strobe(§7.3)。

WRAP 的地址回卷在 `taxi_axi_ram.sv` 里**没有实现**(它只区分 FIXED 和"非 FIXED"), 这是这个 RAM 模型的简化。真正需要 WRAP 语义的地方要自己加。

### 2.4 窄传输: 为什么 `wstrb` 是核心

假设 32 位总线(`STRB_W=4`), 主机发 `awsize=0`(1 字节), `awaddr=0x1002`:

```
wdata = 0x??????AB      (只有 1 字节有意义)
wstrb = 0b0100          (第 2 号字节车道有效)
```

**数据必须在它"该在的车道"上**, 而不是靠右对齐。所以:

- **窄→宽**(upsize): 主机数据只在低 `S_STRB_W` 位上, 从机需要把它搬到一个宽拍的某个车道里 → 复制到所有车道再用 strobe 点亮目标车道(§7.3)。
- **宽→窄**(downsize): 从宽拍里**切片**取当前车道 → §7.4。

`taxi_axi_ram.sv` 的字节写循环直接体现了这一点:

```systemverilog
for (integer i = 0; i < BYTE_LANES; i = i + 1)
    if (mem_wr_en & s_axi_wr.wstrb[i])
        mem[write_addr_valid][BYTE_W*i +: BYTE_W] <= s_axi_wr.wdata[BYTE_W*i +: BYTE_W];
```

**每个字节独立判断 strobe** —— 一行代码同时支持了整拍写和任意字节掩码写。

### 2.5 ID 与响应顺序

规则: **同 ID 的响应必须按请求顺序返回; 不同 ID 可以乱序。**

这条规则是所有 crossbar 里"ID 拼接"技巧的来源(§8.4): 从机侧有 4 个输入, 每个输入有自己的 ID 空间; 拼成一个下游 ID 后, 回程只需要看高位就知道"这笔响应属于哪个输入", 不需要任何查表。

如果没有 ID 支持, 多主多从就必须串行化 —— 这正是 `taxi_axi_interconnect_*`(§9)的做法。

### 2.6 从握手到数据可见: 逐拍推导

以 `taxi_axi_ram` 的写为例。为什么 AW 握手之后**要等一拍** W 通道才开?

因为 `s_axi_awready` 和 `s_axi_wready` **都是寄存器输出**:

```systemverilog
assign s_axi_wr.awready = s_axi_awready_reg;   // 寄存器
assign s_axi_wr.wready  = s_axi_wready_reg;    // 寄存器
```

`awready` 在 IDLE 态由 `always_comb` 置 1, posedge 打进 `s_axi_awready_reg`; 同一拍 `state_reg` 也打进去变成 BURST。**下一拍** `wready` 才会因为状态变了而拉高。所以:

```
拍 N   : awvalid=1, awready=1  → 握手发生(state_next=BURST)
拍 N+1 : state_reg=BURST, awready 落下, wready 升起  ← W 通道在这里才打开
```

实测数据在 §5.2 的表格里(`E3` 握手, `E4` 才有 W 握手)。

**这就是为什么库需要 skid buffer**: 组合逻辑给出的 ready 可以在**同一拍**响应, 寄存化的 ready 天然慢一拍。skid buffer 用 `ready_early` 公式把这个"慢一拍"消掉(§4.3)。

---

## §3 代码骨架: 这个库的六条写法约定

读懂这六条, 任何模块扫一眼就知道结构在哪。

### 3.1 约定一: 两阶段 `always_comb` / `always_ff`

```systemverilog
always_comb begin
    state_next = STATE_IDLE;          // ① 先给默认值(else 分支的省略靠它)
    <所有 *_next 都先赋"保持原值">    // ② 再写保持
    case (state_reg)                  // ③ 最后只写"变化"
        ...
    endcase
end

always_ff @(posedge clk) begin
    state_reg <= state_next;
    <所有寄存器 <= 对应 _next>
    if (rst) begin                    // ④ 同步复位, 放最后, 优先级最高
        ...
    end
end
```

四个细节都值得学:

- **默认值 + 保持**: 每个 `_next` 先 `= _reg`, 后面只在需要时覆盖。这样组合逻辑天然无 latch, 也不会漏赋值。
- **同步复位**: `if (rst)` 在 `always_ff` 末尾, 覆盖前面所有赋值。全库统一, 不混用异步复位。
- **复位只复位控制位**: 注意 `if (rst)` 里通常只复位 `*_valid_reg` 和状态, 数据寄存器不复位(省面积)。例如 `taxi_axi_register_wr.sv` 的复位块只有三行: `s_axi_awready_reg`、`m_axi_awvalid_reg`、`temp_m_axi_awvalid_reg`。
- **`state_next` 的第一个赋值必须是 IDLE 或"保持"**: 取决于模块风格, 两种都有; `taxi_axi_ram.sv` 用 IDLE, 大多数用 `state_next = state_reg`。

### 3.2 约定二: 参数从接口实例提取, 不重复配置

```systemverilog
// taxi_axi_ram.sv
localparam VALID_ADDR_W = ADDR_W - $clog2(STRB_W);
localparam BYTE_LANES = STRB_W;
localparam BYTE_W = DATA_W / BYTE_LANES;

// taxi_axi_register_wr.sv
localparam DATA_W = s_axi_wr.DATA_W;      // ← 从 interface 实例读
localparam ADDR_W = s_axi_wr.ADDR_W;
localparam STRB_W = s_axi_wr.STRB_W;
localparam ID_W   = s_axi_wr.ID_W;
```

**为什么重要**: interface 的 `parameter` 在例化时确定, 模块里再去 `parameter` 一遍就产生了**两个配置源**, 用户忘改一处就是灾难。所以模块的参数表里通常只有"行为参数"(`REG_TYPE`、`PIPELINE_OUTPUT`、`CONVERT_BURST`), 没有"位宽参数"。

例外是 `taxi_axi_ram.sv` / `taxi_axi_dp_ram.sv`: 它们要 `ADDR_W`, 因为**存储深度不能从 AXI 接口推出来** —— 一个 32 位地址的接口可以接 64KB 也可以接 4GB 的 RAM。所以这几个模块的 `ADDR_W` 是独立的, 并且配有自检(§3.4)。

### 3.3 约定三: `T'(expr)` 位宽转型, 不用 `$signed`

```systemverilog
assign m_axi_rd.arid   = m_axi_rd.ID_W'(s_axi_rd.arid);       // 截断或零扩展
assign m_axi_rd.araddr = m_axi_rd.ADDR_W'(s_axi_rd.araddr);
m_axi_awlen_next = (s_axi_wr.awlen + 8'(s_axi_wr.awaddr[..])) >> CL_SEG_COUNT;
```

好处: 一眼看出"目标宽度是多少", 而且 verilator 不会报 `WIDTHTRUNC` 之外的隐式转换警告。**全库没有一处 `$signed`** —— 因为 AXI 全是无符号字节地址。

### 3.4 约定四: elaboration 期自检(`$fatal` 是设计的一部分)

这些 `$fatal` 在**综合前**就会炸, 属于"用仿真器做静态检查":

```systemverilog
// taxi_axi_ram.sv
if (BYTE_W * STRB_W != DATA_W)
    $fatal(0, "Error: AXI data width not evenly divisible (instance %m)");
if (s_axi_wr.ADDR_W < ADDR_W || s_axi_rd.ADDR_W < ADDR_W)
    $fatal(0, "Error: AXI address width is insufficient (instance %m)");

// taxi_axi_tie_rd.sv —— 注意方向: 输出可以更宽, 输入不能更宽
if (m_axi_rd.ADDR_W > ADDR_W)
    $fatal(0, "Error: Output ADDR_W is wider than input ADDR_W, cannot access entire address space (instance %m)");
if (m_axi_rd.ID_W < ID_W)
    $fatal(0, "Error: Output ID_W is narrower than input ID_W, cannot discard ID bits (instance %m)");
```

`tie` 的检查方向很不直观, 值得单独记: `tie` 是"同一根线两头位宽不同"的适配器。
- **地址变宽** = 地址空间被切掉一块 = 不能接受。
- **ID 变窄** = 事务标签被合并 = 响应会张冠李戴 = 不能接受。
- 反过来(地址变窄、ID 变宽)都是安全的, 允许。

### 3.5 约定五: 文件头尾的防御性声明

```systemverilog
`timescale 1ns / 1ps
`default_nettype none
...
endmodule

`resetall
```

- `default_nettype none`: 拼错的信号名从"隐式 wire 警告"升级成"编译错误"。**这个库敢写 64 个文件不出错, 靠的就是它。**
- `resetall` 放在 `endmodule` **之后**: 防止本文件的 `timescale`/`default_nettype` 泄漏到下一个文件。每个文件自成一体。
- 注意 `taxi_axi_if.sv` 和纯 interface 文件**没有** `default_nettype none` —— interface 内部不涉及隐式网络。

### 3.6 约定六: `generate` 按"宽度关系"分三支

adapter / register 都是这个形状:

```systemverilog
if (M_BYTE_LANES == S_BYTE_LANES) begin : bypass       // 等宽 → 直连
    ...
end else if (M_BYTE_LANES > S_BYTE_LANES) begin : upsize   // 变宽
    ...
end else begin : downsize                                   // 变窄
    ...
end
```

三支代码看起来高度重复(adapter_wr 里 1300 行的 upsize/downsize 大部分对称), **但这是故意的**: 每一支都是独立的、可以单独读懂的 FSM, 而不是塞满 `if (EXPAND)` 的一坨。工程上"重复但可读"胜过"参数化但看不懂"。

---

## §4 第一块积木: register 的三种类型

`taxi_axi_register_wr.sv`(623 行)/ `_rd.sv`(472 行), 参数只有三个:

```systemverilog
parameter AW_REG_TYPE = 1,   // 0 to bypass, 1 for simple buffer, 2 for skid buffer
parameter W_REG_TYPE  = 2,
parameter B_REG_TYPE  = 1,
```

每个通道独立 `generate`, 所以可以 AW 用 bypass、W 用 skid。**这是全库最值得先读的文件**, 因为它把"寄存器切分"这件事讲透了, 而后面所有模块的性能差异都源于此。

### 4.1 type 0: bypass

```systemverilog
end else begin : bypass
    assign s_axi_wr.awready = m_axi_wr.awready;
    assign m_axi_wr.awid    = s_axi_wr.awid;
    ...
    assign m_axi_wr.awvalid = s_axi_wr.awvalid;
```

纯组合直连。**零延迟、零面积、零时序改善** —— 从机 ready 到主机 ready 是一条组合路径, 频率上不去。

### 4.2 type 1: simple buffer(有气泡)

```systemverilog
end else if (AW_REG_TYPE == 1) begin : simple
    // simple register, inserts bubble cycles          ← 注释自己就承认了

    assign s_axi_wr.awready = s_axi_awready_reg;      // 注意: ready 是寄存器

    // enable ready input next cycle if output buffer will be empty
    wire s_axi_awready_eawly = !m_axi_awvalid_next;   // ← 原文拼写 "eawly" (early 的笔误)

    always_comb begin
        m_axi_awvalid_next = m_axi_awvalid_reg;
        store_axi_aw_input_to_output = 1'b0;

        if (s_axi_awready_reg) begin
            m_axi_awvalid_next = s_axi_wr.awvalid;    // 收下
            store_axi_aw_input_to_output = 1'b1;
        end else if (m_axi_wr.awready) begin
            m_axi_awvalid_next = 1'b0;                // 放走
        end
    end

    always_ff @(posedge clk) begin
        s_axi_awready_reg <= s_axi_awready_eawly;
        m_axi_awvalid_reg <= m_axi_awvalid_next;
        ...
```

**逐拍推演**(下游 `awready` 恒 1, 上游连续给 `awvalid`):

| 拍 | `awready_reg`(旧) | `awvalid_next` | `awready_eawly = !awvalid_next` | 结果 |
|---|---|---|---|---|
| 1 | 1 | 1(收下) | 0 | 接收第 1 笔 |
| 2 | 0 | 0(下游吃掉) | **1** | 拒收 |
| 3 | 1 | 1(收下) | 0 | 接收第 2 笔 |
| 4 | 0 | 0 | 1 | 拒收 |

**严格的 2 拍一笔**。原因是 `awready` 本身是寄存器, 它只能反映"上一拍算出的 `valid_next`", 于是"收 → 放 → 收"这个循环至少要 2 拍。

对比 skid(§4.3): 它的 `ready` 是**组合**的 `ready_early`, 当拍就能判断"影子寄存器还能不能再装一个", 所以能连续收。

> 那行 `wire s_axi_awready_eawly` 的拼写错误(`eawly` 而非 `early`)在 `taxi_axi_register_wr.sv:239` 原位保留, 全库只有这一处。读源码时遇到这种"看起来像笔误的变量名"不要急着改 —— 它是历史遗留, 改了会和上游 diff 打架。

### 4.3 type 2: skid buffer(零气泡)

skid buffer 有两组寄存器: 主寄存器(`m_axi_aw*_reg`)和影子寄存器(`temp_m_axi_aw*_reg`)。核心是那个 `ready` 的前瞻公式(`taxi_axi_register_wr.sv:118`):

```systemverilog
// enable ready input next cycle if output is ready or the temp reg will not be filled on the next cycle
wire s_axi_awready_early =
    m_axi_wr.awready                                          // ① 下游直接能吃
    || (!temp_m_axi_awvalid_reg                               // ② 影子寄存器空着
        && (!m_axi_awvalid_reg || !s_axi_wr.awvalid));         // ③ 且 主寄存器空 或 上游这拍没给数据
```

**为什么这样就能零气泡?** 关键是第①项: 只要下游 `awready=1`, 公式立刻等于 1, **与影子寄存器、主寄存器状态完全无关**。所以下游畅通时:

```
拍 1 : ready_reg=1, 上游给数据, m.awready=1 → 直通进主寄存器
       awready_early = 1 → ready_reg 下一拍还是 1
拍 2 : ready_reg=1, 上游给数据, m.awready=1 → 直通进主寄存器
       awready_early = 1
拍 3 : 同拍 2 …
```

**每拍收一笔, 与 bypass 完全同速**(§4.4 实测: 12 拍 vs 12 拍, 一模一样)。这就是 skid buffer 相对 bypass 的价值: **寄存器隔离是免费的**。

再看下游堵住的情况(`m.awready` 从 1 变 0, 上游持续 valid):

```
拍 3 : ready_reg=1, main=1(上一笔), temp=0, 上游 awvalid=1
       → 走 else 分支: temp_next = awvalid = 1 (灌影子)
       awready_early = 0 || (!temp(1) && (!main(0) || !awvalid(0))) = 1 && 0 = 0
       → 这一拍**还是收下了**(第三笔进影子, 主寄存器正被下游堵着)
拍 4 : ready_reg=0, main=1, temp=1
       → 两个寄存器都满, 无法再收, awready_early = 0
拍 5 : 下游 m.awready 恢复 → 走 else-if: main_next = temp, temp_next = 0
       awready_early = 1 → ready_reg 下一拍恢复
拍 6 : 又能收
```

**skid buffer 的本质是"两个槽位"**: 主槽正被下游堵着时, 影子槽还能再接一笔, 于是上游不会在"下游刚堵"的那一拍就被拒绝。这就是 `ready_early` 里 `!temp_valid` 项的作用。

**为什么叫 skid(滑移)**: 因为数据在"输入 → 影子 → 主 → 输出"之间可以逐级滑移一级, 类似打滑。只有 2 级, 所以最多吸收 1 拍的抖动; 要吸收更多就要用 FIFO(§6)。

**三个控制位的完整代码**(`taxi_axi_register_wr.sv:119-146`, 原文):

```systemverilog
always_comb begin
    m_axi_awvalid_next = m_axi_awvalid_reg;
    temp_m_axi_awvalid_next = temp_m_axi_awvalid_reg;
    store_axi_aw_input_to_output = 1'b0;
    store_axi_aw_input_to_temp = 1'b0;
    store_axi_aw_temp_to_output = 1'b0;

    if (s_axi_awready_reg) begin
        // input is ready
        if (m_axi_wr.awready || !m_axi_awvalid_reg) begin
            // output is ready or currently not valid, transfer data to output
            m_axi_awvalid_next = s_axi_wr.awvalid;
            store_axi_aw_input_to_output = 1'b1;
        end else begin
            // output is not ready, store input in temp
            temp_m_axi_awvalid_next = s_axi_wr.awvalid;
            store_axi_aw_input_to_temp = 1'b1;
        end
    end else if (m_axi_wr.awready) begin
        // input is not ready, but output is ready
        m_axi_awvalid_next = temp_m_axi_awvalid_reg;
        temp_m_axi_awvalid_next = 1'b0;
        store_axi_aw_temp_to_output = 1'b1;
    end
end
```

上面三个 case 恰好覆盖了"直通 / 灌影子 / 影子吐货"三种转移, 就是 skid buffer 的全部状态机。

> 注意 B 通道是**反方向**的: `wire m_axi_bready_early = s_axi_wr.bready || (!temp_s_axi_bvalid_reg && (!s_axi_bvalid_reg || !m_axi_wr.bvalid));`(`:496`)。所以 skid 是**双向对称**的: 降速方向(AW/W)给 `ready`, 升速方向(B/R)给 `bready`/`rready`。

### 4.4 实测: 三种类型的吞吐

测试方法(`lab/vsim/tb_reg.sv`): 源侧永远抱着 `awvalid` 等握手, 连续发 8 笔 AW, 数发完 8 笔一共过了多少周期。两种下游 ready 图案: 恒 1, 以及每拍轮转的 `101` 图案。

| REG_TYPE | 下游 `awready` 恒 1 | 下游 `awready` 走 `101` 图案 |
|---|---|---|
| 0 bypass | **12 拍** | 16 拍 |
| 1 simple | **19 拍** | **26 拍** |
| 2 skid | **12 拍** | **15 拍** |

绝对周期数里含一个固定的启动开销(复位释放 + 第一笔装载), 所以**要看差值, 不要看绝对值**:

| 对比 | 恒 1 | `101` 图案 |
|---|---|---|
| simple − bypass | **+7 拍** (8 笔, ≈ +0.9 拍/笔) | **+10 拍** (≈ +1.25 拍/笔) |
| skid − bypass | **0** | **−1** (skid 反而更快) |

读法:

- **bypass 与 skid 吞吐相同**(恒 ready 时 12 = 12), skid 的寄存器隔离**没有付出任何吞吐代价**。这是 skid buffer 存在的全部理由。
- **simple 每笔多花约 1 拍**, 也就是稳态吞吐减半(1 拍/笔 → 2 拍/笔) —— 这不是"稍差", 是"砍半"。
- 下游 ready 抖动时, **skid 反超 bypass**(15 < 16) —— 因为 skid 的寄存器吸收了抖动, 而 bypass 把抖动直接传到源侧, 源侧每遇到一次 ready=0 就浪费一次往返。

**这三行数字就是 §4.5 那些默认参数的全部依据。** 它们不是风格偏好, 是量出来的。

**结论(库默认值的理由)**: crossbar 的默认参数是

```systemverilog
S_AW_REG_TYPE = {S_COUNT{2'd0}}   // 输入侧 AW: bypass
S_W_REG_TYPE  = {S_COUNT{2'd0}}   // 输入侧 W:  bypass
S_B_REG_TYPE  = {S_COUNT{2'd1}}   // 输入侧 B:  simple
S_AR_REG_TYPE = {S_COUNT{2'd0}}
S_R_REG_TYPE  = {S_COUNT{2'd2}}   // 输入侧 R:  skid
M_AW_REG_TYPE = {M_COUNT{2'd1}}   // 输出侧 AW: simple
M_W_REG_TYPE  = {M_COUNT{2'd2}}   // 输出侧 W:  skid
M_B_REG_TYPE  = {M_COUNT{2'd0}}
M_AR_REG_TYPE = {M_COUNT{2'd1}}
M_R_REG_TYPE  = {M_COUNT{2'd0}}
```

即"从机侧地址/数据直通, 主机侧数据用 skid"。理解成一句话: **地址通道不必抢那一拍(仲裁本身就有延迟), 数据通道必须满速。**

### 4.5 一个容易被忽略的细节: `simple` 用在响应通道上

`S_B_REG_TYPE` 默认是 1(simple), 而 `S_R_REG_TYPE` 默认是 2(skid)。为什么不对称?

B 通道每笔突发只有一个响应, 天然稀疏, 吞吐压力小 → 用便宜的 simple 就够。
R 通道是连续的数据流(每拍一个 beat), 吞吐压力大 → 必须 skid。

**参数选择要看通道的"稀疏度"**, 不是看方向。这条经验可以直接搬到自己的设计里。

---

## §5 RAM 系列

### 5.1 三种"RAM", 三种抽象层次

| 模块 | 行数 | 抽象层次 | 端口 |
|---|---|---|---|
| `taxi_axi_ram.sv` | 321 | AXI 直接包一个存储体, 自带 FSM | 单时钟, 1 写 1 读 |
| `taxi_axi_ram_if_wr/rd.sv` | 257/243 | 只做 **AXI → RAM 命令** 的翻译, 不含存储 | 命令流接口 |
| `taxi_axi_ram_if_rdwr.sv` | 236 | 把上面两个合并 | 命令流接口 |
| `taxi_axi_dp_ram.sv` | 244 | 用 `ram_if_rdwr` + 真双口存储 | **两个独立时钟** `a_clk`/`b_clk` |

**为什么要拆出 `ram_if_*`**: 因为存储体不该被 AXI 绑死。`taxi_axi_dp_ram` 需要把 AXI 接到一个双口 RAM 上, 如果 `taxi_axi_ram` 内部直接例化 `mem[][]`, 就没法复用。所以库把"AXI 协议处理"和"存储实现"切开:

```
AXI ──[taxi_axi_ram_if_wr/rd]──► ram_cmd_* 命令流 ──► 用户自己的存储
                                              ◄── ram_rd_resp_* 响应流
```

命令流接口(`taxi_axi_ram_if_rdwr.sv` 的端口):

```systemverilog
output ram_cmd_id/addr/lock/cache/prot/qos/region/auser
output ram_cmd_wr_data / ram_cmd_wr_strb / ram_cmd_wr_user
output ram_cmd_wr_en / ram_cmd_rd_en / ram_cmd_last
input  ram_cmd_ready
input  ram_rd_resp_id/data/last/user/valid
output ram_rd_resp_ready
```

**这个接口的形状本身就是个知识点**: 读写共用一组命令线, 用 `wr_en`/`rd_en` 区分, 且带 `ready` 反压。这是"单端口 RAM 加协议引擎"的标准形态, 可以直接抄去接 Xilinx/Intel 的 BRAM IP。

### 5.2 `taxi_axi_ram.sv` 逐行精读

**存储体与地址压缩**:

```systemverilog
localparam VALID_ADDR_W = ADDR_W - $clog2(STRB_W);
logic [DATA_W-1:0] mem[2**VALID_ADDR_W] = '{default: '0};      // :103

wire [VALID_ADDR_W-1:0] read_addr_valid =
    VALID_ADDR_W'(read_addr_reg >> (ADDR_W - VALID_ADDR_W));
```

为什么地址要右移? 因为 **AXI 地址是字节地址, 而存储器按"拍"寻址**。32 位数据 = 4 字节/拍, 所以地址低 2 位在存储体内是无效的(它们由 `wstrb` 和字节车道处理)。`ADDR_W=16`、`STRB_W=4` → `VALID_ADDR_W=14` → 16384 拍 × 4 字节 = 64KB。

那个 `>> (ADDR_W - VALID_ADDR_W)` 是"取高 14 位", 等价于 `[ADDR_W-1:2]`。写成移位而不是切片, 是为了**参数化**: 换位宽时不用改代码。

**写 FSM(3 态)**:

```systemverilog
WRITE_STATE_IDLE: begin
    s_axi_awready_next = 1'b1;              // 随时可以收地址
    if (s_axi_wr.awready && s_axi_wr.awvalid) begin
        ...  // 存 awid/awaddr/awlen/awsize/awburst
        s_axi_wready_next = 1'b1;
        state_next = WRITE_STATE_BURST;
    end
end
WRITE_STATE_BURST: begin
    s_axi_wready_next = 1'b1;               // 每拍都收
    if (s_axi_wr.wready && s_axi_wr.wvalid) begin
        mem_wr_en = 1'b1;                   // 组合写使能
        ...
        if (write_count_reg == 0) begin     // 最后一拍
            if (s_axi_wr.bready || !s_axi_wr.bvalid) begin
                s_axi_bvalid_next = 1'b1;   // 快路径: 直接回 B, 不进 RESP 态
                state_next = WRITE_STATE_IDLE;
            end else begin
                state_next = WRITE_STATE_RESP;
            end
        end
    end
end
WRITE_STATE_RESP: begin
    s_axi_bvalid_next = 1'b1;
    if (s_axi_wr.bready) begin
        state_next = WRITE_STATE_IDLE;
    end
end
```

**那个"快路径"值得单独说**: 如果主机 `bready` 已经为高(或者当前没有 B 在等待), 那么最后一拍写完就可以**直接**拉 `bvalid` 并回 IDLE, 省掉一个 IDLE 周期。实测中这条路径生效了 —— §5.3 的 `E8` 拍: W 的 last 拍握手, **同一拍** `B v1 r1` 出现, 状态已从 BURST(1) 回到 IDLE(0)。

这就是为什么 `WRITE_STATE_RESP` 在典型场景下几乎不会被用到: 只有当 `bready` 慢于数据时才需要它顶一拍。

**读侧(2 态)与 `rlast`**:

```systemverilog
s_axi_rlast_next = read_count_reg == 0;     // 计数到 0 就是最后一拍
```

注意 `rlast` 是**组合**从计数推出的, 所以它和最后一拍 `rdata` 同拍出现(实测 `E15`)。

**`PIPELINE_OUTPUT` 的作用**:

```systemverilog
assign s_axi_rd.rdata = PIPELINE_OUTPUT ? s_axi_rdata_pipe_reg : s_axi_rdata_reg;
...
if (!s_axi_rvalid_pipe_reg || s_axi_rd.rready) begin      // 只有能装载时才装
    s_axi_rdata_pipe_reg <= ...;
end
```

`PIPELINE_OUTPUT=0`: 存储输出直接进 `rdata`(同步读, 1 拍延迟)。
`PIPELINE_OUTPUT=1`: 再加一级寄存器, **切断"存储输出 → 输出端口"的组合路径**, 利于时序。代价是 `rvalid` 晚一拍。

判据 `if (!s_axi_rvalid_pipe_reg || s_axi_rd.rready)` 是标准的"pipe 级在能装的时候才装": 上一拍的数据没被取走(`rvalid_pipe=1` 且 `rready=0`)就不覆盖它。

### 5.3 实测波形: 一笔 4 拍写 + 一笔 4 拍读

环境: `DATA_W=32, ADDR_W=16, PIPELINE_OUTPUT=0`, 时钟 10ns。激励全部在 negedge 驱动, 追踪也在 negedge 采样(无竞争)。原始文件 `lab/tb_axi_ram_trace.sv`。

列含义: `AW v/r` = awvalid/awready, `W v/r/l/d` = wvalid/wready/wlast/wdata, `B v/r`, `AR v/r`, `R v/r/l/d`, `wst`/`rst` = 写/读状态机(`0`=IDLE, `1`=BURST), `mem4` = 存储体第 4 拍(地址 `0x0010`)。

| 拍 | t(ns) | AW v r | W v r l data | B v r | AR v r | R v r l data | wst | rst | mem4 |
|---|---|---|---|---|---|---|---|---|---|
| E0 | 10 | 0 0 | 0 0 0 00000000 | 0 1 | 0 0 | 0 1 0 00000000 | 0 | 0 | 00000000 |
| E1 | 20 | 0 0 | 0 0 0 00000000 | 0 1 | 0 0 | 0 1 0 00000000 | 0 | 0 | 00000000 |
| E2 | 30 | **1 0** | 0 0 0 00000000 | 0 1 | 0 0 | 0 1 0 00000000 | 0 | 0 | 00000000 |
| E3 | 40 | **1 1** | 0 0 0 00000000 | 0 1 | 0 **1** | 0 1 0 00000000 | 0 | 0 | 00000000 |
| E4 | 50 | 0 **0** | **1 1** 0 11111111 | 0 1 | 0 1 | 0 1 0 00000000 | **1** | 0 | 00000000 |
| E5 | 60 | 0 0 | 1 1 0 22222222 | 0 1 | 0 1 | 0 1 0 00000000 | 1 | 0 | **11111111** |
| E6 | 70 | 0 0 | 1 1 0 33333333 | 0 1 | 0 1 | 0 1 0 00000000 | 1 | 0 | 11111111 |
| E7 | 80 | 0 0 | 1 1 **1** 44444444 | 0 1 | 0 1 | 0 1 0 00000000 | 1 | 0 | 11111111 |
| E8 | 90 | 0 **1** | 0 **0** 0 44444444 | **1 1** | 0 1 | 0 1 0 00000000 | **0** | 0 | 11111111 |
| E9 | 100 | 0 1 | 0 0 0 44444444 | 0 1 | 0 1 | 0 1 0 00000000 | 0 | 0 | 11111111 |
| E10 | 110 | 0 1 | 0 0 0 44444444 | 0 1 | **1 1** | 0 1 0 00000000 | 0 | 0 | 11111111 |
| E11 | 120 | 0 1 | 0 0 0 44444444 | 0 1 | 0 **0** | 0 1 0 00000000 | 0 | **1** | 11111111 |
| E12 | 130 | 0 1 | 0 0 0 44444444 | 0 1 | 0 0 | **1 1** 0 11111111 | 0 | 1 | 11111111 |
| E13 | 140 | 0 1 | 0 0 0 44444444 | 0 1 | 0 0 | 1 1 0 22222222 | 0 | 1 | 11111111 |
| E14 | 150 | 0 1 | 0 0 0 44444444 | 0 1 | 0 0 | 1 1 0 33333333 | 0 | 1 | 11111111 |
| E15 | 160 | 0 1 | 0 0 0 44444444 | 0 1 | 0 **1** | 1 1 **1** 44444444 | 0 | **0** | 11111111 |
| E16 | 170 | 0 1 | 0 0 0 44444444 | 0 1 | 0 1 | 0 1 **1** 44444444 | 0 | 0 | 11111111 |

> 原始打印格式: `E3 t=40000|AW v1 r1|W v0 r0 l0 d00000000|B v0 r1|AR v0 r1|R v0 r1 l0 d00000000|wst0 rst0 mem4=00000000`。`t=40000` 是皮秒(`timescale 1ns/1ps`), 即 40ns。

**从这张表能读出的七条硬事实**(每条都对照 §2.6 的推导):

1. **AW 握手(E3)与 W 通道打开(E4)之间隔一拍** —— 因为 `awready`/`wready` 都是寄存器输出。
2. **W 通道满速**: E4–E7 连续 4 拍, 每拍一个 beat, 零气泡。
3. **最后一拍写完后一拍出 B**(E7 W-last → E8 B-valid), 且 **E8 同拍 `AW r` 已回 1** —— 快路径生效, 状态 `wst` 直接 1→0, 没有经过 RESP。
4. **写入晚一拍可见**(E4 握手 → E5 `mem4` 才变) —— 存储是同步写的。
5. **读: AR 握手(E10)后两拍出 R**(E12) —— 一拍用于 `READ_STATE_IDLE → READ_STATE_BURST` 的状态迁移, 另一拍是同步存储的读延迟(`if (mem_rd_en) s_axi_rdata_reg <= mem[read_addr_valid];`)。所以一笔读的最小延迟是 **2 拍**, 不是 1 拍; 后续 beat 靠 `READ_STATE_BURST` 的自循环变成 1 拍/beat(E12→E13→E14→E15)。
6. **`rlast` 与最后一拍数据同拍**(E15), 且 **`AR r` 在最后一拍读握手的那一拍就恢复为 1**(E11 拉低, E15 拉高) —— 读侧回到 IDLE 与最后的数据握手是同一拍, 没有额外空档。
7. **`B r` 与 `R r` 恒为 1**(E0 起), 因为 TB 里 `bready`/`rready` 一直为高。这也说明 RAM 的 B/R 通道不需要等主机 ready 才产生数据。

> 表格里 `rst` 列(读状态)从 E11 到 E15 保持 1, 对应 4 拍数据 + 1 拍等待, 与 `read_count_reg` 从 3 递减到 0 一致。

### 5.4 `taxi_axil_ram.sv`: 没有 FSM 的 RAM

AXI-Lite 没有突发, 一条命令就是一个完整事务, 所以 FSM 可以完全消掉:

```systemverilog
if (s_axil_wr.awvalid && s_axil_wr.wvalid
    && (!s_axil_wr.bvalid || s_axil_wr.bready)     // 响应通道能收
    && (!s_axil_wr.awready && !s_axil_wr.wready)) begin   // 且当前没在等
    s_axil_awready_next = 1'b1;
    s_axil_wready_next  = 1'b1;
    s_axil_bvalid_next  = 1'b1;
    mem_wr_en = 1'b1;
end
```

一次判断完成整笔写。注意那个 `!s_axil_wr.awready && !s_axil_wr.wready` —— 它是从**输出端口回读自己的 ready**, 用来自锁"本拍不重复接收"。这种写法在 AXI-Lite 里很常见, 但要注意它引入了一条"输出→输入"的反馈路径。

### 5.5 `taxi_axi_dp_ram.sv`: 真双口

```systemverilog
parameter A_PIPELINE_OUTPUT = 0, B_PIPELINE_OUTPUT = 0,
parameter A_INTERLEAVE = 0,      B_INTERLEAVE = 0,
...
input wire logic a_clk, b_clk     // ← 两个独立时钟
```

结构: 两个端口各一个 `taxi_axi_ram_if_rdwr` + 一个双口存储。`INTERLEAVE` 参数控制读写交织(读写命令交替优先级), 用来避免单侧饿死。

`AUSER_W` 的取法很有意思:

```systemverilog
localparam AUSER_W = s_axi_wr_a.AWUSER_W > s_axi_rd_a.ARUSER_W
                   ? s_axi_wr_a.AWUSER_W : s_axi_rd_a.ARUSER_W;
```

因为 `ram_cmd_auser` 是**读写共用**的一根线, 它必须容得下两者中较宽的那个。

未用端口直接悬空: `.ram_cmd_lock(), .ram_cmd_cache(), .ram_cmd_prot(), .ram_cmd_qos(), .ram_cmd_region(), .ram_cmd_auser()` —— SystemVerilog 里空连接是合法的, 这比定义一堆 dummy 信号干净。

---

## §6 FIFO

### 6.1 为什么要"打包"

AXI 的 W 通道是 5 根线(`wdata/wstrb/wlast/wuser/wvalid`), 要存进 FIFO 就得**拼成一个宽字**:

```systemverilog
localparam STRB_OFFSET  = DATA_W;                  // :51
localparam LAST_OFFSET  = STRB_OFFSET + STRB_W;
localparam WUSER_OFFSET = LAST_OFFSET + 1;
localparam WWIDTH       = WUSER_OFFSET + (WUSER_EN ? WUSER_W : 0);
```

以 `DATA_W=32, STRB_W=4, WUSER_EN=0` 为例:

```
WWIDTH = 32 + 4 + 1 = 37 bit

 [36]      wlast
 [35:32]   wstrb
 [31:0]    wdata
```

拼装与拆分都是纯 `assign`:

```systemverilog
assign s_axi_w[DATA_W-1:0]           = s_axi_wr.wdata;
assign s_axi_w[DATA_W +: STRB_W]     = s_axi_wr.wstrb;
assign s_axi_w[LAST_OFFSET]          = s_axi_wr.wlast;
if (WUSER_EN) assign s_axi_w[WUSER_OFFSET +: WUSER_W] = s_axi_wr.wuser;
```

**这种"offset 常量 + 连续拼接"的写法是全库的通用技巧**, 出现在 fifo / ram_if / register 各处。它的好处是**加一个字段只改两行**(一个 offset 定义 + 一条 assign), 不会像手写位下标那样改漏。

### 6.2 指针多一位: 满空区分

```systemverilog
localparam FIFO_AW = $clog2(FIFO_DEPTH);
logic [FIFO_AW:0] wr_ptr_reg = '0, wr_ptr_next;    // ← 注意 [FIFO_AW:0], 多一位

// full when first MSB different but rest same
wire full = ((wr_ptr_reg[FIFO_AW] != rd_ptr_reg[FIFO_AW]) &&
             (wr_ptr_reg[FIFO_AW-1:0] == rd_ptr_reg[FIFO_AW-1:0]));
// empty when pointers match exactly
wire empty = wr_ptr_reg == rd_ptr_reg;
```

`FIFO_AW+1` 位指针, 低位是地址, 最高位是"绕圈次数奇偶"。

- 全部相等 → 空
- 高位不同、低位相同 → 满(写指针正好领先一整圈)

相比"计数寄存器"方案, 这个方案省了一个计数器, 且**同一时刻就能判断满空**(不需要等计数更新)。

### 6.3 `FIFO_DELAY`: 扣住 AW, 等数据

这是 `taxi_axi_fifo_wr.sv` 里最反直觉的部分: 一个 3 态 FSM + 一整套 AW 影子寄存器。

> ⚠️ 这一节 `STATE_TRANSFER_OUT` 态里有两行把接口实例名写成了 `s_axi.`(少了 `_wr`)。`FIFO_DELAY=1'b1` 时, 如果你的父层没有一个恰好叫 `s_axi` 的接口实例, verilator 会报 `Can't find definition of scope/variable: 's_axi'`。见 [§11.7](#117-一份实测记录-11-行隐式跨层次引用-在库里能编过-在你工程里编不过)。

```systemverilog
if (FIFO_DELAY) begin
    // store AW channel value until W channel burst is stored in FIFO or FIFO is full
    typedef enum logic [1:0] { STATE_IDLE, STATE_TRANSFER_IN, STATE_TRANSFER_OUT } state_t;

    logic hold_reg = 1'b1, hold_next;          // ← 复位值就是 1!
    logic [8:0] count_reg = 9'd0, count_next;
```

注意 `hold_reg = 1'b1` 的初值: **复位后 `wready = !full && !hold` 立刻是 0**, FIFO 在收到第一笔 AW 之前根本不会接收 W 数据。这是刻意的 —— 没有 AW 就不知道这笔写从哪开始、什么时候 `wlast`。

逐态职责(原文):

```systemverilog
STATE_IDLE: begin
    s_axi_awready_next = !m_axi_wr.awvalid || m_axi_wr.awready;   // ① 下游能接才收 AW
    hold_next = 1'b1;                                            // ② 默认继续扣住 W
    if (s_axi_wr.awready && s_axi_wr.awvalid) begin
        // 把 11 个 AW 字段全部打进影子寄存器
        m_axi_awid_next = s_axi_wr.awid;  m_axi_awaddr_next = s_axi_wr.awaddr;  ...
        s_axi_awready_next = 1'b0;
        hold_next = 1'b0;                                        // ③ 放开 W
        count_next = 0;
        state_next = STATE_TRANSFER_IN;
    end else state_next = STATE_IDLE;
end

STATE_TRANSFER_IN: begin
    s_axi_awready_next = 1'b0;
    hold_next = 1'b0;
    if (s_axi_wr.wready && s_axi_wr.wvalid) begin
        count_next = count_reg + 1;
        if (s_axi_wr.wlast) begin
            m_axi_awvalid_next = 1'b1;                           // ④ 整笔收完 → 放 AW 下去
            hold_next = 1'b1;
            state_next = STATE_IDLE;
        end else if (FIFO_AW < 8 && count_next == 2**FIFO_AW) begin
            m_axi_awvalid_next = 1'b1;                           // ⑤ FIFO 满了 → 也得放 AW
            state_next = STATE_TRANSFER_OUT;
        end else state_next = STATE_TRANSFER_IN;
    end else state_next = STATE_TRANSFER_IN;
end

STATE_TRANSFER_OUT: begin
    s_axi_awready_next = 1'b0;
    hold_next = 1'b0;                                            // ⑥ W 还可以继续收
    if (s_axi_wr.wready && s_axi_wr.wvalid) begin
        if (s_axi_wr.wlast) begin
            hold_next = 1'b1;
            state_next = STATE_IDLE;
        end else state_next = STATE_TRANSFER_OUT;
    end else state_next = STATE_TRANSFER_OUT;
end
```

**两条退出路径**是这个 FSM 的精髓:

| 路径 | 条件 | 含义 |
|---|---|---|
| ④ 正常 | `wlast` 到来 | 整笔 W 已进 FIFO, 可以安全地把 AW 发给下游 |
| ⑤ 强制 | `count_next == 2**FIFO_AW`(且 `FIFO_AW < 8`) | FIFO 装满了, **再无脑扣住 AW 会死锁** —— 下游收不到 AW 就不会来取数据, FIFO 永远满。必须放 AW 出去 |

第 ⑤ 条是**防死锁的必需品**, 不是优化。想清楚这点: 如果把 AW 扣到整笔 W 全部入队, 而 W 突发长度(`awlen+1`)大于 FIFO 深度, 那么 FIFO 满了之后 `wready=0`, 上游永远发不完, `wlast` 永远不来, AW 永远不出去 → **死锁**。所以必须有一条"FIFO 满了就先放 AW"的逃生通道。

> `FIFO_AW < 8` 这个额外条件: 当 `FIFO_AW >= 8` 时 `2**FIFO_AW >= 256`, 而 AXI4 的最大突发是 256 拍, 所以"装不下整笔"的情况根本不存在, 这条分支不需要。

**默认是 0(不 delay)**, 因为 AXI 协议本身允许 AW 先于 W。什么时候该开 1? 当下游是个**要求"先有地址再有数据, 且不能容忍地址提早"**的老旧从机时。这是一种兼容性补救, 不是性能优化 —— 它会明显降低吞吐(AW 要等整笔 W)。

**代价的量化**: `FIFO_DELAY=1` 时, 每笔写的 AW 要等到 `wlast` 那一拍才可能下去, 于是 AW 与 W 完全串行化。`FIFO_DELAY=0` 时两者可流水。

### 6.4 输出级仍然是 skid

FIFO 内部存的是打包字, 但要输出到 AXI 端口仍需一级寄存器:

```systemverilog
if (m_axi_wr.wready || !m_axi_wr.wvalid) begin
    store_output = 1'b1;
    m_axi_wvalid_next = mem_read_data_valid_reg;
end
```

判据是"下游能吃 或 我手上没货" —— 就是 §4.3 里 skid 的直通分支。所以 **FIFO = 存储阵列 + skid 输出级**, 学会 skid 后 FIFO 就没有新东西了。

### 6.5 `taxi_axi_fifo_rd.sv` 的镜像与差异

打包格式多了一个 ID 和 resp(读响应必须带回 ID 和错误码):

```systemverilog
localparam LAST_OFFSET = DATA_W;
localparam ID_OFFSET   = LAST_OFFSET + 1;
localparam RESP_OFFSET = ID_OFFSET + ID_W;
localparam RUSER_OFFSET = RESP_OFFSET + 2;
```

反压方向不同:

```systemverilog
assign m_axi_rd.rready = !full;     // 读侧: FIFO 满就拒收
```

写侧是 `assign s_axi_wr.wready = !full && !hold;` —— 都是"下游由 FIFO 容量决定".

`FIFO_DELAY` 在读侧只有 2 态(`STATE_IDLE` / `STATE_WAIT`), 因为读只需"等 FIFO 有空间容下整笔突发再发 AR", 比写侧的"等数据全部入队"简单一档。

---

## §7 Adapter: 位宽转换

这是全库最大最绕的一块(`adapter_wr` 906 行 / `adapter_rd` 815 行)。读它之前必须先把三种情况分开, 否则 900 行会糊成一团。

### 7.1 三个分支

```systemverilog
if (M_BYTE_LANES == S_BYTE_LANES) begin : bypass        // :81   等宽, 纯 assign
end else if (M_BYTE_LANES > S_BYTE_LANES) begin : upsize // :111  变宽, 打包
end else begin : downsize                                // :496  变窄, 拆分
```

> ⚠️ **读这一章前先知道一件事**: `downsize`(:496 起)和 `FIFO_DELAY=1'b1` 那两条路径里, 有 11 行把接口实例名写成了 `s_axi.` / `m_axi.` / `m_axil.`(漏了 `_wr`/`_rd`)。这在 SystemVerilog 里是**隐式跨层次引用** —— 父层恰好有同名接口实例时能编过(作者的 TB 就是), 否则编不过; 而编过时读到的是父层那个实例, 不是本模块的端口, 本机实测能改变运行期行为。完整清单与证据见 [§11.7](#117-一份实测记录-11-行隐式跨层次引用-在库里能编过-在你工程里编不过)。本章讲的是**源码的意图与算法**, 那个算法本身是对的。

配套的 localparam(每支内部各自定义一遍):

```systemverilog
localparam SEG_COUNT   = EXPAND ? (M_BYTE_LANES / S_BYTE_LANES) : (S_BYTE_LANES / M_BYTE_LANES);
localparam CL_SEG_COUNT = $clog2(SEG_COUNT);
localparam SEG_DATA_W  = DATA_W / SEG_COUNT;
localparam SEG_STRB_W  = STRB_W / SEG_COUNT;
```

`SEG` = "段", 指宽总线被切成几个窄车道。32→128 位时 `SEG_COUNT=4`, `SEG_DATA_W=32`, `SEG_STRB_W=4`。

### 7.2 分支一: bypass

```systemverilog
begin : bypass
    assign s_axi_wr.awready = m_axi_wr.awready;
    assign m_axi_wr.awid    = s_axi_wr.awid;
    ...
```

和 §4.1 一样, 纯直连。**注意这里仍然有一个 FSM**(用于响应通路和 user 信号的条件路由), 但数据通路是组合的。

### 7.3 分支二: upsize —— 两个方向, 别搞混

upsize 有**两种工作模式**, 由一个条件决定:

```systemverilog
if (CONVERT_BURST && s_axi_wr.awcache[1] && (CONVERT_NARROW_BURST || s_axi_wr.awsize == S_BURST_SIZE)) begin
    // ① 合并模式: 重新打包成一笔宽突发
    master_burst_size_next = M_BURST_SIZE;
    m_axi_awlen_next = (s_axi_wr.awlen + 8'(s_axi_wr.awaddr[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET])) >> CL_SEG_COUNT;
    state_next = STATE_DATA_2;
end else begin
    // ② 直通模式: 保持窄突发, 只是搬到宽总线上
    master_burst_size_next = s_axi_wr.awsize;
    m_axi_awlen_next = s_axi_wr.awlen;
    state_next = STATE_DATA;
end
```

**模式②(窄传输直通)** 的核心是"复制到所有车道, 再用 strobe 点亮一个":

```systemverilog
m_axi_wdata_int = {(M_BYTE_LANES/S_BYTE_LANES){s_axi_wr.wdata}};    // 复制 4 份
m_axi_wstrb_int = 0;
m_axi_wstrb_int[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET] * S_STRB_W +: S_STRB_W] = s_axi_wr.wstrb;
//                ↑ 用地址的 [3:2] 位选车道(128 位总线有 4 个 32 位车道)
```

为什么"复制到所有车道"是安全的? 因为 **AXI 规定 strobe 为 0 的车道数据被忽略**。所以最便宜的写法就是把窄数据洒满全场, 然后用 strobe 精确点亮 —— 不需要任何 mux。

**模式①(合并)** 的 `awlen` 计算是全库最费解的一行:

```systemverilog
m_axi_awlen_next = (s_axi_wr.awlen + 8'(s_axi_wr.awaddr[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET])) >> CL_SEG_COUNT;
```

拆开看(32→128, `CL_SEG_COUNT=2`, 车道数 4):

- `awlen` 是"源侧还有几拍"(len = 拍数−1)。
- `awaddr[3:2]` 是"起始地址落在哪个车道"(0..3) —— 未对齐的突发需要多覆盖一拍。
- 加起来除以 4(右移 2) = "目标侧需要几拍"。

举例: `awlen=3`(4 拍), `awaddr[3:2]=0` → `(3+0)>>2 = 0` → 目标 `awlen=0`, 即 **1 拍 128 位**。正确: 4×32bit = 128bit = 1 拍。

再例: `awlen=3`, `awaddr[3:2]=2` → `(3+2)>>2 = 1` → 目标 2 拍。因为地址从车道 2 开始, 4 拍数据横跨两个 128 位拍。

**模式①的打包状态 `STATE_DATA_2`**:

```systemverilog
STATE_DATA_2: begin
    s_axi_wready_next = m_axi_wready_int_early;
    if (s_axi_wr.wready && s_axi_wr.wvalid) begin
        // 把这一拍窄数据塞进宽字的对应段
        data_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEG_DATA_W +: SEG_DATA_W] = s_axi_wr.wdata;
        strb_next[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*SEG_STRB_W +: SEG_STRB_W] = s_axi_wr.wstrb;
        m_axi_wdata_int = data_next;         // 组合输出"下一状态"的累积值
        m_axi_wstrb_int = strb_next;
        burst_next = burst_reg - 1;
        addr_next = addr_reg + (1 << burst_size_reg);
        // 车道索引变了 → 一个宽拍攒满 → 发出去
        if (addr_next[CL_ADDR_W'(master_burst_size_reg)] != addr_reg[CL_ADDR_W'(master_burst_size_reg)]) begin
            strb_next = '0;
            m_axi_wvalid_int = 1'b1;
        end
        if (burst_reg == 0) begin            // 最后一拍: 无条件发
            m_axi_wvalid_int = 1'b1;
            ...
            state_next = STATE_RESP;
        end
    end
end
```

"攒满"的判据是**地址跨过了段边界**:

```systemverilog
addr_next[CL_ADDR_W'(master_burst_size_reg)] != addr_reg[CL_ADDR_W'(master_burst_size_reg)]
```

即"第 `master_burst_size` 位(128 位总线时是 bit 4)发生了变化"。这个位就是"当前在第几个宽拍"的进位位。**用地址的进位位做打包完成判据**, 比维护一个段计数器更简洁, 而且天然处理未对齐起始地址。

我实测了这条路径(`lab/vsim/tb_adapter_wr.sv`, 32→128, `CONVERT_NARROW_BURST=1`, 起始 `0x1000`, `awlen=3`):

| 拍 | 源 W(32 位) | 目标 AW | 目标 MW(`wdata` 低 64 位 / 累积 strobe) |
|---|---|---|---|
| C4 | — | — | — |
| C5 | `v1 r1` d=`11111111` | **`v1 r1` len=**`0`** sz=**`4` | `…00000000` / `0x000f` |
| C6 | d=`22222222` | v0 | `…11111111` / `0x00ff` |
| C7 | d=`33333333` | v0 | `…22222222_11111111` / `0x0fff` |
| C8 | `v1 r1 l1` d=`44444444` | v0 | `…33333333_22222222_11111111` / `0xffff` |
| C9 | v0 | v0 | **`v1 r1 l1`** d=`44444444_33333333_22222222_11111111` |
| C10 | — | — | v0(数据保持) |
| C11 | — | — | `B v1`(bresp 从下游回来) |

> 原始打印: `C9|SAW v0 r0 a00001000 len3 sz2|SW v0 r0 l0 d44444444 stf|B v0|MAW v0 r1 a00001000 len0 sz4|MW v1 r1 l1 d44444444333333332222222211111111|65535`

读法: **4 拍 32 位 → 1 拍 128 位**, 而且这 1 拍是在第 4 个源 beat 握手后的**下一拍**发出。实测里看到的是:

- **`awlen` 从 3 变成 0、`awsize` 从 2 变成 4, 都在 `MAW` 出现的那一拍(C5)一次到位** —— 正是 §7.3 那行公式算出来的。
- **累积数据在 `MW` 上逐拍可见**(C6 起 `…11111111` 出现), 因为 `m_axi_wdata_int = data_next` 是组合赋值; 但 `wvalid` 只在攒满时拉高, 所以下游只看到 C9 那一拍。
- **`MW` 在 C9 之后保持 C9 的值**(C10–C17 一直是 `44444444…`), 这是寄存器保持, 不是又发了一遍(`wvalid=0`)。
- **`B` 在 C11 出现**, 即最后一拍 W 后一拍。
- 那个 `0xffff` 是累积 strobe(16 位), C5 的 `0x000f` → C8 的 `0xffff`, 直接反映"攒了几个字节"。**看 strobe 比看 data 更直观**。

> `awvalid` 在 C5 只亮一拍, 因为 TB 里下游 `awready` 恒 1。

### 7.4 分支三: downsize —— 切片 + 地址回零

一个宽拍拆成多个窄拍。取切片的代码:

```systemverilog
m_axi_wdata_int = s_axi_wr.wdata[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET] * M_DATA_W +: M_DATA_W];
m_axi_wstrb_int = s_axi_wr.wstrb[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET] * M_STRB_W +: M_STRB_W];
//                               ↑ 用地址的 [4:2] 位选段(128 位源有 4 个 32 位段)
```

地址推进多了一个**回零掩码**:

```systemverilog
addr_next = (addr_reg + (1 << master_burst_size_reg)) & ({ADDR_W{1'b1}} << master_burst_size_reg);
```

`& (全1 << size)` 把低 `size` 位清零。为什么? 因为在拆分过程中地址的低位是"段内偏移", 一旦跨段就必须回零重新开始。不清零的话, 用 `addr_reg[4:2]` 索引切片会算错。

`STATE_DATA_2` 在 downsize 里的含义与 upsize **相反**: upsize 的 DATA_2 是"继续攒", downsize 的 DATA_2 是"同一源拍继续往下发多个窄拍":

```systemverilog
STATE_DATA_2: begin
    s_axi_wready_next = 1'b0;        // 源侧冻结! 数据从 data_reg 取
    if (m_axi_wready_int_reg) begin
        m_axi_wdata_int = data_reg[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET] * M_DATA_W +: M_DATA_W];
        //                ↑ 注意是从 data_reg 切, 不是从 s_axi_wr.wdata
```

**为什么必须冻结源侧**: 一个宽拍要拆成 4 个窄拍发 4 拍, 期间源侧不能再给新数据, 否则会丢。所以 `s_axi_wready_next = 1'b0` 并且数据从已锁存的 `data_reg` 里反复切片。

### 7.5 downsize 的突发长度重算

一个 256 拍的窄读, 上到宽总线再下来, 中间可能超过 AXI 的 256 拍上限, 所以需要切段:

```systemverilog
if (s_axi_wr.awlen >> (8+M_BURST_SIZE-s_axi_wr.awsize) != 0) begin
    // limit burst length to max
    master_burst_next = 8'(32'hff << 3'(s_axi_wr.awsize-M_BURST_SIZE))
                      | 8'((8'(~s_axi_wr.awaddr) & 8'(8'hff >> (8-s_axi_wr.awsize))) >> M_BURST_SIZE);
end else begin
    master_burst_next = 8'(s_axi_wr.awlen << 3'(s_axi_wr.awsize-M_BURST_SIZE))
                      | 8'((8'(~s_axi_wr.awaddr) & 8'(8'hff >> (8-s_axi_wr.awsize))) >> M_BURST_SIZE);
end
```

两行的差别只在第一项: 超限时用 `0xff` 而不是 `awlen`(即"发满 256 拍")。第二项 `((~awaddr) & mask) >> M_BURST_SIZE` 是"到下一个对齐边界还差多少", 保证切出来的段是对齐的。

**代入具体数字看**(源总线 128 位 `awsize=3` 即 8 字节/拍, 目标 32 位 `M_BURST_SIZE=2`):

| `awlen` | 源拍数 | 源字节数 | 理论目标拍数 | 公式输出 `master_burst+1` | 是否触发限长 |
|---|---|---|---|---|---|
| 1 | 2 | 16 | 4 | 4 | 否 |
| 3 | 4 | 32 | 8 | 8 | 否 |
| 15 | 16 | 128 | 32 | 32 | 否 |
| 63 | 64 | 512 | 128 | 128 | 否 |
| 127 | 128 | 1024 | 256 | 256 | 否(正好卡上限) |
| 255 | 256 | 2048 | 512 | **256** | **是** → 切两段 |

**先明确缩放倍数**: 源 `awsize=3` 是 8 字节/拍, 目标 `M_BURST_SIZE=2` 是 4 字节/拍, 所以 `expand = 8/4 = 2` —— 源的一拍要拆成目标的**两**拍(不是四拍)。

**限长判据为什么是 `awlen >> (8+M_BURST_SIZE-awsize)`**: 目标拍数 = `(awlen+1) × expand`, 要它 ≤ 256:

```
(awlen+1) × 2^awsize / 2^M_BURST_SIZE ≤ 256
(awlen+1) ≤ 256 × 2^M_BURST_SIZE / 2^awsize = 2^(8 + M_BURST_SIZE - awsize)
(awlen+1) ≤ 128        ← 8+2-3 = 7, 2^7 = 128
```

而 `awlen ≥ 128` 恰好等价于 `awlen >> 7 != 0`(整数移位向下取整)。所以这个判据是**精确的, 不是保守的**: `awlen=127` 时 `(127+1)×2 = 256` 拍正好合法, 判据给 0; `awlen=128` 时 `(128+1)×2 = 258` 拍超限, 判据给 1。表里 `awlen=127` 那行"正好卡上限"就是这个意思 —— 它仍走 `else` 分支, 但算出来的值刚好是 255(即 256 拍)。

第二项 `((~awaddr) & (2**awsize-1)) >> M_BURST_SIZE` 的**真正含义**可以代数推出来: 当起始地址按 `awsize` 对齐时(`awaddr` 低 `awsize` 位全 0), `~awaddr` 低 `awsize` 位全 1, 于是 `& mask` = `2**awsize - 1`, 右移 `M_BURST_SIZE` 后 = `2**(awsize-M_BURST_SIZE) - 1` = **放大倍数减一**。代入:

```
master_burst = awlen × expand + (expand - 1)
             = (awlen + 1) × expand - 1
             = 目标拍数 - 1     ← 正好是目标侧的 awlen
```

**这一项不是"对齐修正", 而是把 `awlen×expand` 补成 `(awlen+1)×expand-1` 的那个 `-1`**。这个视角比"到边界还差多少"更好记, 也解释了为什么对齐时它恒为正。

起始地址**不**对齐时(比如 `awaddr=0x1004`), 这一项会变小(0 而不是 1), 算出的目标拍数少一拍 —— 因为首拍只覆盖了半拍数据。**所以用非对齐起始的窄突发做 downsize 时, 目标侧的拍数会和"字节数÷4"对不上, 这是要实测确认的地方**, 本文没有实测这一支, 不下结论。

这类位运算**不建议硬记**, 建议用参数代入 + 打印验证: 在 `$display` 里打 `awlen/awaddr/awsize/master_burst_next`, 跑几组典型值就明白了。上表就是把公式抄进 Python 逐组代入得到的 —— 不依赖仿真也能自己验。

### 7.6 Adapter 的两个参数

```systemverilog
// When adapting to a wider bus, re-pack full-width burst instead of passing through narrow burst if possible
parameter logic CONVERT_BURST = 1'b1,
// When adapting to a wider bus, re-pack all bursts instead of passing through narrow burst if possible
parameter logic CONVERT_NARROW_BURST = 1'b0,
```

| 参数 | 效果 | 什么时候开 |
|---|---|---|
| `CONVERT_BURST=0` | 永不合并, 全部按窄突发直通 | 下游对 `awlen` 敏感、或调试时想看清原始突发 |
| `CONVERT_BURST=1, CONVERT_NARROW_BURST=0` | **仅当 `awsize` 已等于源总线宽度**(即本来就是整拍突发)且 `awcache[1]=1` 时合并 | 默认, 最安全 |
| `CONVERT_BURST=1, CONVERT_NARROW_BURST=1` | 所有突发都重新打包(包括窄传输) | 追求带宽, 但下游必须真的支持 `wstrb` 稀疏写 |

**`awcache[1]` 是"可以合并"的暗示位**(AXI 里叫 `Modifiable`)。库用它来尊重主机的意愿: 主机说"这笔别改", 就不合并。

打开 `CONVERT_NARROW_BURST` 的打包代码在 `STATE_DATA_2` 里走另一条路:

```systemverilog
if (CONVERT_NARROW_BURST) begin
    for (integer i = 0; i < S_BYTE_LANES; i = i + 1) begin
        if (s_axi_wr.wstrb[i]) begin
            data_next[...*SEG_DATA_W + i*M_BYTE_SIZE +: M_BYTE_SIZE] = s_axi_wr.wdata[i*M_BYTE_SIZE +: M_BYTE_SIZE];
            strb_next[...*SEG_STRB_W + i] = 1'b1;
        end
    end
end
```

注意它是**逐字节**搬的 —— 因为源数据可能只点亮了部分 strobe, 必须只搬有效的那些字节, 否则会把"不该写的字节"也写下去。

---

## §8 Crossbar: 全连接交换

### 8.1 它到底"全连接"在哪

```
        ┌──────────────┐
 s0 ───►│              │───► m0
 s1 ───►│  crossbar    │───► m1
 s2 ───►│              │───► m2
        └──────────────┘
```

"全连接"= **任意 slave 可以同时连到任意不同 master**。s0→m1 与 s1→m0 可以并行, 互不阻塞。

实现方式: 每个 slave 有一份独立的地址解码器 + 一套独立的 (AW/W/B) 通路; 每个 master 侧有一个仲裁器决定"当前这个 master 归哪个 slave 用"。**通路数量 = S_COUNT, 仲裁器数量 = M_COUNT。**

这就是它和 interconnect(§9)的根本区别: interconnect 只有**一条**内部通路, 所以同一时刻只能有一个 slave 在活动。

模块划分(`taxi_axi_crossbar.sv` 165 行只是 wrapper):

```
taxi_axi_crossbar.sv
  ├── taxi_axi_crossbar_wr.sv  (607 行)
  │     ├── for m in S_COUNT:  taxi_axi_register_wr (S 侧)   ← 输入寄存
  │     │                      taxi_axi_crossbar_addr         ← 地址解码 + 线程
  │     │                      taxi_arbiter (B 通道)
  │     └── for n in M_COUNT:  taxi_axi_register_wr (M 侧)   ← 输出寄存
  │                            taxi_arbiter (AW 通道)
  │                            w_select 路由逻辑
  └── taxi_axi_crossbar_rd.sv  (521 行, 同构)
```

### 8.2 地址解码: 一行代码, 四个条件

`taxi_axi_crossbar_addr.sv:322`:

```systemverilog
if (   M_ADDR_W_INT[i*M_REGIONS+j] != 0                       // ① 该区段已启用
    && (!M_SECURE_INT[i] || !s_axi_aprot[1])                   // ② 安全策略放行
    && M_CONNECT_INT[i][S]                                     // ③ 这个 slave 能连这个 master
    && (s_axi_aaddr >> M_ADDR_W_INT[i*M_REGIONS+j])
       == (M_BASE_ADDR_INT[i*M_REGIONS+j] >> M_ADDR_W_INT[i*M_REGIONS+j]))  // ④ 高位相等
begin
    m_select_next = SEL_W'(i);
    m_axi_aregion_next = 4'(j);
    match = 1'b1;
end
```

**条件④是全库最漂亮的技巧**: 地址匹配不用掩码, 而是"两边都右移 `M_ADDR_W` 位再比"。

```
base = 0x4000, M_ADDR_W = 14   →  base >> 14 = 0x1
addr = 0x4100, M_ADDR_W = 14   →  addr >> 14 = 0x1     ✓ 命中
addr = 0x8100, M_ADDR_W = 14   →  addr >> 14 = 0x2     ✗ 不命中
```

等价于 `(addr & ~mask) == base`, 但**不需要算 mask**, 也不需要 `ADDR_W` 位宽的掩码常量。省了一个 `localparam`, 也避免了"掩码算错"这类 bug。这个写法可以直接搬到任何地址译码器里。

条件②里的 `s_axi_aprot[1]`: AXI 的 `aprot[1]` 是 "1 = 非安全访问"。当 `M_SECURE[i]=1`(该 master 是安全域)时, 任何非安全访问都**不匹配**, 于是落到 `match=0` 分支 → DECERR。这是**用地址解码器顺手实现了访问控制**, 不需要独立的保护单元。

**地址自动计算**: `M_BASE_ADDR = 0`(默认)时, 库自己算:

```systemverilog
function [M_COUNT*M_REGIONS-1:0][ADDR_W-1:0] calcBaseAddrs(input [31:0] dummy);
    ...
    mask = {ADDR_W{1'b1}} >> (ADDR_W - width);
    size = mask + 1;
    if ((base & mask) != 0)
        base = base + size - (base & mask);   // align
    ...
```

按顺序累加: 第 0 个 master 从 0 开始, 第 1 个从"前一个的末尾并对齐"开始。实测打印出来是这样:

```
Addressing configuration for axi_crossbar_addr instance tb_xbar1s.uut.rd_inst.rd_inst.s_ifaces[0].addr_inst
 0 ( 0): 00000000 / 14 -- 00000000-00003fff
 1 ( 0): 00004000 / 14 -- 00004000-00007fff
```

这个 `$display` 在 `initial` 块里, **仿真一开始就打印**, 是排查地址映射问题的第一手资料。做多主多从设计时, 建议每次仿真都先看这张表。

**elaboration 期检查**(全部 `$fatal`/`$error`):

```systemverilog
if (M_REGIONS < 1 || M_REGIONS > 16)  $fatal(0, "Error: M_REGIONS must be between 1 and 16 (instance %m)");
if (S_ACCEPT < 1)                     $fatal(0, "Error: need at least 1 accept (instance %m)");
if (S_THREADS < 1)                    $fatal(0, "Error: need at least 1 thread (instance %m)");
// initial 块里还有: 地址宽度 12..ADDR_W、对齐检查、区段两两重叠检查
```

### 8.3 线程追踪: crossbar 最难的 100 行

**问题**: 一个 slave 可以有多笔未完成的事务同时在路上(比如先读 A 再读 B, 不等 A 回来)。每笔事务去了不同的 master。当响应回来时, 怎么知道它是哪一笔的?

**答案**: 按 **ID** 追踪。`S_THREADS` 就是"这个 slave 最多能同时追踪几个不同 ID"。

```systemverilog
localparam S_INT_THREADS = S_THREADS > S_ACCEPT ? S_ACCEPT : S_THREADS;

logic [ID_W-1:0] thread_id_reg[S_INT_THREADS-1:0] = '{default: '0};
logic [SEL_W-1:0] thread_m_reg[S_INT_THREADS-1:0] = '{default: '0};       // 去了哪个 master
logic [3:0]      thread_region_reg[S_INT_THREADS-1:0] = '{default: '0};   // 哪个 region
logic [$clog2(S_ACCEPT+1)-1:0] thread_count_reg[S_INT_THREADS-1:0] = '{default: '0};  // 该 ID 有几笔在飞
```

每个 thread 是一组"ID + 目标 master + region + 在飞计数"。

五根位向量(`:262-266`)是这套机制的全部状态:

```systemverilog
assign thread_active[n]       = thread_count_reg[n] != 0;                        // 该 thread 在用
assign thread_match[n]        = thread_active[n] && thread_id_reg[n] == s_axi_aid;  // 新事务的 ID 命中它
assign thread_match_dest[n]   = thread_match[n] && thread_m_reg[n] == m_select_next
                                && (M_REGIONS < 2 || thread_region_reg[n] == m_axi_aregion_next);
assign thread_cpl_match[n]    = thread_active[n] && thread_id_reg[n] == s_cpl_id;   // 响应回来命中它
assign thread_trans_start[n]  = (thread_match[n]
                                 || (!thread_active[n] && thread_match == 0
                                     && (thread_trans_start & ({S_INT_THREADS{1'b1}} >> (S_INT_THREADS-n))) == 0))
                                && trans_start;
assign thread_trans_complete[n] = thread_cpl_match[n] && trans_complete;
```

**`thread_trans_start[n]` 那个条件最长, 拆成三种情况**:

1. `thread_match[n]` —— 这个 ID 已经有 thread, 直接复用。
2. `!thread_active[n] && thread_match == 0` —— 全新的 ID, 且没有任何 thread 匹配它, 那就找一个**空闲**的 thread。
3. `(thread_trans_start & ({S_INT_THREADS{1'b1}} >> (S_INT_THREADS-n))) == 0` —— **低索引优先**: 如果编号比 n 小的 thread 这一拍也要启动, 就让给它们。

第 3 条是实现"同一拍多个空闲 thread 时只选一个"的干净办法: `{N{1'b1}} >> (N-n)` 生成"索引 ≥ n 的掩码", 与 `thread_trans_start` 相与。如果低位有冲突就返回非零, 于是 n 让位。

这个写法比"用 for 循环 break"好得多 —— **纯组合、可综合、无优先级链**。

**为什么需要 `thread_match_dest`**: 同一个 ID 的两笔事务可能去不同的 master(地址不同)。这时必须**新开一个 thread**, 不能复用。所以准入判据是:

```systemverilog
if (!trans_limit && (thread_match_dest != 0 || (!(&thread_active) && thread_match == 0))) begin
    // ① 已有同 ID 同目标的 thread  或  ② 还有空闲 thread 且是新 ID
    m_axi_avalid_next = 1'b1;
    trans_start = 1'b1;
```

**准入控制**: `S_ACCEPT` 是"这个 slave 最多允许多少笔在飞"。

```systemverilog
localparam TR_CNT_W = $clog2(S_ACCEPT+1);
wire trans_limit = trans_count_reg >= TR_CNT_W'(S_ACCEPT) && !trans_complete;
```

`&& !trans_complete` 是为了避免"已经满了但这一拍正好有一笔完成"时误拒 —— 一边进一边出是允许的。

### 8.4 地址模块的两态 FSM 与"两拍代价"

```systemverilog
STATE_IDLE: begin
    if (s_axi_avalid && !s_axi_aready) begin
        // 解码, 决定 match
        ...
        state_next = STATE_DECODE;
    end
end
STATE_DECODE: begin
    if (!m_axi_avalid_next && (!m_wc_valid_next || !WC_OUTPUT) && !m_rc_valid_next) begin
        s_axi_aready_next = 1'b1;      // ← 所有下游握手都完成了, 才回 aready
        state_next = STATE_IDLE;
    end
end
```

**注意 `aready` 是在 DECODE 态、等所有下游握手完成后才给的**, 不是立刻给。这意味着:

- 地址通路的**最小延迟是 2 拍**(IDLE 解码 1 拍 + DECODE 确认 1 拍)。
- 换来的是**完全无组合环**的握手: `aready` 不依赖 `s_axi_avalid`, 只依赖内部状态。

这是 AXI 里典型的"用延迟换时序"的取舍。对比 §5 的 RAM, 它的 `awready` 在 IDLE 态直接给 1, 只要 1 拍 —— 因为它没有下游要等。

`WC_OUTPUT` 参数控制写命令流(`m_wc_*`)是否输出。写通路需要它(因为 W 通道要跟着 AW 走), 读通路不需要(默认 0)。所以 DECODE 的判据写成 `(!m_wc_valid_next || !WC_OUTPUT)` —— 不输出时就当它不存在。

### 8.5 ID 拼接: crossbar 的核心技巧

`taxi_axi_crossbar_wr.sv:503`:

```systemverilog
if (S_COUNT > 1) begin
    assign int_axi.awid = {a_grant_index, int_s_axi_awid[a_grant_index]};
    //                     ↑ 高位: 来自哪个 slave     ↑ 低位: 主机原本的 ID
end else begin
    assign int_axi.awid = int_s_axi_awid[a_grant_index];
end
```

**为什么这么干**: 下游从机只看到一个 ID 空间。如果把 4 个 slave 的 ID 直接混在一起(比如都是 `0x05`), 从机返回的 `bid=0x05` 就分不清是哪个 slave 的。

拼接后: 高 `$clog2(S_COUNT)` 位记"来源", 低 `S_ID_W` 位保留原 ID。回程一行解出:

```systemverilog
wire [CL_S_COUNT_INT-1:0] b_select = CL_S_COUNT_INT'(int_axi.bid >> S_ID_W);   // :568
```

**这是零成本的解复用** —— 一个移位就够, 不需要任何查表或 FIFO 记录。

代价: 下游的 ID 空间被压缩了 `S_COUNT` 倍。所以 `ID_W` 要留够: 4 个 slave、每个 8 位 ID, 下游需要 `8 + 2 = 10` 位。如果下游只有 8 位, 就必须减少 slave 数或减少每 slave 的 ID 位宽。

**一个必须说清楚的边界**: `S_COUNT == 1` 时**不做拼接**, 代码走 `else` 分支:

```systemverilog
if (S_COUNT > 1) begin
    assign int_axi.awid = {a_grant_index, int_s_axi_awid[a_grant_index]};
end else begin
    assign int_axi.awid = int_s_axi_awid[a_grant_index];     // ← 原样透传
end
```

因为没有第二个 slave, "来自谁"这个问题不存在, 加了高位反而是浪费。我实测用的 `taxi_axi_crossbar_1s` 就是这一支, 所以我**没法用波形验证拼接分支** —— 这一点本文不臆造。

`S_COUNT == 1` 时 `b_select` 仍然会算(`bid >> S_ID_W`), 但 `b_select` 的位宽是 `CL_S_COUNT_INT = 1` 位, 而 `bid >> S_ID_W` 在拼接分支外本来就不是"来源"语义。看代码时要意识到: **`b_select` 只在 `S_COUNT > 1` 时有意义**, 单 slave 时它恒为 `bid` 的最高位, 而 `int_axi_bvalid[n][b_select]` 在 `S_COUNT=1` 时只有 index 0 有效 —— 全靠 `bid` 的高位恰好是 0。这是个隐含的前提, 也是 `M_ID_W < S_ID_W+$clog2(S_COUNT)` 那条 `$fatal` 存在的原因: 保证 ID 高位**真的有** `$clog2(S_COUNT)` 位可用来编码来源。

**DECERR 路径的 ID 回填是另一套机制**(`taxi_axi_crossbar_wr.sv:327-346`):

```systemverilog
logic [S_ID_W-1:0] decerr_m_axi_bid_reg = '0, decerr_m_axi_bid_next;
...
end else if (m_rc_valid && m_rc_ready) begin
    decerr_m_axi_bid_next = int_s_axi_awid[m];      // ← 记住原始 ID
    decerr_m_axi_bvalid_next = 1'b1;
end
```

然后在 B 仲裁的 mux 里, 虚拟端口(`index == M_COUNT_P1-1`)被选中时输出它:

```systemverilog
if (b_grant_index == CL_M_COUNT_P1'(M_COUNT_P1-1)) begin
    int_axi.bid    = decerr_m_axi_bid_reg;          // ← 原始 ID 回填
    int_axi.bresp  = 2'b11;
    int_axi.buser  = '0;
    int_axi.bvalid = decerr_m_axi_bvalid_reg & b_grant_valid;
end else begin
    int_axi.bid    = S_ID_W'(int_m_axi_bid[...]);
    ...
```

**这两行(存 `int_s_axi_awid[m]` / 取 `decerr_m_axi_bid_reg`)是 DECERR 能工作的全部秘密**。忘了回填 ID, 主机会收到一个不认识的 `bid`, 事务永远不完成 —— 而且这种 bug 只在"地址配错"时才暴露, 平时测不出来。§8.8 的实测里那个 `bid=0b` 就是原始 `awid` 被回填的证据。

### 8.6 W 通道的"粘住"逻辑: 最容易被忽略的坑

W 通道没有 ID, 只有一根 `wvalid/wready/wlast`。问题来了:

```
拍 N   : AW(addr=X) 被仲裁给 master 1
拍 N+1 : 又来一个 AW(addr=Y) 被仲裁给 master 2
拍 N+2 : W 数据到了 —— 它是给 X 的还是给 Y 的?
```

**答案**: AXI 规定 W 数据必须**按 AW 的顺序**发。所以 crossbar 必须"记住当前 W 属于哪个 master", 直到 `wlast` 握手完成, 期间**不允许新的 AW 抢占**。

这就是 `w_select_valid_reg` 的作用:

```systemverilog
w_select_valid_next = w_select_valid_reg && !(int_axi.wvalid && int_axi.wready && int_axi.wlast);
//                                      ↑ 只有最后一个 beat 握手才释放
w_select_new_next = w_select_new_reg || a_grant_valid == 0 || a_ack != 0;

if (a_grant_valid && !w_select_valid_reg && w_select_new_reg) begin
    w_select_next = a_grant_index;
    w_select_valid_next = a_grant_valid;
    w_select_new_next = 1'b0;
end
```

三个变量各管一件事:

| 变量 | 含义 |
|---|---|
| `w_select_reg` | 当前 W 数据发给哪个 master |
| `w_select_valid_reg` | "锁定"标志: 1 = 正在传一笔突发的 W, 别人别抢 |
| `w_select_new_reg` | "可以接受新分配"标志: 新一轮仲裁完成且尚未锁定 |

`w_select_new_next = ... || a_grant_valid == 0 || a_ack != 0` 的意思是: **只要仲裁器空闲或握手完成, 就允许下一轮分配**。这是防止"上一轮的 grant 把下一轮永久堵死"的解锁条件。

**AW 请求必须被屏蔽**:

```systemverilog
assign a_req[m] = int_axi_awvalid[m][n] && !a_grant_valid && !trans_limit && !w_select_valid_next;
//                                          ↑ 仲裁器忙        ↑ 达上限     ↑ W 通道被锁
```

注意最后一个 `!w_select_valid_next`: 这正是**"W 通道锁定期间不接受新 AW"**。少了它, W 数据就会串到错误的 master 上 —— 这是 crossbar 里最隐蔽的 bug。

W 数据实际转发:

```systemverilog
always_comb begin
    int_axi_wvalid[m] = '0;
    int_axi_wvalid[m][w_select_reg] = int_axi.wvalid && w_select_valid_reg && !w_drop_reg;
end
assign int_axi.wready = int_axi_wready[w_select_reg][m] || w_drop_reg;
```

`| w_drop_reg` 那一项是 DECERR 路径: 地址解码失败时, 没有 master 接这笔数据, 但**数据还是会来**, 所以必须假装 ready 把它吃掉(丢弃)。

### 8.7 B 通道仲裁: 那个虚拟的 decerr 端口

```systemverilog
localparam M_COUNT_P1 = M_COUNT+1;
localparam CL_M_COUNT_P1 = $clog2(M_COUNT_P1);

taxi_arbiter #(
    .PORTS(M_COUNT_P1),          // ← 多一路!
    .ARB_ROUND_ROBIN(1), .ARB_BLOCK(1), .ARB_BLOCK_ACK(1), .LSB_HIGH_PRIO(1)
) b_arb_inst (...);

for (genvar n = 0; n < M_COUNT; n = n + 1) begin
    assign b_req[n] = int_axi_bvalid[n][m] && !b_grant[n];
    assign b_ack[n] = b_grant[n] && int_axi_bvalid[n][m] && int_axi.bready;
end
// 最后一路是虚拟的 decerr 端口
assign b_req[M_COUNT_P1-1] = decerr_m_axi_bvalid_reg && !b_grant[M_COUNT_P1-1];
assign b_ack[M_COUNT_P1-1] = b_grant[M_COUNT_P1-1] && decerr_m_axi_bvalid_reg && int_axi.bready;
```

**为什么多开一路**: 因为 DECERR 响应是 crossbar **自己造的**, 它也需要参与仲裁 —— 否则它会和真实从机的响应冲突。

把"内部造的错误响应"当成一个**虚拟 master** 挂到仲裁器上, 是这套设计的精髓: 仲裁器不需要知道哪个是真哪个是假, 它只看到 N+1 个请求方。

`ARB_BLOCK_ACK=1` 是必须的: 它让仲裁器在 `ack` 到来前**保持 grant 不变**, 这样 `b_grant_index` 在整个 B 握手期间稳定。对照 `taxi_arbiter.sv` 的判据:

```systemverilog
else if (ARB_BLOCK && ARB_BLOCK_ACK && grant_valid && ((grant_reg & ack) == 0)) begin
    // granted req not yet acknowledged; hold it
```

### 8.8 实测波形: 三次访问, 一条 DECERR

环境: `taxi_axi_crossbar_1s`, `M_COUNT=2`, `ADDR_W=32`, `M_ADDR_W={14,14}`(M0: 0x0000–0x3FFF, M1: 0x4000–0x7FFF), `ID_W=6`。从机是规范响应模型(收到 AR 才回 R)。

激励: 读 `0x0100`(M0) → 读 `0x4100`(M1) → 读 `0xC000`(**无命中**) → 写 `0x8100`(**无命中**)。

| 拍 | AR v r | R v r l resp rid data | AW v r | B v r resp bid | `sel` | `decerr` |
|---|---|---|---|---|---|---|
| C3 | **1** 0 | 0 1 0 – – – | 0 0 | 0 1 00 3f | 0 | 0 |
| C6 | **1 1** | 0 1 0 – – – | 0 0 | 0 1 00 3f | 0 | 0 |
| C7 | 0 0 | 0 1 0 – – – | 0 0 | 0 1 00 3f | 0 | 0 |
| C8 | 0 0 | 0 1 **1** 00 05 c0de0000 | 0 0 | 0 1 00 3f | 0 | 0 |
| C9 | 0 0 | **1 1** 1 00 05 c0de0000 | 0 0 | 0 1 00 3f | 0 | 0 |
| C10 | **1** 0 | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | 0 | 0 |
| C11 | 1 0 | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | **1** | 0 |
| C13 | **1 1** | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | 1 | 0 |
| C16 | 0 0 | **1 1** 1 00 05 c0de0001 | 0 0 | 0 1 00 3f | 1 | 0 |
| C17 | **1** 0 | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | 1 | 0 |
| C18 | 1 0 | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | 1 | **1** |
| C19 | **1 1** | 0 1 1 – 05 – | 0 0 | 0 1 00 3f | 1 | 1 |
| C21 | 0 0 | **1 1** 1 **11** 05 **00000000** | 0 0 | 0 1 00 3f | 1 | 1 |
| C22 | 0 0 | 0 1 1 00 05 – | **1** 0 | 0 1 00 3f | 1 | 1 |
| C24 | 0 0 | 0 1 1 – 05 – | **1 1** | 0 1 00 3f | 1 | 1 |
| C26 | 0 0 | 0 1 1 – 05 – | 0 0 | **1 1 11 0b** | 1 | 1 |

> 原始打印: `C9|AR v0 r0|R v1 r1 l1 resp00 rid05 dc0de0000|AW v0 r0|B v0 r1 resp00 bid3f|sel0 decerr0`。
> `bid3f` 是从机模型在自己那侧的默认值, 不是 crossbar 输出; 主机侧看到的 B 在 `B` 那几列。

**六条从波形读出来的事实**:

1. **第一笔读: `arvalid` 在 C3 出现, C6 握手, C9 才 `rvalid`** —— 共 6 拍。分解: 地址模块在 C3 就看到了 `arvalid`, 但它要**两拍**(C4 解码 + C5 确认)才给 `aready`, 于是握手落在 C6; 下游从机再花 2 拍产生 R, crossbar 内部寄存一拍, C9 出去。这条链是全库最长的组合链之一, 也是 crossbar 吞吐不如 interconnect 的原因。
2. **`sel` 在 C11 才变成 1**, 而第二笔 AR 在 C10 就出现、C13 才握手。`m_select_reg` 是寄存器输出, 这是 §8.4 两态 FSM 的直接后果: 地址解码结果要在下一个 IDLE 才可见。
3. **DECERR 读的 `decerr` 位在 C18 置起**, 比 AR 出现(C17)晚 1 拍 —— 同样是寄存器延迟。
4. **DECERR 读反而更快一点**: 第 3 笔 AR 在 C17 出现、C19 握手、C21 就返回 `rresp=11`(4 拍), 而正常读要 6 拍。因为 DECERR 响应完全在 crossbar 内部生成(`m_rc_valid`), 不需要等真实从机。
5. **DECERR 的 `rdata` 是全 0, `rresp=2'b11`** —— 对应 `int_axi.rdata = '0; int_axi.rresp = 2'b11;`。这个响应**不经过任何从机**, 是 crossbar 自己在 `decerr` 路径上造的。
6. **DECERR 的写 `bid` 保留了主机原始 ID `0x0B`**(C26), 尽管从机从没收到过这笔 AW。这证明 DECERR 响应是 crossbar 自己生成的, 但它**必须伪造出正确的 ID**, 否则主机无法匹配事务。

> 第 6 条是很容易漏的细节: 造错误响应时**必须把 `awid` 记住并回填到 `bid`**。代码里对应 `decerr_m_axi_bid_reg`。

---

## §9 Interconnect: 共享通路交换

### 9.1 一句话区别

| | crossbar | interconnect |
|---|---|---|
| 内部通路 | 每 slave 一条(S_COUNT 条) | **只有一条** |
| 并行性 | 多对 slave/master 可同时活动 | 同一时刻只有一对 |
| FSM 状态数 | 每个 slave 2 态 | 6 态(写) / 5 态(读) |
| 需要 ID 拼接 | 需要 | **不需要** |
| 面积 | 大(∝ S_COUNT × M_COUNT) | 小 |

interconnect 的 `S_COUNT` 指的是"有 S_COUNT 个上游从机端口", 但它们**共享一条通往 M_COUNT 个下游的通路**。所以它不需要 §8.5 的 ID 拼接 —— 因为同一时刻只有一笔事务在路上, 响应只能属于它。

代价: s0 访问 m1 时, s1 想访问 m0 必须等。**吞吐差, 但面积小、时序好、代码简单。**

### 9.2 六态写 FSM

```systemverilog
typedef enum logic [2:0] {
    STATE_IDLE,
    STATE_DECODE,
    STATE_WRITE,
    STATE_WRITE_RESP,
    STATE_WRITE_DROP,
    STATE_WAIT_IDLE
} state_t;
```

逐态职责:

| 状态 | 干什么 |
|---|---|
| `IDLE` | 等仲裁; grant 到了就把选中 slave 的 **AW 全部字段打进影子寄存器**, 同拍给 `awready` |
| `DECODE` | 用影子寄存器里的地址做解码; 命中 → `WRITE`, 未命中 → `WRITE_DROP` |
| `WRITE` | 把影子寄存器里的 AW 发下去(`m_axi_awvalid`), 同时转发 W 数据 |
| `WRITE_RESP` | 把下游的 B 转回上游 |
| `WRITE_DROP` | 地址没命中: 把 W 数据**吞掉**直到 `wlast`, 然后自己造一个 `bresp=2'b11` |
| `WAIT_IDLE` | 等仲裁器的 grant 撤销(`grant_valid == 0 \|\| ack != 0`), 防止重复 grant |

**IDLE 里"先存影子寄存器"是关键设计**(对比 crossbar 是直接 mux 出去):

```systemverilog
STATE_IDLE: begin
    // idle state; wait for arbitration

    axi_addr_valid_next = 1'b1;                  // ← 无条件! 每拍都把当前 grant 的 AW 打进来
    axi_id_next = current_s_axi_awid;            // current_* = s_axi_*[s_select]
    axi_addr_next = current_s_axi_addr;
    axi_len_next = current_s_axi_awlen;
    axi_size_next = current_s_axi_awsize;
    axi_burst_next = current_s_axi_awburst;
    axi_lock_next = current_s_axi_awlock;
    axi_cache_next = current_s_axi_awcache;
    axi_prot_next = current_s_axi_awprot;
    axi_qos_next = current_s_axi_awqos;
    axi_awuser_next = current_s_axi_awuser;

    if (grant_valid) begin                       // ← 只有 grant 到了才真的收
        s_axi_awready_next[s_select] = 1'b1;
        state_next = STATE_DECODE;
    end else begin
        state_next = STATE_IDLE;
    end
end
```

**注意那个"无条件打进来"**: 影子寄存器在每个 IDLE 拍都在刷新, 但只有 `grant_valid` 时才给 `awready`。这不是浪费, 而是**组合延迟优化** —— AW 的影子寄存器负载不依赖 `grant_valid`, 综合出来的路径更短。

**`current_*` 这批 wire 是"按 grant 索引的 mux"**(`taxi_axi_interconnect_wr.sv:306-324`):

```systemverilog
wire [CL_S_COUNT_INT-1:0] s_select;
assign s_select = grant_index;                               // :341

wire [S_ID_W-1:0]  current_s_axi_awid  = s_axi_awid[s_select];    // :308
wire [ADDR_W-1:0]  current_s_axi_addr  = s_axi_addr[s_select];    // :309
...
wire [DATA_W-1:0]  current_s_axi_wdata = s_axi_wdata[s_select];   // :319
```

`grant_index` 由仲裁器直接给出(`:359` 接到 arbiter 的输出), 所以 `s_select` 是**组合**的, 不经过寄存器 —— 这是 interconnect 比 crossbar 延迟低的关键: crossbar 的 `m_select_reg` 是寄存器, 要多一拍。

为什么要存影子? 因为**下游的 AW 要等到 DECODE 之后才发**, 而那时上游的 `awvalid` 可能已经撤了(它看到 `awready` 就以为交付完成)。所以必须**在接收的同拍就把数据锁下来**。

这体现了 AXI 握手的一个推论: **`ready` 一拉高, 数据所有权就转移了**, 上游可以立刻改 payload。任何"先收后发"的模块都必须有影子寄存器。

`ack` 的接法也很巧:

```systemverilog
assign ack = state_reg == STATE_WAIT_IDLE ? '1 : '0;
```

`ack` 是一个**全 1 向量**, 只在 `WAIT_IDLE` 态有效(原文 `'1` 即 `{S_COUNT{1'b1}}`)。配合 `ARB_BLOCK_ACK=1`, 仲裁器会在收到 ack 前一直保持 grant —— 保证整个事务期间 `s_select`(即 `grant_index`)稳定。这就是为什么代码里处处直接用 `s_select` 而不是把它打一拍: **grant 本来就锁住了**, 不需要额外的寄存器。

### 9.3 `WRITE_DROP`: 错误处理的蜜罐

```systemverilog
STATE_WRITE_DROP: begin
    // write drop state; drop write data
    s_axi_wready_next[s_select] = 1'b1;              // ← 无条件 ready, 假装收

    axi_addr_valid_next = 1'b0;                       // ← 不再往下游发 AW

    if (s_axi_wready_reg != 0 && current_s_axi_wvalid && current_s_axi_wlast) begin
        s_axi_wready_next[s_select] = 1'b0;
        s_axi_bvalid_next[s_select] = 1'b1;           // ← 吃完最后一口才回 B
        state_next = STATE_WAIT_IDLE;                 // ← 注意: 直接去 WAIT_IDLE, 不经 WRITE_RESP
    end else begin
        state_next = STATE_WRITE_DROP;
    end
end
```

注意两个细节: `axi_bresp_next` 早在 `STATE_DECODE` 里就被设成 `2'b11` 了(不是在这里), 以及错误写**直接跳 `WAIT_IDLE`**, 因为不需要等下游的 B(下游根本没收到这笔)。

**必须把 W 数据全部吃掉, 一个不能少**。因为 AXI 规定: 一旦 AW 被接受, 主机就会发完整个 W 突发。如果从机不 ready, 主机会永远卡住(而且这笔"错误"会变成死锁, 而不是错误响应)。

这是 AXI 错误处理里最容易踩的坑: **收到错误地址后, 仍然要老老实实接收全部数据, 然后才回 DECERR**。`WRITE_DROP` 这个状态名起得很准确。

对应读侧是 `STATE_READ_DROP`:

```systemverilog
STATE_READ_DROP: begin
    // read drop state; generate decode error read response

    s_axi_rid_int = axi_id_reg;                    // ← ID 必须回填
    s_axi_rdata_int = '0;
    s_axi_rresp_int = 2'b11;
    s_axi_rlast_int = axi_len_reg == 0;            // ← 用剩余长度算 rlast
    s_axi_ruser_int = '0;
    s_axi_rvalid_int[s_select] = 1'b1;

    if (s_axi_rready_int_reg) begin                // ← 主机收一拍, 长度减一
        axi_len_next = axi_len_reg - 1;
        if (axi_len_reg == 0) begin
            state_next = STATE_WAIT_IDLE;          // 最后一拍 → 收工
        end else begin
            state_next = STATE_READ_DROP;
        end
    end else begin
        state_next = STATE_READ_DROP;              // 主机没 ready, 保持
    end
end
```

**`axi_len_next = axi_len_reg - 1` 只在 `rready` 时执行**, 这是 AXI 的常见错误源: 如果写成无条件递减, 主机反压时会少发数据。`rlast` 由 `axi_len_reg == 0` 判断(而不是等计数器到 0 之后再看), 所以最后一拍的 `rlast` 与数据同拍。

读侧只需要**自己造出**读数据(全 0 + DECERR), 不需要收任何东西 —— 因为读没有"主机要发数据"的问题。`rlast` 由剩余长度算出, 保证主机能看到正确的突发长度。

### 9.4 `S_COUNT == 1` 时的退化

两个模块都有这段:

```systemverilog
if (S_COUNT > 1) begin : arb
    taxi_arbiter #(...) a_arb_inst (...);
end else begin
    logic grant_valid_reg = 1'b0;
    always @(posedge clk) begin
        if (req)            grant_valid_reg <= 1'b1;
        if (ack || rst)     grant_valid_reg <= 1'b0;
    end
    assign grant_valid = grant_valid_reg;
    assign grant = '1;
    assign grant_index = '0;
end
```

一个 slave 就不需要仲裁器, 用 3 行寄存器代替。`grant = '1`(永远选中 0 号), `grant_index = '0`。

**为什么要这个分支**: 不只是省面积 —— 更重要的是 `taxi_arbiter` 的 `LSB_HIGH_PRIO`/掩码逻辑在 `PORTS=1` 时会产出一些无意义的复位值, 而且会引入不必要的延迟。库对 `S_COUNT=1` 做了专门优化, 这也是 `taxi_*_1s` 系列(§10)存在的原因: **单 slave 的封装走的是优化路径**。

`taxi_axi_interconnect_1s` / `taxi_axi_crossbar_1s` 就是"1 个 slave 口 + N 个 master 口"的封装, 内部用 `S_COUNT=1` 例化上面两个模块。它们比通用版本少了 interface 数组, 所以**verilator 能仿真**(§1.4 的实测就是用它做的)。

### 9.5 读侧的 5 态

少了一个 `STATE_WRITE_RESP`(读的响应是数据流, 不需要独立状态), 其余同构:

```systemverilog
STATE_IDLE / STATE_DECODE / STATE_READ / STATE_READ_DROP / STATE_WAIT_IDLE
```

`STATE_READ` 里的一个细节值得注意:

```systemverilog
m_axi_rready_next[m_select_reg] = s_axi_rready_int_early;
```

用的是 **`_early` 前瞻信号**, 而不是寄存后的 `s_axi_rready_reg`。这意味着 interconnect 的 R 通道有**组合直通路径**(上游 rready → 下游 rready), 而 crossbar 的 B/R 走寄存器打分。

**为什么可以这样**: interconnect 只有一条通路, 组合路径不构成环(不像 crossbar 有多路 mux 可能形成环)。所以这里可以激进一点, 省一拍延迟。

---

## §10 Tie / 1s 封装 / 双口 RAM

### 10.1 Tie: 位宽适配器

`taxi_axi_tie.sv` 61 行只是例化 `tie_wr` + `tie_rd`, 无参数。

用途: 把一个 AXI 接口接到另一个**位宽不同但地址空间相同**的接口上。

```systemverilog
// taxi_axi_tie_rd.sv 的四条自检
if (m_axi_rd.ADDR_W > ADDR_W)
    $fatal(0, "Error: Output ADDR_W is wider than input ADDR_W, cannot access entire address space (instance %m)");
if (m_axi_rd.DATA_W != DATA_W)
    $fatal(0, "Error: Interface DATA_W parameter mismatch (instance %m)");
if (m_axi_rd.STRB_W != STRB_W)
    $fatal(0, "Error: Interface STRB_W parameter mismatch (instance %m)");
if (m_axi_rd.ID_W < ID_W)
    $fatal(0, "Error: Output ID_W is narrower than input ID_W, cannot discard ID bits (instance %m)");

// 前向: 宽化(零扩展)
assign m_axi_rd.arid   = m_axi_rd.ID_W'(s_axi_rd.arid);
assign m_axi_rd.araddr = m_axi_rd.ADDR_W'(s_axi_rd.araddr);
assign m_axi_rd.aruser = ARUSER_EN ? s_axi_rd.aruser : '0;

// 回向: 缩回源宽度(这一步很容易被忽略)
assign s_axi_rd.rid   = s_axi_rd.ID_W'(m_axi_rd.rid);
assign s_axi_rd.ruser = RUSER_EN ? m_axi_rd.ruser : '0;
```

**`tie` 一共只有 4 条 `$fatal`, 但覆盖了全部"不可恢复"的组合**: 地址变宽 / 数据宽度不等 / 字节宽度不等 / ID 变窄。剩下的组合(地址变窄、ID 变宽)都是安全的 —— 地址变窄只是少访问一块空间, ID 变宽只是浪费几位。

**回向那句 `s_axi_rd.rid = s_axi_rd.ID_W'(m_axi_rd.rid)` 是 tie 的正确性关键**: 下游的 ID 可能比上游宽(因为它多了 ID 拼接位, 或者本身就是个更宽的接口)。回程必须**缩回源宽度**, 否则上游看到的 `rid` 会比它发的 `arid` 宽, 匹配不上。这一句和正向的 `m_axi_rd.ID_W'(...)` 是配对的, 缺一句就错。

**数据通路是纯直连**: `assign s_axi_rd.rdata = m_axi_rd.rdata;` —— 没有任何位宽处理, 因为 `DATA_W` 必须相等(第 2 条 `$fatal`)。**这就是 tie 和 adapter 的分界线**: 数据宽度变 → 用 adapter; 只有地址/ID 宽度变 → 用 tie。

**user 信号的条件路由**是所有模块的统一写法:

```systemverilog
localparam logic ARUSER_EN = s_axi_rd.ARUSER_EN && m_axi_rd.ARUSER_EN;   // 两端都开才开
assign m_axi_rd.aruser = ARUSER_EN ? s_axi_rd.aruser : '0;
```

`ARUSER_EN` 是两端 `&&` 的结果。只在两端都启用时才传递, 否则接 0。这样做的原因: 如果下游不启用 user, 传上去的值会被忽略, 但**留着不接会出 X**, 所以显式接 0。这个 `&&` 模式在 fifo / register / crossbar 里一字不差地重复出现, 是全库的固定套路。

### 10.2 `1s` 系列: 单 slave 的专用封装

```
taxi_axi_crossbar_1s.sv (152)  = tie_wr + tie_rd + crossbar_wr(S_COUNT=1) + crossbar_rd(S_COUNT=1)
taxi_axi_interconnect_1s.sv (103) = 同理, 用 interconnect
```

参数比通用版少了数组维度:

```systemverilog
parameter S_THREADS = 2,                        // 标量, 不是数组
parameter S_ACCEPT  = 16,
parameter S_AW_REG_TYPE = 2'd0,                 // 标量
parameter M_AW_REG_TYPE = {M_COUNT{2'd1}},      // 数组(M_COUNT 侧仍是多口)
```

源码里留了一条注释, 解释了为什么:

```systemverilog
// TODO fix parametrization once verilator issue 5890 is fixed
parameter S_THREADS = 2,
```

**这条注释是个宝藏**: 它说明作者知道这个参数化不完美(应该和通用版一样是数组), 但因为 verilator 的 bug 只能退让。读开源代码时, 这种 `TODO + 原因` 的注释比代码本身更有价值 —— 它告诉你"这里的怪异是有历史原因的"。

### 10.3 APB 桥与 AXI-Lite: 结构性差异

`taxi_axil_apb_adapter.sv`(747 行)是 AXI-Lite 到 APB 的桥, 它的结构和 §7 的 AXI adapter 完全不同, 因为 **APB 没有独立的地址/数据通道**:

APB 是两相协议:

```
SETUP 相 : psel=1, penable=0, paddr/pwrite/pwdata 有效
ACCESS 相: psel=1, penable=1, 等 pready
```

代码里对应:

```systemverilog
STATE_IDLE: begin
    psel_next = 1'b1;               // SETUP 相
    pwrite_next = ...;
    state_next = STATE_DATA;
end
STATE_DATA: begin
    penable_next = 1'b1;            // ACCESS 相
    if (m_apb.psel && m_apb.penable && m_apb.pready) begin
        psel_next = 1'b0;
        penable_next = 1'b0;
        state_next = STATE_IDLE;
    end
end
```

响应映射(注意是**一个共享寄存器**同时驱动写和读两条响应, 因为 APB 一次只做一件事):

```systemverilog
logic [1:0] s_axil_resp_reg = '0, s_axil_resp_next;      // :118
assign s_axil_wr.bresp = s_axil_resp_reg;                // :132
assign s_axil_rd.rresp = s_axil_resp_reg;                // :138

// STATE_DATA 里采样 pslverr
s_axil_resp_next = m_apb.pslverr ? AXI_RESP_SLVERR : AXI_RESP_OKAY;   // :226
```

`pslverr` 在 **ACCESS 相结束的那一拍**才有效(与 `pready` 同拍), 所以要在 `STATE_DATA` 里采样并寄存, 不能在 SETUP 相就取。这正是 APB "错误信号与 ready 同拍" 的协议要求。

**读写轮转防饿死**: AXI-Lite 的读写是两条独立通道, 但 APB 只有一条。所以必须仲裁, 而且不能让写永远赢:

```systemverilog
write_eligible = s_axil_wr.awvalid && s_axil_wr.wvalid
              && (!s_axil_wr.bvalid || s_axil_wr.bready)
              && (!s_axil_wr.awready && !s_axil_wr.wready);
read_eligible  = s_axil_rd.arvalid
              && (!s_axil_rd.rvalid || s_axil_rd.rready)
              && (!s_axil_rd.arready);

if (write_eligible && (!read_eligible || last_read_reg)) begin
    // 写: 只有在没有读, 或上一次是读的时候才赢
    last_read_next = 1'b0;
end else if (read_eligible) begin
    last_read_next = 1'b1;
end
```

`last_read_reg` 是一个 **1 位轮转记忆**: "上次服务的是读吗?" 如果是, 这次让写。这是最省资源的公平仲裁(不需要计数器)。

### 10.4 `taxi_axil_axi_adapter`: 凭空造 AXI4 属性

AXI-Lite 没有 `len/size/burst/cache/...`, 转成 AXI4 时必须**填出合法的默认值**:

```systemverilog
assign m_axi_wr.awid    = '0;
assign m_axi_wr.awlen   = '0;          // 单拍
assign m_axi_wr.awsize  = 3'(AXI_BURST_SIZE);
assign m_axi_wr.awburst = 2'b01;       // INCR
assign m_axi_wr.awlock  = 1'b0;
assign m_axi_wr.awcache = 4'b0011;     // Modifiable + Bufferable
assign m_axi_wr.awqos   = '0;
assign m_axi_wr.awregion= '0;
assign m_axi_wr.wlast   = 1'b1;        // 单拍必然 last
```

`awcache=4'b0011` 特别值得注意: bit0=Bufferable, bit1=Modifiable(可合并)。**设成 `0011` 就是在告诉下游"这笔可以随便优化"** —— 因为 AXI-Lite 的单拍访问本来就是无序无关的。

`awlen=0` + `wlast=1` 是配对的最小合法突发。

---

## §11 参数联动速查与踩坑清单

### 11.1 参数分类

taxi 的参数分三类, 混着记会乱:

| 类别 | 出现在 | 例子 | 谁决定 |
|---|---|---|---|
| **接口位宽** | `taxi_axi_if.sv` | `DATA_W/ADDR_W/STRB_W/ID_W/*USER_EN/*USER_W` | 顶层 interface 例化时 |
| **行为参数** | 各模块 | `*_REG_TYPE`、`PIPELINE_OUTPUT`、`CONVERT_BURST`、`FIFO_DEPTH` | 模块例化时 |
| **拓扑参数** | crossbar / interconnect | `S_COUNT/M_COUNT/M_REGIONS/M_BASE_ADDR/M_ADDR_W/M_CONNECT*/M_SECURE/S_THREADS/S_ACCEPT/M_ISSUE` | 模块例化时 |

**接口位宽不需要也不能在模块上重设** —— 模块用 `localparam DATA_W = s_axi_wr.DATA_W` 读。如果模块和接口不一致, `$fatal` 会在 elaboration 期报错。

### 11.2 拓扑参数的编码规则(最容易配错的)

`crossbar` / `interconnect` 用**位拼接**传数组参数, 规则统一:

```
M_ADDR_W   : M_COUNT 个字段 × M_REGIONS 个字段 × 32 bit
             最后一个字段在最低位
M_BASE_ADDR: M_COUNT × M_REGIONS × ADDR_W bit
M_CONNECT  : M_COUNT × S_COUNT bit
M_SECURE   : M_COUNT bit
S_THREADS  : S_COUNT × 32 bit
S_ACCEPT   : S_COUNT × 32 bit
M_ISSUE    : M_COUNT × 32 bit
```

实例: `M_COUNT=2, M_REGIONS=1, M_ADDR_W={14, 14}` 等价于

```
M_ADDR_W[63:32] = 14    (master 1)
M_ADDR_W[31:0]  = 14    (master 0)
```

**字段顺序是"后面的在低位"**, 所以 `{14, 14}` 里第一个 14 属于 master 1。这个顺序极易搞反, 配错的表现是"地址解码全错但仿真不报错"。**验证手段就是看 §8.2 那张 `$display` 打印的地址表**。

`M_CONNECT` 是 `M_COUNT × S_COUNT` 位, 含义 `M_CONNECT[i][j]` = "master i 能否被 slave j 访问"。全 1 就是全连接。

### 11.3 三处"参数不是数组"的例外

`TODO fix parametrization once verilator issue 5890 is fixed` 这条注释出现在:

- `taxi_axi_crossbar.sv:26` 附近
- `taxi_axi_interconnect.sv:26` 附近
- `taxi_axi_crossbar_1s.sv:26` 附近

后果: `S_THREADS`/`S_ACCEPT` 在通用版里是数组(`{S_COUNT{32'd2}}`), 在 `1s` 版里是**标量**(`2`)。

**踩坑点**: 如果你把一个 `.S_THREADS(32'd2)` 传给通用版 crossbar, verilator 会报宽度不匹配; 必须写 `.S_THREADS({2{32'd2}})`。我在实测中踩到了这个(§1.4)。

### 11.4 `M_ADDR_W` 的取值下限

`taxi_axi_crossbar_addr.sv` 的 `initial` 检查:

```systemverilog
if (M_ADDR_W_INT[i] < 12 || M_ADDR_W_INT[i] > ADDR_W) begin
    $error("Error: address width out of range (instance %m)");
```

**下限 12** 意味着每个区段最小 4KB。这是 ARM 的一个惯例(4KB 是常见的最小页大小)。想分更小的区段必须自己改这个检查。

`M_ADDR_W = 0` 是允许的, 表示"禁用这个区段"(见 §8.2 条件①)。

### 11.5 默认参数组合的合理性

`taxi_axi_crossbar.sv` 的默认值(4 主 4 从):

```systemverilog
S_THREADS = {S_COUNT{32'd2}},     // 每个 slave 2 个 ID 线程
S_ACCEPT  = {S_COUNT{32'd16}},    // 每个 slave 16 笔在飞
M_ISSUE   = {M_COUNT{32'd4}},     // 每个 master 4 笔在飞
M_ADDR_W  = {M_COUNT{{M_REGIONS{32'd24}}}},   // 每段 16MB
```

推导: `M_COUNT=4 × 16MB = 64MB` 总地址空间, 对多数 SoC 的片上外设区域是够的。`S_ACCEPT=16` 比 `S_THREADS=2` 大得多, 说明**同一 ID 允许 8 笔在飞**(因为 thread 数是"不同 ID 数", accept 是"总在飞数")。

`S_THREADS=2` 很小 —— 因为多数主机只用 1-2 个 ID。如果你的主机(比如 GPU)会用 8+ 个 ID, 必须调大, 否则 crossbar 会**串行化**同 ID 之外的事务。

### 11.6 踩坑清单

**① `ADDR_W` 写成 `ADDR_W` 之外的值**

`taxi_axi_ram` 的 `ADDR_W` 是**独立参数**(存储深度), 而接口的 `ADDR_W` 是总线宽度。二者的关系只有 "`接口 ADDR_W >= 模块 ADDR_W`" 这一个约束。**把模块 `ADDR_W` 设成总线的 `ADDR_W`(比如 32)会生成 4G 个存储槽, 综合直接爆炸。**

**② `STRB_W` 与 `DATA_W` 不整除**

```systemverilog
if (BYTE_W * STRB_W != DATA_W)
    $fatal(0, "Error: AXI data width not evenly divisible (instance %m)");
```

`DATA_W=24` 会挂。`DATA_W=8/16/32/64/128/256` 安全。

**③ `ID_W` 在下游不够**

crossbar 拼接 ID 后需要 `S_ID_W + $clog2(S_COUNT)` 位。**好消息: 库检查了这条**(`taxi_axi_crossbar_wr.sv:121` 与 `taxi_axi_crossbar_rd.sv:113` 各一条):

```systemverilog
if (M_ID_W < S_ID_W+$clog2(S_COUNT))
    $fatal(0, "Error: M_ID_W must be at least $clog2(S_COUNT) larger than S_ID_W (instance %m)");
```

**坏消息: `taxi_axi_interconnect_wr/rd.sv` 没有这条检查**(`_wr.sv` 只有 3 条 `$fatal`: ADDR_W/DATA_W/STRB_W 不匹配; `_rd.sv` 多一条 M_REGIONS 的, 都不是 ID 宽度)。interconnect 也会做 ID 拼接, 所以**用 interconnect 时必须自己算**: 4 个 slave 各 8 位 ID → 下游至少 10 位。这是 crossbar 和 interconnect 一个容易被忽略的差异。

```systemverilog
// crossbar 有, interconnect 没有:
localparam S_ID_W = s_axi_wr[0].ID_W;      // crossbar_wr.sv:89
localparam M_ID_W = m_axi_wr[0].ID_W;      // :90
```

**④ `simple` buffer 用在数据通道上**

§4.4 实测: simple 的吞吐是 bypass/skid 的**一半**。把它配到 W 或 R 通道上会直接砍半带宽。

**⑤ 忘了 `M_CONNECT` 而只配 `M_ADDR_W`**

地址配对了但 `M_CONNECT[i][j]=0`, 结果是 DECERR。**两个条件都要满足**才命中。

**⑥ 在 negedge 轮询寄存化的 ready**

§1.5 说的死循环。这是写 TB 时最常见的坑。

**⑦ 用 verilator 编多 slave 的 crossbar**

verilator 5.032 不支持 `interface 数组` 端口(§1.4)。要么用 `_1s` 版本, 要么用商业仿真器。

**⑧ `$fatal` 里的 `%m`**

verilator 5.032 对 `$fatal(0, "... (instance %m)")` 报 `can't convert a SCOPENAME to constant`。绕过办法: 拷一份源码去掉 `%m`(我实测用的办法), 或者升级 verilator。

---

### 11.7 一份实测记录: 11 行隐式跨层次引用, 在库里能编过, 在你工程里编不过

这不是"参数配错"的坑, 而是**源码本身的一个陷阱**。它是我在给 §7 逐个 generate 分支做 lint 验证时撞上的, 值得单独写一节 —— 因为它同时教了三件事: 怎么用 lint 逼出没被走到的分支、为什么"在作者仓库里能编过"不等于"在你工程里能编过"、以及 SystemVerilog 的隐式跨层次引用有多危险。

> **一句话结论**: 库里有 11 行写成了 `s_axi.` / `m_axi.` / `m_axil.`(少了 `_wr`/`_rd` 后缀)。这在 SystemVerilog 里**不是语法错误**, 而是**隐式跨层次引用** —— 工具会去祖先作用域找一个同名的接口实例。作者自己的 TB 恰好把实例命名为 `s_axi`/`m_axi`, 所以上游编得过、CI 是绿的; 你只要不巧用别的名字例化, 就会 `Can't find definition of scope/variable`。

#### 怎么发现的

§7 里我把 adapter 分成 bypass / upsize / downsize 三支讲。讲 downsize 时我想"实测一下 128→32 的切片时序", 于是写了一个最小的 lint 外壳(只例化接口和 DUT, 不写激励):

```bash
cd /tmp/lt
cat > tb_dn.sv <<'EOF'
`timescale 1ns/1ps
module tb_dn;
logic clk=0, rst=1;
taxi_axi_if #(.DATA_W(128),.ADDR_W(32),.STRB_W(16),.ID_W(8)) s_if();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32),.STRB_W(4), .ID_W(8)) m_if();
taxi_axi_adapter_wr uut (.clk(clk), .rst(rst), .s_axi_wr(s_if), .m_axi_wr(m_if));
endmodule
EOF

verilator --lint-only --timing -Wno-fatal --top-module tb_dn \
  /home/chenye/learning/taxi/src/axi/rtl/taxi_axi_if.sv \
  /home/chenye/learning/taxi/src/axi/rtl/taxi_axi_adapter_wr.sv \
  tb_dn.sv
```

结果不是我想看的时序, 而是:

```
%Error: .../taxi_axi_adapter_wr.sv:730:38: Can't find definition of scope/variable: 's_axi'
%Error: .../taxi_axi_adapter_wr.sv:730:55: Can't find definition of scope/variable: 'm_axi'
%Error: .../taxi_axi_adapter_wr.sv:732:21: Can't find definition of scope/variable: 'm_axi'
%Error: .../taxi_axi_adapter_wr.sv:732:37: Can't find definition of scope/variable: 'm_axi'
%Error: .../taxi_axi_adapter_wr.sv:736:47: Can't find definition of scope/variable: 'm_axi'
%Error: .../taxi_axi_adapter_wr.sv:737:44: Can't find definition of scope/variable: 'm_axi'
%Error: .../taxi_axi_adapter_wr.sv:757:47: Can't find definition of scope/variable: 'm_axi'
%Error: Exiting due to 7 error(s)
```

`s_axi` / `m_axi` **不是这个模块里的名字** —— 这个模块的接口实例叫 `s_axi_wr` 和 `m_axi_wr`(§3.2 讲过的"读写分离"命名)。

#### 真相: 这不是"笔误编不过", 是隐式跨层次引用

我第一反应是"作者打错了字"。这个判断**是错的**, 而且错得很有教育意义。

SystemVerilog 允许在模块内部引用一个自己**没有声明**的名字: 工具会沿着**祖先作用域**逐级向上查找同名对象(这叫隐式跨层次引用, implicit hierarchical reference)。于是同一行代码会有两种命运:

- **祖先里恰好有同名的接口实例** → 编过。但那几行读到的是**那个叫这个名字的实例**, 而不是本模块端口列表里的 `s_axi_wr` / `m_axi_wr` —— 两者可能是同一个对象(作者 TB 就是), 也可能完全无关(诱饵实验里就是);
- **祖先里没有** → `Can't find definition of scope/variable`。

而 taxi 自带的 TB **恰好**把接口实例命名为 `s_axi` / `m_axi` / `s_axil` / `m_axil`, **而且那个实例就是接到端口上的同一个实例**:

```systemverilog
// tb/taxi_axi_adapter/test_taxi_axi_adapter.sv:85-99
taxi_axi_if #(...) s_axi();      // ← 顶层声明的实例
taxi_axi_if #(...) m_axi();
taxi_axi_adapter_wr uut (
    .s_axi_wr(s_axi),            // ← 同一个实例接进端口
    .s_axi_rd(s_axi),
    .m_axi_wr(m_axi),
    .m_axi_rd(m_axi));

// tb/taxi_axi_fifo/test_taxi_axi_fifo.sv:61
taxi_axi_if #(...) s_axi(), m_axi();   // 声明即接端口
```

于是那 11 行里的 `s_axi.bvalid` 向上找到的**正是端口上那个实例** —— 名字虽然写错了, 指向的对象是对的。**所以在作者自己的 TB 里, 这些行的功能是正确的, 上游 CI 是名副其实的绿。**

这一点必须说清楚: 这**不是**"测试给了假绿灯", 而是"代码依赖了一个不写在端口列表里的名字, 恰好那个名字指对了"。区别在于 —— 换个命名就崩, 见下一节。

#### 四个实验, 把机制钉死

以下全部是本机 verilator 5.032 实测, 命令都可复现。

**实验一: 放一个"诱饵"就能编过。** 让 DUT 的真实端口接 `real_s` / `real_m`, 另外在顶层**凭空**声明两个完全无关的 8 位接口实例, 只为了让名字存在:

```systemverilog
taxi_axi_if #(.DATA_W(128),.ADDR_W(32),.STRB_W(16),.ID_W(8)) real_s();
taxi_axi_if #(.DATA_W(32), .ADDR_W(32),.STRB_W(4), .ID_W(8)) real_m();
taxi_axi_if #(.DATA_W(8),  .ADDR_W(8), .STRB_W(1), .ID_W(2)) s_axi();   // 诱饵, 不接任何东西
taxi_axi_if #(.DATA_W(8),  .ADDR_W(8), .STRB_W(1), .ID_W(2)) m_axi();   // 诱饵
taxi_axi_adapter_wr uut (.clk(clk),.rst(rst),.s_axi_wr(real_s),.m_axi_wr(real_m));
```

→ **0 条 `%Error`**。位宽都故意写成 8 位, 跟真实端口(128/32 位)完全不同 —— 如果是"正确引用端口", 这里必然报位宽错误。它不报, 说明那几行**根本没看端口**。

**实验二: 查找会一路爬到根。** 把 DUT 塞进 `mid`, 再把 `mid` 塞进 `top`, 只有 `top` 有 `s_axi`/`m_axi`, DUT 的直系父层(`mid`)什么都没有 → 仍然 **0 条 `%Error`**。跨两层也找得到。

**实验三: 最小语义复现。** 子模块没有端口, 直接打印父层的接口信号:

```systemverilog
module inner;  initial $display("inner sees s_axi.bvalid = %b", s_axi.bvalid); endmodule
module top;    taxi_axi_if s_axi(); inner u(); endmodule
```

→ 编过、能跑, 打印 `inner sees s_axi.bvalid = 0`。**接口实例确实可以被向上引用。**

**实验四: 反向对照 —— 为什么这个坑只藏在接口上。** 把父层换成普通变量:

```systemverilog
module inner2; initial $display("%b", foo); endmodule
module e4;     logic foo = 1'b1; inner2 u(); endmodule
```

→ `%Error: e4.sv:2:39: Can't find definition of variable: 'foo'`。**普通变量不能这样向上引用, 接口实例可以。** 正是这个不对称, 让"漏写后缀"从"立刻报错"退化成"编译期静默通过 + 读到别的东西"。

#### 命名决定成败: 一张编译矩阵

把外壳里的实例名从"作者用的名字"换成"你自己会用的名字", 同一份 RTL 的错误数就变了:

| 模块 | 配置 | 父层实例名 `s_axi`/`m_axi`(作者 TB 风格) | 中性名(`s_if`/`m_if`、`sa`/`ma`、`axi_slv`/`axi_mst`) |
|---|---|---|---|
| `taxi_axi_adapter_wr` | 32→32 bypass | **0** | **7** |
| `taxi_axi_adapter_wr` | 32→128 upsize | **0** | **7** |
| `taxi_axi_adapter_wr` | 128→32 downsize | **0** | **7** |
| `taxi_axi_fifo_wr` | `FIFO_DELAY=1'b1` | **0** | **3**(`216:21` / `216:37` / `217:25`) |
| `taxi_axil_adapter_wr` | 64→32 downsize | **0** | **1**(`:340`) |
| `taxi_axil_adapter_rd` | 64→32 downsize | **0** | **1**(`:284`) |
| `taxi_axil_axi_adapter_wr` | 32→8 downsize | **0** | **1**(`:368`) |
| `taxi_axil_axi_adapter_rd` | 8→32 upsize | **0** | **1**(`:309`, 位于 downsize 文本里) |

顺带一个旁证: `taxi_axil_axi_adapter_rd` 那行我们用 **AXIL 8 → AXI 32(upsize)** 配置去跑, 报的却是 **`:309`** —— 而 `:309` 在 `downsize` 分支的源码里(`:211` 起)。这再次印证"所有 generate 分支的 dotted reference 都被解析了"。

**最贴近真实用法的那个测试**: 例化用户真正会用的 wrapper `taxi_axi_adapter`(32→128, 内含 `adapter_wr` + `adapter_rd`), 顶层写 `s_axi()/m_axi()` → **0 错**; 换成 `axi_slv()/axi_mst()` → **7 错**, 而且 7 条全部指向 `taxi_axi_adapter_wr.sv` 的 `:730/:732(x2)/:736/:737/:757`(5 行里共 6 个引用点: `:730` 的 `s_axi` 和 `m_axi`, `:732` 的 `bready`/`bvalid`, `:736`、`:737`、`:757` 各一处); `adapter_rd` 本身是干净的。

`adapter_wr` 三行(bypass / upsize / downsize)在中性名下**都是 7 条**, 一模一样 —— 这点很关键: **变量不是参数配置, 而是父层实例的名字**。verilator 5.032 的 `--lint-only` 会把所有 `generate` 分支的 dotted reference 都解析一遍, 所以连不会走 downsize 的 32→32 配置也照样报那 7 条。(只 elaborate 选中分支的工具则可能完全不报这个模块, 只报真正走到的那个分支。)

也就是说: **这个库的位宽转换器编不编得过, 取决于你把顶层接口实例叫什么名字。**

#### 它不只是"编不过", 运行期真的读错了对象

编译期解析到祖先实例这件事, 可以在波形上直接看到。实验布置: DUT 真实端口接 `real_s`(128 位从机侧)/ `real_m`(32 位主机侧), 顶层另放两个诱饵 `s_axi` / `m_axi`; 真实从机侧正常发一笔单拍写, 真实主机侧恒 `bvalid=1`、并且**故意把诱饵的 `m_axi.awvalid` 分别接 0 和 1**, 观察真实端口 `real_m.bready`。

`taxi_axi_adapter_wr.sv:730` 那行在 `STATE_RESP` 里算的是 `m_axi_bready_next = !s_axi.bvalid && !m_axi.awvalid;`。如果它引用的是**诱饵**, 那么诱饵 `awvalid` 一变, 真实输出的 `bready` 就该跟着变:

| 诱饵 `m_axi.awvalid` | `real_m.bready` 在 40 拍内的累计有效拍数 | 波形片段(进入 `STATE_RESP` 之后) |
|---|---|---|
| `1'b0` | **30** | `cyc=10 br=1`, `11..14 br=1` … 一直挂着 |
| `1'b1` | **1** | `cyc=10 br=1`, 然后 `11..14 br=0` … 掉了 |

注意这个诱饵**没有接进 DUT 的任何端口**。一个与 DUT 毫无电气连接的信号, **把真实端口的 `bready` 从"一直拉高"变成"一拍脉冲"**。这就是运行期证据: 那行代码读的确实是父层那个**同名实例**, 不是 `m_axi_wr` 端口 —— 名字一样才读它, 名字变了就换对象(或者报错)。

反过来也说明作者 TB 为什么没事: 那里的 `s_axi` 恰好**就是**接在端口上的实例, 所以"读错名字"读到了"正确的对象"。

顺带还能看到一个后果: 两组里 `real_s.bvalid` 都是 0 —— 因为 `:732` 的 `if (m_axi.bready && m_axi.bvalid)` 也在读诱饵, 诱饵 `bready=0` 使得这个分支永远不成立, FSM 卡在 `STATE_RESP` 出不来, **写响应永远回不到上游**。这类症状(upper 说"写完了但没响应")最难查, 因为源码看起来完全合理。

#### 11 行清单

同一个形态: **漏掉通道后缀 `_wr` / `_rd`**。全库用一条命令就能扫干净:

```bash
grep -nE "\b(s_axi|m_axi|s_axil|m_axil)\.[a-z]" rtl/*.sv \
  | grep -vE "\b(s_axi|m_axi|s_axil|m_axil)_(wr|rd)\."
```

> 注意 `m_apb` **不在**这个模式里, 尽管 `taxi_axil_apb_adapter.sv` 里满篇 `m_apb.paddr`。因为 APB 只有一组信号, 接口实例就叫 `m_apb`(没有 `_wr`/`_rd` 之分), 那些引用全是**对的**。判断标准不是"名字短", 而是"这个名字在模块里有没有被声明成接口实例"。

| # | 文件:行 | 原文 | 应为 | 所在状态 |
|---|---|---|---|---|
| 1 | `taxi_axi_adapter_wr.sv:730` | `m_axi_bready_next = !s_axi.bvalid && !m_axi.awvalid;` | `!s_axi_wr.bvalid && !m_axi_wr.awvalid` | `STATE_RESP` |
| 2 | `taxi_axi_adapter_wr.sv:732` | `if (m_axi.bready && m_axi.bvalid) begin` | `m_axi_wr.bready && m_axi_wr.bvalid` | `STATE_RESP` |
| 3 | `taxi_axi_adapter_wr.sv:736` | `if (first_transfer_reg \|\| m_axi.bresp != 0) begin` | `m_axi_wr.bresp` | `STATE_RESP` |
| 4 | `taxi_axi_adapter_wr.sv:737` | `s_axi_bresp_next = m_axi.bresp;` | `m_axi_wr.bresp` | `STATE_RESP` |
| 5 | `taxi_axi_adapter_wr.sv:757` | `s_axi_awready_next = !m_axi.awvalid;` | `!m_axi_wr.awvalid` | `STATE_RESP` |
| 6 | `taxi_axi_fifo_wr.sv:216` | `if (s_axi.wready && s_axi.wvalid) begin` | `s_axi_wr.wready && s_axi_wr.wvalid` | `STATE_TRANSFER_OUT` |
| 7 | `taxi_axi_fifo_wr.sv:217` | `if (s_axi.wlast) begin` | `s_axi_wr.wlast` | `STATE_TRANSFER_OUT` |
| 8 | `taxi_axil_adapter_wr.sv:340` | `if (m_axil.bresp != 0) begin` | `m_axil_wr.bresp` | downsize `STATE_RESP` |
| 9 | `taxi_axil_adapter_rd.sv:284` | `if (m_axil.rresp != 0) begin` | `m_axil_rd.rresp` | downsize `STATE_RESP` |
| 10 | `taxi_axil_axi_adapter_wr.sv:368` | `if (m_axi.bresp != 0) begin` | `m_axi_wr.bresp` | downsize `STATE_RESP` |
| 11 | `taxi_axil_axi_adapter_rd.sv:309` | `if (m_axi.rresp != 0) begin` | `m_axi_rd.rresp` | downsize `STATE_RESP` |

**每一处都紧挨着一行写对了的代码**, 这是它们能活下来的原因:

```systemverilog
// taxi_axil_adapter_wr.sv:339-341
s_axil_buser_next = m_axil_wr.buser;    // ← 对
current_seg_next  = current_seg_reg + 1;// ← 对
if (m_axil.bresp != 0) begin            // ← 错, 少了 _wr

// taxi_axi_adapter_wr.sv:715 vs :730 —— 同一个表达式, 两种写法
m_axi_bready_next = !s_axi_wr.bvalid && !m_axi_wr.awvalid;  // :715 对(在 STATE_DATA_2 里)
m_axi_bready_next = !s_axi.bvalid    && !m_axi.awvalid;     // :730 错(在 STATE_RESP 里)
```

上面那对 `:715` / `:730` 是最直接的自我证明: 同一文件、同一个表达式, 一处带后缀一处不带。**这不是作者有意设计, 就是漏写。**

#### 为什么这些行"看起来像能跑"

三个原因叠在一起:

1. **语义上恰好说得通**。`if (m_axi.bresp != 0)` 的意图一目了然 —— "响应不是 OKAY 时才覆盖 bresp"。读者脑子里会自动补上下划线, 眼睛不会停。
2. **它们全在"不常走"的状态里**。11 行里有 9 行在 downsize 支的 `STATE_RESP`, 2 行在 `FIFO_DELAY=1'b1` 才生成的 `STATE_TRANSFER_OUT`。而这些状态**只有真的搬完一笔数据、要回响应时才会进去** —— 恰好是最容易被"跑通了就收工"跳过的收尾阶段。
3. **上游仓库里就是这个样子**。我在本仓库核对过 `git show cc70b27:src/axi/rtl/taxi_axi_adapter_wr.sv`(cc70b27 是 `remotes/upstream/master`), 也直接取过 `https://raw.githubusercontent.com/fpganinja/taxi/master/src/axi/rtl/taxi_axi_adapter_wr.sv`, 两处**都是 `!s_axi.bvalid && !m_axi.awvalid`**。所以这不是本地改坏的, 也不是 fork 引入的。

> **关于"走不到"的一个更正**: 我一度以为"只有 downsize 分支会报错"。实测不是 —— verilator 5.032 对 `--lint-only` 会把**所有** `generate` 分支的 dotted reference 都解析一遍, 所以连 32→32 的 bypass 配置也报同样那几条。真正的变量**不是参数配置, 而是父层实例的名字**(见上面的矩阵)。只 elaborate 选中分支的工具(部分商业仿真器)则可能完全不报 —— 这也是它能存活的原因之一。

#### 修好之后能编过(附验证方法)

在 `/tmp/FIX` 复制 6 份源码, 把上表 11 行按"应为"列改掉, 然后**全部用中性实例名**重新 lint:

```bash
for f in taxi_axi_adapter_wr taxi_axi_fifo_wr taxi_axil_adapter_wr \
         taxi_axil_adapter_rd taxi_axil_axi_adapter_wr taxi_axil_axi_adapter_rd; do
  cp /home/chenye/learning/taxi/src/axi/rtl/$f.sv .
done
# ...(11 处替换, 见上表)
verilator --lint-only --timing -Wno-fatal --top-module <外壳> <接口>.sv <DUT>.sv <外壳>.sv
```

结果: `adapter_wr`(128→32) **0**、`fifo_wr`(FIFO_DELAY=1) **0**、`axil_adapter_wr` **0**、`axil_adapter_rd` **0**、`axil_axi_adapter_wr` **0**、`axil_axi_adapter_rd` **0**。

对照未修时的 `adapter_wr` 中性名 **7 条**, 说明**这 11 行就是全部**, 不多不少 —— 不是"还有别的问题被掩盖了"。

#### 与 `%m` 报错是两件事

这两个坑我一开始混在了一起:

| 现象 | 原因 | 处理 |
|---|---|---|
| `Expecting expression to be constant, but can't convert a SCOPENAME to constant`(指向 `$fatal(0, "... (instance %m)")`) | **verilator 5.032 的工具限制**(§11.6 ⑧) | 拷一份源码 `sed 's/ (instance %m)//g'`, 或用 ≥5.036 |
| `Can't find definition of scope/variable: 's_axi'` | **隐式跨层次引用**(本节) | 补 `_wr` / `_rd` 后缀 |

两者**正交**: 去掉 `%m` 之后, `s_axi` 报错一条不少地在; 只补后缀不去 `%m`, 就剩下一堆 `SCOPENAME`。必须分别处理。前面各节我一直在"拷副本 + 去 `%m`", 那是为了绕过工具限制, **不是**在掩盖源码问题。

#### 顺手能学到的三件事

**① 自带测试本来是设计成要覆盖这些分支的, 但它覆盖不到这类错误。**

`tb/taxi_axi_adapter/test_taxi_axi_adapter.py` 的 pytest 入口:

```python
@pytest.mark.parametrize("m_data_w", [8, 16, 32])
@pytest.mark.parametrize("s_data_w", [8, 16, 32])
def test_taxi_axi_adapter(request, s_data_w, m_data_w):
```

`{8,16,32}` 的笛卡尔积里, 32→8、32→16、16→8 **正是 downsize**。FIFO 那边同样:

```python
@pytest.mark.parametrize("delay", [0, 1])
@pytest.mark.parametrize("data_w", [8, 16, 32])
def test_taxi_axi_fifo(request, data_w, delay):
```

`delay=1` 正是 `FIFO_DELAY=1'b1`。**两套测试都明确要覆盖这些分支**, 而且它们用的是 `s_axi`/`m_axi` 这套命名 —— 那 11 行向上找到的就是接在端口上的同一个实例, **所以这些测试跑的是正确行为, 也真的会通过**。

问题不在测试结果, 而在这份代码的**正确性依赖一个没写进端口列表的名字**。测试证明的是"在作者这套 TB 里对", 不是"这个模块对"。一旦有人在自己工程里把顶层接口叫 `axi_slv`, 同一份 RTL 就连编都编不过(编译矩阵里的 7 条)。

> 我这里**没有**跑成这些 cocotb 测试(本机 cocotb 2.1.0 要求 verilator ≥ 5.036, 见 §1.4)。上面"测试会通过"是由机制推出的判断; 另一侧的**编译矩阵与诱饵 A/B 实验是我实测的**。

**② "读得懂"和"编得过"是两条独立的验证线。**

我在写 §7.4/§7.5 时把 downsize 的切片公式、地址回零、突发长度重算全推导了一遍, 逻辑上没有问题 —— 但那些代码**一行都没被编译器验证过**。真正让它暴露的是一次"顺手 lint 一下"。所以值得养成习惯: **每讲完一个 `generate` 分支, 就把那个分支的配置单独 lint 一遍**, 并且**故意用中性实例名**(不要用 `s_axi`/`m_axi`), 否则隐式跨层次引用会替你把错误藏起来。

```bash
verilator --lint-only --timing -Wno-fatal --top-module <最小外壳> <接口> <DUT> <外壳>
```

`--timing` 不能省, 否则含 `always #5` 的外壳会先报一串 `%Error-NEEDTIMINGOPT: Use --timing ...`, 很容易被误数成"源码错误"。

**③ 隐式跨层次引用是 SystemVerilog 的合法特性, 但别拿它当捷径。**

它在 TB 里偶尔有用(从子模块探父层的信号), 但在**可综合的 RTL 里**是灾难: 模块的端口不再决定它的行为, 行为取决于"它被谁例化、那个父层给实例起了什么名字"。这正是本节 11 行 bug 的根源 —— 它们单看每一行都"能编过"。

一个可操作的自检: 在 `default_nettype none` 之上再给自己一条纪律 —— **RTL 里引用接口, 必须写完整的 `<实例名>.<信号>`, 且该实例名必须在本模块的端口列表里出现**。一条 grep 就能查:

```bash
grep -nE "\b(s_axi|m_axi|s_axil|m_axil)\.[a-z]" rtl/*.sv | grep -vE "_(wr|rd)\."
```

---

---

## §12 动手实验

按难度排序。每个实验都给了**可复现的命令**和**预期观察点**。

### 12.1 实验一: 看 RAM 的一笔完整读写(★)

复用 `lab/tb_axi_ram_trace.sv`:

```bash
cd /home/chenye/learning/taxi/src/axi/lab
verilator --binary --timing -j 4 -Wno-fatal --top-module tb_axi_ram_trace \
  -o trace ../rtl/taxi_axi_if.sv ../rtl/taxi_axi_ram.sv tb_axi_ram_trace.sv
./obj_dir/trace
```

**预期**: 打出 §5.3 那张 21 拍的表。

**改着玩**:
- 把 `awlen` 从 3 改成 0(单拍), 观察 RESP 态是否被经过。
- 把 `PIPELINE_OUTPUT` 改成 1, 观察 `rvalid` 是否晚一拍。
- 把 `awsize` 从 2 改成 0(窄传输), 观察 `mem` 只有单字节被改。

### 12.2 实验二: 三种 register 的吞吐对比(★★)

`lab/vsim/tb_reg.sv`: 源侧连发 8 笔 AW, 数周期。分两种下游 ready 图案。

```bash
cd /home/chenye/learning/taxi/src/axi/lab/vsim
# 图案 A: 下游 awready 恒 1
for t in REG0 REG1 REG2; do
  verilator --binary --timing -j 4 -Wno-fatal -D$t --top-module tb_reg \
    -o tb_reg_$t ../../rtl/taxi_axi_if.sv ../../rtl/taxi_axi_register_wr.sv tb_reg.sv
  ./obj_dir/tb_reg_$t | grep RESULT
done
# 图案 B: 下游 awready 走 101 轮转图案
for t in REG0 REG1 REG2; do
  verilator --binary --timing -j 4 -Wno-fatal -D$t -DPATTERN --top-module tb_reg \
    -o tb_regP_$t ../../rtl/taxi_axi_if.sv ../../rtl/taxi_axi_register_wr.sv tb_reg.sv
  ./obj_dir/tb_regP_$t | grep RESULT
done
```

**预期**(本机实测):

```
RESULT reg_type=0-bypass accepted=8 at cycle=12 (sink awready = constant 1)
RESULT reg_type=1-simple accepted=8 at cycle=19 (sink awready = constant 1)
RESULT reg_type=2-skid   accepted=8 at cycle=12 (sink awready = constant 1)

RESULT reg_type=0-bypass accepted=8 at cycle=16 (sink awready = 101 pattern, rotating)
RESULT reg_type=1-simple accepted=8 at cycle=26 (sink awready = 101 pattern, rotating)
RESULT reg_type=2-skid   accepted=8 at cycle=15 (sink awready = 101 pattern, rotating)
```

**关键观察**: 绝对值里有固定的启动开销, 所以看**差值**:
- skid 与 bypass **恒 1 时完全同速**(12 = 12), `101` 图案时 skid 甚至更快(15 < 16) → **寄存器隔离是免费的**。
- simple 比 bypass 多 7~10 拍(8 笔) → **稳态吞吐减半**。

**这个数字比任何文字描述都有说服力** —— 它解释了为什么库的默认参数里没有一处用 simple 配数据通道。

**改着玩**: 把 `N_TX` 从 8 改成 32, 差值会线性放大(simple ≈ +1 拍/笔), 而 bypass/skid 的差值保持不变 —— 这证明差值是**稳态**的, 不是启动开销。

### 12.3 实验三: crossbar 的地址解码与 DECERR(★★★)

```bash
cd /home/chenye/learning/taxi/src/axi/lab/vsim
verilator --binary --timing -j 4 -Wno-fatal --top-module tb_xbar1s \
  -o xbar1s -f f1s.f
./obj_dir/xbar1s
```

**预期**(本机实测输出):

```
Addressing configuration for axi_crossbar_addr instance tb_xbar1s.uut.rd_inst.rd_inst.s_ifaces[0].addr_inst
 0 ( 0): 00000000 / 14 -- 00000000-00003fff
 1 ( 0): 00004000 / 14 -- 00004000-00007fff
READ  addr=00000100 -> rid=05 rdata=c0de0000 rresp=00
READ  addr=00004100 -> rid=05 rdata=c0de0001 rresp=00   ← rdata 的低位变成 1, 证明确实换了从机
READ  addr=0000c000 -> rid=05 rdata=00000000 rresp=11   ← DECERR
WRITE addr=00008100 -> bid=0b bresp=11                  ← bid 0b 是主机原始 ID
```

逐拍细节见 §8.8 的表。

**改着玩**:
- 把 `M_ADDR_W` 从 `{14,14}` 改成 `{12,12}`, 看 `0x4100` 变成 DECERR(因为 M1 区间变成 0x1000–0x1FFF)。
- 把 `M_CONNECT` 设成 `2'b01`(只有 slave 0 能连), 看是否全部 DECERR。
- 把 `M_SECURE` 设成 `2'b10`, 然后发 `aprot[1]=1` 的访问, 看 M1 是否拒绝。

### 12.4 实验四: adapter 的位宽打包(★★★)

```bash
cd /home/chenye/learning/taxi/src/axi/lab/vsim
verilator --binary --timing -j 4 -Wno-fatal --top-module tb_adapter_wr \
  -o adp ../../rtl/taxi_axi_if.sv ../../rtl/taxi_axi_adapter_wr.sv tb_adapter_wr.sv
./obj_dir/adp | head -20
```

**预期**: 见 §7.3 的表 —— 4 拍 32 位在 C9 合成 1 拍 128 位。

**改着玩**:
- 把 `CONVERT_NARROW_BURST` 改成 0, 观察不再合并(而是窄传输直通, `m_axi.awlen` 保持 3)。
- 把 `CONVERT_BURST` 改成 0, 同上。
- 加入 `awcache[1]=0` 的激励, 观察 `CONVERT_BURST=1` 也不合并 —— 这验证了 §7.6 的 `awcache[1]` 门控。

### 12.5 实验五: 自己写一个 AXI 从机(★★★★)

目标: 不看源码, 自己实现一个 `taxi_axi_ram` 的简化版, 然后用 `lab/tb_axi_ram_trace.sv` 的激励去跑。

**必须自己解决的三件事**:
1. `awready` 和 `wready` 是寄存器输出还是组合? 这决定 AW 到 W 之间隔几拍。
2. `bvalid` 在最后一拍写完之后**哪一拍**拉高?
3. `rlast` 怎么算?

做完后对照 §5.3 的表, 逐拍比较。**这个实验能把 §2.6 的推导彻底钉死**。

### 12.6 实验六: 给 crossbar 加一个 master(★★★★)

改动 `lab/vsim/tb_xbar1s.sv`: `M_COUNT` 从 2 改成 3, 相应地
- `.M_ADDR_W({14,14,14})`
- `.M_ISSUE({32'd2,32'd2,32'd2})`
- 增加一个 `m_axi_wr[2]` / `m_axi_rd[2]` 的从机模型

**观察点**: 地址表是否自动变成 `0x0000/0x4000/0x8000`; `M_COUNT=3` 时 `taxi_arbiter` 的 `PORTS=4`(因为 `M_COUNT_P1`)是否还能正确仲裁。

这是理解 §8.7 那个"虚拟 decerr 端口"的最好方式 —— 你会亲眼看到仲裁器多出一路。

### 12.7 实验七: 用 verible 做 Lint(★★)

本机 `/opt/verible/bin/verible-verilog-lint` 可用。**先用 `default` 规则集, 不要一上来就 `all`**:

```bash
cd /home/chenye/learning/taxi/src/axi
/opt/verible/bin/verible-verilog-lint --ruleset=default rtl/taxi_axi_ram.sv
```

实测输出 13 条(节选):

```
rtl/taxi_axi_ram.sv:21:15-20: Explicitly define a storage type for every parameter and localparam, (ADDR_W). [Style: constants] [explicit-parameter-storage-type]
rtl/taxi_axi_ram.sv:147:101-111: Line length exceeds max: 100; is: 111 [Style: line-length] [line-length]
rtl/taxi_axi_ram.sv:245:5-8: Explicitly define a default case for every case statement or add `unique` qualifier to the case statement. [Style: case-statements] [case-missing-default]
```

这三类告警恰好勾勒出这套代码的**风格取舍**:

1. **`explicit-parameter-storage-type`**: 库里写 `parameter ADDR_W = 16;` 而不是 `parameter int ADDR_W = 16;`。Verible 认为该写显式类型, 作者选择不写 —— 因为 AXI 的宽度参数在例化时经常被传 `32'd24` 这种**位宽明确的字面量**, 声明成 `int` 反而会在某些工具里触发位宽警告。
2. **`line-length`**: 库里若干行超过 100 字符(主要是 `$fatal` 的长消息和长条件表达式)。作者接受这个代价换取"一个条件一行"的可读性。
3. **`case-missing-default`**: 有些 `case` 没写 `default` —— 但注意 `taxi_axi_ram.sv` 的**写 FSM 有 `default`**(`write_state_next = WRITE_STATE_IDLE;`), 是**读 FSM 没有**。这不算 bug(枚举已穷举), 但 Verible 无法证明。

**如果换成 `--ruleset=all`**:

```bash
/opt/verible/bin/verible-verilog-lint --ruleset=all rtl/taxi_axi_ram.sv   # 35 条
/opt/verible/bin/verible-verilog-lint --ruleset=all rtl/*.sv              # 2675 条
```

多出来的 22 条几乎全是 `port-name-suffix`(要求输入端口叫 `_i`)、`dff-name-style`(要求时序变量以 `_next/_n/_d` 结尾)、`instance-shadowing`(端口名和模块名同名)这类**与本项目风格系统性冲突**的规则。**全库 2675 条不是"代码质量差", 而是"没打算遵循那个风格"** —— 这也是一堂关于 lint 规则集该怎么选的课: 规则集是团队约定, 不是绝对真理。

也可以只挑关心的规则:

```bash
/opt/verible/bin/verible-verilog-lint --rules=-line-length,-explicit-parameter-storage-type rtl/taxi_axi_ram.sv
```

或者用 verilator 的 lint 模式(它检查的是**可综合性**, 不是风格):

```bash
verilator --lint-only -Wno-fatal -Wall \
  ../rtl/taxi_axi_if.sv ../rtl/taxi_axi_ram.sv
```

**观察点**: `-Wall` 会打开 `UNOPTFLAT`、`WIDTHEXPAND` 等告警。库自己在 `taxi_axi_crossbar_addr.sv` 里写了 `/* verilator lint_off UNOPTFLAT */`, 说明作者是有意识地处理这些告警的 —— 看看你的代码能不能做到零告警。

> **verible 和 verilator lint 的分工**: verible 管**风格**(命名、行长、case 完整性), verilator 管**语义**(位宽、组合环、未驱动)。两个都要跑, 但别把 verible 的 `all` 输出当成待办清单。

**再加一步(做完 §11.7 之后我认为这一步最值钱)**: 把 DUT 的**每个 generate 分支**各配一遍, 每配一次跑一次 `--lint-only`。以 adapter 为例就是四种外壳:

```bash
# 等宽(bypass) / 变宽(upsize) / 变窄(downsize) / 不同 ID 宽度
verilator --lint-only -Wno-fatal --top-module e32_32 taxi_axi_if.sv taxi_axi_adapter_wr.sv shell_32_32.sv
verilator --lint-only -Wno-fatal --top-module e32_128 taxi_axi_if.sv taxi_axi_adapter_wr.sv shell_32_128.sv
verilator --lint-only -Wno-fatal --top-module e128_32 taxi_axi_if.sv taxi_axi_adapter_wr.sv shell_128_32.sv
```

外壳只有 8 行(接口声明 + DUT 例化), 一分钟能写一个。**这一分钟能买到的东西, 比读十遍代码多** —— §11.7 那 11 行隐式跨层次引用就是这样在几秒内暴露的, 而它们在这份代码里已经躺了很久。

**关键是外壳里的实例名**: 上面前两条命令如果写成 `s_axi`/`m_axi`(作者 TB 那套名字), 那 7 条错误**一条都不会出现** —— 隐式跨层次引用会替你把它们藏起来。所以外壳里的实例名要**故意用你工程里会用的名字**(`s_if`/`m_if`、`axi_slv`/`axi_mst`), 甚至刻意每次换一个, 才能看出有没有跨层引用。另外 `--timing` 别省, 否则含 `always #5` 的外壳会先报一串 `%Error-NEEDTIMINGOPT`。

## 附录 A 文件清单与依赖

`rtl/` 共 63 个 `.sv`, 18432 行, 31 个 `.f`。

### A.1 按功能分组(附行数)

**接口**
| 文件 | 行数 |
|---|---|
| `taxi_axi_if.sv` | 261 |
| `taxi_axil_if.sv` | 175 |

**寄存器 / FIFO**
| 文件 | 行数 |
|---|---|
| `taxi_axi_register_wr.sv` | 623 |
| `taxi_axi_register_rd.sv` | 472 |
| `taxi_axil_register_wr.sv` | 522 |
| `taxi_axil_register_rd.sv` | 371 |
| `taxi_axi_fifo_wr.sv` | 397 |
| `taxi_axi_fifo_rd.sv` | 361 |

**RAM**
| 文件 | 行数 |
|---|---|
| `taxi_axi_ram.sv` | 321 |
| `taxi_axi_ram_if_wr.sv` | 257 |
| `taxi_axi_ram_if_rd.sv` | 243 |
| `taxi_axi_ram_if_rdwr.sv` | 236 |
| `taxi_axi_dp_ram.sv` | 244 |
| `taxi_axil_ram.sv` | 157 |
| `taxi_axil_dp_ram.sv` | 278 |

**Adapter(位宽转换)**
| 文件 | 行数 |
|---|---|
| `taxi_axi_adapter_wr.sv` | 906 |
| `taxi_axi_adapter_rd.sv` | 815 |
| `taxi_axi_axil_adapter_wr.sv` | 776 |
| `taxi_axi_axil_adapter_rd.sv` | 666 |
| `taxi_axil_adapter_wr.sv` | 403 |
| `taxi_axil_adapter_rd.sv` | 334 |
| `taxi_axil_axi_adapter_wr.sv` | 431 |
| `taxi_axil_axi_adapter_rd.sv` | 359 |
| `taxi_axil_apb_adapter.sv` | 747 |

**Crossbar**
| 文件 | 行数 |
|---|---|
| `taxi_axi_crossbar_wr.sv` | 607 |
| `taxi_axi_crossbar_rd.sv` | 521 |
| `taxi_axi_crossbar_addr.sv` | 400 |
| `taxi_axi_crossbar.sv` | 165 |
| `taxi_axi_crossbar_1s.sv` | 152 |
| `taxi_axi_crossbar_1s_wr.sv` | 137 |
| `taxi_axi_crossbar_1s_rd.sv` | 130 |
| `taxi_axil_crossbar_wr.sv` | 546 |
| `taxi_axil_crossbar_rd.sv` | 444 |
| `taxi_axil_crossbar_addr.sv` | 302 |
| `taxi_axil_crossbar.sv` | 160 |
| `taxi_axil_crossbar_1s*.sv` | 148/131/124 |

**Interconnect**
| 文件 | 行数 |
|---|---|
| `taxi_axi_interconnect_wr.sv` | 669 |
| `taxi_axi_interconnect_rd.sv` | 633 |
| `taxi_axi_interconnect.sv` | 115 |
| `taxi_axi_interconnect_1s*.sv` | 103/105/105 |
| `taxi_axil_interconnect_wr.sv` | 505 |
| `taxi_axil_interconnect_rd.sv` | 440 |
| `taxi_axil_interconnect.sv` | 117 |
| `taxi_axil_interconnect_1s*.sv` | 107/106/106 |

**Tie / wrapper**
| 文件 | 行数 |
|---|---|
| `taxi_axi_tie_wr.sv` / `_rd.sv` / `tie.sv` | 85 / 78 / 61 |
| `taxi_axil_tie_wr.sv` / `_rd.sv` / `tie.sv` | 72 / 64 / 61 |
| `taxi_axi_register.sv` / `taxi_axil_register.sv` | 94 / 94 |
| `taxi_axi_fifo.sv` | 86 |
| `taxi_axi_adapter.sv` / `taxi_axi_axil_adapter.sv` | 82 / 82 |
| `taxi_axil_adapter.sv` / `taxi_axil_axi_adapter.sv` | 70 / 70 |

### A.2 `.f` 依赖文件的规则

31 个 `.f`, 命名 = `<模块名>.f`。内容形如:

```
taxi_axi_interconnect_wr.sv
taxi_axi_interconnect_rd.sv
taxi_axi_interconnect.sv
../lib/taxi/src/prim/rtl/taxi_arbiter.sv
../lib/taxi/src/prim/rtl/taxi_penc.sv
```

三个要点:

1. **`src/axi/lib/taxi` 是指向仓库根的符号链接**: `taxi -> ../../`。所以 `../lib/taxi/src/prim/rtl/` 实际解析到 `<repo>/src/prim/rtl/`。这是**跨子库依赖**的实现方式。
2. **不是每个模块都有 `.f`**: `taxi_axi_ram.sv` 没有, 因为它不依赖 prim 里的任何东西。`.f` 只在**有跨目录依赖**时才需要。
3. **`taxi_axi_crossbar.f` 会带上 `taxi_arbiter.sv` + `taxi_penc.sv`**, 因为 crossbar 用仲裁器。而 `taxi_axi_register.f` 只带两个 `.sv` 自己。

**用 `.f` 的正确姿势**:

```bash
verilator --lint-only -f rtl/taxi_axi_crossbar.f --top-module taxi_axi_crossbar
```

但注意: `.f` 里的相对路径是按**当前工作目录**解析的, 所以要在 `rtl/` 下执行, 或者用 `-y` 加搜索路径。

### A.3 testbench 清单

`tb/` 下 20 个目录, 每个都是 `Makefile + test_<dut>.sv + test_<dut>.py`:

```
taxi_axi_adapter      taxi_axi_axil_adapter   taxi_axi_crossbar
taxi_axi_crossbar_1s  taxi_axi_dp_ram         taxi_axi_fifo
taxi_axi_interconnect taxi_axi_interconnect_1s taxi_axi_ram
taxi_axi_register     taxi_axil_adapter       taxi_axil_apb_adapter
taxi_axil_axi_adapter taxi_axil_crossbar      taxi_axil_crossbar_1s
taxi_axil_dp_ram      taxi_axil_interconnect  taxi_axil_interconnect_1s
taxi_axil_ram         taxi_axil_register
```

**注意没有 `taxi_axi_tie` 的 TB** —— 因为 tie 是纯组合直连, 没有可测的状态机。这是个有用的信号: **看哪些模块有 TB, 就知道哪些模块有"行为"。**

`test_*.py` 用的是 `cocotbext-axi` 的 `AxiMaster`/`AxiSlave`/`AxiRam`, 加上 `set_idle_generator` / `set_backpressure_generator` 注入随机停顿。典型模式:

```python
@cocotb.parametrize(
    ("idle_inserter", [None, cycle_pause]),
    ("backpressure_inserter", [None, cycle_pause]),
    ("size", [None] + list(range(max_burst_size))),
)
async def run_test_write(dut, idle_inserter=None, backpressure_inserter=None, size=None):
    ...

def cycle_pause():
    return itertools.cycle([1, 1, 1, 0])
```

`itertools.cycle([1,1,1,0])` 是"每 4 拍停 1 拍"的确定性图案, 比随机更好复现。

---

## 附录 B 术语表

| 术语 | 含义 | 本文对应 |
|---|---|---|
| `beat` | 突发中的一拍数据 | §2.1 |
| `burst` | 一笔突发(1~256 拍) | §2.1 |
| `skid buffer` | 用影子寄存器实现零气泡的寄存器切片 | §4.3 |
| `simple buffer` | 有气泡的寄存器切片, 输出空才收输入 | §4.2 |
| `bypass` | 纯组合直连 | §4.1 |
| `thread` | crossbar 里按 ID 追踪事务的槽位 | §8.3 |
| `accept` | 允许同时在飞的事务数 | §8.3 |
| `issue` | master 侧允许同时在飞的事务数 | §11.5 |
| `lane` | 总线上的一个字节通道 | §2.4 |
| `segment` | 宽总线被切开后的一段 | §7.1 |
| `DECERR` | 地址解码失败的错误响应(`2'b11`) | §8.8 |
| `SLVERR` | 从机内部错误的响应(`2'b10`) | §10.3 |
| `region` | master 的一个地址区段(`M_REGIONS`) | §8.2 |
| `NARROW_BURST` | 传输宽度小于总线宽度 | §2.4 |
| `early` 信号 | 组合前瞻的 ready, 用于消气泡 | §4.3 |

---

## 结语: 这套代码值得学的四件事

1. **两阶段 FSM 的纪律**: `always_comb` 只算 `_next`, `always_ff` 只寄存, 复位放最后。全库 63 个文件无一例外。这种一致性让任何模块都能在 30 秒内找到"状态在哪、逻辑在哪"。

2. **参数从接口提取**: `localparam DATA_W = s_axi_wr.DATA_W`。消除了"两个配置源"这类灾难性 bug, 是这套代码能在 63 个文件间保持一致的根本原因。

3. **用 `$fatal` 做静态检查**: 把"配置错误"从"运行时的诡异行为"提前到"elaboration 期的明确报错"。**这是最便宜的验证投入**, 每个 `$fatal` 都省了未来几小时的调试。

4. **为可读性接受重复**: adapter 的 upsize/downsize 两支有大量对称代码, `b_data` 可以抽公共函数, 但作者选择了复制。因为**一个能单独读懂的分支 > 一个需要理解参数化才能读懂的分支**。

如果只能带走一条: **第 2 条**。它是所有其他优点的前提 —— 因为参数只有一个来源, 才有可能在 63 个文件、18432 行里保持逻辑一致。

### 一条反面教训

上面四条都是"值得学"的。但读完 18432 行之后, 有一件事也值得记住: **这个库里有 11 行把接口实例名写成了 `s_axi.` / `m_axi.` / `m_axil.`(漏了 `_wr`/`_rd`)。** 它们在作者自己的 TB 里能编过、也能跑对, 因为那是**隐式跨层次引用**, 向上找到的恰好就是接在端口上的那个同名实例; 但只要你在自己工程里把顶层接口实例换个名字, 同一份 RTL 就连编都编不过 —— 而如果那个名字恰好存在却指向别的东西, 它还会静默读错。详见 [§11.7](#117-一份实测记录-11-行隐式跨层次引用-在库里能编过-在你工程里编不过)。

它不推翻前面四条 —— 正好相反, 这些代码的**架构**仍然清晰, 问题出在"引用了一个不在端口列表里的名字"这一种写法上。它提醒的是另一件事:

> **"编译通过"是一个很弱的前提, 它可能什么都没证明。** 三条验证线要分开走: 一条是"这个算法对不对"(读 + 推导 + 波形); 一条是"这份源码能不能 elaborate"(对**每个 generate 分支**各跑一次 lint, 并且**故意不用作者的实例名**); 还有一条是"它引用的到底是不是我以为的那个对象"(看端口列表, 不要看名字像不像)。第一条可以很快得出结论, 后两条常常被跳过 —— 而恰恰是它们能在几秒内拓出一个潜伏很久的 bug。

这也是为什么本文把"每个离散的配置都真跑一次"当成方法论(§1.2 的 L3): 不是为了好看, 是因为它真的能把"以为自己读懂了"和"它确实能跑"分开。

---

*本文基于 taxi 仓库 `/home/chenye/learning/taxi/src/axi` 的实读与实测。波形数据由 `lab/` 下的 verilator testbench 生成, 可用文中命令复现。*
