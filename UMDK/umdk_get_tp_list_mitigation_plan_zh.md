# `get_tp_list` 缓解模块计划

_创建时间：2026-04-28。_

本文档规划一个模块，用于降低 URMA/UDMA 栈中重复调用 `get_tp_list` 带来的
延迟影响。它只是设计和实现计划，不表示该模块已经存在。

源码上下文：

- 用户态 API：`umdk/src/urma/lib/urma/core/urma_cp_api.c`，
  `urma_cmd.c`，`urma_cmd_tlv.c`
- 内核 uAPI handler：`kernel/drivers/ub/urma/uburma/uburma_cmd.c`
- 内核通用 TP API：`kernel/drivers/ub/urma/ubcore/ubcore_tp.c`
- UDMA provider：`kernel/drivers/ub/urma/hw/udma/udma_ctrlq_tp.c`
- UBASE 控制队列：`kernel/drivers/ub/ubase/ubase_ctrlq.c`

---

## 1. 问题

从应用侧看，`urma_get_tp_list()` 像是一个很小的查询，但 UDMA 实现是一条同步
控制面路径：

```text
urma_get_tp_list()
  -> urma_cmd_get_tp_list()
  -> ioctl(URMA_CMD_GET_TP_LIST)
  -> uburma_cmd_get_tp_list()
  -> ubcore_get_tp_list()
  -> udma_get_tp_list()
  -> udma_ctrlq_get_tpid_list()
  -> ubase_ctrlq_send_msg()
  -> wait for management/UE response
```

`udma_ctrlq_set_tp_msg()` 会设置 `need_resp = 1`，因此
`ubase_ctrlq_send_msg()` 会把这个请求作为同步请求处理。
`ubase_ctrlq_wait_completed()` 等待 completion，超时时间来自控制队列配置。
默认超时在 `ubase_ctrlq_queue_init()` 中初始化为
`CTRLQ_TX_TIMEOUT = 3000` ms。

当前 `udma_get_tp_list()` 路径每次都会向控制队列发送
`UDMA_CMD_CTRLQ_GET_TP_LIST`。它随后校验响应，并把每个 TPID 存入
`udev->ctrlq_tpid_table`，但没有用本地查询来避免后续相同请求再次走控制队列。

当应用循环调用 `get_tp_list` 时，例如每个 Jetty 调一次，这个问题最明显。
`urma_perftest` 已经有一个窄场景缓解：

```c
if (cfg->tp_reuse && cfg->trans_mode == URMA_TM_RM && i > 0) {
    ctx->tp_info[i] = ctx->tp_info[0];
    continue;
}
```

这只帮助一个 benchmark 模式，不能保护一般应用，也不能保护重复查询同一个
TP list 的内核侧用户。

---

## 2. 目标

新增一个小的 UDMA 侧 TP-list 缓解模块，同时处理两类延迟来源：

- 首次使用延迟：在应用的第一条热路径 `get_tp_list` 之前，主动创建或获取
  TP list。
- 重复调用延迟：缓存成功响应，并合并并发的相同 miss。

该模块应当：

- 在 EID 发现或 context 创建后，预热可能使用的 local/peer EID 对。
- 按严格请求 key 缓存成功的 `GET_TP_LIST` 响应。
- 合并并发相同 miss，使只有一个 caller 发送控制队列请求。
- 在 TP 状态变化时失效缓存项。
- 暴露 debug counter，用于观察 hit/miss/wait/invalidation 行为。
- 便于运行时关闭，方便 bring-up 和正确性排查。

非目标：

- 不修改 UE/MUE firmware 协议。
- 不修改公开 URMA API。
- 不移除现有 perftest `tp_reuse` 优化。
- 不缓存失败的 `GET_TP_LIST` 响应，除非后续 benchmark 证明 negative cache
  是安全且有用的。
- 在 `flag` 字段的请求 owner 语义被证明前，不假设 module-init 预热对用户态
  caller 一定有效。

---

## 3. 首次创建缓解：TP Warmup

缓存只在 TP list 已经存在，或者第一次慢 miss 已经发生后才有帮助。要缓解首次
创建，模块必须把慢速控制队列往返提前，并从应用关键路径移走。

