import Kanna
import SwiftUI

extension PostDetailViewController {
    func openPostAssistant() {
        guard presentedViewController == nil, replyTextView.markedTextRange == nil else { return }
        guard displayMode == .content, showsReplyEntry, let header = currentHeaderContent else {
            showError(message: ChatAssistantText.text("postEmpty"))
            return
        }
        let messages = PostAssistantContext.messages(header: header, comments: comments)
        replyTextView.resignFirstResponder()
        let assistant = ChatAssistantView(messages: messages, canDraft: true, isPost: true) { [weak self] suggestion in
            guard let self, displayMode == .content, showsReplyEntry, currentHeaderContent?.postID == header.postID,
                  replyTextView.isEditable, replyTextView.markedTextRange == nil else { return false }
            replyTextView.text = ChatAssistantContext.appending(suggestion, to: replyTextView.text ?? "")
            updateReplyBarDraftPreview()
            return true
        }
        present(UIHostingController(rootView: assistant), animated: true)
    }
}

enum PostAssistantContext {
    static func messages(header: PostDetailHeaderContent, comments: [Comment]) -> [ChatAssistantMessage] {
        let original = String((String(header.title.prefix(250)) + "\n\n" + plainText(header.contentHTML)).prefix(1_600))
        var result = [ChatAssistantMessage(speaker: "post", text: original)]
        var remaining = 2_800 - original.count
        var recent: [ChatAssistantMessage] = []
        for comment in comments.suffix(20).reversed() {
            guard remaining > 0 else { break }
            let text = String(plainText(comment.contentHTML).prefix(min(400, remaining)))
            guard !text.isEmpty else { continue }
            recent.append(.init(speaker: "comment", text: text))
            remaining -= text.count
        }
        result.append(contentsOf: recent.reversed())
        return result
    }

    private static func plainText(_ html: String) -> String {
        guard let document = try? HTML(html: String(html.prefix(80_000)), encoding: .utf8), let body = document.body else { return "" }
        for element in body.xpath(".//script | .//style | .//template | .//iframe | .//*[@hidden] | .//*[@aria-hidden='true']").reversed() {
            element.parent?.removeChild(element)
        }
        return (body.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
