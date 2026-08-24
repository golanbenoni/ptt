package app.ptt.media

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

const val SFRAME_AES_128_GCM_SHA256_128: Int = 0x0004

interface SFrameCounterStore {
    /** Persists and returns an unused counter before any ciphertext is emitted. */
    fun takeNext(kid: ULong): ULong
}

class MemorySFrameCounterStore : SFrameCounterStore {
    private val next = mutableMapOf<ULong, ULong>()

    @Synchronized
    override fun takeNext(kid: ULong): ULong {
        val value = next[kid] ?: 0uL
        check(value != ULong.MAX_VALUE) { "SFrame counter exhausted" }
        next[kid] = value + 1u
        return value
    }
}

class SFrameEncryptor(
    private val kid: ULong,
    baseKey: ByteArray,
    private val counters: SFrameCounterStore,
) {
    private val key: ByteArray
    private val salt: ByteArray

    init {
        require(baseKey.isNotEmpty()) { "invalid SFrame base key" }
        key = derive(baseKey, label("SFrame 1.0 Secret key ", kid), 16)
        salt = derive(baseKey, label("SFrame 1.0 Secret salt ", kid), 12)
    }

    fun encrypt(metadata: ByteArray, plaintext: ByteArray): ByteArray =
        encryptWithCounter(counters.takeNext(kid), metadata, plaintext)

    internal fun encryptWithCounter(
        counter: ULong,
        metadata: ByteArray,
        plaintext: ByteArray,
    ): ByteArray {
        val header = SFrameHeader.encode(kid, counter)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.ENCRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, nonce(salt, counter)),
        )
        cipher.updateAAD(header + metadata)
        return header + cipher.doFinal(plaintext)
    }
}

class SFrameDecryptor {
    private data class KeyMaterial(val key: ByteArray, val salt: ByteArray)

    private val keys = mutableMapOf<ULong, KeyMaterial>()
    private val replay = mutableMapOf<ULong, ReplayWindow>()

    @Synchronized
    fun addKey(kid: ULong, baseKey: ByteArray) {
        require(baseKey.isNotEmpty()) { "invalid SFrame base key" }
        keys[kid] =
            KeyMaterial(
                derive(baseKey, label("SFrame 1.0 Secret key ", kid), 16),
                derive(baseKey, label("SFrame 1.0 Secret salt ", kid), 12),
            )
        replay.remove(kid)
    }

    @Synchronized
    fun removeKey(kid: ULong) {
        keys.remove(kid)
        replay.remove(kid)
    }

    @Synchronized
    fun decrypt(metadata: ByteArray, frame: ByteArray): ByteArray {
        val parsed = SFrameHeader.parse(frame)
        val material = keys[parsed.kid] ?: throw SFrameException.UnknownKey
        val window = replay.getOrPut(parsed.kid) { ReplayWindow() }
        if (!window.acceptable(parsed.counter)) throw SFrameException.Replay
        if (frame.size < parsed.length + 16) throw SFrameException.MalformedHeader
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(material.key, "AES"),
            GCMParameterSpec(128, nonce(material.salt, parsed.counter)),
        )
        cipher.updateAAD(frame.copyOfRange(0, parsed.length) + metadata)
        val plaintext =
            try {
                cipher.doFinal(frame, parsed.length, frame.size - parsed.length)
            } catch (error: Exception) {
                throw SFrameException.AuthenticationFailed(error)
            }
        window.mark(parsed.counter)
        return plaintext
    }
}

sealed class SFrameException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    data object MalformedHeader : SFrameException("malformed or non-canonical SFrame header")
    data object UnknownKey : SFrameException("SFrame key is not available")
    data object Replay : SFrameException("SFrame counter was replayed or is outside the replay window")
    class AuthenticationFailed(cause: Throwable) : SFrameException("SFrame authentication failed", cause)
}

private data class ParsedSFrameHeader(val kid: ULong, val counter: ULong, val length: Int)

private object SFrameHeader {
    fun encode(kid: ULong, counter: ULong): ByteArray {
        val kidBytes = compact(kid)
        val counterBytes = compact(counter)
        val kidExtended = kid >= 8u
        val counterExtended = counter >= 8u
        var config = 0
        config =
            if (kidExtended) config or 0x80 or ((kidBytes.size - 1) shl 4)
            else config or (kid.toInt() shl 4)
        config =
            if (counterExtended) config or 0x08 or (counterBytes.size - 1)
            else config or counter.toInt()
        val output = ByteArrayOutputStream(17)
        output.write(config)
        if (kidExtended) output.write(kidBytes)
        if (counterExtended) output.write(counterBytes)
        return output.toByteArray()
    }

