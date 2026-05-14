# 公知Jetty可靠通信设计文档

_撰写日期：2026-05-14_

---

## 目录

1. [背景与概述](#1-背景与概述)
2. [核心概念回顾](#2-核心概念回顾)
3. [现有通信机制分析](#3-现有通信机制分析)
4. [三次握手设计（连接建立）](#4-三次握手设计连接建立)
5. [四次挥手设计（连接断开）](#5-四次挥手设计连接断开)
6. [数据结构设计](#6-数据结构设计)
7. [关键函数详细说明](#7-关键函数详细说明)
8. [状态机设计](#8-状态机设计)
9. [可靠性机制](#9-可靠性机制)
10. [实现步骤指南](#10-实现步骤指南)
11. [参考文件索引](#11-参考文件索引)

---

## 1. 背景与概述

### 1.1 需求来源

UMDK（Unified Memory Development Kit）中的公知 Jetty（Well-Known Jetty，简称 WK Jetty）是一种预先约定 ID 的 Jetty 资源，两端无需通过带外（out-of-band）通道交换端点信息，即可互相定位并发送控制消息。

目前 UBMAD/UBCM 已利用公知 Jetty 实现了传输层（TP）链接建立，其消息交互模型为简单的"请求-响应"（CREATE_REQ → CREATE_RESP）两消息交换。

**本文档的目标**：在现有公知 Jetty 基础设施之上，设计并实现面向应用层的**可靠通信协议**，引入：

- **三次握手（Three-Way Handshake）**：可靠地建立一条会话级连接，双方均确认连接可用后再进入数据传输阶段。
- **四次挥手（Four-Way Wave / Connection Teardown）**：可靠地关闭已建立的会话，保证双方数据均完整接收后再释放资源。

### 1.2 设计目标

| 目标 | 说明 |
|------|------|
| 可靠性 | 三次握手确保双方均确认连接；四次挥手确保双方均完成发送 |
| 幂等性 | 重复收到握手/挥手消息不导致状态错误 |
| 复用现有基础设施 | 复用 UBMAD 公知 Jetty（ID 1）、JFC/JFR/JFS、可靠重传机制 |
| 对现有链路建立无侵入 | 新协议为独立的应用层会话，不影响现有 UBCM TP 建立流程 |

---

## 2. 核心概念回顾

### 2.1 公知 Jetty（Well-Known Jetty）

公知 Jetty 的本质是**使用预先约定 ID 创建的 Jetty**，任意两个节点都能在无需握手的情况下计算出对端的 Jetty 端点三元组：

```
(peer_eid, uasid, well_known_id)
```

相关代码位置：

```
kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h:18-21
  #define UBMAD_WK_JETTY_NUM   2
  #define UBMAD_WK_JETTY_ID_0  1U   /* 用于连接控制（CONN_REQ/RESP/SINGLE）*/
  #define UBMAD_WK_JETTY_ID_1  2U   /* 用于认证数据（AUTHN_DATA）*/
```

### 2.2 Jetty 相关对象关系

```
ubcore_device
  └── ubmad_device_priv
        ├── jetty_rsrc[0]  (WK ID = 1)
        │     ├── jfc_s        发送完成队列
        │     ├── jfc_r        接收完成队列
        │     ├── jfr          共享接收资源
        │     ├── jetty        本地公知 Jetty 对象
        │     ├── send_seg     发送段（SGE 池）
        │     ├── recv_seg     接收段（SGE 池）
        │     └── tjetty_hlist 远端 Jetty 缓存（按 EID 哈希）
        └── jetty_rsrc[1]  (WK ID = 2)
              └── ... (同上，用于认证)
```

### 2.3 现有消息类型

```c
/* ub_mad.h */
UBMAD_UBC_CONN_REQ   = 2   /* TP 连接请求 */
UBMAD_UBC_CONN_RESP  = 3   /* TP 连接响应 */
UBMAD_UBC_SINGLE_REQ = 4   /* 单次请求 */
UBMAD_AUTHN_DATA     = 0x10 /* 认证数据 */
UBMAD_CLOSE_REQ      = 0x20 /* 关闭通知 */
```

---

## 3. 现有通信机制分析

### 3.1 现有 TP 建立流程（两消息交换）

当前 UBCM 通过公知 Jetty 进行 TP 建立，交互模型如下：

```
发起方（Initiator）                    响应方（Target）
       │                                      │
       │─── UBCORE_NET_CREATE_REQ ───────────▶│
       │    (UBMAD_UBC_CONN_REQ)              │  ubcore_get_tp_list()
       │                                      │  ubcore_active_tp()
       │◀── UBCORE_NET_CREATE_RESP ───────────│
       │    (UBMAD_UBC_CONN_RESP)             │
       │                                      │
       │  ubcore_session_complete()           │
       │  active_tp_cfg 填充完毕              │
       ▼                                      ▼
```

**关键函数链**（发起方发送侧）：
```
ubcore_exchange_tp_info()
  → send_create_req()
    → ubcore_net_send_to()
      → ubcore_ubcm_send_to()
        → ubcore_call_cm_send_ops()
          → ubmad_ubc_send()
            → ubmad_post_send()
              → ubmad_do_post_send()
                → ubmad_do_post_send_conn_data()
                  → ubcore_post_jetty_send_wr()
```

### 3.2 现有机制的不足

现有 CREATE_REQ / CREATE_RESP 仅用于 TP 元数据交换（PSN、TP 句柄等），不能用于应用层的连接状态管理：

1. **没有明确的连接就绪确认**：响应方发出 RESP 后即认为连接建立，但发起方是否成功处理响应没有反馈给响应方。
2. **没有半关闭状态**：CLOSE_REQ 直接通知关闭，不支持一方结束发送但仍能接收的半关闭语义。
3. **会话状态不对称**：发起方等待响应（阻塞在 `ubcore_session_wait()`），响应方发送完即结束，无双向确认。

---

## 4. 三次握手设计（连接建立）

### 4.1 协议概述

三次握手模拟 TCP 握手语义，确保双方均确认连接可用：

```
发起方（Client）                        响应方（Server）
      │                                        │
      │─── [1] WK_CONN_SYN ──────────────────▶│
      │    seq=ISN_c                           │  进入 SYN_RCVD 状态
      │                                        │
      │◀── [2] WK_CONN_SYN_ACK ───────────────│
      │    seq=ISN_s, ack=ISN_c+1             │
      │  进入 ESTABLISHED 状态                 │
      │                                        │
      │─── [3] WK_CONN_ACK ──────────────────▶│
      │    ack=ISN_s+1                         │  进入 ESTABLISHED 状态
      │                                        │
      ▼    数据传输阶段                         ▼
```

| 消息 | 方向 | 说明 |
|------|------|------|
| WK_CONN_SYN | Client → Server | 发起连接，携带本端初始序列号 ISN_c |
| WK_CONN_SYN_ACK | Server → Client | 确认 SYN，同时发送本端初始序列号 ISN_s |
| WK_CONN_ACK | Client → Server | 确认 SYN_ACK，连接建立完成 |

### 4.2 新增消息类型

在 `ub_mad.h` 中扩展消息类型枚举：

```c
/* 新增：应用层可靠会话消息类型 */
UBMAD_WK_CONN_SYN      = 0x30  /* 三次握手第一步：SYN */
UBMAD_WK_CONN_SYN_ACK  = 0x31  /* 三次握手第二步：SYN+ACK */
UBMAD_WK_CONN_ACK      = 0x32  /* 三次握手第三步：ACK */
UBMAD_WK_FIN           = 0x40  /* 四次挥手第一步：FIN */
UBMAD_WK_FIN_ACK       = 0x41  /* 四次挥手第二/四步：FIN+ACK / ACK */
```

### 4.3 SYN 消息格式

```c
/* 新增结构体：WK Jetty 握手消息头 */
struct ubmad_wk_handshake_msg {
    uint8_t  version;          /* 协议版本，当前为 1 */
    uint8_t  msg_type;         /* 消息类型（UBMAD_WK_CONN_SYN 等）*/
    uint16_t reserved;
    uint32_t session_id;       /* 会话 ID，由发起方生成，全局唯一 */
    uint32_t seq;              /* 本端序列号（ISN）*/
    uint32_t ack;              /* 确认序列号（ack = 对端 seq + 1）*/
    union ubcore_eid src_eid;  /* 发送端 EID */
    union ubcore_eid dst_eid;  /* 目标端 EID */
    uint16_t payload_len;      /* 附加载荷长度（可携带应用元数据）*/
    uint8_t  payload[0];       /* 可变长度载荷 */
};
```

### 4.4 三次握手调用链

#### 4.4.1 发起方发送 SYN

```
ubmad_wk_connect(device, peer_eid, session_cfg)
  → ubmad_alloc_session(session_cfg)       /* 分配会话对象，状态 = CLOSED */
  → ubmad_gen_isn()                        /* 生成初始序列号 ISN_c */
  → ubmad_build_syn_msg(msg, session)      /* 构造 SYN 消息 */
  → ubmad_post_send_wk(device, &msg)       /* 通过 jetty_rsrc[0] 发送 */
      → ubmad_post_send()                  /* 现有发送路径 */
        → ubmad_do_post_send()
          → ubcore_post_jetty_send_wr()
  → session->state = WK_STATE_SYN_SENT    /* 更新状态 */
  → ubmad_wait_session(session, timeout)  /* 等待 SYN_ACK */
```

#### 4.4.2 响应方接收 SYN 并发送 SYN_ACK

```
/* 收到 SYN，在 ubmad_process_msg() 路径中处理 */
ubmad_recv_work_handler()
  → ubmad_process_msg()
    → msg_type == UBMAD_WK_CONN_SYN
    → ubmad_process_wk_syn(cr, rsrc, dev_priv, agent_priv)
        → ubmad_lookup_or_create_session(msg->session_id)
                                           /* 幂等：重复 SYN 不重建会话 */
        → session->state = WK_STATE_SYN_RCVD
        → ubmad_gen_isn()                 /* 生成 ISN_s */
        → ubmad_build_syn_ack_msg(msg, session, isn_c)
        → ubmad_post_send_wk(device, &msg) /* 发送 SYN_ACK */
        → 启动超时定时器（等待第三步 ACK）
```

#### 4.4.3 发起方接收 SYN_ACK 并发送 ACK

```
ubmad_recv_work_handler()
  → ubmad_process_msg()
    → msg_type == UBMAD_WK_CONN_SYN_ACK
    → ubmad_process_wk_syn_ack(cr, rsrc, dev_priv, agent_priv)
        → ubmad_session_find(msg->session_id)
        → 验证 ack == local_isn + 1       /* 防止伪造/重放 */
        → session->peer_isn = msg->seq
        → session->state = WK_STATE_ESTABLISHED
        → ubmad_build_ack_msg(msg, session)
        → ubmad_post_send_wk(device, &msg) /* 发送 ACK */
        → ubmad_session_complete(session)  /* 唤醒等待方 */
```

#### 4.4.4 响应方接收 ACK，连接建立完成

```
ubmad_recv_work_handler()
  → ubmad_process_msg()
    → msg_type == UBMAD_WK_CONN_ACK
    → ubmad_process_wk_ack(cr, rsrc, dev_priv, agent_priv)
        → ubmad_session_find(msg->session_id)
        → 验证 ack == peer_isn + 1
        → session->state = WK_STATE_ESTABLISHED
        → 取消 SYN_ACK 重传定时器
        → 回调上层 on_connected(session)  /* 通知应用层连接就绪 */
```

---

## 5. 四次挥手设计（连接断开）

### 5.1 协议概述

四次挥手保证双方数据均完整交付后再释放资源，支持半关闭（Half-Close）语义：

```
主动关闭方（Active Close）              被动关闭方（Passive Close）
         │                                        │
         │─── [1] WK_FIN ───────────────────────▶│
         │    seq=fin_seq                         │  进入 CLOSE_WAIT 状态
         │                                        │  （仍可向主动关闭方发送数据）
         │◀── [2] WK_FIN_ACK（ACK）──────────────│
         │    ack=fin_seq+1                       │
         │  进入 FIN_WAIT_2 状态                  │
         │                                        │  数据发送完毕
         │◀── [3] WK_FIN（对端 FIN）──────────────│
         │    seq=fin_seq2                        │  进入 LAST_ACK 状态
         │  进入 TIME_WAIT 状态                   │
         │                                        │
         │─── [4] WK_FIN_ACK（ACK）─────────────▶│
         │    ack=fin_seq2+1                      │  进入 CLOSED 状态
         │                                        │
         │  等待 2×MSL 后进入 CLOSED 状态          │
         ▼                                        ▼
```

| 消息 | 方向 | 说明 |
|------|------|------|
| WK_FIN | 主动关闭方 → 被动关闭方 | 通知本端已无数据发送 |
| WK_FIN_ACK | 被动关闭方 → 主动关闭方 | 确认收到 FIN（ACK），被动方可继续发数据 |
| WK_FIN | 被动关闭方 → 主动关闭方 | 被动方数据发送完毕，发出自己的 FIN |
| WK_FIN_ACK | 主动关闭方 → 被动关闭方 | 确认被动方 FIN，进入 TIME_WAIT |

### 5.2 四次挥手调用链

#### 5.2.1 主动关闭方发送 FIN

```
ubmad_wk_close(device, session)
  → 检查 session->state == WK_STATE_ESTABLISHED
  → session->fin_seq = session->local_seq++
  → ubmad_build_fin_msg(msg, session)
  → ubmad_post_send_wk(device, &msg)          /* 发送 FIN */
  → session->state = WK_STATE_FIN_WAIT_1
  → 启动 FIN 重传定时器
```

#### 5.2.2 被动关闭方接收 FIN，发送 ACK

```
ubmad_process_wk_fin(cr, rsrc, dev_priv, agent_priv)
  → ubmad_session_find(msg->session_id)
  → session->state = WK_STATE_CLOSE_WAIT
  → ubmad_build_fin_ack_msg(msg, session, msg->seq + 1)  /* 构造 ACK */
  → ubmad_post_send_wk(device, &ack_msg)                 /* 发送 ACK */
  → 回调上层 on_peer_fin(session)
    /* 上层应用决定何时调用 ubmad_wk_close() 发送己方 FIN */
```

#### 5.2.3 被动关闭方数据发送完毕，发送己方 FIN

```
/* 由上层应用在完成数据发送后主动调用 */
ubmad_wk_close(device, session)
  → 检查 session->state == WK_STATE_CLOSE_WAIT
  → session->fin_seq = session->local_seq++
  → ubmad_build_fin_msg(msg, session)
  → ubmad_post_send_wk(device, &msg)         /* 发送己方 FIN */
  → session->state = WK_STATE_LAST_ACK
  → 启动 FIN 重传定时器
```

#### 5.2.4 主动关闭方接收 FIN，发送最终 ACK

```
ubmad_process_wk_fin(cr, rsrc, dev_priv, agent_priv)
  → 检查 session->state == WK_STATE_FIN_WAIT_2
  → session->state = WK_STATE_TIME_WAIT
  → ubmad_build_fin_ack_msg(msg, session, msg->seq + 1)
  → ubmad_post_send_wk(device, &ack_msg)
  → 启动 TIME_WAIT 定时器（建议 2×MSL，例如 60s）
  → TIME_WAIT 超时后：
      → session->state = WK_STATE_CLOSED
      → ubmad_release_session(session)
```

#### 5.2.5 被动关闭方接收最终 ACK

```
ubmad_process_wk_fin_ack(cr, rsrc, dev_priv, agent_priv)
  → 检查 session->state == WK_STATE_LAST_ACK
  → 取消 FIN 重传定时器
  → session->state = WK_STATE_CLOSED
  → ubmad_release_session(session)
  → 回调上层 on_closed(session)
```

---

## 6. 数据结构设计

### 6.1 会话状态枚举

```c
/* 新增：会话连接状态 */
enum ubmad_wk_session_state {
    WK_STATE_CLOSED       = 0,   /* 初始/已关闭 */
    WK_STATE_LISTEN       = 1,   /* 服务端等待连接 */
    WK_STATE_SYN_SENT     = 2,   /* 客户端已发送 SYN，等待 SYN_ACK */
    WK_STATE_SYN_RCVD     = 3,   /* 服务端已收到 SYN，已发送 SYN_ACK */
    WK_STATE_ESTABLISHED  = 4,   /* 连接已建立，可传输数据 */
    WK_STATE_FIN_WAIT_1   = 5,   /* 主动关闭：已发送 FIN，等待 ACK */
    WK_STATE_FIN_WAIT_2   = 6,   /* 主动关闭：已收到 ACK，等待对端 FIN */
    WK_STATE_CLOSE_WAIT   = 7,   /* 被动关闭：已收到对端 FIN，等待本端数据发完 */
    WK_STATE_LAST_ACK     = 8,   /* 被动关闭：已发送己方 FIN，等待最终 ACK */
    WK_STATE_TIME_WAIT    = 9,   /* 主动关闭：等待 2×MSL 防止旧数据干扰 */
};
```

### 6.2 会话对象

```c
/* 新增：公知 Jetty 可靠会话对象 */
struct ubmad_wk_session {
    uint32_t session_id;                     /* 全局唯一会话 ID */
    enum ubmad_wk_session_state state;       /* 当前状态 */

    union ubcore_eid local_eid;              /* 本端 EID */
    union ubcore_eid peer_eid;               /* 对端 EID */

    uint32_t local_isn;                      /* 本端初始序列号 */
    uint32_t peer_isn;                       /* 对端初始序列号 */
    uint32_t local_seq;                      /* 本端下一个发送序列号 */
    uint32_t peer_ack;                       /* 已确认的对端序列号 */
    uint32_t fin_seq;                        /* 本端 FIN 消息的序列号 */

    struct ubmad_jetty_resource *rsrc;       /* 使用的 WK Jetty 资源（ID 1）*/
    struct ubmad_tjetty *remote_tjetty;      /* 对端 WK 目标 Jetty 缓存 */

    /* 重传定时器 */
    struct delayed_work syn_rt_work;         /* SYN/SYN_ACK 重传 */
    struct delayed_work fin_rt_work;         /* FIN 重传 */
    uint32_t rt_count;                       /* 当前重传次数 */

    /* TIME_WAIT 定时器 */
    struct delayed_work time_wait_work;

    /* 等待/完成同步 */
    struct completion connect_done;          /* 三次握手完成通知 */
    struct completion close_done;            /* 四次挥手完成通知 */
    int connect_result;                      /* 握手结果（0=成功，<0=错误码）*/

    /* 上层回调 */
    void (*on_connected)(struct ubmad_wk_session *session);
    void (*on_peer_fin)(struct ubmad_wk_session *session);
    void (*on_closed)(struct ubmad_wk_session *session);
    void *app_priv;                          /* 上层应用私有指针 */

    struct kref kref;                        /* 引用计数 */
    struct hlist_node node;                  /* 挂入 session_hlist */
};
```

### 6.3 设备私有对象扩展

在 `ubmad_device_priv`（`ub_mad_priv.h:135`）中添加：

```c
/* 在 struct ubmad_device_priv 中新增 */
spinlock_t session_hlist_lock;
struct hlist_head session_hlist[UBMAD_SESSION_HASH_SIZE]; /* session_id 哈希表 */
struct workqueue_struct *session_wq;          /* 握手/挥手工作队列 */
atomic_t next_session_id;                    /* 全局会话 ID 自增计数器 */
```

---

## 7. 关键函数详细说明

本节对新增的关键函数逐一进行详细说明，包括入参、出参、调用时机和内部逻辑。

---

### 7.1 `ubmad_wk_connect()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`（新建）

**函数签名**：
```c
int ubmad_wk_connect(struct ubcore_device *device,
                     const union ubcore_eid *peer_eid,
                     struct ubmad_wk_session_cfg *cfg,
                     struct ubmad_wk_session **out_session);
```

**功能**：作为客户端，向指定对端 EID 发起三次握手，建立应用层可靠会话。

**入参**：
- `device`：本地 ubcore 设备，用于定位 `ubmad_device_priv` 和 `jetty_rsrc[0]`
- `peer_eid`：对端节点的 EID（通过公知 ID 可推导对端 Jetty，无需额外交换）
- `cfg`：会话配置，包含超时时间、最大重传次数、上层回调等
- `out_session`：输出参数，成功时返回已建立的会话指针

**内部逻辑**：
1. 调用 `ubmad_alloc_session()` 分配并初始化 `ubmad_wk_session`，初始状态 = `WK_STATE_CLOSED`
2. 调用 `ubmad_gen_isn()` 生成随机初始序列号 `local_isn`
3. 调用 `ubmad_get_or_import_tjetty()` 获取对端公知 Jetty 的目标句柄（复用现有 `ubmad_get_tjetty()` 路径）
4. 调用 `ubmad_build_syn_msg()` 构造 SYN 消息
5. 调用 `ubmad_post_send_wk()` 将 SYN 发送到对端公知 Jetty ID 1
6. 设置状态 = `WK_STATE_SYN_SENT`，启动 SYN 重传定时器
7. 调用 `wait_for_completion_timeout(&session->connect_done, timeout)` 阻塞等待
8. 超时返回 `-ETIMEDOUT`；握手成功返回 `0`，`*out_session` 指向会话对象

**错误处理**：
- 若 `dev_priv->valid == false`（WK 资源未初始化），立即返回 `-EAGAIN`
- 重传超过 `ubcore_max_retry_cnt` 次后，会话迁移至 `WK_STATE_CLOSED`，`connect_done` 以错误码 `-ECONNREFUSED` 完成

---

### 7.2 `ubmad_wk_listen()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
int ubmad_wk_listen(struct ubcore_device *device,
                    struct ubmad_wk_listen_cfg *cfg);
```

**功能**：将设备置于监听状态，注册上层回调，接受来自任意客户端的三次握手请求。

**内参**：
- `device`：本地 ubcore 设备
- `cfg`：监听配置，包含 `on_connected`/`on_peer_fin`/`on_closed` 回调及 `app_priv`

**内部逻辑**：
1. 将 `cfg` 存入 `dev_priv` 的监听配置字段（新增 `listen_cfg` 成员）
2. 设置设备级别的监听标志 `dev_priv->wk_listening = true`
3. 公知 Jetty 上预投递的接收 WQE（`ubmad_post_recv()` 已在设备初始化时完成）无需额外操作——接收 SYN 时会自动触发

**注意**：本函数是非阻塞的；实际的 SYN 处理由 `ubmad_process_wk_syn()` 在工作队列中完成。

---

### 7.3 `ubmad_alloc_session()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
struct ubmad_wk_session *ubmad_alloc_session(
    struct ubmad_device_priv *dev_priv,
    const union ubcore_eid *local_eid,
    const union ubcore_eid *peer_eid,
    const struct ubmad_wk_session_cfg *cfg);
```

**功能**：分配并初始化一个新的会话对象，插入设备哈希表。

**内部逻辑**：
1. `kzalloc(sizeof(*session), GFP_KERNEL)` 分配内存
2. 使用 `atomic_inc_return(&dev_priv->next_session_id)` 生成唯一 `session_id`
3. 初始化：状态 = `CLOSED`，复制 EID、回调、配置
4. `init_completion(&session->connect_done)`、`init_completion(&session->close_done)`
5. `kref_init(&session->kref)`
6. 在 `dev_priv->session_hlist` 中以 `session_id % UBMAD_SESSION_HASH_SIZE` 为 bucket 插入

---

### 7.4 `ubmad_gen_isn()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static uint32_t ubmad_gen_isn(void);
```

**功能**：生成随机初始序列号（Initial Sequence Number, ISN）。

**内部逻辑**：
```c
return get_random_u32();
```
使用内核随机数生成器，保证每次握手的序列号不可预测，防止会话劫持。

---

### 7.5 `ubmad_build_syn_msg()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_build_syn_msg(struct ubmad_wk_handshake_msg *msg,
                                const struct ubmad_wk_session *session);
```

**功能**：填充 SYN 消息结构体。

**内部逻辑**：
```c
msg->version    = UBMAD_WK_PROTO_VERSION;   /* = 1 */
msg->msg_type   = UBMAD_WK_CONN_SYN;
msg->session_id = session->session_id;
msg->seq        = session->local_isn;
msg->ack        = 0;                         /* SYN 无需 ACK 字段 */
msg->src_eid    = session->local_eid;
msg->dst_eid    = session->peer_eid;
msg->payload_len = 0;
```

---

### 7.6 `ubmad_post_send_wk()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
int ubmad_post_send_wk(struct ubcore_device *device,
                       const struct ubmad_wk_handshake_msg *msg,
                       struct ubmad_wk_session *session);
```

**功能**：封装握手消息并通过现有 `ubmad_post_send()` 路径发送，复用 UBMAD 底层发送机制。

**内部逻辑**：
1. 从 `dev_priv->jetty_rsrc[0]` 的发送段（`send_seg`）中分配一个 SGE 槽位
2. 将 `ubmad_wk_handshake_msg` 写入 SGE 槽位对应的内存区域
3. 构造 `struct ubcore_jfs_wr`：
   - `opcode = UBCORE_OPC_SEND`
   - `tjetty = session->remote_tjetty->tjetty`（已导入的对端公知目标 Jetty）
   - SGE 指向步骤 2 写入的内存
4. 调用 `ubcore_post_jetty_send_wr(rsrc->jetty, &wr, &bad_wr)`
5. 记录发送序列号到重传缓冲区（仅 SYN/FIN 类消息需要重传）

**与现有代码的关系**：
- 此函数不经过 `ubmad_ubc_send()` → `ubcore_call_cm_send_ops()` 路径（那是 TP 建立专用路径）
- 直接操作 `jetty_rsrc[0]`，与 UBCM TP 建立消息共用同一个 WK Jetty ID 1 的物理资源，通过 `msg_type` 字段区分

---

### 7.7 `ubmad_process_wk_syn()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_process_wk_syn(const struct ubcore_cr *cr,
                                  struct ubmad_jetty_resource *rsrc,
                                  struct ubmad_device_priv *dev_priv,
                                  struct ubmad_agent_priv *agent_priv);
```

**功能**：处理接收到的 SYN 消息，完成三次握手第二步（发送 SYN_ACK）。

**调用时机**：由 `ubmad_process_msg()` 在接收工作队列中调用，`msg_type == UBMAD_WK_CONN_SYN`。

**内部逻辑**：
1. 从 `cr->user_ctx` 获取接收到的 `ubmad_wk_handshake_msg`
2. 检查 `dev_priv->wk_listening`，若未监听则丢弃并返回
3. 调用 `ubmad_session_find_by_id()` 查找是否已有同 `session_id` 的会话（幂等处理）：
   - 若已有且状态 == `SYN_RCVD`：重传 SYN_ACK（对端未收到）
   - 若已有且状态 == `ESTABLISHED`：重传 ACK（对端 ACK 丢失）
   - 若无：创建新会话（`ubmad_alloc_session()`），状态 = `WK_STATE_SYN_RCVD`
4. 保存对端 ISN：`session->peer_isn = msg->seq`
5. 生成本端 ISN：`session->local_isn = ubmad_gen_isn()`
6. 构造 SYN_ACK：`ack = msg->seq + 1`，`seq = session->local_isn`
7. 调用 `ubmad_post_send_wk()` 发送 SYN_ACK
8. 启动 SYN_ACK 重传定时器

---

### 7.8 `ubmad_process_wk_syn_ack()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_process_wk_syn_ack(const struct ubcore_cr *cr,
                                      struct ubmad_jetty_resource *rsrc,
                                      struct ubmad_device_priv *dev_priv,
                                      struct ubmad_agent_priv *agent_priv);
```

**功能**：处理 SYN_ACK 消息，完成三次握手第三步（发送 ACK，唤醒发起方）。

**调用时机**：`msg_type == UBMAD_WK_CONN_SYN_ACK`。

**内部逻辑**：
1. `ubmad_session_find_by_id(dev_priv, msg->session_id)`
2. 检查 `session->state == WK_STATE_SYN_SENT`；若不符则丢弃（防重放）
3. 验证 `msg->ack == session->local_isn + 1`；不符则丢弃
4. 取消 SYN 重传定时器
5. 记录对端 ISN：`session->peer_isn = msg->seq`
6. 更新状态：`session->state = WK_STATE_ESTABLISHED`
7. 构造 ACK 消息（`ack = msg->seq + 1`，`seq = session->local_isn + 1`）
8. `ubmad_post_send_wk()` 发送 ACK（ACK 本身不重传）
9. `complete(&session->connect_done)`——唤醒 `ubmad_wk_connect()` 中的等待

---

### 7.9 `ubmad_process_wk_ack()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_process_wk_ack(const struct ubcore_cr *cr,
                                   struct ubmad_jetty_resource *rsrc,
                                   struct ubmad_device_priv *dev_priv,
                                   struct ubmad_agent_priv *agent_priv);
```

**功能**：处理握手第三步的 ACK 消息，服务端确认连接建立完成。

**内部逻辑**：
1. `ubmad_session_find_by_id()` 找到会话
2. 检查状态 `WK_STATE_SYN_RCVD`
3. 验证 `msg->ack == session->local_isn + 1`
4. 取消 SYN_ACK 重传定时器
5. 状态迁移：`session->state = WK_STATE_ESTABLISHED`
6. 若有注册回调：`dev_priv->listen_cfg.on_connected(session)`

---

### 7.10 `ubmad_wk_close()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
int ubmad_wk_close(struct ubcore_device *device,
                   struct ubmad_wk_session *session);
```

**功能**：发起四次挥手，优雅关闭会话。可被主动或被动关闭方调用。

**入参**：
- `device`：本地 ubcore 设备
- `session`：要关闭的会话对象

**内部逻辑**：
1. 根据当前状态决定行为：
   - `WK_STATE_ESTABLISHED` → 主动关闭，发 FIN，状态 = `WK_STATE_FIN_WAIT_1`
   - `WK_STATE_CLOSE_WAIT` → 被动关闭，发己方 FIN，状态 = `WK_STATE_LAST_ACK`
   - 其他状态 → 返回 `-EINVAL`
2. 生成 `session->fin_seq = session->local_seq++`
3. 调用 `ubmad_build_fin_msg()` 构造 FIN 消息
4. `ubmad_post_send_wk()` 发送 FIN
5. 启动 FIN 重传定时器
6. 若调用方希望同步等待：`wait_for_completion_timeout(&session->close_done, timeout)`

---

### 7.11 `ubmad_process_wk_fin()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_process_wk_fin(const struct ubcore_cr *cr,
                                  struct ubmad_jetty_resource *rsrc,
                                  struct ubmad_device_priv *dev_priv,
                                  struct ubmad_agent_priv *agent_priv);
```

**功能**：处理收到的 FIN 消息，执行四次挥手第二步（发送 ACK）和第三步（若为被动关闭方，等待调用 `ubmad_wk_close()`）。

**内部逻辑**：
1. 找到对应会话，验证序列号
2. 构造 FIN_ACK（ACK），立即回复
3. 根据本端当前状态：
   - `WK_STATE_ESTABLISHED`（被动关闭方收到对端 FIN）：
     - 状态 = `WK_STATE_CLOSE_WAIT`
     - 调用 `on_peer_fin(session)` 通知上层
   - `WK_STATE_FIN_WAIT_2`（主动关闭方收到对端 FIN）：
     - 状态 = `WK_STATE_TIME_WAIT`
     - 启动 TIME_WAIT 定时器（`UBMAD_WK_TIME_WAIT_MS`，默认 60000ms）
   - `WK_STATE_FIN_WAIT_1`（同时关闭：双方同时发 FIN）：
     - 状态 = `WK_STATE_TIME_WAIT`
     - 启动 TIME_WAIT 定时器

---

### 7.12 `ubmad_process_wk_fin_ack()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_process_wk_fin_ack(const struct ubcore_cr *cr,
                                      struct ubmad_jetty_resource *rsrc,
                                      struct ubmad_device_priv *dev_priv,
                                      struct ubmad_agent_priv *agent_priv);
```

**功能**：处理 FIN 的 ACK 或最终 ACK，推进四次挥手状态机。

**内部逻辑**：
1. 验证 `msg->ack == session->fin_seq + 1`
2. 取消 FIN 重传定时器（`del_delayed_work_sync(&session->fin_rt_work)`）
3. 根据当前状态：
   - `WK_STATE_FIN_WAIT_1`（主动关闭方收到 FIN 的 ACK）：
     - 状态 = `WK_STATE_FIN_WAIT_2`（等待对端 FIN）
   - `WK_STATE_LAST_ACK`（被动关闭方收到最终 ACK）：
     - 状态 = `WK_STATE_CLOSED`
     - `ubmad_release_session(session)`
     - 调用 `on_closed(session)` 通知上层

---

### 7.13 `ubmad_wk_syn_rt_work_handler()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_wk_syn_rt_work_handler(struct work_struct *work);
```

**功能**：SYN 或 SYN_ACK 的重传定时器回调，在超时后重传握手消息。

**内部逻辑**：
1. 从 `container_of(work, ...)` 获取会话指针
2. 检查当前状态：若已非 `SYN_SENT`/`SYN_RCVD` 则退出（已完成）
3. `session->rt_count++`；若超过最大重传次数：
   - 状态 = `WK_STATE_CLOSED`
   - `session->connect_result = -ECONNREFUSED`
   - `complete(&session->connect_done)` 唤醒等待方
   - 释放会话
4. 否则重传对应消息（SYN 或 SYN_ACK）
5. 重新调度定时器（指数退避：`delay = min(delay * 2, max_delay)`）

---

### 7.14 `ubmad_wk_time_wait_handler()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
static void ubmad_wk_time_wait_handler(struct work_struct *work);
```

**功能**：TIME_WAIT 定时器超时回调，释放主动关闭方的会话资源。

**内部逻辑**：
1. 验证状态 == `WK_STATE_TIME_WAIT`
2. 状态 = `WK_STATE_CLOSED`
3. `complete(&session->close_done)` 唤醒同步等待的 `ubmad_wk_close()`
4. `ubmad_release_session(session)`

---

### 7.15 `ubmad_session_find_by_id()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
struct ubmad_wk_session *ubmad_session_find_by_id(
    struct ubmad_device_priv *dev_priv,
    uint32_t session_id);
```

**功能**：在设备的会话哈希表中查找指定 `session_id` 的会话，返回时持有引用计数。

**内部逻辑**：
```c
spin_lock(&dev_priv->session_hlist_lock);
hash_for_each_possible(dev_priv->session_hlist, session, node,
                       session_id % UBMAD_SESSION_HASH_SIZE) {
    if (session->session_id == session_id) {
        kref_get(&session->kref);
        spin_unlock(&dev_priv->session_hlist_lock);
        return session;
    }
}
spin_unlock(&dev_priv->session_hlist_lock);
return NULL;
```

---

### 7.16 `ubmad_release_session()`

**文件位置**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

**函数签名**：
```c
void ubmad_release_session(struct ubmad_wk_session *session);
```

**功能**：释放会话对象：从哈希表中移除，取消所有待定定时器，释放对端 Jetty 引用，最后释放内存。

**内部逻辑**：
1. 从 `dev_priv->session_hlist` 中 `hlist_del(&session->node)`（加锁）
2. `cancel_delayed_work_sync(&session->syn_rt_work)`
3. `cancel_delayed_work_sync(&session->fin_rt_work)`
4. `cancel_delayed_work_sync(&session->time_wait_work)`
5. 若 `session->remote_tjetty != NULL`：`ubmad_put_tjetty(session->remote_tjetty)`
6. `kfree(session)`

---

## 8. 状态机设计

### 8.1 完整状态转换图

```
                         ┌─────────────────────────────────────────┐
                         │                                         │
                         ▼                                         │
                    ┌─────────┐                                    │
                    │ CLOSED  │◀─────────────────────────┐         │
                    └─────────┘                          │         │
                    主动连接│  被动监听                   │         │
          ubmad_wk_connect()│  ubmad_wk_listen()         │         │
                         │  │                            │         │
          ┌──────────────┘  └──────────────┐             │         │
          │ 发送 SYN                        │             │         │
          ▼                                ▼             │         │
    ┌──────────┐                      ┌─────────┐        │         │
    │ SYN_SENT │                      │ LISTEN  │        │         │
    └──────────┘                      └─────────┘        │         │
    收到 SYN_ACK│                    收到 SYN│            │         │
    验证 ack   │                    发送 SYN_ACK│          │         │
               │                          │             │         │
               ▼                          ▼             │         │
    ┌─────────────────┐           ┌──────────┐          │         │
    │   ESTABLISHED   │◀──────────│ SYN_RCVD │          │         │
    └─────────────────┘ 收到 ACK  └──────────┘          │         │
           │     ▲     验证 ack                          │         │
           │     │                                      │         │
  主动关闭│     │被动关闭                               │         │
  发送 FIN│     │收到对端 FIN                           │         │
           │     │发送 ACK                               │         │
           ▼     │                                      │         │
    ┌────────────┐  ┌──────────────┐                    │         │
    │ FIN_WAIT_1 │  │  CLOSE_WAIT  │                    │         │
    └────────────┘  └──────────────┘                    │         │
    收到 ACK│         │发送己方 FIN                      │         │
           │         ▼                                  │         │
    ┌────────────┐  ┌──────────────┐                    │         │
    │ FIN_WAIT_2 │  │  LAST_ACK   │                     │         │
    └────────────┘  └──────────────┘                    │         │
    收到对端│         │收到最终 ACK                      │         │
    FIN     │         │                                  │         │
    发送 ACK│         └──────────────────────────────────┘         │
           │                   CLOSED                              │
           ▼                                                       │
    ┌────────────┐                                                 │
    │ TIME_WAIT  │─────────────────────────────────────────────────┘
    └────────────┘  2×MSL 超时后进入 CLOSED
```

### 8.2 状态转换事件表

| 当前状态 | 触发事件 | 动作 | 下一状态 |
|---------|---------|------|---------|
| CLOSED | 调用 `ubmad_wk_connect()` | 发送 SYN | SYN_SENT |
| CLOSED | 调用 `ubmad_wk_listen()` | 注册监听 | LISTEN |
| LISTEN | 收到 SYN | 发送 SYN_ACK | SYN_RCVD |
| SYN_SENT | 收到 SYN_ACK（ack有效） | 发送 ACK，唤醒等待 | ESTABLISHED |
| SYN_SENT | SYN 超时（超最大重传） | 通知连接失败 | CLOSED |
| SYN_RCVD | 收到 ACK（ack有效） | 回调 on_connected | ESTABLISHED |
| SYN_RCVD | SYN_ACK 超时（超最大重传） | 释放会话 | CLOSED |
| ESTABLISHED | 调用 `ubmad_wk_close()` | 发送 FIN | FIN_WAIT_1 |
| ESTABLISHED | 收到对端 FIN | 发送 ACK，回调 on_peer_fin | CLOSE_WAIT |
| FIN_WAIT_1 | 收到 ACK（ack = fin_seq+1） | — | FIN_WAIT_2 |
| FIN_WAIT_1 | 收到对端 FIN（同时关闭） | 发送 ACK | TIME_WAIT |
| FIN_WAIT_2 | 收到对端 FIN | 发送 ACK | TIME_WAIT |
| CLOSE_WAIT | 调用 `ubmad_wk_close()` | 发送 FIN | LAST_ACK |
| LAST_ACK | 收到最终 ACK | 释放资源，回调 on_closed | CLOSED |
| TIME_WAIT | 2×MSL 定时器超时 | 释放资源 | CLOSED |

---

## 9. 可靠性机制

### 9.1 SYN/SYN_ACK 重传

握手消息（SYN、SYN_ACK）在发送后启动重传定时器：

```c
/* 默认参数（可通过模块参数调整）*/
#define UBMAD_WK_SYN_RT_INIT_MS   100    /* 初始重传间隔：100ms */
#define UBMAD_WK_SYN_RT_MAX_MS    3200   /* 最大重传间隔：3.2s（指数退避上限）*/
#define UBMAD_WK_SYN_RT_MAX_CNT   6      /* 最大重传次数 */
```

重传工作由 `ubmad_wk_syn_rt_work_handler()` 在 `dev_priv->session_wq` 上执行。

### 9.2 FIN/FIN_ACK 重传

FIN 消息重传参数：

```c
#define UBMAD_WK_FIN_RT_INIT_MS   200
#define UBMAD_WK_FIN_RT_MAX_MS    6400
#define UBMAD_WK_FIN_RT_MAX_CNT   6
```

### 9.3 TIME_WAIT 机制

```c
#define UBMAD_WK_TIME_WAIT_MS     60000   /* 2×MSL = 60秒 */
```

TIME_WAIT 用于吸收网络中残留的旧数据包，防止其干扰新会话。

### 9.4 幂等性保障

| 重复消息 | 处理方式 |
|---------|---------|
| 重复 SYN | 若会话已存在且在 SYN_RCVD：重传 SYN_ACK |
| 重复 SYN_ACK | 若已在 ESTABLISHED：重传 ACK |
| 重复 FIN | 若已在对应等待状态：重传 FIN_ACK |
| 重复最终 ACK | 若已 CLOSED：忽略 |

### 9.5 序列号验证

所有握手/挥手消息在处理前均验证序列号：

```c
/* 验证 SYN_ACK 的 ack 字段 */
if (msg->ack != session->local_isn + 1) {
    pr_warn("ubmad: invalid SYN_ACK ack=%u expected=%u\n",
            msg->ack, session->local_isn + 1);
    return;
}
```

---

## 10. 实现步骤指南

以下是面向新开发者的实现步骤，建议按顺序进行：

### 步骤 1：添加新消息类型（约 1 小时）

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.h`

在现有枚举后添加：
```c
UBMAD_WK_CONN_SYN     = 0x30,
UBMAD_WK_CONN_SYN_ACK = 0x31,
UBMAD_WK_CONN_ACK     = 0x32,
UBMAD_WK_FIN          = 0x40,
UBMAD_WK_FIN_ACK      = 0x41,
```

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h`

添加 `ubmad_wk_handshake_msg` 结构体（参见第 6.1 节）。

### 步骤 2：添加会话数据结构（约 2 小时）

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h`

添加 `ubmad_wk_session_state` 枚举和 `ubmad_wk_session` 结构体（参见第 6.1、6.2 节）。

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad_priv.h`

在 `ubmad_device_priv` 中添加 session 相关字段（参见第 6.3 节）。

### 步骤 3：创建会话管理文件（约 1 天）

**新建文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_wk_session.c`

实现所有第 7 节中列出的函数。建议实现顺序：
1. `ubmad_alloc_session()` / `ubmad_release_session()` / `ubmad_session_find_by_id()`
2. `ubmad_gen_isn()` / `ubmad_build_syn_msg()` 等消息构造函数
3. `ubmad_post_send_wk()`（复用 `jetty_rsrc[0]` 的发送路径）
4. `ubmad_wk_connect()` / `ubmad_wk_listen()` / `ubmad_wk_close()`
5. 各 `ubmad_process_wk_*()` 接收处理函数
6. 重传定时器处理函数

### 步骤 4：接入现有接收路径（约 4 小时）

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ubmad_datapath.c`

在 `ubmad_process_msg()` 函数的消息类型分发 switch 中（约 `ubmad_datapath.c:1110`）添加新消息类型的处理：

```c
case UBMAD_WK_CONN_SYN:
    ubmad_process_wk_syn(cr, rsrc, dev_priv, agent_priv);
    break;
case UBMAD_WK_CONN_SYN_ACK:
    ubmad_process_wk_syn_ack(cr, rsrc, dev_priv, agent_priv);
    break;
case UBMAD_WK_CONN_ACK:
    ubmad_process_wk_ack(cr, rsrc, dev_priv, agent_priv);
    break;
case UBMAD_WK_FIN:
    ubmad_process_wk_fin(cr, rsrc, dev_priv, agent_priv);
    break;
case UBMAD_WK_FIN_ACK:
    ubmad_process_wk_fin_ack(cr, rsrc, dev_priv, agent_priv);
    break;
```

### 步骤 5：初始化与清理（约 2 小时）

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/ub_mad.c`

在 `ubmad_open_device()`（约 `ub_mad.c:1113`）中添加会话哈希表和工作队列的初始化：

```c
spin_lock_init(&dev_priv->session_hlist_lock);
hash_init(dev_priv->session_hlist);
atomic_set(&dev_priv->next_session_id, 1);
dev_priv->session_wq = alloc_workqueue("ubmad_session_%s",
                                        WQ_MEM_RECLAIM, 0,
                                        dev_name(&device->dev));
```

在 `ubmad_release_device_priv()`（约 `ub_mad.c:1086`）中添加清理：

```c
/* 关闭所有未完成的会话 */
ubmad_close_all_sessions(dev_priv);
destroy_workqueue(dev_priv->session_wq);
```

### 步骤 6：添加 Kbuild 规则（约 30 分钟）

**修改文件**：`kernel/drivers/ub/urma/ubcore/ubcm/Makefile`

```makefile
obj-$(CONFIG_UB_CORE) += ubmad_wk_session.o
```

### 步骤 7：编写测试（约 1 天）

推荐使用内核模块方式编写单元测试：

1. **基本握手测试**：同一节点回环（loopback）测试三次握手和四次挥手
2. **重传测试**：使用错误注入模拟丢包，验证重传和幂等性
3. **并发测试**：多线程同时建立会话，验证哈希表和锁的正确性
4. **超时测试**：模拟对端不响应，验证超时回调和资源释放

---

## 11. 参考文件索引

| 文档 | 内容 |
|------|------|
| [`umdk_urma_well_known_jetty.md`](umdk_urma_well_known_jetty.md) | 公知 Jetty 机制概述、IB/TCP 类比、实现层次 |
| [`umdk_ubmad_wk_jetty_deep_dive.md`](umdk_ubmad_wk_jetty_deep_dive.md) | UBMAD WK Jetty 完整深度剖析（资源模型、发送/接收路径、重传、撤销） |
| [`umdk_urma_object_model.md`](umdk_urma_object_model.md) | URMA 对象模型（EID、FE/VFE、Jetty、TP）入门 |
| [`umdk_urma_tp_lifecycle.md`](umdk_urma_tp_lifecycle.md) | TP 生命周期与链接建立：RM 六步流程 |
| [`umdk_urma_rm_vs_rc_code_level.md`](umdk_urma_rm_vs_rc_code_level.md) | RM vs RC 代码级差异 |

### 核心代码文件

| 源文件 | 关键内容 |
|--------|---------|
| `ubcore/ubcm/ub_mad_priv.h` | UBMAD 私有常量、结构体定义 |
| `ubcore/ubcm/ub_mad.h` | UBMAD 公共 API |
| `ubcore/ubcm/ub_mad.c` | UBMAD 生命周期、资源创建、EID 处理 |
| `ubcore/ubcm/ubmad_datapath.c` | UBMAD 发送/接收数据路径、重传、消息分发 |
| `ubcore/ubcm/ub_cm.c` | UBCM 模块粘合层 |
| `ubcore/net/ubcore_cm.c` | UBCM 桥接：net 消息 ↔ CM 消息转换 |
| `ubcore/net/ubcore_comm.c` | 默认控制传输选择 |
| `ubcore/ubcore_connect_adapter.c` | TP 建立请求/响应处理 |
