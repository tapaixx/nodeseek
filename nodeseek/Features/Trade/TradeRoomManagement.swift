import SwiftUI

struct TradeRoomManagement: View {
    let api: TradeWorkspaceServing
    let roomID: Int64
    let room: TradeRoom
    let currentUser: TradeUser?
    let reload: () async -> Void
    @State private var operation: TradeOperation?
    @StateObject private var reviews: TradePageModel
    @StateObject private var approvers: TradePageModel
    @State private var observerQuery = ""
    @State private var users: [TradeValue] = []
    @State private var invitation: String?
    @State private var failure: String?
    init(api: TradeWorkspaceServing, roomID: Int64, room: TradeRoom, currentUser: TradeUser?, reload: @escaping () async -> Void) {
        self.api = api; self.roomID = roomID; self.room = room; self.currentUser = currentUser; self.reload = reload
        _reviews = StateObject(wrappedValue: TradePageModel(api: api)); _approvers = StateObject(wrappedValue: TradePageModel(api: api))
    }
    private var member: Bool { ["buyer", "seller", "agent"].contains(room.access.role ?? "") }
    private var active: Bool { room.conversation.status == "open" }
    private var agent: Bool { room.access.role == "agent" }
    private var base: String { "/api/common/trades/\(room.trade?.id ?? 0)" }
    var body: some View {
        DisclosureGroup(TradeText.text("交易管理与评价")) {
            if let trade = room.trade {
                if active, member {
                    if let proposal = trade.proposal {
                        Text(TradeText.text(proposal.kind == "reset" ? "等待三方同意重置交易" : "等待三方同意关闭流程辅助"))
                        let agreed = room.access.role == "buyer" ? proposal.buyerAt : room.access.role == "seller" ? proposal.sellerAt : proposal.agentAt
                        if agreed == nil { action("同意申请", suffix: "proposal-agree", explanation: "三方同意后立即执行申请。重置会清空进度，关闭流程辅助不可恢复。") }
                        action(proposal.by == currentUser?.id ? "撤回申请" : "拒绝申请", suffix: "proposal-reject", explanation: "申请结束，交易按当前条款继续。")
                    } else if trade.escrowTaskId == nil && trade.redPacket == nil && trade.freeChatAt == nil {
                        if agent, trade.stage == "in_progress" { action("申请解锁", suffix: "unlock-request", explanation: "需要买卖双方同意，期间交易进度暂停。") }
                        if Set((room.members ?? []).map(\.role)).isSuperset(of: ["buyer", "seller", "agent"]) {
                            action("申请重置交易", suffix: "proposal", explanation: "需要三方同意，重置后条款和进度重新确认。已转账款项不会自动退回。", fields: ["kind": .string("reset")])
                            action("申请关闭流程辅助", suffix: "proposal", explanation: "需要三方同意；关闭后流程提示不可恢复，交易由三方在聊天中决定。", fields: ["kind": .string("free_chat")])
                        }
                    }
                    if trade.stage == "in_progress", trade.freeChatAt == nil, trade.proposal == nil,
                       let index = trade.progressStep, let steps = trade.steps, index > 0, steps.indices.contains(index - 1),
                       steps[index - 1].roles?.contains(room.access.role ?? "") == true,
                       !(trade.redPacket != nil && ["buyer_paid", "agent_received", "agent_released"].contains(steps[index - 1].key)),
                       !(trade.escrowTaskId != nil && steps[index - 1].key == "seller_shipped") {
                        action("撤销上一步进度", suffix: "progress-undo", explanation: "只撤销进度记录，不会撤销实际转账或已交付的货物，请先与三方核对。", destructive: true)
                    }
                    if agent, trade.freeChatAt != nil { action("确认交易完成", suffix: "free-chat-complete", explanation: "确认后交易计入统计并转为只读，无法撤销。", destructive: true) }
                    if trade.stage == "draft", trade.progressStep == 0, trade.resetAt == nil, trade.proposal == nil, trade.escrowTaskId == nil {
                        action("退出交易", suffix: "leave", explanation: "退出后释放身份，需要通过邀请重新加入。", destructive: true)
                        ForEach(["buyer", "seller", "agent"].filter { candidate in
                            !(room.members ?? []).contains { $0.role == candidate } && (candidate != "agent" || ["agent", "admin"].contains(currentUser?.role ?? ""))
                        }, id: \.self) { candidate in
                            action(TradeText.text("更换身份") + ": " + TradePresentation.role(candidate), suffix: "role", explanation: "将释放当前身份并切换为所选身份。", fields: ["role": .string(candidate)])
                        }
                    }
                    if agent || currentUser?.role == "admin" || (trade.stage == "draft" && !(room.members ?? []).contains { $0.role == "agent" }) {
                        action("取消交易", suffix: "cancel", explanation: "取消后聊天只读。托管货物已发出时，关联托管任务也可能关闭，无法恢复。", destructive: true)
                    }
                    if agent {
                        TradeParticipantPicker(api: api, selectedID: $observerQuery)
                        if let observerID = Int64(observerQuery) {
                            action("邀请旁观者", suffix: "observers", explanation: "被邀请者可以查看允许旁观的内容，不能发送消息。", fields: ["user_id": .id(observerID)])
                        }
                        Button(TradeText.text("复制旁观邀请")) {
                            operation = .init(title: TradeText.text("创建旁观邀请"), explanation: TradeText.text("持有链接的已登录用户可申请旁观，请只发给可信对象。"), path: base + "/invites", fields: ["kind": .string("observer")], secretResult: true)
                        }
                        ForEach((room.members ?? []).filter { $0.role == "observer" && $0.id != nil }, id: \.id) { observer in
                            action(TradeText.text("移出旁观者") + ": " + (observer.username ?? ""), suffix: "observers/\(observer.id!)", explanation: "移出后不能通过原链接重新加入，除非中介重新邀请。", method: "DELETE", destructive: true)
                        }
                    }
                }
                if agent || currentUser?.role == "admin" {
                    Button(TradeText.text(room.conversation.isPublic == true ? "取消公开聊天" : "公开聊天记录")) {
                        operation = .init(title: TradeText.text("聊天公开范围"), explanation: TradeText.text("公开后所有登录用户可查看；私密内容仍按权限显示。请确认所有参与者知悉。"),
                            path: "/api/common/conversations/\(roomID)/public", fields: ["public": .bool(room.conversation.isPublic != true)], irreversible: true)
                    }
                }
                if ["completed", "cancelled"].contains(trade.stage) { tradeReviews }
                if member, trade.redPacket != nil, room.access.canWrite, trade.stage == "in_progress",
                   let index = trade.progressStep, let steps = trade.steps, steps.indices.contains(index), steps[index].roles?.contains(room.access.role ?? "") == true {
                    action(steps[index].label ?? "确认交易进度", suffix: "progress", explanation: "此操作可能实际划转积分。请核对发行中介、收款人、积分数量和交货结果，提交后可能无法撤销。", fields: ["step": .string(steps[index].key)], destructive: true)
                }
            } else if room.conversation.type == "private" {
                privateActions
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
        }
        .sheet(item: $operation, onDismiss: { Task { await reload() } }) { operation in
            TradeOperationView(operation: operation, api: api) { _ in Task { await reload() } }
        }
    }
    private func action(_ title: String, suffix: String, explanation: String, method: String = "POST", fields: [String: TradeValue] = [:], destructive: Bool = false) -> some View {
        Button(TradeText.text(title), role: destructive ? .destructive : nil) {
            Task {
                do {
                    let path = "/api/common/conversations/\(roomID)"
                    let snapshot = try await api.read(path, query: [:])
                    guard snapshot["trade"]["version"].integer == room.trade?.version,
                          snapshot["trade"]["stage"].text == room.trade?.stage,
                          snapshot["access"]["can_write"].flag == room.access.canWrite else {
                        failure = TradeText.text("交易状态已变化，请核对最新信息后重新操作。")
                        await reload(); return
                    }
                    operation = .init(title: TradeText.text(title), explanation: TradeText.text(explanation) + "\n" + summary,
                        path: base + "/" + suffix, method: method, fields: fields, irreversible: destructive,
                        guardPath: path, guardValue: snapshot)
                } catch { failure = error.localizedDescription }
            }
        }
    }
    private var summary: String {
        ([room.conversation.displayTitle, TradeText.text("物品价格") + ": " + TradePresentation.money(room.trade?.price),
          TradeText.text("中介费") + ": " + TradePresentation.money(room.trade?.agentFee),
          TradeText.text("红包积分") + ": " + (room.trade?.redPacket?.amount?.value ?? "—")] + (room.members ?? []).map {
            TradePresentation.role($0.role) + ": " + ($0.username ?? "—")
        }).joined(separator: "\n")
    }
    @ViewBuilder private var tradeReviews: some View {
        TradeFailureView(model: reviews) { Task { await reviews.load(base + "/reviews") } }
        ForEach(Array(reviews.data["targets"].list.enumerated()), id: \.offset) { _, target in
            TradeBusinessRow(title: target["user"].name, subtitle: target["review"]["comment"].text, trailing: target["review"]["score"].text)
            if reviews.data["can_review"].flag, target["review"].isNull {
                Button(TradeText.text("评价交易方")) {
                    operation = .init(title: TradeText.text("评价交易方"), explanation: TradeText.text("交易评价会公开展示，提交后可能无法修改，请基于实际经历填写。"), path: base + "/reviews", inputs: [
                        .init(key: "score", title: "评分", kind: .choice((1...5).map { .init(value: String($0), title: String($0)) }), required: true, initial: "5"),
                        .init(key: "comment", title: "评价内容", kind: .multiline, limit: 1000)
                    ], fields: ["reviewee_id": target["user"]["id"]], irreversible: true)
                }
            }
        }.task { await reviews.load(base + "/reviews") }
    }
    private func publicationRequest(approverOnly: Bool) async {
        await approvers.load("/api/common/private/\(roomID)/approvers")
        guard approvers.error == nil else { failure = approvers.error; return }
        let choices = approvers.data["approvers"].list.compactMap { item -> TradeOption? in
            guard let id = item["id"].text else { return nil }
            return .init(value: id, title: item.name)
        }
        operation = .init(title: TradeText.text(approverOnly ? "选择中介审批" : "申请公开聊天"),
            explanation: TradeText.text("申请公开后对方或所选审批者可决定可见范围，审批期间审批者可查看聊天。"),
            path: "/api/common/private/\(roomID)/" + (approverOnly ? "publish-approver" : "publish-request"),
            inputs: [.init(key: "approver_id", title: "审批者", kind: .choice(choices), required: approverOnly)]
                + (approverOnly ? [] : [.init(key: "reason", title: "原因", kind: .multiline, limit: 1000)]), irreversible: true)
    }
    @ViewBuilder private var privateActions: some View {
        if let request = room.publishRequest, request["status"].text == "pending",
           currentUser?.role == "admin" || (currentUser?.role == "agent" && request["approver_id"].id == currentUser?.id),
           let requestID = request["id"].text {
            ForEach([true, false], id: \.self) { approve in
                Button(TradeText.text(approve ? "同意公开" : "拒绝公开")) {
                    operation = .init(title: TradeText.text("审批公开申请"), explanation: TradeText.text("批准后所有登录用户可查看聊天记录，私密内容仍保留原权限。"),
                        path: "/api/agent/publish-requests/\(requestID)/decision", fields: ["approve": .bool(approve)], irreversible: true)
                }
            }
        }
        if active, room.access.role == "member" {
            Button(TradeText.text("关闭私聊"), role: .destructive) {
                operation = .init(title: TradeText.text("关闭私聊"), explanation: TradeText.text("双方将无法继续发送消息，不能重新打开，需要重新申请私聊。"), path: "/api/common/private/\(roomID)/close", irreversible: true)
            }
            Button(TradeText.text("申请公开聊天")) { Task { await publicationRequest(approverOnly: false) } }
            if let request = room.publishRequest, request["status"].text == "pending" {
                if request["requested_by"].id == currentUser?.id {
                    Button(TradeText.text("选择中介审批")) { Task { await publicationRequest(approverOnly: true) } }
                    Button(TradeText.text("撤回公开申请")) { operation = .init(title: TradeText.text("撤回公开申请"), explanation: TradeText.text("撤回后聊天保持原来的可见范围。"), path: "/api/common/private/\(roomID)/publish-cancel") }
                } else {
                    ForEach([true, false], id: \.self) { approve in
                        Button(TradeText.text(approve ? "同意公开" : "拒绝公开")) {
                            operation = .init(title: TradeText.text(approve ? "同意公开" : "拒绝公开"), explanation: TradeText.text("同意后所有登录用户可查看聊天记录；拒绝后对方仍可申请中介审批。"), path: "/api/common/private/\(roomID)/publish-peer", fields: ["approve": .bool(approve)], irreversible: true)
                        }
                    }
                }
            }
        }
    }
}