正确模型是 **预热，而不是消除**：第一次 `UDMA_CMD_CTRLQ_GET_TP_LIST` 仍然
必须在某处发生，因为 management 侧拥有 TPID 分配和选择。缓解方法是在已经知道
足够拓扑信息时异步发起该请求，这样后续应用调用通常就变成本地 cache hit。

### 3.1 Warmup 触发点

使用两个触发点。

1. **Device/EID warmup**，在 `udma_init_eid_table()` 之后。

   `udma_init_dev()` 调用 `udma_init_eid_table()`，后者调用
   `udma_query_eid_from_ctrl_cpu()` 并填充本地 UDMA EID 表。如果此时模块也有
   配置好的 peer-host EID 集合，就可以为 `(local_eid, peer_eid)` 对调度后台
   warmup。

2. **Context/PID warmup**，在用户 context 创建时。

   当前 `udma_get_tp_list()` 会发送一个 24-bit、类似 owner 的 flag：

   ```c
   if (current->flags & PF_KTHREAD)
       tp_cfg_req.flag = UDMA_DEFAULT_PID;
   else
       tp_cfg_req.flag = (uint32_t)current->tgid & UDMA_PID_MASK;
   ```

   module-init work item 运行在内核上下文，因此使用 `UDMA_DEFAULT_PID`。如果
   management 侧把该字段当作进程 ownership，module-init warmup 就不能满足后续
   使用自身 `tgid` 的用户态进程。为避免这个问题，需要添加 context-aware
   warmup hook，在进程已知时运行。它应当为后续 `get_tp_list()` 会使用的同一个
   process key 入队 warmup work。

### 3.2 `udma_init_eid_table()` 的时机和过程

`udma_init_eid_table()` 通过 UDMA device bring-up 到达，而不是直接从
`module_init()` 调用。

正常 probe 路径：

```text
module_init(udma_init)
  -> auxiliary_driver_register(&udma_drv)
  -> Linux auxiliary-driver core matches an aux device
  -> udma_probe()
  -> udma_init_dev()
  -> udma_init_eid_table()
```

reset re-init 路径：

```text
udma_reset_handler(..., UBASE_RESET_STAGE_INIT)
  -> udma_reset_init()
  -> udma_init_dev()
  -> udma_init_eid_table()
```

在 `udma_init_dev()` 内部，`udma_init_eid_table()` 发生在这些步骤之后：

1. `udma_create_dev(adev)` 创建 provider device 对象。
2. `udma_register_event(adev)` 注册事件 handler。
3. `udma_register_workqueue(udma_dev)` 使 UDMA workqueue 可用。
4. `udma_set_ubcore_dev(udma_dev)` 注册或设置 ubcore-facing device。
5. `udma_init_eid_table(udma_dev)` 查询并安装本地 EID。
6. 成功后，`udma_dev->status = UDMA_NORMAL`。

这意味着 `udma_init_eid_table()` 成功返回后，warmup 模块立即拥有两个有用事实：
本地 EID 已知，UDMA workqueue 也已经存在。warmup 应在这个点调度，可以在设置
`udma_dev->status = UDMA_NORMAL` 之前或之后，但不能阻塞 probe。

`udma_init_eid_table()` 本身是 `udma_query_eid_from_ctrl_cpu()` 的包装。
该函数：

1. 构造控制队列消息：
   - opcode `UDMA_CTRLQ_GET_SEID_INFO`
   - service version `UBASE_CTRLQ_SER_VER_01`
   - service type `UBASE_CTRLQ_SER_TYPE_DEV_REGISTER`
   - `need_resp = 1`
   - payload command `UDMA_CMD_CTRLQ_QUERY_SEID` (`0xb5`)
2. 通过 `ubase_ctrlq_send_msg()` 发送，因此这是一个到 control CPU 的同步
   控制队列查询。
3. 校验返回的 `seid_num` 不超过 `UDMA_CTRLQ_SEID_NUM`。
4. 获取 `udma_dev->eid_mutex`。
5. 遍历返回的 EID。
6. 校验每个返回的 `eid_idx` 不超过 `SEID_TABLE_SIZE`。
7. 对每个 entry 调用 `udma_add_one_eid()`。

