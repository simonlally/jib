import Foundation
import Testing
@testable import Jib

struct FrameCipherTests {
    @Test func encryptMatchesReferenceVector() {
        // Produced by the original Ruby script for the same input.
        let plaintext = Data(#"{"system":{"get_sysinfo":{}}}"#.utf8)
        let hex = FrameCipher.encrypt(plaintext).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf08bf68bf6")
    }

    @Test func decryptInvertsEncrypt() {
        let original = Data(#"{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"on_off":1,"brightness":42}}}"#.utf8)
        #expect(FrameCipher.decrypt(FrameCipher.encrypt(original)) == original)
    }

    @Test func emptyInput() {
        #expect(FrameCipher.encrypt(Data()).isEmpty)
        #expect(FrameCipher.decrypt(Data()).isEmpty)
    }

    @Test func lengthPrefixIsBigEndian() {
        #expect(UInt32(0x0102_0304).bigEndianBytes == Data([1, 2, 3, 4]))
        #expect(UInt32(bigEndianBytes: Data([0, 0, 1, 44])) == 300)
    }
}
