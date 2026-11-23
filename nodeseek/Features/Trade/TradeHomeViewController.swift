import Combine
import SwiftUI
import UIKit

@MainActor
final class TradeHomeModel: ObservableObject {
    enum State: Equatable { case loading, signedOut, ready, failed }

    enum Filter: String, CaseIterable, Identifiable {
        case all, open, closed, unread
        var id: Self { self }
        var title: String {
            let key = switch self { case .all: "全部交易"; case .open: "进行中"; case .closed: "已结束"; case .unread: "未读" }
            return TradeText.text(key)
        }
    }

    let api: TradeServing
    @Published private(set) var state = State.loading
    @Published private(set) var conversations: [TradeConversation] = []
    @Published private(set) var agents: [TradeUser] = []
    @Published private(set) var failure: String?
    @Published private(set) var isCreating = false
    @Published private(set) var isCheckingSignIn = false
    var onLogin: (() -> Void)?
    var onOpen: ((Int64) -> Void)?
    @Published var query = ""
    @Published var filter = Filter.all
    @Published private(set) var agentFailure = false
    private var isLoading = false

    var filteredConversations: [TradeConversation] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return conversations.filter { conversation in
            let matchesStatus = switch filter {
            case .all: true
            case .open: conversation.status == "open"
            case .closed: conversation.status == "closed"
            case .unread: (conversation.unread ?? 0) > 0
            }
            return matchesStatus && (term.isEmpty || conversation.displayTitle.localizedStandardContains(term)
                || (conversation.lastMessage?.text?.localizedStandardContains(term) == true)
                || String(conversation.id) == term)
        }
    }

    init(api: TradeServing) { self.api = api }

    func signIn() async {
        guard !isCheckingSignIn, !isLoading else { return }
        isCheckingSignIn = true
        defer { isCheckingSignIn = false }
        // 登录按钮显示后，会话可能已由另一个页面恢复；先复用，避免再消耗 connect 次数。
        await load()
        guard !Task.isCancelled, state == .signedOut else { return }
        onLogin?()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        failure = nil
        do {
            guard let user = try await api.currentUser() else {
                clearSession()
                return
            }
            async let rooms = api.conversations()
            async let availableAgents = try? api.agents()
            let result = try await (rooms, availableAgents)
            try Task.checkCancellation()
            conversations = result.0
            agentFailure = result.1 == nil
            agents = (result.1 ?? []).filter { $0.id != user.id }
            state = .ready
        } catch is CancellationError {
        } catch TradeAPIClient.Failure.signInRequired {
            clearSession()
        } catch {
            failure = TradeText.text("无法读取交易数据，请稍后重试。")
            if state != .ready { state = .failed }
        }
    }

    func create(title: String, role: TradeRole, agentID: Int64) async -> Int64? {
        guard !isCreating else { return nil }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120 else { return nil }
        isCreating = true
        defer { isCreating = false }
        do {
            return try await api.create(title: title, role: role, agentID: agentID)
        } catch TradeAPIClient.Failure.signInRequired {
            clearSession()
        } catch {
            failure = TradeText.text("未能确认交易是否创建，请刷新我的交易后再试。")
        }
        return nil
    }

    private func clearSession() {
        conversations = []
        agents = []
        state = .signedOut
    }
}

final class TradeHomeViewController: UIHostingController<TradeHomeView> {
    private let model: TradeHomeModel

    init(api: TradeServing? = nil) {
        let model = TradeHomeModel(api: api ?? TradeAPIClient())
        self.model = model
        super.init(rootView: TradeHomeView(model: model))
        title = TradeText.text("交易系统")
        model.onLogin = { [weak self] in self?.openAuthorization() }
        model.onOpen = { [weak self] id in self?.openRoom(id) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await model.load() }
    }

    private func openAuthorization() {
        guard presentedViewController == nil else { return }
        let authorization = TradeAuthorizationViewController(verifySession: { [api = model.api] in
            try await api.currentUser() != nil
        }) { [weak self] in
            Task { await self?.model.load() }
        }
        present(UINavigationController(rootViewController: authorization), animated: true)
    }

    private func openRoom(_ id: Int64) {
        let room = TradeRoomViewController(id: id, api: model.api)
        navigationController?.pushViewController(room, animated: true)
    }
}

struct TradeHomeView: View {
    @ObservedObject var model: TradeHomeModel
    @State private var selectedAgent: TradeUser?
    @State private var pendingAgent: TradeUser?
    @State private var pendingRoomID: Int64?
    @State private var joining = false
    @State private var choosingAgent = false

