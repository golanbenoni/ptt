package app.ptt.talk

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.time.Instant
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class EncryptedCallTest {
    @Test
    fun `call keys target only the device that claimed the account seat`() {
        val aci = "33333333-3333-4333-8333-333333333333"
        val recipient = CallKeyRecipient(aci.uppercase(), 2)
        fun device(id: Int) = ChannelDevice(
            aci, "Teammate", "member", id, UUID.randomUUID().toString(),
            ByteArray(33) { 1 }, "member",
        )

        assertTrue(recipient.matches(device(2)))
        assertFalse(recipient.matches(device(1)))
        assertThrows(IllegalArgumentException::class.java) { CallKeyRecipient(aci, 3) }
    }

    @Test
    fun `normal calls exclusively own audio while SOS preempts`() {
        assertEquals(
            PttCallAudioDecision.PLAY,
            PttCallAudioPriorityPolicy.decide(callActive = false, isSos = false),
        )
        assertEquals(
            PttCallAudioDecision.ARCHIVE_ONLY,
            PttCallAudioPriorityPolicy.decide(callActive = true, isSos = false),
        )
        assertEquals(
            PttCallAudioDecision.PREEMPT_CALL,
            PttCallAudioPriorityPolicy.decide(callActive = true, isSos = true),
        )
    }

    @Test
    fun callKeyEnvelopeMatchesFrozenSwiftVector() {
        val message = EncryptedCallKeyMessage(
            messageId = UUID.fromString("00010203-0405-4607-8809-0a0b0c0d0e0f"),
            channelId = UUID.fromString("11111111-1111-4111-8111-111111111111"),
            membershipEpoch = 4,
            callId = UUID.fromString("22222222-2222-4222-8222-222222222222"),
            callEpoch = 7,
            kind = EncryptedCallKeyMessageKind.ANNOUNCEMENT,
            participantIdentity = "opaque-participant-0123456789",
            key = ByteArray(32) { 0x5a },
        )
        val expected = (
            "505454430101" +
                "000102030405460788090a0b0c0d0e0f" +
                "11111111111141118111111111111111" +
                "22222222222242228222222222222222" +
                "00000004000000071d" +
                "6f70617175652d7061727469636970616e742d30313233343536373839" +
                "5a".repeat(32)
            ).hexBytes()

        assertArrayEquals(expected, EncryptedCallKeyCodec.encode(message))
        val decoded = EncryptedCallKeyCodec.decode(
            expected,
            senderAci = "33333333-3333-4333-8333-333333333333",
            senderDeviceId = 2,
        )
        assertEquals(message.messageId, decoded.messageId)
        assertArrayEquals(message.key, decoded.key)
    }

    @Test
    fun `durable call key queue preserves sender binding and rejects truncation`() {
        val announcement = EncryptedCallKeyMessage(
            messageId = UUID.fromString("00010203-0405-4607-8809-0a0b0c0d0e0f"),
            channelId = UUID.fromString("11111111-1111-4111-8111-111111111111"),
            membershipEpoch = 4,
            callId = UUID.fromString("22222222-2222-4222-8222-222222222222"),
            callEpoch = 7,
            kind = EncryptedCallKeyMessageKind.ANNOUNCEMENT,
            participantIdentity = "opaque-participant-0123456789",
            key = ByteArray(32) { 0x5a },
            senderAci = "33333333-3333-4333-8333-333333333333",
            senderDeviceId = 2,
        )
        val acknowledgement = announcement.copy(
            messageId = UUID.fromString("01010203-0405-4607-8809-0a0b0c0d0e0f"),
            kind = EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT,
            key = ByteArray(16) { it.toByte() },
        )
        val encoded = EncryptedCallKeyQueueCodec.encode(listOf(announcement, acknowledgement))

        assertEquals(listOf(announcement, acknowledgement), EncryptedCallKeyQueueCodec.decode(encoded))
        assertThrows(IllegalArgumentException::class.java) {
            EncryptedCallKeyQueueCodec.decode(encoded.copyOf(encoded.size - 1))
        }
        assertThrows(IllegalArgumentException::class.java) {
            EncryptedCallKeyQueueCodec.encode(
                List(EncryptedCallKeyQueueCodec.MAX_MESSAGES + 1) { announcement.copy(messageId = UUID.randomUUID()) },
            )
        }
    }

    @Test
    fun frameKeyMatchesFrozenSwiftVector() {
        val actual = EncryptedCallSession.frameKey(
            material = ByteArray(32) { 7 },
            callId = "11111111-1111-4111-8111-111111111111",
            epoch = 1,
            participantIdentity = "participant-a-012345",
        )
        assertArrayEquals(
            "a5f3a911f966ca19b03dcf0e176de4087845d9d768c54142a4dde7a7adfeb978".hexBytes(),
            actual,
        )
    }

    @Test
    fun `debug acoustic processor emits five bounded tone bursts and source markers`() {
        val markers = AtomicInteger()
        val processor = SyntheticCallAudioProcessor { markers.incrementAndGet() }
        val renderDiagnostic = CallAudioRenderDiagnosticProcessor()
        val sampleRate = SyntheticCallAudioProcessor.SAMPLE_RATE
        val renderedFrames = sampleRate * 10
        val framesPerCallback = sampleRate / 100
        val buffer = ByteBuffer.allocateDirect(framesPerCallback * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        var nonSilentCallbacks = 0

        assertTrue(processor.isEnabled())
        assertEquals("PTT call acoustic fixture", processor.getName())
        processor.initializeAudioProcessing(sampleRate, 1)
        renderDiagnostic.initializeAudioProcessing(sampleRate, 1)
        processor.start()
        repeat(renderedFrames / framesPerCallback) {
            buffer.clear()
            processor.processAudio(3, framesPerCallback, buffer)
            renderDiagnostic.processAudio(3, framesPerCallback, buffer)
            val output = buffer.asFloatBuffer()
            if ((0 until output.remaining()).any { output.get(it) != 0f }) nonSilentCallbacks += 1
        }

        assertEquals(SyntheticCallAudioProcessor.BURSTS.toInt(), markers.get())
        assertEquals(SyntheticCallAudioProcessor.BURSTS.toInt(), renderDiagnostic.toneBurstCount)
        assertTrue(renderDiagnostic.peakRms > 10_000f)
        assertTrue(renderDiagnostic.peakCorrelation > 0.6f)
        assertEquals(500, nonSilentCallbacks)

        processor.stop()
        val stopped = ByteBuffer.allocateDirect(framesPerCallback * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder())
        processor.processAudio(3, framesPerCallback, stopped)
        assertTrue((0 until stopped.asFloatBuffer().remaining()).all { stopped.asFloatBuffer().get(it) == 0f })
        assertEquals(SyntheticCallAudioProcessor.BURSTS.toInt(), markers.get())
    }

    @Test
    fun callKeyAcknowledgementBindsTheExactKeyFingerprint() {
        val message = EncryptedCallKeyMessage(
            messageId = UUID.fromString("01010203-0405-4607-8809-0a0b0c0d0e0f"),
            channelId = UUID.fromString("11111111-1111-4111-8111-111111111111"),
            membershipEpoch = 4,
            callId = UUID.fromString("22222222-2222-4222-8222-222222222222"),
            callEpoch = 7,
            kind = EncryptedCallKeyMessageKind.ACKNOWLEDGEMENT,
            participantIdentity = "opaque-participant-0123456789",
            key = ByteArray(16) { it.toByte() },
        )
        val encoded = EncryptedCallKeyCodec.encode(message)
        assertArrayEquals(
            ByteArray(16) { it.toByte() },
            EncryptedCallKeyCodec.decode(
                encoded, "33333333-3333-4333-8333-333333333333", 1,
            ).key,
        )
    }

    @Test
    fun encryptedCallTimelineMatchesFrozenSwiftVectorAndBuildsHistory() {
        val callId = UUID.fromString("22222222-2222-4222-8222-222222222222")
        val channelId = UUID.fromString("11111111-1111-4111-8111-111111111111")
        val startedAt = Instant.ofEpochMilli(1_788_901_234_567)
        val event = EncryptedCallTimelineEvent(
            callId = callId,
            kind = CallTimelineEventKind.ENDED,
            startedAt = startedAt,
            durationMs = 61_234,
            participantCount = 3,
            endReason = "sos_preempted",
        )
        val encoded = EncryptedCallTimelineCodec.encode(event)
        assertEquals(
            "ptt-call-event:v1|ended|22222222-2222-4222-8222-222222222222|1788901234567|61234|3|sos_preempted",
            encoded,
        )
        assertEquals(event, EncryptedCallTimelineCodec.decode(encoded))
        assertEquals(null, EncryptedCallTimelineCodec.decode("ordinary encrypted chat"))

        val messages = listOf(
            ChatMessage(
                UUID.randomUUID(), channelId, 4, startedAt, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 1,
                ChatContentKind.TEXT,
                EncryptedCallTimelineCodec.encode(event.copy(kind = CallTimelineEventKind.STARTED, durationMs = 0, endReason = "")),
            ),
            ChatMessage(
                UUID.randomUUID(), channelId, 4, startedAt.plusSeconds(1), "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", 1,
                ChatContentKind.TEXT,
                EncryptedCallTimelineCodec.encode(event.copy(kind = CallTimelineEventKind.ANSWERED, durationMs = 0, endReason = "")),
            ),
            ChatMessage(
                UUID.randomUUID(), channelId, 4, startedAt.plusMillis(61_234), "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 1,
                ChatContentKind.TEXT, encoded,
            ),
        )
        val history = EncryptedCallTimelineCodec.history(messages, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb").single()
        assertEquals(false, history.outgoing)
        assertEquals(true, history.answeredOnThisAccount)
        assertEquals(61_234, history.durationMs)
        assertEquals("sos_preempted", history.endReason)
    }

    private fun String.hexBytes(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()
}
