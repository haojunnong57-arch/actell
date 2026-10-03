import XCTest
import CryptoKit
@testable import PhoneAgent

final class ProtocolTests: XCTestCase {
    func testFrameLengthIsBigEndianAndBounded() throws {
        XCTAssertEqual(try Wire.length(Data([0, 0, 1, 0])), 256)
        XCTAssertEqual(try Wire.length(Data([0, 1, 0, 0])), 65_536)
        XCTAssertThrowsError(try Wire.length(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try Wire.length(Data([0, 1, 0, 1])))
        XCTAssertThrowsError(try Wire.length(Data([0, 0, 0])))
    }
    func testEnvelopeRoundTrip() throws {
        let e = Envelope(session: "s", request: "r", type: "hello", payload: ["n": .int(1), "b": .bool(true)])
        let frame = try Wire.encode(e)
        XCTAssertEqual(try Wire.length(Data(frame.prefix(4))), frame.count - 4)
        let decoded = try JSONDecoder().decode(Envelope.self, from: frame.dropFirst(4))
        XCTAssertEqual(decoded.session_id, "s"); XCTAssertEqual(decoded.payload["n"], .int(1))
        XCTAssertEqual(decoded.payload["b"], .bool(true))
    }
    func testPixelEndpointsAndBounds() throws {
        XCTAssertEqual(try Wire.normalized(pixel: 0, dimension: 1179), 0)
        XCTAssertEqual(try Wire.normalized(pixel: 1178, dimension: 1179), 65_535)
        XCTAssertThrowsError(try Wire.normalized(pixel: 1179, dimension: 1179))
        XCTAssertThrowsError(try Wire.normalized(pixel: -1, dimension: 1179))
        XCTAssertThrowsError(try Wire.normalized(pixel: 0, dimension: 1))
    }
    func testNoUncommittedImage() throws {
        var a = ImageAssembler()
        try a.begin(["image_id": .string("image"), "mime_type": .string("image/png"), "max_bytes": .int(100)], limit: 100)
        XCTAssertThrowsError(try a.committed(imageID: "image"))
    }
    func testRejectOutOfOrderOrOversizedChunk() throws {
        var a = ImageAssembler()
        try a.begin(["image_id": .string("image"), "mime_type": .string("image/png"), "max_bytes": .int(1)], limit: 1)
        XCTAssertThrowsError(try a.chunk(["image_id": .string("image"), "sequence": .int(1), "offset": .int(0), "data_base64": .string("YQ==")]))
        XCTAssertThrowsError(try a.chunk(["image_id": .string("image"), "sequence": .int(0), "offset": .int(0), "data_base64": .string("YWI=")]))
    }
    func testRejectBadHashAndWrongImageID() throws {
        var a = ImageAssembler()
        try a.begin(["image_id": .string("a"), "mime_type": .string("image/png"), "max_bytes": .int(100)], limit: 100)
        XCTAssertThrowsError(try a.chunk(["image_id": .string("b"), "sequence": .int(0), "offset": .int(0), "data_base64": .string("YQ==")]))
        try a.chunk(["image_id": .string("a"), "sequence": .int(0), "offset": .int(0), "data_base64": .string("YQ==")])
        XCTAssertThrowsError(try a.end(["image_id": .string("a"), "total_bytes": .int(1), "sha256": .string("bad"), "width": .int(2), "height": .int(2)]))
    }
    func testEndpointRejectsCredentialsHTTPAndQueries() throws {
        for url in ["http://example.com/v1", "https://name:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment"] {
            XCTAssertThrowsError(try ProviderSettings(baseURL: url, model: "vision").validatedURL())
        }
        XCTAssertEqual(try ProviderSettings(baseURL: "https://example.com/v1", model: "vision").validatedURL().host, "example.com")
        XCTAssertThrowsError(try ProviderSettings(baseURL: "https://example.com/v1", model: " ").validatedURL())
    }
}
