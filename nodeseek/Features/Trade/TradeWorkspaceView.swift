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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 145
    @State private var creating: TradeOperation?
    @State private var joining = false
    @State private var pendingRoom: Int64?
    var body: some View {
        VStack(spacing: 0) {
            if home.state == .ready { Picker(TradeText.text("交易系统"), selection: $section) {
                Text(TradeText.text("交易大厅")).tag("hall")
                Text(TradeText.text("聊天")).tag("chat")
                Text(TradeText.text("我的")).tag("account")
            }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8) }
            if home.state == .signedOut || home.state == .loading || home.state == .failed {
                TradeHomeView(model: home)
            } else if section == "chat" {
                TradeConversationList(api: api, home: home, open: open)
            } else {
                List {
                    if section == "hall" {
                        hallHeader
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        if let recent = home.conversations.first {
                            Section(TradeText.text("最近的交易")) {
                                Button { home.onOpen?(recent.id) } label: {
                                    HStack {
                                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Color.accentColor)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(recent.displayTitle).fontWeight(.medium)
                                            if let preview = recent.lastMessage?.text { Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                        }
                                        Spacer(); Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary)
                                    }.frame(minHeight: 44).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                        Section(TradeText.text("交易大厅")) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileWidth), spacing: 12)], spacing: 12) {
                                tile("agents", "中介", "资料与评价", "person.2.fill", .indigo)
                                tile("escrow", "托管售卖", "浏览托管任务", "shippingbox.fill", .orange)
                                tile("lookup", "交易查询", "查询账号风险", "magnifyingglass", .teal)
                                tile("records", "公开聊天", "查看交易记录", "text.bubble.fill", .blue)
                            }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                            if ["agent", "admin"].contains(home.user?.role ?? "") { entry("waiting", "等待交易", "hourglass") }
                        }
                        Section(TradeText.text("交易工具")) {
                            entry("brands", "品牌统计", "chart.bar.fill")
                            entry("calculator", "剩余价值计算器", "function")
                            entry("feedback", "意见反馈", "text.bubble")
                            entry("help", "使用帮助", "questionmark.circle")
                        }
                    } else {
                        Section {
                            HStack(spacing: 14) {
                                Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(home.user?.username ?? TradeText.text("我的")).fontWeight(.semibold)
                                    Text(TradeText.text(home.user?.role == "agent" ? "中介" : home.user?.role == "admin" ? "管理员" : "普通用户")).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
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
        .sheet(item: $creating, onDismiss: finishRoom) { operation in
            TradeOperationView(operation: operation, api: api) { pendingRoom = $0["conversation_id"].id }
        }
        .sheet(isPresented: $joining, onDismiss: finishRoom) {
            TradeInvitationView(api: home.api) { pendingRoom = $0; joining = false }
        }
    }
    private func finishRoom() {
        if let pendingRoom { home.onOpen?(pendingRoom); self.pendingRoom = nil }
    }
    private var hallHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(TradeText.text("交易大厅"), systemImage: "bag.fill").font(.title2.bold())
            if typeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 8) { headerActions } }
            else { HStack(spacing: 12) { headerActions } }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color.accentColor.opacity(0.16), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    @ViewBuilder private var headerActions: some View {
        Button { creating = TradeForms.create(agents: home.agents, userRole: home.user?.role) } label: {
            Label(TradeText.text("新建交易"), systemImage: "plus").frame(minHeight: 30)
        }.buttonStyle(.borderedProminent)
        Button { joining = true } label: {
            Label(TradeText.text("通过邀请加入"), systemImage: "link").frame(minHeight: 30)
        }.buttonStyle(.bordered)
    }
    private func tile(_ kind: String, _ title: String, _ subtitle: String, _ symbol: String, _ tint: Color) -> some View {
        Button { open(.init(kind: kind, title: TradeText.text(title))) } label: {
            VStack(alignment: .leading, spacing: 7) {
                Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 36, height: 36)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                Text(TradeText.text(title)).font(.headline)
                Text(TradeText.text(subtitle)).font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func open(_ target: TradeDestination) { home.onDestination?(target) }
    private func entry(_ kind: String, _ title: String, _ symbol: String) -> some View {
        Button { open(.init(kind: kind, title: TradeText.text(title))) } label: {
            HStack { Label(TradeText.text(title), systemImage: symbol); Spacer(); Image(systemName: "chevron.forward").font(.caption).foregroundStyle(.secondary) }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
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
