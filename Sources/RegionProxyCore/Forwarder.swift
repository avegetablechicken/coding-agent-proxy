import Foundation

/// Provider-specific credential loading is isolated from the HTTP transport.
public protocol IdentitySource: Sendable {
    func load(configuration: Configuration) throws -> Identity
}

public struct CodexIdentitySource: IdentitySource {
    public init() {}
    public func load(configuration: Configuration) throws -> Identity { try configuration.identity() }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor Forwarder {
    public static let docsMCPPath = "/mcp/openaiDeveloperDocs"
    public static let docsMCPUpstream = "https://developers.openai.com/mcp"
    private let config: Configuration
    private let identitySource: any IdentitySource
    private let logger: RequestLogger?
    private var sessions: [String: URLSession] = [:]
    private let proxyProbe: (@Sendable (String, URL, Double) async throws -> Bool)?
    private let sessionConfiguration: @Sendable () -> URLSessionConfiguration

    public init(configuration: Configuration, identitySource: any IdentitySource = CodexIdentitySource(), logger: RequestLogger? = nil,
                sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral },
                proxyProbe: (@Sendable (String, URL, Double) async throws -> Bool)? = nil) {
        self.proxyProbe = proxyProbe
        self.config = configuration
        self.identitySource = identitySource
        self.logger = logger
        self.sessionConfiguration = sessionConfiguration
    }

    /// Startup snapshot only; each request still reads and logs its own routing decision.
    public func logCurrentRoute() {
        if !config.auth_file.isEmpty {
            do {
                let identity = try self.identitySource.load(configuration: self.config)
                let name = try config.proxyName(for: identity)
                logger?.write("current_route", ["account_id": identity.accountID, "proxy": name.label,
                                               "proxy_endpoint": name.candidates.map { Configuration.redactedProxyEndpoint(config.proxyEndpoint(for: $0)) }.joined(separator: ", ")])
            } catch {
                logger?.write("route_unavailable", ["reason": (error as? ProxyError)?.message ?? "Cannot read current account route."])
            }
        }
        for provider in config.providers {
            var providerFields = ["provider": provider.name, "proxy": provider.proxy.label,
                                  "proxy_endpoint": provider.proxy.candidates.map { Configuration.redactedProxyEndpoint(config.proxyEndpoint(for: $0)) }.joined(separator: ", ")]
            do {
                _ = try provider.resolveCredential(defaultUpstream: config.api_key_upstream_base_url)
                logger?.write("current_route", providerFields)
            } catch {
                providerFields["reason"] = (error as? ProxyError)?.message ?? "Cannot read provider credential."
                logger?.write("route_unavailable", providerFields)
            }
        }
    }

