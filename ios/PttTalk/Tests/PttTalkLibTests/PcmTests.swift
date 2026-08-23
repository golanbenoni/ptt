import Foundation
import XCTest
@testable import PttTalkLib

final class PcmTests: XCTestCase {
    func testGeneratedToneMatchesPlaybackFormat() {
        var pcm = Data()
        for frame in 0..<20 {
            pcm.append(Pcm.sineFrame(index: frame))
        }

        XCTAssertEqual(Pcm.frameBytes, 640)
        XCTAssertEqual(pcm.count, 12_800)
        XCTAssertGreaterThan(Pcm.energy(pcm), 50_000)
    }
}
