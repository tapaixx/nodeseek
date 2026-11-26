import Kanna
import SwiftUI

extension PostDetailViewController {
    func openPostAssistant() {
        guard presentedViewController == nil, replyTextView.markedTextRange == nil else { return }
        syncPostContextToAssistant()
        replyTextView.resignFirstResponder()
        FloatingAssistantOverlayManager.shared.presentPanel(from: self)
    }

    func syncPostContextToAssistant() {
        guard displayMode == .content, let header = currentHeaderContent else { return }
        let messages = PostAssistantContext.messages(header: header, comments: comments)
        let postID = header.postID
        let draftHandler: ((String) -> Bool)? = showsReplyEntry ? { [weak self] suggestion in
            guard let self, displayMode == .content, showsReplyEntry, currentHeaderContent?.postID == postID,
                  replyTextView.isEditable, replyTextView.markedTextRange == nil else { return false }
            replyTextView.text = ChatAssistantContext.appending(suggestion, to: replyTextView.text ?? "")
            updateReplyBarDraftPreview()
            return true
        } : nil
        AssistantSessionStore.shared.updateCurrentPostContext(
            postID: postID,
            title: header.title,
            authorName: header.authorName,
            commentCount: comments.count,
            messages: messages,
            draftHandler: draftHandler
        )
    }

    func clearPostContextFromAssistant() {
        guard let postID = currentHeaderContent?.postID else { return }
        AssistantSessionStore.shared.clearCurrentPostContext(postID: postID)
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
