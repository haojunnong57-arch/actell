import Foundation
import Network
import OSLog
import Darwin

/// Bounded, process-local diagnostics. Callers record protocol metadata only:
/// never command arguments, received payloads, screenshots, goals, or secrets.
final class USBDiagnosticsLog: @unchecked Sendable {
    static let revision = "usb-diag-20261004-2"
    private let lock = NSLock()
    private let capacity: Int
    private let console: Bool
    private let logger = Logger(subsystem: "com.ja1chen.PhoneAgent", category: "USBNetwork")
    private let formatter: ISO8601DateFormatter
    private let started = ProcessInfo.processInfo.systemUptime
    private let header: String
    private var rows: [String] = []
    private var sequence = 0
    private var dropped = 0

    init(capacity: Int = 600, console: Bool = true) {
        self.capacity = max(1, capacity); self.console = console
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let bundle = Bundle.main
        func value(_ key: String) -> String { bundle.object(forInfoDictionaryKey: key) as? String ?? "unknown" }
        let purpose = value("NSLocalNetworkUsageDescription")
        #if targetEnvironment(simulator)
        let runtime = "simulator (local-network privacy cannot be validated here)"
        #else
        let runtime = "device"
        #endif
        header = """
        PhoneAgent USB Diagnostics v1
        revision=\(Self.revision)
        bundle=\(bundle.bundleIdentifier ?? "unknown") version=\(value("CFBundleShortVersionString")) build=\(value("CFBundleVersion"))
        OS=\(ProcessInfo.processInfo.operatingSystemVersionString) runtime=\(runtime)
        SDK=\(value("DTSDKName")) XcodeBuild=\(value("DTXcodeBuild"))
        localNetworkUsageDescriptionPresent=\(!purpose.isEmpty && purpose != "unknown") (not permission status)
        target=192.168.7.1:28766 expectedPhone=192.168.7.2/24 binding=explicitInterfaceFromLocalIPv4 peerToPeer=false protocol=PA2 noPSK
        Times are UTC plus monotonic elapsed seconds. Copy buffer is process-local; events also appear in OSLog category USBNetwork.
        Interface inventory shows USB-subnet/link-local IPv4; other IPs are redacted. No MAC/SSID/IPv6 or command/screen/model payloads.
        Default/wired path monitors describe system paths, not proof of USB TCP reachability.
        """
    }
    func record(_ message: String, attempt: UUID? = nil) {
        let line = lock.withLock {
            sequence += 1
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            let id = attempt.map { String($0.uuidString.prefix(8)) } ?? "app"
            // Prevent multiline/error text from impersonating another log event.
            let clean = String(message.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined().prefix(1600))
            let line = "\(formatter.string(from: Date())) +\(elapsed)s #\(sequence) [\(id)] \(clean)"
            rows.append(line)
            if rows.count > capacity { dropped += rows.count - capacity; rows.removeFirst(rows.count - capacity) }
            return line
        }
        if console { logger.notice("\(line, privacy: .public)") }
    }
    func report() -> String {
        lock.withLock {
            "\(header)\nexported=\(formatter.string(from: Date())) retained=\(rows.count) dropped=\(dropped)\n\n" + rows.joined(separator: "\n") + "\n"
        }
    }
    static func commandKind(_ body: String) -> String {
        if body == "PING" || body == "STOP" { return body }
        if body.hasPrefix("TAP ") { return "TAP" }
        if body.hasPrefix("DRAG ") { return "DRAG" }
        return "OTHER"
    }
    static func visibleIPv4(_ address: String) -> String {
        if address.hasPrefix("192.168.7.") || address.hasPrefix("169.254.") { return address }
        return "<non-USB IPv4 redacted>"
    }
    func recordInterfaces(reason: String, attempt: UUID? = nil) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            record("interfaces reason=\(reason) getifaddrs_errno=\(errno)", attempt: attempt); return
        }
        defer { freeifaddrs(head) }
        var inventory: [String: (flags: UInt32, addresses: [String])] = [:]
        var cursor = head
        func address(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let row = item.pointee, name = String(cString: row.ifa_name)
            guard row.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var entry = inventory[name] ?? (row.ifa_flags, [])
            if let ip = address(row.ifa_addr) {
                let visible = Self.visibleIPv4(ip)
                let mask = visible == ip ? " mask=\(address(row.ifa_netmask) ?? "unknown")" : ""
                entry.addresses.append("\(visible)\(mask)")
            }
            inventory[name] = entry
        }
        record("interfaces reason=\(reason) count=\(inventory.count)", attempt: attempt)
        for name in inventory.keys.sorted() {
            guard let entry = inventory[name] else { continue }
            record("interface name=\(name) up=\(entry.flags & UInt32(IFF_UP) != 0) running=\(entry.flags & UInt32(IFF_RUNNING) != 0) broadcast=\(entry.flags & UInt32(IFF_BROADCAST) != 0) pointToPoint=\(entry.flags & UInt32(IFF_POINTOPOINT) != 0) ipv4=\(entry.addresses.isEmpty ? "none" : entry.addresses.joined(separator: ","))", attempt: attempt)
        }
    }
}

