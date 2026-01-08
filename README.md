# IP Design Specification: LDO Controller (LDO_CTRL)

| **Document Info** | **Details** |
| --- | --- |
| **IP Name** | LDO_CTRL |
| **Version** | **Rev 4.2 (Realease)** |
| **Date** | 2026-01-06 |
| **Status** | Ready for RTL Coding |
| **Description** | Digital Controller for Mixed-Signal Power Handover |

---

# 1. 概述 (General Description)

**LDO_CTRL** 是一个专用于数模混合电路电源管理的数字控制 IP。其核心功能是管理电源负载从 **DLDO (Digital LDO)** 到 **ALDO (Analog LDO)** 的切换（Handover）。

- **IDLE 状态：** 通过寄存器静态控制 DLDO/ALDO 的开启数量及模拟 Trim 值。
- **ACTIVE 状态：** 响应硬件触发信号，自动执行 DLDO 关闭与 ALDO 开启的线性切换序列。

---

# 2. 接口定义 (Signal Definition)

## 2.1 系统接口 (System Interface)

| **Pin Name** | **Dir** | **Width** | **Description** |
| --- | --- | --- | --- |
| **clk** | In | 1 | **System Clock**. 系统主时钟。 |
| **rst_n** | In | 1 | **System Reset**. 异步复位，低电平有效。 |
| **start_trig_n** | In | 1 | **Handover Trigger**. 切换触发信号 (Active Low)。
• **1**: 系统保持 IDLE 或触发回切序列。
• **0**: 启动 Handover 倒计时窗口。
*注：RTL 需对此信号做 2 级同步及去抖处理。* |
| **status** | Out | 1 | **Combined Status Flag**
指示系统是否处于“繁忙/切换中”。 
• **1 (Ready/Done):** `start_trig_n` 为高 **或** 计时结束 (`timer == 0`)。 
• **0 (Busy):** `start_trig_n` 为低 **且** 计时未结束 (`timer > 0`)。 |

## 2.2 SPI 接口 (SPI Interface)

Note: SPI的模式为Mode 0。

| **Pin Name** | **Dir** | **Width** | **Description** |
| --- | --- | --- | --- |
| **spi_cs_n** | In | 1 | **Chip Select**. |
| **spi_sclk** | In | 1 | **Serial Clock**. |
| **spi_mosi** | In | 1 | **Master Out Slave In**. |
| **spi_miso** | Out | 1 | **Master In Slave Out**. |

**Clock Domain Constraint (时钟域约束):**

- **SPI Domain**: 所有 SPI 信号 (`spi_cs_n`, `spi_sclk`, `spi_mosi`, `spi_miso`) 均工作在 `spi_sclk` 时钟域，频率为10 MHz。
- **Core Domain**: 内部 FSM 及控制逻辑工作在 `clk` (System Clock) 时钟域， 频率为100 MHz。
- **Asynchronous**: `spi_sclk` 与 `clk` 为异步关系。IP 内部必须包含完整的 CDC (Clock Domain Crossing) 处理电路。

## 2.3 模拟控制接口 (Analog Interface)

### **动态控制信号 (Dynamic Controls)**

此类信号由 FSM 状态机直接控制，用于执行 Handover 动作。

Note：请严格遵守极性定义，防止短路风险。

| **Pin Name** | **Direction** | **Width** | **Polarity** | **Description** |
| --- | --- | --- | --- | --- |
| **dldo0_en_n** | Out | 64 | Active Low | **DLDO0 Control Array (Thermometer Code)**.
• **0**: Cell ON (开启 LDO 单元)
• **1**: Cell OFF (关闭 LDO 单元)
IDLE 时由寄存器 `DLDO0_INIT` 控制，Handover 时逐步关闭。 |
| **dldo1_en_n** | Out | 64 | Active Low | **DLDO1 Control Array (Thermometer Code)**.
• **0**: Cell ON
• **1**: Cell OFF
IDLE 时由寄存器 `DLDO1_INIT` 控制，Handover 时逐步关闭。 |
| **aldo_en** | Out | 15 | Active High | **ALDO Control Array (Thermometer Code)**.
• **1**: Cell ON
• **0**: Cell OFF
IDLE 时全关，Handover 时开启至 `ALDO_TARGET`。
*注：只是提供ALDO偏置，并不实际控制开关。* |

### **静态控制信号 (Static Controls)**

此类信号直接透传寄存器配置，用于模拟电路的静态偏置微调。

Note：请严格遵守极性定义，防止短路风险。

| **Signal** | **Dir** | **Width** | **Polarity** | **Description** |
| --- | --- | --- | --- | --- |
| **vref_trim** | Out | 16 | Active High | Bandgap Trim 基准电压微调。 |
| **ks0_trim** | Out | 8 | Active High | Kick-Starter 0 Strength Trim。 |
| **ks1_trim** | Out | 8 | Active High | Kick-Starter 1 Strength Trim。 |
| **r2r_dac_in** | Out | 16 | Active High | R2R DAC Data Input
 ([15:8] Ch2, [7:0] Ch1)。 |
| **spare_out** | Out | 3 | Active High | Direct register mapping for debug or extra trim. |

---

# 3. 寄存器映射 (Register Map)

