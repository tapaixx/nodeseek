import SwiftUI

struct TradeDestination: Identifiable, Hashable {
    let kind: String
    var value = ""
    var title = ""
    var id: String { kind + ":" + value }
}

struct TradeWorkspaceView: View {
    @ObservedObject var home: TradeHomeModel
    let api: TradeWorkspaceServing
    @State private var section = "hall"
    @State private var destination: TradeDestination?
    var body: some View {
        VStack(spacing: 0) {
            Picker(TradeText.text("交易系统"), selection: $section) {
                Text(TradeText.text("交易大厅")).tag("hall")
                Text(TradeText.text("聊天")).tag("chat")
                Text(TradeText.text("我的")).tag("account")
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
            if home.state == .signedOut || home.state == .loading || home.state == .failed {
                TradeHomeView(model: home)
            } else if section == "chat" {
                TradeConversationList(api: api, home: home, open: open)
            } else {
                List {
                    if section == "hall" {
                        Section(TradeText.text("交易大厅")) {
                            entry("agents", "中介", "person.2")
                            entry("escrow", "托管售卖", "shippingbox")
                            entry("brands", "品牌统计", "chart.bar")
                            entry("lookup", "交易查询", "person.crop.circle.badge.magnifyingglass")
                            entry("records", "公开聊天", "bubble.left.and.bubble.right")
                            if ["agent", "admin"].contains(home.user?.role ?? "") { entry("waiting", "等待交易", "hourglass") }
                        }
                        Section(TradeText.text("交易工具")) {
                            entry("calculator", "剩余价值计算器", "calculator")
                            entry("feedback", "意见反馈", "text.bubble")
                            entry("help", "使用帮助", "questionmark.circle")
                        }
                    } else {
                        Section {
                            Text(home.user?.username ?? TradeText.text("我的")).fontWeight(.semibold)
                            Text(TradeText.text(home.user?.role == "agent" ? "中介" : home.user?.role == "admin" ? "管理员" : "普通用户"))
                                .foregroundStyle(.secondary)
                        }
                        Section(TradeText.text("我的")) {
                            entry("overview", "概览", "chart.bar.doc.horizontal")
                            entry("requests", "交易与私聊申请", "tray")
                            entry("points", "我的积分", "creditcard")
                            entry("quick", "快捷消息", "text.bubble")
                            entry("keys", "API Key", "key")
                            entry("profile", "个人资料", "person.crop.circle")
                            entry("help", "使用帮助", "questionmark.circle")
                        }
                    }
                }.refreshable { await home.load() }
            }
        }
        .tradeTypography()

    }
    private func open(_ target: TradeDestination) { home.onDestination?(target) }
    private func entry(_ kind: String, _ title: String, _ symbol: String) -> some View {
        Button { open(.init(kind: kind, title: TradeText.text(title))) } label: {
            Label(TradeText.text(title), systemImage: symbol).foregroundStyle(.primary).frame(minHeight: 44)
        }
    }
}

struct TradeBusinessPage: View {
    let destination: TradeDestination
    let api: TradeWorkspaceServing
    @ObservedObject var home: TradeHomeModel
    let open: (TradeDestination) -> Void
    @State private var child: TradeDestination?
    var body: some View {
        Group {
            switch destination.kind {
            case "calculator": TradeCalculatorView(api: api)
            case "lookup", "user": TradeLookupView(api: api, userID: destination.value, home: home, openRoom: home.onOpen)
            case "escrowDetail": TradeEscrowDetailView(api: api, taskID: destination.value, home: home)
            case "help": TradeHelpView()
            default: TradeCollectionPage(destination: destination, api: api, home: home, open: open)
            }
        }
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .tradeTypography()

    }
}

struct TradeFailureView: View {
    @ObservedObject var model: TradePageModel
    let retry: () -> Void
    var body: some View {
        if model.loading { ProgressView() }
        if let error = model.error {
            Text(error).foregroundStyle(.secondary)
            Button(TradeText.text("重试"), action: retry)
        }
    }
}

struct TradeBusinessRow: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).fontWeight(.medium)
            if let subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
            if let trailing, !trailing.isEmpty { Text(trailing).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 4)
    }
}

extension TradeValue {
    var money: String {
        guard let text, let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        return value.formatted(.currency(code: "CNY"))
    }
    var date: String { TradePresentation.timestamp(text) ?? "—" }
    var name: String { self["username"].text ?? self["label"].text ?? self["name"].text ?? "—" }
}
