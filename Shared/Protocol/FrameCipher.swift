import Foundation

/// The "autokey XOR" obfuscation used by these bulbs on TCP port 9999.
/// Each byte is XORed with the previous *ciphertext* byte, seeded with 171.
enum FrameCipher {
    static let initialKey: UInt8 = 171

    static func encrypt(_ plaintext: Data) -> Data {
        var key = initialKey
        var out = Data(capacity: plaintext.count)
        for byte in plaintext {
            key ^= byte
            out.append(key)
        }
        return out
    }

    static func decrypt(_ ciphertext: Data) -> Data {
        var key = initialKey
        var out = Data(capacity: ciphertext.count)
        for byte in ciphertext {
            out.append(key ^ byte)
            key = byte
        }
        return out
    }
}