`udma_add_one_eid()`：

1. 分配 `struct udma_ctrlq_eid_info`。
2. 拷贝返回的 EID 信息。
3. 以 EID index 作为 xarray key，存入 `udma_dev->eid_table`。
4. 对非 UE 设备，通过 `ummu_core_add_eid()` 向 UMMU 注册 EID。
5. 通过 ubcore 派发 `UBCORE_MGMT_EVENT_EID_ADD`。

如果中途失败，`udma_query_eid_from_ctrl_cpu()` 会按反向顺序调用
`udma_del_one_eid()` 回滚本次已添加 entry，然后返回错误。init 失败时，
`udma_init_dev()` 会 unwind ubcore 注册、workqueue 注册、event 注册和 device
创建。

对 first-TP 缓解而言，最早安全的 device-level warmup hook 是：

```c
ret = udma_init_eid_table(udma_dev);
if (ret)
    goto err_init_eid;

udma_tp_cache_schedule_device_warmup(udma_dev);
udma_dev->status = UDMA_NORMAL;
```

实际实现可以在设置 `UDMA_NORMAL` 前后调度 work，但 work function 必须容忍
reset/remove 与之竞争，并且 reset 和 remove 路径必须 cancel/flush warmup。

### 3.3 Warmup 输入

模块需要 peer EID 来源。如果 host EID 在模块初始化时已经知道，可以通过以下机制
之一提供：

- module parameter，带有有界 peer-EID list，用于 bring-up；
- configfs/sysfs/debugfs 写路径，用于动态 peer-EID 更新；
- UVS/topology callback，在 topology set 或 change 时触发；
- 如果部署环境有静态平台或 firmware-provided host EID list，则使用该列表。

除非部署规模很小，不要盲目推导 all-to-all fabric matrix。warmup 应由策略约束：

- 选择 transport mode：按需选择 RM/RC/UM；
- 选择 TP type flag：按需选择 RTP/CTP/UTP/UBOE；
- local EID 子集；
- peer EID 子集；
- 最大并发控制队列请求数；
- retry/backoff budget。

### 3.4 从 UVS / UBSE Topology 获取 Peer EID

对 topology-driven warmup，peer EID 应来自 UVS/ubcore topology map，而不是
`udma_init_eid_table()`。`udma_init_eid_table()` 只安装本地 SEID。peer 侧信息
要等外部 topology source 填充 UVS/ubcore 后才知道。

表面上的 UBSE 路径是：

```text
UBSE / topology producer
  -> uvs_set_topo_info(topo_buf, node_size, node_num)
  -> uvs_ubagg_ioctl_set_topo()
  -> uvs_ubcore_ioctl_set_topo()
  -> ubcore_cmd_set_topo()
  -> g_ubcore_topo_map
```

本地 repo 不包含 UBSE 实现。能说明 UBSE 是上游 topology producer 的证据是
`uvs_set_topo_info()` 中的 size check：

```c
uint32_t size = sizeof(struct urma_topo_node);

if (size != node_size) {
    TPSA_LOG_ERR("node size not match, urma=%u, ubse=%u\n", size, node_size);
    return -EINVAL;
}
```

`uvs_set_topo_info_inner()` 会把同一份 topology 写入 ubagg 和 ubcore：

```text
uvs_ubagg_ioctl_set_topo(topo, topo_num)
uvs_ubcore_ioctl_set_topo(topo, topo_num)
```

topology node 携带 warmup 需要的 EID 材料：

```c
struct urma_topo_ue {
    uint32_t chip_id;
    uint32_t die_id;
    uint32_t entity_id;
    char primary_eid[EID_LEN];
    char port_eid[PORT_NUM][EID_LEN];
};

struct urma_topo_agg_dev {
    char agg_eid[EID_LEN];
    struct urma_topo_ue ues[IODIE_NUM];
};

struct urma_topo_node {
    uint32_t type;
    uint32_t super_node_id;
    uint32_t node_id;
    uint32_t is_current;
    struct urma_topo_link links[IODIE_NUM][PORT_NUM];
    struct urma_topo_agg_dev agg_devs[DEV_NUM];
};
```

