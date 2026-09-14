package app.ptt.talk

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Keeps latency-sensitive floor work isolated from best-effort mailbox polling.
 *
 * A mailbox request can legitimately wait for its network timeout during a connectivity outage.
 * Sharing that serial executor with a press would make an otherwise healthy, already-connected
 * media path wait behind the poll. Both queues remain serial so their own state transitions stay
 * ordered, while a stalled receive poll can no longer delay microphone activation.
 */
internal class PttSessionWorkQueues(
    val session: ExecutorService = namedSingleThreadExecutor("ptt-session-worker"),
    val mailbox: ExecutorService = namedSingleThreadExecutor("ptt-mailbox-worker"),
) {
    fun shutdownNow() {
        session.shutdownNow()
        mailbox.shutdownNow()
    }

    private companion object {
        fun namedSingleThreadExecutor(name: String): ExecutorService =
            Executors.newSingleThreadExecutor { runnable -> Thread(runnable, name) }
    }
}
