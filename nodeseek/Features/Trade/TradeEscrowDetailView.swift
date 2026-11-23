import SwiftUI

struct TradeEscrowDetailView: View {
    let api: TradeWorkspaceServing
    let taskID: String
    @ObservedObject var home: TradeHomeModel
    @StateObject private var model: TradePageModel
    @State private var operation: TradeOperation?
    @State private var goods: String?
    @State private var goodsError: String?
    @State private var goodsLoading = false
    @State private var confirmGoods = false
    init(api: TradeWorkspaceServing, taskID: String, home: TradeHomeModel) {
        self.api = api; self.taskID = taskID; self.home = home
        _model = StateObject(wrappedValue: TradePageModel(api: api))
    }
    private var path: String { "/api/common/escrow/" + taskID }
    private var task: TradeValue { model.data["task"] }
    var body: some View {
        List {
            TradeFailureView(model: model) { Task { await reload() } }
            if !task.isNull {
                Section {
                    Text(task["title"].text ?? "—").fontWeight(.semibold)
                    Text(TradeText.text(task["status"].text ?? "未知状态")).foregroundStyle(.secondary)
                    Text(task["details"].text ?? "").textSelection(.enabled)
                    if task["seller_risk"]["flagged"].flag || !task["risk_hits"].list.isEmpty {
                        Label(TradeText.text("风险提醒"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if let reason = task["seller_risk"]["reason"].text { Text(reason) }
                        ForEach(Array(task["risk_hits"].list.enumerated()), id: \.offset) { _, hit in
                            Text((hit["value"].text ?? "") + " · " + (hit["reason"].text ?? ""))
                        }
                    }
                }
                Section(TradeText.text("交易信息")) {
                    TradeInfoRow(title: TradeText.text("物品价格"), value: task["price"].money)
                    if let note = task["price_note"].text { Text(note) }
                    TradeInfoRow(title: TradeText.text("中介费"), value: task["agent_fee"].money)
                    if let note = task["agent_fee_note"].text { Text(note) }
                    TradeInfoRow(title: TradeText.text("费用承担方"), value: task["fee_payer"].text == "split" ? TradeText.text("买卖双方均摊") : TradePresentation.role(task["fee_payer"].text ?? ""))
                    TradeInfoRow(title: TradeText.text("品牌"), value: task["brand"].text ?? "—")
                    TradeInfoRow(title: TradeText.text("交货方式"), value: TradeForms.delivery.first { $0.value == task["delivery_method"].text }?.title ?? "—")
                    TradeInfoRow(title: TradeText.text("卖家"), value: task["seller"].name)
                    TradeInfoRow(title: TradeText.text("中介"), value: task["agent"].name)
                    if !task["designated_agent"].isNull { TradeInfoRow(title: TradeText.text("指定中介"), value: task["designated_agent"].name) }
                    if let url = TradePresentation.postURL(task["post_url"].text) { Link(TradeText.text("关联帖子"), destination: url) }
                    TradeInfoRow(title: TradeText.text("发布时间"), value: task["created_at"].date)
                    if let reason = task["close_reason"].text { Text(reason) }
                }
                if task["can_view_goods"].flag {
                    Section(TradeText.text("私密货物信息")) {
                        if let goods {
                            Text(goods).textSelection(.enabled).privacySensitive()
                            Button(TradeText.text("复制")) { UIPasteboard.general.string = goods }
                            Button(TradeText.text("隐藏")) { self.goods = nil }
                        } else {
                            Button(TradeText.text("查看货物信息")) { confirmGoods = true }.disabled(goodsLoading)
                            Text(TradeText.text("每次查看都会留下记录，请勿向无关人员泄露。")) .font(.footnote).foregroundStyle(.secondary)
                        }
                        if goodsLoading { ProgressView() }
                        if let goodsError { Text(goodsError).foregroundStyle(.secondary) }
                    }
                }
                Section {
                    if task["can_accept"].flag { action("接取任务", suffix: "accept", message: "接取后你将负责保管货物、寻找买家，并可代卖家放货。") }
                    if task["can_decline"].flag {
                        Button(TradeText.text("拒绝任务")) {
                            operation = guarded("拒绝任务", suffix: "decline", message: "将通知卖家另选中介，拒绝后不能自行再次接取。", inputs: [.init(key: "reason", title: "原因", kind: .multiline, limit: 500)])
                        }
                    }
                    if task["can_reassign"].flag {
                        Button(TradeText.text("更换中介")) {
                            operation = guarded("更换中介", suffix: "reassign", message: "会通知新指定中介；不指定则通知所有中介。", inputs: [
                                .init(key: "agent_user_id", title: "中介", kind: .choice([.init(value: "all", title: TradeText.text("通知所有中介"))] + home.agents.map { .init(value: String($0.id), title: $0.username) }), initial: "all")])
                        }
                    }
                    if task["can_open_chat"].flag { action("创建交易群聊", suffix: "chats", message: "将创建交易群并邀请卖家，之后可用邀请链接邀请买家。") }
                    if task["can_cancel"].flag { action("撤下托管售卖", suffix: "cancel", message: "进行中的群聊可能一起取消，中介可能已查看货物信息。此操作不能撤销。", irreversible: true) }
                }
                if !task["chats"].list.isEmpty {
                    Section(TradeText.text("群聊记录")) {
                        ForEach(Array(task["chats"].list.enumerated()), id: \.offset) { _, chat in
                            Button { if let id = chat["conversation_id"].id { home.onOpen?(id) } } label: {
                                TradeBusinessRow(title: chat["title"].text ?? TradeText.text("交易群聊"), subtitle: TradeText.text(chat["stage"].text ?? ""))
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }.refreshable { await reload() }
        .onDisappear { goods = nil }
        .alert(TradeText.text("查看货物信息"), isPresented: $confirmGoods) {
            Button(TradeText.text("取消"), role: .cancel) {}
            Button(TradeText.text("查看")) { Task { await loadGoods() } }
        } message: { Text(TradeText.text("每次查看都会留下记录，请勿向无关人员泄露。")) }
        .sheet(item: $operation, onDismiss: { Task { await reload() } }) { operation in
            TradeOperationView(operation: operation, api: api) { result in
                goods = nil
                if let id = result["conversation_id"].id { home.onOpen?(id) }
            }
        }
    }
    private func reload() async {
        await model.load(path)
        if !task["can_view_goods"].flag { goods = nil }
    }
    private func guarded(_ title: String, suffix: String, message: String, inputs: [TradeInput] = [], irreversible: Bool = false) -> TradeOperation {
        .init(title: TradeText.text(title), explanation: TradeText.text(message), path: path + "/" + suffix,
              inputs: inputs, irreversible: irreversible, guardPath: path, guardValue: model.data)
    }
    private func action(_ title: String, suffix: String, message: String, irreversible: Bool = false) -> some View {
        Button(TradeText.text(title)) { operation = guarded(title, suffix: suffix, message: message, irreversible: irreversible) }
    }
    private func loadGoods() async {
        guard !goodsLoading, task["can_view_goods"].flag else { return }
        goodsLoading = true
        defer { goodsLoading = false }
        do {
            let fresh = try await api.read(path, query: [:])
            guard fresh["task"]["can_view_goods"].flag else { goods = nil; return }
            goods = try await api.read(path + "/goods", query: [:])["goods"].text
        } catch { goodsError = error.localizedDescription }
    }
}
