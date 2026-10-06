// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CNCMBackend

/// Existing, authorized RemotePairing identity only. No filesystem/Keychain
/// discovery, generation or conversion from a Lockdown record is performed.
public struct AuthorizedRemoteIdentity {
    public var signingSeed: Data
    public let controllerID: String
    public let peerID: String
    public let peerPublicKey: Data
    public let alternateIRK: Data
    public let peerUDID: String
    public let peerModel: String
    public init(signingSeed: Data, controllerID: String, peerID: String, peerPublicKey: Data,
                alternateIRK: Data, peerUDID: String, peerModel: String) throws {
        guard signingSeed.count == 32, peerPublicKey.count == 32, alternateIRK.count == 16,
              [controllerID, peerID, peerUDID, peerModel].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }) else { throw NativeBackendError.invalidIdentity }
        self.signingSeed = signingSeed; self.controllerID = controllerID; self.peerID = peerID
        self.peerPublicKey = peerPublicKey; self.alternateIRK = alternateIRK; self.peerUDID = peerUDID; self.peerModel = peerModel
    }
    /// Best-effort clearing of this owned Data value; callers must also dispose
    /// of their original copies. No claim that Swift eliminates every COW copy.
    public mutating func clearSeed() { signingSeed.resetBytes(in: signingSeed.startIndex..<signingSeed.endIndex); signingSeed.removeAll() }
}
public struct ExistingSessionAuthorization {
    public let verifyExistingIdentity: Bool
    public let screen: Bool
    public let screenVideoStream: Bool
    public let input: Bool
    public init(verifyExistingIdentity: Bool, screen: Bool = false, screenVideoStream: Bool = false, input: Bool = false) {
        self.verifyExistingIdentity = verifyExistingIdentity; self.screen = screen
        self.screenVideoStream = screenVideoStream; self.input = input
    }
    var mask: UInt32 { (screen ? 1 : 0) | (screenVideoStream ? 2 : 0) | (input ? 4 : 0) | (verifyExistingIdentity ? 8 : 0) }
}
public enum NativeBackendError: Error, Equatable {
    case invalidIdentity, authorizationRequired, unsupportedABI, invalidCandidate, busy, closed, malformedEvent
    case transport(code: Int32)
    /// Numeric protocol categories only; never raw peer data or keys.
    case protocolFailure(stage: UInt32, cause: UInt32)
    case touchPreparationFailure(stage: UInt32, cause: UInt32)
}
public enum InputDelivery: Sendable { case reportsWrittenVisualEffectUnverified }

