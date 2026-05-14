# 公知Jetty可靠通信设计文档（三次握手 / 四次挥手）

_面向读者：对 UMDK/URMA/UBMAD 代码零基础的新开发者。_
_文档版本：v3.9（修正 v3.7-3.8 残留：release_session 内 cancel-sync 自死锁；find_by_* 用 kref_get_unless_zero 防复活）_
_最后更新：2026-05-14_

---

## 目录

0. [设计说明（必读）](#0-设计说明必读)
1. [背景与现有机制](#1-背景与现有机制)
2. [整体设计思路](#2-整体设计思路)
3. [状态机定义](#3-状态机定义)
4. [Step 1：添加握手消息类型枚举](#step-1添加握手消息类型枚举)
5. [Step 2：定义会话状态与核心数据结构](#step-2定义会话状态与核心数据结构)
6. [Step 3：实现会话管理函数（新建 ubmad_session.c）](#step-3实现会话管理函数)
7. [Step 4：实现握手发送侧函数](#step-4实现握手发送侧函数)
8. [Step 5：接入接收消息分发路径](#step-5接入接收消息分发路径)
9. [Step 6：实现四次挥手](#step-6实现四次挥手)
10. [Step 7：实现重传定时器与 TIME_WAIT](#step-7实现重传定时器与-time_wait)
11. [Step 8：集成到模块初始化与清理](#step-8集成到模块初始化与清理)
12. [Step 9：更新 Kconfig 与 Makefile](#step-9更新-kconfig-与-makefile)
13. [Step 10：验证与测试](#step-10验证与测试)
14. [Step 11：Kconfig 特性开关](#step-11kconfig-特性开关)
15. [16 个核心函数汇总](#16-个核心函数汇总)
16. [常见错误排查](#常见错误排查)
17. [关键数据流图](#关键数据流图)
18. [未决设计问题](#未决设计问题)

---

## 0. 设计说明（必读）

> 本节回答"这个设计为什么是这样的"——v2 版本只讲怎么实现，没讲为什么这么设计；v3 补上。如果你跳过本节直接照 Step 1 写代码，会在 Step 7 看到重传逻辑时困惑"为什么不用 UBMAD 现有的 MSN 重传"。

### 0.1 这个设计在解决什么问题

> **核心动机**：把 WK Jetty 从"UBMAD 内部独占使用的不可靠消息总线"，改造成一个可被**多个上层实体并发使用**的**可靠通信通道**——类似 TCP 在 IP 之上提供多路复用的可靠流。

#### 现状

URMA 的 WK Jetty（参见 [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md) §4.7）在物理上是 `UM trans_mode + UTP tp_type`：**不可靠数据报、无连接**。当前几乎只有 UBMAD 在使用它，承载 UBCM 的 `CREATE_REQ`/`CREATE_RESP` 等控制消息。可靠性由 UBMAD 自己的 MSN+重传机制（`ubmad_datapath.c`，详见 [`umdk_ubmad_wk_jetty_deep_dive.md`](umdk_ubmad_wk_jetty_deep_dive.md) §13）在**单条消息粒度**上保证——但这套机制是 UBMAD 内部的，不暴露给其他上层使用者。

#### 目标

让 WK Jetty 成为一个**共享基础设施**：

1. **多实体并发使用**：除了 UBMAD 自身的 UBCM 控制流之外，其他内核组件（ULP、自研协议、cluster control plane 等）可以**同时**在 WK Jetty 上跑各自的会话，互不干扰。每个会话有自己独立的状态、序列号、重传定时器。
2. **可靠通道封装**：底层 WK Jetty 是 UTP（不可靠），上层通过本设计提供的 `ubmad_wk_session` 抽象获得**类 TCP 的可靠通道**——三次握手建链、有序拆除、会话级重传保障传输完整性。

#### 类比 TCP / IP 模型

| 网络模型 | URMA 模型（本设计后） |
|---------|---------------------|
| IP 层：尽力而为投递、不可靠、共享 | WK Jetty（UM/UTP），以 EID 为目的地址 |
| TCP 层：多路复用、可靠流、连接抽象 | `ubmad_wk_session`（本设计），以 `session_id` 为多路复用键 |
| TCP 端口：标识应用层服务 | （v1 缺失）见 [§18.2](#182-high-多-listen-支持的迁移路径)：未来需要的 `service_id` 字段 |
| TCP 三次握手 / 四次挥手 | UBMAD_WK_SYN/SYN_ACK/ACK / FIN/FIN_ACK |
| TCP 重传（超时 + 快速重传）| `ubmad_wk_syn_rt_work_handler` 指数退避（见 [Step 7](#step-7实现重传定时器与-time_wait)）|

#### 与现有 MSN 的分工（关键概念）

| 层级 | 谁负责 | 粒度 | 谁能用 |
|------|--------|------|--------|
| WK Jetty 本身（UTP） | 硬件 / UDMA | 单数据报 | 任何上层 |
| UBMAD MSN+重传 | UBMAD（`ubmad_post_send`）| 单消息 | **仅 UBMAD 自己**（UBCM/UBMAD_AUTHN） |
| 本设计 `ubmad_wk_session` | UBMAD 新增模块 | 会话生命周期 + 多消息重传 | **任何启用了 `CONFIG_UBMAD_WK_SESSION` 的上层模块** |

注意：MSN 是 UBMAD 内部的实现细节，不是公开 API；其他上层无法直接复用 MSN 的可靠性。本设计提供的 `ubmad_wk_*` API **才是**对其他上层公开的可靠通信接口。

#### 当前不在范围内（v1 已知缺口）

- **数据平面**：本设计仅提供建链和拆链（`connect / listen / close`），**没有提供** `ubmad_wk_send(session, data)` 用于会话建立后的可靠数据发送。如果上层只需要"建立连接"这一信号，v1 即可满足；如果需要类 TCP 的可靠数据流，**需要追加 v2 数据平面 API**——见 [§18.0](#180-critical-数据平面缺失)。
- **流控**：v1 没有 TCP 风格的滑动窗口或拥塞控制。每个会话独立重传，但发送速率由调用方自行管控。
- **多端口（service_id）**：v1 每设备一个 listen，相当于"只有一个端口"。上层只能用 `(local_eid, remote_eid)` 作为隐式 service 标识。多 service 见 [§18.2](#182-high-多-listen-支持的迁移路径)。

### 0.2 与 UBMAD MSN+重传的层叠关系

**关键决定：握手消息绕过 MSN，直接调用 `ubcore_post_jetty_send_wr()`。**

这是 [Step 4](#step-4实现握手发送侧函数) 中 `ubmad_post_send_wk()` 的实现选择。原因：

| 选项 | 行为 | 选择 |
|------|------|------|
| 走 `ubmad_post_send()` | 握手消息得到 MSN per-message 重传保证 | ❌ 不选 |
| 走 `ubcore_post_jetty_send_wr()` | 握手消息一次性投递，依靠会话级 SYN/ACK 重传 | ✅ 选 |

为什么不复用 MSN？

1. **重传语义不同**：MSN 是"消息一定送到"的端到端确认；握手需要的是"状态机推进失败时整体重试"。在 `SYN_SENT` 状态下，如果 SYN 丢了，要重发 SYN（同一个 session_id、同一个 ISN），而不是 MSN 风格的"重新投递任意一条消息"。
2. **重传时间窗口冲突**：MSN 的最大重传窗口约 4 秒（见 §0.3 的计算）；如果叠加在会话层之下，session 的状态超时与 MSN 的消息超时会互相干扰，调试难度倍增。
3. **重复抑制由 session_id 提供**：MSN 的去重靠 `msn_node` 哈希；本设计的去重靠 `session_id` + 状态匹配（重复的 SYN 落入同一 session，幂等处理），不需要 MSN 的去重机制。
4. **简化失败路径**：MSN 内部失败时会调度 `rt_work` 重试；如果握手层也重试，定时器层叠会导致清理时机难以推理。

**对实现者的影响**：
- `ubmad_post_send_wk()` 直接调 `ubcore_post_jetty_send_wr()`，**不要**调 `ubmad_post_send()`。
- `ubmad_wk_syn_rt_work_handler()` 是握手消息的**唯一**重传入口。
- 握手消息不会出现在 `dev_priv->msn_mgr` 的统计里——这是预期行为。

### 0.3 TIME_WAIT 与 MSN 重传窗口的关系

`UBMAD_WK_TIME_WAIT_MS = 4000` 常被误解为"类比 TCP 2×MSL"——TCP 中的 MSL 通常 30-60s，2×MSL 应在 60-120s 量级。这里取 4000ms 的真正理由是**与 UBMAD MSN 的最大重传窗口对齐**：

`ubmad_datapath.c:21` 定义 `ubcore_max_retry_cnt = 11`；重传间隔为 `1 << rt_cnt` 毫秒（指数退避）。最大累计窗口：

```
2^0 + 2^1 + 2^2 + ... + 2^11 = 2^12 - 1 = 4095 ms ≈ 4.0 秒
```

也就是说，**MSN 给定一条消息最多 4 秒的重试机会**。本设计的 TIME_WAIT 保证：在 session 进入 TIME_WAIT 后等待 ≥ MSN 最大窗口，确保对端可能由 MSN 触发的延迟重传（如对最后一个 FIN_ACK 的乱序响应）已经被处理完毕，再回收 session_id。

如果将来 `ubcore_max_retry_cnt` 默认值变化，或者改用其他底层传输，**TIME_WAIT 也应同步调整**。本设计未把 `UBMAD_WK_TIME_WAIT_MS` 与 `ubcore_max_retry_cnt` 通过宏关联，是 v3 的待改进项（见 [§18 未决设计问题](#18-未决设计问题)）。

### 0.4 与 `net/ubcore_session.c` 的关系

URMA 内核已有一个名为 `ubcore_session` 的抽象，定义在 `kernel/drivers/ub/urma/ubcore/net/ubcore_session.c:17-230`：以 `session_id` 为键、带 `complete_cb` 回调和 `delayed_work` 超时的轻量会话对象。它被 `net/ubcore_cm.c` 用于网络层 CREATE_REQ/RESP 的请求-响应配对（参见 [`umdk_link_setup_timing.md`](umdk_link_setup_timing.md) §10）。

**本设计提出的 `ubmad_wk_session` 与之并不冲突，但层次不同：**

```
┌──────────────────────────────────────────────┐
│  上层应用（hypothetical）                     │
│  调用 ubmad_wk_connect / wk_close            │
├──────────────────────────────────────────────┤
│  ubmad_wk_session (本设计)                    │
│  状态机：CLOSED / LISTEN / SYN_SENT / ...     │
│  跨多消息（SYN → SYN_ACK → ACK）              │
├──────────────────────────────────────────────┤
│  ubmad_post_send_wk → ubcore_post_jetty_send │
│  WK Jetty ID 1（UM trans_mode + UTP tp_type） │
│  单消息粒度                                    │
├──────────────────────────────────────────────┤
│  ubcore_session (现有)                        │
│  请求-响应配对（CREATE_REQ ↔ CREATE_RESP）    │
│  单次 wait/complete                          │
└──────────────────────────────────────────────┘
```

`ubcore_session` 是"单次请求-响应"的同步原语；`ubmad_wk_session` 是"多步状态机"的连接对象。两者解决不同问题。**本设计不替换或修改 `ubcore_session`**——上层 CREATE_REQ/RESP 流程继续使用它。

### 0.5 关键设计决定速查表

| 决定 | 取值 | 理由 |
|------|------|------|
| 握手消息底层发送 | `ubcore_post_jetty_send_wr` 直接投递，不走 MSN | §0.2 |
| 握手消息复用的 jetty | `jetty_rsrc[0]`（WK Jetty ID 1） | 与 UBCM CONN_REQ 共用，已有完整收发设施 |
| 会话标识 | 双向 `(local_session_id, peer_session_id)`，每端独立从 IDA 分配 16 位 ID（v3.2 修订）| 类比 TCP `(src_port, dst_port)`：发送方填本端 ID 到 local，对端 ID 到 peer；接收方按 peer_session_id（即收方自己的 ID）查找 session。原 v3 单字段设计有协议缺陷（详见 §18.0 之上的 v3.2 修订说明）|
| 重传策略 | 指数退避 `2 << rt_cnt` ms，上限 1000ms，最多 11 次 | 与 UBMAD MSN 上限对齐 |
| TIME_WAIT 时长 | 4000ms | §0.3：与 MSN 最大重传窗口对齐，**不是** TCP 2×MSL |
| listen 数量 | 每设备一个（`dev_priv->listen_session`） | v1 限制；v2 改链表，见 [§18](#18-未决设计问题) |
| Kconfig | `CONFIG_UBMAD_WK_SESSION`（默认 n） | 可选特性，见 [Step 11](#step-11kconfig-特性开关) |

### 0.6 阅读建议

- **想理解为什么这么设计**：本节即可。
- **想动手实现**：跳到 [Step 1](#step-1添加握手消息类型枚举) 顺序读到 [Step 11](#step-11kconfig-特性开关)。
- **想了解 WK Jetty 现状**：先读 [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md)（特别是 §4.7 连接模型），再回到本文档。
- **想了解 UBMAD 内部细节**：[`umdk_ubmad_wk_jetty_deep_dive.md`](umdk_ubmad_wk_jetty_deep_dive.md) §13（重传） + §11（接收路径）。

---

## 1. 背景与现有机制

### 1.1 公知 Jetty（Well-Known Jetty）是什么

URMA 为每个设备保留了一段固定 Jetty ID 范围（称为 `public_jetty` 或 `well_known_jetty`）。这段范围内的 ID **两端都提前知道**，无需带外协商。UBMAD 占用了其中两个：

| 资源索引 | Jetty ID | 用途 |
|---------|---------|------|
| `jetty_rsrc[0]` | `1` | UBCM 连接控制消息（CREATE_REQ / CREATE_RESP / SINGLE_REQ） |
| `jetty_rsrc[1]` | `2` | 认证消息（AUTHN_DATA） |

关键定义位置（`ub_mad_priv.h:18-21`）：

```c
#define UBMAD_WK_JETTY_NUM    2
#define UBMAD_WK_JETTY_ID_0   1U   /* jetty_rsrc[0] */
#define UBMAD_WK_JETTY_ID_1   2U   /* jetty_rsrc[1] */
```

### 1.2 现有 UBCM 两消息交换流程

```
Client                          Server
  │──── UBCORE_NET_CREATE_REQ ────▶│   发起方主动发
  │                                │   Server: ubcore_get_tp_list + ubcore_active_tp
  │◀─── UBCORE_NET_CREATE_RESP ────│   Resp 含 tp_handle + tx_psn
  │                                │
  └── ubcore_exchange_tp_info 返回 ┘
```

这是无连接状态的消息交换（类似 UDP），底层靠 UBMAD 自己的 MSN + 重传保障可靠性。

### 1.3 本次需求：新增连接状态管理

在现有两消息基础上，**在 UBMAD 层面增加类 TCP 的三次握手和四次挥手**，让两端维护 `ESTABLISHED` 会话状态，从而支持：
- 连接级别的流量控制
- 有序的连接拆除（四次挥手）
- 上层感知连接生命周期

---

## 2. 整体设计思路

### 2.1 新增消息类型

在 `ub_mad.h` 中新增五种握手消息，复用 `jetty_rsrc[0]`（Jetty ID 1）传输：

```
UBMAD_WK_SYN         = 0x30   连接建立请求
UBMAD_WK_SYN_ACK     = 0x31   连接建立应答
UBMAD_WK_ACK         = 0x32   连接建立确认（第三次握手）
UBMAD_WK_FIN         = 0x40   连接断开请求
UBMAD_WK_FIN_ACK     = 0x41   连接断开确认
```

### 2.2 会话对象

每条握手连接对应一个 `ubmad_wk_session` 对象，维护：
- 状态机当前状态
- 本端 ISN（初始序列号）和对端 ISN
- 重传定时器
- 上层等待队列（`connect()` 调用者阻塞在此）

### 2.3 三次握手流程

```
Client                                      Server
  │  state: CLOSED                            │  state: LISTEN
  │                                           │
  │──[1] UBMAD_WK_SYN (isn=C) ──────────────▶│
  │  state: SYN_SENT                          │  state: SYN_RCVD
  │                                           │
  │◀─[2] UBMAD_WK_SYN_ACK (isn=S, ack=C+1) ──│
  │  取消 SYN 重传定时器                       │
  │                                           │
  │──[3] UBMAD_WK_ACK (ack=S+1) ────────────▶│
  │  state: ESTABLISHED                       │  state: ESTABLISHED
  │  唤醒 ubmad_wk_connect() 调用者            │  唤醒 ubmad_wk_listen() 的 accept 等待
```

### 2.4 四次挥手流程

```
主动关闭方（A）                              被动关闭方（B）
  │  state: ESTABLISHED                       │  state: ESTABLISHED
  │                                           │
  │──[1] UBMAD_WK_FIN ──────────────────────▶│
  │  state: FIN_WAIT_1                        │  state: CLOSE_WAIT
  │                                           │  （上层仍可发送数据）
  │◀─[2] UBMAD_WK_FIN_ACK ──────────────────│
  │  state: FIN_WAIT_2                        │
  │                                           │
  │◀─[3] UBMAD_WK_FIN ──────────────────────│  B 数据发完后发 FIN
  │                                           │  state: LAST_ACK
  │──[4] UBMAD_WK_FIN_ACK ─────────────────▶│
  │  state: TIME_WAIT (等 4s, 见 §0.3)               │  state: CLOSED
  │      ↓
  │  state: CLOSED
```

---

## 3. 状态机定义

```
                  ┌─────────────────────────────────────────────┐
                  │                  状态迁移表                  │
                  └─────────────────────────────────────────────┘

CLOSED ──listen()──▶ LISTEN
CLOSED ──connect()──▶ SYN_SENT ──recv SYN_ACK──▶ ESTABLISHED (发完 ACK)

LISTEN ──recv SYN──▶ SYN_RCVD ──recv ACK──▶ ESTABLISHED

ESTABLISHED ──close()──▶ FIN_WAIT_1 ──recv FIN_ACK──▶ FIN_WAIT_2 ──recv FIN──▶ TIME_WAIT ──4s──▶ CLOSED
ESTABLISHED ──recv FIN──▶ CLOSE_WAIT ──close()──▶ LAST_ACK ──recv FIN_ACK──▶ CLOSED
```

共 **10** 个状态：`CLOSED / LISTEN / SYN_SENT / SYN_RCVD / ESTABLISHED / FIN_WAIT_1 / FIN_WAIT_2 / CLOSE_WAIT / LAST_ACK / TIME_WAIT`

---

## Step 1：添加握手消息类型枚举

### 1.1 目标

在消息类型头文件中注册五种新握手消息，让编译器和 `ubmad_post_send()` 的 switch 语句识别它们。

### 1.2 改动文件

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.h`

### 1.3 现有枚举位置

打开 `ub_mad.h`，找到 `enum ubmad_msg_type` 定义，在 `ub_mad.h:20-30`：

```c
enum ubmad_msg_type {
    UBMAD_CONN_DATA      = 0,                    /* 内部连接数据 */
    UBMAD_CONN_ACK,                              /* 值 1，自动递增 */
    UBMAD_UBC_CONN_REQ   = UBCORE_CM_CONN_REQ,   /* 与 UBCM 消息类型对齐，值 2 */
    UBMAD_UBC_CONN_RESP  = UBCORE_CM_CONN_RESP,  /* 值 3 */
    UBMAD_UBC_SINGLE_REQ = UBCORE_CM_SINGLE_REQ, /* 值 4 */
    UBMAD_AUTHN_DATA     = 0x10,
    UBMAD_AUTHN_ACK,                             /* 值 0x11，自动递增 */
    /* cm send close request to all tjetty before remove kmod, one-way notification */
    UBMAD_CLOSE_REQ      = 0x20,
};
```

> ⚠️ v2 版本曾遗漏 `UBMAD_CONN_DATA / UBMAD_CONN_ACK / UBMAD_AUTHN_ACK` 三项；v3 已补齐。新增的握手消息值 `0x30-0x32, 0x40-0x41` 与现有所有取值都不冲突。

### 1.4 要新增的代码

在 `UBMAD_CLOSE_REQ = 0x20` **之后**追加：

```c
    /* --- 以下为公知 Jetty 可靠连接握手消息 --- */
    UBMAD_WK_SYN         = 0x30,   /* 三次握手：Client → Server，携带 isn */
    UBMAD_WK_SYN_ACK     = 0x31,   /* 三次握手：Server → Client，携带 isn + ack */
    UBMAD_WK_ACK         = 0x32,   /* 三次握手：Client → Server，完成连接 */
    UBMAD_WK_FIN         = 0x40,   /* 四次挥手：主动关闭方发送 FIN */
    UBMAD_WK_FIN_ACK     = 0x41,   /* 四次挥手：对端确认 FIN */
```

修改后完整枚举：

```c
enum ubmad_msg_type {
    UBMAD_UBC_CONN_REQ   = UBCORE_CM_CONN_REQ,
    UBMAD_UBC_CONN_RESP  = UBCORE_CM_CONN_RESP,
    UBMAD_UBC_SINGLE_REQ = UBCORE_CM_SINGLE_REQ,
    UBMAD_AUTHN_DATA     = 0x10,
    UBMAD_CLOSE_REQ      = 0x20,

    /* 公知 Jetty 可靠连接握手消息 */
    UBMAD_WK_SYN         = 0x30,
    UBMAD_WK_SYN_ACK     = 0x31,
    UBMAD_WK_ACK         = 0x32,
    UBMAD_WK_FIN         = 0x40,
    UBMAD_WK_FIN_ACK     = 0x41,
};
```

### 1.5 不修改 `ubmad_post_send()` —— 握手走独立发送路径

> **v3.3 修订**：v3.2 版本曾要求在 `ubmad_post_send()` 的资源选择 switch 里
> 加 `UBMAD_WK_SYN/SYN_ACK/...` 五个 case。这与 §0.2 的核心设计决定矛盾：
> 握手消息**不走 `ubmad_post_send`**，而是经过 §Step 4 的
> `ubmad_post_send_wk()` 直接调 `ubcore_post_jetty_send_wr()`。
>
> 即使把这五个 case 加到资源选择 switch（`ubmad_datapath.c:795-807`），
> 调用链下游的 `ubmad_do_post_send()` 内部还有第二个 switch
> （`ubmad_datapath.c:702-718`），只识别 `UBMAD_UBC_CONN_REQ/CONN_RESP/SINGLE_REQ`
> 三种类型，遇到 WK_* 会走 `default` 分支并 `return -EINVAL`。
>
> 所以 v3.3 删除原 §1.5。Step 1 只剩"在 `ub_mad.h` 加 WK_* 枚举值"这一步。
> 握手消息的真正发送在 [Step 4](#step-4实现握手发送侧函数) 实现。

`jetty_rsrc[0]`（WK Jetty ID 1）的接收侧本来就已经预投递了 WQE 并绑定了
JFC/JFR/JFS，所以 `ubmad_post_send_wk()` 直接以 `rsrc = &dev_priv->jetty_rsrc[0]`
作为发送资源，无需任何配置。

### 1.6 验证方法

```bash
# 在内核源码目录下编译，确保枚举无重复值、无编译警告
make -C /path/to/kernel M=drivers/ub/urma/ubcore 2>&1 | grep -E "error:|warning:"
```

预期：无任何 error 或 warning。

---

## Step 2：定义会话状态与核心数据结构

### 2.1 目标

新建头文件 `ubmad_session.h`，集中定义所有会话相关的枚举、结构体和函数声明，使各源文件可以包含此头文件而不产生循环依赖。

### 2.2 新建文件路径

`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_session.h`

### 2.3 完整头文件内容

```c
/* SPDX-License-Identifier: GPL-2.0 */
#ifndef UBMAD_SESSION_H
#define UBMAD_SESSION_H

#include <linux/types.h>
#include <linux/spinlock.h>
#include <linux/workqueue.h>
#include <linux/completion.h>
#include <linux/hashtable.h>
#include <linux/kref.h>
#include "ub_mad_priv.h"   /* ubmad_device_priv, ubmad_jetty_resource */
#include "ub_mad.h"        /* ubmad_msg_type */

/* ============================================================
 * 会话状态枚举
 * 名称与 TCP RFC 793 对齐，方便查阅 TCP 规范类比理解
 * ============================================================ */
enum ubmad_wk_session_state {
    UBMAD_WK_CLOSED      = 0,   /* 初始/最终状态，无活跃连接 */
    UBMAD_WK_LISTEN      = 1,   /* 服务端已注册监听，等待 SYN */
    UBMAD_WK_SYN_SENT    = 2,   /* 客户端已发 SYN，等待 SYN_ACK */
    UBMAD_WK_SYN_RCVD    = 3,   /* 服务端已收 SYN、已发 SYN_ACK，等待 ACK */
    UBMAD_WK_ESTABLISHED = 4,   /* 连接已建立，双方可通信 */
    UBMAD_WK_FIN_WAIT_1  = 5,   /* 主动关闭方已发 FIN，等待 FIN_ACK */
    UBMAD_WK_FIN_WAIT_2  = 6,   /* 主动关闭方已收 FIN_ACK，等待对端 FIN */
    UBMAD_WK_CLOSE_WAIT  = 7,   /* 被动关闭方已收 FIN 并发了 ACK，等上层调用 close() */
    UBMAD_WK_LAST_ACK    = 8,   /* 被动关闭方已发 FIN，等最终 FIN_ACK */
    UBMAD_WK_TIME_WAIT   = 9,   /* 主动关闭方等待 MSN-window 后归还资源 */
};

/* ============================================================
 * 握手消息头
 * 内嵌在 ubmad_msg.payload[] 最开始处
 *
 * v3.2 修订：原 single session_id 设计有协议缺陷——服务端处理 SYN 时会
 * 分配新的 session_id 并放入 SYN_ACK，但客户端会按自己分配的 ID 查找
 * session 对象，对不上，握手永远完不成。
 *
 * v3.2 改用 (local_session_id, peer_session_id) 双 ID 携带——类比 TCP
 * 报文头中的 (source_port, dest_port)：
 *   - 发送方填 local_session_id = 自己的 session_id
 *   - 发送方填 peer_session_id = 已知的对端 session_id（初始 SYN 时为 0）
 *   - 接收方按 peer_session_id（即收方自己的 session_id）查找 session
 * 详细推导见 §0.5「会话 ID 协议」。
 * ============================================================ */
struct ubmad_wk_hdr {
    uint32_t  isn;               /* Initial Sequence Number（本端） */
    uint32_t  ack;               /* 对端 ISN + 1（ACK / FIN_ACK 中使用） */
    uint16_t  local_session_id;  /* 发送方自己的 session_id */
    uint16_t  peer_session_id;   /* 发送方已知的接收方 session_id；
                                    初始 SYN 时为 0（尚不知道对方 ID） */
    uint8_t   flags;             /* 预留扩展标志位 */
    uint8_t   reserved[3];
} __packed;

/* session_id 的哈希表桶数（2 的幂） */
#define UBMAD_WK_SESSION_HASH_BITS  8
#define UBMAD_WK_SESSION_HASH_SIZE  (1U << UBMAD_WK_SESSION_HASH_BITS)

/* 重传最大次数，参考现有 ubcore_max_retry_cnt 默认值 11 */
#define UBMAD_WK_MAX_RETRY          11

/* TIME_WAIT 等待时长（毫秒）= UBMAD MSN 最大重传窗口
 * MSN 重传以 1<<rt_cnt ms 指数退避，最多 ubcore_max_retry_cnt(=11) 次。
 * 累计 = 2^0 + 2^1 + ... + 2^11 = 2^12 - 1 = 4095 ms ≈ 4 s。
 * 取 4000ms 保证 TIME_WAIT 期间对端 MSN 触发的延迟重传都已结束。
 * 详细推导见 §0.3。注意这不是 TCP 风格的 2×MSL（TCP 通常 60-120s）。
 */
#define UBMAD_WK_TIME_WAIT_MS       4000

/* FIN_WAIT_2 等待时长（毫秒）。v3.7 新增。
 * 主动关闭方收到 FIN_ACK 之后等对端发自己的 FIN。如果对端永远不发
 * （进程死、对端节点崩溃、对端代码 bug），不能让 session 永驻 FIN_WAIT_2。
 * 借鉴 Linux 内核 net.ipv4.tcp_fin_timeout，默认 60s；这里取 30s 折中
 * （同步关闭场景大多在几十毫秒内完成；30s 留出足够余量给跨节点慢路径）。
 * 这个超时同时是 FIN_WAIT_2 期间唯一的 session 持有者，详见 §6.4 / §7.3。
 */
#define UBMAD_WK_FIN_WAIT_2_MS      30000

/* ============================================================
 * 核心会话对象
 * 每条公知 Jetty 可靠连接对应一个此对象
 * ============================================================ */
struct ubmad_wk_session {
    /* 哈希链表节点，挂入 ubmad_device_priv.session_hash */
    struct hlist_node       hash_node;

    /* 生命周期引用计数 */
    struct kref             kref;

    /* 本次连接本端的唯一标识（分配时从 ida 取得） */
    uint16_t                session_id;

    /* 对端的 session_id（v3.2 新增）。
     * 客户端：在 SYN_ACK 处理中从 wk_hdr->local_session_id 学到。
     * 服务端：在 SYN 处理中从 wk_hdr->local_session_id 学到。
     * 0 表示尚未学到（仅 SYN_SENT 早期状态）。 */
    uint16_t                remote_session_id;

    /* 当前状态机状态 */
    enum ubmad_wk_session_state state;

    /* 保护 state 字段的自旋锁（状态迁移必须在此锁下进行） */
    spinlock_t              lock;

    /* 本端初始序列号（由 ubmad_gen_isn() 生成） */
    uint32_t                local_isn;

    /* 对端初始序列号（收到 SYN / SYN_ACK 后填入） */
    uint32_t                remote_isn;

    /* v3.3：FIN 序列号（TCP 风格，FIN 也消耗一个 seq）。
     * 在 ubmad_wk_close() 首次发 FIN 时设为 local_isn+1，重传时保持不变，
     * 保证 FIN_ACK 的 ack 验证有稳定参照。0 表示尚未发出 FIN。 */
    uint32_t                local_fin_seq;
    uint32_t                remote_fin_seq;

    /* 对端 EID（用于查找远端 tjetty 和发送回包） */
    union ubcore_eid        remote_eid;

    /* 本端所用的 WK 资源（始终为 jetty_rsrc[0]） */
    struct ubmad_jetty_resource   *rsrc;

    /* 对端 WK tjetty（从 rsrc->tjetty_hlist 查找得到） */
    struct ubmad_tjetty           *remote_tjetty;

    /* SYN / SYN_ACK 重传定时器 */
    struct delayed_work     rt_work;
    struct workqueue_struct *rt_wq;   /* 复用 dev_priv->rt_wq */
    int                     rt_cnt;   /* 当前已重传次数 */

    /* TIME_WAIT 定时器 */
    struct delayed_work     tw_work;

    /* connect() 调用者阻塞等待连接完成 */
    struct completion       connected;

    /* listen/accept 等待队列（服务端场景） */
    struct completion       accepted;

    /* 上层回调：连接建立 / 断开事件通知 */
    void  (*on_established)(struct ubmad_wk_session *session, void *ctx);
    void  (*on_closed)(struct ubmad_wk_session *session, int reason, void *ctx);
    void  *cb_ctx;

    /* 所属 device priv，用于在回调中访问全局状态 */
    struct ubmad_device_priv      *dev_priv;

    /* 返回码：0 表示成功，非 0 表示握手失败原因 */
    int                     result;
};

/* ============================================================
 * 函数声明（实现在 ubmad_session.c）
 * ============================================================ */

/**
 * ubmad_session_init_global - 初始化全局会话哈希表和 ID 分配器
 * 必须在 ubmad_init() 中调用一次。
 */
int  ubmad_session_init_global(void);

/**
 * ubmad_session_cleanup_global - 清理全局会话资源
 * 必须在 ubmad_uninit() 中调用。
 */
void ubmad_session_cleanup_global(void);

/**
 * ubmad_alloc_session - 分配并初始化一个新 session 对象
 * @dev_priv: 设备私有对象
 * @remote_eid: 对端 EID
 *
 * 成功返回 session 指针（引用计数=1），失败返回 ERR_PTR(-ENOMEM)。
 * 调用者在使用完毕后需调用 ubmad_put_session()。
 */
struct ubmad_wk_session *ubmad_alloc_session(
        struct ubmad_device_priv *dev_priv,
        const union ubcore_eid *remote_eid);

/**
 * ubmad_release_session - 最终释放 session 资源（kref 归零时被调用）
 * 不要直接调用此函数，使用 ubmad_put_session() 代替。
 */
void ubmad_release_session(struct kref *kref);

/**
 * ubmad_put_session - 减少 session 引用计数，归零时自动释放
 */
static inline void ubmad_put_session(struct ubmad_wk_session *s)
{
    kref_put(&s->kref, ubmad_release_session);
}

/**
 * ubmad_get_session - 增加 session 引用计数
 */
static inline void ubmad_get_session(struct ubmad_wk_session *s)
{
    kref_get(&s->kref);
}

/**
 * ubmad_session_find_by_id - 通过 session_id 在哈希表中查找 session
 * @dev_priv: 设备私有对象
 * @session_id: 目标会话 ID
 *
 * 找到则返回 session（引用计数 +1），未找到返回 NULL。
 * 调用者负责调用 ubmad_put_session() 释放引用。
 */
struct ubmad_wk_session *ubmad_session_find_by_id(
        struct ubmad_device_priv *dev_priv,
        uint16_t session_id);

/**
 * ubmad_gen_isn - 生成随机初始序列号
 *
 * 使用 get_random_u32() 生成，防止序列号预测攻击。
 * 返回 32 位随机值，但不得为 0（0 留作特殊标记）。
 */
uint32_t ubmad_gen_isn(void);

#endif /* UBMAD_SESSION_H */
```

### 2.4 数据结构字段解读（给新开发者）

| 字段 | 类型 | 用途说明 |
|------|------|---------|
| `hash_node` | `hlist_node` | 挂入 `dev_priv->session_hash[]` 哈希桶 |
| `kref` | `kref` | 防止并发释放；`kref_put` 归零时自动调用 `ubmad_release_session` |
| `session_id` | `uint16_t` | 握手消息头中携带，接收方用来找到对应 session |
| `state` | enum | 当前状态机状态；所有迁移必须在 `lock` 下进行 |
| `lock` | `spinlock_t` | 保护 `state` 字段，避免并发的定时器 / 接收回调同时修改状态 |
| `local_isn` / `remote_isn` | `uint32_t` | 类比 TCP 的 ISN，用于防重放和有序确认 |
| `rt_work` | `delayed_work` | SYN 或 SYN_ACK 重传工作，入队到 `rt_wq`（复用 dev_priv->rt_wq） |
| `rt_cnt` | `int` | 已重传次数，超过 `UBMAD_WK_MAX_RETRY` 则放弃 |
| `tw_work` | `delayed_work` | TIME_WAIT 定时器，到期后释放 session |
| `connected` | `completion` | `ubmad_wk_connect()` 调用者在此等待，收到 SYN_ACK + 发出 ACK 后由接收处理路径 `complete()` |
| `accepted` | `completion` | 服务端 accept 调用者在此等待，收到 ACK（进入 ESTABLISHED）后 `complete()` |
| `on_established` / `on_closed` | 函数指针 | 上层注册的生命周期回调，可选 |

### 2.5 验证方法

只需确认头文件语法无误：

```bash
# 只编译头文件（利用 gcc 预处理检查语法）
gcc -fsyntax-only -Iinclude \
    -include kernel/drivers/ub/urma/ubcore/ubcm/ubmad_session.h \
    /dev/null
```

---

## Step 3：实现会话管理函数

### 3.1 目标

新建 `ubmad_session.c`，实现 Step 2 头文件中声明的所有函数。

### 3.2 新建文件路径

`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_session.c`

### 3.3 全局状态

在文件开头定义全局哈希表和 ID 分配器：

```c
/* SPDX-License-Identifier: GPL-2.0 */
#include <linux/slab.h>
#include <linux/random.h>
#include <linux/idr.h>
#include <linux/spinlock.h>
#include "ubmad_session.h"

/*
 * 全局会话哈希表：用 session_id 作键，快速定位 session 对象
 * DEFINE_HASHTABLE 展开为 struct hlist_head g_session_hash[256]
 */
static DEFINE_HASHTABLE(g_session_hash, UBMAD_WK_SESSION_HASH_BITS);
static DEFINE_SPINLOCK(g_session_hash_lock);

/*
 * session_id 分配器：从 [1, 65535] 范围内分配唯一 ID
 * 使用内核 IDA（ID Allocator），线程安全
 */
static DEFINE_IDA(g_session_ida);
```

### 3.4 函数一：`ubmad_session_init_global()`

```c
/**
 * ubmad_session_init_global - 初始化全局哈希表和 IDA
 *
 * 在模块加载时（ubmad_init）调用一次。
 * hash_init() 是宏，展开为把每个桶初始化为空链表。
 * ida_init() 初始化 ID 分配器内部的 radix tree。
 */
int ubmad_session_init_global(void)
{
    hash_init(g_session_hash);
    ida_init(&g_session_ida);
    return 0;
}
```

### 3.5 函数二：`ubmad_session_cleanup_global()`

```c
/**
 * ubmad_session_cleanup_global - 释放 IDA
 *
 * 调用 ida_destroy() 回收 IDA 内部内存。
 * 注意：调用此函数前应确保所有 session 已经释放（ubmad_uninit 时设备已被移除）。
 */
void ubmad_session_cleanup_global(void)
{
    ida_destroy(&g_session_ida);
}
```

### 3.6 函数三：`ubmad_gen_isn()`

```c
/**
 * ubmad_gen_isn - 生成随机 ISN
 *
 * 不能返回 0，因为 ack=0 在握手消息中用作"无确认"标记。
 * 循环直到得到非零值（概率极低多于一次）。
 */
uint32_t ubmad_gen_isn(void)
{
    uint32_t isn;

    do {
        isn = get_random_u32();
    } while (isn == 0);

    return isn;
}
```

### 3.7 函数四：`ubmad_alloc_session()`

```c
/**
 * ubmad_alloc_session - 分配新 session 并插入全局哈希表
 *
 * @dev_priv:   所属设备私有对象
 * @remote_eid: 对端 EID，用于后续发包时查找 tjetty
 *
 * 流程：
 *   1. IDA 分配唯一 session_id
 *   2. kzalloc 分配 session 对象
 *   3. 初始化所有字段
 *   4. 在 g_session_hash_lock 下插入哈希表
 *   5. 返回 session 指针（引用计数=1）
 *
 * 失败时返回 ERR_PTR(-ENOMEM) 或 ERR_PTR(-ENOSPC)。
 */
struct ubmad_wk_session *ubmad_alloc_session(
        struct ubmad_device_priv *dev_priv,
        const union ubcore_eid *remote_eid)
{
    struct ubmad_wk_session *session;
    int id;

    /* 步骤 1：分配 session_id（范围 1..65535） */
    id = ida_alloc_range(&g_session_ida, 1, U16_MAX, GFP_KERNEL);
    if (id < 0)
        return ERR_PTR(id);

    /* 步骤 2：分配 session 对象（零初始化） */
    session = kzalloc(sizeof(*session), GFP_KERNEL);
    if (!session) {
        ida_free(&g_session_ida, id);
        return ERR_PTR(-ENOMEM);
    }

    /* 步骤 3：初始化字段 */
    session->session_id  = (uint16_t)id;
    session->remote_session_id = 0;     /* 握手中再学习；v3.2 新增 */
    session->state       = UBMAD_WK_CLOSED;
    session->dev_priv    = dev_priv;
    /* v3.2 修订：LISTEN session 不绑定特定对端，remote_eid 允许 NULL。
     * 原 v3 写法 session->remote_eid = *remote_eid 在 ubmad_wk_listen()
     * 调用 ubmad_alloc_session(dev_priv, NULL) 时会 NULL 解引用。 */
    if (remote_eid)
        session->remote_eid = *remote_eid;
    else
        memset(&session->remote_eid, 0, sizeof(session->remote_eid));
    session->rt_wq       = dev_priv->rt_wq;   /* 复用设备级重传队列 */

    kref_init(&session->kref);                /* 引用计数初始化为 1 */
    spin_lock_init(&session->lock);
    init_completion(&session->connected);
    init_completion(&session->accepted);
    INIT_DELAYED_WORK(&session->rt_work, ubmad_wk_syn_rt_work_handler);
    INIT_DELAYED_WORK(&session->tw_work, ubmad_wk_time_wait_handler);

    /* 步骤 4：插入全局哈希表 */
    spin_lock(&g_session_hash_lock);
    hash_add(g_session_hash, &session->hash_node, session->session_id);
    spin_unlock(&g_session_hash_lock);

    return session;
}
```

**注意**：`ubmad_wk_syn_rt_work_handler` 和 `ubmad_wk_time_wait_handler` 在 Step 7 中实现；这里先做前向声明（在文件顶部 `static void ubmad_wk_syn_rt_work_handler(struct work_struct *work);`）。`ubmad_wk_time_wait_handler` 自 v3.7 起被 TIME_WAIT 和 FIN_WAIT_2 两种状态共用——既是 TIME_WAIT 4s 清理定时器，也是 FIN_WAIT_2 30s "对端永远不发 FIN" 兜底定时器。

### 3.8 函数五：`ubmad_session_find_by_id()`

```c
/**
 * ubmad_session_find_by_id - 通过 session_id 查找 session
 *
 * 在接收路径中调用（中断上下文之外的工作队列中），
 * 持锁期间对找到的 session 做 kref_get_unless_zero，然后释放锁后安全使用。
 *
 * v3.9 修订：用 kref_get_unless_zero 而不是裸 kref_get。原因是哈希表本身
 * 不持有 ref（§7.4 invariant），所以可能出现的竞争是：另一线程持有最后一份
 * ref 并 kref_put → kref 归零 → release_session 排队等本函数释放哈希锁；
 * 而本函数刚好在锁内查到这个 session 并 kref_get——把 0 拉回 1，等于"复活"
 * 了一个正在被释放的对象，最终导致 double-free 或 UAF。
 * kref_get_unless_zero 在 ref==0 时返回 false，本函数据此跳过即可。
 *
 * 返回值：找到且 ref 不为 0 时返回 session（引用计数已 +1），否则返回 NULL。
 */
struct ubmad_wk_session *ubmad_session_find_by_id(
        struct ubmad_device_priv *dev_priv,
        uint16_t session_id)
{
    struct ubmad_wk_session *session;

    spin_lock(&g_session_hash_lock);
    hash_for_each_possible(g_session_hash, session, hash_node, session_id) {
        if (session->session_id == session_id &&
            session->dev_priv   == dev_priv) {
            if (!kref_get_unless_zero(&session->kref))
                continue;       /* session 正在释放，当作未找到 */
            spin_unlock(&g_session_hash_lock);
            return session;
        }
    }
    spin_unlock(&g_session_hash_lock);
    return NULL;
}
```

**为什么额外比较 `dev_priv`？**  
同一台机器上可能有多个 UB 设备，不同设备的 session_id 可能相同（从各自 IDA 独立分配）。加上 `dev_priv` 判断确保不会跨设备误匹配。

### 3.8b 函数五.5：`ubmad_session_find_by_peer()` (v3.3 新增)

服务端处理 SYN 时需要做幂等检查——如果客户端重传 SYN，应该找到之前已经为它建的 session 而不是再建一个。但此时本地还没分配过对应的 session_id，所以不能用 `find_by_id`；得按 `(remote_eid, remote_session_id)` 二元组查找。

```c
/**
 * ubmad_session_find_by_peer - 按 (对端 EID, 对端 session_id) 查找 session
 *
 * 用途：服务端处理 SYN 重传时的幂等检查。客户端的 wk_hdr->local_session_id
 * 是它本地分配的 ID；服务端需要把它当作"已学到的对端 ID"来匹配现有 session
 * （session->remote_session_id 字段）。
 *
 * 性能说明：与 find_by_id 不同，本函数无法用 hash key 直接索引，必须遍历
 * 整张哈希表。但 LISTEN 节点全部连接平均下来一般不多（v1 单 listen），
 * 实际开销有限。如未来支持高并发握手，可加二级索引（按 remote_session_id 哈希）。
 */
struct ubmad_wk_session *ubmad_session_find_by_peer(
        struct ubmad_device_priv *dev_priv,
        const union ubcore_eid *remote_eid,
        uint16_t remote_session_id)
{
    struct ubmad_wk_session *session;
    int bkt;

    spin_lock(&g_session_hash_lock);
    hash_for_each(g_session_hash, bkt, session, hash_node) {
        if (session->dev_priv          != dev_priv)
            continue;
        if (session->remote_session_id != remote_session_id)
            continue;
        if (memcmp(&session->remote_eid, remote_eid,
                   sizeof(*remote_eid)) != 0)
            continue;
        /* v3.9: 同 find_by_id，避免复活正在释放的 session */
        if (!kref_get_unless_zero(&session->kref))
            continue;
        spin_unlock(&g_session_hash_lock);
        return session;
    }
    spin_unlock(&g_session_hash_lock);
    return NULL;
}
```

### 3.9 函数六：`ubmad_release_session()`

```c
/**
 * ubmad_release_session - kref 归零时的最终释放函数
 *
 * 此函数由 kref_put() 在引用计数降为 0 时自动调用。
 * 不要直接调用！
 *
 * 释放流程：
 *   1. 从哈希表移除（防止再被查到）
 *   2. 取消仍在排队的重传 / TIME_WAIT 定时器
 *   3. 释放对 remote_tjetty 的引用
 *   4. 归还 session_id 到 IDA
 *   5. kfree session 对象
 */
void ubmad_release_session(struct kref *kref)
{
    struct ubmad_wk_session *session =
            container_of(kref, struct ubmad_wk_session, kref);

    /* 步骤 1：从哈希表移除 */
    spin_lock(&g_session_hash_lock);
    hash_del(&session->hash_node);
    spin_unlock(&g_session_hash_lock);

    /* 步骤 2：v3.9——绝不在此处 cancel_delayed_work_sync。
     *
     * 原因：本函数可能由 work handler（rt_work 或 tw_work）的最后那次 put
     * 触发——即 handler 的最终 ubmad_put_session 让 kref 归零并直接调到
     * release_session。在 work handler 上下文里 sync-cancel 当前正在执行的
     * 自身 work，会自死锁（cancel_delayed_work_sync 等 handler 完成 → 而
     * handler 正在等本函数返回 → 永久阻塞或触发内核 WARN）。
     *
     * 我们依赖的 invariant：
     *   - 每次 queue_delayed_work 之前都有 kref_get（§7.4）。
     *   - 每个被 cancel 成功（cancel_delayed_work 返回 true）的路径都
     *     立刻补 ubmad_put_session（§7.4 v3.3 补充）。
     *   - 每个 handler 在末尾 ubmad_put_session。
     * 这个 invariant 成立时，kref 归零意味着没有任何 timer 还持有 ref，
     * 也就没有 pending 的 work——cancel_*  调用本来就是无操作。所以
     * 删除掉它，避免在异常路径上被误用为"我是 handler 但忘了"的安全网。
     *
     * 如果担心 invariant 被未来改动破坏，调试期可以用 WARN_ON：
     *   WARN_ON(delayed_work_pending(&session->rt_work));
     *   WARN_ON(delayed_work_pending(&session->tw_work));
     * 而不是用 cancel_*_sync 兜底（兜底会变成上面描述的死锁）。
     */

    /* 步骤 3：释放对端 tjetty 引用（如果已获取） */
    if (session->remote_tjetty)
        ubmad_put_tjetty(session->remote_tjetty);

    /* 步骤 4：归还 session_id */
    ida_free(&g_session_ida, session->session_id);

    /* 步骤 5：释放 session 对象本身 */
    kfree(session);
}
```

### 3.10 验证方法

编译时确认无未定义符号：

```bash
make -C /path/to/kernel M=drivers/ub/urma/ubcore 2>&1 | grep "undefined reference"
```

运行时验证（插入 debug 打印，在 `ubmad_alloc_session` 末尾）：

```c
pr_debug("ubmad: alloc session id=%u remote_eid=%pI6\n",
         session->session_id, session->remote_eid.raw);
```

然后通过 `dmesg | grep "ubmad: alloc session"` 确认分配成功。

---

## Step 4：实现握手发送侧函数

### 4.1 目标

实现客户端发起三次握手的 `ubmad_wk_connect()`，服务端注册监听的 `ubmad_wk_listen()`，以及底层发包辅助函数 `ubmad_post_send_wk()`。

### 4.2 文件位置

在 `ubmad_datapath.c` 末尾新增（或新建 `ubmad_wk_conn.c`，本文选择直接加到 `ubmad_datapath.c` 以减少文件数量）。

### 4.3 函数一：`ubmad_post_send_wk()`

**功能**：封装握手消息，通过 `jetty_rsrc[0]` 发出。这是所有握手消息的底层发送入口。

```c
/**
 * ubmad_post_send_wk - 发送一条公知 Jetty 握手消息
 *
 * @dev_priv:    设备私有对象
 * @session:     当前会话（提供 remote_eid、session_id、remote_session_id 等）
 * @msg_type:    要发送的握手消息类型（SYN / SYN_ACK / ACK / FIN / FIN_ACK）
 * @isn:         本端 ISN（SYN/SYN_ACK 填 local_isn；FIN 填 local_isn+1）
 * @ack:         确认号（SYN_ACK/ACK 填 remote_isn+1；FIN_ACK 填 remote_fin_seq+1；SYN/FIN 填 0）
 *
 * v3.3 修订要点：
 *   - 删除了 v3.2 引入的虚构 helper（ubmad_alloc_sge / ubmad_free_sge /
 *     ubmad_queue_import_work）。这些函数在内核里不存在，会编译失败。
 *     改用真实存在的底层 API：ubmad_bitmap_get_id / ubmad_bitmap_put_id
 *     （已在 ubmad_datapath.c:248,294,339,378 等多处使用）以及
 *     atomic_fetch_add(&rsrc->tx_in_queue) 计数（同文件 :276-278,361-363 等）。
 *   - 增加 tx_in_queue 累加/回退（v3.2 漏掉这个；ubmad_datapath.c:1230 的
 *     完成处理会无条件做 atomic_fetch_sub，缺增反减会让计数变负）。
 *   - tjetty cache miss 处理：直接返回 -EAGAIN，**调用方** ubmad_wk_connect()
 *     等先调用现有 ubmad_post_send（任意一条 CONN_DATA 占位）触发导入，再用
 *     会话级 rt_work 重试。这条 v3.3 选择不引入新 helper，把触发导入的责任
 *     上移到调用方；后续如确实需要专用入口可在 ub_mad.c 新增
 *     ubmad_kick_import(dev_priv, eid)，但本文档不再假设它已存在。
 *
 * 不复用 ubmad_post_send()：握手层有自己的会话级重传，叠加 MSN 重传会冲突
 * （详见 §0.2）。但具体的 SGE 取用、tx 计数、WR 构造完全 mirror
 * ubmad_datapath.c:240-300 的模式，不重新发明轮子。
 *
 * 返回 0 表示成功，-EAGAIN 表示 tjetty 未就绪（调用方应触发导入并重试），
 * 其他负数表示永久错误。
 */
static int ubmad_post_send_wk(struct ubmad_device_priv *dev_priv,
                               struct ubmad_wk_session *session,
                               enum ubmad_msg_type msg_type,
                               uint32_t isn, uint32_t ack)
{
    struct ubmad_jetty_resource *rsrc = &dev_priv->jetty_rsrc[0];
    struct ubmad_tjetty *tjetty;
    struct ubmad_msg *msg;
    struct ubmad_wk_hdr *wk_hdr;
    struct ubcore_jfs_wr jfs_wr = {};
    struct ubcore_jfs_wr *bad_wr;
    struct ubcore_sge sge;
    uint64_t sge_addr;          /* v3.4: uint64_t to mirror datapath.c:241 pattern */
    uint32_t sge_idx;
    int ret;

    /* 步骤 1：纯缓存查 tjetty。
     * v3.3：cache miss 不在此处触发导入——返回 -EAGAIN 由调用方重试。 */
    tjetty = ubmad_get_tjetty(&session->remote_eid, rsrc);
    if (!tjetty) {
        pr_debug("ubmad_wk: tjetty not cached for eid=%pI6, retry later\n",
                 session->remote_eid.raw);
        return -EAGAIN;
    }

    /* 步骤 2：从 send_seg_bitmap 分配 SGE 槽位（mirror ubmad_datapath.c:248） */
    sge_idx = ubmad_bitmap_get_id(rsrc->send_seg_bitmap);
    if (sge_idx >= rsrc->send_seg_bitmap->size) {
        ubmad_put_tjetty(tjetty);
        return -EBUSY;
    }
    sge_addr = rsrc->send_seg->seg.ubva.va + UBMAD_SGE_MAX_LEN * sge_idx;
    /* sge_addr is uint64_t; cast to pointer when accessing as struct memory below */

    /* 步骤 3：tx 计数（mirror ubmad_datapath.c:276-278）。
     * 必须在 post 之前 inc，因为 post 完成时 ubmad_jfce_handler_s 会 dec。 */
    if (atomic_fetch_add(1, &rsrc->tx_in_queue) >= UBMAD_TX_THREDSHOLD) {
        atomic_fetch_sub(1, &rsrc->tx_in_queue);
        (void)ubmad_bitmap_put_id(rsrc->send_seg_bitmap, sge_idx);
        ubmad_put_tjetty(tjetty);
        return -EBUSY;
    }

    /* 步骤 4：构造 ubmad_msg 头 + ubmad_wk_hdr */
    msg = (struct ubmad_msg *)(uintptr_t)sge_addr;   /* uint64_t → pointer */
    msg->version     = UBMAD_MSG_VERSION_0;
    msg->msg_type    = msg_type;
    msg->msn         = session->session_id;   /* 借用 msn 字段做日志关联 */
    msg->payload_len = sizeof(struct ubmad_wk_hdr);
    msg->reserved    = 0;

    wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    wk_hdr->isn               = isn;
    wk_hdr->ack               = ack;
    wk_hdr->local_session_id  = session->session_id;
    wk_hdr->peer_session_id   = session->remote_session_id; /* 0 if SYN */
    wk_hdr->flags             = 0;
    memset(wk_hdr->reserved, 0, sizeof(wk_hdr->reserved));

    /* 步骤 5：构造发送 WR（mirror ubmad_datapath.c:680-700） */
    jfs_wr.opcode                  = UBCORE_OPC_SEND;
    jfs_wr.tjetty                  = tjetty->tjetty;
    jfs_wr.user_ctx                = sge_addr;       /* uint64_t — no cast needed */
    jfs_wr.flag.bs.complete_enable = 1;

    sge.addr                = sge_addr;              /* same */
    sge.len                 = sizeof(*msg) + msg->payload_len;
    sge.tseg                = rsrc->send_seg;
    jfs_wr.send.src.sge     = &sge;
    jfs_wr.send.src.num_sge = 1;

    /* 步骤 6：投递到硬件发送队列 */
    ret = ubcore_post_jetty_send_wr(rsrc->jetty, &jfs_wr, &bad_wr);
    if (ret) {
        atomic_fetch_sub(1, &rsrc->tx_in_queue);
        (void)ubmad_bitmap_put_id(rsrc->send_seg_bitmap, sge_idx);
        pr_err("ubmad_wk: post send failed type=%d ret=%d\n", msg_type, ret);
    }

    ubmad_put_tjetty(tjetty);
    return ret;
}
```

### 4.4 函数二：`ubmad_wk_connect()`

**功能**：客户端调用，发送 SYN 并阻塞等待连接完成（超时 5 秒）。

```c
/**
 * ubmad_wk_connect - 客户端发起三次握手
 *
 * @dev_priv:    设备私有对象
 * @remote_eid:  对端 EID（服务端地址）
 * @on_established: 连接建立后的回调（可为 NULL，此时函数同步等待返回）
 * @on_closed:   连接断开时的回调（可为 NULL）
 * @cb_ctx:      传递给回调的上下文指针
 *
 * v3.5 修订：返回类型改为 struct ubmad_wk_session *。
 *   - 成功：返回 session 指针；**调用方持有一个 ref**，必须最终调用
 *     ubmad_wk_close(session) 推进到关闭流程。
 *   - 失败：返回 ERR_PTR(-errno)（用 IS_ERR / PTR_ERR 检查）。
 *
 * v3.5 修订：tjetty 是同步导入的（不论同步还是异步模式都会阻塞约 ~10ms 量级）。
 *   - 同步模式（on_established == NULL）：还会再阻塞最多 5 秒等待握手 ACK。
 *   - 异步模式（on_established != NULL）：tjetty 导入后立即返回 session 指针；
 *     握手完成时调 on_established，失败时调 on_closed。
 *   - 如果调用方完全不能接受 import 阻塞，应在 connect 之前用其他方式预热
 *     tjetty 缓存（例如发一条 CONN_DATA），此处不再涉及。
 *
 * 三次握手流程：
 *   1. 分配 session（状态: CLOSED）
 *   2. **同步导入对端 tjetty**（v3.4 新增；保证后续 post_send_wk 不返回 -EAGAIN）
 *   3. 生成 local_isn
 *   4. 迁移状态到 SYN_SENT
 *   5. 发送 UBMAD_WK_SYN 消息
 *   6. 启动 SYN 重传定时器
 *   7. 同步模式：等待 connected completion；异步模式：立即返回
 */
struct ubmad_wk_session *ubmad_wk_connect(
                     struct ubmad_device_priv *dev_priv,
                     const union ubcore_eid *remote_eid,
                     void (*on_established)(struct ubmad_wk_session *, void *),
                     void (*on_closed)(struct ubmad_wk_session *, int, void *),
                     void *cb_ctx)
{
    struct ubmad_jetty_resource *rsrc = &dev_priv->jetty_rsrc[0];
    struct ubmad_wk_session *session;
    struct ubmad_tjetty *tjetty;
    unsigned long timeout;
    int ret;

    /* 步骤 1：分配 session */
    session = ubmad_alloc_session(dev_priv, remote_eid);
    if (IS_ERR(session))
        return ERR_CAST(session);   /* v3.5: 返回类型已是指针 */

    /* 步骤 2（v3.4 新增）：同步导入对端 WK tjetty。
     * 详见函数注释关于 sleepable / aborbing import 阻塞的说明。 */
    tjetty = ubmad_import_jetty(dev_priv->device, rsrc,
                                 (union ubcore_eid *)remote_eid);
    if (IS_ERR_OR_NULL(tjetty)) {
        pr_err("ubmad_wk: import tjetty failed for connect, eid=%pI6\n",
               remote_eid->raw);
        ret = tjetty ? PTR_ERR(tjetty) : -EHOSTUNREACH;
        ubmad_put_session(session);
        return ERR_PTR(ret);
    }
    ubmad_put_tjetty(tjetty);   /* import 已把 tjetty 放进缓存；丢掉本地引用 */

    /* 步骤 3：注册回调 */
    session->on_established = on_established;
    session->on_closed      = on_closed;
    session->cb_ctx         = cb_ctx;

    /* 步骤 4：生成 local_isn */
    session->local_isn = ubmad_gen_isn();

    /* 步骤 5：迁移状态到 SYN_SENT */
    spin_lock(&session->lock);
    session->state = UBMAD_WK_SYN_SENT;
    spin_unlock(&session->lock);

    /* 步骤 6：发送 SYN
     *  isn = local_isn，ack = 0（无确认）
     *  v3.4：tjetty 已在步骤 2 同步导入，此处不应再返回 -EAGAIN。
     *  仍然容许 -EAGAIN 走到 rt_work 重试路径（防止 tjetty 在并发场景被驱逐）。 */
    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_SYN, session->local_isn, 0);
    if (ret && ret != -EAGAIN) {
        ubmad_put_session(session);
        return ERR_PTR(ret);
    }

    /* 步骤 7：启动 SYN 重传定时器（2ms，指数退避，详见 Step 7）
     * v3.2：必须先 kref_get（见 §7.4），定时器路径才能在末尾 put 释放。
     * 如果上一步首发因 -EAGAIN 没成功，rt_work 会很快接手重试。 */
    session->rt_cnt = 0;
    kref_get(&session->kref);
    queue_delayed_work(session->rt_wq, &session->rt_work,
                       msecs_to_jiffies(2));

    /* 步骤 8：同步等待 */
    if (!on_established) {
        timeout = wait_for_completion_timeout(&session->connected,
                                              msecs_to_jiffies(5000));
        if (!timeout) {
            /* 超时：取消重传，关闭 session
             * v3.4：cancel_delayed_work_sync 在 work 还没跑就被取消的情况下
             * 不会执行 handler 的 kref_put——这里需要用「先 cancel(非 sync) 看
             * 是否 pending、pending 就补 put、否则 flush」的模式（详见 §7.4）。 */
            if (cancel_delayed_work(&session->rt_work)) {
                /* work 还在队列里，handler 不会跑，timer 持有的 ref 由我们补释 */
                ubmad_put_session(session);
            } else {
                /* 已经在跑或已跑完；等它结束以保证 handler 的 put 已执行 */
                flush_delayed_work(&session->rt_work);
            }
            spin_lock(&session->lock);
            session->state = UBMAD_WK_CLOSED;
            spin_unlock(&session->lock);
            ubmad_put_session(session);
            return ERR_PTR(-ETIMEDOUT);
        }
        ret = session->result;
        if (ret) {
            /* 握手层报告失败（如重传超限）。释放 session，返回错误。 */
            ubmad_put_session(session);
            return ERR_PTR(ret);
        }
        /* v3.5：握手成功——把 session 指针交给调用方持有的那一份 ref。
         * 不再 ubmad_put_session（v3.4 的 bug：put 会让 kref 跌到 0、free
         * session，调用方拿到的是悬空指针）。调用方未来调 ubmad_wk_close
         * 推进到 CLOSED 时再 put。 */
        return session;
    }

    /* 异步模式：调用方持有这个 session 指针的 ref；
     * 握手完成时回调 on_established(session, ctx)，
     * 失败时回调 on_closed(session, -errno, ctx)。
     * 调用方完成业务后必须调 ubmad_wk_close 释放。 */
    return session;
}
EXPORT_SYMBOL_GPL(ubmad_wk_connect);
```

### 4.5 函数三：`ubmad_wk_listen()`

**功能**：服务端调用，注册监听（将 session 置为 LISTEN 状态）。

```c
/**
 * ubmad_wk_listen - 服务端注册监听
 *
 * @dev_priv:  设备私有对象
 * @on_established: 每当新连接建立时的回调（不可为 NULL）
 * @on_closed: 连接断开时的回调（可为 NULL）
 * @cb_ctx:    传递给回调的上下文
 *
 * 原理：
 *   - 分配一个"监听 session"，状态置为 LISTEN
 *   - 将此 session 存到 dev_priv->listen_session（需在 ubmad_device_priv 中新增此字段）
 *   - 当 ubmad_process_wk_syn() 收到 SYN 时，查询 listen_session 并据此创建连接
 *
 * 返回 0 表示注册成功，负数表示失败（如已有监听）。
 *
 * 注意：每个设备只支持一个并发监听。
 * 如需多路监听，可将 listen_session 改为链表。
 */
int ubmad_wk_listen(struct ubmad_device_priv *dev_priv,
                    void (*on_established)(struct ubmad_wk_session *, void *),
                    void (*on_closed)(struct ubmad_wk_session *, int, void *),
                    void *cb_ctx)
{
    struct ubmad_wk_session *session;

    if (dev_priv->listen_session) {
        pr_warn("ubmad_wk: listen already registered for device\n");
        return -EBUSY;
    }

    session = ubmad_alloc_session(dev_priv, NULL /* 监听 session 无特定对端 */);
    if (IS_ERR(session))
        return PTR_ERR(session);

    session->on_established = on_established;
    session->on_closed      = on_closed;
    session->cb_ctx         = cb_ctx;

    spin_lock(&session->lock);
    session->state = UBMAD_WK_LISTEN;
    spin_unlock(&session->lock);

    /* 存储到 dev_priv（需要在 ub_mad_priv.h 中添加此字段，见下方说明） */
    dev_priv->listen_session = session;

    pr_info("ubmad_wk: listen registered on device\n");
    return 0;
}
EXPORT_SYMBOL_GPL(ubmad_wk_listen);
```

**同步修改 `ub_mad_priv.h`**：在 `struct ubmad_device_priv` 定义中新增一个字段：

```c
struct ubmad_device_priv {
    /* ... 现有字段 ... */

    /* 公知 Jetty 可靠连接：服务端监听 session（每设备最多一个） */
    struct ubmad_wk_session *listen_session;
};
```

### 4.6 验证方法

编写简单的内核模块测试（非生产代码，仅验证编译链路）：

```c
/* 测试：验证 connect 在没有对端时超时返回 ERR_PTR(-ETIMEDOUT) */
void test_ubmad_wk_connect_timeout(struct ubmad_device_priv *dev_priv)
{
    union ubcore_eid fake_eid = {};
    struct ubmad_wk_session *session;   /* v3.5 起 connect 返回指针 */

    /* 填入一个不存在的对端 EID */
    memset(fake_eid.raw, 0xFF, sizeof(fake_eid.raw));

    session = ubmad_wk_connect(dev_priv, &fake_eid, NULL, NULL, NULL);
    WARN_ON(!IS_ERR(session) || PTR_ERR(session) != -ETIMEDOUT);
    pr_info("ubmad_wk: connect timeout test %s\n",
            (IS_ERR(session) && PTR_ERR(session) == -ETIMEDOUT) ? "PASS" : "FAIL");
    /* 失败路径上 connect 内部已 put session；此处不需要再清理。 */
}
```

---

## Step 5：接入接收消息分发路径

### 5.1 目标

在现有 `ubmad_process_msg()` 的 `switch (msg_type)` 中新增对五种握手消息的分发，并实现对应的处理函数。

### 5.2 修改文件

`ubmad_datapath.c`

### 5.3 修改点一：`ubmad_process_msg()` 中添加分发

找到 `ubmad_process_msg()` 内的 switch 语句（约 `ubmad_datapath.c:1110-1150`）：

```c
/* 现有代码 */
switch (msg->msg_type) {
case UBMAD_UBC_CONN_REQ:
    ubmad_process_conn_data(cr, rsrc, dev_priv, agent_priv);
    break;
case UBMAD_UBC_CONN_RESP:
    ubmad_process_conn_resp(cr, rsrc, dev_priv, agent_priv);
    break;
/* ... */
}
```

在 `default:` 之前追加：

```c
case UBMAD_WK_SYN:
    ubmad_process_wk_syn(msg, cr, dev_priv);
    break;
case UBMAD_WK_SYN_ACK:
    ubmad_process_wk_syn_ack(msg, cr, dev_priv);
    break;
case UBMAD_WK_ACK:
    ubmad_process_wk_ack(msg, cr, dev_priv);
    break;
case UBMAD_WK_FIN:
    ubmad_process_wk_fin(msg, cr, dev_priv);
    break;
case UBMAD_WK_FIN_ACK:
    ubmad_process_wk_fin_ack(msg, cr, dev_priv);
    break;
```

### 5.4 函数一：`ubmad_process_wk_syn()`

**场景**：服务端收到客户端发来的 SYN 消息。

```c
/**
 * ubmad_process_wk_syn - 服务端处理 SYN，发送 SYN_ACK
 *
 * v3.2 修订要点：
 *   - 不再用 wk_hdr->session_id（已无此字段）。
 *   - 初始 SYN 的 wk_hdr->peer_session_id == 0（客户端不知道服务端 ID）。
 *   - 幂等检查不能按 ID 查（服务端没分配过 ID 给这个 connection），改按
 *     (remote_eid, wk_hdr->local_session_id) 二元组查找。
 *
 * 状态迁移：LISTEN → SYN_RCVD
 */
static void ubmad_process_wk_syn(struct ubmad_msg *msg,
                                  struct ubcore_cr *cr,
                                  struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;
    union ubcore_eid client_eid;
    int ret;

    /* 获取客户端 EID（从接收完成记录中读取） */
    client_eid = cr->remote_id.eid;

    /* 步骤 1：幂等检查——按 (client_eid, client_session_id) 查找。
     * v3.2：不能按 wk_hdr->local_session_id 直接查本地哈希——那是
     * 客户端的 ID，落到本地表大概率不命中（即使命中也是别的连接）。
     * 用专用辅助函数 ubmad_session_find_by_peer() 在哈希表中
     * 按 (remote_eid, remote_session_id) 二元组匹配。 */
    session = ubmad_session_find_by_peer(dev_priv, &client_eid,
                                          wk_hdr->local_session_id);
    if (session) {
        /* 已在 SYN_RCVD 状态，重发 SYN_ACK */
        if (session->state == UBMAD_WK_SYN_RCVD) {
            pr_debug("ubmad_wk: retransmit SYN_ACK for session=%u (peer=%u)\n",
                     session->session_id, session->remote_session_id);
            ubmad_post_send_wk(dev_priv, session,
                                UBMAD_WK_SYN_ACK,
                                session->local_isn,
                                session->remote_isn + 1);
        }
        ubmad_put_session(session);
        return;
    }

    /* 步骤 2：检查 listen_session 是否存在 */
    if (!dev_priv->listen_session ||
        dev_priv->listen_session->state != UBMAD_WK_LISTEN) {
        pr_warn("ubmad_wk: recv SYN but no listener registered\n");
        return;
    }

    /* 步骤 3：为此新连接分配 session */
    session = ubmad_alloc_session(dev_priv, &client_eid);
    if (IS_ERR(session)) {
        pr_err("ubmad_wk: alloc session failed on SYN\n");
        return;
    }

    /* 继承监听 session 的回调 */
    session->on_established = dev_priv->listen_session->on_established;
    session->on_closed      = dev_priv->listen_session->on_closed;
    session->cb_ctx         = dev_priv->listen_session->cb_ctx;

    /* 步骤 4：记录对端信息（v3.2：包括对端的 session_id） */
    session->remote_isn         = wk_hdr->isn;
    session->local_isn          = ubmad_gen_isn();
    session->remote_session_id  = wk_hdr->local_session_id; /* ★ 学到对端 ID */

    /* 步骤 5：状态迁移到 SYN_RCVD */
    spin_lock(&session->lock);
    session->state = UBMAD_WK_SYN_RCVD;
    spin_unlock(&session->lock);

    /* 步骤 6：发送 SYN_ACK
     *   isn = local_isn（本端 ISN）
     *   ack = remote_isn + 1（确认对端的 ISN）
     *   v3.2：post_send_wk 自动从 session->remote_session_id 填 wk_hdr 的
     *   peer_session_id 字段，让客户端能按自己的 ID 查找 session。 */
    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_SYN_ACK,
                              session->local_isn,
                              session->remote_isn + 1);
    if (ret) {
        pr_err("ubmad_wk: send SYN_ACK failed ret=%d\n", ret);
        ubmad_put_session(session);
        return;
    }

    /* 步骤 7：启动 SYN_ACK 重传定时器（2ms，指数退避）
     * v3.2：必须先 kref_get（见 §7.4）；否则 work 执行 put 时会跌破 0。 */
    session->rt_cnt = 0;
    kref_get(&session->kref);
    queue_delayed_work(session->rt_wq, &session->rt_work,
                       msecs_to_jiffies(2));

    /* session 引用计数由哈希表持有，此处不 put */
}
```

### 5.5 函数二：`ubmad_process_wk_syn_ack()`

**场景**：客户端收到服务端的 SYN_ACK，发送 ACK 完成握手。

```c
/**
 * ubmad_process_wk_syn_ack - 客户端处理 SYN_ACK，发送 ACK
 *
 * v3.2 修订要点：
 *   - 按 wk_hdr->peer_session_id（即客户端自己的 session_id）查找 session。
 *     这与 v3 的 wk_hdr->session_id 不同——v3 那里查的是服务端的 ID，
 *     落到客户端的哈希表必然不命中。
 *   - 顺便从 wk_hdr->local_session_id 学到服务端的 session_id，存入
 *     session->remote_session_id 供后续 ACK/FIN/FIN_ACK 使用。
 *
 * 状态迁移：SYN_SENT → ESTABLISHED
 */
static void ubmad_process_wk_syn_ack(struct ubmad_msg *msg,
                                      struct ubcore_cr *cr,
                                      struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;

    /* 步骤 1：按 peer_session_id 查找 session（v3.2：peer 即"接收方自己"） */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->peer_session_id);
    if (!session) {
        pr_warn("ubmad_wk: SYN_ACK for unknown local session=%u (peer says %u)\n",
                wk_hdr->peer_session_id, wk_hdr->local_session_id);
        return;
    }

    spin_lock(&session->lock);

    /* 步骤 2：校验状态。
     * v3.5：ESTABLISHED 也是合法状态——表示对端没收到我们的 ACK，重传了 SYN_ACK。
     * 此时不更改本端状态，但要重发 ACK 帮助对端推进到 ESTABLISHED。 */
    if (session->state == UBMAD_WK_ESTABLISHED) {
        /* 校验是同一会话的重传（remote_isn 必须一致） */
        if (wk_hdr->isn != session->remote_isn ||
            wk_hdr->ack != session->local_isn + 1) {
            spin_unlock(&session->lock);
            pr_warn("ubmad_wk: SYN_ACK retransmit mismatch session=%u\n",
                    session->session_id);
            ubmad_put_session(session);
            return;
        }
        spin_unlock(&session->lock);
        pr_debug("ubmad_wk: re-ACK duplicate SYN_ACK for session=%u\n",
                 session->session_id);
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_ACK,
                            0, session->remote_isn + 1);
        ubmad_put_session(session);
        return;
    }

    if (session->state != UBMAD_WK_SYN_SENT) {
        spin_unlock(&session->lock);
        pr_warn("ubmad_wk: SYN_ACK in wrong state=%d\n", session->state);
        ubmad_put_session(session);
        return;
    }

    /* 步骤 2b：校验确认号（对端的 ack 应等于 local_isn + 1） */
    if (wk_hdr->ack != session->local_isn + 1) {
        spin_unlock(&session->lock);
        pr_warn("ubmad_wk: SYN_ACK ack mismatch expect=%u got=%u\n",
                session->local_isn + 1, wk_hdr->ack);
        ubmad_put_session(session);
        return;
    }

    /* 步骤 3：记录对端 ISN 和对端 session_id（v3.2：必须学到对端 ID） */
    session->remote_isn         = wk_hdr->isn;
    session->remote_session_id  = wk_hdr->local_session_id;  /* ★ */

    /* 步骤 4：取消 SYN 重传定时器 */
    /* v3.3：cancel 成功（work 还在队列里没跑）需要替它把 timer 持有的 ref 释放掉。
     * 否则 SYN_ACK 早到时（rt_work 还没机会执行 put）会泄露一个引用。 */
    if (cancel_delayed_work(&session->rt_work))
        ubmad_put_session(session);

    /* 步骤 5：状态迁移到 ESTABLISHED */
    session->state  = UBMAD_WK_ESTABLISHED;
    session->result = 0;
    spin_unlock(&session->lock);

    /* 步骤 6：发送 ACK（第三次握手）
     *   isn = 0（ACK 消息无需携带 ISN）
     *   ack = remote_isn + 1 */
    ubmad_post_send_wk(dev_priv, session,
                        UBMAD_WK_ACK,
                        0, session->remote_isn + 1);

    /* 步骤 7：通知上层连接建立 */
    if (session->on_established) {
        session->on_established(session, session->cb_ctx);
    } else {
        complete(&session->connected);   /* 唤醒阻塞的 ubmad_wk_connect() */
    }

    ubmad_put_session(session);
}
```

### 5.6 函数三：`ubmad_process_wk_ack()`

**场景**：服务端收到客户端发来的 ACK（第三次握手），连接建立完成。

```c
/**
 * ubmad_process_wk_ack - 服务端处理 ACK，完成三次握手
 *
 * 状态迁移：SYN_RCVD → ESTABLISHED
 */
static void ubmad_process_wk_ack(struct ubmad_msg *msg,
                                  struct ubcore_cr *cr,
                                  struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;

    /* v3.2：按 peer_session_id 查找（即服务端自己的 ID） */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->peer_session_id);
    if (!session)
        return;

    spin_lock(&session->lock);

    if (session->state != UBMAD_WK_SYN_RCVD) {
        spin_unlock(&session->lock);
        ubmad_put_session(session);
        return;
    }

    /* 校验 ACK 确认号 */
    if (wk_hdr->ack != session->local_isn + 1) {
        spin_unlock(&session->lock);
        ubmad_put_session(session);
        return;
    }

    /* 取消 SYN_ACK 重传定时器（v3.3：cancel 成功要释放 timer 持有的 ref） */
    if (cancel_delayed_work(&session->rt_work))
        ubmad_put_session(session);

    /* 状态迁移 */
    session->state = UBMAD_WK_ESTABLISHED;
    spin_unlock(&session->lock);

    /* 通知上层 */
    if (session->on_established)
        session->on_established(session, session->cb_ctx);
    else
        complete(&session->accepted);

    ubmad_put_session(session);
}
```

### 5.7 验证方法

使用 `ftrace` 跟踪函数调用：

```bash
# 开启函数跟踪
echo 'ubmad_process_wk_syn ubmad_process_wk_syn_ack ubmad_process_wk_ack' \
    > /sys/kernel/debug/tracing/set_ftrace_filter
echo function > /sys/kernel/debug/tracing/current_tracer
echo 1 > /sys/kernel/debug/tracing/tracing_on

# 触发握手（在测试程序中调用 ubmad_wk_connect / ubmad_wk_listen）

# 查看调用轨迹
cat /sys/kernel/debug/tracing/trace | grep ubmad_process_wk
```

预期输出（三次握手完成）：

```
ubmad_process_wk_syn      [server side]
ubmad_process_wk_syn_ack  [client side]
ubmad_process_wk_ack      [server side]
```

---

## Step 6：实现四次挥手

### 6.1 修改文件

`ubmad_datapath.c`

### 6.2 函数一：`ubmad_wk_close()`

**功能**：主动发起关闭，适用于主动方（Client 或 Server 均可调用）。

```c
/**
 * ubmad_wk_close - 发起四次挥手（主动或被动关闭通用）
 *
 * @session: 要关闭的会话（来自 ubmad_wk_connect 或 on_established 回调）
 *
 * **v3.6 修订：本函数 consume 调用方持有的那一份 ref**——返回后调用方
 * MUST NOT 再访问 session 指针。后续状态推进、FIN 重传、TIME_WAIT、最终
 * 释放都由内部定时器和接收路径自动完成。
 *
 * 这是 v3.5 留下的所有权歧义的最终解法（v3.5 让 connect 返回指针让调用方
 * 持有 ref，但没说 close 怎么处理这份 ref，造成"调 close 之后还要不要
 * 自己 put 一次"的不确定）。v3.6 选择"close consume"语义，理由：
 *   - 类比 fclose / close(fd)：调用后 fd 不再可用。
 *   - 调用方除了 close 也无法用 session 干别的事（不暴露其它 API）。
 *   - 简化使用：调用方只需 if (!IS_ERR(session = wk_connect(...))) wk_close(session)。
 *
 * 状态合法性：
 *   - ESTABLISHED → FIN_WAIT_1（主动关闭，发自己的 FIN）
 *   - CLOSE_WAIT → LAST_ACK（被动关闭，对端已 FIN，本端回 FIN）
 *   - 其它状态：返回 -EINVAL，**仍然 consume 调用方的 ref**（统一释放语义）
 *
 * 错误返回值：
 *   - 0：FIN 已投递，重传定时器已挂；session 异步推进直至 CLOSED 后自动释放。
 *   - -EINVAL：状态不合法（既不是 ESTABLISHED 也不是 CLOSE_WAIT）；session 已 put。
 *   - 其它负数：FIN 投递失败；状态已回滚；session 已 put。
 */
int ubmad_wk_close(struct ubmad_wk_session *session)
{
    struct ubmad_device_priv *dev_priv = session->dev_priv;
    enum ubmad_wk_session_state prev_state;
    uint32_t fin_seq;
    int ret;

    spin_lock(&session->lock);
    prev_state = session->state;     /* v3.3：保存以便失败回滚到正确状态 */

    /* 被动方在 CLOSE_WAIT 状态也可调用 close 发起自己的 FIN（→ LAST_ACK） */
    if (prev_state == UBMAD_WK_ESTABLISHED) {
        session->state = UBMAD_WK_FIN_WAIT_1;
    } else if (prev_state == UBMAD_WK_CLOSE_WAIT) {
        session->state = UBMAD_WK_LAST_ACK;
    } else {
        spin_unlock(&session->lock);
        ubmad_put_session(session);   /* v3.6: consume caller's ref even on -EINVAL */
        return -EINVAL;
    }

    /* v3.3：FIN 也"消耗"一个序列号（TCP 风格）。SYN 已用 local_isn，
     * 故 FIN 用 local_isn+1。这个值需要持久存进 session 以便重传时一致。 */
    if (!session->local_fin_seq)
        session->local_fin_seq = session->local_isn + 1;
    fin_seq = session->local_fin_seq;
    spin_unlock(&session->lock);

    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_FIN, fin_seq, 0);
    if (ret) {
        spin_lock(&session->lock);
        session->state = prev_state;     /* v3.3：回滚到原状态（不是硬编码 ESTABLISHED） */
        spin_unlock(&session->lock);
        ubmad_put_session(session);   /* v3.6: consume caller's ref */
        return ret;
    }

    /* v3.2 新增：启动 FIN 重传定时器。
     * 复用 rt_work（握手已完成，rt_work 此刻空闲）。
     * rt_work_handler 会按 session->state 分派到 SYN/SYN_ACK/FIN 重传。
     * 必须先 kref_get（见 §7.4）——这是给 timer 的独立一份 ref，
     * 与下面要 put 掉的 caller ref 是两份不同的 ref。 */
    session->rt_cnt = 0;
    kref_get(&session->kref);
    queue_delayed_work(session->rt_wq, &session->rt_work,
                       msecs_to_jiffies(2));

    /* v3.6: consume caller's ref。timer 持有自己那份 ref，
     * session 不会被立即释放；teardown 完成后 timer 会 put 让 kref 归零。 */
    ubmad_put_session(session);
    return 0;
}
EXPORT_SYMBOL_GPL(ubmad_wk_close);
```

### 6.3 函数二：`ubmad_process_wk_fin()`

**场景**：收到对端 FIN 消息。

```c
/**
 * ubmad_process_wk_fin - 处理收到的 FIN
 *
 * 场景一：主动方收到对端 FIN（主动方处于 FIN_WAIT_2）
 *   → 发送 FIN_ACK → 迁移到 TIME_WAIT → 启动 MSN-window 定时器
 *
 * 场景二：被动方首次收到 FIN（被动方处于 ESTABLISHED）
 *   → 迁移到 CLOSE_WAIT → 发送 FIN_ACK → 通知上层（上层调用 ubmad_wk_close）
 */
static void ubmad_process_wk_fin(struct ubmad_msg *msg,
                                  struct ubcore_cr *cr,
                                  struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;
    enum ubmad_wk_session_state old_state;

    /* v3.2：按 peer_session_id 查找（即接收方自己的 ID） */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->peer_session_id);
    if (!session)
        return;

    spin_lock(&session->lock);
    old_state = session->state;

    /* v3.3：首次见到对端 FIN 的状态——记录对端 FIN 的 seq，
     * 后续 FIN_ACK 的 ack 字段需要回填 wk_hdr->isn+1。
     *
     * v3.7：原来 TIME_WAIT 也在这个 record 块里，结果下面的"FIN 重传校验"
     * 形同虚设——每次进来都会被覆盖成 wk_hdr->isn，与之比较自然永远相等。
     * 现在限制只在首次见到 FIN 的两个状态记录：
     *   - ESTABLISHED → CLOSE_WAIT（被动方首次收 FIN）
     *   - FIN_WAIT_2  → TIME_WAIT（主动方首次收对端 FIN）
     * CLOSE_WAIT / TIME_WAIT 是重传 FIN 的处理路径，必须保留首次记录的值
     * 以便对 isn 做有效校验。 */
    if (old_state == UBMAD_WK_FIN_WAIT_2 ||
        old_state == UBMAD_WK_ESTABLISHED) {
        session->remote_fin_seq = wk_hdr->isn;
    }

    if (old_state == UBMAD_WK_FIN_WAIT_2) {
        /* 场景一：主动方收到对端 FIN。
         *
         * v3.8 修订：FIN_WAIT_2 → TIME_WAIT 这一步存在与 FW2 keep-alive
         * 定时器的 race：tw_work 被两种用途共用，handler 进来时只看 state。
         * 如果我们先把 state 改成 TIME_WAIT 再 cancel，万一 handler 此时
         * 已经在 spinlock 上等候，它解锁后会看到 state==TIME_WAIT 并误以为
         * 是 TIME_WAIT 期满，提前把 session 关掉（漏发 FIN_ACK，对端会重传
         * 直到 MSN 上限）。
         *
         * 正确顺序：先解锁释放 FW2 timer（不改 state），cancel 或 flush 让
         * handler 跑完；然后重新加锁、检查 state 是否仍是 FIN_WAIT_2；
         * 是则改成 TIME_WAIT 继续，否则 handler 已经把 state 推到 CLOSED
         * 了——FW2 期满和我们收 FIN 同时发生，handler 赢；本端只需 bail，
         * 对端会因为没收到 FIN_ACK 而由 MSN 重传一会儿，但不影响清理正确性。 */
        spin_unlock(&session->lock);

        if (cancel_delayed_work(&session->tw_work)) {
            /* FW2 timer 还在队列里，没跑——补 put */
            ubmad_put_session(session);
        } else {
            /* 已经在跑或刚跑完——等它结束（不能持锁，会死锁） */
            flush_delayed_work(&session->tw_work);
        }

        spin_lock(&session->lock);
        if (session->state != UBMAD_WK_FIN_WAIT_2) {
            /* FW2 handler 在我们之前赢得了竞争，session 已被标为 CLOSED
             * 并 put 了哈希 ref。我们这里只需 put 自己的 find ref，让对端
             * 重传的 FIN 自行超时即可——session 可能马上释放。 */
            spin_unlock(&session->lock);
            ubmad_put_session(session);
            return;
        }
        session->state = UBMAD_WK_TIME_WAIT;
        spin_unlock(&session->lock);

        /* 发送 FIN_ACK（v3.3：ack = remote_fin_seq + 1） */
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN_ACK,
                            0, session->remote_fin_seq + 1);

        /* 启动 TIME_WAIT 定时器（UBMAD_WK_TIME_WAIT_MS = 4000ms）
         * v3.2：必须先 kref_get，否则 tw_work_handler 的 put 会跌破 0。 */
        kref_get(&session->kref);
        queue_delayed_work(session->rt_wq, &session->tw_work,
                           msecs_to_jiffies(UBMAD_WK_TIME_WAIT_MS));

    } else if (old_state == UBMAD_WK_ESTABLISHED) {
        /* 场景二：被动方收到 FIN */
        session->state = UBMAD_WK_CLOSE_WAIT;
        spin_unlock(&session->lock);

        /* 发送 FIN_ACK（v3.3：ack = remote_fin_seq + 1） */
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN_ACK,
                            0, session->remote_fin_seq + 1);

        /* 通知上层"对端已关闭，你可以继续发数据，但最终也需要调用 close()" */
        if (session->on_closed)
            session->on_closed(session, 0 /* 正常关闭 */, session->cb_ctx);

    } else if (old_state == UBMAD_WK_TIME_WAIT ||
               old_state == UBMAD_WK_CLOSE_WAIT) {
        /* v3.2 / v3.5：处于 TIME_WAIT 或 CLOSE_WAIT 时收到对端重传的 FIN。
         * 重发 FIN_ACK 让对端能推进。
         *
         * v3.6：先校验 wk_hdr->isn 与首次记录的 remote_fin_seq 一致——这是
         * 同一连接的同一个 FIN 的重传。如果不同（异常或攻击），不应该用旧的
         * remote_fin_seq+1 去 ACK 一个不同的 isn，会破坏对端的 ack 校验。
         * 直接丢弃并 warn。 */
        if (wk_hdr->isn != session->remote_fin_seq) {
            spin_unlock(&session->lock);
            pr_warn("ubmad_wk: FIN isn mismatch in state=%d session=%u "
                    "expect=%u got=%u (drop)\n",
                    old_state, session->session_id,
                    session->remote_fin_seq, wk_hdr->isn);
            ubmad_put_session(session);
            return;
        }
        spin_unlock(&session->lock);
        pr_debug("ubmad_wk: re-ACK FIN in state=%d for session=%u\n",
                 old_state, session->session_id);
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN_ACK,
                            0, session->remote_fin_seq + 1);
        /* 不重启 TIME_WAIT；不重新触发 on_closed（已在首次 FIN 时回调）。 */

    } else {
        spin_unlock(&session->lock);
        pr_warn("ubmad_wk: FIN in unexpected state=%d\n", old_state);
    }

    ubmad_put_session(session);
}
```

### 6.4 函数三：`ubmad_process_wk_fin_ack()`

**场景**：收到对端对 FIN 的确认（FIN_ACK）。

```c
/**
 * ubmad_process_wk_fin_ack - 处理 FIN_ACK
 *
 * 场景一：主动方（FIN_WAIT_1）收到 FIN_ACK
 *   → 迁移到 FIN_WAIT_2（等待对端 FIN）
 *
 * 场景二：被动方（LAST_ACK）收到 FIN_ACK
 *   → 迁移到 CLOSED → 释放 session
 */
static void ubmad_process_wk_fin_ack(struct ubmad_msg *msg,
                                       struct ubcore_cr *cr,
                                       struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;
    enum ubmad_wk_session_state old_state;

    /* v3.2：按 peer_session_id 查找（即接收方自己的 ID） */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->peer_session_id);
    if (!session)
        return;

    spin_lock(&session->lock);

    /* v3.3：校验 ack 字段。本端发出的 FIN 用 local_fin_seq，故 FIN_ACK 的
     * ack 应等于 local_fin_seq + 1。
     * local_fin_seq == 0 表示本端从未发过 FIN（不应收到 FIN_ACK）。 */
    if (session->local_fin_seq == 0 ||
        wk_hdr->ack != session->local_fin_seq + 1) {
        spin_unlock(&session->lock);
        pr_warn("ubmad_wk: FIN_ACK ack mismatch session=%u expect=%u got=%u\n",
                session->session_id,
                session->local_fin_seq + 1, wk_hdr->ack);
        ubmad_put_session(session);
        return;
    }

    old_state = session->state;

    if (old_state == UBMAD_WK_FIN_WAIT_1) {
        session->state = UBMAD_WK_FIN_WAIT_2;
        spin_unlock(&session->lock);
        /* v3.3：cancel 成功要释放 timer 持有的 ref */
        if (cancel_delayed_work(&session->rt_work))
            ubmad_put_session(session);

        /* v3.7：FIN_WAIT_2 必须有自己的 keep-alive ref，否则对端 FIN
         * 到达之前 session 没有任何 ref（caller ref 早被 close 消费、
         * timer ref 刚被 cancel-then-put、find ref 马上要在函数末尾 put）
         * 就会被 free。同时也需要一个超时——TCP 标准做法（Linux
         * tcp_fin_timeout，默认 60s）防止对端永远不发 FIN。
         *
         * 复用 tw_work：它本来就是"等若干秒然后释放 session"的形态。
         * tw_work_handler 现在按 state 分派：FIN_WAIT_2 表示对端没在期限内
         * 发 FIN，本端放弃并迁到 CLOSED；TIME_WAIT 表示等待重传 FIN，
         * 期满后干净释放。 */
        kref_get(&session->kref);
        queue_delayed_work(session->rt_wq, &session->tw_work,
                           msecs_to_jiffies(UBMAD_WK_FIN_WAIT_2_MS));
        /* 等待对端的 FIN（由 ubmad_process_wk_fin 处理；它会先 cancel
         * 这个 FIN_WAIT_2 keep-alive，再启动真正的 TIME_WAIT 定时器） */

    } else if (old_state == UBMAD_WK_LAST_ACK) {
        session->state = UBMAD_WK_CLOSED;
        spin_unlock(&session->lock);
        /* v3.3：同上 */
        if (cancel_delayed_work(&session->rt_work))
            ubmad_put_session(session);

        /* 被动方四次挥手完成，释放 session */
        pr_info("ubmad_wk: session=%u closed (passive side)\n",
                session->session_id);
        ubmad_put_session(session);   /* 释放哈希表持有的引用 */
    } else {
        spin_unlock(&session->lock);
    }

    ubmad_put_session(session);   /* 释放 find_by_id 持有的引用 */
}
```

### 6.5 被动方发送自己的 FIN

被动方在 CLOSE_WAIT 状态下，上层只需要调用 §6.2 的同一个 `ubmad_wk_close()`——
该函数已经同时处理 ESTABLISHED → FIN_WAIT_1（主动方）和 CLOSE_WAIT → LAST_ACK
（被动方）两条路径。**不需要单独定义被动方版本**。

> **v3.4 修订**：v3.2 / v3.3 在本节给出过一个独立的 `ubmad_wk_close` 副本，
> 但它（a）使用 `UBMAD_WK_FIN, 0, 0` 而忽略 v3.3 §6.2 引入的 FIN 序列号约定；
> （b）状态回滚仍是 v3.2 风格的硬编码三元运算。两套实现共存只会让读者迷惑。
> v3.4 删除本节的重复定义，统一以 §6.2 为准。

被动方典型调用序列：

```text
1. 收到对端 FIN → ubmad_process_wk_fin() 把 session 迁入 CLOSE_WAIT 并触发
   on_closed 回调通知上层。
2. 上层在 on_closed 回调（或之后的某个清理点）里调用 ubmad_wk_close(session)。
   §6.2 的实现检测 state==CLOSE_WAIT，把 state 迁到 LAST_ACK，发送 FIN
   （携带 local_fin_seq = local_isn + 1），启动 FIN 重传定时器。
3. 收到对端 FIN_ACK → ubmad_process_wk_fin_ack() 校验 ack==local_fin_seq+1
   后迁到 CLOSED，释放 session。
```

### 6.6 验证方法

使用 `dmesg` 观察状态迁移日志（在每个状态迁移处加 `pr_debug`）：

```bash
# 开启动态 debug
echo 'module ubcore +p' > /sys/kernel/debug/dynamic_debug/control
# 触发连接和断开
# 观察日志
dmesg | grep "ubmad_wk:"
```

预期日志序列（主动关闭方）：

```
ubmad_wk: session=1 state: ESTABLISHED → FIN_WAIT_1
ubmad_wk: session=1 state: FIN_WAIT_1  → FIN_WAIT_2
ubmad_wk: session=1 state: FIN_WAIT_2  → TIME_WAIT
ubmad_wk: session=1 TIME_WAIT expired, session closed
```

---

## Step 7：实现重传定时器与 TIME_WAIT

### 7.1 目标

实现 SYN/SYN_ACK 的重传逻辑（指数退避）以及 TIME_WAIT 的超时释放逻辑。

### 7.2 函数一：`ubmad_wk_syn_rt_work_handler()`

```c
/**
 * ubmad_wk_syn_rt_work_handler - SYN / SYN_ACK 重传工作处理函数
 *
 * 此函数在 dev_priv->rt_wq 工作队列中执行（非中断上下文）。
 *
 * 重传逻辑（指数退避）：
 *   - 首次重传延迟：2ms
 *   - 第 n 次重传延迟：2 * 2^(n-1) ms（最大不超过 1000ms）
 *   - 超过 UBMAD_WK_MAX_RETRY 次后，放弃并通知上层失败
 *
 * 幂等性保证：
 *   检查 session->state 是否仍处于 SYN_SENT / SYN_RCVD，
 *   如果已迁移则说明握手已完成，不再重传。
 */
static void ubmad_wk_syn_rt_work_handler(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct ubmad_wk_session *session =
            container_of(dwork, struct ubmad_wk_session, rt_work);
    struct ubmad_device_priv *dev_priv = session->dev_priv;
    enum ubmad_wk_session_state state;
    unsigned long delay_ms;
    int ret;

    spin_lock(&session->lock);
    state = session->state;
    spin_unlock(&session->lock);

    /* 检查是否仍需重传（v3.2：除握手状态外，FIN_WAIT_1/LAST_ACK 也走此路径） */
    if (state != UBMAD_WK_SYN_SENT && state != UBMAD_WK_SYN_RCVD &&
        state != UBMAD_WK_FIN_WAIT_1 && state != UBMAD_WK_LAST_ACK) {
        /* 握手 / 挥手已完成或已失败，不再重传 */
        ubmad_put_session(session);
        return;
    }

    /* 检查重传次数 */
    if (session->rt_cnt >= UBMAD_WK_MAX_RETRY) {
        pr_warn("ubmad_wk: session=%u retransmit limit reached in state=%d\n",
                session->session_id, state);

        spin_lock(&session->lock);
        session->state  = UBMAD_WK_CLOSED;
        session->result = -ETIMEDOUT;
        spin_unlock(&session->lock);

        /* 通知等待者失败 */
        if (session->on_closed)
            session->on_closed(session, -ETIMEDOUT, session->cb_ctx);
        else
            complete(&session->connected);

        ubmad_put_session(session);
        return;
    }

    /* 重传对应消息（v3.2：扩展为支持 FIN/SYN/SYN_ACK） */
    session->rt_cnt++;
    switch (state) {
    case UBMAD_WK_SYN_SENT:
        /* 客户端重传 SYN */
        ret = ubmad_post_send_wk(dev_priv, session,
                                  UBMAD_WK_SYN, session->local_isn, 0);
        break;
    case UBMAD_WK_SYN_RCVD:
        /* 服务端重传 SYN_ACK */
        ret = ubmad_post_send_wk(dev_priv, session,
                                  UBMAD_WK_SYN_ACK,
                                  session->local_isn,
                                  session->remote_isn + 1);
        break;
    case UBMAD_WK_FIN_WAIT_1:
    case UBMAD_WK_LAST_ACK:
        /* v3.2 新增：主动方/被动方重传自己发的 FIN
         * v3.3：用 session->local_fin_seq 而不是 0；
         * 重传必须与首次发送 seq 一致，否则对端 FIN_ACK 的 ack 校验会失败。 */
        ret = ubmad_post_send_wk(dev_priv, session,
                                  UBMAD_WK_FIN,
                                  session->local_fin_seq, 0);
        break;
    default:
        ret = 0;  /* 不应到达 */
        break;
    }

    if (ret) {
        pr_err("ubmad_wk: retransmit failed ret=%d\n", ret);
        /* 仍然继续重试，下次可能网络就好了 */
    }

    /* 计算下次重传延迟（指数退避，上限 1000ms） */
    delay_ms = min_t(unsigned long,
                     2UL << session->rt_cnt,   /* 2, 4, 8, 16, ... ms */
                     1000UL);

    queue_delayed_work(session->rt_wq, &session->rt_work,
                       msecs_to_jiffies(delay_ms));

    /* 注意：不在此处 put session，定时器持有一个引用 */
}
```

### 7.3 函数二：`ubmad_wk_time_wait_handler()`

```c
/**
 * ubmad_wk_time_wait_handler - TIME_WAIT / FIN_WAIT_2 超时处理（v3.7 起 reuse）
 *
 * v3.7 改动：本 handler 同时被 TIME_WAIT 和 FIN_WAIT_2 两种状态用作超时器。
 *   - TIME_WAIT：等 UBMAD_WK_TIME_WAIT_MS（4000ms）。期间收到对端重传的
 *     FIN 时由 process_wk_fin 重发 FIN_ACK；超时后正常释放。
 *   - FIN_WAIT_2：等 UBMAD_WK_FIN_WAIT_2_MS（30000ms）。本端已收到对端的
 *     FIN_ACK 但还没看到对端发自己的 FIN；如果对端永远不发，超时后放弃。
 *     这个 keep-alive 同时也是 FIN_WAIT_2 期间唯一的 session 持有者。
 *
 * 两种状态的处理逻辑都是"迁到 CLOSED → put 哈希表持有的 ref"，所以本
 * handler 不需要按状态分支，只在日志里区分原因即可。
 *
 * 为什么需要 TIME_WAIT？
 *   最后一个 FIN_ACK 可能因网络丢失导致对端重传 FIN。
 *   TIME_WAIT 确保我们还能响应这些迟到的 FIN（直接重发 FIN_ACK），
 *   避免对端因未收到 FIN_ACK 而一直重传。
 *
 * 为什么需要 FIN_WAIT_2 超时？
 *   主动关闭方收到 FIN_ACK 后等对端发自己的 FIN。如果对端已经异常掉线
 *   或对端的 close 路径出问题，主动方就会一直留在 FIN_WAIT_2，session
 *   永远不释放。30 秒超时是借鉴 Linux tcp_fin_timeout 的折中。
 */
static void ubmad_wk_time_wait_handler(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct ubmad_wk_session *session =
            container_of(dwork, struct ubmad_wk_session, tw_work);
    enum ubmad_wk_session_state old_state;

    spin_lock(&session->lock);
    old_state = session->state;
    if (old_state == UBMAD_WK_TIME_WAIT ||
        old_state == UBMAD_WK_FIN_WAIT_2)
        session->state = UBMAD_WK_CLOSED;
    spin_unlock(&session->lock);

    if (old_state == UBMAD_WK_FIN_WAIT_2)
        pr_info("ubmad_wk: session=%u FIN_WAIT_2 timeout, peer never sent FIN; releasing\n",
                session->session_id);
    else
        pr_info("ubmad_wk: session=%u TIME_WAIT expired, releasing\n",
                session->session_id);

    /* v3.9 修订：释放本 timer 入队前 kref_get 拿的那一份 ref。
     * （§7.4 规则：哈希表本身不计 ref；此处放掉的是 timer ref。
     *  这一 put 通常会让 kref 归零并触发 ubmad_release_session。） */
    ubmad_put_session(session);
}
```

### 7.4 定时器引用计数管理

| 场景 | get 时机 | put 时机 |
|------|---------|---------|
| 分配 session | `kref_init`（=1） | — |
| 哈希表插入 | 无额外 get（哈希表不加引用） | `ubmad_release_session` 中 hash_del |
| `ubmad_alloc_session` 返回给调用者 | 已有的 1 个 | 调用者用完后 `ubmad_put_session` |
| `find_by_id` / `find_by_peer` | **`kref_get_unless_zero`**（v3.9） | 调用者用完后 `ubmad_put_session` |
| rt_work 入队前 | `kref_get` | `rt_work_handler` 末尾 `put`（或 cancel 路径补 put） |
| tw_work 入队前 | `kref_get` | `tw_work_handler` 末尾 `put`（或 cancel 路径补 put） |
| `ubmad_wk_connect` 返回给上层调用方 | 把 alloc 的那 1 个 ref 转给调用方 | **调用方调 `ubmad_wk_close(session)` 时被 consume**（v3.6） |

> **v3.9 关键 invariant**：哈希表本身**不持有 ref**——这意味着 `find_by_*` 在锁内做 ref 增长时，session 可能正处于 ref==0 → 即将释放的窗口。如果用裸 `kref_get` 把 0 拉回 1，等于复活一个正在被释放的对象，最终触发 double-free 或 UAF。`kref_get_unless_zero` 是标准做法：返回 false 时把这个 session 当作"未找到"跳过即可。
>
> 同样这个 invariant 决定了 `ubmad_release_session()` 不能 `cancel_delayed_work_sync` 自己——release 可能由 work handler 的最终 put 触发；handler 同步 cancel 自己会死锁。详见 §3.9 函数注释。

> **重要**：每次 `queue_delayed_work` 之前必须先 `kref_get`，并在 handler 最后 `kref_put`。否则 session 对象可能在 handler 执行中途被释放。
>
> **v3.3 补充**：取消 work 时若 `cancel_delayed_work()` 返回 `true`（说明 work 还在队列里没执行），handler 不会跑、它的 `kref_put` 也不会发生。**调用方此时必须代替 handler 做一次 `ubmad_put_session(session)`**，否则就泄露一个引用。
> ```c
> if (cancel_delayed_work(&session->rt_work))
>     ubmad_put_session(session);
> ```
>
> **v3.4 修订**：v3.3 曾说「`cancel_delayed_work_sync()` 不需要补 put」——这是错的。`cancel_delayed_work_sync()` 不会"自动执行" handler；它只会：(a) 如果 work 还在排队，从队列移除；(b) 如果 work 已经在跑，等它跑完。两种情况都返回 `true`，**但只有 (b) 中 handler 才执行了 `kref_put`**；(a) 中 handler 永远没机会跑，timer ref 仍泄露。
>
> 而且从返回值无法分辨 (a) 和 (b)。所以正确做法是不要在取消热路径用 sync 版本，改用以下规范：
> ```c
> if (cancel_delayed_work(&session->rt_work)) {
>     /* (a) work 还在队列里，handler 不会跑 — 我们补 put */
>     ubmad_put_session(session);
> } else {
>     /* (b) 已经在跑或已跑完；等它结束以保证 handler 的 put 真正发生 */
>     flush_delayed_work(&session->rt_work);
> }
> ```
> 这个模式在持锁时不能用（`flush_delayed_work` 会等 handler，handler 要拿同一把锁就死锁）。所以：所有同步等待 handler 退出的 cancel 都必须发生在解锁后。本设计的 §4.4 connect() 同步超时分支就是这样写的。
>
> **v3.6 补充：调用方持有的 ref 由 `ubmad_wk_close()` consume**——v3.5 让 `ubmad_wk_connect()` 返回 session 指针并把 alloc 的那份 ref 交给调用方，但当时没说清楚 `ubmad_wk_close()` 怎么处理这份 ref，留下了"调 close 之后要不要再 put 一次"的歧义。v3.6 选 close-consume 语义：调用 `ubmad_wk_close(session)` 后，调用方 MUST NOT 再访问 session 指针；不论 close 返回 0 还是 -EINVAL/其它错，调用方那一份 ref 都已被释放。理由：close 之后调用方除了 put 外没别的操作可做，统一 consume 简化使用方代码。

---

## Step 8：集成到模块初始化与清理

### 8.1 修改文件

`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c`

### 8.2 在 `ubmad_init()` 中初始化会话全局表

找到 `ubmad_init()` 函数（约 `ub_mad.c:1272`），在函数开头添加：

```c
int ubmad_init(void)
{
    int ret;

    /* 新增：初始化公知 Jetty 会话全局哈希表 */
    ret = ubmad_session_init_global();
    if (ret) {
        pr_err("ubmad: failed to init session table ret=%d\n", ret);
        return ret;
    }

    /* 以下为原有代码 */
    INIT_LIST_HEAD(&g_ubmad_device_list);
    /* ... */
}
```

### 8.3 在 `ubmad_uninit()` 中清理

找到 `ubmad_uninit()` 函数（约 `ub_mad.c:1291`），在函数末尾添加：

```c
void ubmad_uninit(void)
{
    /* 原有代码：先取消注册 client */
    ubcore_unregister_client(&g_ubmad_client);

    /* 新增：清理会话全局资源 */
    ubmad_session_cleanup_global();
}
```

### 8.4 在 `ubmad_close_device()` 中清理设备级监听 session

找到 `ubmad_close_device()` 函数，在调用 `ubmad_put_device_priv()` 之前添加：

```c
static void ubmad_close_device(struct ubcore_device *device)
{
    struct ubmad_device_priv *dev_priv;

    /* ... 原有代码：从全局链表移除 ... */

    /* 新增：清理监听 session */
    if (dev_priv->listen_session) {
        ubmad_put_session(dev_priv->listen_session);
        dev_priv->listen_session = NULL;
    }

    /* 原有代码 */
    ubmad_put_device_priv(dev_priv);
    ubmad_put_device_priv(dev_priv);
}
```

### 8.5 验证方法

```bash
# 模块加载 / 卸载测试
modprobe ubcore
dmesg | tail -20   # 应无 BUG / WARN / use-after-free

rmmod ubcore
dmesg | tail -20   # 应无内存泄漏警告
```

配合 KASAN（Kernel Address Sanitizer）使用效果更好：

```bash
# 编译内核时开启 CONFIG_KASAN=y, CONFIG_KASAN_GENERIC=y
# 运行同上测试，观察是否有 KASAN 报告
```

---

## Step 9：更新 Makefile

> **v3.2 修订**：原 Step 9 还提到了"更新 Kconfig"，但实际内核树没有
> `ubcore/Kconfig`（只有顶层 `drivers/ub/Kconfig`，定义 `CONFIG_UB_URMA`）。
> Kconfig 改动归 [Step 11](#step-11kconfig-特性开关) 处理；本步只改
> Makefile。原文中错误指向 `ubcore/ubcm/Makefile`（也不存在）的部分已修正。

### 9.1 修改 Makefile

文件：`kernel/drivers/ub/urma/ubcore/Makefile`（**这是真实存在的文件**；不存在 `ubcm/Makefile`，所有 ubcm 下的 .o 直接列在 ubcore Makefile 里，参见现有 `ubcm/ub_mad.o` `ubcm/ubmad_datapath.o` 的写法）。

在 `ubcore-objs := \` 块中追加一行（按字母序或紧贴现有的 `ubcm/` 行）：

```makefile
ubcore-objs := \
    ...
    ubcm/ub_mad.o \
    ubcm/ubmad_datapath.o \
    ubcm/ub_cm.o \
    ubcm/ubmad_session.o \    # ← 新增
    ...
```

> 注意：Step 11 会把这一行包成 `ubcore-$(CONFIG_UBMAD_WK_SESSION) += ubcm/ubmad_session.o` 以做条件编译。本步先无条件加入便于调试；Step 11 再补上 Kconfig 守护。

### 9.2 验证方法

```bash
# 全量编译，确认 ubmad_session.o 被正确编译进去
make -C /path/to/kernel M=drivers/ub/urma/ubcore V=1 2>&1 | grep ubmad_session
```

预期输出类似：

```
  CC [M]  drivers/ub/urma/ubcore/ubcm/ubmad_session.o
  LD [M]  drivers/ub/urma/ubcore/ubcore.ko
```

---

## Step 10：验证与测试

### 10.1 单元测试（内核 kunit 框架）

在 `ubmad_session.c` 末尾添加 kunit 测试套件：

```c
#ifdef CONFIG_UBMAD_WK_KUNIT_TEST
#include <kunit/test.h>

/* 测试用例一：session 分配和释放 */
static void ubmad_test_session_alloc_free(struct kunit *test)
{
    struct ubmad_device_priv fake_dev = {};
    union ubcore_eid fake_eid = {};
    struct ubmad_wk_session *session;

    /* 初始化全局表 */
    ubmad_session_init_global();

    /* 分配 */
    session = ubmad_alloc_session(&fake_dev, &fake_eid);
    KUNIT_ASSERT_NOT_ERR_OR_NULL(test, session);
    KUNIT_EXPECT_EQ(test, session->state, UBMAD_WK_CLOSED);

    /* 通过 ID 查找 */
    struct ubmad_wk_session *found =
        ubmad_session_find_by_id(&fake_dev, session->session_id);
    KUNIT_EXPECT_PTR_EQ(test, found, session);
    ubmad_put_session(found);

    /* 释放 */
    ubmad_put_session(session);

    ubmad_session_cleanup_global();
}

/* 测试用例二：ISN 非零 */
static void ubmad_test_gen_isn(struct kunit *test)
{
    int i;
    for (i = 0; i < 1000; i++) {
        uint32_t isn = ubmad_gen_isn();
        KUNIT_EXPECT_NE(test, isn, 0u);
    }
}

static struct kunit_case ubmad_wk_test_cases[] = {
    KUNIT_CASE(ubmad_test_session_alloc_free),
    KUNIT_CASE(ubmad_test_gen_isn),
    {}
};

static struct kunit_suite ubmad_wk_suite = {
    .name  = "ubmad_wk_session",
    .test_cases = ubmad_wk_test_cases,
};
kunit_test_suite(ubmad_wk_suite);

#endif /* CONFIG_UBMAD_WK_KUNIT_TEST */
```

运行：

```bash
# 编译时开启 CONFIG_UBMAD_WK_KUNIT_TEST=y
./tools/testing/kunit/kunit.py run --filter_glob='ubmad_wk_session*'
```

### 10.2 集成测试（端到端握手）

在测试驱动模块中：

```c
/* server.c */
void server_thread(struct ubmad_device_priv *dev_priv)
{
    ubmad_wk_listen(dev_priv, on_established_cb, on_closed_cb, NULL);
}

void on_established_cb(struct ubmad_wk_session *session, void *ctx)
{
    pr_info("Server: connection ESTABLISHED with client session=%u\n",
            session->session_id);
    /* 连接建立后，服务端可以发送应用数据（超出本设计文档范围） */
}

/* client.c */
void client_thread(struct ubmad_device_priv *dev_priv,
                   union ubcore_eid *server_eid)
{
    /* v3.5 起 connect 返回 session 指针或 ERR_PTR */
    struct ubmad_wk_session *session =
        ubmad_wk_connect(dev_priv, server_eid, NULL, NULL, NULL);

    if (IS_ERR(session)) {
        pr_err("Client: connect failed ret=%ld\n", PTR_ERR(session));
        return;
    }
    pr_info("Client: 3-way handshake complete, session=%u\n",
            session->session_id);

    /* ... 这里跑业务（v1 没有数据平面，所以业务通常意味着"知道连接已就绪即可"） ... */

    /* v3.6 起 close consume 调用方持有的那一份 ref；返回后 session 不可再用 */
    ubmad_wk_close(session);
}
```

预期 `dmesg` 输出：

```
ubmad_wk: alloc session id=1 remote_eid=...
ubmad_wk: alloc session id=2 remote_eid=...   (服务端为此连接分配 session)
ubmad_wk: session=2 state: SYN_RCVD
ubmad_wk: session=1 state: ESTABLISHED
Server: connection ESTABLISHED with client session=2
Client: 3-way handshake complete!
```

### 10.3 异常测试清单

| 测试场景 | 预期行为 |
|---------|---------|
| SYN 丢包（模拟：临时 drop 接收包） | 客户端在 2ms / 4ms / ... 重传，11 次后返回 -ETIMEDOUT |
| SYN_ACK 丢包 | 服务端重传 SYN_ACK，客户端最终收到后正常完成握手 |
| 重复 SYN（模拟：客户端快速发两次）| 服务端幂等处理，只建立一个 session |
| 连接建立后设备移除（modprobe -r）| `ubmad_close_device` 清理 session，无 use-after-free |
| 并发 1000 个握手请求 | 无死锁，无内存泄漏（用 KASAN 验证）|

---

## Step 11：Kconfig 特性开关

### 11.1 目标

将本设计作为**可选特性**编译，让不需要 WK Jetty 会话状态机的部署能完全跳过这部分代码（节省内存、避免引入新错误面）。

### 11.2 修改文件

**v3.2 修订**：内核树中 **没有** `drivers/ub/urma/ubcore/Kconfig`——所有 UB 子系统的 Kconfig 都汇总在顶层 `drivers/ub/Kconfig`，通过 `source` 引入各子目录的 Kconfig（如 `source "drivers/ub/urma/hw/udma/Kconfig"`）。`CONFIG_UB_URMA` 也定义在此文件。

两种实现方式：

**方式 A（推荐，最小侵入）**：直接把新 config 加到 `drivers/ub/Kconfig` 中 `config UB_URMA` 块的下方。

**方式 B（更整洁）**：新建 `drivers/ub/urma/ubcore/Kconfig`，里面只放 `UBMAD_WK_SESSION` 这一项；然后在 `drivers/ub/Kconfig` 中加一行 `source "drivers/ub/urma/ubcore/Kconfig"`。后续如果有更多 ubcore 级别的 config 选项可以集中放在这里。

Makefile 改动文件：`drivers/ub/urma/ubcore/Makefile`（这个文件**确实存在**）。

### 11.3 Kconfig 新增项

在 `drivers/ub/Kconfig` 中 `config UB_URMA` 块的下方（方式 A），或新建的 `drivers/ub/urma/ubcore/Kconfig` 中（方式 B），追加：

```
config UBMAD_WK_SESSION
    bool "UBMAD well-known jetty connection state machine (3-way handshake / 4-way teardown)"
    depends on UB_URMA
    default n
    help
      Enable the optional connection state machine layered on top of the
      UBMAD well-known jetty (jetty ID 1). When enabled, callers can use
      ubmad_wk_connect() / ubmad_wk_listen() / ubmad_wk_close() to
      establish and tear down logical sessions over the unreliable WK
      jetty transport (UM trans_mode).

      The session-level state machine adds its own retransmit timer for
      handshake messages; it does NOT layer on top of UBMAD's MSN retry
      (handshake messages bypass MSN — see design doc §0.2).

      If unsure, say N.
```

### 11.4 Makefile 条件编译

修改 `drivers/ub/urma/ubcore/Makefile`：

```makefile
# 现有 ubcore 编译目标
ubcore-y += ... ubcm/ub_mad.o ubcm/ubmad_datapath.o ...

# 新增：仅在启用 WK SESSION 时编译会话管理
ubcore-$(CONFIG_UBMAD_WK_SESSION) += ubcm/ubmad_session.o
```

### 11.5 源文件中的 ifdef 守护

`ubmad_datapath.c` 中所有新增的握手相关函数（`ubmad_wk_connect`、`ubmad_wk_listen`、`ubmad_wk_close`、`ubmad_post_send_wk`、`ubmad_process_wk_*`、`ubmad_wk_syn_rt_work_handler`、`ubmad_wk_time_wait_handler`）以 `#ifdef CONFIG_UBMAD_WK_SESSION ... #endif` 包裹。

`ubmad_process_msg()` 中的新分发分支也用同样的 ifdef 包裹：

```c
switch (msg->msg_type) {
case UBMAD_UBC_CONN_REQ:
case UBMAD_UBC_CONN_RESP:
    ubmad_process_conn_data(...);
    break;
#ifdef CONFIG_UBMAD_WK_SESSION
case UBMAD_WK_SYN:
    ubmad_process_wk_syn(dev_priv, msg, src_eid);
    break;
case UBMAD_WK_SYN_ACK:
    ubmad_process_wk_syn_ack(dev_priv, msg, src_eid);
    break;
/* ... 其余握手类型 ... */
#endif
default:
    /* unknown */
    break;
}
```

`ubmad_init()` 和 `ubmad_uninit()` 中的全局初始化/清理调用也加 ifdef：

```c
int ubmad_init(void)
{
    ...
#ifdef CONFIG_UBMAD_WK_SESSION
    ret = ubmad_session_init_global();
    if (ret) goto err_session;
#endif
    ...
}

void ubmad_uninit(void)
{
    ...
#ifdef CONFIG_UBMAD_WK_SESSION
    ubmad_session_cleanup_global();
#endif
    ...
}
```

### 11.6 头文件中的枚举处理

`ub_mad.h` 中新增的 `UBMAD_WK_SYN ... UBMAD_WK_FIN_ACK` 枚举值**不**用 ifdef 包裹——它们只是数值定义，不引入代码或符号。即使没启用本特性，留下这些枚举占位符也无副作用，避免后续启用时再改头文件破坏 ABI。

### 11.7 验证方法

```bash
# 测试一：默认配置不应包含 ubmad_session.o
make defconfig
make drivers/ub/urma/ubcore/
nm drivers/ub/urma/ubcore/ubcore.ko | grep ubmad_wk_  # 期望：无输出

# 测试二：启用配置后应包含
echo "CONFIG_UBMAD_WK_SESSION=y" >> .config
make olddefconfig
make drivers/ub/urma/ubcore/
nm drivers/ub/urma/ubcore/ubcore.ko | grep ubmad_wk_  # 期望：列出所有握手函数
```

预期：默认编译产物**不包含**任何 `ubmad_wk_*` 符号；启用后包含全部 16 个新函数。

---

## 16 个核心函数汇总

| # | 函数名 | 所在文件 | 功能摘要 |
|---|--------|---------|---------|
| 1 | `ubmad_wk_connect()` | `ubmad_datapath.c` | 客户端发起三次握手，阻塞等待连接完成（最多 5 秒）|
| 2 | `ubmad_wk_listen()` | `ubmad_datapath.c` | 服务端注册监听，接受握手请求 |
| 3 | `ubmad_alloc_session()` | `ubmad_session.c` | 分配会话对象，初始化字段，插入全局哈希表 |
| 4 | `ubmad_release_session()` | `ubmad_session.c` | kref 归零时的最终释放：撤销定时器、释放 tjetty、归还 ID、kfree |
| 5 | `ubmad_gen_isn()` | `ubmad_session.c` | 用 `get_random_u32()` 生成非零 ISN，防会话劫持 |
| 6 | `ubmad_post_send_wk()` | `ubmad_datapath.c` | 底层握手消息发送：分配 SGE、填头、构造 WR、投递硬件 |
| 7 | `ubmad_process_wk_syn()` | `ubmad_datapath.c` | 服务端收到 SYN：幂等创建 session → 发 SYN_ACK → 启重传定时器 |
| 8 | `ubmad_process_wk_syn_ack()` | `ubmad_datapath.c` | 客户端收到 SYN_ACK：校验 → 取消重传 → 发 ACK → 唤醒 connect() |
| 9 | `ubmad_process_wk_ack()` | `ubmad_datapath.c` | 服务端收到 ACK：迁移到 ESTABLISHED → 通知上层 |
| 10 | `ubmad_wk_close()` | `ubmad_datapath.c` | 发起四次挥手（主动 / 被动关闭均可调用），发 FIN |
| 11 | `ubmad_process_wk_fin()` | `ubmad_datapath.c` | 收到 FIN：发 FIN_ACK → 迁移状态 → 回调上层 |
| 12 | `ubmad_process_wk_fin_ack()` | `ubmad_datapath.c` | 收到 FIN_ACK：推进关闭状态机（FIN_WAIT_1→2 或 LAST_ACK→CLOSED）|
| 13 | `ubmad_wk_syn_rt_work_handler()` | `ubmad_datapath.c` | SYN/SYN_ACK 重传工作：指数退避，超限则通知失败 |
| 14 | `ubmad_wk_time_wait_handler()` | `ubmad_datapath.c` | **TIME_WAIT / FIN_WAIT_2** 共用的超时 handler（v3.7 起复用）：到期把 session 置 CLOSED 并 put 哈希 ref。两种触发原因日志区分：TIME_WAIT 是正常清理；FIN_WAIT_2 是对端没在 30s 内发 FIN，强制关闭 |
| 15 | `ubmad_session_find_by_id()` | `ubmad_session.c` | 哈希表查找 session：持锁、kref_get 后返回，调用者负责 put |
| 16 | `ubmad_session_init_global()` | `ubmad_session.c` | 初始化全局哈希表和 IDA，在 ubmad_init() 中调用 |

---

## 常见错误排查

### 错误一：`ubmad_post_send_wk` 返回 -EAGAIN

**原因**：对端 WK tjetty 尚未导入（`ubmad_get_tjetty` 返回 NULL）。

**排查**：

```bash
# 检查 conn_wq 工作项是否积压
cat /proc/$(pgrep -f ub_mad)/wchan   # 若阻塞在 conn_wq 说明导入未完成

# 检查 TP 是否建立
dmesg | grep "ubcore_get_tp_list"    # 应有成功返回日志
```

**解决**：调用 `ubmad_wk_connect()` 前确保对端设备已在线，或者引入重试机制（在 `ubmad_wk_syn_rt_work_handler` 中重试 `ubmad_post_send_wk`）。

### 错误二：握手超时但对端日志显示已收到 SYN

**原因**：SYN_ACK 在返回路径丢失，或客户端 `ubmad_process_wk_syn_ack()` 未被调用。

**排查**：

```bash
# 确认 ubmad_process_msg 的 switch 分支正确加入了 UBMAD_WK_SYN_ACK
grep -n "UBMAD_WK_SYN_ACK" ubmad_datapath.c

# 检查 session_id 是否匹配（客户端分配的 id 是否与 SYN 消息中的一致）
dmesg | grep "ubmad_wk.*session"
```

### 错误三：TIME_WAIT 结束后 use-after-free（KASAN 报告）

**原因**：`ubmad_wk_time_wait_handler` 中 `ubmad_put_session` 后，其他代码路径仍持有裸指针访问 session。

**解决**：所有 session 访问必须通过 `ubmad_session_find_by_id()` 获取引用计数保护，不得保存裸指针超过 `put_session` 的生命周期。

### 错误四：死锁（`cancel_delayed_work_sync` 在持锁时调用）

**原因**：在 `spin_lock(&session->lock)` 持锁期间调用了 `cancel_delayed_work_sync`，而 `rt_work_handler` 也需要获取同一个锁。

**解决**：用 §7.4「v3.4 修订」给出的"先 `cancel_delayed_work()` 看是否 pending、pending 就补 put、否则 `flush_delayed_work()`"模式，并保证整段操作都在解锁之后做。简单一律 `cancel_delayed_work_sync()` 既会死锁也会泄露 ref，**两个问题一起解决**。

---

## 关键数据流图

### 握手消息传输路径（复用现有 UBMAD 基础设施）

```
ubmad_wk_connect()
    │
    ▼
ubmad_post_send_wk()
    │  分配 SGE 槽位，填写 ubmad_msg + ubmad_wk_hdr
    ▼
ubcore_post_jetty_send_wr(jetty_rsrc[0].jetty, wr)
    │  通过 UBMAD WK Jetty ID=1 发送
    ▼
[硬件/UDMA 发送队列]
    │
    ▼ (对端)
ubmad_jfce_handler_r()         ← 接收 JFC 事件
    │
    ▼
ubmad_recv_work_handler()      ← 工作队列处理
    │
    ▼
ubmad_process_msg()
    │  switch(msg_type)
    ├── UBMAD_WK_SYN     → ubmad_process_wk_syn()
    ├── UBMAD_WK_SYN_ACK → ubmad_process_wk_syn_ack()
    ├── UBMAD_WK_ACK     → ubmad_process_wk_ack()
    ├── UBMAD_WK_FIN     → ubmad_process_wk_fin()
    └── UBMAD_WK_FIN_ACK → ubmad_process_wk_fin_ack()
```

---

## 18. 未决设计问题

下面这些问题在 v3 中**未做决定**，需要设计作者（或上层 stakeholder）拍板后再进入实现阶段。每个问题都标了影响范围，便于评估优先级。

### 18.0 [CRITICAL] 数据平面缺失

**问题**：§0.1 把本设计定位为"在 UTP 之上提供类 TCP 的可靠通道"，但 v1 API 表面只有 `ubmad_wk_connect / ubmad_wk_listen / ubmad_wk_close`——**没有** `ubmad_wk_send(session, buf, len)` 这样的数据发送 API。会话建立到 `ESTABLISHED` 之后，上层除了"知道连接已建立"以外做不了别的事。

这与 TCP/IP 类比的承诺有出入：TCP 的核心价值是 `send/recv` 的可靠字节流，不只是建链。

**两种解决思路**：

**思路 A：v1 只做控制平面，v2 加数据平面**
- v1 约定上层只用 `ubmad_wk_session` 作为"连接已就绪"信号，建链后实际数据走其他通道（例如双方协商的普通 jetty 上的 RC 连接）。
- v2 才追加 `ubmad_wk_send / ubmad_wk_recv`，引入 SEQ/ACK/window，把会话变成真正的可靠流。
- **代价**：v1 的实用价值有限，§0.1 §0.7 的多消费者承诺要打折扣。
- **好处**：v1 范围可控，可以先验证状态机和会话管理机制。

**思路 B：v1 直接做最小数据平面**
- 在 v1 加一组 API：`ubmad_wk_send(session, msg_type=DATA, payload, len)` + `ubmad_wk_recv_register_cb(session, cb)`。
- 数据消息也走 session 级重传（超时未收到 DATA_ACK 则重传），与握手消息共用 `rt_work`。
- 不做窗口/流控，发送方自己管节奏（如同步阻塞、应用层节流）。
- **代价**：实现复杂度上升约 50%，需要新增 `UBMAD_WK_DATA / UBMAD_WK_DATA_ACK` 消息类型和对应的处理器；要处理乱序、重复、合法性校验。
- **好处**：v1 一步到位，承诺与实现一致。

**待定**：选 A 还是 B？如选 A，v1 文档的 §0 应明确说"v1 仅是控制平面，数据由上层另行约定"；如选 B，需要在文档中追加 Step 12「实现数据平面」，并把 16 个核心函数扩展到约 20 个。

**影响**：决定 v1 的实用价值边界；决定文档第二、三、四章的整体框架是否需要重写；决定上层使用者的实际收益。

### 18.1 [HIGH] 具体的 v1 API 消费者是谁

**问题（v3 修订）**：§0.1 已经说清楚整体动机（多实体共享 + 可靠通道封装）。剩下的具体问题是：v1 合入主干时，**至少一个**上层模块要立刻调用 `ubmad_wk_*` API。否则代码合入后会变成"无人使用的接口"，CI 覆盖率低、回归风险积累。

**候选清单**（需挑出至少一个并落地）：
- IPoURMA：在多 EID 场景下，可能需要建立"对端节点已上线"的会话感知。
- SMC-R-over-URMA / USOCK：用 `ubmad_wk_session` 替代当前的 socket 连接初始化握手。
- ubmgr / cluster control plane：节点间健康探测、配置同步通道。
- 自研协议（用户名）：______（待填）

**待定**：哪一个上层模块在 v1 落地时同步迁移过来？

**影响**：决定 `ubmad_wk_connect/listen/close` 的 API 签名细节（如 timeout 是否暴露、callback 模型 vs 阻塞模型）；决定符号导出策略（`EXPORT_SYMBOL` vs `EXPORT_SYMBOL_GPL`）；决定 v1 是放主干还是 staging。

### 18.2 [HIGH] 多 listen 支持的迁移路径

**问题**：v3 限制每设备只有一个 listen（`dev_priv->listen_session` 单字段）。这对 server-side multi-port 模型（一个进程在不同 well-known service 上 listen）不友好。

**v3 处理**：留作 v2 改造，改用 `hlist`。

**待定**：
- 多 listen 的 demux 键应该是什么？仅靠 `session_id` 不够（client 还没分配 session_id 时怎么 demux SYN？）。可能需要在 `ubmad_wk_hdr` 加一个 `service_id` 字段。
- 加字段就是 wire 格式变化——是否打算先冻结 wire 格式？还是 v1 接受此 ABI 不稳定？

**影响**：`struct ubmad_wk_hdr` 的字段集合；wire 格式版本号策略。

### 18.3 [MEDIUM] TIME_WAIT 与 `ubcore_max_retry_cnt` 解耦

**问题**：§0.3 说明 `UBMAD_WK_TIME_WAIT_MS = 4000` 是手算的 `ubcore_max_retry_cnt = 11` 累计值。如果将来这个 module param 默认值变化，TIME_WAIT 不会自动跟随，会出现"对端 MSN 仍在重传，本端 TIME_WAIT 已结束、session_id 已重用"的窗口。

**v3 处理**：硬编码 4000，注释说明依赖 MSN 默认值。

**待定**：是否将 TIME_WAIT 改为运行时计算？如：

```c
static unsigned int ubmad_wk_calc_time_wait_ms(void)
{
    unsigned int n = ubcore_max_retry_cnt;
    if (n > 30) n = 30;          /* 防溢出 */
    return (1U << (n + 1)) - 1;  /* 2^(n+1) - 1 */
}
```

**影响**：消除潜在的隐式依赖，但增加一点运行时开销（每次 TIME_WAIT 启动时调一次）。

### 18.4 [MEDIUM] 与 `ubcore_session` 是否需要互通

**问题**：§0.4 明确说 `ubmad_wk_session` 与 `net/ubcore_session.c` 解决不同问题，互不替换。但如果上层使用者**同时**有 `ubcore_session` 和 `ubmad_wk_session`（典型场景：先用 ubcore_session 完成 CREATE_REQ/RESP 交换，建立 vTP；然后在该连接上跑 ubmad_wk_session 的握手），需要约定两者的生命周期关系：

- ubcore_session 完成（vTP 建立）后才能开始 ubmad_wk_session？还是反过来？
- 一方失败时，另一方是否要联动清理？

**v3 处理**：未涉及。

**待定**：是否在 §0 加一段「典型生命周期叠加示例」？

**影响**：API 文档清晰度；上层使用者的错误处理复杂度。

### 18.5 [LOW] 重传退避上限 1000ms 是否合理

Step 7.2 中 `delay_ms = min(2 << session->rt_cnt, 1000UL)`——上限 1000ms。在 `rt_cnt = 9` 时退避就达到 1024ms 被 clamp 到 1000ms；后两次（10、11）也都是 1000ms。等于退化成「最后两次以 1 秒为间隔重试」。

**v3 处理**：保持 1000ms 上限。

**待定**：是否抬高到 2000ms 或 4000ms（与 TIME_WAIT 对齐）？或改为 max(1000, msn_window)？

**影响**：握手失败的最大检测时间（当前约 11s = `2+4+8+16+32+64+128+256+512+1000+1000+1000`）。

### 18.6 [LOW] ISN 生成的随机性等级

`ubmad_gen_isn()` 用 `get_random_u32()`（CRNG）生成 ISN，开销略高于 `prandom_u32()`。在握手频率高的场景下（如 1 万次/秒）可能成为瓶颈。

**v3 处理**：用 `get_random_u32()`，符合"防会话劫持"的安全考量。

**待定**：是否切到 `prandom_u32()` + 进程 PID xor 之类的伪随机？取决于威胁模型——如果攻击者无法注入 WK Jetty 报文（受 EID 鉴权保护），ISN 不需要是 CSPRNG 强度的。

**影响**：CRNG 池压力；高负载下的吞吐。

### 18.7 [LOW] 上层 `connect()` 5 秒超时

`ubmad_wk_connect()` 内部 `wait_for_completion_timeout(5*HZ)`——5 秒超时。这只是握手超时，不包含上层应用语义。

**v3 处理**：硬编码 5 秒。

**待定**：
- 是否暴露为参数（`ubmad_wk_connect(..., int timeout_ms)`）？
- 是否区分"网络超时"（应该重试）和"对端拒绝"（不应重试）？

**影响**：API 易用性；上层重试逻辑的清晰度。

---

_文档结束。如有疑问，优先参考 `umdk_ubmad_wk_jetty_deep_dive.md` 了解 UBMAD 现有发送/接收基础设施的详细实现。_

_v3 修订（2026-05-14）相对 v2 的主要变化_：
- 新增 §0「设计说明（必读）」：动机、与 MSN 的层叠关系、TIME_WAIT 真正含义、与 `ubcore_session` 的层次关系、关键决定速查表
- 新增 §11「Step 11：Kconfig 特性开关」：让本特性可选编译
- 新增 §18「未决设计问题」：列出 7 项需要设计作者拍板的事项
- 修正 §1.3「现有枚举」：补全遗漏的 `UBMAD_CONN_DATA / UBMAD_CONN_ACK / UBMAD_AUTHN_ACK`
- 修正 §3：状态总数 9 → 10
- 修正 `UBMAD_WK_TIME_WAIT_MS` 注释：澄清 4000ms 不是 TCP 风格的 2×MSL，而是 UBMAD MSN 最大重传窗口

_v3.1 修订（2026-05-14）相对 v3 的主要变化_：
- 重写 §0.1「这个设计在解决什么问题」：从"枚举 3 类可能场景"升级为明确动机——把 WK Jetty 改造为**多实体共享 + 可靠通道封装**（类比 TCP/IP 多路复用 + 可靠流），含 TCP/IP 类比表与现有 MSN 分工表
- §0.1 增补「当前不在范围内」小节，明确 v1 不含数据平面、流控、多 service_id
- 新增 §18.0 [CRITICAL]「数据平面缺失」：v1 只有 connect/listen/close，没有 `ubmad_wk_send/recv`；列出"v2 再加" vs "v1 直接加"两条路径供选择
- 重写 §18.1：原"具体的上层消费者是谁"已被 §0.1 部分回答；剩余问题聚焦在「v1 合入时哪个具体上层模块同步迁移过来」

_v3.2 修订（2026-05-14）相对 v3.1 的主要变化_：

外部 reviewer 在 v3 → v3.1 之后做了一轮源码对照，指出 7 项**实现层面**的具体缺陷（与 v3.1 的设计说明无关）。v3.2 全部修复：

| # | 缺陷 | v3.2 修复 |
|---|-----|-----------|
| 1 | **握手永远完不成**：`wk_hdr` 只有单个 `session_id`，但客户端和服务端各自分配本地 ID，对端按错的 ID 查找 → SYN_ACK 永远找不到目标 session | wire 头改为 `(local_session_id, peer_session_id)` 双 ID 对，类比 TCP 端口（§Step 2 §2.5、§0.5、所有 process_wk_* 函数） |
| 2 | **`ubmad_wk_listen()` NULL 解引用**：listen 调用 `ubmad_alloc_session(dev_priv, NULL)`，但 alloc 内部 `session->remote_eid = *remote_eid` | alloc 增加 NULL 判断，LISTEN session 的 remote_eid 置零（§Step 3 §3.7） |
| 3 | **kref 失配**：示例代码在 4 处 `queue_delayed_work` 之前没有 `kref_get`，但 handler 末尾有 `ubmad_put_session`，会跌破 0 触发 use-after-free | 4 处 `queue_delayed_work` 之前都加 `kref_get(&session->kref)`，注释指向 §7.4 规则（§Step 4 connect、§Step 5 process_wk_syn、§Step 6 wk_close、§Step 6 process_wk_fin TIME_WAIT 分支） |
| 4 | **JFS WR 结构体不对**：示例 `wr.complete_enable / wr.src.sge[0]` 对不上真实内核 API；`ubmad_get_send_sge_addr()` 不存在 | 重写 `ubmad_post_send_wk()` 与 `ubmad_datapath.c:680-720` 对齐：栈上 `struct ubcore_sge sge`、`jfs_wr.flag.bs.complete_enable`、`jfs_wr.send.src.sge = &sge`；用现有 `ubmad_alloc_sge()`/`ubmad_free_sge()` 替代不存在的 helper（§Step 4 §4.3） |
| 5 | **tjetty 导入描述错误**：v3 说 `ubmad_get_tjetty()` cache miss 触发异步导入；实际只查缓存 | 注释修正：cache miss 时显式调用 `ubmad_queue_import_work()` 触发异步导入，本次返回 `-EAGAIN` 让会话级 rt_work 重试（§Step 4 §4.3） |
| 6 | **FIN 不可靠**：v3 没有 FIN 重传、没有 FIN_ACK 校验、TIME_WAIT 声称会重发 FIN_ACK 但实现里没有 | `ubmad_wk_close()` 启动 FIN 重传定时器；`rt_work_handler` switch 扩展支持 FIN_WAIT_1/LAST_ACK；`process_wk_fin()` 在 TIME_WAIT 状态收到重传 FIN 时重发 FIN_ACK；`process_wk_fin_ack()` 显式 cancel rt_work（§Step 6、§Step 7） |
| 7 | **构建路径错误**：Step 9 引用不存在的 `ubcore/ubcm/Makefile`；Step 11 引用不存在的 `ubcore/Kconfig` | Step 9 改为 `drivers/ub/urma/ubcore/Makefile` 中 `ubcore-objs` 块加 `ubcm/ubmad_session.o`；Step 11 说明 Kconfig 应放在 `drivers/ub/Kconfig`（方式 A）或新建 `drivers/ub/urma/ubcore/Kconfig` 并 `source` 引入（方式 B） |

外部 reviewer 链接：上述 7 项中的 #1（双 ID 协议）和 #3（kref 配对）属于"如照 v3 实现就跑不起来"的阻塞性 bug；其余 5 项严重性递减但都是必须修。修复后这份文档才真正达到「可照着写代码」的实现指南级别。

_v3.3 修订（2026-05-14）相对 v3.2 的主要变化_：

第二轮外部 reviewer 在 v3.2 上又找出 6 项实现层面的 bug。v3.3 全部修复：

| # | 缺陷（v3.2 残留） | v3.3 修复 |
|---|------|-----------|
| 1 | **Step 1 §1.5 与 §0.2 设计矛盾**：v3 / v3.2 让读者把 WK_* 加进 `ubmad_post_send()` 的资源选择 switch，但握手实际走 `ubmad_post_send_wk()` 直接调 `ubcore_post_jetty_send_wr()`，根本不经过 `ubmad_post_send`。即使加了，下游的 `ubmad_do_post_send()` 内还有第二个 switch（`ubmad_datapath.c:702-718`）只识别 CONN_REQ/CONN_RESP/SINGLE_REQ，遇 WK_* 直接 -EINVAL。 | **删除 §1.5**。Step 1 只剩"在 `ub_mad.h` 加 WK_* 枚举"。重写说明指出删除原因和下游 switch 的限制（§Step 1 §1.5）。 |
| 2 | **虚构的 helper 不存在**：v3.2 引入 `ubmad_alloc_sge() / ubmad_free_sge() / ubmad_queue_import_work()` 三个不在内核里的函数，会编译失败。`ubmad_session_find_by_peer()` 也只用未定义。 | **全部替换为真实 API**：`ubmad_bitmap_get_id` / `ubmad_bitmap_put_id`（参 `ub_mad_priv.h:237`、`ubmad_datapath.c:248,294`）；SGE 地址用 `rsrc->send_seg->seg.ubva.va + UBMAD_SGE_MAX_LEN * sge_idx`（参 `ubmad_datapath.c:254`）；tjetty cache miss 不在底层触发导入而是返回 `-EAGAIN` 给调用方。`ubmad_session_find_by_peer()` 在 §3.8b 给出完整定义（哈希表遍历 + `(remote_eid, remote_session_id)` 二元组匹配）。（§Step 3 §3.8b、§Step 4 §4.3） |
| 3 | **取消定时器漏 put 引用**：`cancel_delayed_work` 成功（work 还在队列里没跑）说明 handler 不会执行也就不会做 `ubmad_put_session`，timer 持有的那个 ref 会泄露。v3.2 的 4 处 cancel 都没补 put。 | 改用 `if (cancel_delayed_work(...)) ubmad_put_session(session);` 模式。§7.4 规则表加补充说明，明确 sync 与非 sync 两种取消方式的 ref 处理差异。涉及 process_wk_syn_ack / process_wk_ack / process_wk_fin_ack 三个函数，共 4 个 cancel 点。 |
| 4 | **`ubmad_wk_close()` 回滚到错的状态**：v3.2 把"被动方 CLOSE_WAIT → LAST_ACK"加上了，但失败回滚仍硬编码 `state = ESTABLISHED`，被动方失败后会跳到错的状态。 | 用局部变量 `prev_state` 保存原状态，失败时 `session->state = prev_state`。 |
| 5 | **FIN_ACK 缺校验**：v3.2 的 FIN 用 `isn=0, ack=0`，FIN_ACK 也无 ack 校验；任何乱序到达的 FIN_ACK 都会被接受。 | session 增加 `local_fin_seq / remote_fin_seq` 字段。`ubmad_wk_close()` 首发 FIN 时 `local_fin_seq = local_isn + 1`（FIN 消耗一个 seq，TCP 风格），重传保持一致。`process_wk_fin()` 记录 `remote_fin_seq = wk_hdr->isn` 后用 `ack = remote_fin_seq + 1` 回 FIN_ACK。`process_wk_fin_ack()` 校验 `wk_hdr->ack == local_fin_seq + 1`，不符则丢弃。 |
| 6 | **`tx_in_queue` 不一致**：v3.2 的 `ubmad_post_send_wk()` 直接 post，没 `atomic_fetch_add(&rsrc->tx_in_queue)`。但完成处理（`ubmad_datapath.c:1230`）会无条件 dec，缺增反减计数最终变负。 | 在 post 之前 `atomic_fetch_add(1, &rsrc->tx_in_queue)`，超过 `UBMAD_TX_THREDSHOLD`（已存在的真实宏）回滚 + 释放 SGE 后返回 -EBUSY；post 失败也回退（mirror `ubmad_datapath.c:276-278,287`）。 |

v3.3 后这份文档的代码示例**应当能编译并跑通完整握手 + 挥手**——所有 helper 都映射到真实内核符号，所有 ref 计数路径都成对，所有协议字段都有发送侧填值和接收侧校验。剩余的开放设计问题（§18）不影响代码正确性，只关乎设计取舍与上层消费者落实。

_v3.4 修订（2026-05-14）相对 v3.3 的主要变化_：

第三轮外部 reviewer 在 v3.3 上又找出 4 项残留 bug。v3.4 全部修复：

| # | 缺陷（v3.3 残留） | v3.4 修复 |
|---|------|-----------|
| 1 | **首次 connect 对未缓存 peer 永远失败**：v3.3 让 `ubmad_post_send_wk()` 在 tjetty cache miss 时返回 -EAGAIN，但 `ubmad_wk_connect()` 收到 -EAGAIN 后立刻 `ubmad_put_session + return`，根本没机会让 rt_work 重试。结果：第一次连接陌生 peer 必败。 | `ubmad_wk_connect()` 在分配 session 之后、迁状态之前**同步调用 `ubmad_import_jetty()`**（已在 ub_mad.c:575 导出，幂等，可睡眠）。导入失败返回 -EHOSTUNREACH。导入成功后首发 SYN 必然命中缓存。如果首发仍因并发驱逐返回 -EAGAIN，rt_work 接管重试。 |
| 2 | **`cancel_delayed_work_sync` ref 泄漏**：v3.3 §7.4 的规则错了——sync 版本只在 work 已经在跑的情况下让 handler 完成 put；如果 work 还在排队，cancel 直接移除、handler 永远不跑、timer ref 泄漏。同步超时分支（connect §4.4）就是这种情况。 | `connect()` 同步超时分支改用：`if (cancel_delayed_work(...)) put; else flush_delayed_work(...);` 模式。§7.4 表头加 v3.4 修订段，把 v3.3 「sync 不需要补 put」的错误说法改正。troubleshooting §"错误四" 同步更新。release_session 中的 `cancel_delayed_work_sync` 加注释说明那里是"应当为 no-op 的保险措施"。 |
| 3 | **§6.5 残留过期 close 副本**：v3.2/v3.3 在 §6.5 留了一个独立的 `ubmad_wk_close()` 实现，沿用 v3.2 的 `UBMAD_WK_FIN, 0, 0` 和硬编码三元回滚。这与 §6.2 的 v3.3 实现完全冲突。 | 删除 §6.5 的代码副本。改成"被动方调用同一个 §6.2 `ubmad_wk_close`"的说明，列出典型调用序列（recv FIN → on_closed 回调 → 上层调 close → ...）。 |
| 4 | **`sge_addr` 类型不一致**：v3.3 用 `void *sge_addr`，但真实内核 `ubmad_datapath.c:241` 用 `uint64_t sge_addr` 搭配按需 cast。类型不一致会让实现者抄代码时困惑或写出错。 | 改 `ubmad_post_send_wk()` 用 `uint64_t sge_addr`；`msg = (struct ubmad_msg *)(uintptr_t)sge_addr;` 显式 cast；`jfs_wr.user_ctx` 和 `sge.addr` 是 uint64_t 字段直接赋值，不需要 cast。完全 mirror 真实模式。 |

到 v3.4 为止，反复出现的实现层 bug 类别（虚构 helper、ref 泄漏、协议字段不闭环、与现有代码模式不对齐）应当全部清零。剩余风险主要在两类：(a) 没人在真实内核上跑过这份代码；(b) §18 的开放设计问题——这两类都不是 doc 修订能解决的。

_v3.5 修订（2026-05-14）相对 v3.4 的主要变化_：

第四轮外部 reviewer 在 v3.4 上找出 4 项问题——两条 API/生命周期、两条协议幂等性。v3.5 全部修复：

| # | 缺陷（v3.4 残留） | v3.5 修复 |
|---|------|-----------|
| 1 | **`ubmad_wk_connect()` 同步成功路径释放 session**：返回类型是 int，成功时 `ubmad_put_session(session)` 后 `return 0`。调用方既拿不到 session 指针（无法后续调 close），且这一 put 可能让 kref 归零并立即释放刚建好的 session。结构性 API 缺陷。 | 函数签名改为 `struct ubmad_wk_session *`。成功时返回 session 指针，**调用方持有 ref**，必须最终调 `ubmad_wk_close(session)` 推进到 CLOSED 状态以触发释放。失败返回 `ERR_PTR(-errno)`，用 `IS_ERR/PTR_ERR` 检查。同步和异步两条路径统一返回这一份指针；async 路径上 session 状态在调用方手里时为 SYN_SENT 或后续被推进。 |
| 2 | **异步模式注释与 v3.4 行为矛盾**：v3.4 引入同步 `ubmad_import_jetty()` 在 SYN 之前。但异步分支的注释仍然说"立即返回"——同步 import 会阻塞约 ~10ms 量级的控制平面 RPC。 | 函数注释更新：明确 tjetty 导入是同步的（不论模式），异步只指代握手 ACK 阶段。给出"如果完全不能阻塞，应在 connect 之前另行预热缓存"的指导，并把这条作为可选的 v2 增强 API（参见 §18）。 |
| 3 | **客户端 ESTABLISHED 状态丢弃重传 SYN_ACK**：标准 TCP 边界场景——客户端发 ACK 后即进入 ESTABLISHED；如果 ACK 路上丢了，服务端在 SYN_RCVD 重传 SYN_ACK；客户端 v3.4 在 ESTABLISHED 状态收到 SYN_ACK 直接 `pr_warn` 后丢弃，不重发 ACK。结果：服务端会一直重传 SYN_ACK 直到 UBMAD_WK_MAX_RETRY 失败。 | `ubmad_process_wk_syn_ack()` 在 ESTABLISHED 状态下识别为重传：先校验 `wk_hdr->isn == session->remote_isn` 且 `wk_hdr->ack == local_isn+1` 确保是同一连接的重传，然后重发 ACK，让服务端能推进到 ESTABLISHED。 |
| 4 | **被动方 CLOSE_WAIT 状态丢弃重传 FIN**：对应于 #3 的对称问题。被动方收 FIN → CLOSE_WAIT → 发 FIN_ACK；FIN_ACK 丢失；主动方在 FIN_WAIT_1 重传 FIN；被动方 v3.4 在 CLOSE_WAIT 状态走到 default 分支 `pr_warn`，不重发 FIN_ACK。 | `ubmad_process_wk_fin()` 增加 CLOSE_WAIT 分支：用首次记录的 `remote_fin_seq` 重发 FIN_ACK（不更新 remote_fin_seq 以防 ISN 边界差异）。不重新触发 on_closed 回调（已在首次 FIN 时回调过）。 |

到 v3.5 为止，握手和挥手两个方向上「ACK 单次丢失」这一类问题都被对称地补全了。这是 TCP 实现里教科书级的边界条件，对应于 RFC 793 中的"FIN_WAIT_2 接收 FIN 重传"、"ESTABLISHED 接收 SYN_ACK 重传"等场景。

剩余 §18 设计问题（数据平面、v1 消费者）依旧未答；这些不会出现在再下一轮代码 review 里，需要 stakeholder 输入。

_v3.6 修订（2026-05-14）相对 v3.5 的主要变化_：

第五轮外部 reviewer 在 v3.5 上找出 3 项问题——一项 API 所有权歧义（仍是 BLOCKER）、一项过期示例代码、一项协议幂等性硬化。v3.6 全部修复：

| # | 缺陷（v3.5 残留） | v3.6 修复 |
|---|------|-----------|
| 1 | **ubmad_wk_close 所有权语义未定**：v3.5 让 connect 返回 session 指针、把 alloc 的 ref 交给调用方，但没说 close 怎么处理这份 ref。`ubmad_wk_close()` 只发 FIN + 排重传，没 put；TIME_WAIT 只 put 自己的 timer ref。结果调用方拿到的那一份 ref 永远不释放——session 永远不会被 free。 | **`ubmad_wk_close()` consume 调用方持有的那一份 ref**（v3.6 选用 close-consume 语义，类比 fclose / close(fd)）。在所有返回路径上都 put：成功路径在排完重传定时器后 put；失败路径（`-EINVAL`、FIN 投递失败）也 put。调用方 MUST NOT 在调 close 之后访问 session 指针。§7.4 ref 表新增对应行；§7.4 v3.6 补充段落详细说明语义和理由。 |
| 2 | **测试示例还在用旧的 int 返回值**：Step 4.4 / Step 10 的两段示例代码（timeout test、client 集成测试）写着 `int ret = ubmad_wk_connect(...)`，与 v3.5 实际签名 `struct ubmad_wk_session *` 不一致——按文档照抄会编译失败。 | 两段示例都改用 `struct ubmad_wk_session *session = ubmad_wk_connect(...)` + `IS_ERR / PTR_ERR` 判断；client 测试同时演示 v3.6 的 `ubmad_wk_close(session)` consume 语义。 |
| 3 | **CLOSE_WAIT/TIME_WAIT 重传 FIN 不校验 isn**：v3.5 在 `ubmad_process_wk_fin()` 加了 CLOSE_WAIT/TIME_WAIT 状态下重发 FIN_ACK 的逻辑，但用的是首次记录的 `remote_fin_seq + 1` 作为 ack；如果第二次到达的 FIN 携带不同的 isn（异常或恶意），我们会错误地给一个不同 FIN 回 ACK。 | CLOSE_WAIT/TIME_WAIT 分支合并并加 isn 校验：先比较 `wk_hdr->isn == session->remote_fin_seq`，相等才重发 FIN_ACK；不等则 warn 并丢弃。这避免给"非首次 FIN" 错误地 ACK，也保护对端的 ack 校验逻辑。 |

到 v3.6 为止，调用方 API 表面（`connect → session pointer; close consumes`）应当无歧义；ref-counting 在所有正常和异常路径上都成对；TCP 风格的重传幂等性（SYN_ACK 重传、FIN 重传）都有正确的状态分支处理。本文档的代码示例**应当能直接编译并照着写实现**。

剩余的不确定性只在两个方面：(a) 没有人在真实内核上跑过这份代码；(b) §18 的开放设计问题（数据平面缺失、v1 消费者）需要 stakeholder 输入。这两类问题都不在 doc review 的能力范围内。

_v3.7 修订（2026-05-14）相对 v3.6 的主要变化_：

第六轮外部 reviewer 在 v3.6 上找出 2 项问题——一项又是 close-consume 引发的 lifetime bug（FIN_WAIT_2 状态没有 ref 持有），一项是 v3.6 自己引入的 isn 校验形同虚设。v3.7 全部修复：

| # | 缺陷（v3.6 残留） | v3.7 修复 |
|---|------|-----------|
| 1 | **FIN_WAIT_2 期间 session 没有 ref 持有**（BLOCKER）：v3.6 让 close 立刻 consume caller ref。FIN_ACK 到达时 process_wk_fin_ack 走 FIN_WAIT_1→FIN_WAIT_2 分支，在解锁后做了 `cancel_delayed_work + put`（消费 timer ref），然后函数末尾的 `ubmad_put_session(session)`（消费 find ref）。此时 caller ref 早已被 close consume 了，**session 没有任何 ref 持有**——hash 表不计 ref，session 会被立即 free。但本端还在 FIN_WAIT_2 等对端的 FIN，session 必须存活。 | process_wk_fin_ack FIN_WAIT_1→FIN_WAIT_2 分支增加：`kref_get + queue_delayed_work(tw_work, FIN_WAIT_2_MS)`——同时充当 (a) FIN_WAIT_2 keep-alive ref 和 (b) "对端永远不发 FIN 时的 30s 超时"（借鉴 Linux tcp_fin_timeout）。process_wk_fin FIN_WAIT_2→TIME_WAIT 分支：先 cancel-then-put 这个 keep-alive，再启动真正的 TIME_WAIT 定时器。tw_work_handler 同时处理 TIME_WAIT 和 FIN_WAIT_2 两种到期场景（语义都是"迁到 CLOSED + put 哈希 ref"，只是日志不同）。新增 `UBMAD_WK_FIN_WAIT_2_MS = 30000` 常量。 |
| 2 | **TIME_WAIT 的 FIN isn 校验自相矛盾**：v3.6 的"record remote_fin_seq"块包含 TIME_WAIT，意味着每次重传 FIN 进来都会先把 remote_fin_seq 覆盖成 wk_hdr->isn；下面的 isn 校验自然永远等于自己。验证形同虚设。 | record 块缩小到只在首次见到 FIN 的两个状态（ESTABLISHED 和 FIN_WAIT_2）记录；CLOSE_WAIT / TIME_WAIT 的重传路径只读取首次记录的值做校验。v3.6 同时把 CLOSE_WAIT 和 TIME_WAIT 合并到同一个 isn-validation 分支，v3.7 之后这套校验真正生效。 |

到 v3.7 为止，session 生命周期在所有路径（ESTABLISHED 主动关闭、CLOSE_WAIT 被动关闭、FIN_WAIT_2 等待对端 FIN、TIME_WAIT 等待重传 FIN、所有失败回滚）都有明确的 ref 持有者，不会出现 use-after-free 或永久泄露；FIN 重传幂等性的 isn 校验真正生效。

剩余风险维持在 v3.6 时的两类：实际编译运行验证 + §18 设计问题。

_v3.8 修订（2026-05-14）相对 v3.7 的主要变化_：

第七轮外部 reviewer 在 v3.7 上找出 2 项问题——一项是 v3.7 reuse tw_work 引入的 state-vs-handler race（MEDIUM），一项是函数表里的描述还停留在 v3.7 之前的"TIME_WAIT-only"。

| # | 缺陷（v3.7 残留） | v3.8 修复 |
|---|------|-----------|
| 1 | **FIN_WAIT_2 → TIME_WAIT 与 tw_work handler 的 race**：v3.7 让 tw_work 同时承担 FIN_WAIT_2 keep-alive 和 TIME_WAIT 清理两种角色。process_wk_fin 进 FIN_WAIT_2 分支时按 `set state=TIME_WAIT → cancel → queue` 顺序操作；如果 cancel 失败（FW2 handler 已经在 spinlock 上等候），handler 解锁后会看到 state==TIME_WAIT 并误以为是 TIME_WAIT 期满，把 session 提前 CLOSED 并 put 哈希 ref——本端漏发 FIN_ACK，对端会一直重传到 MSN 上限。 | 重排顺序：先解锁释放 FW2 timer（**不改 state**）→ cancel-then-put（成功）或 flush_delayed_work（失败时等 handler 跑完）→ 重新加锁、检查 state 是否仍是 FIN_WAIT_2 → 是则改成 TIME_WAIT 继续，否则直接 bail。这样 FW2 handler 看到的 state 永远是 FIN_WAIT_2（合法的"FW2 期满"语义）；如果它先把 session 推到 CLOSED，process_wk_fin 在 recheck 时识别并 bail，不再做 FIN_ACK 投递或 timer 排队。 |
| 2 | **§16 函数表对 ubmad_wk_time_wait_handler 的描述未跟上 v3.7**：v3.7 让该 handler 同时处理 TIME_WAIT 和 FIN_WAIT_2 两种状态的到期，但 §16 表里仍写"TIME_WAIT 超时：将 session 置 CLOSED"。 | §16 第 14 项更新为 "TIME_WAIT / FIN_WAIT_2 共用的超时 handler"，并说明两种触发原因的日志差异。Step 3 §3.7 alloc_session 里关于 tw_work 的注释也补一句双用途说明。 |

到 v3.8 为止，没有再发现明显的"按设计就跑不起来"或"有 race 引发 UAF"的实现层 bug；所有 ref 计数路径成对，所有 timer / state 转换的 race 窗口都被显式 cancel 或 flush 关掉。剩余风险还是 (a) 实际编译运行验证 + (b) §18 设计问题。

_v3.9 修订（2026-05-14）相对 v3.8 的主要变化_：

第八轮外部 reviewer 在 v3.8 上找出 1 项 BLOCKER（release_session 自死锁），其相关的 kref/find race 我顺手修了。

| # | 缺陷（v3.7-3.8 残留） | v3.9 修复 |
|---|------|-----------|
| 1 | **`ubmad_release_session()` 自死锁**（BLOCKER）：v3.4 加进去的"保险措施" `cancel_delayed_work_sync(&session->{rt,tw}_work)` 在常规 TIME_WAIT / FIN_WAIT_2 路径里会死锁——handler 末尾的 `ubmad_put_session(session)` 是 timer ref 的最后一份 put，触发 release_session；release_session 在 handler 上下文里反过来 sync-cancel 自己等着的那个 work，等于"自己等自己跑完"。 | 删除 release_session 里两个 `cancel_delayed_work_sync` 调用。改用注释明确 invariant：每个 queue_delayed_work 都有配对的 kref_get；每个成功的 cancel 都补 put；handler 末尾 put——这套约束成立时 kref 归零等价于"没有 pending 的 work"，sync-cancel 是无操作但风险是死锁，索性删掉。如果担心未来代码破坏 invariant，可以加 `WARN_ON(delayed_work_pending(...))` 调试，而不是 cancel-sync 兜底。 |
| 2 | （顺手修）**`find_by_id` / `find_by_peer` 可能复活 ref==0 的 session**：哈希表不计 ref。如果某线程持最后一份 ref 做 kref_put、kref 归零、release_session 排队等本函数的 spin_lock，本函数刚好在锁内查到这个 session 用 `kref_get` 把 0 拉回 1。release_session 拿到锁后 hash_del + 释放；本函数已经把"复活的"指针返回出去，调用方再 kref_put 时 double-free。 | 改用 `kref_get_unless_zero(&session->kref)`：ref==0 时返回 false，本函数把这条记录当作"未找到"跳过。这是 Linux 内核里"哈希表不计 ref"模式的标准做法。同时更新 §7.4 把 invariant 写得更明显。 |
| 3 | （顺手修）**tw_work_handler 末尾注释错把 timer ref 说成 hash ref**：reviewer 顺手指出。 | 注释改为"释放本 timer 入队前 kref_get 拿的那一份 ref"，并解释这一 put 通常会触发 release_session。 |

到 v3.9 为止，所有已知的 ref-counting / timer / state 交互问题都被显式处理：close-consume 语义清晰；FW2 keep-alive 与 TIME_WAIT 复用但 race 已关；find_by_* 防复活；release 不会自死锁。代码示例应当能在生产质量的标准下编译并跑通完整生命周期。

剩余风险维持：实际编译运行验证 + §18 设计问题。
