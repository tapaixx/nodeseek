# 探针线路延迟与丢包率接口核验

核验日期：2026-11-15。当前实际内置适配器是 Komari、极简探针（monitor）和 CF-Server-Monitor；哪吒仍属于旧规划，不在本次实现范围。以下结论来自官方源码和官方 API 文档，没有登录账户或执行网络探测。

这里的延迟由服务器上的探针测量，方向是「服务器 → 管理员配置的监测目标」，不能当作手机到服务器的延迟。三网也不是所有面板固定返回的三个字段：Komari、monitor 返回管理员自定义的任务，需保留其名称；不能按任务编号或顺序臆造电信、联通、移动。

## 数据入口

| 适配器 | 列表摘要 | 详情与历史 | 单位与认证 |
|---|---|---|---|
| Komari | 现有 `common:getNodesLatestStatus` 的每节点 `ping` 字典 | `GET /api/records/ping?uuid={nodeID}&hours={hours}` | 延迟 ms；丢包率 0–100%。公开站点游客可读；私有站点仍需认证，隐藏节点不会泄漏 |
| monitor | `/api/nodes` 不含线路统计，不能从资源指标推导 | `GET /api/nodes/{id}/metrics?hours={hours}&series=ping`，可加 `points` | 延迟 ms；丢包率 0–100%。与现有资源历史采用相同可读性检查，已保存的 `monitor_session` 可复用 |
| CFSM | 现有 `/api/servers` 中的 `ping_ct/cu/cm/bd` 与 `loss_ct/cu/cm/bd`，另有最多四条自定义线路 | 现有 `/api/history/all?id={nodeID}&hours={hours}` 包含相同指标；列表还可附 `ping` / `loss` 窗口数组 | 延迟 ms；丢包率 0–100%。公开站点游客可读；私有站点需管理 JWT 或 App Password，Turnstile 仍受原有限制 |

