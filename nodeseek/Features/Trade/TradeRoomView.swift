import Combine
import SwiftUI
import UIKit

@MainActor
final class TradeRoomModel: ObservableObject {
    @Published private(set) var room: TradeRoom?
    @Published private(set) var messages: [TradeMessage] = []
    @Published private(set) var hasMore = false
    @Published private(set) var isSending = false
    @Published private(set) var sendNeedsReview = false
    @Published private(set) var invitePending = false
    @Published private(set) var notice: String?
    @Published var draft = ""
    @Published var reply: TradeMessage?
    @Published var isVisible = false
    @Published private(set) var isMutating = false
    @Published private(set) var actionNeedsReview = false
    @Published private(set) var isLoading = false

    let live = TradeLiveEvents()
    private var lastReadID: Int64 = 0
    private var isMarkingRead = false
    let id: Int64
    let api: TradeServing
    @Published var visibility: Int64?
    private var pendingAttachmentID: TradeValue?
    @Published var attachment: Data?
    @Published var quoteText: String?
    @Published private(set) var currentUser: TradeUser?
    @Published private(set) var quickMessages: [String] = []
    @Published private(set) var pins: [TradeValue] = []
    var workspace: TradeWorkspaceServing? { api as? TradeWorkspaceServing }

    init(id: Int64, api: TradeServing) {
        self.id = id
        self.api = api
    }

