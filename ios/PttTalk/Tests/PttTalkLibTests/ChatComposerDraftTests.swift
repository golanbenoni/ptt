import Foundation
import Testing
@testable import PttTalkLib

@Test func composerDraftRoundTripAndLimits() throws {
    let first = ChatStagedAttachment(fileName: "Photo.jpg", mimeType: "image/jpeg", byteCount: 1024, caption: "First")
    let second = ChatStagedAttachment(fileName: "Video.mp4", mimeType: "video/mp4", byteCount: 2048, caption: "Second")
    let draft = ChatComposerDraft(text: "Unsent text", replyToMessageId: UUID(), attachments: [second, first])
    let reopened = try JSONDecoder().decode(ChatComposerDraft.self, from: JSONEncoder().encode(draft))
    #expect(try reopened.validated() == draft)
    #expect(throws: (any Error).self) { try ChatComposerDraft(text: String(repeating: "😀", count: 1025)).validated() }
    #expect(throws: (any Error).self) { try ChatComposerDraft(attachments: [first, first]).validated() }
    #expect(throws: (any Error).self) { try ChatComposerDraft(attachments: [ChatStagedAttachment(fileName: "large", mimeType: "image/jpeg", byteCount: 25 * 1024 * 1024 + 1)]).validated() }
}

@Test func stagedMediaIsEncryptedBoundToConversationAndDiscardable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 7, count: 32)
    let archive = try SecureChatArchive(namespace: "test-composer", directory: directory, testKey: key)
    let id = UUID(), channel = UUID()
    let clear = Data("private photo bytes".utf8)
    try archive.stageMedia(clear, id: id, channelId: channel)
    let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
    #expect(try Data(contentsOf: file).range(of: clear) == nil)
    let reopened = try SecureChatArchive(namespace: "test-composer", directory: directory, testKey: key)
    #expect(try reopened.stagedMedia(id, channelId: channel) == clear)
    #expect(throws: (any Error).self) { try reopened.stagedMedia(id, channelId: UUID()) }
    try reopened.discardStagedMedia(id, channelId: channel)
    #expect(throws: (any Error).self) { try reopened.stagedMedia(id, channelId: channel) }
}

@Test func acceptedAttachmentKeepsOneOutboxEventAcrossReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = Data(repeating: 8, count: 32)
    let archive = try SecureChatArchive(namespace: "test-accept", directory: directory, testKey: key)
    let message = ChatMessage(messageId: UUID(), channelId: UUID(), membershipEpoch: 1, sentAt: Date(), senderAci: UUID().uuidString.lowercased(), senderDeviceId: 1, kind: .text, text: "durable")
    let event = ChatEvent.message(message, replyTo: UUID())
    let expiry = Date().addingTimeInterval(3600)
    try archive.acceptSend(event: event, expiresAt: expiry, attachmentCiphertext: nil)
    try archive.acceptSend(event: event, expiresAt: expiry, attachmentCiphertext: nil)
    let reopened = try SecureChatArchive(namespace: "test-accept", directory: directory, testKey: key)
    #expect(try reopened.outbox().count == 1)
    let events = try reopened.events(channelId: message.channelId)
    #expect(events.count == 1)
    #expect(try EncryptedChatCodec.encodeEvent(#require(events.first)) == EncryptedChatCodec.encodeEvent(event))
    let different = ChatMessage(messageId: message.messageId, channelId: message.channelId, membershipEpoch: 1, sentAt: message.sentAt, senderAci: message.senderAci, senderDeviceId: 1, kind: .text, text: "different content")
    #expect(throws: (any Error).self) { try reopened.put(different, expiresAt: expiry) }
}
