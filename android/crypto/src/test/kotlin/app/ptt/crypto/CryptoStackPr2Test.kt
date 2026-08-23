package app.ptt.crypto

import java.nio.ByteBuffer
import java.util.UUID
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Assumptions.assumeTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.TestInstance
import org.signal.libsignal.protocol.IdentityKeyPair


@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class CryptoStackPr2Test {
    @BeforeAll
    fun requireJni() {
        try {
            IdentityKeyPair.generate()
        } catch (e: Throwable) {
            assumeTrue(false, "libsignal JNI required: ${e.message}")
        }
    }

    @Test
    fun aadIs36BytesGolden() {
        val channel = UUID.fromString("01020304-0506-4708-890a-0b0c0d0e0f10")
        val talk = UUID.fromString("11121314-1516-4718-991a-1b1c1d1e1f20")
        val aad = ByteBuffer.allocate(36)
            .putLong(channel.mostSignificantBits)
            .putLong(channel.leastSignificantBits)
            .putLong(talk.mostSignificantBits)
            .putLong(talk.leastSignificantBits)
            .putInt(0x01020304)
            .array()
        assertEquals(36, aad.size)
        val hex = aad.joinToString("") { "%02x".format(it) }
        assertEquals(
            "0102030405064708890a0b0c0d0e0f10" +
                "1112131415164718991a1b1c1d1e1f20" +
                "01020304",
            hex,
        )
    }

    @Test
    fun talkStartRoundTrip() {
        val channel = ChannelId(UUID.randomUUID())
        val talkId = UUID.randomUUID()
        val decision =
            FloorDecision(
                requestToken = ByteArray(16) { 7 },
                talkId = talkId,
                totMs = 30_000,
                mediaEpochKid = 99L,
                senderDemux = 3,
            )
        val epoch =
            MediaEpoch(
                talkId = talkId,
                epoch = 1,
                kid = 99L,
                baseKey = ByteArray(16) { 1 },
                suite = CipherSuite.AES_128_GCM_SHA256_128,
                graceMs = 3000,
                senderDemux = 3,
                channelId = channel,
            )
        val bytes = TalkStartCodec.encode(decision, epoch)
        val (d, e, c) = TalkStartCodec.decode(bytes)
        assertEquals(channel, c)
        assertEquals(talkId, d.talkId)
        assertEquals(99L, e.kid)
        assertArrayEquals(epoch.baseKey, e.baseKey)
        assertEquals(3000, e.graceMs)
    }

    @Test
    fun talkStartRejectsMalformedWireValues() {
        val channel = ChannelId(UUID.randomUUID())
        val talkId = UUID.randomUUID()
        val decision = FloorDecision(ByteArray(16), talkId, 30_000, 7L, 3)
        val epoch =
            MediaEpoch(
                talkId,
                1,
                7L,
                ByteArray(16),
                CipherSuite.AES_128_GCM_SHA256_128,
                3000,
                3,
                channel,
            )
        val encoded = TalkStartCodec.encode(decision, epoch)

        val unknownSuite = encoded.copyOf()
        ByteBuffer.wrap(unknownSuite, unknownSuite.size - 8, 4).putInt(0x7fff)
        assertThrows(IllegalArgumentException::class.java) { TalkStartCodec.decode(unknownSuite) }
        assertThrows(IllegalArgumentException::class.java) { TalkStartCodec.decode(encoded.copyOf(encoded.size - 1)) }
        assertThrows(IllegalArgumentException::class.java) { TalkStartCodec.decode(encoded + 0x00) }
    }

    @Test
    fun threeMembersGroupThenKick() =
        runTest {
            val (alice, bob, carol) = triple()
            val channel = ChannelId(UUID.fromString("cccccccc-cccc-4ccc-8ccc-cccccccccccc"))
            distributeSenderKeys(listOf(alice, bob, carol), channel)

            val fp =
                alice.safetyNumberChannel(
                    channel,
                    listOf(
                        alice.localBundle().identityKey,
                        bob.localBundle().identityKey,
                        carol.localBundle().identityKey,
                    ),
                )
            assertEquals(12, fp.split(' ').size)
            assertTrue(fp.split(' ').all { it.length == 5 && it.all(Char::isDigit) })

            val talkId = UUID.randomUUID()
            val epoch =
                MediaEpoch(
                    talkId = talkId,
                    epoch = 1,
                    kid = 1L,
                    baseKey = ByteArray(16) { 9 },
                    suite = CipherSuite.AES_128_GCM_SHA256_128,
                    graceMs = 3000,
                    senderDemux = 1,
                    channelId = channel,
                )
            val decision = FloorDecision(ByteArray(16), talkId, 30_000, 1L, 1)
            val start = alice.encodeTalkStart(decision, epoch)
            val ct1 = alice.groupEncrypt(channel, start)
            val bobStart = bob.decodeTalkStart(bob.groupDecrypt(alice.localDevice(), channel, ct1))
            val carolStart = carol.decodeTalkStart(carol.groupDecrypt(alice.localDevice(), channel, ct1))
            assertArrayEquals(epoch.baseKey, bobStart.second.baseKey)
            assertArrayEquals(epoch.baseKey, carolStart.second.baseKey)

            val oldCarolDist = alice.rotateSenderKey(channel)
            val newSkdm = alice.createSenderKeyDistribution(channel)
            val toBob = alice.encrypt1to1(bob.localDevice(), newSkdm)
            bob.processSenderKeyDistribution(
                alice.localDevice(),
                channel,
                bob.decrypt1to1(alice.localDevice(), toBob),
            )
            // carol is not given the new SKDM
            assertNotEquals(oldCarolDist, UUID(0, 0))

            val ct2 = alice.groupEncrypt(channel, "after-kick".toByteArray())
            val bobPt = bob.groupDecrypt(alice.localDevice(), channel, ct2)
            assertEquals("after-kick", bobPt.decodeToString())
            assertThrows(Exception::class.java) {
                kotlinx.coroutines.runBlocking {
                    carol.groupDecrypt(alice.localDevice(), channel, ct2)
                }
            }
        }

    @Test
    fun sealFallsBackWithoutCertAndOpensWithCert() =
        runTest {
            val (alice, bob, _) = triple()
            val sealed = alice.seal(listOf(bob.localDevice()), "hello".toByteArray())
            assertTrue(sealed.envelopes.isEmpty())
            assertEquals(listOf(bob.localDevice()), sealed.identifiedFallback)

            val ca = TestCertificateAuthority()
            alice.attachTestAuthority(ca)
            bob.attachTestAuthority(ca)
            val again = alice.seal(listOf(bob.localDevice()), "hello".toByteArray())
            assertEquals(1, again.envelopes.size)
            assertTrue(again.identifiedFallback.isEmpty())
            val opened = bob.open(again.envelopes[0].outer)
            assertEquals(alice.localDevice().aci, opened.sender.aci)
            assertEquals("hello", opened.inner.decodeToString())
        }

    private suspend fun triple(): Triple<InMemoryCryptoStack, InMemoryCryptoStack, InMemoryCryptoStack> {
        val alice = stack("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        val bob = stack("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
        val carol = stack("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
        pairwise(alice, bob)
        pairwise(alice, carol)
        pairwise(bob, carol)
        return Triple(alice, bob, carol)
    }

    private suspend fun stack(id: String): InMemoryCryptoStack {
        val s = InMemoryCryptoStack()
        s.debugSetAci(Aci(UUID.fromString(id)))
        s.generateIdentity()
        s.replenishPreKeys(10)
        return s
    }

    private suspend fun pairwise(a: InMemoryCryptoStack, b: InMemoryCryptoStack) {
        a.processPreKeyBundle(b.localDevice(), b.localBundle())
        b.processPreKeyBundle(a.localDevice(), a.localBundle())
    }

    private suspend fun distributeSenderKeys(
        members: List<InMemoryCryptoStack>,
        channel: ChannelId,
    ) {
        for (sender in members) {
            val skdm = sender.createSenderKeyDistribution(channel)
            for (recv in members) {
                if (recv === sender) continue
                val ct = sender.encrypt1to1(recv.localDevice(), skdm)
                recv.processSenderKeyDistribution(
                    sender.localDevice(),
                    channel,
                    recv.decrypt1to1(sender.localDevice(), ct),
                )
            }
        }
    }
}
