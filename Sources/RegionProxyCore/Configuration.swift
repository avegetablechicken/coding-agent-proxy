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
    public let account_upstream_base_url: String
    public let api_key_upstream_base_url: String
    public let request_timeout_seconds: Double
    public let proxies: [String: String]
    public let accounts: [String: String]
    public let providers: [APIKeyProvider]
    public let account_fallback_proxy: String?
    public let openai_fallback_proxy: String?
    public let mcp_fallback_proxy: String?

    enum CodingKeys: String, CodingKey {
        case base_url, routing, listen_port, auth_file, account_upstream_base_url, upstream_base_url, request_timeout_seconds, proxies, accounts, api_key_providers, openai_fallback_proxy, api_key_upstream_base_url, mcp_fallback_proxy
    }

    private struct BaseURLs: Codable {
        let account: String?
        let api_key: String?
    }

    private struct Routing: Codable {
        let account: [String: String]?
        let api_key: [APIKeyProvider]?
        let account_fallback: String?
        let api_key_fallback: String?
        let mcp_fallback: String?
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let urls = try values.decodeIfPresent(BaseURLs.self, forKey: .base_url)
        let routing = try values.decodeIfPresent(Routing.self, forKey: .routing)
        if values.contains(.base_url), [.account_upstream_base_url, .upstream_base_url, .api_key_upstream_base_url].contains(where: values.contains) {
            throw ProxyError("Do not mix base_url with legacy upstream fields.")
        }
        if values.contains(.routing), [.accounts, .api_key_providers, .openai_fallback_proxy, .mcp_fallback_proxy].contains(where: values.contains) {
            throw ProxyError("Do not mix routing with legacy route fields.")
        }
        listen_port = try values.decode(UInt16.self, forKey: .listen_port)
        auth_file = try values.decodeIfPresent(String.self, forKey: .auth_file) ?? ""
        guard !(values.contains(.account_upstream_base_url) && values.contains(.upstream_base_url)) else {
            throw ProxyError("Use account_upstream_base_url only; do not also set legacy upstream_base_url.")
        }
        account_upstream_base_url = try urls?.account ?? values.decodeIfPresent(String.self, forKey: .account_upstream_base_url)
            ?? values.decodeIfPresent(String.self, forKey: .upstream_base_url) ?? "https://chatgpt.com/backend-api"
        api_key_upstream_base_url = try urls?.api_key ?? values.decodeIfPresent(String.self, forKey: .api_key_upstream_base_url) ?? "https://api.openai.com/v1"
        request_timeout_seconds = try values.decode(Double.self, forKey: .request_timeout_seconds)
        proxies = try values.decodeIfPresent([String: String].self, forKey: .proxies) ?? [:]
        accounts = try routing?.account ?? values.decodeIfPresent([String: String].self, forKey: .accounts) ?? [:]
        providers = try routing?.api_key ?? values.decodeIfPresent([APIKeyProvider].self, forKey: .api_key_providers) ?? []
        account_fallback_proxy = routing?.account_fallback
        openai_fallback_proxy = try routing?.api_key_fallback ?? values.decodeIfPresent(String.self, forKey: .openai_fallback_proxy)
        mcp_fallback_proxy = try routing?.mcp_fallback ?? values.decodeIfPresent(String.self, forKey: .mcp_fallback_proxy)
    }

    public static func read(_ path: String) throws -> Configuration {
        let text: String
        do { text = try String(contentsOfFile: path, encoding: .utf8) }
        catch { throw ProxyError("Cannot read configuration file.") }
        return try parse(text)
    }

    public func canonicalYAML() throws -> String {
        struct Output: Encodable {
            let listen_port: UInt16
            let auth_file: String?
            let request_timeout_seconds: Double
            let base_url: BaseURLs
            let proxies: [String: String]
            let routing: Routing
        }
        let accountBase = account_upstream_base_url.hasSuffix("/backend-api/codex")
            ? String(account_upstream_base_url.dropLast("/codex".count)) : account_upstream_base_url
        return try YAMLEncoder().encode(Output(listen_port: listen_port, auth_file: auth_file.isEmpty ? nil : auth_file,
            request_timeout_seconds: request_timeout_seconds,
            base_url: BaseURLs(account: accountBase, api_key: api_key_upstream_base_url), proxies: proxies,
            routing: Routing(account: accounts.isEmpty ? nil : accounts, api_key: providers.isEmpty ? nil : providers,
                             account_fallback: account_fallback_proxy, api_key_fallback: openai_fallback_proxy,
                             mcp_fallback: mcp_fallback_proxy)))
    }

    public static func parse(_ text: String) throws -> Configuration {
        let result: Configuration
        do {
            let allowed: Set<String> = ["base_url", "routing", "listen_port", "auth_file", "account_upstream_base_url", "upstream_base_url", "request_timeout_seconds", "proxies", "accounts", "api_key_providers", "openai_fallback_proxy", "api_key_upstream_base_url", "mcp_fallback_proxy"]
            guard let root = try compose(yaml: text)?.mapping,
                  root.keys.allSatisfy({ $0.string.map { allowed.contains($0) } == true }) else {
                throw ProxyError("Unknown configuration field.")
            }
            result = try YAMLDecoder().decode(Configuration.self, from: text)
            for (node, keys) in [(root["base_url"], Set(["account", "api_key"])),
                                 (root["routing"], Set(["account", "api_key", "account_fallback", "api_key_fallback", "mcp_fallback"]))] {
                if let node {
                    guard let mapping = node.mapping,
                          mapping.keys.allSatisfy({ $0.string.map { keys.contains($0) } == true }) else {
                        throw ProxyError("Unknown nested configuration field.")
                    }
                }
            }
            let nodes = (root["routing"]?.mapping?["api_key"] ?? root["api_key_providers"])?.sequence.map { Array($0) } ?? []
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
              (1...3600).contains(result.request_timeout_seconds) else { throw ProxyError("Invalid port or timeout (1–3600 seconds).") }
        try validateUpstream(result.account_upstream_base_url)
        try validateUpstream(result.api_key_upstream_base_url)
        guard result.auth_file.isEmpty == (result.accounts.isEmpty && result.account_fallback_proxy == nil) else {
            throw ProxyError("ChatGPT routing requires auth_file and account mappings or account_fallback.")
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
        for (name, value) in [("account_fallback", result.account_fallback_proxy),
                              ("api_key_fallback", result.openai_fallback_proxy), ("mcp_fallback", result.mcp_fallback_proxy)] {
            if let fallback = value {
                guard !fallback.isEmpty, fallback == "none" || result.proxies[fallback] != nil else {
                    throw ProxyError("routing.\(name) must select an existing proxy or none.")
                }
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

    public static func redactedProxyEndpoint(_ value: String) -> String {
        if value == "none" { return value }
        guard var url = URLComponents(string: value) else { return "<invalid-proxy>" }
        url.user = nil
        url.password = nil
        return url.string ?? "<invalid-proxy>"
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
              url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ProxyError("Invalid proxy URL: use http/https/socks5://[username:password@]host:port.")
        }
        if url.user != nil || url.password != nil {
            guard let username = url.user, !username.isEmpty, let password = url.password,
                  (username + password).unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
                  scheme == "socks5" || !username.contains(":"),
                  scheme != "socks5" || ((1...255).contains(username.utf8.count) && (1...255).contains(password.utf8.count)) else {
                throw ProxyError("Invalid proxy credentials: supply username and password without control characters; SOCKS5 fields must be 1–255 UTF-8 bytes and HTTP usernames cannot contain a colon.")
            }
        }
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: UInt16(port))!)
        var proxy = scheme == "socks5"
            ? Network.ProxyConfiguration(socksv5Proxy: endpoint)
            : Network.ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: scheme == "https" ? NWProtocolTLS.Options() : nil)
        proxy.allowFailover = false
        proxy.matchDomains = [""]
        proxy.excludedDomains = []
        if let username = url.user, let password = url.password {
            proxy.applyCredential(username: username, password: password)
        }
        return proxy
    }

    /// Load each credential once and select only by the incoming Bearer token.
    public func resolveRoute(authorization: String?, allowOpenAIFallback: Bool = true, loadIdentity: (() throws -> Identity)? = nil) throws -> CredentialRoute {
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
                let credential = try provider.resolveCredential(defaultUpstream: api_key_upstream_base_url, allowShellLookup: matchedIdentity == nil)
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
                proxy: try proxyName(for: identity), upstream: account_upstream_base_url)
        }
        if let route = matches.first { return route }
        if allowOpenAIFallback, let proxy = openai_fallback_proxy {
            return CredentialRoute(token: token, accountID: nil, provider: "openai-fallback",
                                   proxy: proxy, upstream: api_key_upstream_base_url)
        }
        if unavailable { throw ProxyError("No matching route; one or more credential sources are unavailable.") }
        throw RouteRejection(status: 401, message: "Bearer token does not match a configured credential.")
    }

    /// Public documentation requests can proceed without a model credential.
    /// Only an exact, unambiguous credential match inherits a model route.
    public func resolveMCPRoute(authorization: String?, accountID: String? = nil,
                                loadIdentity: (() throws -> Identity)? = nil) -> (credential: CredentialRoute?, proxy: String) {
        if let route = try? resolveRoute(authorization: authorization, allowOpenAIFallback: false, loadIdentity: loadIdentity),
           accountID == nil || accountID == route.accountID,
           route.proxy == "none" || proxies[route.proxy] != nil {
            return (route, route.proxy)
        }
        return (nil, mcp_fallback_proxy ?? "none")
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
        guard let name = accounts[identity.accountID] ?? identity.usernames.lazy.compactMap({ accounts[$0] }).first ?? account_fallback_proxy else {
            throw ProxyError("Current account has no proxy mapping; forwarding refused.")
        }
        return name
    }
}