    func reload(quiet: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await api.room(id: id)
            let page = try await api.messages(id: id, before: nil)
            try Task.checkCancellation()
            room = details
            if currentUser == nil { currentUser = try? await api.currentUser() }
            if let workspace, !quiet {
                quickMessages = ((try? await workspace.read("/api/common/quick-messages", query: [:]))?["quick_messages"].list ?? []).compactMap { $0["content"].text }
                pins = (try? await workspace.read("/api/common/conversations/\(id)/pins", query: [:]))?["pins"].list ?? []
            }
            if messages.isEmpty { hasMore = page.hasMore }
            merge(page.messages)
            if !quiet, !sendNeedsReview, !actionNeedsReview { notice = nil }
        } catch is CancellationError {
        } catch TradeAPIClient.Failure.signInRequired {
            room = nil
            messages = []
            notice = TradeText.text("请返回交易系统重新登录。")
        } catch where !quiet {
            notice = TradeText.text("无法读取交易数据，请稍后重试。")
        } catch {}
    }

    func loadOlder() async {
        guard !isLoading, hasMore, let previousID = messages.first?.id else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.messages(id: id, before: previousID)
            try Task.checkCancellation()
            hasMore = page.hasMore && !page.messages.isEmpty
            merge(page.messages)
        } catch is CancellationError {
        } catch {
            notice = TradeText.text("无法读取交易数据，请稍后重试。")
        }
    }

    private func merge(_ page: [TradeMessage]) {
        var byID: [Int64: TradeMessage] = [:]
        for message in messages + page { byID[message.id] = message }
        messages = byID.values.sorted { $0.id < $1.id }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard room?.access.canWrite == true, (!text.isEmpty || attachment != nil), !isSending, !sendNeedsReview else { return }
        isSending = true
        defer { isSending = false }
        do {
            let sent: TradeMessage
            if let workspace, attachment != nil || visibility != nil || quoteText != nil {
                var fields: [String: TradeValue] = [:]
                if !text.isEmpty { fields["content"] = .string(text) }
                if let reply { fields["reply_to_id"] = .id(reply.id) }
                if let quoteText { fields["quote_text"] = .string(quoteText) }
                if let visibility {
                    let role = room?.access.role
                    let allowed = room?.members?.contains { $0.id == visibility && (role == "agent" ? ["buyer", "seller"].contains($0.role) : $0.role == "agent") } == true
                    guard allowed else { throw TradeAPIClient.Failure.rejected }
                    fields["visible_to"] = .object(["user_ids": .array([.id(visibility)])])
                }
                if let attachment {
                    if let pendingAttachmentID { fields["attachment_id"] = pendingAttachmentID }
                    else {
                        let upload = try await workspace.uploadImage(attachment, conversationID: id)
                        guard !upload["id"].isNull else { throw TradeAPIClient.Failure.invalidResponse }
                        pendingAttachmentID = upload["id"]
                        fields["attachment_id"] = upload["id"]
                    }
                }
                let result = try await workspace.write("/api/common/conversations/\(id)/messages", method: "POST", fields: fields)
                sent = try TradeAPIClient.decodeWorkspaceMessage(result["message"])
            } else if let reply { sent = try await api.send(text, to: id, replyingTo: reply.id) }
            else { sent = try await api.send(text, to: id) }
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
            reply = nil
            attachment = nil
            pendingAttachmentID = nil
            quoteText = nil
            merge([sent])
            notice = nil
        } catch TradeAPIClient.Failure.signInRequired {
            room = nil
            messages = []
            notice = TradeText.text("请返回交易系统重新登录。")
        } catch {
            sendNeedsReview = true
            notice = TradeText.text("未能确认消息是否发出，请刷新核对后再发送。")
        }
    }

    func markRead(through messageID: Int64) async {
        guard isVisible, !isMarkingRead, room?.access.role != nil, messageID > lastReadID,
              messages.contains(where: { $0.id == messageID }) else { return }
        isMarkingRead = true
        defer { isMarkingRead = false }
        do {
            try await api.markRead(conversationID: id, messageID: messageID)
            lastReadID = messageID
        } catch {
            // 已读同步失败不阻塞聊天发送，下一次滚动或刷新后重试。
        }
    }

    func selectAttachment(_ data: Data?) {
        attachment = data
        pendingAttachmentID = nil
    }

    func acknowledgeSend() {
        sendNeedsReview = false
        notice = nil
    }

    func acknowledgeAction() {
        actionNeedsReview = false
        notice = nil
    }

    func perform(_ action: TradeAction, confirmedRoom: TradeRoom) async {
        guard !isMutating, !actionNeedsReview, confirmedRoom.availableActions.contains(action),
              let confirmedTrade = confirmedRoom.trade else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            let fresh = try await api.room(id: id)
            room = fresh
            // 条款、进度、参与者或权限变化后，必须让用户看到新状态再确认。
            guard fresh.trade == confirmedTrade, fresh.access == confirmedRoom.access,
                  fresh.members == confirmedRoom.members, fresh.availableActions.contains(action) else {
                notice = TradeText.text("交易状态已变化，请核对最新信息后重新操作。")
                return
            }
        } catch {
            notice = TradeText.text("无法读取交易数据，请稍后重试。")
            return
        }
        do {
            try await api.perform(action, tradeID: confirmedTrade.id)
            notice = TradeText.text("操作已提交")
            await reload(quiet: true)
        } catch {
            actionNeedsReview = true
            notice = TradeText.text("未能确认操作结果，请刷新核对交易进度后再操作。")
            await reload(quiet: true)
        }
    }

    func saveTerms(_ terms: TradeTerms, confirmedRoom: TradeRoom) async -> Bool {
        guard !isMutating, !actionNeedsReview, confirmedRoom.canEditTerms, let trade = confirmedRoom.trade,
              terms.version == trade.version else { return false }
        isMutating = true
        defer { isMutating = false }
        do {
            let fresh = try await api.room(id: id)
            room = fresh
            guard fresh.canEditTerms, fresh.trade == trade, fresh.members == confirmedRoom.members else {
                notice = TradeText.text("交易状态已变化，请核对最新信息后重新操作。")
                return false
            }
        } catch {
            notice = TradeText.text("无法读取交易数据，请稍后重试。")
            return false
        }
        do {
            try await api.updateTerms(terms, tradeID: trade.id)
            notice = TradeText.text("交易信息已保存")
            await reload(quiet: true)
            return true
        } catch {
            actionNeedsReview = true
            notice = TradeText.text("未能确认操作结果，请刷新核对交易进度后再操作。")
            await reload(quiet: true)
            return false
        }
    }

    func copyInvitation() async {
        guard let room, let trade = room.trade, room.canInvite, !invitePending else { return }
        invitePending = true
        defer { invitePending = false }
        do {
            let url = try await api.invitation(for: trade.id)
            UIPasteboard.general.url = url
            notice = TradeText.text("已复制参与链接")
        } catch {
            notice = TradeText.text("未能取得参与链接，请稍后重试。")
        }
    }
}

final class TradeRoomViewController: UIHostingController<TradeRoomView> {
    private let model: TradeRoomModel
    init(id: Int64, api: TradeServing) {
        let model = TradeRoomModel(id: id, api: api)
        self.model = model
        super.init(rootView: TradeRoomView(model: model))
        title = TradeText.text("交易群聊")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.isVisible = false
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        model.isVisible = true
    }
}

