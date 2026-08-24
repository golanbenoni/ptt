import Foundation
import Testing
@testable import PttTalkLib

@Test func nativeOpusRoundTripAndPlcProduceExactFrames() throws {
    let encoder = try NativeOpusEncoder()
    let decoder = try NativeOpusDecoder()
    let pcm = (0..<voiceSamplesPerFrame).map { index in
        Int16(sin(Double(index) * 2 * .pi * 440 / voiceSampleRate) * 12_000)
    }
    let packet = try encoder.encode(pcm)
    #expect(!packet.isEmpty && packet.count <= 98)
    #expect(try decoder.decode(packet).count == voiceSamplesPerFrame)
    #expect(try decoder.decode(nil).count == voiceSamplesPerFrame)
}

@Test func nativeOpusRejectsWrongFrameAndUseAfterClose() throws {
    let encoder = try NativeOpusEncoder()
    #expect(throws: NativeOpusError.invalidPcmFrame) { try encoder.encode([1]) }
    encoder.close()
    #expect(throws: NativeOpusError.closed) {
        try encoder.encode([Int16](repeating: 0, count: voiceSamplesPerFrame))
    }
}
