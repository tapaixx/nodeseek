import SwiftUI

struct TradeProfileContent: View {
    let api: TradeWorkspaceServing
    let user: TradeValue
    @Binding var operation: TradeOperation?
    @StateObject private var telegram: TradePageModel
    init(api: TradeWorkspaceServing, user: TradeValue, operation: Binding<TradeOperation?>) {
        self.api = api; self.user = user; _operation = operation
        _telegram = StateObject(wrappedValue: TradePageModel(api: api))
    }
    var body: some View {
        Section(TradeText.text("个人资料")) {
            Text(user.name).fontWeight(.semibold)
            TradeInfoRow(title: TradeText.text("注册时间"), value: user["created_at"].date)
            if let bio = user["bio"].text { Text(bio).textSelection(.enabled) }
            Button(TradeText.text("编辑简介")) {
                operation = .init(title: TradeText.text("编辑简介"), explanation: TradeText.text("交易平台的个人简介会展示给其他用户。"), path: "/api/common/me", method: "PATCH",
                                  inputs: [.init(key: "bio", title: "简介", kind: .multiline, initial: user["bio"].text ?? "", limit: 2000)])
            }
            if let name = user["username"].text {
                let link = "https://agent.nodeseek.org/chat?with=" + (name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
                Text(link).textSelection(.enabled)
                Button(TradeText.text("复制建群链接")) { UIPasteboard.general.string = link }
            }
        }
        Section("Telegram") {
            TradeFailureView(model: telegram) { Task { await telegram.load("/api/common/telegram") } }
            if !telegram.data.isNull {
                if telegram.data["available"] == .bool(false) {
                    Text(TradeText.text("Telegram 通知暂不可用。"))
                } else if telegram.data["bound"].flag {
                    Text(telegram.data["username"].text ?? telegram.data["telegram"]["username"].text ?? TradeText.text("已绑定"))
                    Button(TradeText.text("解绑 Telegram")) {
                        operation = .init(title: TradeText.text("解绑 Telegram"), explanation: TradeText.text("解绑后不再收到 Telegram 通知，可以重新绑定。"), path: "/api/common/telegram", method: "DELETE", irreversible: true)
                    }
                } else {
                    Button(TradeText.text("绑定 Telegram")) {
                        operation = .init(title: TradeText.text("绑定 Telegram"), explanation: TradeText.text("将生成绑定链接；打开 Telegram 后确认绑定。"), path: "/api/common/telegram/bind", secretResult: true)
                    }
                }
                Button(TradeText.text("刷新绑定状态")) { Task { await telegram.load("/api/common/telegram") } }
            }
        }.task { await telegram.load("/api/common/telegram") }
    }
}

struct TradePointsContent: View {
    let api: TradeWorkspaceServing
    let data: TradeValue
    @ObservedObject var home: TradeHomeModel
    @Binding var operation: TradeOperation?
    let open: (TradeDestination) -> Void
    @StateObject private var payment: TradePageModel
    @State private var packetLink = ""
    @State private var packetLoading = false
    @State private var packet: TradeValue?
    @State private var packetError: String?
    init(api: TradeWorkspaceServing, data: TradeValue, home: TradeHomeModel, operation: Binding<TradeOperation?>, open: @escaping (TradeDestination) -> Void) {
        self.api = api; self.data = data; self.home = home; _operation = operation; self.open = open
        _payment = StateObject(wrappedValue: TradePageModel(api: api))
    }
    var body: some View {
        Section {
            Text(TradeText.text("积分只能用于发行中介经手的交易，请核对中介和金额。")) .font(.footnote).foregroundStyle(.secondary)
            ForEach(Array(data["restrictions"].list.enumerated()), id: \.offset) { _, restriction in
                Label(restriction["reason"].text ?? TradeText.text("账户存在交易限制"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        Section(TradeText.text("积分余额")) {
            if data["balances"].list.isEmpty { Text(TradeText.text("暂无积分余额")) }
            ForEach(Array(data["balances"].list.enumerated()), id: \.offset) { _, balance in
                TradeBusinessRow(title: balance["agent_name"].text ?? balance["agent"].name,
                                 subtitle: balance["balance"].text ?? "0")
                if let id = balance["agent_id"].id {
                    Button(TradeText.text("发中介口令红包")) {
                        operation = .init(title: TradeText.text("发中介口令红包"), explanation: TradeText.text("创建时立即扣除积分，接受前可取消；卖家接受后不能自行撤回。") + "\n" + (balance["agent_name"].text ?? balance["agent"].name) + " · " + (balance["balance"].text ?? "0"), path: "/api/common/points/packets", inputs: [
                            .init(key: "amount", title: "积分数量", kind: .money, required: true),
                            .init(key: "note", title: "备注", kind: .multiline, limit: 500)
                        ], fields: ["agent_id": .id(id)], irreversible: true, secretResult: true,
                            maximumAmount: balance["balance"].text.flatMap { Decimal(string: $0) })
                    }
                }
            }
        }
        Section {
            Button(TradeText.text("兑换中介券")) {
                operation = .init(title: TradeText.text("兑换中介券"), explanation: TradeText.text("兑换后积分计入对应中介余额，提交前请核对券码。"), path: "/api/common/points/redeem",
                                  inputs: [.init(key: "code", title: "券码", kind: .secret, required: true, limit: 500)], irreversible: true)
            }
            Button(TradeText.text("我的红包")) { open(.init(kind: "packets", title: TradeText.text("我的红包"))) }
            Button(TradeText.text("积分明细")) { open(.init(kind: "logs", title: TradeText.text("积分明细"))) }
            Button(TradeText.text("购买订单")) { open(.init(kind: "orders", title: TradeText.text("购买订单"))) }
        }
        Section(TradeText.text("打开中介口令红包")) {
            TextField("https://agent.nodeseek.org/chat/packet/…", text: $packetLink)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel(TradeText.text("红包链接"))
            Button(TradeText.text("预览红包")) { Task { await previewPacket() } }.disabled(packetLoading)
            if packetLoading { ProgressView() }
            if let packetError { Text(packetError).foregroundStyle(.secondary) }
            if let packet {
                TradeBusinessRow(title: packet["agent"].name, subtitle: packet["amount"].text, trailing: TradeText.text(packet["status"].text ?? ""))
                if packet["can_accept"].flag, let token = token {
                    Button(TradeText.text("接受红包")) {
                        operation = .init(title: TradeText.text("接受红包"), explanation: TradeText.text("接受后进入担保交易，买家不能自行取消；请核对中介、对方和积分金额。") + "\n" + packet["agent"].name + " · " + packet["buyer"].name + " · " + (packet["amount"].text ?? "—"), path: "/api/common/packets/\(token)/accept", irreversible: true,
                                          guardPath: "/api/common/packets/\(token)", guardValue: packet)
                    }
                }
                if let id = packet["conversation_id"].id { Button(TradeText.text("打开交易")) { home.onOpen?(id) } }
            }
        }
        Section(TradeText.text("提现确认")) {
            ForEach(Array(data["withdrawals"].list.enumerated()), id: \.offset) { _, row in
                TradeBusinessRow(title: row["agent_name"].text ?? row["agent"].name, subtitle: row["amount"].text, trailing: TradeText.text(row["status"].text ?? ""))
                if row["status"].text == "pending", let id = row["id"].text {
                    ForEach([true, false], id: \.self) { approve in
                        Button(TradeText.text(approve ? "同意提现" : "拒绝提现")) {
                            operation = .init(title: TradeText.text(approve ? "同意提现" : "拒绝提现"),
                                explanation: TradeText.text("同意会扣除对应积分，请先核对中介、金额和实际收款。") + "\n" + (row["agent_name"].text ?? row["agent"].name) + " · " + (row["amount"].text ?? "—"), path: "/api/common/points/withdrawals/\(id)/decision",
                                fields: ["approve": .bool(approve)], irreversible: true)
                        }
                    }
                }
            }
        }
        if payment.data["enabled"].flag {
            Section(TradeText.text("购买积分")) {
                ForEach(Array(payment.data["agents"].list.enumerated()), id: \.offset) { _, agent in
                    Button(agent.name) {
                        operation = .init(title: TradeText.text("购买积分"), explanation: TradeText.text("将创建支付订单，需在官方支付页面完成付款。请核对发行中介与金额。") + "\n" + agent.name, path: "/api/common/points/alipay/orders",
                            inputs: [.init(key: "amount", title: "积分数量", kind: .money, required: true)], fields: ["agent_id": agent["id"], "mobile": .bool(true)], irreversible: true, secretResult: true,
                            maximumAmount: agent["available"].text.flatMap { Decimal(string: $0) })
                    }
                }
            }
        }
        Section { Text(TradeText.text("提现请联系对应中介；不要向无关账户付款。")) .font(.footnote).foregroundStyle(.secondary) }
            .task { await payment.load("/api/common/points/alipay") }
    }
    private var token: String? {
        TradeInvitationLink.token(from: packetLink.replacingOccurrences(of: "/chat/packet/", with: "/chat/invite/"))
    }
    private func previewPacket() async {
        guard !packetLoading else { return }
        guard let token else { packetError = TradeText.text("请填写官方红包链接。"); return }
        packetLoading = true
        defer { packetLoading = false }
        do { packet = try await api.read("/api/common/packets/\(token)", query: [:]); packetError = nil }
        catch { packetError = error.localizedDescription; packet = nil }
    }
}

struct TradePacketsContent: View {
    let data: TradeValue
    let userID: Int64?
    @Binding var operation: TradeOperation?
    var body: some View {
        if data["packets"].list.isEmpty { Text(TradeText.text("暂无红包")) }
        ForEach(Array(data["packets"].list.enumerated()), id: \.offset) { _, row in
            Section {
                TradeBusinessRow(title: row["agent_name"].text ?? row["agent"].name, subtitle: row["amount"].text,
                                 trailing: TradeText.text(row["status"].text ?? "") + " · " + row["created_at"].date)
                if let token = row["token"].text, TradeInvitationLink.isValidToken(token) {
                    Button(TradeText.text("复制红包链接")) { UIPasteboard.general.string = "https://agent.nodeseek.org/chat/packet/" + token }
                }
                if let id = row["id"].text {
                    if row["can_cancel"].flag || (row["status"].text == "pending" && row["mine"].text == "buyer") {
                        Button(TradeText.text("取消红包")) { operation = .init(title: TradeText.text("取消红包"), explanation: TradeText.text("取消后积分退回；已接受的红包不能自行取消。") + "\n" + (row["agent_name"].text ?? row["agent"].name) + " · " + (row["amount"].text ?? "—"), path: "/api/common/points/packets/\(id)/cancel", irreversible: true) }
                    }
                    if row["can_open_chat"].flag || ["accepted", "settled"].contains(row["status"].text ?? "") {
                        Button(TradeText.text("创建交易群聊")) { operation = .init(title: TradeText.text("创建交易群聊"), explanation: TradeText.text("将邀请红包相关三方进入交易群。"), path: "/api/common/points/packets/\(id)/chat") }
                    }
                }
            }
        }
    }
}

struct TradeOrdersContent: View {
    let api: TradeWorkspaceServing
    let data: TradeValue
    @Binding var operation: TradeOperation?
    var body: some View {
        if data["orders"].list.isEmpty { Text(TradeText.text("暂无订单")) }
        ForEach(Array(data["orders"].list.enumerated()), id: \.offset) { _, order in
            Section {
                TradeBusinessRow(title: order["agent_name"].text ?? order["agent"].name, subtitle: order["amount"].text,
                                 trailing: TradeText.text(order["status"].text ?? "") + " · " + order["created_at"].date)
                if let id = order["id"].text {
                    Button(TradeText.text("核对付款状态")) {
                        operation = .init(title: TradeText.text("核对付款状态"), explanation: TradeText.text("只向支付服务核对现有订单，不会创建新订单或重复付款。"), path: "/api/common/points/alipay/orders/\(id)/sync")
                    }
                }
                if let value = order["pay_url"].text, let url = TradeExternalURL.allowed(value), order["status"].text == "created" {
                    Link(TradeText.text("前往付款"), destination: url)
                }
            }
        }
    }
}