struct TradeRoomView: View {
    @StateObject var model: TradeRoomModel
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var composerFocused: Bool
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 64
    @State private var search = ""
    @State private var detailsExpanded = false
    @State private var proposedAction: TradeAction?
    @State private var confirmedRoom: TradeRoom?
    @State private var editingTerms = false
    @State private var lastVisibleMessage: Int64?
    @State private var viewport = CGRect.zero
    @State private var scrolledInitially = false
    @State private var messageOperation: TradeOperation?
    @State private var history: TradeValue?
    @State private var imagePicker = false

    private var shownMessages: [TradeMessage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.messages.filter { query.isEmpty || ($0.content?.localizedStandardContains(query) == true)
            || ($0.sender?.username.localizedStandardContains(query) == true) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let room = model.room {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(room.conversation.displayTitle).fontWeight(.semibold)
                            HStack {
                                if let trade = room.trade { Text(TradePresentation.stage(trade.stage)) }
                                Spacer()
                                if let role = room.access.role { Text(TradePresentation.role(role)) }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let trade = room.trade, let index = trade.progressStep, let steps = trade.steps,
                               steps.indices.contains(index), trade.stage == "in_progress" {
                                Label(steps[index].label ?? steps[index].title ?? steps[index].key, systemImage: "circle.dotted")
                            }
                        }.padding(.vertical, 4)
                        DisclosureGroup(TradeText.text("交易信息与进度"), isExpanded: $detailsExpanded) {
                            TradeDetailsView(room: room)
                        }
                        if let api = model.workspace {
                            TradeAdvancedTermsView(api: api, room: room) { await model.reload(quiet: true) }
                        } else if room.canEditTerms {
                            Button(TradeText.text("编辑交易信息")) { editingTerms = true }
                                .disabled(model.isMutating || model.actionNeedsReview)
                        }
                        if room.canInvite {
                            Button {
                                Task { await model.copyInvitation() }
                            } label: { Label(TradeText.text("复制参与链接"), systemImage: "link") }
                            .disabled(model.invitePending)
                        }
                        ForEach(room.availableActions) { action in
                            Button(action.title) { confirmedRoom = room; proposedAction = action }
                                .disabled(model.isMutating || model.actionNeedsReview)
                        }
                        if model.isMutating { ProgressView() }
                        if let api = model.workspace {
                            TradeRoomManagement(api: api, roomID: model.id, room: room, currentUser: model.currentUser) { await model.reload(quiet: true) }
                        }
                    }
                }
                if let notice = model.notice {
                    Section {
                        Text(notice).foregroundStyle(.secondary)
                        if model.actionNeedsReview {
                            Button(TradeText.text("刷新交易状态")) { Task { await model.reload(quiet: true) } }
                            Button(TradeText.text("已核对操作结果")) { model.acknowledgeAction() }
                        }
                        if model.sendNeedsReview {
                            Button(TradeText.text("已核对，可再次发送")) { model.acknowledgeSend() }
                        }
                    }
                }
                if model.room == nil {
                    if model.isLoading { ProgressView() }
                    else { Button(TradeText.text("重试")) { Task { await model.reload() } } }
                } else {
                    if !model.pins.isEmpty {
                        Section(TradeText.text("置顶消息")) {
                            ForEach(Array(model.pins.enumerated()), id: \.offset) { _, pin in
                                Button(pin["content"].text ?? TradeText.text("消息")) {
                                    if let id = pin["id"].id { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                        }
                    }
                    Section(TradeText.text("交易群聊")) {
                        if model.hasMore {
                            Button(TradeText.text("加载更早的消息")) {
                                let anchor = shownMessages.first?.id
                                Task {
                                    await model.loadOlder()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }.disabled(model.isLoading)
                        }
                        if shownMessages.isEmpty {
                            Text(TradeText.text(search.isEmpty ? "暂无消息" : "没有匹配的消息"))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shownMessages) { message in
                            messageRow(message)
                                .id(message.id)
                                .background(GeometryReader { geometry in
                                    Color.clear.preference(key: TradeMessageFrames.self, value: [message.id: geometry.frame(in: .global)])
                                })
                        }
                    }
                }
            }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { viewport = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { viewport = $0 }
            })
            .onPreferenceChange(TradeMessageFrames.self) { frames in
                let visible = frames.filter { $0.value.intersects(viewport) && $0.value.height > 0 }.keys.max()
                lastVisibleMessage = visible
                if let visible, scenePhase == .active { Task { await model.markRead(through: visible) } }
            }
            .searchable(text: $search, prompt: TradeText.text("搜索已加载的消息"))
            .refreshable { await model.reload() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    if search.isEmpty, let last = model.messages.last?.id, lastVisibleMessage != last {
                        Button {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        } label: { Label(TradeText.text("回到最新消息"), systemImage: "arrow.down.circle") }.font(.callout)
                        .padding(8)
                    }
                    if model.room?.access.canWrite == true { composer(proxy: proxy) }
                    else if model.room != nil {
                        Text(TradeText.text("当前交易为只读，无法发送消息。"))
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }.background(Color(uiColor: .systemBackground))
            }
            .onChange(of: model.messages.last?.id) { _ in
                guard !scrolledInitially, search.isEmpty, let id = model.messages.last?.id else { return }
                scrolledInitially = true
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
        .tradeTypography()
        .onReceive(NotificationCenter.default.publisher(for: TradeLiveEvents.didReceive)) { notification in
            guard model.isVisible, scenePhase == .active else { return }
            if let event = notification.userInfo?["event"] as? TradeValue {
                if event["type"].text == "typing" || event["type"].text == "read" { return }
                if let id = event["conversation_id"].id, id != model.id { return }
            }
            Task { await model.reload(quiet: true) }
        }
        .task(id: model.isVisible && scenePhase == .active) {
            guard model.isVisible, scenePhase == .active else { return }
            model.live.start(conversationID: model.id)
            defer { model.live.stop() }
            await model.reload()
            if let id = lastVisibleMessage { await model.markRead(through: id) }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                await model.reload(quiet: true)
                if let id = lastVisibleMessage { await model.markRead(through: id) }
            }
        }
        .alert(proposedAction?.title ?? "", isPresented: Binding(get: { proposedAction != nil }, set: { if !$0 { proposedAction = nil } })) {
            Button(TradeText.text("取消"), role: .cancel) { proposedAction = nil }
            Button(TradeText.text("确认")) {
                if let action = proposedAction, let room = confirmedRoom {
                    Task { await model.perform(action, confirmedRoom: room) }
                }
                proposedAction = nil
            }
        } message: {
            if let action = proposedAction, let room = confirmedRoom {
                Text(action.explanation(in: room) + "\n\n" + actionSummary(room))
            }
        }
        .sheet(item: $messageOperation, onDismiss: { Task { await model.reload(quiet: true) } }) { operation in
            if let api = model.workspace { TradeOperationView(operation: operation, api: api) { _ in } }
        }
        .sheet(isPresented: Binding(get: { history != nil }, set: { if !$0 { history = nil } })) {
            if let history { TradeMessageHistory(data: history) }
        }
        .sheet(isPresented: $imagePicker) { TradeImagePicker { model.selectAttachment($0) } }
        .sheet(isPresented: $editingTerms) {
            if let room = model.room { TradeTermsView(model: model, room: room).tradeTypography() }
        }
    }

    private func actionSummary(_ room: TradeRoom) -> String {
        let roles = ["buyer", "seller", "agent"].map { role in
            let name = room.members?.first(where: { $0.role == role })?.username ?? TradeText.text("等待加入")
            return TradePresentation.role(role) + ": " + name
        }
        return ([room.conversation.displayTitle,
                 TradeText.text("物品价格") + ": " + TradePresentation.money(room.trade?.price),
                 TradeText.text("中介费") + ": " + TradePresentation.money(room.trade?.agentFee)] + roles).joined(separator: "\n")
    }

    private func messageRow(_ message: TradeMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(message.sender?.username ?? TradeText.text("系统消息")).fontWeight(.medium)
                if let sender = message.sender,
                   let role = model.room?.members?.first(where: { $0.id == sender.id })?.role {
                    Text(TradePresentation.role(role)).foregroundStyle(.secondary)
                }
            }.font(.caption)
            if let reply = message.replyTo {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reply.sender?.username ?? TradeText.text("回复消息")).font(.caption)
                    Text(reply.hidden == true ? TradeText.text("此消息的内容仅对指定参与者可见。") : reply.deleted == true && reply.content == nil ? TradeText.text("消息已删除") : message.quoteText ?? reply.content ?? "#\(reply.id)").lineLimit(2)
                }.foregroundStyle(.secondary).padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            if let recipients = message.visibleTo, !recipients.isEmpty {
                Label(TradeText.text("私密消息") + " · " + recipients.map(\.username).joined(separator: "、"), systemImage: "lock.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(messageText(message)).textSelection(.enabled)
            if message.type == "deleted", let content = message.content,
               model.room?.access.canModerate == true || message.deletionVisible == true {
                Text(content).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if message.hidden != true, message.type != "private_hidden", message.type != "deleted", message.deleted != true, let path = message.imageUrl, let api = model.workspace {
                TradeRemoteImage(api: api, path: path)
            }
            if let reactions = message.reactions, !reactions.isEmpty {
                Text(reactions.compactMap { ($0["emoji"].text ?? "") + " " + ($0["count"].text ?? "") }.joined(separator: "  ")).font(.caption)
            }
            if let stamp = TradePresentation.timestamp(message.createdAt) {
                Text(stamp).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        .contextMenu {
            if let text = message.content, ["text", "image"].contains(message.type ?? ""), message.deleted != true, message.hidden != true {
                Button { UIPasteboard.general.string = text } label: { Label(TradeText.text("复制消息"), systemImage: "doc.on.doc") }
                if model.room?.access.canWrite == true {
                    Button { model.reply = message; model.quoteText = nil; composerFocused = true } label: { Label(TradeText.text("回复消息"), systemImage: "arrowshape.turn.up.left") }
                    Button { model.reply = message; model.quoteText = text; composerFocused = true } label: { Label(TradeText.text("引用消息"), systemImage: "text.quote") }
                }
            }
            if let room = model.room, let api = model.workspace {
                TradeMessageActions(message: message, room: room, currentUser: model.currentUser, api: api, conversationID: model.id,
                                    operation: $messageOperation, history: $history)
            }
        }
    }

    private func composer(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.workspace != nil {
                HStack {
                    Menu {
                        Button(TradeText.text("添加图片")) { imagePicker = true }
                        ForEach(Array(model.quickMessages.enumerated()), id: \.offset) { _, text in
                            Button(text) { model.draft = text }
                        }
                    } label: { Label(TradeText.text("快捷操作"), systemImage: "plus.circle") }.font(.callout)
                    Spacer()
                    Menu {
                        Button(TradeText.text("对所有人可见")) { model.visibility = nil }
                        ForEach((model.room?.members ?? []).filter { member in
                            model.room?.access.role == "agent" ? ["buyer", "seller"].contains(member.role) : member.role == "agent"
                        }, id: \.id) { member in
                            if let id = member.id { Button(member.username ?? TradePresentation.role(member.role)) { model.visibility = id } }
                        }
                    } label: { Label(TradeText.text(model.visibility == nil ? "对所有人可见" : "私密发送"), systemImage: model.visibility == nil ? "person.2" : "lock") }.font(.caption)
                }
                if let data = model.attachment, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 100).accessibilityLabel(TradeText.text("已选择图片"))
                    HStack { Label(TradeText.text("已选择图片"), systemImage: "photo"); Spacer(); Button(TradeText.text("移除")) { model.selectAttachment(nil) } }.font(.caption)
                }
            }
            if let reply = model.reply {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(reply.sender?.username ?? TradeText.text("回复消息")).font(.caption).foregroundStyle(.secondary)
                        Text(reply.content ?? "#\(reply.id)").lineLimit(2)
                    }
                    Spacer()
                    Button { model.reply = nil; model.quoteText = nil } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 20)) }
                        .frame(minWidth: 44, minHeight: 44).accessibilityLabel(TradeText.text("取消回复"))
                }
            }
            HStack(alignment: .bottom, spacing: 12) {
                TextEditor(text: $model.draft)
                    .focused($composerFocused)
                    .frame(height: min(editorHeight, 160))
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(TradeText.text("输入消息"))
                    .accessibilityIdentifier("trade-message-field")
                Button {
                    Task {
                        await model.send()
                        if !model.sendNeedsReview, let last = model.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                } label: {
                    if model.isSending { ProgressView() }
                    else { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                }
                .accessibilityLabel(TradeText.text("发送"))
                .disabled(model.isSending || model.sendNeedsReview || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachment == nil))
                .frame(minWidth: 44, minHeight: 44)
                Button { composerFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down").font(.system(size: 22)) }
                    .frame(minWidth: 44, minHeight: 44).accessibilityLabel(TradeText.text("收起键盘"))
            }
        }.padding(.horizontal).padding(.vertical, 8)
    }

    private func messageText(_ message: TradeMessage) -> String {
        if message.hidden == true || message.type == "private_hidden" { return TradeText.text("此消息的内容仅对指定参与者可见。") }
        if message.type == "deleted" || message.deleted == true { return TradeText.text("消息已删除") }
        if let content = message.content, !content.isEmpty { return content }
        return TradeText.text("此消息不是文字，暂无法在 App 内查看。")
    }
}


private struct TradeMessageFrames: PreferenceKey {
    static var defaultValue: [Int64: CGRect] { [:] }
    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
