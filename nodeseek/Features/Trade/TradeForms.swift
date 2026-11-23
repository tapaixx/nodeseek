import Foundation

enum TradeForms {
    static func options(_ keys: [String]) -> [TradeOption] { keys.map { .init(value: $0, title: TradeText.text($0)) } }
    static let roles = [TradeOption(value: "buyer", title: TradeText.text("买家")), .init(value: "seller", title: TradeText.text("卖家"))]
    static let feePayers = roles + [.init(value: "split", title: TradeText.text("买卖双方均摊"))]
    static let delivery = [TradeOption(value: "official_push", title: TradeText.text("官方转移")), .init(value: "change_email", title: TradeText.text("更改邮箱")), .init(value: "original_email", title: TradeText.text("提供原邮箱")), .init(value: "other", title: TradeText.text("其他"))]
    static let currencies = ["CNY", "USD", "EUR", "GBP", "HKD", "JPY", "USDT"].map { TradeOption(value: $0, title: $0) }
    static func create(agents: [TradeUser], selectedAgent: String = "none", userRole: String?) -> TradeOperation {
        let allowedRoles = roles + (["agent", "admin"].contains(userRole ?? "") ? [.init(value: "agent", title: TradeText.text("中介"))] : [])
        return .init(title: TradeText.text("新建交易"), explanation: TradeText.text("创建后可通过邀请链接拉人；选择具体中介会立即邀请并通知对方。"), path: "/api/common/trades", inputs: [
            .init(key: "role", title: "我的身份", kind: .choice(allowedRoles), required: true, initial: "buyer"),
            .init(key: "title", title: "交易标题（可稍后填写）", limit: 120),
            .init(key: "agent_user_id", title: "中介", kind: .choice([.init(value: "none", title: TradeText.text("暂不选择")), .init(value: "all", title: TradeText.text("通知所有中介"))] + agents.map { .init(value: String($0.id), title: $0.username) }), initial: selectedAgent)
        ])
    }
    static func escrow(agents: [TradeUser], brandOptions: [TradeOption] = []) -> TradeOperation {
        .init(title: TradeText.text("发布托管售卖"), explanation: TradeText.text("公开详情不能填写账号密码。货物信息加密交给接取的中介，放货后发送给买家。"), path: "/api/common/escrow", inputs: [
            .init(key: "title", title: "交易标题", required: true, limit: 120),
            .init(key: "details", title: "公开交易详情", kind: .multiline, required: true, limit: 2000, help: "所有登录用户都能看到，不要写账号密码。"),
            .init(key: "goods", title: "私密货物信息", kind: .secret, required: true, limit: 4000, help: "仅你和有权限的中介可查看，查看会留下记录。"),
            .init(key: "brand_id", title: "品牌", kind: .choice(brandOptions)),
            .init(key: "price", title: "物品价格", kind: .money, required: true),
            .init(key: "price_currency", title: "物品价格币种", kind: .choice(currencies), required: true, initial: "CNY"),
            .init(key: "agent_fee", title: "中介费", kind: .money, required: true),
            .init(key: "agent_fee_currency", title: "中介费币种", kind: .choice(currencies), required: true, initial: "CNY"),
            .init(key: "fee_payer", title: "费用承担方", kind: .choice(feePayers), required: true, initial: "buyer"),
            .init(key: "delivery_method", title: "交货方式", kind: .choice(delivery)),
            .init(key: "post_url", title: "关联帖子", kind: .url, limit: 512),
            .init(key: "agent_user_id", title: "中介", kind: .choice([.init(value: "all", title: TradeText.text("通知所有中介"))] + agents.map { .init(value: String($0.id), title: $0.username) }), initial: "all")
        ])
    }
    static func request(user: TradeValue, trade: Bool, userRole: String?, relatedTradeID: Int64? = nil) -> TradeOperation {
        let userRoles = roles + (["agent", "admin"].contains(userRole ?? "") ? [.init(value: "agent", title: TradeText.text("中介"))] : [])
        let peerRoles = roles + (["agent", "admin"].contains(user["role"].text ?? "") ? [.init(value: "agent", title: TradeText.text("中介"))] : [])
        var fields: [String: TradeValue] = ["to_user_id": user["id"]]
        if trade { fields["kind"] = .string("trade") }
        if let relatedTradeID { fields["related_trade_id"] = .id(relatedTradeID) }
        return .init(title: TradeText.text(trade ? "申请组建交易" : "发起私聊"),
            explanation: String(format: TradeText.text("将向 %@ 发送申请，对方同意后才会建立会话。"), user.name), path: "/api/common/private/requests",
            inputs: (trade ? [TradeInput(key: "from_role", title: "我的身份", kind: .choice(userRoles), required: true, initial: "buyer"),
                              .init(key: "to_role", title: "对方的身份", kind: .choice(peerRoles), required: true, initial: "seller")] : []) + [
                .init(key: "title", title: "会话主题（可选）", limit: 120),
                .init(key: "note", title: "申请说明", kind: .multiline, limit: 500)
            ], fields: fields)
    }
    static func respond(id: String, approve: Bool) -> TradeOperation {
        .init(title: TradeText.text(approve ? "同意申请" : "拒绝申请"), explanation: TradeText.text(approve ? "同意后会创建会话，并通知对方。" : "拒绝后对方会看到申请结果。"),
              path: "/api/common/private/requests/\(id)/respond", fields: ["approve": .bool(approve)])
    }
    static func quick(id: String? = nil, content: String = "") -> TradeOperation {
        .init(title: TradeText.text(id == nil ? "添加快捷消息" : "编辑快捷消息"), explanation: TradeText.text("选用快捷消息只填入输入框，不会直接发送。"),
              path: "/api/common/quick-messages" + (id.map { "/" + $0 } ?? ""), method: id == nil ? "POST" : "PATCH",
              inputs: [.init(key: "content", title: "消息内容", kind: .multiline, required: true, initial: content, limit: 2000)])
    }
    static var feedback: TradeOperation {
        .init(title: TradeText.text("提交反馈"), explanation: TradeText.text("只有管理员可查看反馈，请勿填写账号密码。"), path: "/api/common/feedback",
              inputs: [.init(key: "content", title: "反馈内容", kind: .multiline, required: true, limit: 4000)])
    }
    static var apiKey: TradeOperation {
        .init(title: TradeText.text("创建 API Key"), explanation: TradeText.text("API Key 只用于公开数据查询，创建后仅显示一次，请妥善保存。"), path: "/api/common/api-keys",
              inputs: [.init(key: "name", title: "名称", required: true, limit: 80)], secretResult: true)
    }
}
