package app.ptt.talk

import java.io.IOException
import java.net.UnknownHostException
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class CommunicationEstablishmentPolicyTest {
    @Test
    fun `metadata refresh is reserved for stale epoch responses`() {
        assertFalse(CommunicationEstablishmentPolicy.requiresMetadataRefresh(null, null))
        assertFalse(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "FLOOR_BUSY"))
        assertTrue(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "STALE_MEMBERSHIP_EPOCH"))
        assertTrue(CommunicationEstablishmentPolicy.requiresMetadataRefresh(409, "MEMBERSHIP_EPOCH_MISMATCH"))
    }

    @Test
    fun `prepared media epoch is used only for its exact authorization context`() {
        val channel = ChannelSummary(
            "f37ae51f-1c51-48a0-b596-27fd14c3ad7c",
            "Operations",
            "private",
            "18c7c7e4-2cdc-44a0-a8ac-1c39c09f1e45",
            7,
            30,
            "talk",
        )
        fun matches(
            membershipEpoch: Int = 7,
            distributionId: String = channel.distributionId,
            senderDemux: Long = 44,
            grantedTotMs: Int = 30_000,
            isSos: Boolean = false,
        ) = CommunicationEstablishmentPolicy.matchesPreparedMediaEpoch(
            channel.channelId,
            membershipEpoch,
            distributionId,
            44,
            30_000,
            false,
            channel,
            senderDemux,
            grantedTotMs,
            isSos,
        )

        assertTrue(matches())
        assertFalse(matches(membershipEpoch = 8))
        assertFalse(matches(distributionId = "29a5edb7-f0a1-4bf5-8a27-4300b98900ea"))
        assertFalse(matches(senderDemux = 45))
        assertFalse(matches(grantedTotMs = 1_000))
        assertFalse(matches(isSos = true))
    }

    @Test
    fun `temporary network failures reconnect without becoming fatal session errors`() {
        assertTrue(CommunicationEstablishmentPolicy.isTransientNetworkFailure(UnknownHostException("offline")))
        assertTrue(
            CommunicationEstablishmentPolicy.isTransientNetworkFailure(
                IllegalStateException("wrapped", IOException("network changed")),
            ),
        )
        assertTrue(CommunicationEstablishmentPolicy.isTransientNetworkFailure(ControlApiException(503, "UNAVAILABLE")))
        assertFalse(CommunicationEstablishmentPolicy.isTransientNetworkFailure(ControlApiException(401, "UNAUTHORIZED")))
        assertFalse(CommunicationEstablishmentPolicy.isTransientNetworkFailure(IllegalArgumentException("bad media")))
    }

    @Test
    fun `unknown packets coalesce mailbox wakeups`() {
        val gate = ExpeditedMailboxPollGate()
        assertTrue(gate.begin())
        assertFalse(gate.begin())
        assertTrue(gate.finish())
        assertFalse(gate.finish())
        assertTrue(gate.begin())
    }

    @Test
    fun `network recovery coalesces pending and running reconnect attempts`() {
        val gate = ReconnectAttemptGate()
        assertTrue(gate.begin())
        assertFalse(gate.begin())

        gate.finish()
        assertTrue(gate.begin())
        assertFalse(gate.begin())
    }

    @Test
    fun `history uploads defer transient failures without hiding permanent failures`() {
        assertTrue(HistoryUploadFailurePolicy.shouldDefer(IOException("offline")))
        assertTrue(HistoryUploadFailurePolicy.shouldDefer(ControlApiException(429, "RATE_LIMITED")))
        assertTrue(HistoryUploadFailurePolicy.shouldDefer(ControlApiException(503, "UNAVAILABLE")))
        assertFalse(HistoryUploadFailurePolicy.shouldDefer(ControlApiException(400, "BAD_REQUEST")))
        assertFalse(HistoryUploadFailurePolicy.shouldDefer(ControlApiException(401, "UNAUTHORIZED")))
    }
}
