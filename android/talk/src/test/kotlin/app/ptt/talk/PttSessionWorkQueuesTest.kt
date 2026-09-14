package app.ptt.talk

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PttSessionWorkQueuesTest {
    @Test
    fun `blocked mailbox request cannot delay floor work`() {
        val queues = PttSessionWorkQueues()
        val mailboxStarted = CountDownLatch(1)
        val releaseMailbox = CountDownLatch(1)
        val floorCompleted = CountDownLatch(1)

        try {
            queues.mailbox.execute {
                mailboxStarted.countDown()
                releaseMailbox.await(5, TimeUnit.SECONDS)
            }
            assertTrue(mailboxStarted.await(1, TimeUnit.SECONDS))

            queues.session.execute { floorCompleted.countDown() }

            assertTrue(
                floorCompleted.await(500, TimeUnit.MILLISECONDS),
                "floor work waited behind a blocked mailbox request",
            )
        } finally {
            releaseMailbox.countDown()
            queues.shutdownNow()
        }
    }
}
