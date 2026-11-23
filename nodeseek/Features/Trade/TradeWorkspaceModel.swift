import Combine
import Foundation
import SwiftUI

struct TradeOption: Identifiable {
    let value: String
    let title: String
    var id: String { value }
}

struct TradeInput: Identifiable {
    enum Kind { case text, multiline, secret, money, number, url, toggle, choice([TradeOption]), date }
    let key: String
    let title: String
    var kind = Kind.text
    var required = false
    var initial = ""
    var limit = 2000
    var help: String? = nil
    var id: String { key }
}

struct TradeOperation: Identifiable {
    let id = UUID()
    let title: String
    let explanation: String
    let path: String
    var method = "POST"
    var inputs: [TradeInput] = []
    var fields: [String: TradeValue] = [:]
    var irreversible = false
    var secretResult = false
    var guardPath: String? = nil
    var guardValue: TradeValue? = nil
    var maximumAmount: Decimal? = nil
}

@MainActor
final class TradePageModel: ObservableObject {
    @Published private(set) var data = TradeValue.null
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var generation = 0
    let api: TradeWorkspaceServing
    init(api: TradeWorkspaceServing) { self.api = api }
    func load(_ path: String, query: [String: String] = [:]) async {
        generation += 1
        let ticket = generation
        loading = true
        error = nil
        do {
            let result = try await api.read(path, query: query)
            try Task.checkCancellation()
            guard generation == ticket else { return }
            data = result
        } catch is CancellationError {
        } catch {
            guard generation == ticket else { return }
            self.error = error.localizedDescription
        }
        if generation == ticket { loading = false }
    }
}

@MainActor
final class TradeOperationModel: ObservableObject {
    @Published var values: [String: String]
    @Published private(set) var working = false
    @Published private(set) var attempted = false
    @Published private(set) var result: TradeValue?
    @Published private(set) var error: String?
    let operation: TradeOperation
    let api: TradeWorkspaceServing
    init(operation: TradeOperation, api: TradeWorkspaceServing) {
        self.operation = operation
        self.api = api
        values = Dictionary(uniqueKeysWithValues: operation.inputs.map { ($0.key, $0.initial) })
    }
    var valid: Bool {
        !working && !attempted && operation.inputs.allSatisfy { field in
            let value = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.count <= field.limit, !field.required || !value.isEmpty else { return false }
            switch field.kind {
            case .money: return value.isEmpty || TradeTerms.amount(value) != nil
            case .number: return value.isEmpty || (Int64(value).map { $0 >= 0 } ?? false)
            case .url: return value.isEmpty || TradePresentation.postURL(value) != nil
            case .choice(let options): return value.isEmpty || options.contains { $0.value == value }
            default: return true
            }
        }
    }
    func submit() async {
        guard valid else { return }
        working = true
        defer { working = false }
        error = nil
        if let path = operation.guardPath, let expected = operation.guardValue {
            do {
                let fresh = try await api.read(path, query: [:])
                guard fresh == expected else {
                    error = TradeText.text("交易状态已变化，请核对最新信息后重新操作。")
                    attempted = true
                    return
                }
            } catch { self.error = error.localizedDescription; return }
        }
        attempted = true
        var fields = operation.fields
        for field in operation.inputs {
            let raw = (values[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch field.kind {
            case .toggle: fields[field.key] = .bool(raw == "true")
            case .money:
                fields[field.key] = TradeTerms.amount(raw).map(TradeValue.string) ?? .null
            case .number:
                fields[field.key] = Int64(raw).map(TradeValue.id) ?? .null
            default: fields[field.key] = raw.isEmpty ? .null : .string(raw)
            }
        }
        if let selection = fields["agent_user_id"]?.text {
            if selection == "all" || selection == "none" {
                if operation.path.hasSuffix("/reassign") { fields["agent_user_id"] = .null }
                else { fields.removeValue(forKey: "agent_user_id") }
                if selection == "all", operation.path == "/api/common/trades" { fields["notify_agents"] = .bool(true) }
            } else if let id = Int64(selection) { fields["agent_user_id"] = .id(id) }
        }
        if operation.path == "/api/common/trades", fields["title"] == .null { fields.removeValue(forKey: "title") }
        if operation.path == "/api/common/private/requests" {
            for key in ["title", "note", "from_role", "to_role"] where fields[key] == .null { fields.removeValue(forKey: key) }
        }
        if operation.path.hasSuffix("/publish-request"), fields["approver_id"] == .null { fields.removeValue(forKey: "approver_id") }
        for key in ["brand_id", "score", "approver_id"] {
            if let selection = fields[key]?.text, let id = Int64(selection) { fields[key] = .id(id) }
        }
        if operation.path == "/api/common/points/alipay/orders" || operation.path == "/api/common/points/packets", let text = fields["amount"]?.text,
           let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), amount != Decimal(NSDecimalNumber(decimal: amount).int64Value) {
            attempted = false; error = TradeText.text("购买积分数量必须为正整数。"); return
        }
        if operation.path == "/api/common/points/packets" || operation.path == "/api/common/points/alipay/orders" {
            if let text = fields["amount"]?.text, let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), amount > 0 {
                if let maximum = operation.maximumAmount, amount > maximum {
                    attempted = false; error = TradeText.text("积分数量超过可用额度。"); return
                }
                fields["amount"] = .number(amount)
            } else {
                attempted = false; error = TradeText.text("金额必须大于零。"); return
            }
        }
        if operation.path == "/api/common/private/requests", fields["kind"]?.text == "trade", fields["from_role"] == fields["to_role"] {
            attempted = false
            error = TradeText.text("交易双方不能选择相同身份。")
            return
        }
        do {
            result = try await api.write(operation.path, method: operation.method, fields: fields)
            // 私密货物和券码等提交后立即离开可编辑内存，不进入日志或持久化草稿。
            for input in operation.inputs {
                if case .secret = input.kind { values[input.key] = "" }
            }
        } catch {
            self.error = TradeText.text("未能确认操作结果，请刷新核对交易进度后再操作。") + "\n" + error.localizedDescription
        }
    }
}

