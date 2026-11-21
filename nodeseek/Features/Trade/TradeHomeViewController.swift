import Combine
import SwiftUI
import UIKit

@MainActor
final class TradeHomeModel: ObservableObject {
    enum State: Equatable { case loading, signedOut, ready, failed }

    let api: TradeServing
    @Published private(set) var state = State.loading
    @Published private(set) var conversations: [TradeConversation] = []
    @Published private(set) var agents: [TradeUser] = []
    @Published private(set) var failure: String?
    @Published private(set) var isCreating = false
    @Published private(set) var isCheckingSignIn = false
    var onLogin: (() -> Void)?
    var onOpen: ((Int64) -> Void)?
    private var isLoading = false

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
            async let availableAgents = api.agents()
            let result = try await (rooms, availableAgents)
            try Task.checkCancellation()
            conversations = result.0
            agents = result.1.filter { $0.id != user.id }
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
        let room = UIHostingController(rootView: TradeRoomView(model: TradeRoomModel(id: id, api: self.model.api)))
        room.title = TradeText.text("交易群聊")
        navigationController?.pushViewController(room, animated: true)
    }
}

struct TradeHomeView: View {
    @ObservedObject var model: TradeHomeModel
    @State private var selectedAgent: TradeUser?

    var body: some View {
        List {
            switch model.state {
            case .loading:
                ProgressView()
            case .signedOut:
                Button(TradeText.text("使用 NodeSeek 登录")) { Task { await model.signIn() } }
                    .disabled(model.isCheckingSignIn)
                Text(TradeText.text("优先使用已有交易会话；首次授权会使用 App 当前的 NodeSeek 登录态。"))
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed:
                Button(TradeText.text("重试")) { Task { await model.load() } }
            case .ready:
                Section(TradeText.text("我的交易")) {
                    if model.conversations.isEmpty { Text(TradeText.text("暂无交易")).foregroundStyle(.secondary) }
                    ForEach(model.conversations) { trade in
                        Button {
                            model.onOpen?(trade.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trade.displayTitle)
                                if let preview = trade.lastMessage?.text {
                                    Text(preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
                Section(TradeText.text("选择中介发起交易")) {
                    if model.agents.isEmpty { Text(TradeText.text("暂无可选中介")).foregroundStyle(.secondary) }
                    ForEach(model.agents) { agent in
                        Button {
                            selectedAgent = agent
                        } label: {
                            Label(agent.username, systemImage: "person.crop.circle")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                    }
                }
            }
            if let failure = model.failure { Text(failure).foregroundStyle(.secondary) }
        }
        .accessibilityIdentifier("trade-native-home")
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $selectedAgent) { agent in
            TradeCreateView(model: model, agent: agent) { id in
                selectedAgent = nil
                model.onOpen?(id)
            }
            .interactiveDismissDisabled(model.isCreating)
        }
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
