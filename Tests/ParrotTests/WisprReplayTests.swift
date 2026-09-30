import XCTest
@testable import ParrotCore

final class WisprReplayTests: XCTestCase {
    /// A WAV file: RIFF header, a fmt chunk, then the samples.
    private func wav(samples: [Int16], rate: Int = 16_000, channels: Int = 1, bits: Int = 16, extraChunk: Bool = false) -> Data {
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        var body: [UInt8] = Array("WAVE".utf8)
        body += Array("fmt ".utf8) + le32(16) + le16(1) + le16(channels) + le32(rate) + le32(rate * channels * bits / 8) + le16(channels * bits / 8) + le16(bits)
        if extraChunk { body += Array("LIST".utf8) + le32(3) + [1, 2, 3, 0] }
        let data = samples.flatMap { le16(Int(UInt16(bitPattern: $0))) }
        body += Array("data".utf8) + le32(data.count) + data
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    func testDecodesSixteenBitMonoAtSixteenKilohertz() throws {
        let samples = try XCTUnwrap(WisprReplay.decodeWAV(wav(samples: [0, 16_384, -32_768], extraChunk: true)))
        XCTAssertEqual(samples, [0, 0.5, -1])
    }

    func testRefusesOtherFormats() {
        XCTAssertNil(WisprReplay.decodeWAV(wav(samples: [0, 1], rate: 44_100)))
        XCTAssertNil(WisprReplay.decodeWAV(wav(samples: [0, 1], channels: 2)))
        XCTAssertNil(WisprReplay.decodeWAV(Data("not a wav file at all".utf8)))
    }

    func testWordErrors() {
        XCTAssertEqual(WisprReplay.wordErrors(["a", "b", "c"], ["a", "x", "c", "d"]), 2)
        XCTAssertEqual(WisprReplay.wordErrors([], ["a"]), 1)
        XCTAssertEqual(WisprReplay.wordErrors(["a"], []), 1)
    }

    func testCountsTermsWithTheirCase() {
        let words = ["ping", "the", "Qwilbo", "team", "and", "qwilbo", "Zor", "Blink"]
        XCTAssertEqual(WisprReplay.count(["Qwilbo"], in: words), 1)
        XCTAssertEqual(WisprReplay.count(["Zor", "Blink"], in: words), 1)
        XCTAssertEqual(WisprReplay.count(["Missing"], in: words), 0)
    }
}