    var body: some View {
        List {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut:
                Section {
                    Label(TradeText.text("交易系统"), systemImage: "arrow.left.arrow.right")
                    Button(TradeText.text("使用 NodeSeek 登录")) { Task { await model.signIn() } }
                        .disabled(model.isCheckingSignIn)
                    Text(TradeText.text("优先使用已有交易会话；首次授权会使用 App 当前的 NodeSeek 登录态。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            case .failed:
                Button(TradeText.text("重试")) { Task { await model.load() } }
            case .ready:
                Section {
                    Button { choosingAgent = true } label: {
                        Label(TradeText.text("发起交易"), systemImage: "plus.circle.fill")
                    }
                    Button { joining = true } label: {
                        Label(TradeText.text("通过邀请加入"), systemImage: "link.badge.plus")
                    }
                }
                Section {
                    Picker(TradeText.text("筛选交易"), selection: $model.filter) {
                        ForEach(TradeHomeModel.Filter.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section(TradeText.text("我的交易")) {
                    if model.filteredConversations.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(TradeText.text(model.conversations.isEmpty ? "暂无交易" : "没有符合条件的交易"), systemImage: "tray")
                            Text(TradeText.text("可以发起交易，或粘贴他人发来的交易邀请链接。"))
                                .font(.footnote).foregroundStyle(.secondary)
                        }.padding(.vertical, 12)
                    }
                    ForEach(model.filteredConversations) { trade in
                        Button { model.onOpen?(trade.id) } label: { conversationRow(trade) }
                            .buttonStyle(.plain)
                    }
                }
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.secondary) }
        }
        .searchable(text: $model.query, prompt: TradeText.text("搜索标题、消息或交易编号"))
        .accessibilityIdentifier("trade-native-home")
        .tradeTypography()
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(isPresented: $choosingAgent, onDismiss: { selectedAgent = pendingAgent; pendingAgent = nil }) {
            NavigationView {
                List {
                    if model.agentFailure {
                        Text(TradeText.text("未能加载中介，已有交易仍可查看。"))
                        Button(TradeText.text("重试")) { Task { await model.load() } }
                    } else if model.agents.isEmpty { Text(TradeText.text("暂无可选中介")) }
                    ForEach(model.agents) { agent in
                        Button {
                            choosingAgent = false
                            // 待选择器关闭再展示创建表单，避免两个 sheet 竞争。
                            pendingAgent = agent
                        } label: { Label(agent.username, systemImage: "person.crop.circle") }
                    }
                }
                .navigationTitle(TradeText.text("选择中介发起交易"))
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(TradeText.text("取消")) { choosingAgent = false }
                } }
            }.tradeTypography()
        }
        .sheet(item: $selectedAgent, onDismiss: openPendingRoom) { agent in
            TradeCreateView(model: model, agent: agent) { id in
                pendingRoomID = id
                selectedAgent = nil
            }
            .tradeTypography()
            .interactiveDismissDisabled(model.isCreating)
        }
        .sheet(isPresented: $joining, onDismiss: openPendingRoom) {
            TradeInvitationView(api: model.api) { id in
                pendingRoomID = id
                joining = false
            }.tradeTypography()
        }
    }

    private func openPendingRoom() {
        guard let id = pendingRoomID else { return }
        pendingRoomID = nil
        model.onOpen?(id)
    }

    private func conversationRow(_ trade: TradeConversation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(trade.displayTitle).fontWeight(.semibold).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let unread = trade.unread, unread > 0 {
                    Text(unread.formatted()).font(.caption).padding(6)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                        .accessibilityLabel(String(format: TradeText.text("%d 条未读消息"), unread))
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                if let stage = trade.trade?.stage { Text(TradePresentation.stage(stage)) }
                else { Text(TradeText.text(trade.status == "closed" ? "已结束" : "进行中")) }
                if let role = trade.myRole { Text(TradePresentation.role(role)) }
                Spacer()
                Text("#\(trade.id)").monospacedDigit()
            }.font(.caption).foregroundStyle(.secondary)
            Text(trade.lastMessage?.text ?? TradeText.text("暂无消息"))
                .foregroundStyle(.secondary).lineLimit(2)
            if let stamp = TradePresentation.timestamp(trade.lastMessage?.at ?? trade.createdAt) {
                Text(stamp).font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.vertical, 5)
    }
}

private struct TradeCreateView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TradeHomeModel
    let agent: TradeUser
    let onCreated: (Int64) -> Void
    @State private var title = ""
    @State private var role = TradeRole.buyer
    @State private var showConfirmation = false
    @State private var attempted = false

    var body: some View {
        NavigationView {
            Form {
                Section(TradeText.text("中介")) { Text(agent.username) }
                TextField(TradeText.text("交易标题"), text: $title)
                    .submitLabel(.done)
                Picker(TradeText.text("我的身份"), selection: $role) {
                    ForEach(TradeRole.allCases) { Text($0.title).tag($0) }
                }
                if let failure = model.failure, attempted { Text(failure).foregroundStyle(.secondary) }
                if attempted, !model.isCreating {
                    Button(TradeText.text("返回我的交易")) { dismiss() }
                }
            }
            .navigationTitle(TradeText.text("发起交易"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TradeText.text("取消")) { dismiss() }.disabled(model.isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isCreating { ProgressView() }
                    else {
                        Button(TradeText.text("发起交易")) { showConfirmation = true }
                            .disabled(attempted || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.count > 120)
                    }
                }
            }
            .alert(TradeText.text("确认发起交易？"), isPresented: $showConfirmation) {
                Button(TradeText.text("取消"), role: .cancel) {}
                Button(TradeText.text("确认")) {
                    attempted = true
                    Task {
                        if let id = await model.create(title: title, role: role, agentID: agent.id) { onCreated(id) }
                    }
                }
            } message: {
                Text(TradeText.text("创建后会通知所选中介。"))
            }
        }
        .navigationViewStyle(.stack)
    }
}
