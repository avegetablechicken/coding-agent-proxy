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
