import Foundation
import Network
import CryptoKit

enum USBWire {
    static func acceptACK(_ phase: String, needsReceipt: Bool, received: inout Bool) throws -> Bool {
        if phase == "received", needsReceipt, !received { received = true; return false }
        if phase == "executed", !needsReceipt || received { return true }
        throw AppError.unknownOutcome
    }
    static func key(_ hex: String) throws -> SymmetricKey {
        guard hex.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }) else {
            throw AppError.invalid("USB PSK 需为 64 位十六进制")
        }
        var data = Data(); var i = hex.startIndex
        while i < hex.endIndex { let end = hex.index(i, offsetBy: 2); data.append(UInt8(hex[i..<end], radix: 16)!); i = end }
        return SymmetricKey(data: data)
    }
    static func mac(_ text: String, key: SymmetricKey) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).map { String(format: "%02x", $0) }.joined()
    }
    static func verify(_ text: String, signature: String, key: SymmetricKey) -> Bool {
        guard signature.count == 64, let bytes = try? self.key(signature) else { return false }
        return bytes.withUnsafeBytes { HMAC<SHA256>.isValidAuthenticationCode(Data($0), authenticating: Data(text.utf8), using: key) }
    }
}

protocol USBCommandTransport: Sendable {
    func command(_ body: String) async throws
    func command(_ body: String, permit: USBInputPermit?) async throws
    func stop() async
}
extension USBCommandTransport {
    // Test transports can use this default. The production client overrides it
    // to consume the permit at NWConnection.send, after its actor hop.
    func command(_ body: String, permit: USBInputPermit?) async throws {
        try permit?.enqueue({})
        try await command(body)
    }
}

