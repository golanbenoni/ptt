import Foundation
import Testing
@testable import PttTalkLib
import PttWire

@Test func secureHistoryPersistsAndAuthenticatesPackets() throws {
    let id = UUID().uuidString.lowercased()
    let namespace = "app.ptt.test.history.\(id)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? KeychainVault(service: "\(namespace).key").deleteAll()
    }
    let testKey = Data(repeating: 0xa5, count: 32)
    let archive = try SecureVoiceHistoryArchive(namespace: namespace, directory: directory, testKey: testKey)
    let channel = UUID()
    let talk = UUID()
    let announcement = MediaEpochAnnouncement(
        channelId: channel,
        talkId: talk,
        membershipEpoch: 3,
        senderDemux: 7,
        kid: 11,
        baseKey: Data(repeating: 9, count: 32),
        totMs: 30_000
    )
    try archive.putEpoch(announcement, senderAci: UUID().uuidString, senderDeviceId: 1)
    let packets = [Data(repeating: 1, count: 160), Data(repeating: 2, count: 160)]
    let ciphertext = try EncryptedHistory.seal(
        channelId: channel,
        talkId: talk,
        membershipEpoch: 3,
        kid: 11,
        baseKey: announcement.baseKey,
        packets: packets,
        nonce: Data(repeating: 4, count: 12)
    )
    let now = Date()
    let metadata = HistoryMetadata(
        objectId: UUID(),
        talkId: talk,
        channelId: channel,
        membershipEpoch: 3,
        mediaKid: 11,
        startedAt: now,
        durationMs: 40,
        expiresAt: now.addingTimeInterval(3_600),
        ciphertextBytes: ciphertext.count
    )
    try archive.complete(metadata: metadata, ciphertext: ciphertext)

    #expect(try archive.records(channelId: channel).count == 1)
    #expect(try archive.packets(talk) == packets)
    #expect(try SecureVoiceHistoryArchive(
        namespace: namespace,
        directory: directory,
        testKey: testKey
    ).packets(talk) == packets)
}

@Test func secureHistoryRejectsTalkIdReuse() throws {
    let namespace = "app.ptt.test.history.\(UUID().uuidString.lowercased())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? KeychainVault(service: "\(namespace).key").deleteAll()
    }
    let archive = try SecureVoiceHistoryArchive(
        namespace: namespace,
        directory: directory,
        testKey: Data(repeating: 0xb6, count: 32)
    )
    let talk = UUID()
    let first = MediaEpochAnnouncement(
        channelId: UUID(), talkId: talk, membershipEpoch: 1, senderDemux: 1,
        kid: 1, baseKey: Data(repeating: 1, count: 32), totMs: 1_000
    )
    try archive.putEpoch(first, senderAci: "sender", senderDeviceId: 1)
    let reused = MediaEpochAnnouncement(
        channelId: first.channelId, talkId: talk, membershipEpoch: 1, senderDemux: 1,
        kid: 2, baseKey: Data(repeating: 2, count: 32), totMs: 1_000
    )
    #expect(throws: SecureVoiceHistoryError.talkIdReused) {
        try archive.putEpoch(reused, senderAci: "sender", senderDeviceId: 1)
    }
}

@Test func secureHistoryStagesUploadDurablyBeforeServerAcceptance() throws {
    let namespace = "app.ptt.test.history.\(UUID().uuidString.lowercased())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
    defer {
        try? FileManager.default.removeItem(at: directory)
        try? KeychainVault(service: "\(namespace).key").deleteAll()
    }
    let key = Data(repeating: 0xc7, count: 32)
    let channel = UUID()
    let talk = UUID()
    let announcement = MediaEpochAnnouncement(
        channelId: channel, talkId: talk, membershipEpoch: 4, senderDemux: 9,
        kid: 12, baseKey: Data(repeating: 0x31, count: 32), totMs: 1_000
    )
    let packets = [Data(repeating: 0x42, count: 160)]
    let ciphertext = try EncryptedHistory.seal(
        channelId: channel,
        talkId: talk,
        membershipEpoch: 4,
        kid: 12,
        baseKey: announcement.baseKey,
        packets: packets,
        nonce: Data(repeating: 0x11, count: 12)
    )
    let archive = try SecureVoiceHistoryArchive(namespace: namespace, directory: directory, testKey: key)
    try archive.putEpoch(announcement, senderAci: "sender", senderDeviceId: 1)
    try archive.stageUpload(talkId: talk, startedAt: Date(), durationMs: 20, ciphertext: ciphertext)

    let restored = try SecureVoiceHistoryArchive(namespace: namespace, directory: directory, testKey: key)
    let pending = try restored.pendingUploads(channelId: channel)
    #expect(pending.map(\.talkId) == [talk])
    #expect(try restored.pendingUploads().map(\.talkId) == [talk])
    #expect(try restored.pendingUploads(channelId: UUID()).isEmpty)
    #expect(try restored.pendingCiphertext(talk) == ciphertext)
    #expect(try restored.records(channelId: channel).isEmpty)
    #expect(try restored.records(channelId: channel, includePending: true).count == 1)
}