warmup 模块不应自己扫描这份 topology 并直接配对 raw EID，除非它完全复制 ubcore
route logic。优先使用现有 route helper，因为这些 helper 会把 bonding/aggregate
EID 转换为正确配对的 primary EID 和 port EID。

用户态模型：

```c
uvs_route_t route = {
    .src = local_agg_eid,
    .dst = peer_agg_eid,
};
uvs_route_list_t routes = {0};

ret = uvs_get_route_list(&route, &routes);
if (ret == 0) {
    for (uint32_t i = 0; i < routes.len; i++) {
        local_eid = routes.buf[i].src;
        peer_eid = routes.buf[i].dst;
    }
}
```

内核侧模型：

```c
struct ubcore_route route = {
    .src = local_agg_eid,
    .dst = peer_agg_eid,
};
struct ubcore_route_list routes = {0};

ret = ubcore_get_route_list(&route, &routes);
if (ret == 0) {
    for (uint32_t i = 0; i < routes.route_num; i++) {
        get_tp_cfg.local_eid = routes.buf[i].src;
        get_tp_cfg.peer_eid = routes.buf[i].dst;
        /* schedule warmup for this pair */
    }
}
```

`ubcore_get_route_list()` 先追加 primary-EID pair，再根据 topology link 追加
port-EID pair。对于跨节点 direct route，port pair 来自 source port link：

```text
src = src_agg_dev->ues[iodie_id].port_eid[port_id]
dst = dst_agg_dev->ues[iodie_id].port_eid[peer_port_id]
```

对于 path-aware warmup，`uvs_get_path_set()` / `ubcore_get_path_set()` 返回
path set，其中 entry 已经包含 `src_eid` 和 `dst_eid`：

```c
struct ubcore_path {
    union ubcore_port_id src_port;
    union ubcore_port_id dst_port;
    union ubcore_eid src_eid;
    union ubcore_eid dst_eid;
};
```

普通 `(local_eid, peer_eid)` warmup 使用 route-list 输出即可。只有当 warmup
策略需要 per-path port selection、multipath 行为或 topology-specific filtering
时，才使用 path-set 输出。

实际 warmup source sequence：

1. 等待 `ubcore_cmd_set_topo()` 创建或更新 `g_ubcore_topo_map`。
2. 从 topology 或 device policy 中识别当前/local aggregate EID。
3. 从 `is_current == 0` 的 topology node 中枚举 peer aggregate EID，或使用
   UBSE/admin 提供的 peer 子集。
4. 对每个 `(local_agg_eid, peer_agg_eid)` 调用 `ubcore_get_route_list()`。
5. 对每个返回的 physical/primary/port EID pair 调度 warmup。
6. topology 更新时重新运行 warmup 或失效旧 warmup/cache。

如果 warmup 代码位于 UDMA 内部，它应通过 admin/topology integration path 获取
peer aggregate-EID list，然后调用内核 ubcore route helper。它不应直接调用用户态
UVS API。

### 3.5 Warmup API

在拟议模块中加入显式 warmup 调用：

```c
int udma_tp_cache_warmup_pair(struct udma_dev *udev,
                              const union ubcore_eid *local_eid,
                              const union ubcore_eid *peer_eid,
                              const struct udma_tp_warmup_policy *policy,
                              u32 owner_key);

int udma_tp_cache_schedule_warmup(struct udma_dev *udev,
                                  const struct udma_tp_warmup_plan *plan);

void udma_tp_cache_cancel_warmup(struct udma_dev *udev);
```

`owner_key` 必须显式传入。对 device/EID warmup，可以是 `UDMA_DEFAULT_PID`。
对 context warmup，必须是普通用户态调用会发送的同一个
`current->tgid & UDMA_PID_MASK` 值。

### 3.6 Warmup 执行

warmup 应运行在专用或现有 UDMA workqueue 上，不能 inline 在 probe 或 context
creation 中。probe 和 context creation 只应入队 work，然后返回。