// Dedicated Ethernet connection only. No default-route/VPN changes, HTTP redirects,
// DNS discovery, automatic reconnect, or automatic replay of input.
actor USBCommandClient: USBCommandTransport {
    nonisolated let health = USBTransportHealth()
    private var keepalive: Task<Void, Never>?
    private var connection: NWConnection?
    private var generation = UUID()
    private let queue = DispatchQueue(label: "phoneagent.usb.transport")
    private var key: SymmetricKey?
    private var challenge = ""
    private var incoming = Data()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var ready = false
    private(set) var supportsHID = false
    private var nextID: UInt64 = 0
    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
        var received = false
        let needsReceipt: Bool
        let isPing: Bool
    }
    private var pending: [UInt64: Pending] = [:]

    func connect(pskHex: String) async throws {
        fail(.stopped)
        key = try USBWire.key(pskHex)
        let token = UUID(); generation = token
        health.begin(token)
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wiredEthernet
        parameters.includePeerToPeer = false
        let c = NWConnection(host: "192.168.7.1", port: 28766, using: parameters)
        connection = c
        c.stateUpdateHandler = { [weak self, health] state in
            switch state {
            case .failed, .waiting, .cancelled: health.invalidate(token)
            default: break
            }
            if case .failed = state { Task { await self?.transportFailed(token) } }
            if case .waiting = state { Task { await self?.transportFailed(token) } }
            if case .cancelled = state { Task { await self?.transportFailed(token) } }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiter = continuation
                c.start(queue: queue); receive(token)
                timeout(token, id: nil, seconds: 3)
            }
        } onCancel: { Task { await self.cancel(token) } }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.command("PING"); try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
            }
        }
    }
    func command(_ body: String) async throws {
        try await command(body, permit: nil)
    }
    func command(_ body: String, permit: USBInputPermit?) async throws {
        try Task.checkCancellation()
        guard ready, let key, !body.contains("\n"), body.utf8.count < 128 else { throw AppError.unavailable("USB 未认证连接") }
        if body.hasPrefix("TAP ") || body.hasPrefix("DRAG ") {
            guard supportsHID else { throw AppError.unavailable("当前固件仅 NCM；尚未启用 HID") }
            guard permit != nil else { throw AppError.stopped }
        }
        guard pending.count < 8, nextID < UInt64(UInt32.max) else { throw AppError.unavailable("USB 请求达到上限") }
        nextID += 1; let id = nextID, token = generation
        let payload = "\(id) \(body)"
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let line = payload + " " + USBWire.mac("client|\(challenge)|\(payload)", key: key)
                    let enqueue = {
                        self.pending[id] = Pending(continuation: continuation, needsReceipt: body.hasPrefix("TAP ") || body.hasPrefix("DRAG "), isPing: body == "PING")
                        self.send(line, token)
                    }
                    if let permit { try permit.enqueue(enqueue) } else { enqueue() }
                    timeout(token, id: id, seconds: body.hasPrefix("DRAG ") ? 3 : 1)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancel(token) } }
    }
    func stop() async {
        // Best effort release. Disconnect also revokes the device's lease.
        if ready { try? await command("STOP") }
        fail(.stopped)
    }
    private func send(_ line: String, _ token: UUID) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self] error in
            if error != nil { Task { await self?.transportFailed(token) } }
        })
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, closed: complete || error != nil, token: token) }
        }
    }
    private func consume(_ data: Data?, closed: Bool, token: UUID) {
        guard generation == token else { return }
        if let data { incoming.append(data) }
        guard incoming.count <= 2048 else { fail(.protocolViolation("USB 回复过长")); return }
        while let newline = incoming.firstIndex(of: 10) {
            let bytes = incoming[..<newline]; incoming.removeSubrange(...newline)
            guard bytes.count <= 256, let line = String(data: bytes, encoding: .ascii) else { fail(.protocolViolation("USB 回复格式错误")); return }
            do { try handle(line, token) } catch { fail((error as? AppError) ?? .unknownOutcome); return }
        }
        if closed { fail(.unknownOutcome) } else if generation == token { receive(token) }
    }
    private func handle(_ line: String, _ token: UUID) throws {
        guard let key else { throw AppError.stopped }
        let parts = line.split(separator: " ").map(String.init)
        if !ready {
            if parts.count == 3, parts[0] == "PA1", parts[1] == "CHALLENGE", challenge.isEmpty,
               parts[2].count == 64, (try? USBWire.key(parts[2])) != nil {
                challenge = parts[2]
                send("PA1 AUTH " + USBWire.mac("auth|\(challenge)", key: key), token); return
            }
            guard parts.count == 3, parts[0] == "READY", ["0", "1"].contains(parts[1]), !challenge.isEmpty,
                  USBWire.verify("server|\(challenge)|READY \(parts[1])", signature: parts[2], key: key) else {
                throw AppError.protocolViolation("USB 身份认证失败；确认已配置同一 PSK")
            }
            ready = true; supportsHID = parts[1] == "1"
            connectWaiter?.resume(); connectWaiter = nil; return
        }
        guard parts.count == 3, let id = UInt64(parts[0]), var request = pending[id],
              USBWire.verify("server|\(challenge)|\(parts[0]) \(parts[1])", signature: parts[2], key: key) else {
            throw AppError.protocolViolation("USB ACK 签名或命令 ID 不匹配")
        }
        if try USBWire.acceptACK(parts[1], needsReceipt: request.needsReceipt, received: &request.received) {
            if request.isPing { health.receivedPing(token) }
            pending.removeValue(forKey: id); request.continuation.resume()
        } else { pending[id] = request }
    }
    private func timeout(_ token: UUID, id: UInt64?, seconds: Double) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.expire(token, id: id)
        }
    }
    private func expire(_ token: UUID, id: UInt64?) {
        guard generation == token else { return }
        if let id { if pending[id] != nil { fail(.unknownOutcome) } }
        else if !ready { fail(.timeout) }
    }
    private func transportFailed(_ token: UUID) { if generation == token { fail(.unknownOutcome) } }
    private func cancel(_ token: UUID) { if generation == token { fail(.stopped) } }
    private func fail(_ error: AppError) {
        health.invalidate(); keepalive?.cancel(); keepalive = nil
        generation = UUID(); ready = false; supportsHID = false
        connection?.cancel(); connection = nil; incoming.removeAll(); challenge = ""; nextID = 0; key = nil
        connectWaiter?.resume(throwing: error); connectWaiter = nil
        let waiting = pending; pending.removeAll()
        for request in waiting.values { request.continuation.resume(throwing: error) }
    }
}
