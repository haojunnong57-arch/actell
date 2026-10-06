// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import CNCMBackend
@testable import PhoneAgentNCM
final class NativeBackendTests: XCTestCase {
    @MainActor func testLockdownGateIsIndependentOfRemotePairing() async {
        let client = NativeLockdownSession()
        do { try await client.connect(pairingRecord: Data("rp-record".utf8), expectedUDID: "PUBLIC-TEST", authorized: false); XCTFail("authorization gate") }
        catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
        do { try await client.stop(); XCTFail("idle session") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        var handle: UInt64 = 55
        let invalid = Data("rp-record".utf8), udid = Data("PUBLIC-TEST".utf8)
        invalid.withUnsafeBytes { record in udid.withUnsafeBytes { peer in
            let r = ncm_bytes(data: record.bindMemory(to: UInt8.self).baseAddress, size: record.count)
            let u = ncm_bytes(data: peer.bindMemory(to: UInt8.self).baseAddress, size: peer.count)
            XCTAssertEqual(ncm_lockdown_start(1, 8, r, u, &handle), 1)
            XCTAssertEqual(handle, 0)
        }}
        client.close(); client.close()
    }
    @MainActor func testActualNativeABIAndMalformedIdentityBoundary() throws {
        XCTAssertEqual(NativeDeveloperServices.linkedABIVersion, 1)
        XCTAssertEqual(MemoryLayout<ncm_event>.size, 32)
        var handle: UInt64 = 44
        XCTAssertEqual(ncm_backend_start(nil, nil, &handle), 1)
        XCTAssertThrowsError(try AuthorizedRemoteIdentity(signingSeed: Data(), controllerID: "test", peerID: "test", peerPublicKey: Data(), alternateIRK: Data(), peerUDID: "test", peerModel: "test"))
        XCTAssertEqual(ncm_backend_submit(0, 1, 2, 0, 0), 3)
    }
    @MainActor func testIdleNativeWrapperDoesNotConnect() async {
        let client = NativeDeveloperServices()
        do { _ = try await client.listServices(); XCTFail("idle client") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close(); client.close()
    }
    @MainActor func testVerifyConsentGateRunsBeforeAnyInterfaceOrSocket() async throws {
        // Synthetic bytes only; no pairing record is generated or persisted.
        let identity = try AuthorizedRemoteIdentity(signingSeed: Data(repeating: 0x42, count: 32), controllerID: "SYNTHETIC", peerID: "SYNTHETIC", peerPublicKey: Data(repeating: 0x44, count: 32), alternateIRK: Data(repeating: 0x33, count: 16), peerUDID: "SYNTHETIC", peerModel: "SYNTHETIC")
        let discovery = try DiagnosticReply.decode(Data("{\"protocol\":\"ND1\",\"layer\":\"discovery\",\"result\":\"candidates\",\"authenticated\":false,\"generation\":7,\"endpoints\":[{\"index\":0,\"service\":\"remotepairing\",\"family\":4,\"port\":54321}]}\n".utf8))
        let client = NativeDeveloperServices()
        do { try await client.connect(identity: identity, authorization: .init(verifyExistingIdentity: false), discovery: discovery, endpoint: discovery.endpoints![0]); XCTFail("consent gate") }
        catch { XCTAssertEqual(error as? NativeBackendError, .authorizationRequired) }
    }
    #if NCM_OFFLINE_FIXTURES
    @MainActor func testMediaPreparationFailureRetainsSessionButUncertainTouchClosesIt() async throws {
        let client = NativeDeveloperServices()
        try await client.connectMediaFailureFixture()
        do { try await client.startTouchMedia(); XCTFail("expected preparation timeout") }
        catch { XCTAssertEqual(error as? NativeBackendError, .touchPreparationFailure(stage: 15, cause: 2)) }
        // This crosses the same native handle after failure, not just a cached UI flag.
        try await client.checkDeveloperReadiness()
        do { _ = try await client.tapDelivery(x: 32768, y: 32768); XCTFail("expected uncertain delivery") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 11, cause: 7)) }
        do { _ = try await client.listServices(); XCTFail("uncertain touch must close") }
        catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
        client.close()
    }
    private final class Fixture {
        let process = Process()
        let output = Pipe()
        let port: UInt16
        init(hold: Bool) throws {
            guard let path = ProcessInfo.processInfo.environment["NCM_RELAY_FIXTURE"] else { throw XCTSkip("fixture executable absent") }
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = hold ? ["hold"] : []
            process.standardOutput = output
            try process.run()
            var line = Data()
            while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
            guard let parsed = UInt16(String(decoding: line, as: UTF8.self)) else { throw NativeBackendError.malformedEvent }
            port = parsed
        }
        func finish() -> String {
            process.waitUntilExit()
            return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        deinit { if process.isRunning { process.terminate() } }
    }
    @MainActor func testSwiftRustRealCRelayPropagatesPairVerifyFailure() async throws {
        let fixture = try Fixture(hold: false), client = NativeDeveloperServices()
        do { try await client.connectLoopbackFixture(port: fixture.port); XCTFail("synthetic peer never authenticates") }
        catch { XCTAssertEqual(error as? NativeBackendError, .protocolFailure(stage: 3, cause: 1)) }
        let evidence = fixture.finish()
        XCTAssertEqual(fixture.process.terminationStatus, 0)
        XCTAssertTrue(evidence.contains("GREETING")); XCTAssertTrue(evidence.contains("VERIFY_M1")); XCTAssertTrue(evidence.contains("CLOSED"))
        do { _ = try await client.listServices(); XCTFail("failed generation reused") } catch { XCTAssertEqual(error as? NativeBackendError, .closed) }
    }
    @MainActor func testSwiftCancellationClosesNativeWorkerAndCRelay() async throws {
        let fixture = try Fixture(hold: true), client = NativeDeveloperServices()
        let task = Task { @MainActor in try await client.connectLoopbackFixture(port: fixture.port) }
        // Await actual synthetic wire evidence; detached reader leaves MainActor
        // free for connect/poll, and no timing assumption decides cancellation.
        let read = Task.detached { () -> String in
            var line = Data()
            while let byte = try fixture.output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte[0] != 10 { line.append(byte) }
            return String(decoding: line, as: UTF8.self)
        }
        let greeting = try await read.value
        XCTAssertEqual(greeting, "GREETING")
        task.cancel()
        do { try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let evidence = fixture.finish(); XCTAssertEqual(fixture.process.terminationStatus, 0); XCTAssertTrue(evidence.contains("CLOSED"))
        client.close()
    }
    #endif
}