每个 key 的 warmup 流程：

1. 构造后续 `get_tp_list` 调用会构造的同一个 cache key。
2. 在发送控制队列请求前，插入一个 `filling` cache entry。
3. 调用现有 slow path 一次。
4. 把成功响应存入 cache 和 `ctrlq_tpid_table`。
5. complete waiters。
6. 失败时，用同一个错误 complete waiters，并删除失败 entry。

这意味着如果应用与 warmup 竞争，应用会等待 in-flight warmup entry，而不是发送
重复控制队列请求。

### 3.7 Owner 语义决策

在依赖 module-init warmup 来降低用户态延迟前，需要确认 MUE/management 侧如何
解释 `tp_cfg_req.flag`。

可能结果：

- **Flag 只是 hint 或 default namespace。** 使用 `UDMA_DEFAULT_PID` 的
  device/EID warmup 可以填充真实 TP 资源，后续 process-specific call 也可以复用，
  但只有在证明后才能放宽 cache-key 策略。
- **Flag 是 process ownership。** Device/EID warmup 只帮助 kernel/default
  owner 用户。用户态 first-call 缓解必须发生在 context creation，或者需要
  firmware/API 扩展来为指定 owner precreate。
- **Flag 选择 isolation 和 resource accounting。** PID 必须保留在 cache key 中，
  且绝不能把 module-init entry 复用于用户态。生产路径应使用 context warmup。

在被证明前，假设它是 process ownership，并保持严格 cache key。

### 3.8 Firmware/API 扩展选项

如果严格需求是“在 module initialization 时为未来用户态进程创建所有 first TP
list”，当前 API 可能不够，因为 owner 隐含在 `current` 中。干净的扩展方式之一是：

- 新增一个 kernel-internal precreate command，携带显式 owner key；
- 新增 management 侧支持的 shared/global TP-list owner namespace；
- 新增 userspace/admin prewarm API，在目标进程下运行，或在显式选择的 owner
  namespace 下运行。

没有这些扩展时，module-init prewarming 只能安全地 precreate default-owner TP
list。

---

## 4. 模块边界

把它实现为内核 UDMA provider 内的源文件模块，而不是独立的 Linux loadable
module。

建议文件：

```text
kernel/drivers/ub/urma/hw/udma/udma_tp_cache.c
kernel/drivers/ub/urma/hw/udma/udma_tp_cache.h
```

集成点：

- 在 `struct udma_dev` 中添加 cache state。
- 在 UDMA device initialization 中初始化它。
- 在 UDMA device teardown/reset cleanup 中销毁它。
- 把 `udma_get_tp_list()` 内的直接调用替换为
  `udma_tp_cache_get_or_fetch()`。
- 在 `udma_init_eid_table()` 成功后，调度可选 device/EID warmup。
- 在用户态 context 创建时，调度可选 context/PID warmup。
- 在 TPID state 被 remove、deactivate 或 replace 的地方添加 invalidation hook。

保留当前 slow path。cache module 应调用现有
`udma_ctrlq_get_tpid_list()` miss path，而不是重复实现 message packing 或控制队列
逻辑。

---

## 5. Cache Key

key 必须保守。它应包含所有可能改变返回 TP list 的字段：

- 请求使用的 process identity：
  - kernel thread 使用 `UDMA_DEFAULT_PID`
  - user caller 使用 `current->tgid & UDMA_PID_MASK`
- canonical transport selector：
  - `udma_ctrlq_get_trans_type()` 后的 `trans_type`，或 CTP override
  - link mode：UB vs UBOE
- 原始 `ubcore_get_tp_cfg` selector：
  - `cfg->flag.value`
  - `cfg->trans_mode`
  - `cfg->local_eid`
  - `cfg->peer_eid`

建议 key struct：

```c
struct udma_tp_cache_key {
    u32 pid_key;
    u32 flag_value;
    u32 trans_mode;
    u32 trans_type;
    u32 link_mode;
    u8 local_eid[UDMA_EID_SIZE];
    u8 peer_eid[UDMA_EID_SIZE];
};
```