struct TradeOperationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: TradeOperationModel
    @State private var confirming = false
    @FocusState private var focused: String?
    let onComplete: (TradeValue) -> Void
    init(operation: TradeOperation, api: TradeWorkspaceServing, onComplete: @escaping (TradeValue) -> Void) {
        _model = StateObject(wrappedValue: TradeOperationModel(operation: operation, api: api))
        self.onComplete = onComplete
    }
    var body: some View {
        NavigationView {
            Form {
                Section { Text(model.operation.explanation).foregroundStyle(.secondary) }
                ForEach(model.operation.inputs) { input in
                    Section(TradeText.text(input.title)) {
                        field(input)
                        if let help = input.help { Text(TradeText.text(help)).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
                if let error = model.error { Text(error).foregroundStyle(.secondary) }
                if model.working { ProgressView() }
                if let result = model.result {
                    Label(TradeText.text("操作已提交"), systemImage: "checkmark.circle")
                    if model.operation.secretResult { TradeOperationResult(result: result, path: model.operation.path) }
                    Button(TradeText.text("完成")) { onComplete(result); dismiss() }
                } else if model.attempted {
                    Text(TradeText.text("请关闭后刷新核对结果；不会自动重复提交。"))
                }
            }
            .disabled(model.working)
            .navigationTitle(model.operation.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(TradeText.text(model.result == nil ? "取消" : "关闭")) { dismiss() }.disabled(model.working)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.result == nil { Button(TradeText.text("提交")) { focused = nil; confirming = true }.disabled(!model.valid) }
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(TradeText.text("收起键盘")) { focused = nil } }
            }
            .alert(model.operation.title, isPresented: $confirming) {
                Button(TradeText.text("取消"), role: .cancel) {}
                Button(TradeText.text("确认"), role: model.operation.irreversible ? .destructive : nil) { Task { await model.submit() } }
            } message: {
                Text(model.operation.explanation + confirmationSummary)
            }
        }
        .navigationViewStyle(.stack)
        .tradeTypography()
        .interactiveDismissDisabled(model.working || (model.operation.secretResult && model.result != nil))
    }
    private var confirmationSummary: String {
        let selected = model.operation.inputs.compactMap { input -> String? in
            switch input.kind {
            case .secret: return nil
            case .money, .number: return TradeText.text(input.title) + ": " + (model.values[input.key] ?? "")
            case .choice(let options):
                guard let value = options.first(where: { $0.value == model.values[input.key] }) else { return nil }
                return TradeText.text(input.title) + ": " + value.title
            default: return nil
            }
        }
        return selected.isEmpty ? "" : "\n\n" + selected.joined(separator: "\n")
    }
    @ViewBuilder private func field(_ input: TradeInput) -> some View {
        let binding = Binding(get: { model.values[input.key] ?? "" }, set: { model.values[input.key] = $0 })
        switch input.kind {
        case .choice(let options):
            Picker(TradeText.text(input.title), selection: binding) {
                if !input.required { Text(TradeText.text("未指定")).tag("") }
                ForEach(options) { Text($0.title).tag($0.value) }
            }
        case .toggle:
            Toggle(TradeText.text(input.title), isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
        case .multiline, .secret:
            TextEditor(text: binding).frame(minHeight: 130).focused($focused, equals: input.key)
                .privacySensitive().accessibilityLabel(TradeText.text(input.title))
        default:
            TextField(TradeText.text(input.title), text: binding).focused($focused, equals: input.key)
                .keyboardType(keyboard(input.kind)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.done).onSubmit { focused = nil }
        }
    }
    private func keyboard(_ kind: TradeInput.Kind) -> UIKeyboardType {
        switch kind { case .money: .decimalPad; case .number: .numberPad; case .url: .URL; default: .default }
    }
}

private struct TradeOperationResult: View {
    let result: TradeValue
    let path: String
    private func display(_ key: String, _ value: String) -> String {
        guard key == "token" else { return value }
        return "https://agent.nodeseek.org/chat/" + (path.hasSuffix("/invites") ? "invite/" : "packet/") + value
    }
    var body: some View {
        ForEach(["key", "token", "code", "url", "pay_url"], id: \.self) { key in
            if let value = result[key].text, !value.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(TradeText.text("请保存，此信息可能只显示一次。"))
                    Text(display(key, value)).textSelection(.enabled).privacySensitive()
                    Button(TradeText.text("复制")) { UIPasteboard.general.string = display(key, value) }
                    if key == "pay_url" || key == "url", let url = TradeExternalURL.allowed(value) {
                        Link(TradeText.text("打开链接"), destination: url)
                    }
                }
            }
        }
    }
}

enum TradeExternalURL {
    static func allowed(_ raw: String) -> URL? {
        guard let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host,
              ["agent.nodeseek.org", "t.me", "telegram.me", "www.nodeseek.com"].contains(host)
                || host == "alipay.com" || host.hasSuffix(".alipay.com") else { return nil }
        return url
    }
}
