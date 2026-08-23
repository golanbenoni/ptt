package app.ptt.net

import org.junit.jupiter.api.Assertions.assertEquals
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
                repeat(2) { index ->
                    var recv: TalkResult? = null
                    var sent: TalkSendResult? = null
                    var err: Throwable? = null
                    val t =
                        thread(name = "bob-recv-${index + 1}") {
                            try {
                                recv = bob.recvTone(timeoutMs = 10_000)
                            } catch (e: Throwable) {
                                err = e
                            }
                        }
                    Thread.sleep(200)
                    sent = alice.sendToneDetailed(durationMs = 400, paceMs = 1)
                    t.join(12_000)
                    err?.let { throw it }
                    val r = recv ?: error("bob got nothing on tone ${index + 1}")
                    val sendEncryption = requireNotNull(sent).encryption
                    val receiveEncryption = requireNotNull(r.encryption)
                    assertTrue(r.frames >= 10, "tone=${index + 1} frames=${r.frames}")
                    assertTrue(r.energy > 50_000, "tone=${index + 1} energy=${r.energy}")
                    assertEquals(sendEncryption.talkId, receiveEncryption.talkId)
                    assertEquals(sendEncryption.channel, receiveEncryption.channel)
                    assertEquals(sendEncryption.mediaKeyFingerprint, receiveEncryption.mediaKeyFingerprint)
                    assertEquals(sendEncryption.aadFingerprint, receiveEncryption.aadFingerprint)
                    assertEquals(sendEncryption.wrappedKeyBytes, receiveEncryption.wrappedKeyBytes)
                }
            }
        }
    }
}
