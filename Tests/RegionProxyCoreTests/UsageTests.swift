import Foundation
import XCTest
@testable import RegionProxyCore

private final class UsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "usage-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertTrue(["/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits"].contains(request.url!.path))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer usage-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "usage-account")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"rate_limit":{"allowed":true},"credits":{"balance":"10"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor UsageRouter {
    var forwarder: Forwarder?
    func install(_ value: Forwarder) { forwarder = value }
    func handle(_ request: HTTPRequest, _ connection: HTTPConnection) async {
        await forwarder?.handle(request, client: connection)
    }
}

@MainActor
final class UsageTests: XCTestCase {
    func testAccountQueryPathsAndOriginRestrictions() throws {
        let base = "https://chatgpt.com/backend-api/codex"
        for target in ["/backend-api/wham/usage", "/https://chatgpt.com/backend-api/wham/usage"] {
            XCTAssertEqual(try Forwarder.accountQueryURL(base: base, target: target + "?value=a%2Fb").absoluteString,
                           "https://chatgpt.com/backend-api/wham/usage?value=a%2Fb")
        }
        for target in ["/https://other.invalid/backend-api/wham/usage", "/http://chatgpt.com/backend-api/wham/usage",
                       "/https://chatgpt.com:444/backend-api/wham/usage", "/backend-api/wham/usage#fragment",
                       "//other.invalid/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits/consume",
                       "/wham/usage", "/api/codex/usage", "/api/codex/rate-limit-reset-credits"] {
            XCTAssertThrowsError(try Forwarder.accountQueryURL(base: base, target: target))
        }
        XCTAssertThrowsError(try Forwarder.accountQueryURL(base: "https://api.openai.com/v1", target: "/wham/usage"))
    }

    func testUsageAndCreditsRequireMatchedAccountAndPreserveJSON() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let router = UsageRouter()
        let server = try HTTPServer(port: 0) { request, connection in await router.handle(request, connection) }
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let auth = folder.appendingPathComponent("auth.json")
        try #"{"tokens":{"account_id":"usage-account","access_token":"usage-token"}}"#.write(to: auth, atomically: true, encoding: .utf8)
        let config = folder.appendingPathComponent("config.yaml")
        try """
        listen_port: \(port)
        request_timeout_seconds: 10
        auth_file: "\(auth.path)"
        upstream_base_url: https://usage-fixture.invalid/backend-api/codex
        accounts:
          usage-account: none
        openai_fallback_proxy: none
        """.write(to: config, atomically: true, encoding: .utf8)
        await router.install(Forwarder(configuration: try Configuration.read(config.path), sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UsageProtocol.self]
            return configuration
        }))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for path in ["/backend-api/wham/usage", "/backend-api/wham/rate-limit-reset-credits",
                     "/https://usage-fixture.invalid/backend-api/wham/usage"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.setValue("Bearer usage-token", forHTTPHeaderField: "Authorization")
            request.setValue("private-cookie", forHTTPHeaderField: "Cookie")
            let (body, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"rate_limit":{"allowed":true},"credits":{"balance":"10"}}"#)
            for (credential, account, method, status) in [
                (nil, nil, "GET", 401), ("Bearer unknown-api-key", nil, "GET", 403),
                ("Bearer usage-token", "other-account", "GET", 409), ("Bearer usage-token", nil, "POST", 405)
            ] as [(String?, String?, String, Int)] {
                request.setValue(credential, forHTTPHeaderField: "Authorization")
                request.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
                request.httpMethod = method
                let (_, rejected) = try await session.data(for: request)
                XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, status)
            }
        }
    }
}
