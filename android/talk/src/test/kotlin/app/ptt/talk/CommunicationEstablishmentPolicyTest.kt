package app.ptt.talk

import java.io.IOException
import java.net.UnknownHostException
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.assertThrows
import org.junit.jupiter.api.Test

class CommunicationEstablishmentPolicyTest {
    @Test
    fun `authenticated media becomes usable before remote mailbox acknowledgement`() {
        val events = mutableListOf<String>()

        AuthenticatedMailboxDeliveryPolicy.deliver(
            makeLocallyUsable = { events += "playable" },
            acknowledgeRemote = { events += "acknowledged" },
        )

        assertEquals(listOf("playable", "acknowledged"), events)
    }

    @Test
    fun `failed local activation does not acknowledge the authenticated envelope`() {
        var acknowledged = false

        assertThrows<IllegalStateException> {
            AuthenticatedMailboxDeliveryPolicy.deliver(
                makeLocallyUsable = { error("playback unavailable") },
                acknowledgeRemote = { acknowledged = true },
            )
        }

        assertFalse(acknowledged)
    }

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
    fun `relay reconnect preserves only the exact active authorization context`() {
        val active = ChannelSummary(
            "f37ae51f-1c51-48a0-b596-27fd14c3ad7c",
            "Operations",
            "private",
            "18c7c7e4-2cdc-44a0-a8ac-1c39c09f1e45",
            7,
            30,
            "talk",
        )

        assertTrue(CommunicationEstablishmentPolicy.canPreserveIncoming(active, active.copy(displayName = "Ops")))
        assertFalse(CommunicationEstablishmentPolicy.canPreserveIncoming(null, active))
        assertFalse(CommunicationEstablishmentPolicy.canPreserveIncoming(active, active.copy(membershipEpoch = 8)))
        assertFalse(
            CommunicationEstablishmentPolicy.canPreserveIncoming(
                active,
                active.copy(distributionId = "29a5edb7-f0a1-4bf5-8a27-4300b98900ea"),
            ),
        )
        assertFalse(
            CommunicationEstablishmentPolicy.canPreserveIncoming(
                active,
                active.copy(channelId = "6044fb95-9cf8-4cc0-a30e-e36447e29ba5"),
            ),
        )
    }

    @Test
    fun `history recovery requires a partial live transmission without authenticated end`() {
        assertTrue(CommunicationEstablishmentPolicy.shouldRecoverInterruptedIncoming(true, false, false))
        assertTrue(CommunicationEstablishmentPolicy.shouldRecoverInterruptedIncoming(false, false, true))
        assertFalse(CommunicationEstablishmentPolicy.shouldRecoverInterruptedIncoming(false, false, false))
        assertFalse(CommunicationEstablishmentPolicy.shouldRecoverInterruptedIncoming(true, true, true))
        assertFalse(CommunicationEstablishmentPolicy.shouldRecoverInterruptedIncoming(false, true, true))
    }

    @Test
    fun `whole history recovery is bounded to a verified recent relay interruption`() {
        val recovery = RelayInterruptionRecoveryWindow(
            lookbackMs = 10_000,
            lifetimeMs = 30_000,
            futureClockSkewMs = 5_000,
        )

        assertFalse(recovery.includes(95_000, 100_000))
        recovery.mark(100_000)
        assertTrue(recovery.includes(90_000, 100_000))
        assertTrue(recovery.includes(105_000, 100_000))
        assertFalse(recovery.includes(89_999, 100_000))
        assertFalse(recovery.includes(105_001, 100_000))
        assertTrue(recovery.includes(99_000, 130_000))
        assertFalse(recovery.includes(99_000, 130_001))
        assertFalse(recovery.includes(99_000, 99_999))
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
    fun `live mailbox requests are bounded below the talk separation window`() {
        assertEquals(1_000L, MailboxDeliveryTimingPolicy.MAX_NETWORK_WAIT_MS)
        assertFalse(MailboxDeliveryTimingPolicy.isSlow(499))
        assertTrue(MailboxDeliveryTimingPolicy.isSlow(500))
    }

    @Test
    fun `live call coordination cannot block beyond its authenticated recovery window`() {
        assertEquals(250L, CallCoordinationTimingPolicy.MAX_NETWORK_WAIT_MS)
        assertEquals(5_000L, CallCoordinationTimingPolicy.MAX_AUTHENTICATED_STATE_AGE_MS)
        assertEquals(25L, CallCoordinationTimingPolicy.RETRY_DELAY_MS)
        assertEquals(2, CallCoordinationTimingPolicy.MAX_IDEMPOTENT_SEND_ATTEMPTS)
        assertTrue(
            CallCoordinationTimingPolicy.mayRetry(
                IOException("network transition"), lastAuthenticatedAtMs = 10_000, nowMs = 14_999,
            ),
        )
        assertTrue(
            CallCoordinationTimingPolicy.mayRetry(
                ControlApiException(503, "UNAVAILABLE"), lastAuthenticatedAtMs = 10_000, nowMs = 15_000,
            ),
        )
        assertFalse(
            CallCoordinationTimingPolicy.mayRetry(
                IOException("still offline"), lastAuthenticatedAtMs = 10_000, nowMs = 15_001,
            ),
        )
        assertFalse(
            CallCoordinationTimingPolicy.mayRetry(
                ControlApiException(401, "UNAUTHORIZED"), lastAuthenticatedAtMs = 10_000, nowMs = 10_100,
            ),
        )
        assertFalse(
            CallCoordinationTimingPolicy.mayRetry(
                IOException("clock moved backwards"), lastAuthenticatedAtMs = 10_000, nowMs = 9_999,
            ),
        )
        assertTrue(
            CallCoordinationTimingPolicy.mayRetryIdempotentSend(
                IOException("response lost"), completedAttempts = 1,
            ),
        )
        assertFalse(
            CallCoordinationTimingPolicy.mayRetryIdempotentSend(
                IOException("still unavailable"), completedAttempts = 2,
            ),
        )
        assertFalse(
            CallCoordinationTimingPolicy.mayRetryIdempotentSend(
                ControlApiException(403, "FORBIDDEN"), completedAttempts = 1,
            ),
        )
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
    fun `missing Signal sessions get bounded reorder grace without starving the mailbox`() {
        val retries = SignalQueueRetryTracker(gracePeriodMs = 2_000)

        assertFalse(retries.shouldAcknowledge("stale-item", 10_000))
        assertFalse(retries.shouldAcknowledge("stale-item", 11_999))
        assertTrue(retries.shouldAcknowledge("stale-item", 12_000))

        // A successful server ACK removes the old observation. Reuse of the value starts a
        // fresh grace interval instead of inheriting state from a completed queue item.
        retries.resolved(listOf("stale-item"))
        assertFalse(retries.shouldAcknowledge("stale-item", 20_000))
        assertTrue(retries.shouldAcknowledge("stale-item", 22_000))
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
