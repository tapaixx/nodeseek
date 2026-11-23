import SwiftUI

struct TradeAdvancedTermsView: View {
    let api: TradeWorkspaceServing
    let room: TradeRoom
    let onComplete: () async -> Void
    @State private var brands: [TradeOption] = []
    @State private var rates = TradeValue.null
    @State private var operation: TradeOperation?
    @State private var error: String?
    private var editable: Bool {
        room.access.canWrite && ["buyer", "seller", "agent"].contains(room.access.role ?? "")
            && room.conversation.status == "open" && room.trade?.version != nil
            && (room.trade?.stage == "draft" || room.trade?.freeChatAt != nil)
    }
    var body: some View {
        Group {
            if editable, let trade = room.trade {
                Button(TradeText.text("编辑完整交易条款")) { Task { await prepare(trade) } }
                if let error { Text(error).foregroundStyle(.secondary) }
            }
        }
        .sheet(item: $operation, onDismiss: { Task { await onComplete() } }) { operation in
            TradeOperationView(operation: operation, api: api) { _ in Task { await onComplete() } }
        }
    }
    private func prepare(_ trade: TradeRoom.Progress) async {
        do {
            let snapshot = try await api.read("/api/common/conversations/\(room.conversation.id)", query: [:])
            guard snapshot["trade"]["version"].integer == trade.version,
                  snapshot["trade"]["stage"].text == trade.stage else { error = TradeText.text("交易状态已变化，请核对最新信息后重新操作。"); return }
            let response = try await api.read("/api/common/brands", query: [:])
            brands = response["brands"].list.compactMap { row in row["id"].text.map { TradeOption(value: $0, title: row["label"].text ?? "—") } }
            rates = (try? await api.read("/api/common/fx/rates", query: [:])) ?? .null
            let currencies = rates.isNull ? [TradeOption(value: "CNY", title: "CNY")] : TradeForms.currencies
            let locked = trade.escrowTaskId != nil || trade.redPacket != nil
            let normal: [TradeInput] = locked ? [] : [
                .init(key: "title", title: "交易标题", initial: trade.title ?? "", limit: 120),
                .init(key: "brand_id", title: "品牌", kind: .choice(brands), initial: trade.brandId.map(String.init) ?? ""),
                .init(key: "price", title: "物品价格", kind: .money, initial: trade.price?.value ?? ""),
                .init(key: "price_currency", title: "物品价格币种", kind: .choice(currencies), initial: "CNY"),
                .init(key: "agent_fee", title: "中介费", kind: .money, initial: trade.agentFee?.value ?? ""),
                .init(key: "agent_fee_currency", title: "中介费币种", kind: .choice(currencies), initial: "CNY"),
                .init(key: "fee_payer", title: "费用承担方", kind: .choice(TradeForms.feePayers), initial: trade.feePayer ?? ""),
                .init(key: "delivery_method", title: "交货方式", kind: .choice(TradeForms.delivery), initial: trade.deliveryMethod ?? "")
            ]
            operation = .init(title: TradeText.text("编辑完整交易条款"), explanation: TradeText.text(locked ? "托管或红包交易只能修改关联帖子，其他条款由原交易决定。" : "所有参与者都能看到修改。外币按保存时汇率折算为人民币，最终仍需三方核对。"), path: "/api/common/trades/\(trade.id)", method: "PATCH",
                inputs: normal + [.init(key: "post_url", title: "关联帖子", kind: .url, initial: trade.postUrl ?? "", limit: 512)],
                fields: ["version": .number(Decimal(trade.version!))], guardPath: "/api/common/conversations/\(room.conversation.id)", guardValue: snapshot)
        } catch { self.error = error.localizedDescription }
    }
}
