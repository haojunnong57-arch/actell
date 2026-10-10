import XCTest
import ProviderCore
import OpenAIAdapter
@testable import PhoneAgent

private final class WireFixtureState: @unchecked Sendable {
    let lock = NSLock()
    var body = Data(), status = 200, block = false, stopped = 0
    var requests: [URLRequest] = []
    func reset(body: Data = Data(), status: Int = 200, block: Bool = false) { lock.withLock { self.body = body; self.status = status; self.block = block; self.requests = []; self.stopped = 0 } }
}
private final class ProviderURLProtocol: URLProtocol, @unchecked Sendable {
    static let fixture = WireFixtureState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let values = Self.fixture.lock.withLock { Self.fixture.requests.append(request); return (Self.fixture.body, Self.fixture.status, Self.fixture.block) }
        let response = HTTPURLResponse(url: request.url!, statusCode: values.1, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream", "Set-Cookie": "sensitive=fixture"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !values.0.isEmpty { client?.urlProtocol(self, didLoad: values.0) }
        if !values.2 { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.fixture.lock.withLock { Self.fixture.stopped += 1 } }
}
final class ProviderTransportTests: XCTestCase {
    private var request: ModelRequest { .init(model: "fixture", messages: [.system("instructions"), .user("task")]) }
    private func provider() throws -> PrivateVisionProvider {
        try PrivateVisionProvider(settings: .init(baseURL: "https://invalid.invalid/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), inferenceAPI: .responses, transport: ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]))
    }
    private func completed() -> Data {
        Data("{\"id\":\"r1\",\"model\":\"fixture\",\"status\":\"completed\",\"output\":[{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\",\"annotations\":[]}]}]}".utf8)
    }
    func testBothTransportPathsUseEphemeralNoCookieCacheAndExplicitHeaders() throws {
        let t = ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]); defer { t.cancel() }
        let config = t.session.configuration
        XCTAssertNil(config.urlCache); XCTAssertNil(config.httpCookieStorage); XCTAssertFalse(config.httpShouldSetCookies)
        XCTAssertEqual(config.requestCachePolicy, .reloadIgnoringLocalCacheData)
        let p = try provider(); defer { p.cancel() }
        for stream in [true, false] {
            let r = try p.prepareRequest(request, stream: stream)
            XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), stream ? "text/event-stream" : "application/json")
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
        }
    }
    func testCompleteMockAndHTTPErrorDoNotTriggerRegeneration() async throws {
        ProviderURLProtocol.fixture.reset(body: completed())
        let p = try provider(); defer { p.cancel() }
        let r = try await p.complete(request); XCTAssertEqual(r.text, "answer")
        XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        for status in [401, 429, 500, 404] {
            ProviderURLProtocol.fixture.reset(body: Data("SECRET_PAYLOAD".utf8), status: status)
            let failure = try provider(); defer { failure.cancel() }
            do { _ = try await failure.complete(request); XCTFail("HTTP error expected") } catch {
                XCTAssertFalse(error.localizedDescription.contains("SECRET_PAYLOAD"))
            }
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testOpenRouterAccountingFrameCompletesForBothOpenAIAndRouterProfiles() async throws {
        // Official Chat shape: the final usage frame repeats role, empty content
        // and finish_reason, unlike OpenAI's empty choices accounting frame.
        let body = Data("""
        : OPENROUTER PROCESSING

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"answer"},"finish_reason":null}]}

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop","native_finish_reason":"stop"}]}

        data: {"id":"gen-fixture","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"stop","native_finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":5,"total_tokens":17}}

        data: [DONE]


        """.utf8)
        for kind in [ProviderKind.openAI, .openRouter] {
            ProviderURLProtocol.fixture.reset(body: body)
            let p = try PrivateVisionProvider(settings: .init(baseURL: "https://fixture.invalid/api/v1", model: "fixture"), apiKey: "synthetic", limits: .init(), providerKind: kind, transport: ResponsesTransport(protocolClasses: [ProviderURLProtocol.self]))
            defer { p.cancel() }
            var text = "", terminals: [ModelResponse] = []
            for try await event in p.stream(request) {
                switch event {
                case .text(let value): text += value
                case .terminal(let response): terminals.append(response)
                case .toolCall, .finish: XCTFail("Expected one authoritative terminal")
                default: break
                }
            }
            XCTAssertEqual(text, "answer"); XCTAssertEqual(terminals.count, 1)
            XCTAssertEqual(terminals.first?.text, "answer"); XCTAssertEqual(terminals.first?.status, .completed)
            XCTAssertEqual(terminals.first?.usage?.totalTokens, 17)
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testStreamingEOFFailureAndMalformedPayloadCancelUnderlyingTask() async throws {
        for body in [Data("data: {\"type\":\"response.created\",\"sequence_number\":0,\"response\":{\"id\":\"r1\"}}\n\n".utf8), Data("data: INVALID_SECRET_PAYLOAD\n\n".utf8)] {
            ProviderURLProtocol.fixture.reset(body: body, block: false)
            let p = try provider(); defer { p.cancel() }
            do { for try await _ in p.stream(request) {}; XCTFail("No valid terminal") } catch { XCTAssertFalse(error.localizedDescription.contains("SECRET_PAYLOAD")) }
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
        }
    }
    func testCancellationPropagatesForBothOperationsWithoutSecondRequest() async throws {
        for stream in [true, false] {
            ProviderURLProtocol.fixture.reset(block: true)
            let p = try provider()
            let task = Task {
                if stream { for try await _ in p.stream(request) {}; try Task.checkCancellation() } else { _ = try await p.complete(request) }
            }
            for _ in 0..<100 {
                if ProviderURLProtocol.fixture.lock.withLock({ !ProviderURLProtocol.fixture.requests.isEmpty }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            task.cancel(); p.cancel()
            do { try await task.value; XCTFail("Cancellation expected") } catch {}
            XCTAssertEqual(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.requests.count }, 1)
            for _ in 0..<100 {
                if ProviderURLProtocol.fixture.lock.withLock({ ProviderURLProtocol.fixture.stopped > 0 }) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertGreaterThan(ProviderURLProtocol.fixture.lock.withLock { ProviderURLProtocol.fixture.stopped }, 0)
        }
    }
}