public struct APIKeyProvider: Codable, Sendable {
    public let upstream_base_url: String?
    public var name: String { providerID ?? api_key_env ?? "" }
    public let proxy: String
    public let api_key_env: String?
    public let api_key_file: String?
    public let providerID: String?

    enum CodingKeys: String, CodingKey {
        case name, proxy, upstream_base_url, api_key_env, api_key_file
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(providerID, forKey: .name)
        try values.encode(proxy, forKey: .proxy)
        try values.encodeIfPresent(upstream_base_url, forKey: .upstream_base_url)
        try values.encodeIfPresent(api_key_env, forKey: .api_key_env)
        try values.encodeIfPresent(api_key_file, forKey: .api_key_file)
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
                                  defaultUpstream: String = "https://api.openai.com/v1", allowShellLookup: Bool = true) throws -> (key: String, upstream: String) {
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
        guard let variable = api_key_env ?? definition?.env_key else {
            throw ProxyError("API Key environment variable is unavailable.")
        }
        guard environment[variable] != nil || allowShellLookup else {
            throw ProxyError("API Key environment variable is unavailable.")
        }
        let raw = try environment[variable] ?? ShellEnvironment.value(for: variable, environment: environment)
        let key = try Self.validatedKey(raw)
        // Codex's built-in model URL may point back at this listener. Its API
        // route uses our API default instead; custom providers retain their URL.
        let providerUpstream = definition?.id == "openai" ? nil : definition?.base_url
        let upstream = try Configuration.unwrappedUpstream(upstream_base_url ?? providerUpstream ?? defaultUpstream)
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
    public let usernames: [String]

    public init(accountID: String, accessToken: String, usernames: [String] = []) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.usernames = usernames
    }

