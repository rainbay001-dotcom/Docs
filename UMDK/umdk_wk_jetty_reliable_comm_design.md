# 公知Jetty可靠通信设计文档（三次握手 / 四次挥手）

_面向读者：对 UMDK/URMA/UBMAD 代码零基础的新开发者。_
_文档版本：v3（设计说明 + 开发步骤）_
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

URMA 的 WK Jetty（参见 [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md)）当前提供的是**无连接、单消息往返**的控制平面：发起方发 `UBCORE_NET_CREATE_REQ`，对端回 `UBCORE_NET_CREATE_RESP`，结束。两端都不维护"连接"概念。可靠性由 UBMAD 的 MSN+重传机制（`ubmad_datapath.c`，详见 [`umdk_ubmad_wk_jetty_deep_dive.md`](umdk_ubmad_wk_jetty_deep_dive.md) §13）在**单条消息粒度**上保证。

本设计在 UBMAD 层面新增**有状态的连接抽象**，让两端共同维护一个 `ESTABLISHED` 会话生命周期。适用场景：

- **上层协议需要"连接已就绪"信号**：例如某种 SMB/iSCSI-like 的应用层协议，希望在数据传输前确认对端已准备好接收。
- **有序拆除**：两端约定数据传输完毕后再回收资源（类比 TCP FIN-ACK 与 RST 的差别）。
- **会话级流控/计数**：以连接为单位统计重传率、RTT、活跃数等。

> ⚠️ **本设计不是为了让 WK Jetty 本身变成"可靠传输"**——单消息可靠性已经由 MSN 提供。本设计添加的是**会话状态机**，不是字节流可靠传输。

如果你的需求只是"让 WK Jetty 上的某条消息一定能送达"，**不需要本设计**——直接用现有的 `ubmad_post_send()`（走 MSN+重传）即可。

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
| 会话标识 | `session_id`（32 位，IDA 分配），放入 `ubmad_wk_hdr` | 不依赖消息序到达顺序，不依赖 MSN |
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

### 1.5 同步修改：`ubmad_post_send()` 资源选择

文件：`ubmad_datapath.c`，找到 `ubmad_post_send()` 内的 `switch (send_buf->msg_type)` 块（约 `ubmad_datapath.c:795-807`），**新增**：

```c
    case UBMAD_WK_SYN:
    case UBMAD_WK_SYN_ACK:
    case UBMAD_WK_ACK:
    case UBMAD_WK_FIN:
    case UBMAD_WK_FIN_ACK:
        rsrc = &dev_priv->jetty_rsrc[0];   /* 复用 WK ID 1 */
        break;
```

**为什么复用 `jetty_rsrc[0]`？**  
该资源（Jetty ID 1）已有完整的 JFC/JFR/JFS 及预先投递的接收 WQE，底层 TP 连接也已建立。握手消息报文小（< 64 字节），共享通道不会产生拥塞问题。

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
 * ============================================================ */
struct ubmad_wk_hdr {
    uint32_t  isn;        /* Initial Sequence Number（本端） */
    uint32_t  ack;        /* 对端 ISN + 1（三次握手 ACK / 挥手 FIN_ACK 中使用） */
    uint16_t  session_id; /* 会话 ID，用于在接收方查找 session 对象 */
    uint8_t   flags;      /* 预留扩展标志位 */
    uint8_t   reserved;
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

/* ============================================================
 * 核心会话对象
 * 每条公知 Jetty 可靠连接对应一个此对象
 * ============================================================ */
struct ubmad_wk_session {
    /* 哈希链表节点，挂入 ubmad_device_priv.session_hash */
    struct hlist_node       hash_node;

    /* 生命周期引用计数 */
    struct kref             kref;

    /* 本次连接唯一标识（分配时从 ida 取得） */
    uint16_t                session_id;

    /* 当前状态机状态 */
    enum ubmad_wk_session_state state;

    /* 保护 state 字段的自旋锁（状态迁移必须在此锁下进行） */
    spinlock_t              lock;

    /* 本端初始序列号（由 ubmad_gen_isn() 生成） */
    uint32_t                local_isn;

