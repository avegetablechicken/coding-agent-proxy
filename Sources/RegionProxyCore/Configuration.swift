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
    public let api_key_upstream_base_url: String
    public let request_timeout_seconds: Double
    public let proxies: [String: String]
    public let accounts: [String: String]
    public let providers: [APIKeyProvider]
    public let openai_fallback_proxy: String?

    enum CodingKeys: String, CodingKey {
        case listen_port, auth_file, upstream_base_url, request_timeout_seconds, proxies, accounts, api_key_providers, openai_fallback_proxy, api_key_upstream_base_url
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        listen_port = try values.decode(UInt16.self, forKey: .listen_port)
        auth_file = try values.decodeIfPresent(String.self, forKey: .auth_file) ?? ""
        upstream_base_url = try values.decodeIfPresent(String.self, forKey: .upstream_base_url) ?? "https://chatgpt.com/backend-api/codex"
        api_key_upstream_base_url = try values.decodeIfPresent(String.self, forKey: .api_key_upstream_base_url) ?? "https://api.openai.com/v1"
        request_timeout_seconds = try values.decode(Double.self, forKey: .request_timeout_seconds)
        proxies = try values.decodeIfPresent([String: String].self, forKey: .proxies) ?? [:]
        accounts = try values.decodeIfPresent([String: String].self, forKey: .accounts) ?? [:]
        providers = try values.decodeIfPresent([APIKeyProvider].self, forKey: .api_key_providers) ?? []
        openai_fallback_proxy = try values.decodeIfPresent(String.self, forKey: .openai_fallback_proxy)
    }

    public static func read(_ path: String) throws -> Configuration {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw ProxyError("Cannot read configuration file.") }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> Configuration {
        let result: Configuration
        do {
            let allowed: Set<String> = ["listen_port", "auth_file", "upstream_base_url", "request_timeout_seconds", "proxies", "accounts", "api_key_providers", "openai_fallback_proxy", "api_key_upstream_base_url"]
            guard let root = try compose(yaml: text)?.mapping,
                  root.keys.allSatisfy({ $0.string.map { allowed.contains($0) } == true }) else {
                throw ProxyError("Unknown configuration field.")
            }
            result = try YAMLDecoder().decode(Configuration.self, from: text)
            let nodes = root["api_key_providers"]?.sequence.map { Array($0) } ?? []
            for provider in nodes {
                let providerFields: Set<String> = ["name", "proxy", "upstream_base_url", "api_key_env", "api_key_file"]
                guard let mapping = provider.mapping,
                      mapping.keys.allSatisfy({ $0.string.map { providerFields.contains($0) } == true }) else {
                    throw ProxyError("Unknown API Key provider field.")
                }
            }
        }
        catch { throw ProxyError("Invalid YAML configuration; check required fields against config.example.yaml.") }
        guard result.listen_port > 0,
              result.request_timeout_seconds.isFinite,
              (1...3600).contains(result.request_timeout_seconds),
              !result.providers.isEmpty || !result.auth_file.isEmpty || result.openai_fallback_proxy != nil else { throw ProxyError("Invalid port, auth_file or timeout (1–3600 seconds).") }
        try validateUpstream(result.upstream_base_url)
        try validateUpstream(result.api_key_upstream_base_url)
        guard !result.providers.isEmpty || !result.accounts.isEmpty || result.openai_fallback_proxy != nil else {
            throw ProxyError("Configure at least one proxy and credential route.")
        }
        guard result.auth_file.isEmpty == result.accounts.isEmpty else {
            throw ProxyError("ChatGPT routing requires both auth_file and account mappings.")
        }
        for (name, value) in result.proxies {
            guard !name.isEmpty, name != "none" else { throw ProxyError("Proxy names must be nonempty; none is reserved for direct connections.") }
            if value != "none" { _ = try Self.proxyConfiguration(value) }
        }
        for (id, name) in result.accounts {
            guard !id.isEmpty, (name == "none" || result.proxies[name] != nil) else {
                throw ProxyError("Every account must select an existing proxy name or none.")
            }
        }
        if let fallback = result.openai_fallback_proxy {
            guard !fallback.isEmpty, (fallback == "none" || result.proxies[fallback] != nil) else {
                throw ProxyError("openai_fallback_proxy must select an existing proxy or none.")
            }
        }
        for provider in result.providers {
            try validateUpstream(provider.upstream_base_url ?? result.api_key_upstream_base_url)
            guard !provider.name.isEmpty, (provider.proxy == "none" || result.proxies[provider.proxy] != nil),
                  !(provider.api_key_env != nil && provider.api_key_file != nil),
                  provider.api_key_env.map({ !$0.isEmpty }) ?? true,
                  provider.api_key_file.map({ !$0.isEmpty }) ?? true else {
                throw ProxyError("API Key provider requires an identifier, existing proxy and nonempty credential sources; api_key_env and api_key_file cannot be combined.")
            }
        }
        return result
    }

    static func validateUpstream(_ value: String) throws {
        guard let url = URLComponents(string: value),
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
    }

    /// A Codex provider may point at our explicit-path endpoint. Recover only
    /// its embedded HTTPS URL; never send an upstream request to the local wrapper.
    static func unwrappedUpstream(_ value: String) throws -> String {
        guard let outer = URLComponents(string: value), outer.scheme == "http",
              outer.host == "127.0.0.1", outer.port != nil,
              outer.user == nil, outer.password == nil,
              outer.query == nil, outer.fragment == nil,
              outer.percentEncodedPath.hasPrefix("/https://") else {
            try validateUpstream(value)
            return value
        }
        let embedded = String(outer.percentEncodedPath.dropFirst())
        try validateUpstream(embedded)
        return embedded
    }

    public func proxyEndpoint(for name: String) -> String {
        name == "none" ? "none" : proxies[name]!
    }

    static func configureTransport(_ configuration: URLSessionConfiguration, endpoint: String) throws {
        if endpoint == "none" {
            configuration.proxyConfigurations = []
            // Empty proxyConfigurations alone can leave system/PAC proxy discovery enabled.
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
            ]
        } else {
            configuration.connectionProxyDictionary = ["ExceptionsList": [], "ExcludeSimpleHostnames": false]
            configuration.proxyConfigurations = [try proxyConfiguration(endpoint)]
        }
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

    /// Load each credential once and select only by the incoming Bearer token.
    public func resolveRoute(authorization: String?, loadIdentity: (() throws -> Identity)? = nil) throws -> CredentialRoute {
        guard let authorization, authorization.hasPrefix("Bearer "),
              !authorization.dropFirst(7).isEmpty else {
            throw RouteRejection(status: 401, message: "A configured Bearer token is required.")
        }
        let token = String(authorization.dropFirst(7))
        guard token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw RouteRejection(status: 401, message: "Bearer token must not contain whitespace or control characters.")
        }
        var matches: [CredentialRoute] = []
        var matchedIdentity: Identity?
        var unavailable = false
        if !auth_file.isEmpty {
            do {
                let identity = try loadIdentity?() ?? self.identity()
                if token == identity.accessToken { matchedIdentity = identity }
            } catch { unavailable = true }
        }
        for provider in providers {
            do {
                let credential = try provider.resolveCredential(defaultUpstream: api_key_upstream_base_url)
                let key = credential.key
                if token == key {
                    matches.append(CredentialRoute(token: key, accountID: nil, provider: provider.name,
                        proxy: provider.proxy, upstream: credential.upstream))
                }
            } catch { unavailable = true }
        }
        guard matches.count + (matchedIdentity == nil ? 0 : 1) <= 1 else {
            throw RouteRejection(status: 409, message: "Bearer token matches multiple routes; configure distinct credentials.")
        }
        if let identity = matchedIdentity {
            return CredentialRoute(token: identity.accessToken, accountID: identity.accountID, provider: nil,
                proxy: try proxyName(for: identity), upstream: upstream_base_url)
        }
        if let route = matches.first { return route }
        if let proxy = openai_fallback_proxy {
            return CredentialRoute(token: token, accountID: nil, provider: "openai-fallback",
                                   proxy: proxy, upstream: api_key_upstream_base_url)
        }
        if unavailable { throw ProxyError("No matching route; one or more credential sources are unavailable.") }
        throw RouteRejection(status: 401, message: "Bearer token does not match a configured credential.")
    }

    public func checkCredentials() throws {
        var keys = Set<String>()
        if !auth_file.isEmpty {
            let identity = try self.identity()
            _ = try proxyName(for: identity)
            keys.insert(identity.accessToken)
        }
        for provider in providers {
            guard keys.insert(try provider.resolveCredential(defaultUpstream: api_key_upstream_base_url).key).inserted else {
                throw ProxyError("Multiple routes have the same credential.")
            }
        }
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

public struct APIKeyProvider: Decodable, Sendable {
    public let upstream_base_url: String?
    public var name: String { providerID ?? api_key_env ?? "" }
    public let proxy: String
    public let api_key_env: String?
    public let api_key_file: String?
    public let providerID: String?

    enum CodingKeys: String, CodingKey {
        case name, proxy, upstream_base_url, api_key_env, api_key_file
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let explicitName = try values.decodeIfPresent(String.self, forKey: .name)
        let explicitEnv = try values.decodeIfPresent(String.self, forKey: .api_key_env)
        guard explicitName.map({ !$0.isEmpty }) ?? true,
              explicitEnv.map({ !$0.isEmpty }) ?? true,
              explicitName != nil || explicitEnv != nil else {
            throw ProxyError("Specify a nonempty name or api_key_env.")
        }
        providerID = explicitName
        proxy = try values.decode(String.self, forKey: .proxy)
        upstream_base_url = try values.decodeIfPresent(String.self, forKey: .upstream_base_url)
        api_key_file = try values.decodeIfPresent(String.self, forKey: .api_key_file)
        api_key_env = explicitEnv
    }

    public func resolveCredential(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  defaultUpstream: String = "https://api.openai.com/v1") throws -> (key: String, upstream: String) {
        // File-backed routes retain their explicit label and do not require Codex config.
        if let file = api_key_file {
            guard let raw = try? String(contentsOfFile: NSString(string: file).expandingTildeInPath, encoding: .utf8) else {
                throw ProxyError("Cannot read API Key file.")
            }
            let upstream = upstream_base_url ?? defaultUpstream
            try Configuration.validateUpstream(upstream)
            return (try Self.validatedKey(raw), upstream)
        }
        let definitions = try CodexProviderLookup.definitions(environment: environment)
        let named: CodexProviderLookup.Definition?
        if let providerID {
            guard let found = definitions.first(where: { $0.id == providerID }) else {
                throw ProxyError("Codex Provider ID has no API Key configuration.")
            }
            named = found
        } else { named = nil }
        var reversed: CodexProviderLookup.Definition?
        if named == nil, let variable = api_key_env {
            let candidates = definitions.filter { $0.env_key == variable }
            guard candidates.count <= 1 else {
                throw ProxyError("api_key_env matches multiple Codex providers; routing is ambiguous.")
            }
            reversed = candidates.first
        }
        let definition = named ?? reversed
        guard let variable = api_key_env ?? definition?.env_key,
              let raw = environment[variable] else {
            throw ProxyError("API Key environment variable is unavailable.")
        }
        let key = try Self.validatedKey(raw)
        let upstream = try Configuration.unwrappedUpstream(upstream_base_url ?? definition?.base_url ?? defaultUpstream)
        return (key, upstream)
    }

    private static func validatedKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else {
            throw ProxyError("API Key must be a nonempty ASCII token without whitespace or control characters.")
        }
        return key
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

public struct CredentialRoute: Sendable {
    public let token: String
    public let accountID: String?
    public let provider: String?
    public let proxy: String
    public let upstream: String
}

public struct RouteRejection: Error, Sendable {
    public let status: Int
    public let message: String
}
