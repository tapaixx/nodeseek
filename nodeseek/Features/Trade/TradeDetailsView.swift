import SwiftUI

struct TradeInfoRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
    }
}

struct TradeDetailsView: View {
    let room: TradeRoom
    var body: some View {
        if let trade = room.trade {
            TradeInfoRow(title: TradeText.text("交易编号"), value: "#\(trade.id)")
            TradeInfoRow(title: TradeText.text("物品价格"), value: TradePresentation.money(trade.price))
            if let note = trade.priceNote, !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            TradeInfoRow(title: TradeText.text("中介费"), value: TradePresentation.money(trade.agentFee))
            if let note = trade.agentFeeNote, !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.secondary) }
            if let payer = trade.feePayer {
                TradeInfoRow(title: TradeText.text("费用承担方"), value: payer == "split" ? TradeText.text("买卖双方均摊") : TradePresentation.role(payer))
            }
            if let brand = trade.brand, !brand.isEmpty { TradeInfoRow(title: TradeText.text("品牌"), value: brand) }
            if let delivery = trade.deliveryMethod, !delivery.isEmpty {
                TradeInfoRow(title: TradeText.text("交货方式"), value: deliveryTitle(delivery))
            }
            if let url = TradePresentation.postURL(trade.postUrl) {
                Link(destination: url) { Label(TradeText.text("查看关联帖子"), systemImage: "doc.text") }
                    .frame(minHeight: 44)
            }
            Text(TradeText.text("参与者")).fontWeight(.semibold).padding(.top, 8)
            ForEach(["buyer", "seller", "agent"], id: \.self) { role in
                TradeInfoRow(title: TradePresentation.role(role),
                             value: room.members?.first(where: { $0.role == role })?.username ?? TradeText.text("等待加入"))
            }
            if trade.stage == "finalized" {
                TradeInfoRow(title: TradePresentation.role("buyer"), value: TradeText.text(trade.buyerConfirmedAt == nil ? "等待确认" : "已确认"))
                TradeInfoRow(title: TradePresentation.role("seller"), value: TradeText.text(trade.sellerConfirmedAt == nil ? "等待确认" : "已确认"))
            }
            if trade.proposal != nil { Text(TradeText.text("有待处理的三方申请，交易进度暂时暂停。")).foregroundStyle(.secondary) }
            if trade.freeChatAt != nil { Text(TradeText.text("流程辅助已关闭，请在群聊中与三方核对交易安排。")).foregroundStyle(.secondary) }
            if trade.redPacket != nil { Text(TradeText.text("此交易涉及积分托管，当前仅展示进度。")).foregroundStyle(.secondary) }
            if let steps = trade.steps {
                Text(TradeText.text("交易进度")).fontWeight(.semibold).padding(.top, 8)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: progressIcon(index, trade: trade))
                            .foregroundStyle(index < (trade.progressStep ?? 0) ? .primary : .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(step.label ?? step.title ?? step.key)
                            if let roles = step.roles, !roles.isEmpty {
                                Text(roles.map(TradePresentation.role).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }
    }

    private func deliveryTitle(_ value: String) -> String {
        switch value {
        case "official_push": TradeText.text("官方转移")
        case "change_email": TradeText.text("更改邮箱")
        case "original_email": TradeText.text("提供原邮箱")
        case "other": TradeText.text("其他")
        default: value
        }
    }

    private func progressIcon(_ index: Int, trade: TradeRoom.Progress) -> String {
        if trade.stage == "completed" || index < (trade.progressStep ?? 0) { return "checkmark.circle.fill" }
        if trade.stage == "in_progress", index == trade.progressStep { return "circle.inset.filled" }
        return "circle"
    }
}

struct TradeTermsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TradeRoomModel
    let room: TradeRoom
    @State private var title: String
    @State private var price: String
    @State private var fee: String
    @State private var payer: String
    @State private var post: String
    @State private var confirming = false
    @State private var attempted = false
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case title, price, fee, post }

    init(model: TradeRoomModel, room: TradeRoom) {
        self.model = model
        self.room = room
        _title = State(initialValue: room.trade?.title ?? room.conversation.title ?? "")
        _price = State(initialValue: room.trade?.price?.value ?? "")
        _fee = State(initialValue: room.trade?.agentFee?.value ?? "")
        _payer = State(initialValue: room.trade?.feePayer ?? "")
        _post = State(initialValue: room.trade?.postUrl ?? "")
    }

    private var isValid: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty && cleanTitle.count <= 120
            && (price.isEmpty || TradeTerms.amount(price) != nil)
            && (fee.isEmpty || TradeTerms.amount(fee) != nil)
            && (post.isEmpty || TradePresentation.postURL(post) != nil)
            && room.canEditTerms
    }

    var body: some View {
        NavigationView {
            Form {
                Section(TradeText.text("交易标题")) {
                    TextField(TradeText.text("交易标题"), text: $title).focused($focusedField, equals: .title)
                        .submitLabel(.next).onSubmit { focusedField = .price }
                }
                Section(TradeText.text("交易金额（人民币）")) {
                    TextField(TradeText.text("物品价格"), text: $price).keyboardType(.decimalPad).focused($focusedField, equals: .price)
                    TextField(TradeText.text("中介费"), text: $fee).keyboardType(.decimalPad).focused($focusedField, equals: .fee)
                    ForEach(["", "buyer", "seller", "split"], id: \.self) { value in
                        Button { payer = value } label: {
                            HStack(alignment: .top) {
                                Text(value.isEmpty ? TradeText.text("未指定") : value == "split" ? TradeText.text("买卖双方均摊") : TradePresentation.role(value))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                if payer == value { Image(systemName: "checkmark").font(.system(size: 18)) }
                            }.frame(minHeight: 44)
                        }.accessibilityAddTraits(payer == value ? .isSelected : [])
                    }
                    if (!price.isEmpty && TradeTerms.amount(price) == nil) || (!fee.isEmpty && TradeTerms.amount(fee) == nil) {
                        Text(TradeText.text("金额须为非负数，最多两位小数。")).foregroundStyle(.secondary)
                    }
                }
                Section(TradeText.text("关联帖子")) {
                    TextField("https://www.nodeseek.com/…", text: $post)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .post).submitLabel(.done)
                        .onSubmit { focusedField = nil }.accessibilityLabel(TradeText.text("关联帖子"))
                    if !post.isEmpty, TradePresentation.postURL(post) == nil {
                        Text(TradeText.text("请填写 NodeSeek 的 HTTPS 帖子链接。")).foregroundStyle(.secondary)
                    }
                }
                Text(TradeText.text("保存后所有参与者都能看到修改，最终条款仍需中介敲定和买卖双方确认。"))
                    .font(.footnote).foregroundStyle(.secondary)
                if let notice = model.notice, attempted { Text(notice).foregroundStyle(.secondary) }
            }
            .disabled(model.isMutating)
            .navigationTitle(TradeText.text("编辑交易信息"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(TradeText.text("取消")) { dismiss() }.disabled(model.isMutating) }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isMutating { ProgressView() }
                    else { Button(TradeText.text("保存")) { focusedField = nil; confirming = true }
                        .disabled(!isValid || model.actionNeedsReview) }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(TradeText.text("收起键盘")) { focusedField = nil }
                }
            }
            .alert(TradeText.text("保存交易信息？"), isPresented: $confirming) {
                Button(TradeText.text("取消"), role: .cancel) {}
                Button(TradeText.text("保存")) {
                    guard let version = room.trade?.version else { return }
                    let terms = TradeTerms(version: version, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        price: TradeTerms.amount(price), agentFee: TradeTerms.amount(fee), feePayer: payer.isEmpty ? nil : payer,
                        postUrl: post.isEmpty ? nil : post)
                    attempted = true
                    Task { if await model.saveTerms(terms, confirmedRoom: room) { dismiss() } }
                }
            } message: { Text(TradeText.text("保存后所有参与者都能看到修改，最终条款仍需中介敲定和买卖双方确认。")) }
        }.interactiveDismissDisabled(model.isMutating)
    }
}