    /* 对端初始序列号（收到 SYN / SYN_ACK 后填入） */
    uint32_t                remote_isn;

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
    session->state       = UBMAD_WK_CLOSED;
    session->dev_priv    = dev_priv;
    session->remote_eid  = *remote_eid;
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

**注意**：`ubmad_wk_syn_rt_work_handler` 和 `ubmad_wk_time_wait_handler` 在 Step 7 中实现；这里先做前向声明（在文件顶部 `static void ubmad_wk_syn_rt_work_handler(struct work_struct *work);`）。

### 3.8 函数五：`ubmad_session_find_by_id()`

```c
/**
 * ubmad_session_find_by_id - 通过 session_id 查找 session
 *
 * 在接收路径中调用（中断上下文之外的工作队列中），
 * 持锁期间对找到的 session 做 kref_get，然后释放锁后安全使用。
 *
 * 返回值：找到返回 session（引用计数已 +1），未找到返回 NULL。
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
            kref_get(&session->kref);
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

    /* 步骤 2：取消定时器（cancel_delayed_work_sync 会等待正在执行的 handler 返回） */
    cancel_delayed_work_sync(&session->rt_work);
    cancel_delayed_work_sync(&session->tw_work);

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
 * @session:     当前会话（提供 remote_eid、session_id 等信息）
 * @msg_type:    要发送的握手消息类型（SYN / SYN_ACK / ACK / FIN / FIN_ACK）
 * @isn:         本端 ISN（SYN 和 SYN_ACK 中填入；ACK/FIN_ACK 中填 0）
 * @ack:         确认号（SYN_ACK 填 remote_isn+1；ACK 填 remote_isn+1；SYN 填 0）
 *
 * 实现原理：
 *   1. 从 send_seg_bitmap 分配一个 SGE 槽位
 *   2. 在 SGE 指向的内存中写入 ubmad_msg 头 + ubmad_wk_hdr
 *   3. 构造 ubcore_jfs_wr，opcode=UBCORE_OPC_SEND，tjetty=对端 WK tjetty
 *   4. 调用 ubcore_post_jetty_send_wr() 投递到硬件发送队列
 *   5. 如果是 SYN 或 SYN_ACK，调用者负责启动重传定时器（Step 7）
 *
 * 返回 0 表示成功，负数表示错误码。
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
    struct ubcore_jfs_wr wr = {};
    struct ubcore_jfs_wr *bad_wr;
    int sge_idx, ret;

    /* 步骤 1：获取对端 WK tjetty（先从缓存取，缓存未命中时触发导入） */
    tjetty = ubmad_get_tjetty(&session->remote_eid, rsrc);
    if (!tjetty) {
        /* 触发异步导入，调用者需重试（或等待 conn_wq 完成后再调用） */
        pr_warn("ubmad_wk: tjetty not ready for eid=%pI6\n",
                session->remote_eid.raw);
        return -EAGAIN;
    }

    /* 步骤 2：从 send_seg_bitmap 分配 SGE 槽位 */
    sge_idx = ubmad_bitmap_get_id(rsrc->send_seg_bitmap);
    if (sge_idx < 0) {
        ubmad_put_tjetty(tjetty);
        return -EBUSY;
    }

    /* 步骤 3：构造 ubmad_msg 头 + ubmad_wk_hdr */
    msg = (struct ubmad_msg *)ubmad_get_send_sge_addr(rsrc, sge_idx);
    msg->version     = UBMAD_MSG_VERSION_0;
    msg->msg_type    = msg_type;
    msg->msn         = session->session_id;   /* 复用 msn 字段传递 session_id */
    msg->payload_len = sizeof(struct ubmad_wk_hdr);
    msg->reserved    = 0;

    wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    wk_hdr->isn        = isn;
    wk_hdr->ack        = ack;
    wk_hdr->session_id = session->session_id;
    wk_hdr->flags      = 0;
    wk_hdr->reserved   = 0;

    /* 步骤 4：构造发送 WR */
    wr.opcode          = UBCORE_OPC_SEND;
    wr.tjetty          = tjetty->tjetty;
    wr.complete_enable = 1;
    wr.user_ctx        = (uintptr_t)ubmad_get_send_sge_addr(rsrc, sge_idx);
    wr.src.sge[0].addr = (uintptr_t)msg;
    wr.src.sge[0].len  = sizeof(*msg) + msg->payload_len;
    wr.src.sge[0].key  = rsrc->send_seg->token_id;
    wr.src.num_sge     = 1;

    /* 步骤 5：投递到硬件发送队列 */
    ret = ubcore_post_jetty_send_wr(rsrc->jetty, &wr, &bad_wr);
    if (ret) {
        ubmad_bitmap_put_id(rsrc->send_seg_bitmap, sge_idx);
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
 * 同步模式（on_established == NULL）：
 *   - 阻塞等待，最多 5 秒
 *   - 返回 0 表示连接成功，负数表示失败
 *
 * 异步模式（on_established != NULL）：
 *   - 立即返回，连接结果通过回调通知
 *   - 连接成功：调用 on_established(session, ctx)
 *   - 连接失败：调用 on_closed(session, -ETIMEDOUT, ctx)
 *
 * 三次握手流程：
 *   1. 分配 session（状态: CLOSED）
 *   2. 获取/导入对端 tjetty（如未缓存，触发 conn_wq 工作项）
 *   3. 生成 local_isn
 *   4. 迁移状态到 SYN_SENT
 *   5. 发送 UBMAD_WK_SYN 消息
 *   6. 启动 SYN 重传定时器
 *   7. 等待 connected completion（收到 SYN_ACK 后由 ubmad_process_wk_syn_ack 发出）
 */
int ubmad_wk_connect(struct ubmad_device_priv *dev_priv,
                     const union ubcore_eid *remote_eid,
                     void (*on_established)(struct ubmad_wk_session *, void *),
                     void (*on_closed)(struct ubmad_wk_session *, int, void *),
                     void *cb_ctx)
{
    struct ubmad_wk_session *session;
    unsigned long timeout;
    int ret;

    /* 步骤 1：分配 session */
    session = ubmad_alloc_session(dev_priv, remote_eid);
    if (IS_ERR(session))
        return PTR_ERR(session);

    /* 步骤 2：注册回调 */
    session->on_established = on_established;
    session->on_closed      = on_closed;
    session->cb_ctx         = cb_ctx;

    /* 步骤 3：生成 local_isn */
    session->local_isn = ubmad_gen_isn();

    /* 步骤 4：迁移状态到 SYN_SENT */
    spin_lock(&session->lock);
    session->state = UBMAD_WK_SYN_SENT;
    spin_unlock(&session->lock);

    /* 步骤 5：发送 SYN
     *  isn = local_isn，ack = 0（无确认） */
    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_SYN, session->local_isn, 0);
    if (ret) {
        ubmad_put_session(session);
        return ret;
    }

    /* 步骤 6：启动 SYN 重传定时器（2ms，指数退避，详见 Step 7） */
    session->rt_cnt = 0;
    queue_delayed_work(session->rt_wq, &session->rt_work,
                       msecs_to_jiffies(2));

    /* 步骤 7：同步等待 */
    if (!on_established) {
        timeout = wait_for_completion_timeout(&session->connected,
                                              msecs_to_jiffies(5000));
        if (!timeout) {
            /* 超时：取消重传，关闭 session */
            cancel_delayed_work_sync(&session->rt_work);
            spin_lock(&session->lock);
            session->state = UBMAD_WK_CLOSED;
            spin_unlock(&session->lock);
            ubmad_put_session(session);
            return -ETIMEDOUT;
        }
        ret = session->result;
        ubmad_put_session(session);
        return ret;
    }

    /* 异步模式：调用者持有 session 引用，由回调负责释放 */
    return 0;
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
/* 测试：验证 connect 在没有对端时超时返回 -ETIMEDOUT */
void test_ubmad_wk_connect_timeout(struct ubmad_device_priv *dev_priv)
{
    union ubcore_eid fake_eid = {};
    int ret;

    /* 填入一个不存在的对端 EID */
    memset(fake_eid.raw, 0xFF, sizeof(fake_eid.raw));

    ret = ubmad_wk_connect(dev_priv, &fake_eid, NULL, NULL, NULL);
    WARN_ON(ret != -ETIMEDOUT);
    pr_info("ubmad_wk: connect timeout test %s\n",
            ret == -ETIMEDOUT ? "PASS" : "FAIL");
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
 * 状态迁移：LISTEN → SYN_RCVD
 *
 * 幂等处理（防止重传 SYN 导致重复创建 session）：
 *   1. 先查找是否已有 session_id 对应的 session
 *   2. 如果已存在且状态为 SYN_RCVD，直接重发 SYN_ACK（不重新分配）
 *   3. 如果不存在，从 listen_session 模板创建新 session
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

    /* 步骤 1：幂等检查——查找已有 session */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->session_id);
    if (session) {
        /* 如果已在 SYN_RCVD 状态，重发 SYN_ACK */
        if (session->state == UBMAD_WK_SYN_RCVD) {
            pr_debug("ubmad_wk: retransmit SYN_ACK for session=%u\n",
                     session->session_id);
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

    /* 步骤 4：记录对端信息 */
    session->remote_isn = wk_hdr->isn;
    session->local_isn  = ubmad_gen_isn();

    /* 步骤 5：状态迁移到 SYN_RCVD */
    spin_lock(&session->lock);
    session->state = UBMAD_WK_SYN_RCVD;
    spin_unlock(&session->lock);

    /* 步骤 6：发送 SYN_ACK
     *   isn = local_isn（本端 ISN）
     *   ack = remote_isn + 1（确认对端的 ISN） */
    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_SYN_ACK,
                              session->local_isn,
                              session->remote_isn + 1);
    if (ret) {
        pr_err("ubmad_wk: send SYN_ACK failed ret=%d\n", ret);
        ubmad_put_session(session);
        return;
    }

    /* 步骤 7：启动 SYN_ACK 重传定时器（2ms，指数退避） */
    session->rt_cnt = 0;
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
 * 状态迁移：SYN_SENT → ESTABLISHED
 *
 * 关键操作：
 *   1. 找到对应 session（通过 wk_hdr->session_id）
 *   2. 验证状态为 SYN_SENT 且 ack 字段正确（ack == local_isn + 1）
 *   3. 取消 SYN 重传定时器
 *   4. 发送 ACK（第三次握手）
 *   5. 迁移到 ESTABLISHED 并唤醒 ubmad_wk_connect() 调用者
 */
static void ubmad_process_wk_syn_ack(struct ubmad_msg *msg,
                                      struct ubcore_cr *cr,
                                      struct ubmad_device_priv *dev_priv)
{
    struct ubmad_wk_hdr *wk_hdr = (struct ubmad_wk_hdr *)msg->payload;
    struct ubmad_wk_session *session;

    /* 步骤 1：查找 session */
    session = ubmad_session_find_by_id(dev_priv, wk_hdr->session_id);
    if (!session) {
        pr_warn("ubmad_wk: SYN_ACK for unknown session=%u\n",
                wk_hdr->session_id);
        return;
    }

    spin_lock(&session->lock);

    /* 步骤 2：校验状态 */
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

    /* 步骤 3：记录对端 ISN */
    session->remote_isn = wk_hdr->isn;

    /* 步骤 4：取消 SYN 重传定时器 */
    cancel_delayed_work(&session->rt_work);   /* 非 sync，避免死锁 */

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

    session = ubmad_session_find_by_id(dev_priv, wk_hdr->session_id);
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

    /* 取消 SYN_ACK 重传定时器 */
    cancel_delayed_work(&session->rt_work);

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
 * ubmad_wk_close - 发起四次挥手（主动关闭）
 *
 * @session: 要关闭的会话
 *
 * 只有在 ESTABLISHED 状态下才允许主动发起 FIN。
 * 被动方处理 FIN 并准备好后，也调用此函数发起自己的 FIN（Step 6.5）。
 *
 * 流程：
 *   1. 验证状态为 ESTABLISHED
 *   2. 迁移到 FIN_WAIT_1
 *   3. 发送 UBMAD_WK_FIN
 */
int ubmad_wk_close(struct ubmad_wk_session *session)
{
    struct ubmad_device_priv *dev_priv = session->dev_priv;
    int ret;

    spin_lock(&session->lock);
    if (session->state != UBMAD_WK_ESTABLISHED) {
        spin_unlock(&session->lock);
        return -EINVAL;
    }
    session->state = UBMAD_WK_FIN_WAIT_1;
    spin_unlock(&session->lock);

    ret = ubmad_post_send_wk(dev_priv, session,
                              UBMAD_WK_FIN, 0, 0);
    if (ret) {
        spin_lock(&session->lock);
        session->state = UBMAD_WK_ESTABLISHED;   /* 发送失败，回滚状态 */
        spin_unlock(&session->lock);
    }
    return ret;
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

    session = ubmad_session_find_by_id(dev_priv, wk_hdr->session_id);
    if (!session)
        return;

    spin_lock(&session->lock);
    old_state = session->state;

    if (old_state == UBMAD_WK_FIN_WAIT_2) {
        /* 场景一：主动方收到对端 FIN */
        session->state = UBMAD_WK_TIME_WAIT;
        spin_unlock(&session->lock);

        /* 发送 FIN_ACK */
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN_ACK, 0, 0);

        /* 启动 TIME_WAIT 定时器（UBMAD_WK_TIME_WAIT_MS = 4000ms） */
        queue_delayed_work(session->rt_wq, &session->tw_work,
                           msecs_to_jiffies(UBMAD_WK_TIME_WAIT_MS));

    } else if (old_state == UBMAD_WK_ESTABLISHED) {
        /* 场景二：被动方收到 FIN */
        session->state = UBMAD_WK_CLOSE_WAIT;
        spin_unlock(&session->lock);

        /* 发送 FIN_ACK */
        ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN_ACK, 0, 0);

        /* 通知上层"对端已关闭，你可以继续发数据，但最终也需要调用 close()" */
        if (session->on_closed)
            session->on_closed(session, 0 /* 正常关闭 */, session->cb_ctx);
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

    session = ubmad_session_find_by_id(dev_priv, wk_hdr->session_id);
    if (!session)
        return;

    spin_lock(&session->lock);
    old_state = session->state;

    if (old_state == UBMAD_WK_FIN_WAIT_1) {
        session->state = UBMAD_WK_FIN_WAIT_2;
        spin_unlock(&session->lock);
        /* 等待对端的 FIN（ubmad_process_wk_fin 处理） */

    } else if (old_state == UBMAD_WK_LAST_ACK) {
        session->state = UBMAD_WK_CLOSED;
        spin_unlock(&session->lock);

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

被动方在 CLOSE_WAIT 状态下，上层调用 `ubmad_wk_close()`：

```c
/* 复用 ubmad_wk_close()，但需要处理 CLOSE_WAIT 状态 */
int ubmad_wk_close(struct ubmad_wk_session *session)
{
    struct ubmad_device_priv *dev_priv = session->dev_priv;
    enum ubmad_wk_session_state new_state;
    int ret;

    spin_lock(&session->lock);
    if (session->state == UBMAD_WK_ESTABLISHED) {
        new_state = UBMAD_WK_FIN_WAIT_1;       /* 主动关闭 */
    } else if (session->state == UBMAD_WK_CLOSE_WAIT) {
        new_state = UBMAD_WK_LAST_ACK;          /* 被动关闭，发自己的 FIN */
    } else {
        spin_unlock(&session->lock);
        return -EINVAL;
    }
    session->state = new_state;
    spin_unlock(&session->lock);

    ret = ubmad_post_send_wk(dev_priv, session, UBMAD_WK_FIN, 0, 0);
    if (ret) {
        /* 回滚状态 */
        spin_lock(&session->lock);
        session->state = (new_state == UBMAD_WK_FIN_WAIT_1)
                         ? UBMAD_WK_ESTABLISHED : UBMAD_WK_CLOSE_WAIT;
        spin_unlock(&session->lock);
    }
    return ret;
}
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

