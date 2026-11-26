import SwiftUI
import UIKit

/// 新版悬浮 AI 助手对话面板（支持跨帖子上下文、流式回复、多会话管理与暗黑模式）。
struct AssistantPanelView: View {
    @ObservedObject var store: AssistantSessionStore
    let onDismiss: () -> Void

    @State private var inputText = ""
    @State private var showingSessions = false
    @State private var showingSettings = false
    @State private var showingContextManager = false
    @State private var confirmingExternalPrompt: String?
    @State private var copiedTurnID: UUID?
    @State private var toastMessage: String?
    @FocusState private var isInputFocused: Bool

    private var session: AssistantSession {
        store.activeSession
    }

    /// 除当前浏览帖子外，会话中已引用过的其他帖子数量（用于跨帖子对比提示）。
    private var otherReferencedPostCount: Int {
        let currentID = store.currentPageContext?.id
        return session.referencedContexts.filter { $0.id != currentID }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.6)
            conversationArea
            Divider().opacity(0.6)
            composerSection
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .overlay(alignment: .top) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.footnote.weight(.medium))
                    .foregroundColor(Color(UIColor.systemBackground))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.88)))
                    .padding(.top, 58)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showingSessions) {
            AssistantSessionListSheet(store: store)
        }
        .sheet(isPresented: $showingSettings) {
            AssistantProviderSettingsSheet(store: store)
        }
        .sheet(isPresented: $showingContextManager) {
            AssistantReferencedContextsSheet(store: store)
        }
        .alert(
            ChatAssistantText.text("externalConfirm"),
            isPresented: Binding(
                get: { confirmingExternalPrompt != nil },
                set: { if !$0 { confirmingExternalPrompt = nil } }
            )
        ) {
            Button(ChatAssistantText.text("close"), role: .cancel) {
                confirmingExternalPrompt = nil
            }
            Button(ChatAssistantText.text("confirmAndSend")) {
                if let pending = confirmingExternalPrompt {
                    confirmingExternalPrompt = nil
                    store.confirmExternalEndpointConsent()
                    store.sendMessage(pending)
                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == pending {
                        inputText = ""
                    }
                }
            }
        } message: {
            if let endpoint = store.apiConfiguration?.endpoint.absoluteString {
                Text(String(format: ChatAssistantText.text("externalChatConfirmBody"), locale: .current, endpoint))
            }
        }
        .tradeTypography()
    }

    // MARK: - 顶部栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            Button {
                showingSessions = true
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .accessibilityLabel(ChatAssistantText.text("historySessions"))

            Button {
                store.startNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .accessibilityLabel(ChatAssistantText.text("newConversation"))

            Spacer(minLength: 4)

            Button {
                showingSettings = true
            } label: {
                VStack(spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                        Text(ChatAssistantText.text("title"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundColor(.primary)

                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.isReadyToSend ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(providerStatusText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityIdentifier("assistant-provider-status-button")

            Spacer(minLength: 4)

            Button {
                isInputFocused = false
                onDismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color(UIColor.secondarySystemBackground)))
            }
            .accessibilityLabel(ChatAssistantText.text("minimize"))
            .accessibilityIdentifier("assistant-minimize-button")
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var providerStatusText: String {
        if store.usesCustomAPI {
            if let model = store.apiConfiguration?.model, !model.isEmpty {
                return model
            }
            return ChatAssistantText.text("apiNotConfiguredShort")
        }
        return store.isOnDeviceAvailable
            ? ChatAssistantText.text("onDevice")
            : ChatAssistantText.text("needSetupShort")
    }

    // MARK: - 对话内容区

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if session.turns.isEmpty {
                        emptyWelcomeView
                    } else {
                        ForEach(session.turns) { turn in
                            turnRow(turn)
                                .id(turn.id)
                        }
                    }
                    Color.clear
                        .frame(height: 6)
                        .id("assistant-bottom-anchor")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .onChange(of: session.turns.count) { _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("assistant-bottom-anchor", anchor: .bottom)
                }
            }
            .onChange(of: session.turns.last?.content) { _ in
                proxy.scrollTo("assistant-bottom-anchor", anchor: .bottom)
            }
        }
    }

    private var emptyWelcomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(width: 54, height: 54)
                    Image(systemName: "sparkles")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.primary)
                }
                Text(ChatAssistantText.text("welcomeTitle"))
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(ChatAssistantText.text("welcomeSubtitle"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)

            if !store.isReadyToSend {
                setupBannerCard
            }

            if let context = store.currentPageContext {
                currentContextPreviewCard(context)
            }

            quickPromptGrid
        }
    }

    private var setupBannerCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.orange)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.orange.opacity(0.14)))

            VStack(alignment: .leading, spacing: 3) {
                Text(ChatAssistantText.text("setupNeededTitle"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                Text(ChatAssistantText.text("setupNeededBody"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 4)

            Button(ChatAssistantText.text("goConfigure")) {
                showingSettings = true
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(Color(UIColor.systemBackground))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(Color.primary))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private func currentContextPreviewCard(_ context: AssistantContextSnapshot) -> some View {
        HStack(spacing: 10) {
            Image(systemName: context.kind == .post ? "doc.text.fill" : "bubble.left.and.bubble.right.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.primary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(UIColor.tertiarySystemBackground)))

            VStack(alignment: .leading, spacing: 2) {
                Text(ChatAssistantText.text("currentReadingPost"))
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                Text(context.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                if let subtitle = context.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
    }

    private var quickPromptGrid: some View {
        let items = availableQuickPrompts
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(items, id: \.title) { item in
                Button {
                    submitPrompt(item.prompt)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: item.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.primary)
                        Text(item.title)
                            .font(.footnote.weight(.medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
                .disabled(store.isGenerating)
            }
        }
    }

    private struct QuickPromptItem {
        let title: String
        let icon: String
        let prompt: String
    }

    private var availableQuickPrompts: [QuickPromptItem] {
        var items: [QuickPromptItem] = []
        if let context = store.currentPageContext {
            if context.kind == .post {
                items.append(.init(
                    title: ChatAssistantText.text("postSummary"),
                    icon: "doc.text",
                    prompt: ChatAssistantText.text("quickPromptSummarizePost")
                ))
                items.append(.init(
                    title: ChatAssistantText.text("analysis"),
                    icon: "text.magnifyingglass",
                    prompt: ChatAssistantText.text("quickPromptAnalyzePost")
                ))
                if store.canApplyDraftToCurrentPage {
                    items.append(.init(
                        title: ChatAssistantText.text("reply"),
                        icon: "square.and.pencil",
                        prompt: ChatAssistantText.text("quickPromptDraftReply")
                    ))
                }
                if otherReferencedPostCount > 0 {
                    items.append(.init(
                        title: ChatAssistantText.text("comparePosts"),
                        icon: "arrow.left.arrow.right",
                        prompt: ChatAssistantText.text("quickPromptComparePosts")
                    ))
                } else {
                    items.append(.init(
                        title: ChatAssistantText.text("extractDeals"),
                        icon: "tag",
                        prompt: ChatAssistantText.text("quickPromptExtractSpecs")
                    ))
                }
            } else {
                items.append(.init(
                    title: ChatAssistantText.text("summary"),
                    icon: "doc.text",
                    prompt: ChatAssistantText.text("quickPromptSummarizeChat")
                ))
                items.append(.init(
                    title: ChatAssistantText.text("analysis"),
                    icon: "text.magnifyingglass",
                    prompt: ChatAssistantText.text("quickPromptAnalyzeChat")
                ))
                if store.canApplyDraftToCurrentPage {
                    items.append(.init(
                        title: ChatAssistantText.text("reply"),
                        icon: "square.and.pencil",
                        prompt: ChatAssistantText.text("quickPromptDraftChatReply")
                    ))
                }
            }
        } else {
            items.append(.init(
                title: ChatAssistantText.text("quickGeneralVPS"),
                icon: "server.rack",
                prompt: ChatAssistantText.text("quickGeneralVPSPrompt")
            ))
            items.append(.init(
                title: ChatAssistantText.text("quickGeneralTranslate"),
                icon: "globe",
                prompt: ChatAssistantText.text("quickGeneralTranslatePrompt")
            ))
        }
        return items
    }

    // MARK: - 气泡行

    @ViewBuilder
    private func turnRow(_ turn: AssistantChatTurn) -> some View {
        if turn.role == .user {
            VStack(alignment: .trailing, spacing: 5) {
                if !turn.attachedReferences.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(turn.attachedReferences) { ref in
                            HStack(spacing: 4) {
                                Image(systemName: ref.kind == .post ? "doc.text" : "bubble.left")
                                    .font(.system(size: 10, weight: .medium))
                                Text(ref.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
                            .frame(maxWidth: 240, alignment: .trailing)
                        }
                    }
                }

                Text(turn.content)
                    .font(.body)
                    .foregroundColor(Color(UIColor.systemBackground))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.primary)
                    )
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        } else {
            let isLastTurn = session.turns.last?.id == turn.id
            let isStreamingThis = isLastTurn && store.isGenerating

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(ChatAssistantText.text("title"))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if turn.content.isEmpty && isStreamingThis {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text(ChatAssistantText.text("working"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    } else {
                        renderedMarkdownText(turn.content, isError: turn.isError)
                            .textSelection(.enabled)
                    }

                    if !isStreamingThis && !turn.content.isEmpty {
                        HStack(spacing: 14) {
                            Button {
                                UIPasteboard.general.string = turn.content
                                copiedTurnID = turn.id
                                showToast(ChatAssistantText.text("copiedToast"))
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedTurnID == turn.id { copiedTurnID = nil }
                                }
                            } label: {
                                Label(
                                    copiedTurnID == turn.id ? ChatAssistantText.text("copied") : ChatAssistantText.text("copyShort"),
                                    systemImage: copiedTurnID == turn.id ? "checkmark" : "doc.on.doc"
                                )
                                .font(.caption)
                                .foregroundColor(copiedTurnID == turn.id ? .green : .secondary)
                            }

                            if !turn.isError && store.canApplyDraftToCurrentPage {
                                Button {
                                    if store.applyDraftToCurrentPage(turn.content) {
                                        showToast(ChatAssistantText.text("draftAppliedToast"))
                                    } else {
                                        showToast(ChatAssistantText.text("draftUnavailable"))
                                    }
                                } label: {
                                    Label(ChatAssistantText.text("draftShort"), systemImage: "square.and.pencil")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if isLastTurn {
                                Button {
                                    store.regenerateLastReply()
                                } label: {
                                    Label(ChatAssistantText.text("regenerate"), systemImage: "arrow.clockwise")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(turn.isError
                              ? Color.red.opacity(0.08)
                              : Color(UIColor.secondarySystemBackground))
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 20)
        }
    }

    @ViewBuilder
    private func renderedMarkdownText(_ text: String, isError: Bool) -> some View {
        if isError {
            Text(text)
                .font(.footnote)
                .foregroundColor(.red)
        } else if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 底部上下文胶囊 + 输入栏

    private var composerSection: some View {
        VStack(spacing: 8) {
            contextAndQuickChipBar
            inputRow
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private var contextAndQuickChipBar: some View {
        let hasContext = store.currentPageContext != nil
        let hasReferenced = !session.referencedContexts.isEmpty
        if hasContext || hasReferenced {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let current = store.currentPageContext {
                        Button {
                            store.attachCurrentContext.toggle()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: store.attachCurrentContext ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(current.shortTitle)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                            }
                            .foregroundColor(store.attachCurrentContext ? Color(UIColor.systemBackground) : .secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    store.attachCurrentContext
                                        ? Color.primary
                                        : Color(UIColor.secondarySystemBackground)
                                )
                            )
                        }
                        .accessibilityIdentifier("assistant-current-context-chip")
                    }

                    if hasReferenced {
                        Button {
                            showingContextManager = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "books.vertical")
                                    .font(.system(size: 11, weight: .medium))
                                Text(String(format: ChatAssistantText.text("referencedCountFormat"), session.referencedContexts.count))
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(UIColor.secondarySystemBackground)))
                        }
                        .accessibilityIdentifier("assistant-referenced-contexts-chip")
                    }

                    // 已有对话且切换到了新帖子时，提供一键跨帖对比按钮
                    if !session.turns.isEmpty, store.currentPageContext?.kind == .post, otherReferencedPostCount > 0 {
                        Button {
                            submitPrompt(ChatAssistantText.text("quickPromptComparePosts"))
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(ChatAssistantText.text("comparePosts"))
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .strokeBorder(Color(UIColor.separator), lineWidth: 0.8)
                            )
                        }
                        .disabled(store.isGenerating)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(store.currentPageContext != nil && store.attachCurrentContext
                         ? ChatAssistantText.text("inputPlaceholderWithPost")
                         : ChatAssistantText.text("inputPlaceholder"))
                        .font(.body)
                        .foregroundColor(Color(UIColor.placeholderText))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }

                // 用透明占位文本撑开多行高度（兼容 iOS 15）
                Text(inputText.isEmpty ? " " : inputText + " ")
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .opacity(0)
                    .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 112, alignment: .leading)

                TextEditor(text: $inputText)
                    .font(.body)
                    .focused($isInputFocused)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .frame(minHeight: 38, maxHeight: 112)
                    .transparentTextEditorBackground()
                    .accessibilityIdentifier("assistant-message-input")
            }
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(UIColor.secondarySystemBackground))
            )

            if store.isGenerating {
                Button {
                    store.cancelGeneration()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(UIColor.systemBackground))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Color.primary))
                }
                .accessibilityLabel(ChatAssistantText.text("stopGenerating"))
                .accessibilityIdentifier("assistant-stop-button")
            } else {
                let canSend = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button {
                    submitPrompt(inputText)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(canSend ? Color(UIColor.systemBackground) : .secondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? Color.primary : Color(UIColor.tertiarySystemFill)))
                }
                .disabled(!canSend)
                .accessibilityLabel(ChatAssistantText.text("send"))
                .accessibilityIdentifier("assistant-send-button")
            }
        }
    }

    // MARK: - Actions

    private func submitPrompt(_ rawPrompt: String) {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }

        if !store.isReadyToSend {
            showingSettings = true
            return
        }
        if store.needsExternalConsent {
            confirmingExternalPrompt = prompt
            return
        }
        isInputFocused = false
        store.sendMessage(prompt)
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines) == prompt {
            inputText = ""
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            toastMessage = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            if toastMessage == message {
                withAnimation(.easeInOut(duration: 0.2)) {
                    toastMessage = nil
                }
            }
        }
    }
}

