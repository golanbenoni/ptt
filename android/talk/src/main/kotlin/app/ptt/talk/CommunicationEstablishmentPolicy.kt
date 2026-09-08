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

internal class ReconnectAttemptGate {
    private val pending = AtomicBoolean(false)

    fun begin(): Boolean = pending.compareAndSet(false, true)

    fun finish() {
        pending.set(false)
    }
}
