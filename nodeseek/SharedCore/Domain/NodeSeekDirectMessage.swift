import Foundation

nonisolated struct NodeSeekDirectMessage: Decodable, Equatable, Sendable {
    let id: Int
    let senderID: Int
    let receiverID: Int
    let content: String
    let createdAt: Date
    let isMarkdown: Bool
    let viewed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, content, viewed
        case senderID = "sender_id"
        case receiverID = "receiver_id"
        case createdAt = "created_at"
        case isMarkdown = "is_markdown"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        senderID = try values.decode(Int.self, forKey: .senderID)
        receiverID = try values.decode(Int.self, forKey: .receiverID)
        content = try values.decode(String.self, forKey: .content)
        let text = try values.decode(String.self, forKey: .createdAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: text)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? formatter.date(from: text) else {
            throw DecodingError.dataCorruptedError(forKey: .createdAt, in: values, debugDescription: "Invalid message date")
        }
        createdAt = date
        func flag(_ key: CodingKeys) throws -> Bool {
            if let value = try? values.decode(Bool.self, forKey: key) { return value }
            return try values.decodeIfPresent(Int.self, forKey: key).map { $0 != 0 } ?? false
        }
        isMarkdown = try flag(.isMarkdown)
        viewed = try flag(.viewed)
    }
}

nonisolated struct NodeSeekMessageThread: Decodable, Sendable {
    let success: Bool
    let message: String?
    let talkTo: Participant?
    let msgArray: [NodeSeekDirectMessage]

    struct Participant: Decodable, Sendable {
        let memberID: Int
        let memberName: String

        private enum CodingKeys: String, CodingKey {
            case memberID = "member_id"
            case memberName = "member_name"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case success, message, talkTo, msgArray
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        success = try values.decode(Bool.self, forKey: .success)
        message = try values.decodeIfPresent(String.self, forKey: .message)
        talkTo = try values.decodeIfPresent(Participant.self, forKey: .talkTo)
        msgArray = try values.decodeIfPresent([NodeSeekDirectMessage].self, forKey: .msgArray) ?? []
    }

    func messages(participantID: Int, currentUserID: Int) -> [NodeSeekDirectMessage] {
        var seen: Set<Int> = []
        return msgArray.filter {
            $0.id > 0 && (($0.senderID == participantID && $0.receiverID == currentUserID)
                || ($0.senderID == currentUserID && $0.receiverID == participantID))
                && seen.insert($0.id).inserted
        }.sorted { $0.id < $1.id }
    }
}

nonisolated struct NodeSeekMessageRoute: Equatable {
    let participantID: Int

    init?(url: URL) {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              NodeSeekSite.isNodeSeekHost(url), url.path == "/notification",
              let fragment = url.fragment,
              let components = URLComponents(string: fragment), components.path == "/message",
              components.queryItems?.first(where: { $0.name == "mode" })?.value == "talk",
              let text = components.queryItems?.first(where: { $0.name == "to" })?.value,
              let id = Int(text), id > 0 else { return nil }
        participantID = id
    }
}
