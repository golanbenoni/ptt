package app.ptt.talk

import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

internal object CommunicationEstablishmentPolicy {
    fun requiresMetadataRefresh(status: Int?, code: String?): Boolean =
        status == 409 && code in setOf("STALE_MEMBERSHIP_EPOCH", "MEMBERSHIP_EPOCH_MISMATCH")

    fun matchesPreparedMediaEpoch(
        preparedChannelId: String,
        preparedMembershipEpoch: Int,
        preparedDistributionId: String,
        preparedSenderDemux: Long,
        preparedTotMs: Int,
        preparedIsSos: Boolean,
        channel: ChannelSummary,
        senderDemux: Long,
        grantedTotMs: Int,
        isSos: Boolean,
    ): Boolean =
        preparedChannelId == channel.channelId &&
            preparedMembershipEpoch == channel.membershipEpoch &&
            preparedDistributionId == channel.distributionId &&
            preparedSenderDemux == senderDemux &&
            preparedTotMs == grantedTotMs &&
            preparedIsSos == isSos

    fun isTransientNetworkFailure(error: Throwable): Boolean =
        generateSequence(error) { it.cause }.any { cause ->
            cause is IOException ||
                (cause is ControlApiException && (cause.status == 408 || cause.status == 429 || cause.status >= 500))
        }
}

internal object HistoryUploadFailurePolicy {
    fun shouldDefer(error: Throwable): Boolean =
        error is IOException ||
            (error is ControlApiException && (error.status == 429 || error.status >= 500))
}

internal class ExpeditedMailboxPollGate {
    // 0 = idle, 1 = polling, 2 = polling with one coalesced rerun requested.
    private val state = AtomicInteger(0)

    fun begin(): Boolean {
        while (true) {
            when (state.get()) {
                0 -> if (state.compareAndSet(0, 1)) return true
                1 -> if (state.compareAndSet(1, 2)) return false
                else -> return false
            }
        }
    }

    fun finish(): Boolean {
        while (true) {
            when (state.get()) {
                2 -> if (state.compareAndSet(2, 1)) return true
                1 -> if (state.compareAndSet(1, 0)) return false
                else -> return false
            }
        }
    }
}

/**
 * An authenticated envelope is durable before this policy is invoked. Make its media usable
 * before waiting for remote mailbox bookkeeping so network latency on the ACK path cannot delay
 * audible PTT. If local activation fails, the ACK is deliberately not sent and normal mailbox
 * retry semantics preserve the envelope.
 */
internal object AuthenticatedMailboxDeliveryPolicy {
    fun deliver(
        makeLocallyUsable: () -> Unit,
        acknowledgeRemote: () -> Unit,
    ) {
        makeLocallyUsable()
        acknowledgeRemote()
    }
}

internal class ReconnectAttemptGate {
    private val pending = AtomicBoolean(false)

    fun begin(): Boolean = pending.compareAndSet(false, true)

    fun finish() {
        pending.set(false)
    }
}

/**
 * Gives an out-of-order SignalMessage a short opportunity to be overtaken by the
 * PreKeySignalMessage that establishes its session, without letting an immutable
 * envelope for a retired session permanently occupy the front of a mailbox page.
 *
 * The caller supplies monotonic time so wall-clock changes cannot extend the
 * retry window. Entries are removed only after the corresponding server ACK has
 * succeeded; a failed ACK therefore remains immediately eligible on the next poll.
 */
internal class SignalQueueRetryTracker(
    private val gracePeriodMs: Long = 2_000L,
) {
    private val firstFailureAtMs = mutableMapOf<String, Long>()

    init {
        require(gracePeriodMs > 0)
    }

    @Synchronized
    fun shouldAcknowledge(itemId: String, nowMs: Long): Boolean {
        require(itemId.isNotBlank() && nowMs >= 0)
        val firstFailure = firstFailureAtMs.getOrPut(itemId) { nowMs }
        return nowMs - firstFailure >= gracePeriodMs
    }

    @Synchronized
    fun resolved(itemIds: Collection<String>) {
        itemIds.forEach(firstFailureAtMs::remove)
    }
}
