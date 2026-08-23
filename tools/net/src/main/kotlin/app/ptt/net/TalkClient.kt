package app.ptt.net

import app.ptt.crypto.Aci
import app.ptt.crypto.DeviceId
import app.ptt.crypto.InMemoryCryptoStack
import app.ptt.media.AesGcmFrames
import app.ptt.media.FRAME_BYTES
import app.ptt.media.FRAME_MS
import app.ptt.media.pcmEnergy
import app.ptt.media.sineFrame
import app.ptt.media.writeWav
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URI
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.runBlocking

data class EncryptionDiagnostics(
    val algorithm: String,
    val keyEstablishment: String,
    val channel: UUID,
    val talkId: UUID,
    val senderAci: UUID,
    val receiverAci: UUID,
    val demux: Int,
    val frameCount: Int,
    val wrappedKeyBytes: Int,
    val mediaKeyFingerprint: String,
    val aadFingerprint: String,
)

data class TalkSendResult(val frames: Int, val encryption: EncryptionDiagnostics)

data class TalkResult(
    val pcm: ByteArray,
    val frames: Int,
    val energy: Long,
    val encryption: EncryptionDiagnostics?,
)

object DemoIds {
    val ALICE = UUID.fromString("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
    val BOB = UUID.fromString("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
    val CHANNEL = UUID.fromString("dddddddd-dddd-4ddd-8ddd-dddddddddddd")
}

class TalkClient(
    private val selfAci: UUID,
    private val peerAci: UUID,
    private val prekeyBase: String,
    private val relayHost: String,
    private val relayPort: Int,
    private val channel: UUID = DemoIds.CHANNEL,
) {
    fun sendTone(durationMs: Int = 800, paceMs: Long = 0, bindWaitMs: Long = 80): Int =
        sendToneDetailed(durationMs, paceMs, bindWaitMs).frames

    fun sendToneDetailed(
        durationMs: Int = 800,
        paceMs: Long = 0,
        bindWaitMs: Long = 80,
    ): TalkSendResult = runBlocking {
        val self = stack(selfAci)
        putBundle(self)
        waitForPeer()
        val peerBundle = getBundle(peerAci)
        self.processPreKeyBundle(DeviceId(Aci(peerAci)), peerBundle)

        val frames = durationMs / FRAME_MS
        val talkId = UUID.randomUUID()
        val demux = 1
        val mediaKey = AesGcmFrames.newKey()
        val wrapped = self.encrypt1to1(DeviceId(Aci(peerAci)), mediaKey)
        val aad = AesGcmFrames.aad(channel, talkId, demux)
        val gcm = AesGcmFrames(mediaKey)

        DatagramSocket().use { sock ->
            val relay = InetAddress.getByName(relayHost)
            fun send(bytes: ByteArray) {
                sock.send(DatagramPacket(bytes, bytes.size, relay, relayPort))
            }
            send(Packets.bind(channel, selfAci))
            Thread.sleep(bindWaitMs)
            send(Packets.key(channel, talkId, demux, frames, wrapped))
            repeat(frames) { i ->
                val payload = gcm.encrypt(i.toLong(), aad, sineFrame(i))
                send(Packets.frame(channel, talkId, demux, payload))
                if (paceMs > 0) Thread.sleep(paceMs)
            }
        }
        TalkSendResult(
            frames,
            EncryptionDiagnostics(
                algorithm = "AES-128-GCM (128-bit tag)",
                keyEstablishment = "Signal PQXDH + 1:1 key wrap",
                channel = channel,
                talkId = talkId,
                senderAci = selfAci,
                receiverAci = peerAci,
                demux = demux,
                frameCount = frames,
                wrappedKeyBytes = wrapped.size,
                mediaKeyFingerprint = fingerprint(mediaKey),
                aadFingerprint = fingerprint(aad),
            ),
        )
    }

    fun recvTone(
        outWav: File? = null,
        timeoutMs: Int = 8_000,
        shouldContinue: () -> Boolean = { true },
    ): TalkResult = runBlocking {
        val self = stack(selfAci)
        putBundle(self)

        DatagramSocket().use { sock ->
            sock.soTimeout = 250
            val relay = InetAddress.getByName(relayHost)
            val bind = Packets.bind(channel, selfAci)
            // Bind before the talker PUTs so the relay has a 5-tuple when frames arrive.
            sock.send(DatagramPacket(bind, bind.size, relay, relayPort))
            val buf = ByteArray(4096)
            var talkId: UUID? = null
            var demux = 0
            var expected = 0
            var gcm: AesGcmFrames? = null
            var encryption: EncryptionDiagnostics? = null
            val pcm = ByteArrayOutputStream()
            val deadline = System.currentTimeMillis() + timeoutMs
            while (System.currentTimeMillis() < deadline && shouldContinue()) {
                val pkt = DatagramPacket(buf, buf.size)
                try {
                    sock.receive(pkt)
                } catch (_: Exception) {
                    continue
                }
                val data = buf.copyOf(pkt.length)
                when (Packets.type(data)) {
                    Packets.KEY -> {
                        talkId = Packets.talkId(data)
                        demux = Packets.demux(data)
                        expected = Packets.keyFrameCount(data)
                        val wrapped = Packets.keyWrapped(data)
                        val key = self.decrypt1to1(DeviceId(Aci(peerAci)), wrapped)
                        gcm = AesGcmFrames(key)
                        val tid = requireNotNull(talkId)
                        val aad = AesGcmFrames.aad(channel, tid, demux)
                        encryption =
                            EncryptionDiagnostics(
                                algorithm = "AES-128-GCM (128-bit tag)",
                                keyEstablishment = "Signal PQXDH + 1:1 key wrap",
                                channel = channel,
                                talkId = tid,
                                senderAci = peerAci,
                                receiverAci = selfAci,
                                demux = demux,
                                frameCount = expected,
                                wrappedKeyBytes = wrapped.size,
                                mediaKeyFingerprint = fingerprint(key),
                                aadFingerprint = fingerprint(aad),
                            )
                    }
                    Packets.FRAME -> {
                        val crypto = gcm ?: continue
                        val tid = talkId ?: continue
                        val aad = AesGcmFrames.aad(channel, tid, demux)
                        pcm.write(crypto.decrypt(aad, Packets.framePayload(data)))
                        if (expected > 0 && pcm.size() >= expected * FRAME_BYTES) break
                    }
                }
            }
            val bytes = pcm.toByteArray()
            if (outWav != null) writeWav(bytes, outWav)
            TalkResult(bytes, bytes.size / FRAME_BYTES, pcmEnergy(bytes), encryption)
        }
    }

    private fun fingerprint(data: ByteArray): String =
        MessageDigest.getInstance("SHA-256")
            .digest(data)
            .take(8)
            .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    private suspend fun stack(aci: UUID): InMemoryCryptoStack {
        val s = InMemoryCryptoStack()
        s.debugSetAci(Aci(aci))
        s.generateIdentity()
        s.replenishPreKeys(20)
        return s
    }

    private suspend fun putBundle(s: InMemoryCryptoStack) {
        val json = BundleJson.toJson(s.localBundle())
        val url = URI.create("$prekeyBase/v1/prekeys/${s.localDevice().aci.uuid}").toURL()
        val c = url.openConnection() as HttpURLConnection
        c.requestMethod = "PUT"
        c.doOutput = true
        c.setRequestProperty("Content-Type", "application/json")
        c.outputStream.use { it.write(json.toByteArray()) }
        check(c.responseCode in 200..299) { "put prekeys ${c.responseCode}" }
        c.disconnect()
    }

    private fun waitForPeer() {
        val deadline = System.currentTimeMillis() + 8_000
        while (System.currentTimeMillis() < deadline) {
            val c = URI.create("$prekeyBase/v1/prekeys/$peerAci").toURL().openConnection() as HttpURLConnection
            c.requestMethod = "GET"
            val code = c.responseCode
            c.disconnect()
            if (code == 200) return
            Thread.sleep(50)
        }
        error("peer $peerAci never registered")
    }

    private fun getBundle(aci: UUID): app.ptt.crypto.PreKeyBundleDto {
        val c = URI.create("$prekeyBase/v1/prekeys/$aci").toURL().openConnection() as HttpURLConnection
        c.requestMethod = "GET"
        val body = c.inputStream.use { it.readBytes().decodeToString() }
        val code = c.responseCode
        c.disconnect()
        check(code == 200) { "get prekeys $code" }
        return BundleJson.fromJson(body)
    }
}
