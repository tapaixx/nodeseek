import Combine
import SwiftUI

@MainActor
final class TradeInvitationModel: ObservableObject {
    @Published var link = "" { didSet { if link != oldValue { invitation = nil; token = nil; role = ""; needsReview = false; failure = nil } } }
    @Published var role = ""
    @Published private(set) var invitation: TradeInvitation?
    @Published private(set) var isWorking = false
    @Published private(set) var needsReview = false
    @Published private(set) var failure: String?
    private var token: String?
    private let api: TradeServing

    init(api: TradeServing) { self.api = api }

    func preview() async {
        guard !isWorking else { return }
        guard let token = TradeInvitationLink.token(from: link) else {
            failure = TradeText.text("请粘贴有效的官方交易邀请链接。")
            return
        }
        isWorking = true
        defer { isWorking = false }
        failure = nil
        invitation = nil
        role = ""
        do {
            let result = try await api.invitation(token: token)
            try Task.checkCancellation()
            guard TradeInvitationLink.token(from: link) == token else { return }
            self.token = token
            invitation = result
            needsReview = false
        } catch is CancellationError {
        } catch {
            failure = TradeText.text("无法读取邀请，请确认链接有效且已登录。")
        }
    }

    func join() async -> Int64? {
        guard !isWorking, !needsReview, let token, let invitation,
              TradeInvitationLink.token(from: link) == token else { return nil }
        if invitation.isMember { return invitation.conversationId }
        let observer = invitation.kind == "observer"
        guard observer || (invitation.trade.stage == "draft" && invitation.availableRoles.contains { $0.role == role }) else { return nil }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await api.join(token: token, role: observer ? nil : role)
        } catch {
            needsReview = true
            failure = TradeText.text("未能确认是否加入成功，请重新预览邀请后核对身份。")
            return nil
        }
    }
}

struct TradeInvitationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TradeInvitationModel
    @State private var confirming = false
    let onJoined: (Int64) -> Void

    init(api: TradeServing, onJoined: @escaping (Int64) -> Void) {
        _model = StateObject(wrappedValue: TradeInvitationModel(api: api))
        self.onJoined = onJoined
    }

    var body: some View {
        NavigationView {
            Form {
                Section(TradeText.text("邀请链接")) {
                    TextField("https://agent.nodeseek.org/chat/invite/…", text: $model.link)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(model.isWorking)
                        .accessibilityLabel(TradeText.text("邀请链接"))
                    Button(TradeText.text("预览邀请")) { Task { await model.preview() } }
                        .disabled(model.isWorking)
                }
                if model.isWorking { ProgressView() }
                if let invitation = model.invitation {
                    Section(TradeText.text("交易信息")) {
                        Text(invitation.trade.title ?? TradeText.text("未命名交易")).fontWeight(.semibold)
                        TradeInfoRow(title: TradeText.text("状态"), value: TradePresentation.stage(invitation.trade.stage))
                        TradeInfoRow(title: TradeText.text("物品价格"), value: TradePresentation.money(invitation.trade.price))
                        TradeInfoRow(title: TradeText.text("中介费"), value: TradePresentation.money(invitation.trade.agentFee))
                    }
                    if invitation.isMember {
                        Button(TradeText.text("打开交易")) { onJoined(invitation.conversationId) }
                    } else if invitation.kind == "observer" {
                        Text(TradeText.text("旁观者可以查看聊天，但不能发言。"))
                        joinButton
                    } else if invitation.trade.stage == "draft" {
                        Section(TradeText.text("我的身份")) {
                            ForEach(invitation.roles ?? []) { role in
                                Button { model.role = role.role } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(TradePresentation.role(role.role))
                                            if let name = role.takenBy { Text(name).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        if model.role == role.role { Image(systemName: "checkmark") }
                                    }.frame(minHeight: 44)
                                }.disabled(!role.allowed || role.takenBy != nil || model.isWorking)
                            }
                            joinButton.disabled(model.role.isEmpty)
                        }
                    } else { Text(TradeText.text("交易信息已敲定，无法再加入。")) }
                }
                if let failure = model.failure { Text(failure).foregroundStyle(.secondary) }
            }
            .navigationTitle(TradeText.text("通过邀请加入"))
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(TradeText.text("关闭")) { dismiss() }.disabled(model.isWorking)
            } }
            .alert(TradeText.text("确认加入交易？"), isPresented: $confirming) {
                Button(TradeText.text("取消"), role: .cancel) {}
                Button(TradeText.text("确认")) { Task { if let id = await model.join() { onJoined(id) } } }
            } message: { Text(TradeText.text("请核对交易内容和所选身份，加入后其他参与者可以看到你的账号。")) }
        }.interactiveDismissDisabled(model.isWorking)
    }

    private var joinButton: some View {
        Button(TradeText.text("加入交易")) { confirming = true }
            .disabled(model.isWorking || model.needsReview)
    }
}
