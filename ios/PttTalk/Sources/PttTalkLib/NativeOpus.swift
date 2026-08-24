import Foundation

@_silgen_name("ptt_opus_samples_per_frame")
private func nativeSamplesPerFrame() -> Int
@_silgen_name("ptt_opus_max_packet_bytes")
private func nativeMaxPacketBytes() -> Int
@_silgen_name("ptt_opus_encoder_create")
private func nativeEncoderCreate() -> OpaquePointer?
@_silgen_name("ptt_opus_encoder_encode")
private func nativeEncoderEncode(
    _ handle: OpaquePointer?, _ pcm: UnsafePointer<Int16>?, _ pcmCount: Int,
    _ output: UnsafeMutablePointer<UInt8>?, _ outputCapacity: Int
) -> Int32
@_silgen_name("ptt_opus_encoder_destroy")
private func nativeEncoderDestroy(_ handle: OpaquePointer?)
@_silgen_name("ptt_opus_decoder_create")
private func nativeDecoderCreate() -> OpaquePointer?
@_silgen_name("ptt_opus_decoder_decode")
private func nativeDecoderDecode(
    _ handle: OpaquePointer?, _ packet: UnsafePointer<UInt8>?, _ packetCount: Int,
    _ output: UnsafeMutablePointer<Int16>?, _ outputCapacity: Int
) -> Int32
@_silgen_name("ptt_opus_decoder_destroy")
private func nativeDecoderDestroy(_ handle: OpaquePointer?)

public let voiceSampleRate = 48_000.0
public let voiceSamplesPerFrame = 960

public final class NativeOpusEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init() throws {
        guard nativeSamplesPerFrame() == voiceSamplesPerFrame,
              nativeMaxPacketBytes() == 98,
              let created = nativeEncoderCreate() else { throw NativeOpusError.initializationFailed }
        handle = created
    }

    public func encode(_ pcm: [Int16]) throws -> Data {
        guard pcm.count == voiceSamplesPerFrame else { throw NativeOpusError.invalidPcmFrame }
        return try lock.withLock {
            guard let handle else { throw NativeOpusError.closed }
            var output = [UInt8](repeating: 0, count: 98)
            let count = pcm.withUnsafeBufferPointer { samples in
                output.withUnsafeMutableBufferPointer { bytes in
                    nativeEncoderEncode(handle, samples.baseAddress, samples.count, bytes.baseAddress, bytes.count)
                }
            }
            guard count > 0, count <= output.count else { throw NativeOpusError.codecFailure(count) }
            return Data(output.prefix(Int(count)))
        }
    }

    public func close() {
        lock.withLock {
            if let handle { nativeEncoderDestroy(handle) }
            handle = nil
        }
    }

    deinit { close() }
}

public final class NativeOpusDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?

    public init() throws {
        guard nativeSamplesPerFrame() == voiceSamplesPerFrame,
              let created = nativeDecoderCreate() else { throw NativeOpusError.initializationFailed }
        handle = created
    }

    public func decode(_ packet: Data?) throws -> [Int16] {
        if let packet, packet.isEmpty || packet.count > 98 { throw NativeOpusError.invalidPacket }
        return try lock.withLock {
            guard let handle else { throw NativeOpusError.closed }
            var output = [Int16](repeating: 0, count: voiceSamplesPerFrame)
            let count: Int32
            if let packet {
                count = packet.withUnsafeBytes { bytes in
                    output.withUnsafeMutableBufferPointer { samples in
                        nativeDecoderDecode(
                            handle,
                            bytes.bindMemory(to: UInt8.self).baseAddress,
                            packet.count,
                            samples.baseAddress,
                            samples.count
                        )
                    }
                }
            } else {
                count = output.withUnsafeMutableBufferPointer { samples in
                    nativeDecoderDecode(handle, nil, 0, samples.baseAddress, samples.count)
                }
            }
            guard count == voiceSamplesPerFrame else { throw NativeOpusError.codecFailure(count) }
            return output
        }
    }

    public func close() {
        lock.withLock {
            if let handle { nativeDecoderDestroy(handle) }
            handle = nil
        }
    }

    deinit { close() }
}

public enum NativeOpusError: Error, Equatable {
    case initializationFailed
    case invalidPcmFrame
    case invalidPacket
    case codecFailure(Int32)
    case closed
}