    // Metadata comes only from the saved login, never from an incoming JWT.
    private static func claims(_ token: String?) -> [String: Any] {
        guard let token else { return [:] }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return claims
    }

    public static func parse(_ data: Data) throws -> Identity {
        struct Auth: Decodable {
            struct Tokens: Decodable { let account_id: String; let access_token: String; let id_token: String? }
            let tokens: Tokens
        }
        guard let auth = try? JSONDecoder().decode(Auth.self, from: data),
              !auth.tokens.account_id.isEmpty, !auth.tokens.access_token.isEmpty,
              !auth.tokens.account_id.contains(where: { $0.isWhitespace || $0.isNewline }),
              !auth.tokens.access_token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ProxyError("auth_file requires nonempty tokens.account_id and tokens.access_token (ChatGPT login).")
        }
        let accessClaims = claims(auth.tokens.access_token)
        let profile = accessClaims["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let idClaims = claims(auth.tokens.id_token)
        let usernames = ["email", "preferred_username", "name"].compactMap { key -> String? in
            let value = (profile[key] as? String) ?? (accessClaims[key] as? String) ?? (idClaims[key] as? String)
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return value
        }
        return Identity(accountID: auth.tokens.account_id, accessToken: auth.tokens.access_token, usernames: usernames)
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
