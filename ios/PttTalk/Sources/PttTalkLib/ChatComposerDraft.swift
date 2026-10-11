import Foundation

/// Local-only state. Never changes the encrypted message wire format.
public struct ChatStagedAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let fileName: String
    public let mimeType: String
    public let byteCount: Int
    public var caption: String
    public init(id: UUID = UUID(), fileName: String, mimeType: String, byteCount: Int, caption: String = "") {
        self.id = id; self.fileName = fileName; self.mimeType = mimeType
        self.byteCount = byteCount; self.caption = caption
    }
}

public struct ChatComposerDraft: Codable, Equatable, Sendable {
    public var text: String
    public var replyToMessageId: UUID?
    public var attachments: [ChatStagedAttachment]
    public init(text: String = "", replyToMessageId: UUID? = nil, attachments: [ChatStagedAttachment] = []) {
        self.text = text; self.replyToMessageId = replyToMessageId; self.attachments = attachments
    }
    public func validated() throws -> Self {
        guard text.utf8.count <= 4096, attachments.count <= 10,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= 25 * 1024 * 1024 && $0.caption.utf8.count <= 4096 })
        else { throw EncryptedChatError.invalidMessage }
        return self
    }
}
