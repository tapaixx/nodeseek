import SwiftUI

struct TradeCalculatorView: View {
    let api: TradeWorkspaceServing
    @State private var expiry = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()
    @State private var valuation = Date()
    @State private var cycle = 12
    @State private var price = ""
    @State private var asking = ""
    @State private var currency = "CNY"
    @State private var premiumPercent = ""
    @State private var rates = TradeValue.null
    @FocusState private var focused: Bool
    private var remaining: Decimal? {
        TradeRemainingValue.calculate(expiry: expiry, valuation: valuation, cycleMonths: cycle, price: price)
    }
    private func converted(_ value: Decimal) -> String {
        if currency == "CNY" { return value.formatted(.currency(code: "CNY")) }
        guard let raw = rates["rates"][currency].text, let rate = Decimal(string: raw), rate > 0 else { return "—" }
        return (value / rate).formatted(.currency(code: "CNY"))
    }
    var body: some View {
        Form {
            Section {
                DatePicker(TradeText.text("到期时间"), selection: $expiry, displayedComponents: .date)
                DatePicker(TradeText.text("估值时间"), selection: $valuation, displayedComponents: .date)
                Picker(TradeText.text("付款周期"), selection: $cycle) {
                    Text(TradeText.text("月付")).tag(1); Text(TradeText.text("季付")).tag(3); Text(TradeText.text("年付")).tag(12)
                }
                Picker(TradeText.text("货币"), selection: $currency) { ForEach(TradeForms.currencies) { Text($0.title).tag($0.value) } }
                TextField(TradeText.text("周期价格"), text: $price).keyboardType(.decimalPad).focused($focused)
                TextField(TradeText.text("转让价格"), text: $asking).keyboardType(.decimalPad).focused($focused)
                TextField(TradeText.text("溢价百分比"), text: $premiumPercent).keyboardType(.numbersAndPunctuation).focused($focused)
                Button(TradeText.text("由溢价计算转让价格")) {
                    if let remaining, let percent = Decimal(string: premiumPercent) {
                        asking = NSDecimalNumber(decimal: max(0, remaining * (1 + percent / 100))).stringValue
                    }
                }
            }
            if let remaining {
                Section(TradeText.text("估算结果")) {
                    TradeInfoRow(title: TradeText.text("剩余价值"), value: NSDecimalNumber(decimal: remaining).stringValue + " " + currency)
                    TradeInfoRow(title: TradeText.text("人民币参考价值"), value: converted(remaining))
                    if let raw = TradeTerms.amount(asking), let value = Decimal(string: raw) {
                        TradeInfoRow(title: TradeText.text("溢价"), value: NSDecimalNumber(decimal: value - remaining).stringValue + " " + currency)
                        if remaining > 0 { TradeInfoRow(title: TradeText.text("溢价百分比"), value: NSDecimalNumber(decimal: (value / remaining - 1) * 100).stringValue + "%") }
                    }
                    Text(TradeText.text("按当前付款周期剩余时间估算，实际交易价格由双方商定。")) .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(TradeText.text("收起键盘")) { focused = false } } }
        .task { rates = (try? await api.read("/api/common/fx/rates", query: [:])) ?? .null }
    }
}

struct TradeHelpView: View {
    var body: some View {
        List {
            Section(TradeText.text("交易模式")) {
                Text(TradeText.text("普通交易由买家、中介、卖家三方确认条款与进度，货款在站外转账。"))
                Text(TradeText.text("托管售卖由卖家提交公开介绍和私密货物，中介接取后寻找买家并代为放货。"))
                Text(TradeText.text("中介口令红包使用对应中介积分，接受后按担保交易流程交付。"))
            }
            Section(TradeText.text("消息与权限")) {
                Text(TradeText.text("私聊需对方同意。交易私密消息只对选定参与者及有权处理纠纷的管理员可见。"))
                Text(TradeText.text("公开聊天不会公开私密内容。编辑、删除和查看货物可能保留审计记录。"))
            }
            Section(TradeText.text("登录与安全")) {
                Text(TradeText.text("论坛和交易使用独立会话；首次授权需要官方 connect，已有交易会话会优先复用。"))
                Text(TradeText.text("不要将账号密码填入公开商品详情。核对中介、金额、货物和收款状态后再确认。"))
            }
            Section(TradeText.text("操作结果不明确")) {
                Text(TradeText.text("网络失败后先刷新核对。创建、发送和资金相关操作不会自动重复提交。"))
            }
        }
    }
}


enum TradeRemainingValue {
    static func calculate(expiry: Date, valuation: Date, cycleMonths: Int, price: String, calendar: Calendar = .current) -> Decimal? {
        guard cycleMonths > 0, let raw = TradeTerms.amount(price), let amount = Decimal(string: raw) else { return nil }
        let end = calendar.startOfDay(for: expiry)
        let now = calendar.startOfDay(for: valuation)
        guard end > now else { return 0 }
        var cycles = 0
        // 以到期日向前推完整计费周期，月底使用系统 Calendar 处理。
        while cycles < 12000, let prior = calendar.date(byAdding: .month, value: -(cycles + 1) * cycleMonths, to: end), prior >= now { cycles += 1 }
        guard let edge = calendar.date(byAdding: .month, value: -cycles * cycleMonths, to: end),
              let prior = calendar.date(byAdding: .month, value: -(cycles + 1) * cycleMonths, to: end) else { return nil }
        let fullDays = calendar.dateComponents([.day], from: prior, to: edge).day ?? 0
        let partial = calendar.dateComponents([.day], from: now, to: edge).day ?? 0
        guard fullDays > 0 else { return nil }
        return amount * (Decimal(cycles) + Decimal(partial) / Decimal(fullDays))
    }
}


struct TradeBarChart: View {
    let points: [TradeValue]
    private var maximum: Double { max(1, points.compactMap { $0["completed"].text.flatMap(Double.init) }.max() ?? 1) }
    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    VStack(spacing: 5) {
                        Text(point["completed"].text ?? "0").font(.caption2)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor)
                            .frame(width: 20, height: max(2, 120 * (Double(point["completed"].text ?? "0") ?? 0) / maximum))
                        Text(String((point["day"].text ?? "").suffix(5))).font(.caption2)
                    }.accessibilityElement(children: .combine)
                }
            }.frame(minHeight: 170, alignment: .bottom)
        }
    }
}