使用与控制队列请求相同的 endian-normalized EID 形式，这样 cache comparison 与
management 侧实际收到的内容一致。

---

## 6. Cache Value

存储完整的成功响应，而不只是一个 TP handle：

```c
struct udma_tp_cache_entry {
    struct hlist_node node;
    struct udma_tp_cache_key key;
    struct completion fill_done;
    refcount_t refs;
    bool filling;
    int fill_result;
    unsigned long created_jiffies;
    struct udma_ctrlq_tpid_list_rsp rsp;
};
```

响应很小：`UDMA_MAX_TPID_NUM` 当前为 5，每个 TPID entry 包含 `tpid`、
`tpn_start`、`tpn_cnt` 和 migration bit。保存完整响应可以让 cache 独立于当前
caller 请求的 `tp_cnt`；最终拷贝到 `struct ubcore_tp_info` 时仍然按 caller 容量
进行限制。

---

## 7. Lookup 和 Single-Flight

使用 mutex 保护 hash table。mutex 是可接受的，因为 miss path 可能分配内存，
且 `get_tp_list` 本来就可能在控制队列等待中睡眠。

lookup 行为：

1. 从 `udev`、`tpid_cfg` 和当前 task identity 构造 cache key。
2. 如果 caching 被关闭，调用现有 slow path。
3. 获取 cache mutex 并查找 key。
4. 如果存在完整且未过期的 entry，把响应拷贝给 caller。
5. 如果 entry 存在但仍在 filling，获取引用，释放 mutex，然后等待 `fill_done`。
6. 如果 entry 不存在，插入一个 `filling` entry，释放 mutex，并执行现有
   `udma_ctrlq_get_tpid_list()` slow path。
7. 把结果存入 entry，complete `fill_done`，然后为原始 caller 拷贝响应。

这可以防止 N 个线程请求同一个 `(pid, flags, trans mode, local EID, peer EID)`
tuple 时发送 N 条控制队列消息。

---

## 8. Freshness 和 Invalidation

正确性比 hit rate 更重要。使用显式 invalidation 加短 TTL。

配置：

```text
udma_tp_cache_enable=0|1
udma_tp_cache_ttl_ms=<milliseconds>
udma_tp_cache_max_entries=<count>
udma_tp_warmup_enable=0|1
udma_tp_warmup_mode=device,context,both
udma_tp_warmup_max_inflight=<count>
```

建议 rollout 默认值：

- 第一版 patch：默认关闭，启用时 TTL 1000 ms。
- 在 owner semantics 被验证前，默认关闭 warmup。
- 验证后：只有在 create/import/bind/deactivate/reset stress 下 TP lifecycle 测试
  通过，才考虑默认启用。

显式 invalidation hook：

- `udma_ctrlq_erase_one_tpid()` 运行时，使包含该 TPID 的 entry 失效。
- remove/deactivate TP 操作成功时，使包含该 TPID 的 entry 失效。
- UDMA reset、device teardown 或 UE/MUE re-registration 时 flush 全部 entry。
- 如果有可靠 context-destroy hook，在 process-scoped context 销毁时，按 process
  identity flush entry。

TTL 规则：

- 超过 `udma_tp_cache_ttl_ms` 的 entry 被视为 stale，并重新 fetch。
- TTL 为 `0` 应表示“不复用 TTL entry”；保留 single-flight 行为，但不服务已完成
  cache entry。

---

## 9. Public Internal API

Header sketch：

```c
int udma_tp_cache_init(struct udma_dev *udev);
void udma_tp_cache_destroy(struct udma_dev *udev);

int udma_tp_cache_get_or_fetch(struct udma_dev *udev,
                               struct ubcore_get_tp_cfg *cfg,
                               uint32_t *tp_cnt,
                               struct ubcore_tp_info *tp_list);

void udma_tp_cache_invalidate_tpid(struct udma_dev *udev, u32 tpid);
void udma_tp_cache_flush(struct udma_dev *udev);
void udma_tp_cache_flush_pid(struct udma_dev *udev, u32 pid_key);

int udma_tp_cache_schedule_device_warmup(struct udma_dev *udev);
int udma_tp_cache_schedule_context_warmup(struct udma_dev *udev, u32 pid_key);
void udma_tp_cache_cancel_warmup(struct udma_dev *udev);
```

