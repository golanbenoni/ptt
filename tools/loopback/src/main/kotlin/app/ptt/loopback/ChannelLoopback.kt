package app.ptt.loopback

import app.ptt.crypto.Aci
import app.ptt.crypto.ChannelId
import app.ptt.crypto.CipherSuite
import app.ptt.crypto.FloorDecision
import app.ptt.crypto.InMemoryCryptoStack
import app.ptt.crypto.MediaEpoch
import app.ptt.media.AesGcmFrames
import java.util.UUID
import kotlinx.coroutines.runBlocking

data class ChannelLoopbackResult(
    val bobHeardFirst: Boolean,
    val carolHeardFirst: Boolean,
    val bobHeardAfterKick: Boolean,
    val carolBlockedAfterKick: Boolean,
    val safety: String,
)

fun runChannelLoopback(): ChannelLoopbackResult = runBlocking {
    val alice = stack("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    val bob = stack("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    val carol = stack("cccccccc-cccc-4ccc-8ccc-cccccccccccc")
    pairwise(alice, bob)
    pairwise(alice, carol)
    pairwise(bob, carol)
    val channel = ChannelId(UUID.fromString("dddddddd-dddd-4ddd-8ddd-dddddddddddd"))
    distribute(listOf(alice, bob, carol), channel)

    val talk1 = UUID.randomUUID()
    val epoch1 =
        MediaEpoch(
            talkId = talk1,
            epoch = 1,
            kid = 1L,
            baseKey = AesGcmFrames.newKey(),
            suite = CipherSuite.AES_128_GCM_SHA256_128,
            graceMs = 3000,
            senderDemux = 1,
            channelId = channel,
        )
    val start1 =
        alice.encodeTalkStart(
            FloorDecision(ByteArray(16) { 1 }, talk1, 30_000, 1L, 1),
            epoch1,
        )
    val ct1 = alice.groupEncrypt(channel, start1)
    val bob1 = bob.decodeTalkStart(bob.groupDecrypt(alice.localDevice(), channel, ct1)).second
    val carol1 = carol.decodeTalkStart(carol.groupDecrypt(alice.localDevice(), channel, ct1)).second

    val aad = AesGcmFrames.aad(channel.uuid, talk1, 1)
    val frame = AesGcmFrames(epoch1.baseKey).encrypt(0, aad, sineFrame(0))
    val bobPcm = AesGcmFrames(bob1.baseKey).decrypt(aad, frame)
    val carolPcm = AesGcmFrames(carol1.baseKey).decrypt(aad, frame)

    alice.rotateSenderKey(channel)
    val newSkdm = alice.createSenderKeyDistribution(channel)
    bob.processSenderKeyDistribution(
        alice.localDevice(),
        channel,
        bob.decrypt1to1(alice.localDevice(), alice.encrypt1to1(bob.localDevice(), newSkdm)),
    )

    val talk2 = UUID.randomUUID()
    val epoch2 =
        MediaEpoch(
            talkId = talk2,
            epoch = 2,
            kid = 2L,
            baseKey = AesGcmFrames.newKey(),
            suite = CipherSuite.AES_128_GCM_SHA256_128,
            graceMs = 3000,
            senderDemux = 2,
            channelId = channel,
        )
    val start2 =
        alice.encodeTalkStart(
            FloorDecision(ByteArray(16) { 2 }, talk2, 30_000, 2L, 2),
            epoch2,
        )
    val ct2 = alice.groupEncrypt(channel, start2)
    val bob2Ok =
        runCatching {
            bob.decodeTalkStart(bob.groupDecrypt(alice.localDevice(), channel, ct2))
        }.isSuccess
    val carol2Blocked =
        runCatching {
            carol.groupDecrypt(alice.localDevice(), channel, ct2)
        }.isFailure

    ChannelLoopbackResult(
        bobHeardFirst = bobPcm.size == FRAME_BYTES,
        carolHeardFirst = carolPcm.size == FRAME_BYTES,
        bobHeardAfterKick = bob2Ok,
        carolBlockedAfterKick = carol2Blocked,
        safety =
            alice.safetyNumberChannel(
                channel,
                listOf(
                    alice.localBundle().identityKey,
                    bob.localBundle().identityKey,
                    carol.localBundle().identityKey,
                ),
            ),
    )
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

private suspend fun distribute(members: List<InMemoryCryptoStack>, channel: ChannelId) {
    for (sender in members) {
        val skdm = sender.createSenderKeyDistribution(channel)
        for (recv in members) {
            if (recv === sender) continue
            recv.processSenderKeyDistribution(
                sender.localDevice(),
                channel,
                recv.decrypt1to1(
                    sender.localDevice(),
                    sender.encrypt1to1(recv.localDevice(), skdm),
                ),
            )
        }
    }
}

fun main() {
    println("PTT channel loopback: Alice → Bob+Carol, kick Carol, Alice talks again")
    val r = runChannelLoopback()
    println("first TX  bob=${r.bobHeardFirst} carol=${r.carolHeardFirst}")
    println("after kick bob=${r.bobHeardAfterKick} carolBlocked=${r.carolBlockedAfterKick}")
    println("channelFingerprint=${r.safety}")
    check(r.bobHeardFirst && r.carolHeardFirst) { "first TX failed" }
    check(r.bobHeardAfterKick && r.carolBlockedAfterKick) { "kick rotation failed" }
    println("ok")
}
