import SwiftUI
import UIKit
#if canImport(FoundationModels)
import FoundationModels
#endif

enum ChatAssistantText {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: "ChatAssistant", comment: "")
    }
}

enum ChatAssistantMode: String, CaseIterable {
    case summary, analysis, reply

    var instruction: String {
        switch self {
        case .summary: return "Summarize the conversation, decisions, and outstanding items in a few bullets."
        case .analysis: return "Identify the participants' needs, unresolved questions, and points to verify. Separate facts from inferences."
        case .reply: return "Write one concise reply from the perspective of the speaker labeled me. Return only the reply text. Ask for clarification if needed. Do not make commitments on my behalf."
        }
    }
}

struct ChatAssistantMessage: Codable, Equatable {
    let speaker: String
    let text: String

    static func context(_ messages: [Self]) -> [Self] {
        var remaining = 2_800
        var selected: [Self] = []
        for message in messages.reversed() {
            if remaining == 0 || selected.count == 20 { break }
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = String(text.prefix(min(600, remaining)))
            selected.append(Self(speaker: message.speaker, text: clipped))
            remaining -= clipped.count
        }
        return Array(selected.reversed())
    }
}

struct ChatAssistantContext: Identifiable {
    let id = UUID()
    let messages: [ChatAssistantMessage]
    let canDraft: Bool

    static func appending(_ suggestion: String, to draft: String) -> String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestion : draft + "\n\n" + suggestion
    }
}

struct ChatAssistantView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: AssistantSessionStore

    init(messages: [ChatAssistantMessage], canDraft: Bool, isPost: Bool = false,
         configuration: ChatAssistantAPIConfiguration? = ChatAssistantAPIStore.load(),
         useDraft: @escaping (String) -> Bool) {
        let sessionStore = AssistantSessionStore(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("nodeseek-transient-assistant-\(UUID().uuidString).json"),
            configuration: configuration
        )
        let title: String
        if isPost {
            title = messages.first?.text.components(separatedBy: .newlines).first ?? ChatAssistantText.text("untitledPost")
        } else {
            title = ChatAssistantText.text("chatContext")
        }
        if !messages.isEmpty {
            if isPost {
                sessionStore.updateCurrentPostContext(
                    postID: "transient-post",
                    title: title,
                    authorName: nil,
                    commentCount: max(0, messages.count - 1),
                    messages: messages,
                    draftHandler: canDraft ? useDraft : nil
                )
            } else {
                sessionStore.setTransientChatContext(
                    id: "transient-chat",
                    title: title,
                    messages: messages,
                    draftHandler: canDraft ? useDraft : nil
                )
            }
        }
        _store = StateObject(wrappedValue: sessionStore)
    }

    var body: some View {
        AssistantPanelView(store: store) {
            dismiss()
        }
        .onDisappear {
            store.cancelGeneration()
        }
    }
}

struct ChatAssistantAPISettingsView: View {
    let configuration: ChatAssistantAPIConfiguration?
    let onSave: (ChatAssistantAPIConfiguration?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var model = ""
    @State private var key = ""
    @State private var error: String?
    @FocusState private var field: Field?

    private enum Field: Hashable { case address, model, key }

    var body: some View {
        NavigationView {
            Form {
                Text(ChatAssistantText.text("apiFormat")).foregroundStyle(.secondary)
                TextField(ChatAssistantText.text("endpoint"), text: $address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($field, equals: .address).submitLabel(.next).onSubmit { field = .model }
                TextField(ChatAssistantText.text("model"), text: $model)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($field, equals: .model).submitLabel(.next).onSubmit { field = .key }
                SecureField(ChatAssistantText.text("apiKey"), text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($field, equals: .key).submitLabel(.done).onSubmit { field = nil }
                if let error { Text(error).foregroundStyle(.secondary) }
                if configuration != nil {
                    Button(ChatAssistantText.text("removeAPI"), role: .destructive) {
                        guard ChatAssistantAPIStore.remove() else { error = ChatAssistantText.text("keychainFailed"); return }
                        onSave(nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle(ChatAssistantText.text("configureAPI"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ChatAssistantText.text("close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(ChatAssistantText.text("save"), action: save) }
            }
            .onAppear {
                address = configuration?.endpoint.absoluteString ?? ""
                model = configuration?.model ?? ""
                key = configuration?.key ?? ""
            }
        }.navigationViewStyle(.stack).tradeTypography()
    }

    private func save() {
        guard let updated = ChatAssistantAPIConfiguration(address: address, model: model, key: key) else {
            error = ChatAssistantText.text("invalidAPI")
            return
        }
        if let configuration, updated.endpoint != configuration.endpoint, !updated.key.isEmpty, updated.key == configuration.key {
            error = ChatAssistantText.text("keyForNewEndpoint")
            return
        }
        guard ChatAssistantAPIStore.save(updated) else { error = ChatAssistantText.text("keychainFailed"); return }
        onSave(updated)
        dismiss()
    }
}