`udma_tp_cache_get_or_fetch()` 应返回与当前 `udma_get_tp_list()` 实现相同的错误码。

---

## 10. `udma_get_tp_list` 集成细节

当前形态：

```c
ret = udma_ctrlq_get_tpid_list(udev, &tp_cfg_req, tpid_cfg, &tpid_list_resp);
...
for (i = 0; i < tpid_list_resp.tp_list_cnt; i++) {
    tp_list[i].tp_handle.bs.tpid = tpid_list_resp.tpid_list[i].tpid;
    ...
}
*tp_cnt = tpid_list_resp.tp_list_cnt;
ret = udma_ctrlq_store_tpid_list(...);
```

目标形态：

```c
ret = udma_tp_cache_get_or_fetch(udev, tpid_cfg, tp_cnt, tp_list);
```

cache module 内部应当：

- 以当前代码相同方式构造 `tp_cfg_req.flag`；
- 调用现有控制队列 miss function；
- 保留当前校验规则：
  - 拒绝 `tp_list_cnt == 0`
  - 拒绝 `tp_list_cnt > *tp_cnt`
  - 如果现有响应校验要求，拒绝 migration
- 对新 fetch 的响应调用 `udma_ctrlq_store_tpid_list()`。

如果 cached response 中的 TPID 已经存在于 `ctrlq_tpid_table`，
`udma_ctrlq_store_one_tpid()` 已经把这种情况视为成功。

---

## 11. 可观测性

在 `struct udma_tp_cache` 中添加 counter：

- `lookup_cnt`
- `hit_cnt`
- `miss_cnt`
- `stale_cnt`
- `singleflight_wait_cnt`
- `singleflight_error_cnt`
- `insert_cnt`
- `evict_cnt`
- `invalidate_tpid_cnt`
- `flush_cnt`
- `ctrlq_fetch_cnt`
- `ctrlq_fetch_error_cnt`
- `warmup_queued_cnt`
- `warmup_started_cnt`
- `warmup_success_cnt`
- `warmup_error_cnt`
- `warmup_cancel_cnt`
- `warmup_race_wait_cnt`

如果已有 UDMA debug surface 可用，通过它暴露 counter。如果没有合适的
debugfs/sysfs surface，先使用由现有 `debug_switch` gate 的 rate-limited debug
log，后续 patch 再增加真实 readout。

还应在以下位置添加 tracepoint 或临时时间日志：

- cache lookup start/end；
- control-queue fetch start/end；
- wait-on-inflight start/end。

第一轮性能证明应比较 `ctrlq_fetch_cnt` 与 application-level
`urma_get_tp_list()` 调用次数。

---

## 12. 测试计划

cache logic 的 Unit/KUnit 测试：

- key equality 和 hashing；
- TTL expiry；
- capacity eviction；
- 按 TPID invalidation；
- single-flight success；
- single-flight failure propagation；
- caller capacity 小于 cached `tp_list_cnt`。

功能测试：

- 使用已知 local/peer EID 做 Device/EID warmup：验证后续第一个
  `UDMA_DEFAULT_PID` 的 `get_tp_list` 是 cache hit。
- Context/PID warmup：创建 context，等待 warmup 完成，然后验证第一个用户态
  `get_tp_list` 对该 process key 是 cache hit。
- Race test：在同 key warmup in flight 时启动用户态 `get_tp_list`；验证只发送一条
  控制队列 fetch。
- 不使用 `tp_reuse` 的现有 `urma_perftest`：验证重复相同调用在第一次后 hit cache。
- 使用 `tp_reuse` 的现有 `urma_perftest`：验证行为不变。
- 多线程相同 local/peer EID 查询：验证只发送一条控制队列 fetch。
- 不同 peer EID：验证 distinct miss，且没有 cross-contamination。
- 不同 PID/process：验证 entry 不会跨 process identity 泄漏，除非这是显式意图。
- Module-init warmup versus userspace PID：验证 `UDMA_DEFAULT_PID` warm entry 是否
  真的能满足 process-keyed call。如果不能，保持严格 isolation。