- **Base Address**: 0x00
- **Bus Width**: 32-bit
- **Endianness**: Little Endian

## 0x00: HANDOVER_CTRL (切换控制寄存器)

| **Bits** | **Name** | **R/W** | **Default** | **Description** |
| --- | --- | --- | --- | --- |
| 31:19 | Reserved | RO | 0x0 | - |
| 18:3 | **`TIMER_VAL`** | R/W | 16hFFFF | **Handover Timeout Window**.
定义 Handover 总时间窗口。 |
| 2:1 | **`STEP_RATE`** | R/W | 2b00 | **Ramp Step Rate**.
• `00`: 1 cell/period
• `01`: 2 cells/period
• `10`: 4 cells/period
• `11`: 8 cells/period |
| 0 | **`FSM_EN`** | R/W | 2b0 | **FSM Enable Control**.
• `0`: Disable. 强制复位至 IDLE。
• `1`: Enable. 允许响应外部触发。 |

## 0x04: LDO_INIT_CFG (LDO 初始配置)

| **Bits** | **Name** | **R/W** | **Default** | **Description** |
| --- | --- | --- | --- | --- |
| 31:14 | Reserved | RO | 0x0 | - |
| 15:14 | **`ALDO_TARGET`** | R/W | 2b00 | **ALDO Target Count** (0~15).
定义切换完成后 ALDO 开启的 Cell 数量。
• `00`: 开启0个cell
• `01`: 开启5个cell
• `10`: 开启10个cell
• `11`: 开启15个cell |
| **13:7** | **`DLDO1_INIT`** | R/W | 0x00 | **DLDO1 Initial Count (0~64).**
Sets initial number of active cells.
• Range: 0 (All Off) to 64 (All On). |
| **6:0** | **`DLDO0_INIT`** | R/W | 0x00 | **DLDO0 Initial Count (0~64).**
Sets initial number of active cells.
• Range: 0 (All Off) to 64 (All On). |

## 0x08: ANALOG_STATIC (模拟静态配置)

| **Bits** | **Name** | **R/W** | **Default** | **Description** |
| --- | --- | --- | --- | --- |
| **31:29** | **`SPARE_OUT`** | R/W | 0x0 | Directly drives the `aux_ctrl` output pins.
No decoding (Binary transparent). |
| **28:13** | **`R2R_DAC_VAL`** | R/W | 0x0 | **DAC Data Input.** 
[15:8] Ch2, [7:0] Ch1. |
| **12:9** | **`KS1_TRIM`** | R/W | 0x0 | **KS1 Strength Trim (0~8).**
Range: 0 to 8 cells ON. |
| **8:5** | **`KS0_TRIM`** | R/W | 0x0 | **KS0 Strength Trim (0~8).**
Range: 0 to 8 cells ON. |
| **4:0** | **`VREF_TRIM`** | R/W | 0x0 | **Bandgap Trim (0~16).**
Range: 0 to 16 cells ON. |

---

# 4. 功能描述 (Functional Description)

## 4.1 状态机流程 (FSM Workflow)

状态机仅包含两个主状态：**IDLE (空闲/保持)** 和 **ACTIVE (切换/锁定)**。

**Global Reset & Override**

- 若 `rst_n == 0` 或 `FSM_EN == 0`：
    - State = **IDLE**
    - Timer = 0
    - `dldo_cnt` = `DLDO_INIT` (Register Value).
    - `aldo_cnt` = 0.

### **State 0: IDLE**

- **进入条件**：
    - `rst_n == 0` (系统复位)
    - `FSM_EN == 0` (软件禁用)
    - `start_trig_n == 1` (用户请求停止/退出)
- **行为 (Behavior)**：
    - **Timer**: `timer_cnt` = `TIMER_VAL`。
    - **DLDO Output**: 保持寄存器设定值 (`DLDO_INIT_CFG`)。
    - **ALDO Output**: 强制为 0 (全关)。
- **跳转 (Transition)**：
    - 若 `start_trig_n` 检测到 **下降沿** 且 `FSM_EN == 1`：
        - 装载 `timer_cnt = TIMER_VAL`
        - 跳转至 -> **ACTIVE**

### **State 1: ACTIVE**

- **行为 (Behavior)**：
在此状态下，逻辑根据 `timer_cnt` 的值分为两个阶段：
    1. **Ramping Phase (timer_cnt > 0)**:
        - `timer_cnt` 每个时钟周期自减。
        - 依据 `STEP_RATE` 对 DLDO 执行递减 。
        - 依据`ALDO_TARGET`直接开启ALDO。
    2. **Holding Phase (timer_cnt == 0)**:
        - `timer_cnt` 保持为 0。
        - **强制输出最终态**：`dldo_out = 0`, `aldo_out = ALDO_TARGET`。
- **跳转 (Transition)**：
    - 若 `start_trig_n` 变高 (Rising Edge)：立即跳转回 -> **IDLE**。

## 4.2 通用译码逻辑 (Common Decoding Logic)

INIT_CFG寄存器和ANALOG_STATIC寄存器中除了**`SPARE_OUT`**外**，**均采用 **Binary to Thermometer** 译码方式驱动模拟接口。

当寄存器溢出输出端口时，输出锁定为全1。
***特别说明：DLDO 端口为 Active Low。***
