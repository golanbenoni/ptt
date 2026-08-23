package app.ptt.net

import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.signal.libsignal.protocol.IdentityKeyPair
import kotlin.concurrent.thread

@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class TwoClientRelayTest {
    @BeforeAll
    fun requireJni() {
        try {
            IdentityKeyPair.generate()
        } catch (e: Throwable) {
            assumeTrue(false, "libsignal JNI required: ${e.message}")
        }
    }

    @Test
    fun twoClientsThroughRelay() {
        PrekeyServer().use { prekey ->
            RelayServer().use { relay ->
                val alice =
                    TalkClient(
                        DemoIds.ALICE,
                        DemoIds.BOB,
                        prekey.baseUrl,
                        "127.0.0.1",
                        relay.port,
                    )
                val bob =
                    TalkClient(
                        DemoIds.BOB,
                        DemoIds.ALICE,
                        prekey.baseUrl,
                        "127.0.0.1",
                        relay.port,
                    )
                var recv: TalkResult? = null
                var err: Throwable? = null
                val t =
                    thread(name = "bob-recv") {
                        try {
                            recv = bob.recvTone(timeoutMs = 10_000)
                        } catch (e: Throwable) {
                            err = e
                        }
                    }
                Thread.sleep(200)
                alice.sendTone(durationMs = 400, paceMs = 1)
                t.join(12_000)
                err?.let { throw it }
                val r = recv ?: error("bob got nothing")
                assertTrue(r.frames >= 10, "frames=${r.frames}")
                assertTrue(r.energy > 50_000, "energy=${r.energy}")
            }
        }
    }
}