- Deactivate/remove TP 后重新 query：验证不会返回 stale TPID。
- Device reset 或 UDMA teardown：验证之后 cache 为空。

性能测试：

- 测量用户态 `urma_get_tp_list()` 周围的 per-call latency。
- 分别测量无缓解、仅 cache、device/EID warmup、context/PID warmup 下的 first-call
  latency。
- 测量内核中 `ubase_ctrlq_send_msg()` 花费的时间。
- 记录 hit/miss counter。
- 比较 `jetty_num = 1, 8, 64, 128` 下有无 cache 的结果。
- 通过混合 `GET_TP_ATTR`、`SET_TP_ATTR` 和 `GET_TP_LIST`，在控制队列压力下运行。

失败测试：

- 强制 `ubase_ctrlq_send_msg()` timeout，确认失败响应不会被缓存。
- 强制返回 zero `tp_list_cnt`，确认错误路径不变。
- 强制 `tp_list_cnt > caller capacity`，确认返回 `-EINVAL`。

---

## 13. Rollout

Phase 1：仅 instrumentation

- 在现有 `udma_get_tp_list()` 周围添加 timing 和 counter。
- 确认目标系统上的延迟具体花在哪里。

Phase 2：默认关闭的 cache module

- 添加 `udma_tp_cache`。
- 默认保持关闭。
- 本地验证正确性并 benchmark。

Phase 3：默认关闭的 warmup

- 在 EID table initialization 后添加 device/EID warmup。
- 在用户态 owner identity 已知时添加 context/PID warmup。
- 验证 `tp_cfg_req.flag` 的 owner semantics。

Phase 4：对选定测试启用

- 为 perftest 和已知 repeated-query workload 启用 cache。
- 为拥有已知 peer EID 的部署启用 warmup。
- 收集 hit rate 和 latency 数据。

Phase 5：更广泛默认启用

- 只有在 reset、deactivate、migration 和 process-isolation 测试通过后，才考虑默认
  启用。

---

## 14. 风险

stale TP handle 是主要风险。stale TPID 可能导致后续 TP attr 或 activation 操作指向
一个已经被移除或复用的 TP。因此计划要求显式 invalidation 加 TTL。

process scoping 是另一个风险。当前请求嵌入类似 PID 的 flag，因此 cache key 必须
包含同一个值。在没有证明 management 侧把它们视为 process-independent 前，跨进程
共享 cached TP list 是不安全的。

如果 management 侧使用 `tp_cfg_req.flag` 表示 process ownership，module-init
warmup 可能创建错误 owner namespace。此时它能加速 kernel/default-owner 调用，但
不能消除普通用户态的 first-call latency。该场景需要 context/PID warmup 或显式
owner firmware command。

warmup 可能创建不必要的 TP 资源。需要通过 peer-EID policy、transport mode、
max in-flight request 和 TTL 进行约束。EID removal 和 device reset 时必须有 cancel
路径。

RM shared-TP logic 在 `ubcore_connect_adapter.c` 中还有一条独立 busy-wait 路径。
本模块减少 repeated provider-level control-queue call，但不修复那个 spin wait。
如果 profile 仍显示那里有 CPU burn，应在后续 patch 中把 spin loop 替换为
completion/wait queue。

---

## 15. 验收标准

模块满足以下条件时可接受：

- 在 peer EID 已知且 warmup 启用时，应用可见的第一个 warmed key 的
  `get_tp_list` 不再发送新的控制队列请求。
- 重复相同 `get_tp_list` workload 在每个 fresh key、每个 TTL window 内只发送一次
  控制队列请求，而不是每次 API 调用都发送。
- 公开 URMA 行为和返回码保持兼容。
- TP deactivate/remove/reset 测试不观察到 stale TP handle。
- 多进程测试证明 PID scoping 被遵守。
- Debug counter 清楚显示 lookup、hit、miss、invalidation 和 slow-path fetch 行为。
- 该功能可在运行时关闭，从而恢复当前行为。