/// Resolve the configured local IPv4 to one concrete Ethernet-like interface.
/// NWPathMonitor's default-route inventory can omit a local-only USB service.
/// Never fall back to an unbound connection, a hostname, or another transport.
struct USBInterfaceBinding {
    static let localIP = "192.168.7.2"
    static let remoteIP = "192.168.7.1"
    static let netmask = "255.255.255.0"
    struct Row: Equatable {
        let name: String
        let index: UInt32
        let address: String
        let mask: String
        let flags: UInt32
        let linkType: UInt8?
    }
    let row: Row
    let interface: NWInterface
    let localAddress: IPv4Address
    let remoteAddress: IPv4Address

    static func select(_ rows: [Row]) throws -> Row {
        let matches = rows.filter { $0.address == localIP }
        guard matches.count == 1, let row = matches.first else {
            throw AppError.unavailable(matches.isEmpty ? "未找到配置 192.168.7.2 的接口；请确认 USB 以太网固定 IP" : "多个接口使用 192.168.7.2，无法安全选择 USB 接口")
        }
        let required = UInt32(IFF_UP | IFF_RUNNING | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK | IFF_POINTOPOINT)
        guard row.index > 0, row.mask == netmask, row.flags & required == required,
              row.flags & forbidden == 0, row.linkType == UInt8(IFT_ETHER) else {
            throw AppError.unavailable("接口 \(row.name) 不满足 USB Ethernet 条件（启用、运行中、广播、/24、Ethernet 链路且非隧道）")
        }
        return row
    }
    static func validateType(_ type: NWInterface.InterfaceType) throws {
        switch type {
        case .wiredEthernet, .other: break // .other additionally requires IFT_ETHER and no POINTOPOINT above.
        default: throw AppError.unavailable("固定 IP 对应的是 \(type) 接口，拒绝用作 USB 通信")
        }
    }
    static func resolve(_ rows: [Row]) throws -> USBInterfaceBinding {
        let row = try select(rows)
        // This public parser returns the NWInterface for the explicit scope.
        // Validate the result; unsupported/stale scopes fail instead of unbinding.
        guard let remote = IPv4Address("\(remoteIP)%\(row.name)"),
              let local = IPv4Address("\(localIP)%\(row.name)"),
              let interface = remote.interface, local.interface == interface,
              interface.name == row.name, interface.index == Int(row.index) else {
            throw AppError.unavailable("无法解析或接口已变化：\(row.name)；请重新连接 USB 后手动重试")
        }
        try validateType(interface.type)
        return USBInterfaceBinding(row: row, interface: interface, localAddress: local, remoteAddress: remote)
    }
    func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(localAddress), port: .any)
        parameters.includePeerToPeer = false
        return parameters
    }
    static func inventory() throws -> [Row] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw AppError.unavailable("无法读取接口列表，errno=\(errno)") }
        defer { freeifaddrs(head) }
        var entries: [(String, String, String, UInt32)] = []
        var linkTypes: [String: UInt8] = [:]
        var cursor = head
        func ipv4(_ pointer: UnsafeMutablePointer<sockaddr>?) -> String? {
            guard let pointer, pointer.pointee.sa_family == UInt8(AF_INET) else { return nil }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(pointer, socklen_t(pointer.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
            return String(cString: buffer)
        }
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let value = entry.pointee, name = String(cString: value.ifa_name)
            if let address = ipv4(value.ifa_addr) {
                entries.append((name, address, ipv4(value.ifa_netmask) ?? "unknown", value.ifa_flags))
            }
            if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK) {
                // Read the link type only, never link-layer addresses (MACs).
                linkTypes[name] = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self).pointee.sdl_type
            }
        }
        return entries.map { name, address, mask, flags in
            Row(name: name, index: if_nametoindex(name), address: address, mask: mask, flags: flags, linkType: linkTypes[name])
        }
    }
}

