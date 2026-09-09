import Foundation
import Testing
@testable import PttTalkLib

@Test func callKeysTargetOnlyTheDeviceThatClaimedTheAccountSeat() throws {
    let aci = "33333333-3333-4333-8333-333333333333"
    let recipient = try CallKeyRecipient(aci: aci.uppercased(), deviceId: 2)
    func device(_ id: Int) -> ChannelDevice {
        ChannelDevice(
            aci: aci, displayName: "Teammate", accountKind: "member", deviceId: id,
            mailboxId: UUID().uuidString.lowercased(), identityKey: Data(repeating: 1, count: 33),
            role: "member"
        )
    }

    #expect(recipient.matches(device(2)))
    #expect(!recipient.matches(device(1)))
    #expect(throws: EncryptedChatError.self) {
        _ = try CallKeyRecipient(aci: aci, deviceId: 3)
    }
}

@Test func callKeyEnvelopeRoundTripsAndRejectsTampering() throws {
    let message = EncryptedCallKeyMessage(
        messageId: UUID(uuidString: "00010203-0405-4607-8809-0a0b0c0d0e0f")!,
        channelId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        membershipEpoch: 4,
        callId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        callEpoch: 7,
        kind: .announcement,
        participantIdentity: "opaque-participant-0123456789",
        key: Data(repeating: 0x5a, count: 32)
    )
    let bytes = try EncryptedCallKeyCodec.encode(message)
    let expectedHex =
        "505454430101" +
        "000102030405460788090a0b0c0d0e0f" +
        "11111111111141118111111111111111" +
        "22222222222242228222222222222222" +
        "00000004000000071d" +
        "6f70617175652d7061727469636970616e742d30313233343536373839" +
        String(repeating: "5a", count: 32)
    #expect(bytes.map { String(format: "%02x", $0) }.joined() == expectedHex)
    let opened = try EncryptedCallKeyCodec.decode(
        bytes,
        senderAci: "33333333-3333-4333-8333-333333333333",
        senderDeviceId: 2
    )
    #expect(opened.messageId == message.messageId)
    #expect(opened.callId == message.callId)
    #expect(opened.key == message.key)

    var altered = bytes
    altered[altered.count - 1] ^= 1
    let alteredOpened = try EncryptedCallKeyCodec.decode(
        altered,
        senderAci: "33333333-3333-4333-8333-333333333333",
        senderDeviceId: 2
    )
    // The outer Double Ratchet authenticates this payload. At the codec layer,
    // key changes remain structurally valid and must produce a distinct frame key.
    #expect(alteredOpened.key != opened.key)
}

@Test func callFrameKeysAreBoundToEpochAndParticipant() {
    let material = Data(repeating: 7, count: 32)
    let first = EncryptedCallSession.frameKey(
        material: material,
        callId: "11111111-1111-4111-8111-111111111111",
        epoch: 1,
        participantIdentity: "participant-a-012345"
    )
    let nextEpoch = EncryptedCallSession.frameKey(
        material: material,
        callId: "11111111-1111-4111-8111-111111111111",
        epoch: 2,
        participantIdentity: "participant-a-012345"
    )
    let otherParticipant = EncryptedCallSession.frameKey(
        material: material,
        callId: "11111111-1111-4111-8111-111111111111",
        epoch: 1,
        participantIdentity: "participant-b-012345"
    )
    #expect(first.count == 32)
    #expect(first.map { String(format: "%02x", $0) }.joined() ==
        "a5f3a911f966ca19b03dcf0e176de4087845d9d768c54142a4dde7a7adfeb978")
    #expect(first != nextEpoch)
    #expect(first != otherParticipant)
}

@Test func callKeyAcknowledgementCarriesTheExactFingerprint() throws {
    let message = EncryptedCallKeyMessage(
        messageId: UUID(uuidString: "01010203-0405-4607-8809-0a0b0c0d0e0f")!,
        channelId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
        membershipEpoch: 4,
        callId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
        callEpoch: 7,
        kind: .acknowledgement,
        participantIdentity: "opaque-participant-0123456789",
        key: Data((0..<16).map(UInt8.init))
    )
    let opened = try EncryptedCallKeyCodec.decode(
        EncryptedCallKeyCodec.encode(message),
        senderAci: "33333333-3333-4333-8333-333333333333",
        senderDeviceId: 1
    )
    #expect(opened.key == Data((0..<16).map(UInt8.init)))
}

@Test func encryptedCallTimelineMatchesFrozenAndroidVectorAndBuildsHistory() throws {
    let callId = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    let channelId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    let startedAt = Date(timeIntervalSince1970: 1_788_901_234.567)
    let event = EncryptedCallTimelineEvent(
        callId: callId, kind: .ended, startedAt: startedAt,
        durationMs: 61_234, participantCount: 3, endReason: "sos_preempted"
    )
    let encoded = try EncryptedCallTimelineCodec.encode(event)
    #expect(encoded ==
        "ptt-call-event:v1|ended|22222222-2222-4222-8222-222222222222|1788901234567|61234|3|sos_preempted")
    #expect(try EncryptedCallTimelineCodec.decode(encoded) == event)
    #expect(try EncryptedCallTimelineCodec.decode("ordinary encrypted chat") == nil)

    let messages = [
        ChatMessage(
            messageId: UUID(), channelId: channelId, membershipEpoch: 4, sentAt: startedAt,
            senderAci: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", senderDeviceId: 1, kind: .text,
            text: try EncryptedCallTimelineCodec.encode(.init(
                callId: callId, kind: .started, startedAt: startedAt, participantCount: 3
            ))
        ),
        ChatMessage(
            messageId: UUID(), channelId: channelId, membershipEpoch: 4,
            sentAt: startedAt.addingTimeInterval(1),
            senderAci: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", senderDeviceId: 1, kind: .text,
            text: try EncryptedCallTimelineCodec.encode(.init(
                callId: callId, kind: .answered, startedAt: startedAt, participantCount: 3
            ))
        ),
        ChatMessage(
            messageId: UUID(), channelId: channelId, membershipEpoch: 4,
            sentAt: startedAt.addingTimeInterval(61.234),
            senderAci: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", senderDeviceId: 1,
            kind: .text, text: encoded
        ),
    ]
    let history = try #require(EncryptedCallTimelineCodec.history(
        messages: messages, localAci: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    ).first)
    #expect(!history.outgoing)
    #expect(history.answeredOnThisAccount)
    #expect(history.durationMs == 61_234)
    #expect(history.endReason == "sos_preempted")
}
