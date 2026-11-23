import SwiftUI

struct TradeCollectionPage: View {
    let destination: TradeDestination
    let api: TradeWorkspaceServing
    @ObservedObject var home: TradeHomeModel
    let open: (TradeDestination) -> Void
    @StateObject private var model: TradePageModel
    @State private var scope = "hall"
    @State private var page = 1
    @State private var days = "30"
    @State private var operation: TradeOperation?
    @State private var selectedAgent: TradeValue?
    @State private var brands: [TradeValue] = []
    @State private var brand = ""
    @State private var chart = true
    @State private var createdResult: TradeValue?
    @State private var accountRequests: Int?
    @State private var accountChats: Int?
    init(destination: TradeDestination, api: TradeWorkspaceServing, home: TradeHomeModel, open: @escaping (TradeDestination) -> Void) {
        self.destination = destination; self.api = api; self.home = home; self.open = open
        _model = StateObject(wrappedValue: TradePageModel(api: api))
    }
    private var path: String {
        switch destination.kind {
        case "agents": "/api/common/agents"
        case "escrow": "/api/common/escrow"
        case "brands": "/api/common/hall/brand-stats"
        case "records": "/api/common/public-records"
        case "waiting": "/api/agent/waiting"
        case "feedback": "/api/common/feedback"
        case "overview": "/api/common/me/stats"
        case "requests": "/api/common/private/requests"
        case "quick": "/api/common/quick-messages"
        case "keys": "/api/common/api-keys"
        case "profile": "/api/auth/me"
        case "points": "/api/common/points"
        case "logs": "/api/common/points/logs"
        case "packets": "/api/common/points/packets"
        case "orders": "/api/common/points/alipay/orders"
        default: "/api/common/me/stats"
        }
    }
    private var query: [String: String] {
        switch destination.kind {
        case "escrow": ["scope": scope]
        case "brands": ["days": days, "brand_id": brand]
        case "records": ["limit": "30", "offset": String((page - 1) * 30)]
        default: ["page": String(page)]
        }
    }
    var body: some View {
        List {
            TradeFailureView(model: model) { Task { await reload() } }
            content
            if ["records", "logs", "packets", "orders"].contains(destination.kind) {
                HStack {
                    Button(TradeText.text("上一页")) { page = max(1, page - 1) }.disabled(page == 1 || model.loading)
                    Spacer()
                    Text(page.formatted()).monospacedDigit()
                    Spacer()
                    Button(TradeText.text("下一页")) { page += 1 }.disabled(!hasNext || model.loading)
                }
            }
        }
        .task(id: destination.id + ":" + scope + ":" + String(page) + ":" + days + ":" + brand) { await reload() }
        .refreshable { await reload() }
        .toolbar { ToolbarItem(placement: .primaryAction) { toolbar } }
        .sheet(item: $operation, onDismiss: { Task { await reload() } }) { operation in
            TradeOperationView(operation: operation, api: api) { result in
                createdResult = result
                if operation.path == "/api/auth/logout" { Task { await home.load() } }
                if let id = result["conversation_id"].id { home.onOpen?(id) }
                if destination.kind == "escrow", let id = result["id"].text {
                    open(.init(kind: "escrowDetail", value: id, title: TradeText.text("托管售卖")))
                }
            }
        }
    }
    private func reload() async {
        await model.load(path, query: query)
        if destination.kind == "overview" {
            let pending = try? await api.read("/api/common/private/requests", query: [:])
            let chats = try? await api.read("/api/common/conversations", query: ["type": "private", "status": "open"])
            accountRequests = pending?["requests"].list.filter { $0["status"].text == "pending" }.count
            accountChats = chats?["conversations"].list.count
        }
    }
    private var hasNext: Bool {
        if model.data["has_more"].flag { return true }
        if let total = model.data["total"].integer { return page * (model.data["page_size"].integer ?? 20) < total }
        return destination.kind == "records" && model.data["conversations"].list.count >= 30
    }
    @ViewBuilder private var toolbar: some View {
        switch destination.kind {
        case "escrow": Button(TradeText.text("发布")) {
            Task {
                let result = try? await api.read("/api/common/brands", query: [:])
                let choices = (result?["brands"].list ?? []).compactMap { value -> TradeOption? in
                    guard let id = value["id"].text else { return nil }; return .init(value: id, title: value["label"].text ?? "—")
                }
                operation = TradeForms.escrow(agents: home.agents, brandOptions: choices)
            }
        }
        case "quick": Button(TradeText.text("添加")) { operation = TradeForms.quick() }
        case "feedback": Button(TradeText.text("提交反馈")) { operation = TradeForms.feedback }
        case "keys": Button(TradeText.text("创建")) { operation = TradeForms.apiKey }
        default: EmptyView()
        }
    }
    @ViewBuilder private var content: some View {
        switch destination.kind {
        case "agents": agents
        case "escrow": escrow
        case "brands": brandStats
        case "records": records
        case "waiting": waiting
        case "feedback": feedback
        case "overview": overview
        case "requests": requests
        case "quick": quick
        case "keys": keys
        case "profile":
            TradeProfileContent(api: api, user: model.data["user"], operation: $operation)
            Section {
                Button(TradeText.text("退出交易账户"), role: .destructive) {
                    operation = .init(title: TradeText.text("退出交易账户"), explanation: TradeText.text("将结束交易系统会话，论坛登录仍由论坛账户设置管理。"), path: "/api/auth/logout")
                }
            }
        case "points": TradePointsContent(api: api, data: model.data, home: home, operation: $operation, open: open)
        case "logs": logs
        case "packets": TradePacketsContent(data: model.data, userID: home.user?.id, operation: $operation)
        case "orders": TradeOrdersContent(api: api, data: model.data, operation: $operation)
        default: EmptyView()
        }
    }
    private func responseTime(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: TimeInterval(seconds)) ?? "—"
    }
    @ViewBuilder private var agents: some View {
        let rows = model.data["agents"].list
        if rows.isEmpty, !model.loading { Text(TradeText.text("暂无中介")) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, agent in
            Section {
                TradeBusinessRow(title: agent.name,
                    subtitle: TradeText.text(agent["profile"]["online_status"].text ?? "未知状态"),
                    trailing: TradeText.text("成功交易") + ": " + (agent["completed"].text ?? "0"))
                if let bio = agent["bio"].text, !bio.isEmpty { Text(bio) }
                TradeInfoRow(title: TradeText.text("费率"), value: (agent["profile"]["fee_rate"].text ?? "—") + "%")
                TradeInfoRow(title: TradeText.text("最低收费"), value: agent["profile"]["fee_min"].money)
                TradeInfoRow(title: TradeText.text("封顶费用"), value: agent["profile"]["fee_cap"].money)
                TradeInfoRow(title: TradeText.text("用户评价"), value: (agent["reputation"]["score"].text ?? "—") + " / " + (agent["reputation"]["reviews"].text ?? "0"))
                TradeInfoRow(title: TradeText.text("取消率"), value: (agent["reputation"]["agent"]["cancel_rate"].text ?? "—") + "%")
                if let seconds = agent["reputation"]["agent"]["response_seconds"].integer {
                    TradeInfoRow(title: TradeText.text("平均响应"), value: responseTime(seconds))
                }
                if let other = agent["profile"]["other_info"].text { Text(other) }
                if let from = agent["profile"]["online_from"].text {
                    TradeInfoRow(title: TradeText.text("在线时间"), value: from + " – " + (agent["profile"]["online_to"].text ?? ""))
                }
                if let id = agent["id"].text {
                    Button(TradeText.text("资料与评价")) { open(.init(kind: "user", value: id, title: agent.name)) }
                    if agent["id"].id != home.user?.id {
                        Button(TradeText.text("拉交易群")) { operation = TradeForms.create(agents: home.agents, selectedAgent: id, userRole: home.user?.role) }
                        Button(TradeText.text("发起私聊")) { operation = TradeForms.request(user: agent, trade: false, userRole: home.user?.role) }
                    }
                }
            }
        }
    }
    @ViewBuilder private var escrow: some View {
        Picker(TradeText.text("任务范围"), selection: $scope) {
            Text(TradeText.text("大厅")).tag("hall"); Text(TradeText.text("与我有关")).tag("mine")
        }.pickerStyle(.segmented)
        let tasks = model.data["tasks"].list
        if tasks.isEmpty, !model.loading { Text(TradeText.text("暂无托管售卖")) }
        ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
            if let id = task["id"].text {
                Button { open(.init(kind: "escrowDetail", value: id, title: TradeText.text("托管售卖"))) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        TradeBusinessRow(title: task["title"].text ?? "—", subtitle: task["details"].text,
                            trailing: task["price"].money + " · " + TradeText.text(task["status"].text ?? "未知状态"))
                        Text(TradeText.text("卖家") + ": " + task["seller"].name).font(.caption)
                        if task["seller_flagged"].flag || task["has_risk_hit"].flag { Label(TradeText.text("风险提醒"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }.buttonStyle(.plain)
            }
        }
    }
    @ViewBuilder private var brandStats: some View {
        Picker(TradeText.text("时间范围"), selection: $days) {
            Text(TradeText.text("7 天")).tag("7"); Text(TradeText.text("30 天")).tag("30")
            Text(TradeText.text("90 天")).tag("90")
        }
        TradeInfoRow(title: TradeText.text("成功交易"), value: model.data["totals"]["trades"].text ?? "0")
        TradeInfoRow(title: TradeText.text("平均价格"), value: model.data["totals"]["avg_price"].money)
        TradeInfoRow(title: TradeText.text("成交额"), value: model.data["totals"]["amount"].money)
        Section(TradeText.text("每日成功交易")) {
            Toggle(TradeText.text("显示趋势图"), isOn: $chart)
            if chart { TradeBarChart(points: model.data["series"].list) }
            ForEach(Array(model.data["series"].list.enumerated()), id: \.offset) { _, point in
                HStack { Text(point["day"].text ?? "—"); Spacer(); Text(point["completed"].text ?? "0").monospacedDigit() }
            }
        }
        Section(TradeText.text("热榜品牌")) {
            Button(TradeText.text("全部")) { brand = "" }
            if model.data["hot"].list.isEmpty { Text(TradeText.text("暂无数据")) }
            ForEach(Array(model.data["hot"].list.enumerated()), id: \.offset) { _, row in
                Button { brand = row["id"].text ?? "" } label: {
                    TradeBusinessRow(title: row["label"].text ?? "—", subtitle: row["amount"].money,
                                     trailing: row["trades"].text ?? row["completed"].text)
                }
            }
        }
    }
    @ViewBuilder private var records: some View {
        Text(TradeText.text("公开记录仍遵循私密消息的可见权限。")) .font(.footnote).foregroundStyle(.secondary)
        if model.data["conversations"].list.isEmpty, !model.loading { Text(TradeText.text("暂无公开记录")) }
        ForEach(Array(model.data["conversations"].list.enumerated()), id: \.offset) { _, row in
            Button { if let id = row["id"].id { home.onOpen?(id) } } label: {
                TradeBusinessRow(title: row["title"].text ?? TradeText.text("未命名交易"), subtitle: row["last_message"]["text"].text,
                                 trailing: TradeText.text(row["status"].text ?? "") + " · " + row["created_at"].date)
            }.buttonStyle(.plain)
        }
    }
    @ViewBuilder private var waiting: some View {
        let rows = model.data["trades"].list.isEmpty ? model.data["waiting"].list : model.data["trades"].list
        if rows.isEmpty, !model.loading { Text(TradeText.text("暂无等待接单的交易")) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            TradeBusinessRow(title: row["title"].text ?? TradeText.text("未命名交易"), subtitle: row["price"].money)
            if let id = row["id"].text {
                Button(TradeText.text("接单")) {
                    operation = .init(title: TradeText.text("接单"), explanation: TradeText.text("你将以中介身份加入并通知交易参与者。"),
                                      path: "/api/agent/waiting/\(id)/take", guardPath: path, guardValue: model.data)
                }
            }
        }
    }
    @ViewBuilder private var feedback: some View {
        if model.data["feedback"].list.isEmpty, !model.loading { Text(TradeText.text("暂无反馈记录")) }
        ForEach(Array(model.data["feedback"].list.enumerated()), id: \.offset) { _, row in
            TradeBusinessRow(title: row["content"].text ?? "—", subtitle: row["reply"].text ?? row["admin_reply"].text,
                             trailing: TradeText.text(row["status"].text ?? "") + " · " + row["created_at"].date)
        }
    }
    @ViewBuilder private var overview: some View {
        TradeInfoRow(title: TradeText.text("成功交易"), value: model.data["trades"].text ?? "0")
        TradeInfoRow(title: TradeText.text("累计交易额"), value: model.data["amount"].money)
        TradeInfoRow(title: TradeText.text("待处理申请"), value: accountRequests.map { $0.formatted() } ?? "—")
        TradeInfoRow(title: TradeText.text("进行中的私聊"), value: accountChats.map { $0.formatted() } ?? "—")
        ForEach(Array(model.data["by_role"].list.enumerated()), id: \.offset) { _, row in
            TradeInfoRow(title: TradePresentation.role(row["role"].text ?? ""), value: row["trades"].text ?? "0")
        }
        Button(TradeText.text("交易与私聊申请")) { open(.init(kind: "requests", title: TradeText.text("交易与私聊申请"))) }
        Button(TradeText.text("我的积分")) { open(.init(kind: "points", title: TradeText.text("我的积分"))) }
    }
    @ViewBuilder private var requests: some View {
        if model.data["requests"].list.isEmpty, !model.loading { Text(TradeText.text("暂无申请")) }
        ForEach(Array(model.data["requests"].list.enumerated()), id: \.offset) { _, row in
            Section {
                TradeBusinessRow(title: row["title"].text ?? TradeText.text(row["kind"].text == "trade" ? "建群申请" : "私聊申请"),
                    subtitle: row["from"].name + " → " + row["to"].name, trailing: TradeText.text(row["status"].text ?? ""))
                if let note = row["note"].text { Text(note) }
                if row["status"].text == "pending", let id = row["id"].text {
                    if row["to"]["id"].id == home.user?.id {
                        Button(TradeText.text("同意")) { operation = TradeForms.respond(id: id, approve: true) }
                        Button(TradeText.text("拒绝")) { operation = TradeForms.respond(id: id, approve: false) }
                    } else if row["from"]["id"].id == home.user?.id {
                        Button(TradeText.text("撤回申请")) {
                            operation = .init(title: TradeText.text("撤回申请"), explanation: TradeText.text("撤回后对方不能再接受此申请。"), path: "/api/common/private/requests/\(id)/cancel")
                        }
                    }
                }
                if let id = row["conversation_id"].id { Button(TradeText.text("打开聊天")) { home.onOpen?(id) } }
            }
        }
    }
    @ViewBuilder private var quick: some View {
        Text(TradeText.text("选用快捷消息只填入输入框，不会直接发送。")) .font(.footnote).foregroundStyle(.secondary)
        if model.data["quick_messages"].list.isEmpty, !model.loading { Text(TradeText.text("暂无快捷消息")) }
        ForEach(Array(model.data["quick_messages"].list.enumerated()), id: \.offset) { _, row in
            Section {
                Text(row["content"].text ?? "—").textSelection(.enabled)
                if let id = row["id"].text {
                    Button(TradeText.text("编辑")) { operation = TradeForms.quick(id: id, content: row["content"].text ?? "") }
                    Button(TradeText.text("删除"), role: .destructive) {
                        operation = .init(title: TradeText.text("删除快捷消息"), explanation: TradeText.text("删除后无法恢复。"), path: "/api/common/quick-messages/\(id)", method: "DELETE", irreversible: true)
                    }
                }
            }
        }
    }
    @ViewBuilder private var keys: some View {
        Text(TradeText.text("API Key 只用于公开数据查询，不能替代私人账户登录。")) .font(.footnote).foregroundStyle(.secondary)
        let rows = model.data["keys"].list.isEmpty ? model.data["api_keys"].list : model.data["keys"].list
        if rows.isEmpty, !model.loading { Text(TradeText.text("暂无 API Key")) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            Section {
                TradeBusinessRow(title: row["name"].text ?? "—", subtitle: row["prefix"].text,
                                 trailing: row["created_at"].date)
                if row["revoked_at"].isNull, let id = row["id"].text {
                    Button(TradeText.text("吊销"), role: .destructive) {
                        operation = .init(title: TradeText.text("吊销 API Key"), explanation: TradeText.text("吊销后立即失效，无法恢复。"), path: "/api/common/api-keys/\(id)", method: "DELETE", irreversible: true)
                    }
                }
            }
        }
    }
    @ViewBuilder private var logs: some View {
        let rows = model.data["logs"].list
        if rows.isEmpty, !model.loading { Text(TradeText.text("暂无记录")) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            TradeBusinessRow(title: TradeText.text(row["action"].text ?? row["event"].text ?? row["type"].text ?? "积分变动"),
                subtitle: (row["delta"].text ?? row["amount"].text ?? "—") + " · " + (row["agent_name"].text ?? row["agent"].name),
                trailing: row["created_at"].date)
            TradeInfoRow(title: TradeText.text("余额"), value: row["balance_after"].text ?? "—")
            TradeInfoRow(title: TradeText.text("操作人"), value: row["actor_name"].text ?? TradeText.text("系统消息"))
            if let note = row["note"].text { Text(note).foregroundStyle(.secondary) }
        }
    }
}