/// Owns one native worker, its two relay streams and media. The caller closes
/// on explicit stop, execution expiry or disconnect, rather than app visibility.
/// Initializer is idle and never imports credentials.
@MainActor public final class NativeDeveloperServices: DeveloperServices {
    public static var linkedABIVersion: UInt32 { ncm_backend_abi() }
    private var handle: UInt64 = 0
    private var serial: UInt64 = 0
    private var busy = false
    private var ready = false
    private var services: [String] = []
    public init() {}
    deinit { if handle != 0 { ncm_backend_close(handle) } }
    public func close() {
        let old = handle; handle = 0; ready = false; services = []
        if old != 0 { ncm_backend_close(old) }
    }
    /// Caller must refresh discovery just before this call (candidate TTL).
    /// Bind to the actual .2/24 Ethernet interface, never default routing.
    public func connect(identity: AuthorizedRemoteIdentity, authorization: ExistingSessionAuthorization,
                        discovery: DiagnosticReply, endpoint: DiagnosticReply.Endpoint) async throws {
        try Task.checkCancellation()
        guard authorization.verifyExistingIdentity else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard Self.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        guard let generation = discovery.generation, generation > 0, endpoint.service == "remotepairing",
              discovery.endpoints?.contains(where: { $0.index == endpoint.index && $0.family == endpoint.family && $0.port == endpoint.port && $0.service == endpoint.service }) == true else { throw NativeBackendError.invalidCandidate }
        let row = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory()).row
        var config = ncm_config(abi: 1, interface_index: row.index, generation: generation, endpoint_index: UInt32(endpoint.index), permissions: authorization.mask)
        let values = [identity.signingSeed, Data(identity.controllerID.utf8), Data(identity.peerID.utf8), identity.peerPublicKey,
                      identity.alternateIRK, Data(identity.peerUDID.utf8), Data(identity.peerModel.utf8)]
        var started: UInt64 = 0
        let code = withSlices(values) { b in
            var raw = ncm_identity(seed: b[0], controller_id: b[1], peer_id: b[2], peer_public_key: b[3], alt_irk: b[4], peer_udid: b[5], peer_model: b[6])
            return ncm_backend_start(&config, &raw, &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started
        try await finishConnect(started)
    }
    private func finishConnect(_ token: UInt64) async throws {
        busy = true; defer { busy = false }
        do {
            let (header, data) = try await receive(token, requestID: 0)
            guard header.kind == 1, data.count <= 256 * 1024,
                  let names = try? JSONDecoder().decode([String].self, from: data), names.count <= 4096 else { throw NativeBackendError.malformedEvent }
            services = names; ready = true
        } catch { if handle == token { close() }; throw error }
    }
    public func listServices() async throws -> [String] {
        guard ready, handle != 0 else { throw NativeBackendError.closed }; return services
    }
    public func checkDeveloperReadiness() async throws { _ = try await operation(1) }
    public func capturePNG() async throws -> Data { try await operation(2, expectedKind: 4) }
    /// Starts an authenticated screen video stream; packets are drained locally.
    public func startTouchMedia() async throws { _ = try await operation(3) }
    public func tapDelivery(x: UInt16, y: UInt16) async throws -> InputDelivery {
        _ = try await operation(4, x: x, y: y); return .reportsWrittenVisualEffectUnverified
    }
    public func tap(x: UInt16, y: UInt16) async throws { _ = try await tapDelivery(x: x, y: y) }
    public func dragDelivery(fromX: UInt16, fromY: UInt16, toX: UInt16, toY: UInt16, durationMS: UInt16) async throws -> InputDelivery {
        guard (100...2000).contains(durationMS) else { throw NativeBackendError.malformedEvent }
        _ = try await operation(6, x: fromX, y: fromY, drag: (toX, toY, durationMS))
        return .reportsWrittenVisualEffectUnverified
    }
    private func operation(_ action: UInt32, x: UInt16 = 0, y: UInt16 = 0, expectedKind: UInt32 = 2, drag: (UInt16, UInt16, UInt16)? = nil) async throws -> Data {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false }; let token = handle
        serial += 1; let id = serial
        do {
            try Task.checkCancellation()
            let code: Int32
            if let drag { code = ncm_backend_drag(token, id, x, y, drag.0, drag.1, drag.2) }
            else { code = ncm_backend_submit(token, id, action, x, y) }
            guard code == 0 else { throw NativeBackendError.transport(code: code) }
            let (header, data) = try await receive(token, requestID: id)
            guard header.kind == expectedKind else { throw NativeBackendError.malformedEvent }
            return data
        } catch {
            if case NativeBackendError.touchPreparationFailure = error { throw error }
            if handle == token { close() }; throw error
        }
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws -> (ncm_event, Data) {
        // Overall connect/readiness/media stages can contain multiple 15s protocol
        // steps. This bound is independent of the Rust per-stage deadlines.
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = ncm_event(); let status = ncm_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            if status == 3 { throw NativeBackendError.closed }
            var data = Data()
            if status == 5 {
                guard event.size > 0, event.size <= 64 * 1024 * 1024 else { throw NativeBackendError.malformedEvent }
                data = Data(count: event.size)
                let copied = data.withUnsafeMutableBytes { bytes in ncm_backend_poll(token, &event, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
                guard copied == 0 else { throw NativeBackendError.transport(code: copied) }
            } else if status != 0 { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 10 { throw NativeBackendError.touchPreparationFailure(stage: event.stage, cause: event.cause) }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            return (event, data)
        }
        throw NCMError.timeout
    }
    #if NCM_OFFLINE_FIXTURES
    /// Compiled only into the separately built host test target.
    func connectMediaFailureFixture() async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0
        let code = ncm_test_start_media_failure(&started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    func connectLoopbackFixture(port: UInt16) async throws {
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        var started: UInt64 = 0; let code = ncm_test_start_loopback(port, &started)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; try await finishConnect(started)
    }
    #endif
}
private func withSlices<T>(_ data: [Data], _ index: Int = 0, _ slices: [ncm_bytes] = [], _ body: ([ncm_bytes]) -> T) -> T {
    if index == data.count { return body(slices) }
    return data[index].withUnsafeBytes { bytes in
        withSlices(data, index + 1, slices + [ncm_bytes(data: bytes.bindMemory(to: UInt8.self).baseAddress, size: bytes.count)], body)
    }
}

/// Ordinary Lockdown only. Caller explicitly supplies the existing pairing plist.
/// Kept separate from the RP identity, discovery and screenshot/media API.
@MainActor public final class NativeLockdownSession {
    private var handle: UInt64 = 0
    private var ready = false
    private var busy = false
    public init() {}
    deinit { if handle != 0 { ncm_backend_close(handle) } }
    public func close() {
        let old = handle; handle = 0; ready = false
        if old != 0 { ncm_backend_close(old) }
    }
    public func connect(pairingRecord: Data, expectedUDID: String, authorized: Bool) async throws {
        try Task.checkCancellation()
        guard authorized else { throw NativeBackendError.authorizationRequired }
        guard !busy, handle == 0 else { throw NativeBackendError.busy }
        guard !pairingRecord.isEmpty, pairingRecord.count <= 1024 * 1024,
              !expectedUDID.isEmpty, expectedUDID.utf8.count <= 256 else { throw NativeBackendError.invalidIdentity }
        guard NativeDeveloperServices.linkedABIVersion == NCM_BACKEND_ABI else { throw NativeBackendError.unsupportedABI }
        let row = try NCMInterfaceBinding.resolve(NCMInterfaceBinding.inventory()).row
        var started: UInt64 = 0
        let code = withSlices([pairingRecord, Data(expectedUDID.utf8)]) { slices in
            ncm_lockdown_start(row.index, UInt32(NCM_ALLOW_EXISTING_VERIFY), slices[0], slices[1], &started)
        }
        guard code == 0, started != 0 else { throw NativeBackendError.transport(code: code) }
        handle = started; busy = true; defer { busy = false }
        do { try await receive(started, requestID: 0); ready = true }
        catch { close(); throw error }
    }
    /// Normal cleanup sends StopSession on the same TLS channel. Cancellation or
    /// background close instead revokes transport; it cannot confirm remote stop.
    public func stop() async throws {
        guard !busy else { throw NativeBackendError.busy }
        guard ready, handle != 0 else { throw NativeBackendError.closed }
        busy = true; defer { busy = false; close() }
        let token = handle
        let code = ncm_backend_submit(token, 1, 5, 0, 0)
        guard code == 0 else { throw NativeBackendError.transport(code: code) }
        try await receive(token, requestID: 1)
    }
    private func receive(_ token: UInt64, requestID: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(40))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard handle == token else { throw NativeBackendError.closed }
            var event = ncm_event()
            let status = ncm_backend_poll(token, &event, nil, 0)
            if status == 4 { try await Task.sleep(for: .milliseconds(10)); continue }
            guard status == 0 else { throw NativeBackendError.transport(code: status) }
            guard event.request_id == requestID, event.size == 0, event.reserved == 0 else { throw NativeBackendError.malformedEvent }
            if event.kind == 3 { throw NativeBackendError.protocolFailure(stage: event.stage, cause: event.cause) }
            guard event.kind == 2 else { throw NativeBackendError.malformedEvent }
            return
        }
        throw NCMError.timeout
    }
}