    /* 检查是否仍需重传 */
    if (state != UBMAD_WK_SYN_SENT && state != UBMAD_WK_SYN_RCVD) {
        /* 握手已完成或已失败，不再重传 */
        ubmad_put_session(session);
        return;
    }

    /* 检查重传次数 */
    if (session->rt_cnt >= UBMAD_WK_MAX_RETRY) {
        pr_warn("ubmad_wk: session=%u SYN retransmit limit reached\n",
                session->session_id);

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

    /* 重传对应消息 */
    session->rt_cnt++;
    if (state == UBMAD_WK_SYN_SENT) {
        /* 客户端重传 SYN */
        ret = ubmad_post_send_wk(dev_priv, session,
                                  UBMAD_WK_SYN, session->local_isn, 0);
    } else {
        /* 服务端重传 SYN_ACK */
        ret = ubmad_post_send_wk(dev_priv, session,
                                  UBMAD_WK_SYN_ACK,
                                  session->local_isn,
                                  session->remote_isn + 1);
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
 * ubmad_wk_time_wait_handler - TIME_WAIT 超时处理
 *
 * 在 UBMAD_WK_TIME_WAIT_MS（4000ms）后自动调用。
 * 将 session 状态迁移到 CLOSED 并释放资源。
 *
 * 为什么需要 TIME_WAIT？
 *   最后一个 FIN_ACK 可能因网络丢失导致对端重传 FIN。
 *   TIME_WAIT 确保我们还能响应这些迟到的 FIN（直接重发 FIN_ACK），
 *   避免对端因未收到 FIN_ACK 而一直重传。
 */
static void ubmad_wk_time_wait_handler(struct work_struct *work)
{
    struct delayed_work *dwork = to_delayed_work(work);
    struct ubmad_wk_session *session =
            container_of(dwork, struct ubmad_wk_session, tw_work);

    pr_info("ubmad_wk: session=%u TIME_WAIT expired, releasing\n",
            session->session_id);

    spin_lock(&session->lock);
    if (session->state == UBMAD_WK_TIME_WAIT)
        session->state = UBMAD_WK_CLOSED;
    spin_unlock(&session->lock);

    /* 释放哈希表持有的引用（触发 ubmad_release_session） */
    ubmad_put_session(session);
}
```

### 7.4 定时器引用计数管理

| 场景 | get 时机 | put 时机 |
|------|---------|---------|
| 分配 session | `kref_init`（=1） | — |
| 哈希表插入 | 无额外 get（哈希表不加引用） | `ubmad_release_session` 中移除 |
| `ubmad_alloc_session` 返回给调用者 | 已有的 1 个 | 调用者用完后 `ubmad_put_session` |
| `find_by_id` | `kref_get` | 调用者用完后 `ubmad_put_session` |
| rt_work 入队前 | `kref_get` | `rt_work_handler` 末尾 `put` |
| tw_work 入队前 | `kref_get` | `tw_work_handler` 末尾 `put` |

> **重要**：每次 `queue_delayed_work` 之前必须先 `kref_get`，并在 handler 最后 `kref_put`。否则 session 对象可能在 handler 执行中途被释放。

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

## Step 9：更新 Kconfig 与 Makefile

### 9.1 修改 Makefile

文件：`kernel/drivers/ub/urma/ubcore/ubcm/Makefile`

在现有的 `ubmad_datapath.o` 行后面追加：

```makefile
# 原有条目（示例）
obj-$(CONFIG_UB_URMA) += ub_mad.o ubmad_datapath.o ub_cm.o

# 新增
obj-$(CONFIG_UB_URMA) += ubmad_session.o
```

如果使用了模块聚合（`ubcore-objs`）格式，则：

```makefile
ubcore-objs += ubcm/ubmad_session.o
```

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
    int ret = ubmad_wk_connect(dev_priv, server_eid, NULL, NULL, NULL);
    if (ret == 0)
        pr_info("Client: 3-way handshake complete!\n");
    else
        pr_err("Client: connect failed ret=%d\n", ret);
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

`drivers/ub/urma/ubcore/Kconfig` 和 `drivers/ub/urma/ubcore/Makefile`。

### 11.3 Kconfig 新增项

在 `Kconfig` 末尾追加：

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
| 14 | `ubmad_wk_time_wait_handler()` | `ubmad_datapath.c` | TIME_WAIT 超时：将 session 置 CLOSED 并释放 |
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

**解决**：改用非阻塞的 `cancel_delayed_work()`（不等待 handler 完成），然后在不持锁时调用 `cancel_delayed_work_sync()`，或重新设计以避免锁嵌套。

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

### 18.1 [HIGH] 具体的上层消费者是谁

**问题**：v3 §0.1 列举了三类可能的使用场景（连接就绪信号、有序拆除、会话级流控），但没有指明具体哪个上层模块需要这套机制。如果没有真实需求，整个设计是「为可能的未来留口子」，会增加内核维护面但无实际价值。

**建议**：在合入主干前，至少列出一个**已经存在或确定要做**的上层模块作为消费者。如：
- 是某个 ULP（如 IPoURMA、SMC-R-over-URMA）需要连接生命周期？
- 是某个用户态库需要内核态的连接抽象？
- 还是计划性的 R&D（在这种情况下可以先放在 staging/experimental 目录）？

**影响**：决定是否接受 Step 11 的 Kconfig 默认 `n` 策略；决定是否需要导出符号到 ULP；决定 `ubmad_wk_connect/listen/close` 的 API 签名是否需要适配特定调用方。

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