enum USBConnectionStatus: Equatable {
    case idle, connecting, waiting(String), awaitingGreeting, checking, ready(hid: Bool), failed(String), disconnected(String)
    var isConnecting: Bool {
        switch self {
        case .connecting, .waiting, .awaitingGreeting, .checking: return true
        default: return false
        }
    }
    // A system permission sheet can make the scene inactive. Only initial
    // connection/PING setup may continue there; background still cancels it.
    func allowsSetup(in scene: ScreenUSBExecutionContext.Scene) -> Bool {
        scene == .active || (scene == .inactive && isConnecting)
    }
    var isFailure: Bool { if case .failed = self { return true }; return false }
    var message: String {
        switch self {
        case .idle: return "USB 尚未连接"
        case .connecting: return "正在连接 USB 设备 192.168.7.1:28766…"
        case .waiting(let reason): return "等待 USB 网络（本次连接最多 30 秒）：\(reason)"
        case .awaitingGreeting: return "USB TCP 已接通，等待设备 PA2 应答…"
        case .checking: return "已收到设备应答，正在验证双向 PING…"
        case .ready(let hid): return hid ? "USB NCM + HID 已连接（免 PSK）；屏幕控制尚需逐动作确认" : "USB NCM 双向 PING 已验证（免 PSK）；固件未启用 HID"
        case .failed(let message): return "USB 连接失败：\(message)"
        case .disconnected(let message): return "USB 已断开：\(message)"
        }
    }
}

