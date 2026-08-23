import Foundation

public enum Pcm {
    public static let sampleRate = 16_000
    public static let frameMs = 20
    public static let samplesPerFrame = sampleRate * frameMs / 1000
    public static let frameBytes = samplesPerFrame * 2

    static func sineFrame(index: Int, freqHz: Double = 440.0) -> Data {
        var data = Data(count: frameBytes)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            let start = index * samplesPerFrame
            for n in 0..<samplesPerFrame {
                let t = Double(start + n) / Double(sampleRate)
                let s = sin(2.0 * Double.pi * freqHz * t) * 16_000.0
                ptr[n] = Int16(s)
            }
        }
        return data
    }

    static func writeWav(_ pcm: Data, to url: URL) throws {
        var header = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 4))
        }
        func appendU16(_ v: UInt16) {
            var le = v.littleEndian
            header.append(Data(bytes: &le, count: 2))
        }
        header.append(contentsOf: Array("RIFF".utf8))
        appendU32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(1)
        appendU16(1)
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2))
        appendU16(2)
        appendU16(16)
        header.append(contentsOf: Array("data".utf8))
        appendU32(UInt32(pcm.count))
        try (header + pcm).write(to: url)
    }

    static func energy(_ pcm: Data) -> Int64 {
        let bytes = [UInt8](pcm)
        var energy: Int64 = 0
        var i = 0
        while i + 1 < bytes.count {
            let s = Int16(truncatingIfNeeded: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            energy += Int64(abs(Int32(s)))
            i += 2
        }
        return energy
    }
}
