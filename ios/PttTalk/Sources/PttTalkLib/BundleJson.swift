import Foundation

struct PreKeyBundleJson: Codable {
    var aci: String
    var deviceId: Int
    var registrationId: Int
    var identityKey: String
    var signedPreKeyId: Int
    var signedPreKey: String
    var signedPreKeySig: String
    var preKeyId: Int?
    var preKey: String?
    var kyberPreKeyId: Int
    var kyberPreKey: String
    var kyberPreKeySig: String
}

enum BundleJson {
    static func encode(_ b: PreKeyBundleJson) throws -> Data {
        let encoder = JSONEncoder()
        // Kotlin BundleJson is a regex parser; escaped slashes (`\/`) break Base64.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(b)
    }

    static func decode(_ data: Data) throws -> PreKeyBundleJson {
        try JSONDecoder().decode(PreKeyBundleJson.self, from: data)
    }

    static func b64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    static func unb64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else { throw TalkError("bad b64") }
        return d
    }
}