enum USBWire {
    static func transportError(_ error: NWError?, inputInFlight: Bool, path: NWPath? = nil) -> AppError {
        // A connection failure before any input is not an unknown HID result.
        // Preserve unknown-outcome semantics once an input is in flight.
        if inputInFlight { return .unknownOutcome }
        let detail = error.map { String(describing: $0) } ?? "连接被关闭"
        return .unavailable("\(detail)。\(pathDetails(path)) 请检查 USB 以太网、固定 IP 和本地网络权限，再手动连接。")
    }
    static func pathDetails(_ path: NWPath?) -> String {
        guard let path else { return "系统未提供此连接的路径信息。" }
        let reason: String
        if path.status == .unsatisfied {
            switch path.unsatisfiedReason {
            case .localNetworkDenied: reason = "本地网络访问尚未获准（localNetworkDenied）"
            case .notAvailable: reason = "没有满足有线连接要求的路径（notAvailable）"
            case .wifiDenied: reason = "系统不允许 Wi-Fi 路径（wifiDenied）"
            case .cellularDenied: reason = "系统不允许蜂窝路径（cellularDenied）"
            case .vpnInactive: reason = "系统报告 VPN 未激活（vpnInactive）"
            @unknown default: reason = String(describing: path.unsatisfiedReason)
            }
        } else { reason = "无 unsatisfied 原因" }
        let interfaces = path.availableInterfaces.map { "\($0.name)(\($0.type))" }.joined(separator: ", ")
        return "路径=\(path.status)；原因=\(reason)；可用接口=\(interfaces.isEmpty ? "无" : interfaces)；IPv4=\(path.supportsIPv4 ? "是" : "否")。"
    }
    static func receiptTimeout(isPing: Bool, inputInFlight: Bool) -> AppError {
        // A PING/STOP timeout also revokes any concurrent input, whose result
        // remains unknown even though the timed-out request was not an input.
        if inputInFlight { return .unknownOutcome }
        return .unavailable("USB \(isPing ? "PING" : "STOP") 回执超时，已断开；请手动重新连接。")
    }
    static func acceptACK(_ phase: String, needsReceipt: Bool, received: inout Bool) throws -> Bool {
        if phase == "received", needsReceipt, !received { received = true; return false }
        if phase == "executed", !needsReceipt || received { return true }
        throw needsReceipt ? AppError.unknownOutcome : AppError.protocolViolation("USB ACK 阶段不匹配")
    }
    // PA2 deliberately has no identity authentication or encryption. Never
    // silently interpret a PA1 challenge/LOCKED response as a usable session.
    static func supportsHID(_ greeting: String) throws -> Bool {
        switch greeting {
        case "PA2 READY 0": return false
        case "PA2 READY 1": return true
        default: throw AppError.protocolViolation("USB 协议不匹配；App 和固件均需 PA2 免 PSK 版本")
        }
    }
    static func parseACK(_ line: String) throws -> (id: UInt64, phase: String) {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UInt32(parts[0]), id > 0, String(id) == parts[0],
              parts[1] == "received" || parts[1] == "executed" else {
            throw AppError.protocolViolation("USB ACK 格式错误")
        }
        return (UInt64(id), String(parts[1]))
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
    private var incoming = Data()
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var ready = false
    private var tcpReady = false
    private var lastWaitingError: NWError?
    private var lastPath: NWPath?
    private var pathMonitors: [NWPathMonitor] = []
    private var receivedBytes = 0
    private var receivedLines = 0
    private var pingReplies = 0
    private let diagnostics: USBDiagnosticsLog
    private let onProgress: @Sendable (USBConnectionStatus) -> Void
    private(set) var supportsHID = false
    private var nextID: UInt64 = 0
    private struct Pending {
        let continuation: CheckedContinuation<Void, Error>
        var received = false
        let needsReceipt: Bool
        let isPing: Bool
        let kind: String
        let logDetails: Bool
        let sentAt: TimeInterval
    }
    private var pending: [UInt64: Pending] = [:]

    init(diagnostics: USBDiagnosticsLog = USBDiagnosticsLog(), onProgress: @escaping @Sendable (USBConnectionStatus) -> Void = { _ in }) {
        self.diagnostics = diagnostics; self.onProgress = onProgress
    }

    func connect(attempt: UUID = UUID()) async throws {
        fail(.stopped)
        let token = attempt; generation = token
        health.begin(token)
        diagnostics.record("connect.begin target=192.168.7.1:28766 binding=explicitInterface setupDeadline=30s greetingDeadline=3s", attempt: token)
        diagnostics.recordInterfaces(reason: "connect", attempt: token)
        let binding: USBInterfaceBinding
        do {
            let rows = try USBInterfaceBinding.inventory()
            for row in rows where row.address == USBInterfaceBinding.localIP {
                diagnostics.record("binding.candidate name=\(row.name) index=\(row.index) mask=\(row.mask) flags=\(row.flags) linkType=\(row.linkType.map { String($0) } ?? "unknown")", attempt: token)
            }
            binding = try USBInterfaceBinding.resolve(rows)
        } catch {
            diagnostics.record("binding.rejected reason=\(error.localizedDescription)", attempt: token)
            fail((error as? AppError) ?? .unavailable("USB 接口绑定失败")); throw error
        }
        let parameters = binding.parameters()
        diagnostics.record("binding.selected name=\(binding.interface.name) index=\(binding.interface.index) networkType=\(binding.interface.type) local=\(binding.localAddress) remote=\(binding.remoteAddress) requiredInterface=true; no unbound fallback", attempt: token)
        startPathMonitors(token)
        let c = NWConnection(host: .ipv4(binding.remoteAddress), port: 28766, using: parameters)
        connection = c
        c.pathUpdateHandler = { [weak self] path in
            Task { await self?.pathChanged(path, source: "connection", token: token) }
        }
        c.viabilityUpdateHandler = { [diagnostics] viable in
            diagnostics.record("connection.viability=\(viable)", attempt: token)
        }
        c.betterPathUpdateHandler = { [diagnostics] available in
            diagnostics.record("connection.betterPath=\(available) (no automatic reconnect)", attempt: token)
        }
        c.stateUpdateHandler = { [weak self, health, diagnostics] state in
            switch state {
            case .failed, .waiting, .cancelled: health.invalidate(token)
            default: break
            }
            diagnostics.record("connection.state=\(state)", attempt: token)
            // currentPath can lack an endpoint handler during setup/teardown.
            // Consume pathUpdateHandler snapshots instead of querying here.
            Task { await self?.stateChanged(state, token: token) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connectWaiter = continuation
                c.start(queue: queue)
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    await self?.expireSetup(token)
                }
            }
        } onCancel: { Task { await self.cancel(token) } }
        keepalive = Task { [weak self] in
            while !Task.isCancelled {
                do { try await self?.command("PING"); try await Task.sleep(nanoseconds: 200_000_000) }
                catch { return }
            }
        }
    }
    private func startPathMonitors(_ token: UUID) {
        for (source, monitor) in [("system.default", NWPathMonitor()), ("system.wired", NWPathMonitor(requiredInterfaceType: .wiredEthernet))] {
            monitor.pathUpdateHandler = { [weak self] path in
                Task { await self?.pathChanged(path, source: source, token: token) }
            }
            pathMonitors.append(monitor); monitor.start(queue: queue)
        }
    }
    private func pathChanged(_ path: NWPath, source: String, token: UUID) {
        guard generation == token else { return }
        diagnostics.record("path source=\(source) \(USBWire.pathDetails(path))", attempt: token)
        if source == "connection" {
            lastPath = path
            if let error = lastWaitingError, !tcpReady {
                onProgress(.waiting("\(error)。\(USBWire.pathDetails(path))"))
            }
        }
    }
    private func stateChanged(_ state: NWConnection.State, token: UUID) {
        guard generation == token else { return }
        switch state {
        case .waiting(let error):
            if !tcpReady, !ready, pending.isEmpty {
                // First-use local network permission may put NWConnection in
                // waiting before the user answers. There are no commands yet.
                // Once TCP has connected, any later waiting state is fatal.
                lastWaitingError = error
                diagnostics.record("connect.waiting tcpReady=false error=\(error); cachedConnectionPath=\(USBWire.pathDetails(lastPath))", attempt: token)
                onProgress(.waiting("\(error)。\(USBWire.pathDetails(lastPath))"))
            } else { transportFailed(token, error: error) }
        case .ready:
            guard !tcpReady else { return }
            tcpReady = true; lastWaitingError = nil
            diagnostics.record("tcp.ready; PA2 greeting deadline started", attempt: token)
            onProgress(.awaitingGreeting)
            receive(token)
            timeout(token, id: nil, seconds: 3)
        case .failed(let error): transportFailed(token, error: error)
        case .cancelled: transportFailed(token, error: nil)
        default: break
        }
    }
    private func expireSetup(_ token: UUID) {
        guard generation == token, !ready else { return }
        let detail = "\(lastWaitingError.map { String(describing: $0) } ?? "no waiting error"); \(USBWire.pathDetails(lastPath))"
        diagnostics.record("timeout.setup 30s tcpReady=\(tcpReady) greetingReady=\(ready)", attempt: token)
        diagnostics.recordInterfaces(reason: "setup-timeout", attempt: token)
        fail(.unavailable("USB 连接等待超过 30 秒。\(detail) 如出现本地网络提示，请允许后手动重试；没有提示时请保留这段路径诊断。"))
    }
    func command(_ body: String) async throws {
        try await command(body, permit: nil)
    }
    func command(_ body: String, permit: USBInputPermit?) async throws {
        try Task.checkCancellation()
        guard ready, !body.isEmpty, body.utf8.allSatisfy({ (32...126).contains($0) }), body.utf8.count < 128 else { throw AppError.unavailable("USB 未连接或命令格式错误") }
        if body.hasPrefix("TAP ") || body.hasPrefix("DRAG ") {
            guard supportsHID else { throw AppError.unavailable("当前固件仅 NCM；尚未启用 HID") }
            guard permit != nil else { throw AppError.stopped }
        }
        guard pending.count < 8, nextID < UInt64(UInt32.max) else { throw AppError.unavailable("USB 请求达到上限") }
        nextID += 1; let id = nextID, token = generation
        let payload = "\(id) \(body)"
        let kind = USBDiagnosticsLog.commandKind(body)
        let logDetails = kind != "PING" || id <= 4 || id % 25 == 0
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let enqueue = {
                        self.pending[id] = Pending(continuation: continuation, needsReceipt: body.hasPrefix("TAP ") || body.hasPrefix("DRAG "), isPing: body == "PING", kind: kind, logDetails: logDetails, sentAt: ProcessInfo.processInfo.systemUptime)
                        self.send(payload, token, id: id, logDetails: logDetails)
                    }
                    if let permit { try permit.enqueue(enqueue) } else { enqueue() }
                    // Logging stays outside the final input permit's locked send fence.
                    if logDetails { diagnostics.record("send.enqueued id=\(id) kind=\(kind) bytes=\(payload.utf8.count + 1); arguments omitted", attempt: token) }
                    timeout(token, id: id, seconds: body.hasPrefix("DRAG ") ? 3 : 1)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: { Task { await self.cancel(token) } }
    }
    func stop() async {
        diagnostics.record("client.stop requested tcpReady=\(tcpReady) greetingReady=\(ready) pending=\(pending.count)", attempt: generation)
        // Best effort release. Disconnect also revokes the device's lease.
        if ready { try? await command("STOP") }
        fail(.stopped)
    }
    private func send(_ line: String, _ token: UUID, id: UInt64, logDetails: Bool) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { [weak self, diagnostics] error in
            if error != nil || logDetails { diagnostics.record("send.processed id=\(id) error=\(error.map { String(describing: $0) } ?? "none") (not device ACK)", attempt: token) }
            if let error { Task { await self?.transportFailed(token, error: error) } }
        })
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, complete, error in
            Task { await self?.consume(data, closed: complete || error != nil, error: error, token: token) }
        }
    }
    private func consume(_ data: Data?, closed: Bool, error: NWError?, token: UUID) {
        guard generation == token else { return }
        receivedBytes += data?.count ?? 0
        if !ready || closed {
            diagnostics.record("receive bytes=\(data?.count ?? 0) total=\(receivedBytes) closed=\(closed) error=\(error.map { String(describing: $0) } ?? "none"); payload omitted", attempt: token)
        }
        if let data { incoming.append(data) }
        guard incoming.count <= 2048 else { fail(.protocolViolation("USB 回复过长")); return }
        while let newline = incoming.firstIndex(of: 10) {
            let bytes = incoming[..<newline]; incoming.removeSubrange(...newline)
            guard bytes.count <= 256, let line = String(data: bytes, encoding: .ascii) else { fail(.protocolViolation("USB 回复格式错误")); return }
            do { try handle(line, token) } catch { fail((error as? AppError) ?? .unknownOutcome); return }
        }
        if closed { transportFailed(token, error: error) } else if generation == token { receive(token) }
    }
    private func handle(_ line: String, _ token: UUID) throws {
        receivedLines += 1
        if !ready {
            supportsHID = try USBWire.supportsHID(line); ready = true
            diagnostics.record("greeting.valid protocol=PA2 hid=\(supportsHID)", attempt: token)
            connectWaiter?.resume(); connectWaiter = nil; return
        }
        let (id, phase) = try USBWire.parseACK(line)
        guard var request = pending[id] else {
            throw AppError.protocolViolation("USB ACK 命令 ID 不匹配")
        }
        if request.logDetails {
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - request.sentAt) * 1000)
            diagnostics.record("ack id=\(id) kind=\(request.kind) phase=\(phase) elapsedMs=\(elapsed)", attempt: token)
        }
        if try USBWire.acceptACK(phase, needsReceipt: request.needsReceipt, received: &request.received) {
            if request.isPing { health.receivedPing(token); pingReplies += 1 }
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
        if let id, let request = pending[id] {
            diagnostics.record("timeout.receipt id=\(id) kind=\(request.kind) received=\(request.received) inputInFlight=\(pending.values.contains { $0.needsReceipt })", attempt: token)
            fail(USBWire.receiptTimeout(isPing: request.isPing, inputInFlight: pending.values.contains { $0.needsReceipt }))
        } else if id == nil, !ready {
            diagnostics.record("timeout.greeting 3s receivedBytes=\(receivedBytes)", attempt: token)
            fail(.unavailable("TCP 已接通，但 3 秒内未收到 USB 设备的 PA2 应答。请检查固件版本。\(USBWire.pathDetails(lastPath))"))
        }
    }
    private func transportFailed(_ token: UUID, error: NWError?) {
        if generation == token {
            diagnostics.record("transport.failed error=\(error.map { String(describing: $0) } ?? "closed")", attempt: token)
            fail(USBWire.transportError(error, inputInFlight: pending.values.contains { $0.needsReceipt }, path: lastPath))
        }
    }
    private func cancel(_ token: UUID) { if generation == token { fail(.stopped) } }
    private func fail(_ error: AppError) {
        health.invalidate(); keepalive?.cancel(); keepalive = nil
        if connection != nil {
            diagnostics.record("connection.close reason=\(error.localizedDescription) tcpReady=\(tcpReady) greetingReady=\(ready) sent=\(nextID) receivedBytes=\(receivedBytes) receivedLines=\(receivedLines) pingReplies=\(pingReplies) pending=\(pending.count)", attempt: generation)
            for id in pending.keys.sorted() {
                guard let request = pending[id] else { continue }
                diagnostics.record("pending id=\(id) kind=\(request.kind) received=\(request.received) input=\(request.needsReceipt)", attempt: generation)
            }
        }
        for monitor in pathMonitors { monitor.cancel() }
        pathMonitors.removeAll()
        generation = UUID(); ready = false; tcpReady = false; supportsHID = false; lastWaitingError = nil; lastPath = nil
        receivedBytes = 0; receivedLines = 0; pingReplies = 0
        connection?.cancel(); connection = nil; incoming.removeAll(); nextID = 0
        connectWaiter?.resume(throwing: error); connectWaiter = nil
        let waiting = pending; pending.removeAll()
        for request in waiting.values { request.continuation.resume(throwing: error) }
    }
}
