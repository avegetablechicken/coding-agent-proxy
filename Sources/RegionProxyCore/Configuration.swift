import Foundation
import Network
import Yams

public struct ProxyError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct Configuration: Decodable, Sendable {
    public let listen_port: UInt16
    public let auth_file: String
    public let upstream_base_url: String
    public let request_timeout_seconds: Double
    public let proxies: [String: String]
    public let accounts: [String: String]

    public static func read(_ path: String) throws -> Configuration {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw ProxyError("Cannot read configuration file.") }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> Configuration {
        let result: Configuration
        do {
            let allowed: Set<String> = ["listen_port", "auth_file", "upstream_base_url", "request_timeout_seconds", "proxies", "accounts"]
            guard let root = try compose(yaml: text)?.mapping,
                  root.keys.allSatisfy({ $0.string.map { allowed.contains($0) } == true }) else {
                throw ProxyError("Unknown configuration field.")
            }
            result = try YAMLDecoder().decode(Configuration.self, from: text)
        }
        catch { throw ProxyError("Invalid YAML configuration; check required fields against config.example.yaml.") }
        guard result.listen_port > 0,
              result.request_timeout_seconds.isFinite,
              (1...3600).contains(result.request_timeout_seconds),
              !result.auth_file.isEmpty else { throw ProxyError("Invalid port, auth_file or timeout (1–3600 seconds).") }
        guard let url = URLComponents(string: result.upstream_base_url),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.port != 0 else { throw ProxyError("upstream_base_url must be an HTTPS URL without credentials, query or fragment.") }
        let upstreamHost = host.lowercased()
        guard upstreamHost.contains("."), !upstreamHost.contains(":"),
              !upstreamHost.allSatisfy({ $0.isNumber || $0 == "." }),
              !upstreamHost.hasSuffix("."),
              !["localhost", "local", "internal", "lan"].contains(where: { upstreamHost == $0 || upstreamHost.hasSuffix("." + $0) }) else {
            throw ProxyError("Upstream must use a public service hostname, not an IP or local hostname (URLSession bypasses proxies for loopback).")
        }
        guard !result.proxies.isEmpty, !result.accounts.isEmpty else {
            throw ProxyError("Configure at least one proxy and account mapping.")
        }
        for (name, value) in result.proxies {
            guard !name.isEmpty else { throw ProxyError("Proxy names must not be empty.") }
            _ = try Self.proxyConfiguration(value)
        }
        for (id, name) in result.accounts {
            guard !id.isEmpty, result.proxies[name] != nil else {
                throw ProxyError("Every account must reference an existing proxy name.")
            }
        }
        return result
    }

    public static func proxyConfiguration(_ value: String) throws -> Network.ProxyConfiguration {
        guard let url = URLComponents(string: value),
              let scheme = url.scheme, ["http", "https", "socks5"].contains(scheme),
              let host = url.host, !host.isEmpty, let port = url.port, (1...65535).contains(port),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ProxyError("Invalid proxy URL: use http/https/socks5://host:port without credentials.")
        }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: UInt16(port))!)
        var proxy = scheme == "socks5"
            ? Network.ProxyConfiguration(socksv5Proxy: endpoint)
            : Network.ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: scheme == "https" ? NWProtocolTLS.Options() : nil)
        proxy.allowFailover = false
        proxy.matchDomains = [""]
        proxy.excludedDomains = []
        return proxy
    }

    public func identity() throws -> Identity {
        let path = NSString(string: auth_file).expandingTildeInPath
        let data: Data
        do { data = try Data(contentsOf: URL(fileURLWithPath: path)) }
        catch { throw ProxyError("Cannot read auth_file.") }
        return try Identity.parse(data)
    }

    public func proxyName(for identity: Identity) throws -> String {
        guard let name = accounts[identity.accountID] else {
            throw ProxyError("Current account has no proxy mapping; forwarding refused.")
        }
        return name
    }
}

public struct Identity: Sendable {
    public let accountID: String
    public let accessToken: String

    public static func parse(_ data: Data) throws -> Identity {
        struct Auth: Decodable {
            struct Tokens: Decodable { let account_id: String; let access_token: String }
            let tokens: Tokens
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.account_id.isEmpty, !auth.tokens.access_token.isEmpty,
              !auth.tokens.account_id.contains(where: { $0.isWhitespace || $0.isNewline }),
              !auth.tokens.access_token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ProxyError("auth_file requires nonempty tokens.account_id and tokens.access_token (ChatGPT login).")
        }
        return Identity(accountID: auth.tokens.account_id, accessToken: auth.tokens.access_token)
    }
}
