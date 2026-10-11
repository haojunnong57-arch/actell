import Foundation
import CryptoKit
import Security

/// Official route policy. No browser, credential registration, token loading or
/// inference happens until an iOS callback/identity-verification flow is validated.
enum ChatGPTSubscriptionPolicy {
    static let resource = URL(string: "https://api.openai.com/v1")!
    static let authorize = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let token = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let mobileLoginNotice = "通过系统浏览器连接 ChatGPT；身份登录还需订阅额度授权。仅对已授权模型使用套餐额度，不自动改用付费 API。"
    static let usageNotice = "仅获授权的账户／模型使用订阅额度，受套餐与工作区限制。HTTP 请求必须 store=false、stream=true，发送本地上下文；不支持 previous_response_id。"
}

/// Offline-testable authorization attempt. Kept in memory, never serialized or logged.
/// This is preparation for the documented loopback flow, not a live iOS login.
struct ChatGPTAuthorizationAttempt: CustomStringConvertible {
    let redirect: URL
    let state: String
    let nonce: String
    let verifier: String
    let clientID: String?
    var description: String { "ChatGPTAuthorizationAttempt(<redacted>)" }

    init(redirect: URL, clientID: String? = nil) throws {
        guard let parts = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", parts.port.map({ (1...65535).contains($0) }) == true,
              parts.path == "/auth/callback", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              clientID != "dynamic_agent_client" else { throw AppError.invalid("授权回调或注册 ID 无效") }
        self.redirect = redirect; self.clientID = clientID
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AppError.unavailable("无法生成安全授权随机值") }
        return base64url(Data(bytes))
    }
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var challenge: String { Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    func authorizationURL(hostID: UUID) -> URL {
        var parts = URLComponents(url: ChatGPTSubscriptionPolicy.authorize, resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "client_id", value: clientID ?? "dynamic_agent_client"),
            .init(name: "ext_agent_host_id", value: "urn:uuid:" + hostID.uuidString.lowercased()),
            .init(name: "response_type", value: "code"), .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "scope", value: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"),
            .init(name: "resource", value: ChatGPTSubscriptionPolicy.resource.absoluteString),
            .init(name: "state", value: state), .init(name: "nonce", value: nonce),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "code_challenge", value: challenge)
        ]
        if clientID == nil { parts.queryItems?.append(.init(name: "agent_name_hint", value: "Actell")) }
        return parts.url!
    }
    func validateCallback(_ callback: URL) throws -> (code: String, issuedClientID: String) {
        guard var parts = URLComponents(url: callback, resolvingAgainstBaseURL: false), parts.fragment == nil else { throw AppError.invalid("授权回调无效") }
        let items = parts.queryItems ?? []; parts.query = nil
        guard parts.url == redirect else { throw AppError.invalid("授权回调地址不匹配") }
        guard Set(items.map(\.name)).count == items.count else { throw AppError.invalid("授权回调参数重复") }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw AppError.invalid("授权 state 不匹配") }
        if values["error"] != nil { throw AppError.unavailable("授权已取消或被拒绝；未交换凭据") }
        guard let code = values["code"], !code.isEmpty else { throw AppError.invalid("授权码缺失") }
        let issued = values["client_id"] ?? clientID
        guard let issued, !issued.isEmpty, issued != "dynamic_agent_client", clientID == nil || issued == clientID else {
            throw AppError.invalid("授权注册 ID 不匹配")
        }
        return (code, issued)
    }
    /// Call only after JWKS signature, issuer, audience and expiry validation.
    func validateVerifiedNonce(_ verifiedNonce: String) throws {
        guard verifiedNonce == nonce else { throw AppError.invalid("授权 nonce 不匹配") }
    }
}

/// Display-only permission status; never contains credentials or trusts callback scopes.
enum ChatGPTConnectionStatus: Equatable {
    case disconnected, identityOnly, planAuthorized, expired, refreshFailed, revoked, usageLimited, noModels
    static func granted(tokenResponseScopes: Set<String>, expired: Bool) -> Self {
        if expired { return .expired }
        return tokenResponseScopes.isSuperset(of: ["resource.invoke", "chatgpt.tokens.use.direct"]) ? .planAuthorized : .identityOnly
    }
    var message: String {
        switch self {
        case .disconnected: return "未连接 ChatGPT"
        case .identityOnly: return "身份已连接，尚未获订阅额度授权"
        case .planAuthorized: return "已获订阅额度授权；仍需核对可用模型与额度"
        case .expired: return "授权已到期，请重新登录"
        case .refreshFailed: return "授权刷新失败，未发送或重试请求"
        case .revoked: return "授权已撤销，请重新登录"
        case .usageLimited: return "此 App 的订阅额度受限或限流；请查看 ChatGPT 使用设置。未购买额度或改用付费 API"
        case .noModels: return "此账户暂无可用模型"
        }
    }
}
