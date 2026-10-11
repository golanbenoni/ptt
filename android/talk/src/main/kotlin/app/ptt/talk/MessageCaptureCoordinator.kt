package app.ptt.talk

/** Process-wide exclusion also covers service/hardware PTT, not only screen buttons. */
internal object MessageCaptureCoordinator {
    private var noteOwner: Any? = null
    private var stopNote: (() -> Unit)? = null
    private var ptt = false

    @Synchronized fun beginNote(owner: Any, callActive: Boolean, stop: () -> Unit): Boolean {
        if (ptt || noteOwner != null || callActive) return false
        noteOwner = owner
        stopNote = stop
        return true
    }

    @Synchronized fun endNote(owner: Any) {
        if (noteOwner === owner) { noteOwner = null; stopNote = null }
    }

    @Synchronized fun beginPtt(callActive: Boolean): Boolean {
        if (noteOwner != null || ptt || callActive) return false
        ptt = true
        return true
    }

    @Synchronized fun endPtt() { ptt = false }

    /** Called on the main thread before call/SOS capture starts; preserves the recording. */
    fun interruptNote() {
        val stop = synchronized(this) { stopNote }
        stop?.invoke()
    }
}