    public static func upstreamURL(base: String, target: String, chatGPTBackend: Bool = false) throws -> URL {
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let decoded = target.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.split(separator: "/").contains(".."),
              !target.contains("#") else { throw ProxyError("Invalid request target.") }
        if chatGPTBackend, var backend = URLComponents(string: base),
           ["backend-api", "backend-api/codex"].contains(backend.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            backend.path = "/backend-api"
            guard let root = backend.string else { throw ProxyError("Invalid ChatGPT backend URL.") }
            if target.hasPrefix("/https://") || target.hasPrefix("/http://") {
                return try upstreamURL(base: root, target: target)
            }
            let destination: String
            if target.hasPrefix("/backend-api/") {
                backend.path = ""
                guard let origin = backend.string else { throw ProxyError("Invalid ChatGPT origin.") }
                destination = origin + target
            } else {
                let suffix = target.hasPrefix("/v1/") ? String(target.dropFirst(3)) : target
                destination = root + (suffix.hasPrefix("/codex/") ? "" : "/codex") + suffix
            }
            guard let url = URL(string: destination) else { throw ProxyError("Invalid ChatGPT request URL.") }
            return url
        }
        if target.hasPrefix("/https://") || target.hasPrefix("/http://") {
            guard let destination = URLComponents(string: String(target.dropFirst())),
                  let configured = URLComponents(string: base),
                  destination.scheme == "https", destination.user == nil, destination.password == nil,
                  destination.fragment == nil,
                  destination.host?.lowercased() == configured.host?.lowercased(),
                  (destination.port ?? 443) == (configured.port ?? 443) else {
                throw ProxyError("Explicit upstream must match the credential's configured HTTPS upstream.")
            }
            let root = configured.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let prefix = root.isEmpty ? "" : "/" + root
            guard destination.path == prefix || destination.path.hasPrefix(prefix + "/"),
                  let url = destination.url else {
                throw ProxyError("Explicit upstream path is outside the configured API base.")
            }
            return url
        }
        var suffix = target
        for prefix in ["/backend-api/codex", "/v1"] {
            if suffix.hasPrefix(prefix + "/") { suffix = String(suffix.dropFirst(prefix.count)); break }
        }
        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + suffix) else {
            throw ProxyError("Invalid upstream URL.")
        }
        return url
    }

    /// Only the two read-only account queries used by Codex /status are exposed.
    public static func accountQuerySuffix(target: String) -> String? {
        let explicit = target.hasPrefix("/https://") || target.hasPrefix("/http://")
        guard let components = URLComponents(string: explicit ? String(target.dropFirst()) : target) else { return nil }
        switch components.path {
        case "/backend-api/wham/usage": return "/wham/usage"
        case "/backend-api/wham/rate-limit-reset-credits":
            return "/wham/rate-limit-reset-credits"
        default: return nil
        }
    }

    public static func accountQueryURL(base: String, target: String) throws -> URL {
        guard let suffix = accountQuerySuffix(target: target),
              var backend = URLComponents(string: base), ["/backend-api", "/backend-api/codex"].contains(backend.path) else {
            throw ProxyError("Account queries require a ChatGPT /backend-api upstream.")
        }
        backend.path = "/backend-api"
        guard let root = backend.string else { throw ProxyError("Invalid ChatGPT backend URL.") }
        if target.hasPrefix("/https://") || target.hasPrefix("/http://") {
            let url = try upstreamURL(base: root, target: target)
            guard url.path == backend.path + suffix else { throw ProxyError("Unsupported account query path.") }
            return url
        }
        guard let query = URLComponents(string: target), !target.hasPrefix("//"), query.fragment == nil,
              !target.contains("\\"), target.removingPercentEncoding?.contains("\\") == false else {
            throw ProxyError("Invalid account query target.")
        }
        backend.path += suffix
        backend.percentEncodedQuery = query.percentEncodedQuery
        guard let url = backend.url else { throw ProxyError("Invalid account query URL.") }
        return url
    }

    public static func forwardHeaders(_ headers: [String: String]) -> [String: String] {
        var excluded: Set<String> = ["host", "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                     "te", "trailer", "transfer-encoding", "upgrade", "content-length",
                                     "authorization", "x-api-key", "api-key", "chatgpt-account-id", "cookie", "accept-encoding"]
        for name in (headers["connection"] ?? "").split(separator: ",") {
            excluded.insert(name.trimmingCharacters(in: .whitespaces).lowercased())
        }
        return headers.filter { !excluded.contains($0.key.lowercased()) }
    }

    public func handle(_ incoming: HTTPRequest, client: HTTPConnection) async {
        if incoming.method == "GET", incoming.target == "/health" {
            try? await client.write(Data("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"ok\":true}".utf8))
            return
        }
        let began = DispatchTime.now().uptimeNanoseconds
        var fields = ["request_id": UUID().uuidString.lowercased(), "method": incoming.method,
                      "path": String(incoming.target.split(separator: "?", maxSplits: 1).first ?? "/")]
        var outcome = "request_failed"
        var stage = "configuration"
        var status = 502
        var receivedBytes = 0
        logger?.write("request_received", fields)
        defer {
            fields["status"] = String(status)
            fields["duration_ms"] = String((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            fields["received_bytes"] = String(receivedBytes)
            fields["stage"] = stage
            logger?.write(outcome, fields)
        }
        if incoming.headers["upgrade"] != nil {
            status = 426
            outcome = "request_rejected"
            fields["reason"] = "websocket_unsupported"
            await client.error(status: 426, message: "Use HTTP/SSE; WebSocket upgrades are unsupported.")
            return
        }
        var started = false
        do {
            // Routing configuration is immutable; credentials still refresh per request.
            stage = "authorization"
            let requestPath = String(incoming.target.split(separator: "?", maxSplits: 1).first ?? "")
            let docsMCP = requestPath == Self.docsMCPPath
            let accountQuery = Self.accountQuerySuffix(target: incoming.target) != nil
            let route: CredentialRoute?
            let name: ProxyChoice
            if docsMCP {
                let selection = config.resolveMCPRoute(authorization: incoming.headers["authorization"],
                                                       accountID: incoming.headers["chatgpt-account-id"]) {
                    try self.identitySource.load(configuration: self.config)
                }
                route = selection.credential
                name = selection.proxy
                fields["routing"] = route == nil ? "mcp_fallback" : "credential"
                fields["service"] = "openaiDeveloperDocs"
            } else {
                do {
                    let selected = try config.resolveRoute(authorization: incoming.headers["authorization"]) {
                        try self.identitySource.load(configuration: self.config)
                    }
                    route = selected
                    name = selected.proxy
                } catch let rejection as RouteRejection {
                    status = rejection.status
                    outcome = "request_rejected"
                    fields["reason"] = rejection.message
                    await client.error(status: status, message: rejection.message)
                    return
                }
            }
            fields["account_id"] = route?.accountID
            fields["provider"] = route?.provider
            if !docsMCP, let expected = route?.accountID, let account = incoming.headers["chatgpt-account-id"], account != expected {
                status = 409
                outcome = "request_rejected"
                fields["reason"] = "account_mismatch"
                await client.error(status: 409, message: "Account changed; retry with the current login.")
                return
            }
            stage = "routing"
            fields["proxy"] = name.label
            stage = "request"
            if requestPath.hasPrefix("/mcp/"), !docsMCP {
                status = 404
                outcome = "request_rejected"
                await client.error(status: status, message: "Unknown MCP endpoint.")
                return
            }
            if docsMCP, !["GET", "POST", "DELETE"].contains(incoming.method) {
                status = 405
                outcome = "request_rejected"
                await client.error(status: status, message: "MCP supports GET, POST and DELETE.")
                return
            }
            let url: URL
            if accountQuery {
                guard let route, route.accountID != nil else {
                    status = 403
                    outcome = "request_rejected"
                    await client.error(status: status, message: "Account usage queries require a matched ChatGPT login credential.")
                    return
                }
                guard incoming.method == "GET" else {
                    status = 405
                    outcome = "request_rejected"
                    await client.error(status: status, message: "Account usage queries support GET only.")
                    return
                }
                url = try Self.accountQueryURL(base: route.upstream, target: incoming.target)
                fields["service"] = "chatgptUsage"
            } else if docsMCP {
                // Only this fixed, public MCP destination is allowed. Model credentials
                // select the local route but must never be sent to the documentation site.
                guard !incoming.target.contains("#"),
                      let destination = URL(string: Self.docsMCPUpstream + incoming.target.dropFirst(Self.docsMCPPath.count)) else {
                    throw ProxyError("Invalid MCP request target.")
                }
                url = destination
            } else {
                guard let route else { throw ProxyError("Missing model route.") }
                url = try Self.upstreamURL(base: route.upstream, target: incoming.target, chatGPTBackend: route.accountID != nil)
            }
            var request = URLRequest(url: url)
            request.httpMethod = incoming.method
            request.httpBody = incoming.body.isEmpty ? nil : incoming.body
            let mcpHeaders: Set<String> = ["accept", "content-type", "mcp-session-id", "mcp-protocol-version", "last-event-id"]
            for (key, value) in Self.forwardHeaders(incoming.headers) where !docsMCP || mcpHeaders.contains(key.lowercased()) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if !docsMCP, let route {
                request.setValue("Bearer \(route.token)", forHTTPHeaderField: "Authorization")
                if let accountID = route.accountID {
                    request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
                }
            }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            stage = "proxy_selection"
            let selected = try await selectProxy(name, destination: url, fields: fields)
            let proxyURL = config.proxyEndpoint(for: selected)
            fields["proxy"] = selected
            fields["proxy_endpoint"] = Configuration.redactedProxyEndpoint(proxyURL)
            let session = try session(proxyURL: proxyURL, timeout: config.request_timeout_seconds)
            logger?.write("route_selected", fields)
            stage = "upstream_connect"
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw ProxyError("Invalid upstream response.") }
            status = http.statusCode
            var responseFields = fields
            responseFields["status"] = String(status)
            responseFields["headers_ms"] = String((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
            logger?.write("upstream_response", responseFields)
            stage = "streaming"
            // Cancellation closes the upstream task even while waiting for the next SSE event.
            try await withTaskCancellationHandler {
                let noBody = incoming.method == "HEAD" || [204, 304].contains(http.statusCode)
                var header = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\r\nConnection: close\r\n"
                if !noBody { header += "Transfer-Encoding: chunked\r\n" }
                var responseHeaders: [String: String] = [:]
                for (key, value) in http.allHeaderFields { responseHeaders[String(describing: key).lowercased()] = String(describing: value) }
                // URLSession transparently decompresses responses, so do not retain encoding/length.
                responseHeaders.removeValue(forKey: "content-encoding")
                for (key, value) in Self.forwardHeaders(responseHeaders) where !value.contains("\r") && !value.contains("\n") {
                    header += "\(key): \(value)\r\n"
                }
                started = true
                try await client.write(Data((header + "\r\n").utf8))
                if noBody { return }
                var chunk = Data()
                let sse = responseHeaders["content-type"]?.lowercased().contains("text/event-stream") == true
                for try await byte in bytes {
                    try Task.checkCancellation()
                    receivedBytes += 1
                    chunk.append(byte)
                    if chunk.count >= 16 * 1024 || (sse && byte == 10) {
                        try await client.write(Self.chunk(chunk))
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { try await client.write(Self.chunk(chunk)) }
                try await client.write(Data("0\r\n\r\n".utf8))
            } onCancel: { bytes.task.cancel() }
            stage = "complete"
            outcome = "request_finished"
        } catch {
            fields["reason"] = (error as? ProxyError)?.message ?? "transport_error"
            if !(error is ProxyError) {
                let error = error as NSError
                fields["error_domain"] = error.domain
                fields["error_code"] = String(error.code)
            }
            fields["response_started"] = String(started)
            if !started { status = 502 }
            // Never expose tokens, account IDs, request bodies or authenticated URLs in errors.
            if !started {
                let message = (error as? ProxyError)?.message ?? "Upstream transport failed; no direct fallback was attempted."
                await client.error(status: 502, message: message)
            }
        }
    }

    private func selectProxy(_ selection: ProxyChoice, destination: URL, fields: [String: String]) async throws -> String {
        guard selection.isList else { return selection.candidates[0] }
        let timeout = min(5, config.request_timeout_seconds)
        var origin = URLComponents(url: destination, resolvingAgainstBaseURL: false)!
        origin.path = "/"
        origin.query = nil
        origin.fragment = nil
        let probeURL = origin.url!
        for name in selection.candidates {
            try Task.checkCancellation()
            let endpoint = config.proxyEndpoint(for: name)
            var available = false
            do {
                if let proxyProbe {
                    available = try await proxyProbe(endpoint, probeURL, timeout)
                } else {
                    var request = URLRequest(url: probeURL)
                    request.httpMethod = "HEAD"
                    let probeSession = try session(proxyURL: endpoint, timeout: timeout)
                    let (_, response) = try await probeSession.data(for: request)
                    if let http = response as? HTTPURLResponse {
                        available = (200..<500).contains(http.statusCode) && http.statusCode != 407
                    }
                }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
            }
            var event = fields
            event["proxy"] = name
            event["proxy_endpoint"] = Configuration.redactedProxyEndpoint(endpoint)
            event["available"] = available ? "true" : "false"
            logger?.write("proxy_probe", event)
            if available { return name }
        }
        throw ProxyError("No available outbound proxy in the configured list.")
    }

    private static func chunk(_ data: Data) -> Data {
        Data("\(String(data.count, radix: 16))\r\n".utf8) + data + Data("\r\n".utf8)
    }

    private func session(proxyURL: String, timeout: Double) throws -> URLSession {
        let key = "\(proxyURL)|\(timeout)"
        if let session = sessions[key] { return session }
        let configuration = sessionConfiguration()
        try Configuration.configureTransport(configuration, endpoint: proxyURL)
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        if sessions.count >= 32, let oldest = sessions.keys.sorted().first {
            sessions.removeValue(forKey: oldest)?.finishTasksAndInvalidate()
        }
        sessions[key] = session
        return session
    }
}