    fun parse(frame: ByteArray): ParsedSFrameHeader {
        if (frame.isEmpty()) throw SFrameException.MalformedHeader
        val config = frame[0].toInt() and 0xff
        val kidExtended = config and 0x80 != 0
        val counterExtended = config and 0x08 != 0
        val kidLength = if (kidExtended) ((config ushr 4) and 0x07) + 1 else 0
        val counterLength = if (counterExtended) (config and 0x07) + 1 else 0
        val length = 1 + kidLength + counterLength
        if (frame.size < length) throw SFrameException.MalformedHeader
        var offset = 1
        val kid =
            if (kidExtended) decode(frame, offset, kidLength).also { offset += kidLength }
            else ((config ushr 4) and 0x07).toULong()
        val counter =
            if (counterExtended) decode(frame, offset, counterLength)
            else (config and 0x07).toULong()
        if ((kidExtended && kid < 8u) || (counterExtended && counter < 8u)) {
            throw SFrameException.MalformedHeader
        }
        return ParsedSFrameHeader(kid, counter, length)
    }

    private fun compact(value: ULong): ByteArray {
        val bytes = ByteBuffer.allocate(8).putLong(value.toLong()).array()
        val first = bytes.indexOfFirst { it.toInt() != 0 }.let { if (it == -1) 7 else it }
        return bytes.copyOfRange(first, 8)
    }

    private fun decode(bytes: ByteArray, offset: Int, length: Int): ULong {
        if (length !in 1..8 || (length > 1 && bytes[offset].toInt() == 0)) {
            throw SFrameException.MalformedHeader
        }
        var result = 0uL
        repeat(length) { result = (result shl 8) or (bytes[offset + it].toUByte().toULong()) }
        return result
    }
}

private class ReplayWindow {
    private var initialized = false
    private var highest = 0uL
    private var low = 0uL
    private var high = 0uL

    fun acceptable(counter: ULong): Boolean {
        if (!initialized || counter > highest) return true
        val distance = highest - counter
        if (distance >= 128u) return false
        val bit = distance.toInt()
        return if (bit < 64) low and (1uL shl bit) == 0uL
        else high and (1uL shl (bit - 64)) == 0uL
    }

    fun mark(counter: ULong) {
        if (!initialized) {
            initialized = true
            highest = counter
            low = 1u
            return
        }
        if (counter > highest) {
            val distance = counter - highest
            when {
                distance >= 128u -> {
                    low = 1u
                    high = 0u
                }
                distance >= 64u -> {
                    high = low shl (distance.toInt() - 64)
                    low = 1u
                }
                else -> {
                    val shift = distance.toInt()
                    high = (high shl shift) or (low shr (64 - shift))
                    low = (low shl shift) or 1u
                }
            }
            highest = counter
        } else {
            val distance = (highest - counter).toInt()
            if (distance < 64) low = low or (1uL shl distance)
            else high = high or (1uL shl (distance - 64))
        }
    }
}

private fun label(prefix: String, kid: ULong): ByteArray =
    prefix.encodeToByteArray() +
        ByteBuffer.allocate(8).putLong(kid.toLong()).array() +
        byteArrayOf(0, SFRAME_AES_128_GCM_SHA256_128.toByte())

private fun derive(baseKey: ByteArray, info: ByteArray, length: Int): ByteArray {
    val extract = Mac.getInstance("HmacSHA256")
    extract.init(SecretKeySpec(ByteArray(32), "HmacSHA256"))
    val pseudoRandomKey = extract.doFinal(baseKey)
    val expand = Mac.getInstance("HmacSHA256")
    expand.init(SecretKeySpec(pseudoRandomKey, "HmacSHA256"))
    expand.update(info)
    expand.update(1)
    return expand.doFinal().copyOf(length)
}

private fun nonce(salt: ByteArray, counter: ULong): ByteArray {
    val result = salt.copyOf()
    val counterBytes = ByteBuffer.allocate(8).putLong(counter.toLong()).array()
    for (index in counterBytes.indices) {
        result[result.size - 8 + index] =
            (result[result.size - 8 + index].toInt() xor counterBytes[index].toInt()).toByte()
    }
    return result
}
