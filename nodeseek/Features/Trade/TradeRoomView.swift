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

    private let id: Int64
    private let api: TradeServing
    private var isLoading = false

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
            if messages.isEmpty { hasMore = page.hasMore }
            merge(page.messages)
            if !quiet, !sendNeedsReview { notice = nil }
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
        guard room?.access.canWrite == true, !text.isEmpty, !isSending, !sendNeedsReview else { return }
        isSending = true
        defer { isSending = false }
        do {
            let sent = try await api.send(text, to: id)
            if draft.trimmingCharacters(in: .whitespacesAndNewlines) == text { draft = "" }
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

    func acknowledgeSend() {
        sendNeedsReview = false
        notice = nil
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

struct TradeRoomView: View {
    @StateObject var model: TradeRoomModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let room = model.room {
                    Section(TradeText.text("交易进度")) {
                        Text(room.conversation.displayTitle)
                            .font(.headline)
                        if let trade = room.trade {
                            Text(stageTitle(trade.stage)).foregroundStyle(.secondary)
                            if let steps = trade.steps, let index = trade.progressStep,
                               steps.indices.contains(index), trade.stage == "in_progress",
                               let label = steps[index].label ?? steps[index].title {
                                Text(label).foregroundStyle(.secondary)
                            }
                        }
                        if room.canInvite {
                            Button(TradeText.text("复制参与链接")) { Task { await model.copyInvitation() } }
                                .disabled(model.invitePending)
                        }
                    }
                }
                if let notice = model.notice { Text(notice).foregroundStyle(.secondary) }
                if model.sendNeedsReview {
                    Button(TradeText.text("已核对，可再次发送")) { model.acknowledgeSend() }
                }
                if model.room == nil {
                    if model.notice == nil { ProgressView() }
                    else { Button(TradeText.text("重试")) { Task { await model.reload() } } }
                } else {
                    Section(TradeText.text("交易群聊")) {
                        if model.hasMore { Button(TradeText.text("加载更早的消息")) { Task { await model.loadOlder() } } }
                        if model.messages.isEmpty { Text(TradeText.text("暂无消息")).foregroundStyle(.secondary) }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(message.sender?.username ?? TradeText.text("系统消息"))
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(messageText(message)).textSelection(.enabled)
                                if let stamp = message.createdAt, let date = ISO8601DateFormatter().date(from: stamp)
                                    ?? fractionalDate(stamp) {
                                    Text(date.formatted(.dateTime.year().month().day().hour().minute().second()))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .id(message.id)
                        }
                    }
                }
            }
            .refreshable { await model.reload() }
            .safeAreaInset(edge: .bottom) {
                if model.room?.access.canWrite == true {
                    HStack(spacing: 12) {
                        TextField(TradeText.text("输入消息"), text: $model.draft)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("trade-message-field")
                        Button(TradeText.text("发送")) {
                            Task {
                                await model.send()
                                if let last = model.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        }
                        .disabled(model.isSending || model.sendNeedsReview || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(minHeight: 44)
                    }
                    .padding(.horizontal)
                    .background(.regularMaterial)
                }
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.reload()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                await model.reload(quiet: true)
            }
        }
    }

    private func fractionalDate(_ stamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: stamp)
    }

    private func messageText(_ message: TradeMessage) -> String {
        if message.type == "deleted" { return TradeText.text("消息已删除") }
        if let content = message.content, !content.isEmpty { return content }
        return TradeText.text("此消息不是文字，暂无法在 App 内查看。")
    }

    private func stageTitle(_ stage: String) -> String {
        switch stage {
        case "draft": TradeText.text("待敲定")
        case "finalized": TradeText.text("待确认")
        case "in_progress": TradeText.text("交易进行中")
        case "unlock_pending": TradeText.text("等待解锁确认")
        case "completed": TradeText.text("已完成")
        case "cancelled": TradeText.text("已取消")
        default: TradeText.text("未知进度")
        }
    }
}
