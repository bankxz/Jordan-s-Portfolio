import Foundation
import Testing
@testable import PeakKit

struct PushPayloadTests {
    @Test func tokensAreLowercaseHex() {
        #expect(PushPayload.hex(Data([0x00, 0xAB, 0x10, 0xff])) == "00ab10ff")
    }

    @Test func onlyPeakRoutesAreOpened() {
        #expect(PushPayload.route(from: ["url": "peakstats://game/920587237"])?.absoluteString == "peakstats://game/920587237")
        #expect(PushPayload.route(from: ["url": "https://evil.example/phish"]) == nil)
        #expect(PushPayload.route(from: ["url": 42]) == nil)
        #expect(PushPayload.route(from: [:]) == nil)
    }

    @Test func deviceBodyTimeZoneIsOptionalOnTheWire() throws {
        let old = #"{"apnsToken":"ab","sandbox":true}"#
        let decoded = try JSONCoding.makeDecoder().decode(BackendAPI.DeviceBody.self, from: Data(old.utf8))
        #expect(decoded.timeZone == nil)
    }
}
