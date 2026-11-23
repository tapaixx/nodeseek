import SwiftUI

struct TradeLookupView: View {
    let api: TradeWorkspaceServing
    let userID: String
    @ObservedObject var home: TradeHomeModel
    var openRoom: ((Int64) -> Void)?
    @StateObject private var search: TradePageModel
    @StateObject private var detail: TradePageModel
    @StateObject private var reviews: TradePageModel
    @StateObject private var userReviews: TradePageModel
    @StateObject private var risk: TradePageModel
    @State private var query = ""
    @State private var riskQuery = ""
    @State private var selected = ""
    @State private var reviewPage = 1
    @State private var personalPage = 1
    @State private var operation: TradeOperation?
    @FocusState private var focused: Bool
    init(api: TradeWorkspaceServing, userID: String, home: TradeHomeModel, openRoom: ((Int64) -> Void)?) {
        self.api = api; self.userID = userID; self.home = home; self.openRoom = openRoom
        _search = StateObject(wrappedValue: TradePageModel(api: api)); _detail = StateObject(wrappedValue: TradePageModel(api: api))
        _reviews = StateObject(wrappedValue: TradePageModel(api: api)); _userReviews = StateObject(wrappedValue: TradePageModel(api: api))
        _risk = StateObject(wrappedValue: TradePageModel(api: api))
    }
    var body: some View {
        List {
            if userID.isEmpty {
                Section(TradeText.text("搜索用户")) {
                    TextField(TradeText.text("输入用户名"), text: $query).focused($focused).submitLabel(.search)
                        .onSubmit { focused = false; Task { await searchUsers() } }
                    Button(TradeText.text("搜索")) { focused = false; Task { await searchUsers() } }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || search.loading)
                    TradeFailureView(model: search) { Task { await searchUsers() } }
                    ForEach(Array(search.data["users"].list.enumerated()), id: \.offset) { _, user in
                        Button(user.name) { selected = user["id"].text ?? "" }
                    }
                }
                Section(TradeText.text("查询账号风险")) {
                    TextField(TradeText.text("收款账号或货物账号"), text: $riskQuery).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused)
                    Button(TradeText.text("查询")) {
                        focused = false
                        Task { await risk.load("/api/common/risk/check", query: ["value": riskQuery.trimmingCharacters(in: .whitespacesAndNewlines)]) }
                    }.disabled(riskQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || risk.loading)
                    TradeFailureView(model: risk) { Task { await risk.load("/api/common/risk/check", query: ["value": riskQuery]) } }
                    if !risk.data.isNull {
                        Label(TradeText.text(risk.data["flagged"].flag || !risk.data["hits"].list.isEmpty ? "发现风险记录" : "未发现记录不代表交易安全"), systemImage: "exclamationmark.triangle")
                        ForEach(Array(risk.data["hits"].list.enumerated()), id: \.offset) { _, hit in
                            TradeBusinessRow(title: hit["kind_label"].text ?? TradeText.text("风险提醒"), subtitle: hit["reason"].text)
                        }
                    }
                }
            }
            TradeFailureView(model: detail) { Task { await loadUser() } }
            if !detail.data.isNull {
                Section {
                    Text(detail.data["user"].name).fontWeight(.semibold)
                    if let bio = detail.data["user"]["bio"].text { Text(bio) }
                    if detail.data["risk"]["flagged"].flag { Label(TradeText.text("风险提醒"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    TradeInfoRow(title: TradeText.text("成功交易"), value: detail.data["stats"]["trades"].text ?? detail.data["trades"].text ?? "0")
                    TradeInfoRow(title: TradeText.text("累计交易额"), value: detail.data["stats"]["amount"].isNull ? detail.data["amount"].money : detail.data["stats"]["amount"].money)
                    if detail.data["user"]["id"].id != home.user?.id {
                        Button(TradeText.text("发起私聊")) { operation = TradeForms.request(user: detail.data["user"], trade: false, userRole: home.user?.role) }
                        Button(TradeText.text("申请组建交易")) { operation = TradeForms.request(user: detail.data["user"], trade: true, userRole: home.user?.role) }
                    }
                }
                Section(TradeText.text("交易评价")) { reviewRows(reviews.data); pagination(page: $reviewPage, data: reviews.data) }
                Section(TradeText.text("用户评价")) {
                    reviewRows(userReviews.data)
                    pagination(page: $personalPage, data: userReviews.data)
                    if userReviews.data["can_review"].flag {
                        Button(TradeText.text("评价用户")) {
                            operation = .init(title: TradeText.text("评价用户"), explanation: TradeText.text("评价将公开展示，请基于实际交易经历填写。"), path: "/api/common/users/\(selected)/user-review", method: "PUT", inputs: [
                                .init(key: "score", title: "评分", kind: .choice((1...5).map { .init(value: String($0), title: String($0)) }), required: true, initial: userReviews.data["mine"]["score"].text ?? "5"),
                                .init(key: "comment", title: "评价内容", kind: .multiline, initial: userReviews.data["mine"]["comment"].text ?? "", limit: 1000)])
                        }
                    }
                }
            }
        }
        .task { if !userID.isEmpty { selected = userID } }
        .task(id: selected) { await loadUser() }
        .task(id: "\(selected)-\(reviewPage)") { if !selected.isEmpty { await reviews.load("/api/common/users/\(selected)/reviews", query: ["page": String(reviewPage)]) } }
        .task(id: "\(selected)-\(personalPage)") { if !selected.isEmpty { await userReviews.load("/api/common/users/\(selected)/user-reviews", query: ["page": String(personalPage)]) } }
        .toolbar { ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(TradeText.text("收起键盘")) { focused = false } } }
        .sheet(item: $operation, onDismiss: { Task { await loadUser() } }) { op in
            TradeOperationView(operation: op, api: api) { result in if let id = result["conversation_id"].id { openRoom?(id) } }
        }
    }
    private func searchUsers() async { await search.load("/api/common/users/search", query: ["q": query.trimmingCharacters(in: .whitespacesAndNewlines)]) }
    private func loadUser() async {
        guard !selected.isEmpty else { return }
        await detail.load("/api/common/users/\(selected)")
    }
    @ViewBuilder private func reviewRows(_ data: TradeValue) -> some View {
        let rows = data["reviews"].list.isEmpty ? data["user_reviews"].list : data["reviews"].list
        if rows.isEmpty { Text(TradeText.text("暂无评价")) }
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            TradeBusinessRow(title: (row["reviewer"].text ?? row["reviewer"].name) + " · " + (row["score"].text ?? "—"), subtitle: row["comment"].text, trailing: row["created_at"].date)
        }
    }
    private func pagination(page: Binding<Int>, data: TradeValue) -> some View {
        HStack {
            Button(TradeText.text("上一页")) { page.wrappedValue -= 1 }.disabled(page.wrappedValue <= 1)
            Spacer(); Text(page.wrappedValue.formatted()); Spacer()
            Button(TradeText.text("下一页")) { page.wrappedValue += 1 }
                .disabled(page.wrappedValue * (data["page_size"].integer ?? 20) >= (data["total"].integer ?? 0))
        }
    }
}
