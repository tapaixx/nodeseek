import Foundation
import SwiftUI
import UIKit

// 所有操作入口共用这份状态判断；提交前再读取服务器，防止用旧进度确认资金或货物。
enum TradeAction: String, Identifiable {
    case finalize, confirm, reject, unlockConfirm, unlockReject
    case buyerPaid, agentReceived, sellerShipped, buyerInspected, agentReleased, sellerReceived, completed

    var id: String { rawValue }
    var endpoint: String {
        switch self {
        case .finalize: "finalize"
        case .confirm: "confirm"
        case .reject: "reject"
        case .unlockConfirm: "unlock-confirm"
        case .unlockReject: "unlock-reject"
        default: "progress"
        }
    }
    var step: String? {
        switch self {
        case .buyerPaid: "buyer_paid"
        case .agentReceived: "agent_received"
        case .sellerShipped: "seller_shipped"
        case .buyerInspected: "buyer_inspected"
        case .agentReleased: "agent_released"
        case .sellerReceived: "seller_received"
        case .completed: "completed"
        default: nil
        }
    }
    var title: String {
        let key = switch self {
        case .finalize: "敲定交易信息"
        case .confirm: "确认交易信息"
        case .reject: "退回修改"
        case .unlockConfirm: "同意解锁"
        case .unlockReject: "拒绝解锁"
        case .buyerPaid: "我已付款给中介"
        case .agentReceived: "我已收到买家付款"
        case .sellerShipped: "确认放货"
        case .buyerInspected: "确认验货通过"
        case .agentReleased: "确认向卖家放款"
        case .sellerReceived: "我已收到中介放款"
        case .completed: "确认交易完成"
        }
        return TradeText.text(key)
    }
    func explanation(in room: TradeRoom) -> String {
        let key = switch self {
        case .finalize: "请核对金额、费用和交货方式。敲定后将等待买卖双方确认。"
        case .confirm: "请核对全部交易条款。买卖双方均确认后，交易信息将锁定。"
        case .reject: "交易信息会退回可编辑状态，需要重新敲定和确认。"
        case .unlockConfirm: "买卖双方均同意后，条款将解锁，需要重新敲定和确认。"
        case .unlockReject: "交易信息将保持锁定。"
        case .buyerPaid: "请在实际付款完成后确认。此操作只记录进度，不会替你转账。"
        case .agentReceived: "请核对实际到账金额后确认，随后卖家可以放货。"
        case .sellerShipped: room.trade?.escrowTaskId != nil
            ? "托管货物信息会发送给买家，发出后无法撤销。请核对交易条款和收款状态。"
            : "请在实际交付货物后确认，随后买家可以验货。"
        case .buyerInspected: "请确认货物符合约定。确认后，中介将可以向卖家放款。"
        case .agentReleased: "请在实际向卖家放款后确认。此操作只记录进度，不会替你转账。"
        case .sellerReceived: "请核对中介放款已实际到账后确认。"
        case .completed: "确认后交易计入统计，聊天转为只读，无法撤销。"
        }
        return TradeText.text(key)
    }
}

extension TradeRoom {
    var canEditTerms: Bool {
        conversation.status == "open" && access.canWrite && trade?.stage == "draft"
            && ["buyer", "seller", "agent"].contains(access.role ?? "")
            && trade?.version != nil && trade?.proposal == nil && trade?.escrowTaskId == nil && trade?.redPacket == nil
    }

    var availableActions: [TradeAction] {
        guard conversation.status == "open", access.canWrite, let trade,
              trade.proposal == nil, trade.freeChatAt == nil,
              let role = access.role, ["buyer", "seller", "agent"].contains(role) else { return [] }
        switch trade.stage {
        case "draft":
            return role == "agent" && Set((members ?? []).map(\.role)).isSuperset(of: ["buyer", "seller", "agent"])
                ? [.finalize] : []
        case "finalized":
            if role == "agent" { return [.reject] }
            let confirmed = role == "buyer" ? trade.buyerConfirmedAt : trade.sellerConfirmedAt
            return confirmed == nil ? [.confirm, .reject] : []
        case "unlock_pending":
            if role == "agent" { return [.unlockReject] }
            let confirmed = role == "buyer" ? trade.unlockBuyerAt : trade.unlockSellerAt
            return confirmed == nil ? [.unlockConfirm, .unlockReject] : []
        case "in_progress":
            guard let index = trade.progressStep, let steps = trade.steps, steps.indices.contains(index),
                  steps[index].roles?.contains(role) == true,
                  let action = [TradeAction.buyerPaid, .agentReceived, .sellerShipped, .buyerInspected,
                                .agentReleased, .sellerReceived, .completed].first(where: { $0.step == steps[index].key }) else { return [] }
            // 积分红包会实际划转余额，需要单独接入金额与收款人核验后再开放。
            if trade.redPacket != nil { return [] }
            return [action]
        default: return []
        }
    }
}

