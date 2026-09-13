import Foundation
import XCTest
@testable import RegionProxyCore

final class CoreTests: XCTestCase {
    let yaml = """
    listen_port: 8787
    auth_file: "~/.codex/auth.json"
    upstream_base_url: "https://chatgpt.com/backend-api/codex"
    request_timeout_seconds: 30
    proxies:
      us: "http://127.0.0.1:8101"
      jp: "socks5://127.0.0.1:8102"
    accounts:
      account-a: us
      account-b: jp
    """

    func testAccountRoutingAndUnknownAccount() throws {
        let config = try Configuration.parse(yaml)
        XCTAssertEqual(try config.proxyName(for: Identity(accountID: "account-a", accessToken: "a")), "us")
        XCTAssertEqual(try config.proxyName(for: Identity(accountID: "account-b", accessToken: "b")), "jp")
        XCTAssertThrowsError(try config.proxyName(for: Identity(accountID: "unknown", accessToken: "a")))
    }

    func testMCPFallbackIsIndependentOfOpenAIFallback() throws {
        let config = try Configuration.parse(yaml + "\nopenai_fallback_proxy: us\nmcp_fallback_proxy: jp")
        let identity = { Identity(accountID: "account-a", accessToken: "known") }
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer known", loadIdentity: identity).proxy, "us")
        for header in [nil, "", "Basic secret", "Bearer unknown", "Bearer two words"] as [String?] {
            let selection = config.resolveMCPRoute(authorization: header, loadIdentity: identity)
            XCTAssertEqual(selection.proxy, "jp")
            XCTAssertNil(selection.credential)
        }
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer known", accountID: "different", loadIdentity: identity).proxy, "jp")
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer known", loadIdentity: {
            throw ProxyError("unavailable")
        }).proxy, "jp")
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer known", loadIdentity: {
            Identity(accountID: "unmapped", accessToken: "known")
        }).proxy, "jp")
        let direct = try Configuration.parse(yaml.replacingOccurrences(of: "account-a: us", with: "account-a: none")
                                            + "\nmcp_fallback_proxy: jp")
        XCTAssertEqual(direct.resolveMCPRoute(authorization: "Bearer known", loadIdentity: identity).proxy, "none")
        let defaults = try Configuration.parse(yaml + "\nopenai_fallback_proxy: us")
        XCTAssertEqual(defaults.resolveMCPRoute(authorization: "Bearer unknown").proxy, "none")
        let onlyMCP = try Configuration.parse("listen_port: 7889\nrequest_timeout_seconds: 30")
        XCTAssertEqual(onlyMCP.resolveMCPRoute(authorization: nil).proxy, "none")
        XCTAssertThrowsError(try onlyMCP.resolveRoute(authorization: "Bearer unknown"))
        for fallback in ["missing", "''"] {
            XCTAssertThrowsError(try Configuration.parse(yaml + "\nmcp_fallback_proxy: \(fallback)"))
        }
    }

    func testOpenAIFallbackRequiresExplicitProxyAndPreservesToken() throws {
        let config = try Configuration.parse(yaml + "\nopenai_fallback_proxy: jp")
        let identity = { Identity(accountID: "account-a", accessToken: "known") }
        let matched = try config.resolveRoute(authorization: "Bearer known", loadIdentity: identity)
        XCTAssertEqual(matched.proxy, "us")
        XCTAssertEqual(matched.accountID, "account-a")
        let loaders: [() throws -> Identity] = [identity, { throw ProxyError("missing auth") }]
        for loader in loaders {
            let route = try config.resolveRoute(authorization: "Bearer unknown", loadIdentity: loader)
            XCTAssertEqual(route.token, "unknown")
            XCTAssertEqual(route.proxy, "jp")
            XCTAssertEqual(route.upstream, "https://api.openai.com/v1")
            XCTAssertEqual(route.provider, "openai-fallback")
            XCTAssertNil(route.accountID)
        }
        for header in [nil, "", "Basic secret", "Bearer ", "Bearer two words"] as [String?] {
            XCTAssertThrowsError(try config.resolveRoute(authorization: header, loadIdentity: identity)) {
                XCTAssertEqual(($0 as? RouteRejection)?.status, 401)
            }
        }
        for value in ["missing", "''"] {
            XCTAssertThrowsError(try Configuration.parse(yaml + "\nopenai_fallback_proxy: \(value)"))
        }
        XCTAssertThrowsError(try Configuration.parse(yaml).resolveRoute(authorization: "Bearer unknown", loadIdentity: identity))
        let fallbackOnly = try Configuration.parse("""
        listen_port: 7889
        request_timeout_seconds: 30
        proxies:
          selected: http://127.0.0.1:8118
        openai_fallback_proxy: selected
        """)
        XCTAssertEqual(try fallbackOnly.resolveRoute(authorization: "Bearer test").proxy, "selected")
    }

    func testExplicitNoneSelectsDirectTransport() throws {
        let config = try Configuration.parse(yaml.replacingOccurrences(of: "account-a: us", with: "account-a: none")
            + "\nopenai_fallback_proxy: none")
        let identity = { Identity(accountID: "account-a", accessToken: "known") }
        for token in ["known", "unknown"] {
            let route = try config.resolveRoute(authorization: "Bearer \(token)", loadIdentity: identity)
            XCTAssertEqual(route.proxy, "none")
            XCTAssertEqual(config.proxyEndpoint(for: route.proxy), "none")
        }
        let alias = try Configuration.parse(yaml.replacingOccurrences(of: "http://127.0.0.1:8101", with: "none"))
        XCTAssertEqual(alias.proxyEndpoint(for: "us"), "none")
        let directOnly = try Configuration.parse("""
        listen_port: 7889
        request_timeout_seconds: 30
        openai_fallback_proxy: none
        """)
        XCTAssertEqual(try directOnly.resolveRoute(authorization: "Bearer key").proxy, "none")
        let transport = URLSessionConfiguration.ephemeral
        transport.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": "unwanted.invalid", "ProxyAutoConfigEnable": 1]
        transport.proxyConfigurations = [try Configuration.proxyConfiguration("http://127.0.0.1:8101")]
        try Configuration.configureTransport(transport, endpoint: "none")
        XCTAssertEqual(transport.proxyConfigurations.count, 0)
        XCTAssertEqual(transport.connectionProxyDictionary?["HTTPEnable"] as? Int, 0)
        XCTAssertEqual(transport.connectionProxyDictionary?["ProxyAutoConfigEnable"] as? Int, 0)
        XCTAssertNil(transport.connectionProxyDictionary?["HTTPProxy"])
        try Configuration.configureTransport(transport, endpoint: "http://127.0.0.1:8101")
        XCTAssertEqual(transport.proxyConfigurations.count, 1)
    }

    func testInvalidConfigurationsFailClosed() throws {
        for text in [yaml.replacingOccurrences(of: "account-a: us", with: "account-a: missing"),
                     yaml.replacingOccurrences(of: "8787", with: "0"),
                     yaml.replacingOccurrences(of: "seconds: 30", with: "seconds: -1"),
                     yaml.replacingOccurrences(of: "https://chatgpt", with: "http://chatgpt"),
                     yaml.replacingOccurrences(of: "chatgpt.com", with: "127.0.0.1"),
                     yaml.replacingOccurrences(of: "chatgpt.com", with: "foo.localhost"),
                     yaml + "\nunknown_option: true", yaml + "\nlisten_port: 8888"] {
            XCTAssertThrowsError(try Configuration.parse(text))
        }
        for proxy in ["", "direct", "http://localhost", "http://user:secret@localhost:8080", "ftp://localhost:8080", "socks5://localhost:0", "http://localhost:8080?q=1"] {
            XCTAssertThrowsError(try Configuration.proxyConfiguration(proxy))
        }
        XCTAssertFalse(try Configuration.proxyConfiguration("http://localhost:8080").allowFailover)
        XCTAssertFalse(try Configuration.proxyConfiguration("https://localhost:8080").allowFailover)
        XCTAssertFalse(try Configuration.proxyConfiguration("socks5://localhost:8080").allowFailover)
    }

    func testAuthSnapshotValidation() throws {
        let identity = try Identity.parse(Data(#"{"tokens":{"account_id":"abc","access_token":"secret"}}"#.utf8))
        XCTAssertEqual(identity.accountID, "abc")
        for value in ["{}", #"{"OPENAI_API_KEY":"secret"}"#, #"{"tokens":{"account_id":"","access_token":"secret"}}"#, #"{"tokens":{"account_id":"abc","access_token":"bad\r\nheader"}}"#] {
            XCTAssertThrowsError(try Identity.parse(Data(value.utf8)))
        }
    }

    func testURLMappingPreservesQueryAndRejectsEscapes() throws {
        let base = "https://chatgpt.com/backend-api/codex"
        for path in ["/responses?x=a%2Fb", "/v1/responses?x=a%2Fb", "/backend-api/codex/responses?x=a%2Fb"] {
            XCTAssertEqual(try Forwarder.upstreamURL(base: base, target: path).absoluteString, base + "/responses?x=a%2Fb")
        }
        for path in ["//evil.test/a", "https://evil.test", "/%2e%2e/secret", "/responses#fragment"] {
            XCTAssertThrowsError(try Forwarder.upstreamURL(base: base, target: path))
        }
    }

    func testHeaderFiltering() {
        let result = Forwarder.forwardHeaders(["connection": "x-private, keep-alive", "x-private": "hidden", "authorization": "secret", "host": "localhost", "content-length": "5", "x-request-id": "abc", "content-type": "application/json"])
        XCTAssertEqual(result, ["x-request-id": "abc", "content-type": "application/json"])
    }

    func testExplicitUpstreamPathPreservesEndpointAndQuery() throws {
        let base = "https://provider.example.com/v1"
        XCTAssertEqual(try Forwarder.upstreamURL(base: base, target: "/https://provider.example.com/v1/models?cursor=a%2Fb").absoluteString,
                       "https://provider.example.com/v1/models?cursor=a%2Fb")
        XCTAssertEqual(try Forwarder.upstreamURL(base: base, target: "/https://provider.example.com/v1/responses").absoluteString,
                       base + "/responses")
        for target in ["/https://evil.example.com/v1/responses", "/http://provider.example.com/v1/responses",
                       "/https://provider.example.com:444/v1/responses", "/https://secret@provider.example.com/v1/responses",
                       "/https://provider.example.com/v10/responses", "/https://provider.example.com/admin",
                       "/https://provider.example.com/v1/%2e%2e/admin"] {
            XCTAssertThrowsError(try Forwarder.upstreamURL(base: base, target: target))
        }
    }

    func testFragmentedBodyAndChunkedUpload() throws {
        let raw = Data("POST /responses?q=1 HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        for offset in 0..<raw.count { XCTAssertNil(try HTTPParser.parse(Data(raw.prefix(offset)))) }
        let parsed = try XCTUnwrap(HTTPParser.parse(raw))
        XCTAssertEqual(parsed.body, Data("hello".utf8))
        XCTAssertEqual(parsed.target, "/responses?q=1")
        let chunked = Data("POST /responses HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3;test=yes\r\nllo\r\n0\r\n\r\n".utf8)
        for offset in 0..<chunked.count { XCTAssertNil(try HTTPParser.parse(Data(chunked.prefix(offset)))) }
        XCTAssertEqual(try HTTPParser.parse(chunked)?.body, Data("hello".utf8))
    }

    func testMalformedFramingAndLimits() {
        for headers in ["Content-Length: -1", "Content-Length: NaN", "Content-Length: 999999999999999999999999999999", "Content-Length: 33554433", "Content-Length: 1\r\nContent-Length: 2", "Content-Length: 1\r\nTransfer-Encoding: chunked", "Transfer-Encoding: gzip", "Expect: 100-continue", "bad header: x"] {
            XCTAssertThrowsError(try HTTPParser.parse(Data("POST /responses HTTP/1.1\r\n\(headers)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try HTTPParser.parse(Data(repeating: 65, count: HTTPParser.maxHeader + 1)))
    }
}
