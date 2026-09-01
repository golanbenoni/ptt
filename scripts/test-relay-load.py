#!/usr/bin/env python3
"""Exercise the native UDP relay with its full 256-listener channel capacity."""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
import selectors
import socket
import struct
import time
import uuid


LISTENERS = 256
MEDIA_BYTES = 160
HMAC_BYTES = 8
BIND_MAGIC = b"PTTB"
ACK_MAGIC = b"PTTA"


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def relay_ticket(
    secret: bytes,
    channel_id: uuid.UUID,
    aci: uuid.UUID,
    device_id: int,
    sender_demux: int,
    expires_unix: int,
    demux_token: bytes,
) -> str:
    payload = b"".join(
        (
            b"\x01",
            channel_id.bytes,
            aci.bytes,
            struct.pack(">I", device_id),
            struct.pack(">I", sender_demux),
            struct.pack(">q", expires_unix),
            demux_token,
        )
    )
    if len(payload) != 81:
        raise AssertionError("relay ticket payload length drifted")
    tag = hmac.new(secret, payload, hashlib.sha256).digest()
    return base64.urlsafe_b64encode(payload + tag).decode("ascii").rstrip("=")


def bind_listener(
    relay: tuple[str, int],
    ticket: str,
    sender_demux: int,
) -> socket.socket:
    client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    client.bind(("127.0.0.1", 0))
    client.settimeout(1.0)
    expected = ACK_MAGIC + struct.pack(">I", sender_demux)
    for _ in range(3):
        client.sendto(BIND_MAGIC + ticket.encode("ascii"), relay)
        try:
            received, source = client.recvfrom(64)
        except TimeoutError:
            continue
        if source == relay and received == expected:
            client.setblocking(False)
            return client
    client.close()
    raise AssertionError(f"relay did not acknowledge listener demux {sender_demux}")


def redis_command(host: str, port: int, *parts: str) -> bytes:
    encoded = [part.encode("utf-8") for part in parts]
    request = [f"*{len(encoded)}\r\n".encode("ascii")]
    for part in encoded:
        request.extend((f"${len(part)}\r\n".encode("ascii"), part, b"\r\n"))
    with socket.create_connection((host, port), timeout=2.0) as connection:
        connection.sendall(b"".join(request))
        response = connection.recv(4096)
    if not response or response[:1] == b"-":
        raise AssertionError(f"Redis command failed: {response!r}")
    return response


def signed_media(sender_demux: int, demux_token: bytes) -> bytes:
    packet = bytearray(MEDIA_BYTES)
    packet[0] = 1
    packet[1] = 0x08
    packet[2:6] = struct.pack(">I", sender_demux)
    packet[6:10] = struct.pack(">I", 1)
    packet[10:14] = struct.pack(">I", 960)
    packet[14:18] = b"LOAD"
    packet[-HMAC_BYTES:] = hmac.new(
        demux_token, packet[:-HMAC_BYTES], hashlib.sha256
    ).digest()[:HMAC_BYTES]
    return bytes(packet)


def main() -> None:
    relay_host = os.environ.get("PTT_RELAY_LOAD_HOST", "127.0.0.1")
    relay_port = int(required("PTT_RELAY_LOAD_PORT"))
    redis_host = os.environ.get("PTT_RELAY_LOAD_REDIS_HOST", "127.0.0.1")
    redis_port = int(required("PTT_RELAY_LOAD_REDIS_PORT"))
    secret = required("PTT_RELAY_SHARED_SECRET").encode("utf-8")
    if len(secret) < 32:
        raise RuntimeError("PTT_RELAY_SHARED_SECRET must be at least 32 bytes")

    relay = (relay_host, relay_port)
    channel_id = uuid.uuid4()
    expires_unix = int(time.time()) + 120
    clients: list[socket.socket] = []
    identities: list[tuple[uuid.UUID, int, bytes]] = []
    try:
        for index in range(LISTENERS):
            aci = uuid.uuid4()
            sender_demux = index + 1
            demux_token = hashlib.sha256(f"ptt-load-{index}".encode("ascii")).digest()
            ticket = relay_ticket(
                secret,
                channel_id,
                aci,
                1,
                sender_demux,
                expires_unix,
                demux_token,
            )
            clients.append(bind_listener(relay, ticket, sender_demux))
            identities.append((aci, sender_demux, demux_token))

        overflow_token = hashlib.sha256(b"ptt-load-overflow").digest()
        overflow_ticket = relay_ticket(
            secret,
            channel_id,
            uuid.uuid4(),
            1,
            LISTENERS + 1,
            expires_unix,
            overflow_token,
        )
        overflow = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        overflow.settimeout(0.4)
        try:
            overflow.sendto(BIND_MAGIC + overflow_ticket.encode("ascii"), relay)
            try:
                overflow.recvfrom(64)
            except TimeoutError:
                pass
            else:
                raise AssertionError("relay acknowledged listener 257")
        finally:
            overflow.close()

        sender_aci, sender_demux, sender_token = identities[0]
        floor_key = f"ptt:v1:floor:{channel_id}"
        redis_command(
            redis_host,
            redis_port,
            "HSET",
            floor_key,
            "owner",
            f"{sender_aci}:1",
            "demux",
            str(sender_demux),
        )
        redis_command(redis_host, redis_port, "EXPIRE", floor_key, "30")

        expected = signed_media(sender_demux, sender_token)
        selector = selectors.DefaultSelector()
        for index, client in enumerate(clients[1:], start=1):
            selector.register(client, selectors.EVENT_READ, index)
        clients[0].sendto(expected, relay)

        received: set[int] = set()
        deadline = time.monotonic() + 10.0
        while len(received) < LISTENERS - 1 and time.monotonic() < deadline:
            for key, _ in selector.select(max(0.0, deadline - time.monotonic())):
                packet, source = key.fileobj.recvfrom(MEDIA_BYTES + 1)
                if source != relay or packet != expected:
                    raise AssertionError("relay altered or misrouted an authenticated frame")
                received.add(key.data)
                selector.unregister(key.fileobj)

        if len(received) != LISTENERS - 1:
            missing = LISTENERS - 1 - len(received)
            raise AssertionError(f"{missing} of 255 listeners missed the fan-out frame")
        print("Native UDP relay delivered one authenticated frame to 255 listeners and rejected listener 257")
    finally:
        for client in clients:
            client.close()


if __name__ == "__main__":
    main()