struct TradeTerms: Encodable {
    let version: Int
    var title: String
    var price: String?
    var agentFee: String?
    var feePayer: String?
    var postUrl: String?
    let priceCurrency = "CNY"
    let agentFeeCurrency = "CNY"

    enum CodingKeys: String, CodingKey {
        case version, title, price, agentFee, feePayer, postUrl, priceCurrency, agentFeeCurrency
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(title, forKey: .title)
        try container.encode(price, forKey: .price)
        try container.encode(agentFee, forKey: .agentFee)
        try container.encode(feePayer, forKey: .feePayer)
        try container.encode(postUrl, forKey: .postUrl)
        try container.encode(priceCurrency, forKey: .priceCurrency)
        try container.encode(agentFeeCurrency, forKey: .agentFeeCurrency)
    }

    static func amount(_ raw: String, locale: Locale = .current) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let separator = locale.decimalSeparator ?? "."
        let normalized = trimmed.replacingOccurrences(of: separator, with: ".")
        guard normalized.range(of: #"^\d{1,12}(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value >= 0 else { return nil }
        return NSDecimalNumber(decimal: value).stringValue
    }
}

enum TradeInvitationLink {
    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 512 && token.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
    static func token(from input: String) -> String? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "agent.nodeseek.org", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let pieces = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 4, pieces[0].isEmpty, pieces[1] == "chat", pieces[2] == "invite",
              isValidToken(String(pieces[3])) else { return nil }
        return String(pieces[3])
    }
}

enum TradePresentation {
    static func role(_ role: String) -> String {
        switch role {
        case "buyer": TradeText.text("买家")
        case "seller": TradeText.text("卖家")
        case "agent": TradeText.text("中介")
        case "observer": TradeText.text("旁观者")
        default: TradeText.text("参与者")
        }
    }
    static func stage(_ stage: String) -> String {
        let key = switch stage {
        case "draft": "待敲定"
        case "finalized": "待确认"
        case "in_progress": "交易进行中"
        case "unlock_pending": "等待解锁确认"
        case "completed": "已完成"
        case "cancelled": "已取消"
        default: "未知进度"
        }
        return TradeText.text(key)
    }
    static func timestamp(_ stamp: String?) -> String? {
        guard let stamp, !stamp.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return stamp }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmssSSS")
        return formatter.string(from: date)
    }
    static func money(_ amount: TradeAmount?) -> String {
        guard let amount, let value = Decimal(string: amount.value, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
        return value.formatted(.currency(code: "CNY"))
    }
    static func postURL(_ raw: String?) -> URL? {
        guard let raw, let url = URL(string: raw), url.scheme == "https",
              ["www.nodeseek.com", "nodeseek.com"].contains(url.host ?? ""),
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// 系统 Dynamic Type 与应用内字号各缩放一次，整个交易模块共用。
private struct TradeTypography: ViewModifier {
    @State private var pointOffset = AppTextSizeSettings.shared.pointOffset
    @ScaledMetric(relativeTo: .body) private var systemSize: CGFloat = 17
    func body(content: Content) -> some View {
        content.font(.system(size: (17 + pointOffset) * systemSize / 17))
            .onReceive(NotificationCenter.default.publisher(for: AppTextSizeSettings.didChangeNotification)) { _ in
                pointOffset = AppTextSizeSettings.shared.pointOffset
            }
    }
}

extension View {
    func tradeTypography() -> some View { modifier(TradeTypography()) }
}
