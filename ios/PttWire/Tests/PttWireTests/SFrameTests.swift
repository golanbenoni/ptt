import XCTest
@testable import PttWire

final class SFrameTests: XCTestCase {
    func testRfc9605Aes128GcmVectorMatchesKotlinAndRust() throws {
        let key = data("000102030405060708090a0b0c0d0e0f")
        let metadata = data("4945544620534672616d65205747")
        let plaintext = data("64726166742d696574662d736672616d652d656e63")
        let encryptor = try SFrameEncryptor(
            kid: 0x0123,
            baseKey: key,
            counters: MemorySFrameCounterStore()
        )
        let frame = try encryptor.encrypt(counter: 0x4567, metadata: metadata, plaintext: plaintext)
        XCTAssertEqual(
            hex(frame),
            "9901234567b7412c2513a1b66dbb48841bbaf17f598751176ad847681a69c6d0b091c07018ce4adb34eb"
        )
        let decryptor = SFrameDecryptor()
        try decryptor.addKey(kid: 0x0123, baseKey: key)
        XCTAssertEqual(try decryptor.decrypt(metadata: metadata, frame: frame), plaintext)
    }

    func testAuthenticationFailureDoesNotConsumeReplaySlot() throws {
        let key = Data(repeating: 9, count: 16)
        let encryptor = try SFrameEncryptor(kid: 1, baseKey: key, counters: MemorySFrameCounterStore())
        let frame = try encryptor.encrypt(metadata: Data("aad".utf8), plaintext: Data("voice".utf8))
        let decryptor = SFrameDecryptor()
        try decryptor.addKey(kid: 1, baseKey: key)
        var corrupt = frame
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertThrowsError(try decryptor.decrypt(metadata: Data("aad".utf8), frame: corrupt)) {
            XCTAssertEqual($0 as? SFrameError, .authenticationFailed)
        }
        XCTAssertEqual(
            try decryptor.decrypt(metadata: Data("aad".utf8), frame: frame),
            Data("voice".utf8)
        )
        XCTAssertThrowsError(try decryptor.decrypt(metadata: Data("aad".utf8), frame: frame)) {
            XCTAssertEqual($0 as? SFrameError, .replay)
        }
    }

    private func data(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start..<end], radix: 16)!
        })
    }

    private func hex(_ value: Data) -> String {
        value.map { String(format: "%02x", $0) }.joined()
    }
}
