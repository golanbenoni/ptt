package app.ptt.floor

import app.ptt.crypto.Aci
import app.ptt.crypto.ChannelId
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class TalkTarget {
    data class Direct(val aci: Aci) : TalkTarget()
    data class Channel(val id: ChannelId) : TalkTarget()
}

enum class PttMode { HOLD, TOGGLE, VOX }

enum class Priority { NORMAL, BARGE, DISPATCH, SOS }

sealed class FloorState {
    data object Idle : FloorState()

    data class Requesting(val target: TalkTarget, val mode: PttMode) : FloorState()

    data class Granted(
        val target: TalkTarget,
        val talkId: UUID,
        val totDeadlineMs: Long,
        val priority: Priority,
    ) : FloorState()

    data class Receiving(
        val target: TalkTarget,
        val talkId: UUID,
        val talkerSafetyLabel: String,
    ) : FloorState()

    data class Interrupted(val target: TalkTarget, val byPriority: Priority) : FloorState()

    data class Sos(val talkId: UUID, val silent: Boolean, val totDeadlineMs: Long) : FloorState()
}

enum class PeerPresence { AVAILABLE, BUSY, SOLO, OFFLINE }

interface FloorController {
    val state: StateFlow<FloorState>

    fun pttDown(target: TalkTarget, mode: PttMode = PttMode.HOLD)

    fun pttUp(target: TalkTarget)

    fun requestSos(target: TalkTarget, silent: Boolean)

    fun setVoxEnabled(enabled: Boolean)

    /** Loopback / tests: mark a 1:1 peer's presence so auto-grant can fire. */
    fun setDirectPeerPresence(aci: Aci, presence: PeerPresence)
}

/**
 * Local floor machine. 1:1 auto-grants when the peer is not Busy/Solo/Offline (KD-11).
 * Channel grants still need a serializer (PR8); this MVP treats Channel as request-only.
 */
class InMemoryFloorController(
    private val clockMs: () -> Long = { System.currentTimeMillis() },
    private val totMs: Int = 30_000,
) : FloorController {
    private val _state = MutableStateFlow<FloorState>(FloorState.Idle)
    override val state: StateFlow<FloorState> = _state.asStateFlow()

    private val presence = mutableMapOf<Aci, PeerPresence>()
    private var vox = false

    override fun setDirectPeerPresence(aci: Aci, presence: PeerPresence) {
        this.presence[aci] = presence
    }

    override fun setVoxEnabled(enabled: Boolean) {
        vox = enabled
    }

    override fun pttDown(target: TalkTarget, mode: PttMode) {
        when (val now = _state.value) {
            is FloorState.Granted -> return
            is FloorState.Sos -> return
            else -> Unit
        }
        if (target is TalkTarget.Direct) {
            val p = presence[target.aci] ?: PeerPresence.AVAILABLE
            if (p == PeerPresence.BUSY || p == PeerPresence.SOLO || p == PeerPresence.OFFLINE) {
                _state.value = FloorState.Requesting(target, mode)
                return
            }
            grant(target)
            return
        }
        _state.value = FloorState.Requesting(target, mode)
    }

    /** Channel path: apply a local grant after the E2EE FloorDecision is accepted. */
    fun applyChannelGrant(target: TalkTarget.Channel, talkId: UUID, totDeadlineMs: Long) {
        _state.value =
            FloorState.Granted(
                target = target,
                talkId = talkId,
                totDeadlineMs = totDeadlineMs,
                priority = Priority.NORMAL,
            )
    }

    fun beginReceiving(target: TalkTarget, talkId: UUID, talkerSafetyLabel: String) {
        _state.value = FloorState.Receiving(target, talkId, talkerSafetyLabel)
    }

    override fun pttUp(target: TalkTarget) {
        val s = _state.value
        if (s is FloorState.Granted && s.target == target) {
            _state.value = FloorState.Idle
        }
        if (s is FloorState.Requesting && s.target == target) {
            _state.value = FloorState.Idle
        }
    }

    override fun requestSos(target: TalkTarget, silent: Boolean) {
        val talkId = UUID.randomUUID()
        _state.value = FloorState.Sos(talkId, silent, clockMs() + totMs)
    }

    private fun grant(target: TalkTarget) {
        _state.value =
            FloorState.Granted(
                target = target,
                talkId = UUID.randomUUID(),
                totDeadlineMs = clockMs() + totMs,
                priority = Priority.NORMAL,
            )
    }
}
