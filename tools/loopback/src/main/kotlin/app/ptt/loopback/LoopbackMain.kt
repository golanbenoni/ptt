package app.ptt.loopback

import app.ptt.crypto.Aci
import app.ptt.crypto.DeviceId
import app.ptt.crypto.InMemoryCryptoStack
import app.ptt.floor.FloorState
import app.ptt.floor.InMemoryFloorController
import app.ptt.floor.PeerPresence
import app.ptt.floor.TalkTarget
import app.ptt.media.AesGcmFrames
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.concurrent.thread
import kotlin.math.PI
import kotlin.math.sin
import kotlinx.coroutines.runBlocking

const val SAMPLE_RATE = 16_000
const val FRAME_MS = 20
const val SAMPLES_PER_FRAME = SAMPLE_RATE * FRAME_MS / 1000
const val FRAME_BYTES = SAMPLES_PER_FRAME * 2
const val DURATION_MS = 2_000
const val PORT = 47_111

data class LoopbackResult(
    val pcm: ByteArray,
    val frames: Int,
    val talkId: UUID,
    val safetyNumber: String,
)

fun runLoopback(durationMs: Int = DURATION_MS, paceMs: Long = FRAME_MS.toLong()): LoopbackResult =
    runBlocking {
    val aliceAci = Aci(UUID.fromString("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
    val bobAci = Aci(UUID.fromString("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
    val alice = InMemoryCryptoStack()
    val bob = InMemoryCryptoStack()
    alice.debugSetAci(aliceAci)
    bob.debugSetAci(bobAci)
    alice.generateIdentity()
    bob.generateIdentity()
    alice.replenishPreKeys(20)
    bob.replenishPreKeys(20)
    alice.processPreKeyBundle(DeviceId(bobAci), bob.localBundle())
    bob.processPreKeyBundle(DeviceId(aliceAci), alice.localBundle())

    val floor = InMemoryFloorController()
    floor.setDirectPeerPresence(bobAci, PeerPresence.AVAILABLE)
    floor.pttDown(TalkTarget.Direct(bobAci))
    val granted = floor.state.value as FloorState.Granted
    val talkId = granted.talkId
    val demux = 1
    val mediaKey = AesGcmFrames.newKey()
    val wrapped = alice.encrypt1to1(DeviceId(bobAci), mediaKey)
    val unwrapped = bob.decrypt1to1(DeviceId(aliceAci), wrapped)
    check(unwrapped.contentEquals(mediaKey)) { "media key wrap failed" }

    val aad = AesGcmFrames.aad(UUID(0, 0), talkId, demux)
    val tx = AesGcmFrames(mediaKey)
    val rx = AesGcmFrames(unwrapped)
    val frames = durationMs / FRAME_MS
    val pcmOut = ByteArrayOutputStream()

    DatagramSocket().use { sender ->
        DatagramSocket(PORT, InetAddress.getByName("127.0.0.1")).use { receiver ->
            receiver.soTimeout = 2_000
            val recvThread =
                thread(name = "bob-rx") {
                    val buf = ByteArray(2048)
                    repeat(frames) {
                        val pkt = DatagramPacket(buf, buf.size)
                        receiver.receive(pkt)
                        val data = buf.copyOf(pkt.length)
                        val pcm = rx.decrypt(aad, data)
                        synchronized(pcmOut) { pcmOut.write(pcm) }
                    }
                }
            repeat(frames) { i ->
                val pcm = sineFrame(i)
                val wire = tx.encrypt(i.toLong(), aad, pcm)
                sender.send(
                    DatagramPacket(wire, wire.size, InetAddress.getByName("127.0.0.1"), PORT),
                )
                if (paceMs > 0) Thread.sleep(paceMs)
            }
            recvThread.join(5_000)
        }
    }
    floor.pttUp(TalkTarget.Direct(bobAci))
    LoopbackResult(
        pcm = pcmOut.toByteArray(),
        frames = frames,
        talkId = talkId,
        safetyNumber = alice.safetyNumber1to1(bobAci),
    )
}

fun sineFrame(index: Int): ByteArray {
    val start = index * SAMPLES_PER_FRAME
    val buf = ByteBuffer.allocate(FRAME_BYTES).order(ByteOrder.LITTLE_ENDIAN)
    val freq = 440.0
    for (n in 0 until SAMPLES_PER_FRAME) {
        val t = (start + n).toDouble() / SAMPLE_RATE
        val s = (sin(2.0 * PI * freq * t) * 16_000).toInt().toShort()
        buf.putShort(s)
    }
    return buf.array()
}

fun writeWav(pcm: ByteArray, file: File) {
    val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
    val dataSize = pcm.size
    header.put("RIFF".toByteArray())
    header.putInt(36 + dataSize)
    header.put("WAVE".toByteArray())
    header.put("fmt ".toByteArray())
    header.putInt(16)
    header.putShort(1) // PCM
    header.putShort(1) // mono
    header.putInt(SAMPLE_RATE)
    header.putInt(SAMPLE_RATE * 2)
    header.putShort(2) // block align
    header.putShort(16)
    header.put("data".toByteArray())
    header.putInt(dataSize)
    file.outputStream().use {
        it.write(header.array())
        it.write(pcm)
    }
}

fun playIfPossible(wav: File) {
    val players = listOf(
        listOf("aplay", "-q", wav.absolutePath),
        listOf("paplay", wav.absolutePath),
        listOf("ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet", wav.absolutePath),
    )
    for (cmd in players) {
        val bin = cmd.first()
        val found = Runtime.getRuntime().exec(arrayOf("which", bin)).waitFor() == 0
        if (!found) continue
        println("playing with $bin")
        ProcessBuilder(cmd).inheritIO().start().waitFor()
        return
    }
    println("no aplay/paplay/ffplay — open ${wav.absolutePath}")
}

fun main() {
    println("PTT loopback: Alice → UDP 127.0.0.1:$PORT → Bob (PQXDH + AES-GCM frames)")
    val result = runLoopback()
    val out = File("build/ptt-loopback.wav")
    out.parentFile.mkdirs()
    writeWav(result.pcm, out)
    println("talkId=${result.talkId}")
    println("safetyNumber=${result.safetyNumber}")
    println("frames=${result.frames} pcmBytes=${result.pcm.size} wav=${out.absolutePath}")
    check(result.pcm.size == result.frames * FRAME_BYTES) {
        "expected ${result.frames * FRAME_BYTES} pcm bytes, got ${result.pcm.size}"
    }
    playIfPossible(out)
    println("ok")
}