// MARK: - 历史会话列表 Sheet

private struct AssistantSessionListSheet: View {
    @ObservedObject var store: AssistantSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(store.sessions) { session in
                    Button {
                        store.selectSession(session.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.displayTitle)
                                    .font(.body.weight(session.id == store.activeSessionID ? .semibold : .regular))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(String(format: ChatAssistantText.text("turnCountFormat"), session.turns.count))
                                    if !session.referencedContexts.isEmpty {
                                        Text("·")
                                        Text(String(format: ChatAssistantText.text("referencedCountFormat"), session.referencedContexts.count))
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            Spacer()
                            if session.id == store.activeSessionID {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.primary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { store.sessions[$0].id }
                    ids.forEach { store.deleteSession($0) }
                }
            }
            .navigationTitle(ChatAssistantText.text("historySessions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatAssistantText.text("close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.startNewSession()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .tradeTypography()
    }
}

// MARK: - 已引用帖子上下文管理 Sheet

private struct AssistantReferencedContextsSheet: View {
    @ObservedObject var store: AssistantSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text(ChatAssistantText.text("referencedContextsFooter"))) {
                    ForEach(store.activeSession.referencedContexts) { snapshot in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                            if let subtitle = snapshot.subtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.activeSession.referencedContexts[$0].id }
                        ids.forEach { store.removeReferencedContext(id: $0) }
                    }
                }
            }
            .navigationTitle(ChatAssistantText.text("referencedContextsTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ChatAssistantText.text("close")) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .tradeTypography()
    }
}

// MARK: - 模型与 API 设置 Sheet

private struct AssistantProviderSettingsSheet: View {
    @ObservedObject var store: AssistantSessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var configuringAPI = false

