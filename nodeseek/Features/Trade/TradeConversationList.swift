import SwiftUI

struct TradeConversationList: View {
    let api: TradeWorkspaceServing
    @ObservedObject var home: TradeHomeModel
    let open: (TradeDestination) -> Void
    @StateObject private var model: TradePageModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var live = TradeLiveEvents()
    @State private var query = ""
    @State private var status = "open"
    @State private var type = ""
    @State private var participant = ""
    @State private var dateFilter = false
    @State private var from = Date().addingTimeInterval(-30 * 86400)
    @State private var to = Date()
    @State private var showFilters = false
    @State private var operation: TradeOperation?
    @State private var invitation = false
    @State private var userSearch = false
    init(api: TradeWorkspaceServing, home: TradeHomeModel, open: @escaping (TradeDestination) -> Void) {
        self.api = api; self.home = home; self.open = open
        _model = StateObject(wrappedValue: TradePageModel(api: api))
    }
    private var filters: [String: String] {
        var result = ["q": query.trimmingCharacters(in: .whitespacesAndNewlines), "status": status, "type": type, "participant": participant]
        if dateFilter {
            result["from"] = ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: from))
            let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: to)) ?? to
            result["to"] = ISO8601DateFormatter().string(from: end.addingTimeInterval(-0.001))
        }
        return result
    }
    var body: some View {
        List {
            Section {
                Menu {
                    Button(TradeText.text("新建交易")) { operation = TradeForms.create(agents: home.agents, userRole: home.user?.role) }
                    Button(TradeText.text("搜索用户并申请")) { userSearch = true }
                    Button(TradeText.text("发布托管售卖")) { open(.init(kind: "escrow", title: TradeText.text("托管售卖"))) }
                    Button(TradeText.text("通过邀请加入")) { invitation = true }
                } label: { Label(TradeText.text("新建"), systemImage: "plus.circle") }
                Button(TradeText.text("交易与私聊申请")) { open(.init(kind: "requests", title: TradeText.text("交易与私聊申请"))) }
                DisclosureGroup(TradeText.text("过滤聊天"), isExpanded: $showFilters) {
                    Picker(TradeText.text("进行状态"), selection: $status) {
                        Text(TradeText.text("全部")).tag(""); Text(TradeText.text("进行中")).tag("open"); Text(TradeText.text("已结束")).tag("closed")
                    }
                    Picker(TradeText.text("类型"), selection: $type) {
                        Text(TradeText.text("全部")).tag(""); Text(TradeText.text("群聊")).tag("trade"); Text(TradeText.text("私聊")).tag("private")
                    }
                    TradeParticipantPicker(api: api, selectedID: $participant)
                    Toggle(TradeText.text("按日期筛选"), isOn: $dateFilter)
                    if dateFilter {
                        DatePicker(TradeText.text("开始日期"), selection: $from, displayedComponents: .date)
                        DatePicker(TradeText.text("结束日期"), selection: $to, in: from..., displayedComponents: .date)
                    }
                    Button(TradeText.text("清除筛选")) { status = ""; type = ""; participant = ""; query = ""; dateFilter = false }
                }
            }
            TradeFailureView(model: model) { Task { await reload() } }
            if model.data["conversations"].list.isEmpty, !model.loading { Text(TradeText.text("暂无聊天")) }
            ForEach(Array(model.data["conversations"].list.enumerated()), id: \.offset) { _, conversation in
                Button { if let id = conversation["id"].id { home.onOpen?(id) } } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(conversation["title"].text ?? TradeText.text(conversation["type"].text == "private" ? "私聊" : "未命名交易")).fontWeight(.medium)
                            Spacer()
                            if let count = conversation["unread"].integer, count > 0 { Text(count.formatted()).font(.caption).padding(6).background(Color(uiColor: .tertiarySystemFill), in: Capsule()) }
                        }
                        Text(conversation["last_message"]["text"].text ?? TradeText.text("暂无消息")).foregroundStyle(.secondary).lineLimit(2)
                        HStack {
                            Text(TradeText.text(conversation["type"].text == "private" ? "私聊" : "群聊"))
                            if let stage = conversation["trade"]["stage"].text { Text(TradePresentation.stage(stage)) }
                            Spacer()
                            Text(conversation["last_message"]["at"].isNull ? conversation["created_at"].date : conversation["last_message"]["at"].date)
                        }.font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).padding(.vertical, 5)
                }.buttonStyle(.plain)
            }
        }
        .searchable(text: $query, prompt: TradeText.text("搜索交易或用户"))
        .task(id: filters.sorted { $0.key < $1.key }.description) {
            do { try await Task.sleep(nanoseconds: 250_000_000); try Task.checkCancellation(); await reload() } catch {}
        }
        .refreshable { await reload() }
        .task(id: scenePhase == .active && home.workspaceVisible) {
            guard scenePhase == .active, home.workspaceVisible else { live.stop(); return }
            live.start()
            defer { live.stop() }
            do { try await Task.sleep(nanoseconds: UInt64.max) } catch {}
        }
        .onReceive(NotificationCenter.default.publisher(for: TradeLiveEvents.didReceive)) { notification in
            guard scenePhase == .active, home.workspaceVisible else { return }
            if let event = notification.userInfo?["event"] as? TradeValue, ["typing", "read"].contains(event["type"].text ?? "") { return }
            Task { await reload() }
        }
        .sheet(item: $operation, onDismiss: { Task { await reload() } }) { operation in
            TradeOperationView(operation: operation, api: api) { result in if let id = result["conversation_id"].id { home.onOpen?(id) } }
        }
        .sheet(isPresented: $invitation) { TradeInvitationView(api: home.api) { id in invitation = false; home.onOpen?(id) } }
        .sheet(isPresented: $userSearch) {
            NavigationView {
                TradeLookupView(api: api, userID: "", home: home, openRoom: home.onOpen)
                    .navigationTitle(TradeText.text("交易查询"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(TradeText.text("关闭")) { userSearch = false } } }
            }
        }
    }
    private func reload() async { await model.load("/api/common/conversations", query: filters) }
}

struct TradeParticipantPicker: View {
    let api: TradeWorkspaceServing
    @Binding var selectedID: String
    @State private var query = ""
    @State private var users: [TradeValue] = []
    var body: some View {
        VStack(alignment: .leading) {
            TextField(TradeText.text("参与对象用户名"), text: $query).textInputAutocapitalization(.never)
                .task(id: query) {
                    do {
                        try await Task.sleep(nanoseconds: 350_000_000)
                        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { users = []; return }
                        let result = try await api.read("/api/common/users/search", query: ["q": query])
                        try Task.checkCancellation()
                        users = result["users"].list
                    } catch {}
                }
            ForEach(Array(users.enumerated()), id: \.offset) { _, user in
                Button { selectedID = user["id"].text ?? ""; query = user.name; users = [] } label: {
                    HStack { Text(user.name); if selectedID == user["id"].text { Image(systemName: "checkmark") } }
                }
            }
            if !selectedID.isEmpty { Button(TradeText.text("清除参与对象")) { selectedID = ""; query = "" } }
        }
    }
}
