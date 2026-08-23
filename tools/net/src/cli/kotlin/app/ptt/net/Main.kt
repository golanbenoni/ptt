package app.ptt.net

import java.io.File

fun main(args: Array<String>) {
    if (args.isEmpty()) {
        System.err.println("usage: net prekey [--port N] | relay [--port N] | send | recv [--out wav]")
        kotlin.system.exitProcess(2)
    }
    fun flag(name: String, default: String): String {
        val idx = args.indexOf(name)
        return if (idx >= 0 && idx + 1 < args.size) args[idx + 1] else default
    }
    when (args[0]) {
        "prekey" -> {
            val port = flag("--port", "8088").toInt()
            val bind = flag("--bind", "127.0.0.1")
            val s = PrekeyServer(port, bind)
            println("prekey ${s.baseUrl}")
            Thread.currentThread().join()
        }
        "relay" -> {
            val port = flag("--port", "47000").toInt()
            val bind = flag("--bind", "127.0.0.1")
            val s = RelayServer(port, bind)
            println("relay $bind:${s.port}")
            Thread.currentThread().join()
        }
        "send" -> {
            val prekey = flag("--prekey", "http://127.0.0.1:8088")
            val relay = flag("--relay", "127.0.0.1:47000")
            val (host, port) = relay.split(":")
            val n =
                TalkClient(DemoIds.ALICE, DemoIds.BOB, prekey, host, port.toInt())
                    .sendTone(
                        durationMs = flag("--ms", "800").toInt(),
                        paceMs = flag("--pace-ms", "0").toLong(),
                        bindWaitMs = flag("--bind-wait-ms", "80").toLong(),
                    )
            println("sent $n frames")
        }
        "recv" -> {
            val prekey = flag("--prekey", "http://127.0.0.1:8088")
            val relay = flag("--relay", "127.0.0.1:47000")
            val out = File(flag("--out", "build/ptt-bob.wav"))
            val (host, port) = relay.split(":")
            val r =
                TalkClient(DemoIds.BOB, DemoIds.ALICE, prekey, host, port.toInt())
                    .recvTone(outWav = out)
            println("recv frames=${r.frames} energy=${r.energy} wav=${out.absolutePath}")
            check(r.energy > 50_000) { "silence energy=${r.energy}" }
        }
        else -> error("unknown ${args[0]}")
    }
}