依据：[Komari 路由](https://github.com/komari-monitor/komari/blob/1.6.1/web/router/router.go)、[Komari public 接口](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/public.go)、[monitor API](https://github.com/monitor-probe/monitor/blob/2840c7b07735771b043c5a824c31e6eb435d0f56/src/api.rs)、[CFSM 官方 API](https://github.com/huilang-me/CF-Server-Monitor/blob/1be24f0eabdcc2d06c215c45258382b02e438b49/API.md)。

## Komari：直接利用已有列表数据

`POST /api/rpc2` 的现有 `common:getNodesLatestStatus` 返回 `result[nodeID].ping`，形状为：

```json
{"1":{"name":"上海电信","latest":44,"avg":44,"tail":0,"loss":50,"min":44,"max":44}}
```

这是最近一小时统计，服务端缓存一分钟。`latest` 是**最近一次成功样本**，不是最近一次尝试；若最新尝试超时，它仍可能显示较早的成功延迟。`latest=-1` 表示该窗口没有成功样本。不要用这个数字掩盖超时或将其称作毫秒级实时测量。[官方统计实现](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/common.go)

详情 REST 返回标准包装 `{"status":"success","data":{...}}`。`records` 为 `{task_id,time,value,client}`；`time` 是 RFC3339，`value` 为毫秒，负值代表失败。`tasks` 含 `id,name,type,interval,default_on,loss,min,max,avg,total`。`type` 可为 icmp/tcp/http。优先使用任务级 `loss`、`avg` 等服务端全窗统计，不能用抽样后的点重算覆盖它们。`total=0` 时 `loss=0`、`avg=0` 是空统计占位，应该显示「尚未采样」。[公开历史实现](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/public.go)、[统计规则](https://github.com/komari-monitor/komari/blob/62af91037924057b961dff7b93beacd3f76a81e8/database/tasks/ping_summary.go)

`GET /api/task/ping` 可取任务配置，但不暴露 `target` 或正式 ISP 字段。已有 per-node 历史的 `tasks` 已足够展示名称，不必再请求一次。REST 路由只转发 uuid/task_id/hours，不转发 max_count；如需限制样本量，可 POST `/api/rpc2` 调 `public:getPingRecords`，params 的 uuid/hours 为字符串、max_count 为整数，读取 `result` 而非 `data`。[REST 桥接路由](https://github.com/komari-monitor/komari/blob/1.6.1/web/router/router.go)、[公共任务字段](https://github.com/komari-monitor/komari/blob/1.6.1/web/rpc/jsonrpc/public.go)

精简合成 fixture（按官方字段构造，不是线上采样）：

```json
{"status":"success","data":{"count":2,"records":[{"task_id":1,"time":"2026-11-15T08:00:00Z","value":44,"client":"fake-node"},{"task_id":1,"time":"2026-11-15T08:01:00Z","value":-1,"client":"fake-node"}],"tasks":[{"id":1,"name":"上海电信","type":"icmp","interval":60,"default_on":true,"loss":50,"min":44,"max":44,"avg":44,"total":2},{"id":2,"name":"联通","type":"tcp","interval":60,"default_on":false,"loss":0,"min":0,"max":0,"avg":0,"total":0}]}}
```

## monitor：现有请求主动过滤掉了 ping

当前 App 历史请求指定 `series=metrics`，所以响应中的 `ping`、`probes`、`loss` 被置空。另加 `series=ping` 可只读线路数据，避免重复下载资源曲线。`hours` 最小 1 并受保留时间限制；`points` 预算限定在 60–1440，响应 `step` 是每桶秒数。[窗口与 handler](https://github.com/monitor-probe/monitor/blob/2840c7b07735771b043c5a824c31e6eb435d0f56/src/api.rs)

响应是 `{metrics:[],ping:[],probes:{},loss:{},step}`。`probes` 为分配给该节点的任务名映射，不包含目标地址、间隔或 ISP。`ping` 点为 `{task_id,ts,latency,loss?,band?}`：

- `ts` 是桶起点 Unix 秒；`latency` 是桶内**成功回应的中位数**，不是平均或最近值。偶数样本取中间两数的整数平均；全超时时为 `null`。
- `band:[min,max]` 是成功回应的最小、最大毫秒值，仅在两者不同才出现。单个成功值不应自行制造波动带。
- 桶级 `loss` 是超时百分比，只有非零时才出现，且向上取整。已有数据桶中省略 `loss` 表示 0%；不能把整个任务没有样本也当成 0%。
- 顶层 `loss[taskID]` 是整窗 `100 × 失败数 / 全部尝试数`，未四舍五入；只有存在失败时才出现。某任务有 ping 样本、但顶层未列出它时才可按 0% 显示。`probes` 有名字、但没有任何该任务 ping 点时是「尚未采样」。
- 长窗超过七天时使用小时汇总。跨多个小时的桶采用按成功数加权的小时中位数近似；不要宣称是原始样本的精确全窗中位数。整窗 loss 与 min/max 仍保留真实计数和范围。

这些语义在官方 `Sample`、`Tally`、`close_bucket` 与 `ping_records` 中明确定义，并有包含 75%、100%、无丢包和 1/13 整窗比例的测试。[实现与测试](https://github.com/monitor-probe/monitor/blob/2840c7b07735771b043c5a824c31e6eb435d0f56/src/db.rs)

精简合成 fixture：

```json
{"metrics":[],"probes":{"1":"电信","2":"联通","3":"移动"},"ping":[{"task_id":1,"ts":1763193600,"latency":null,"loss":100},{"task_id":1,"ts":1763193660,"latency":42,"band":[40,44]},{"task_id":2,"ts":1763193660,"latency":18}],"loss":{"1":6.25},"step":60}
```

该例中电信有全超时桶，但整窗丢包为 6.25%，不能平均成 50%；联通为 0%，移动尚未采样。公开页关闭、节点不公开且未登录会返回 401「需要登录后查看」；读取失败也不能转成无丢包。

## CFSM：当前值和采样历史分别处理

`ping_*` / `loss_*` 可能为数字、数字字符串、`false`、`"false"` 或 `null`。`false`、字符串 false 和字段缺失表示未配置/未上报/未取样；不是数字 0。延迟 null 配合 loss=100 表示全超时；loss=0 是有效的零丢包。当前 REST 会在 loss=null 时移除对应 ping/loss 字段，表示没有可用样本。[字段约定](https://github.com/huilang-me/CF-Server-Monitor/blob/1be24f0eabdcc2d06c215c45258382b02e438b49/API.md)、[REST 缺失字段处理](https://github.com/huilang-me/CF-Server-Monitor/blob/1be24f0eabdcc2d06c215c45258382b02e438b49/src/handlers/dashboard.js)

`GET /api/config` 提供 `custom_ct_name`、`custom_cu_name`、`custom_cm_name`、`custom_bd_name` 与 node_1_name 到 node_4_name。未改名时为电信、联通、移动、BGP、自定义 Node 1–4。后四条分别对应 `ping_node_1` / `loss_node_1` 等，不应只硬编码三个字段。[配置字段](https://github.com/huilang-me/CF-Server-Monitor/blob/1be24f0eabdcc2d06c215c45258382b02e438b49/API.md)

列表额外窗口 `ping` 与 `loss` 仅在 `sysConfig.show_three_net_details` 开启时查询，最近两小时最多 20 个真实点，约五分钟缓存；关闭时返回空数组。点格式 `{ts,ct,cu,cm,bd,...}`，`ts` 为 Unix **毫秒**，不存在的列不补点。单台 `/api/server` 不提供这两组数组。资源历史接口 `/api/history/all` 已有同名 `ping_*` / `loss_*`，可以复用；长窗 loss 按桶取 MAX，因此不能平均这些桶得到精确整窗丢包率。[历史抽样实现](https://github.com/huilang-me/CF-Server-Monitor/blob/1be24f0eabdcc2d06c215c45258382b02e438b49/src/database/schema.js)

精简合成 fixture：

```json
{"timestamp":1763193600000,"ping_ct":null,"loss_ct":100,"ping_cu":"18.4","loss_cu":"0","ping_cm":false,"loss_cm":false,"ping_bd":35,"loss_bd":0}
```

这里应显示电信超时/100%、联通 18.4ms/0%、移动未提供，BGP 35ms/0%。不能把 false 通过 NSNumber 或字符串兜底转成 0ms。

## 最小扩充建议

1. 保留现有请求构造、同源限制、登录会话与 adapter 错误处理。为 spec 添加可选的线路来源/格式说明，不在 UIKit 层硬编码 URL，也不新增手机主动 ping。
2. 列表优先读已有 Komari status.ping、CFSM ping/loss 当前字段，不随节点数增加请求。monitor 列表如未另取历史则显示「详情查看」，不要虚构实时摘要。
3. 详情用独立的 `networkHistory` 方法按需读取并缓存，以节点、时间范围和登录代数为键；退出登录时与私有资源历史一起清除。失败应保留错误/上次数据提示，不覆盖成空的健康数据。
4. 统一模型保留任务 ID、原名、可选类型、采样时间、延迟、丢包率、范围及统计窗口；区分「未提供」「尚未采样」「超时」「正常」。若返回的是桶中位数/桶最大丢包，应如实标示，不能统称实时或平均。
5. 任务名可按明确的电信/联通/移动、Telecom/Unicom/Mobile 或独立 CT/CU/CM 标记分类，仍展示原名；未知线路正常展示，不通过任务 ID 猜运营商。
6. 验证数值 0 与布尔 false、100% 超时、无样本任务、稀疏历史、整窗和桶统计差异、私有会话隔离、缓存代数，以及深浅色布局。

## 公开示例及核验边界

Komari 官方仓库链接作者站点 [ss.akz.moe](https://ss.akz.moe/)；CFSM 官方 README 给出 [demo.huilang.me](https://demo.huilang.me/)。本次环境直接读取两站 API 均被 HTTP 拒绝，不能声称已用它们完成线上采样验证。上面的 fixture 是依据官方源码构造的合成样例，适合单测；真实站点的三网任务需要由面板管理员先行配置。

本次参考快照：Komari `62af91037924057b961dff7b93beacd3f76a81e8`（同时对照稳定标签 `1.6.1`）、monitor `2840c7b07735771b043c5a824c31e6eb435d0f56`、CFSM `1be24f0eabdcc2d06c215c45258382b02e438b49`。没有修改探针程序或发送真实通知。
