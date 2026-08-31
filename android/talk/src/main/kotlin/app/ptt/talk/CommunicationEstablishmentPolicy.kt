package app.ptt.talk

import java.util.concurrent.atomic.AtomicInteger

internal object CommunicationEstablishmentPolicy {
    fun requiresMetadataRefresh(status: Int?, code: String?): Boolean =
        status == 409 && code in setOf("STALE_MEMBERSHIP_EPOCH", "MEMBERSHIP_EPOCH_MISMATCH")
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
