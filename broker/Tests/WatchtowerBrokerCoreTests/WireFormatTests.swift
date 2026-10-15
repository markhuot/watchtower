import XCTest
@testable import WatchtowerBrokerCore

final class WireFormatTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let payload = Data("hello".utf8)
        let frame = Frame(type: .hello, payload: payload)
        let encoded = frame.encode()

        let parser = FrameParser()
        parser.feed(encoded)
        let decoded = try parser.nextFrame()
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.type, .hello)
        XCTAssertEqual(decoded?.payload, payload)
        XCTAssertNil(try parser.nextFrame())
    }

    func testMultipleFrames() throws {
        let f1 = Frame(type: .listPanes, payload: Data())
        let f2 = Frame(type: .openPane, payload: Data([1, 2, 3]))
        let parser = FrameParser()
        parser.feed(f1.encode() + f2.encode())
        let d1 = try parser.nextFrame()
        let d2 = try parser.nextFrame()
        XCTAssertEqual(d1?.type, .listPanes)
        XCTAssertEqual(d2?.type, .openPane)
        XCTAssertEqual(d2?.payload, Data([1, 2, 3]))
    }

    func testPartialFeed() throws {
        let f = Frame(type: .input, payload: Data("xyz".utf8))
        let bytes = f.encode()
        let parser = FrameParser()
        parser.feed(bytes.prefix(3))
        XCTAssertNil(try parser.nextFrame())
        parser.feed(bytes.dropFirst(3))
        let out = try parser.nextFrame()
        XCTAssertEqual(out?.type, .input)
        XCTAssertEqual(out?.payload, Data("xyz".utf8))
    }

    func testDataFrameSplit() throws {
        let id = UUID()
        let body = Data("payload".utf8)
        let frame = WireCoder.dataFrame(type: .output, paneId: id, bytes: body)
        let split = WireCoder.splitDataFrame(frame)
        XCTAssertNotNil(split)
        XCTAssertEqual(split?.0, id)
        XCTAssertEqual(split?.1, body)
    }
}

final class RingBufferTests: XCTestCase {
    func testSmallAppendsAndSnapshot() {
        let r = RingBuffer(capacity: 8)
        r.append([1, 2, 3])
        XCTAssertEqual(r.snapshot(), [1, 2, 3])
    }

    func testEvictionOnOverflow() {
        let r = RingBuffer(capacity: 4)
        r.append([1, 2, 3, 4])
        XCTAssertEqual(r.snapshot(), [1, 2, 3, 4])
        r.append([5, 6])
        XCTAssertEqual(r.snapshot(), [3, 4, 5, 6])
    }

    func testOversizedAppendKeepsTrailing() {
        let r = RingBuffer(capacity: 3)
        r.append([1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(r.snapshot(), [5, 6, 7])
    }

    func testJSONMessageRoundTrip() throws {
        let m = AttachMessage(paneId: UUID().uuidString, replayScrollback: true)
        let frame = try WireCoder.encode(m, type: .attach)
        let parsed = try WireCoder.decode(frame, as: AttachMessage.self)
        XCTAssertEqual(parsed.paneId, m.paneId)
        XCTAssertEqual(parsed.replayScrollback, m.replayScrollback)
    }
}