    var body: some View {
        NavigationView {
            Form {
                Section(ChatAssistantText.text("provider")) {
                    Picker(ChatAssistantText.text("provider"), selection: $store.usesCustomAPI) {
                        Text(ChatAssistantText.text("onDevice")).tag(false)
                        Text(ChatAssistantText.text("customAPI")).tag(true)
                    }
                    .pickerStyle(.segmented)

                    if store.usesCustomAPI {
                        Button(ChatAssistantText.text("configureAPI")) {
                            configuringAPI = true
                        }
                        if let api = store.apiConfiguration {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(api.model)
                                    .font(.subheadline.weight(.medium))
                                Text(api.endpoint.absoluteString)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text(ChatAssistantText.text("apiMissing"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else if !store.isOnDeviceAvailable {
                        Text(ChatAssistantText.text("unavailable"))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button(ChatAssistantText.text("useCustomAPI")) {
                            store.usesCustomAPI = true
                            configuringAPI = true
                        }
                    }
                }

                Section {
                    Button(ChatAssistantText.text("clearCurrentSession"), role: .destructive) {
                        store.clearActiveSession()
                        dismiss()
                    }
                }

                Section {
                    Text(ChatAssistantText.text(store.usesCustomAPI ? "postExternalPrivacy" : "postPrivacy"))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(ChatAssistantText.text("assistantSettings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ChatAssistantText.text("close")) { dismiss() }
                }
            }
            .sheet(isPresented: $configuringAPI) {
                ChatAssistantAPISettingsView(configuration: store.apiConfiguration) { updated in
                    store.updateAPIConfiguration(updated)
                }
            }
        }
        .navigationViewStyle(.stack)
        .tradeTypography()
    }
}

private extension View {
    @ViewBuilder
    func transparentTextEditorBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}
