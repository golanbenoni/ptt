# media relay

`ptt-relay` is the production ciphertext-only UDP fan-out service. It validates
short-lived authenticated binding tickets, pins each sender demux to its source
tuple, supports authenticated rebinding and teardown, rejects injection, and
caps a channel at 256 listeners. It never receives or decrypts SFrame keys.
