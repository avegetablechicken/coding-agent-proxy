import Foundation
import XCTest
@testable import RegionProxyCore

private final class SelectionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "selection.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "HEAD" {
            XCTAssertEqual(request.url?.path, "/")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            let status = request.url?.port == 444 ? 503 : 404
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        } else {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let response = HTTPURLResponse(url: request.url!, statusCode: request.url?.port == 445 ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SelectionRouter {
    var forwarder: Forwarder?
    var probes: [String] = []
    func install(_ value: Forwarder) { forwarder = value }
    func record(_ endpoint: String) { probes.append(endpoint) }
    func handle(_ request: HTTPRequest, _ connection: HTTPConnection) async { await forwarder?.handle(request, client: connection) }
}

@MainActor
final class ProxySelectionTests: XCTestCase {
    func testListConfigurationValidationAndRoundTrip() throws {
        let text = """
        listen_port: 7889
        request_timeout_seconds: 10
        auth_file: /unused/auth.json
        proxies:
          first: http://127.0.0.1:8001
          second: socks5://127.0.0.1:8002
        routing:
          account:
            account-id: [first, second]
          api_key:
            vendor: [second, none]
          account_fallback: [second, first]
          api_key_fallback: [first, none]
          mcp_fallback: [second]
        """
        let config = try Configuration.parse(text)
        XCTAssertEqual(config.accounts["account-id"]?.candidates, ["first", "second"])
        XCTAssertEqual(config.providers[0].proxy.candidates, ["second", "none"])
        let migrated = try Configuration.parse(config.canonicalYAML())
        XCTAssertEqual(migrated.accounts, config.accounts)
        XCTAssertEqual(migrated.mcp_fallback_proxy, config.mcp_fallback_proxy)
        XCTAssertTrue(try XCTUnwrap(migrated.mcp_fallback_proxy).isList)
        for invalid in ["[]", "[first, missing]", "[first, '']", "{first: second}"] {
            XCTAssertThrowsError(try Configuration.parse(text.replacingOccurrences(of: "[first, second]", with: invalid)))
        }
    }

    func testOrderedSelectionStopsAtFirstAvailableAndSendsBusinessRequestOnce() async throws {
        try await exercise(choice: "[first, second, third]", available: "second", expected: ["first", "second"], selected: "second")
    }

    func testFirstAvailableWinsAndScalarSkipsProbes() async throws {
        try await exercise(choice: "[first, second]", available: "first", expected: ["first"], selected: "first")
        try await exercise(choice: "first", available: nil, expected: [], selected: "first")
    }

    func testAllUnavailableFailsWithoutSendingBusinessRequest() async throws {
        try await exercise(choice: "[first, second]", available: nil, expected: ["first", "second"], selected: nil)
    }

    func testExplicitDirectCandidateIsTestedInOrder() async throws {
        try await exercise(choice: "[first, none, second]", available: "none", expected: ["first", "none"], selected: "none")
    }

    func testBusinessFailureAfterSelectionDoesNotReplayThroughAnotherProxy() async throws {
        try await exercise(choice: "[first, second]", available: "first", expected: ["first"], selected: "first", failingBusiness: true)
    }

    func testRealProbeUsesUnauthenticatedHEADAndAcceptsReachable404() async throws {
        try await exercise(choice: "[none]", available: nil, expected: [], selected: "none", realProbe: true)
        try await exercise(choice: "[none]", available: nil, expected: [], selected: nil, realProbe: true, failingOrigin: true)
    }

    private func exercise(choice: String, available: String?, expected: [String], selected: String?,
                          realProbe: Bool = false, failingOrigin: Bool = false, failingBusiness: Bool = false) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let router = SelectionRouter()
        let server = try HTTPServer(port: 0) { request, connection in await router.handle(request, connection) }
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let log = folder.appendingPathComponent("proxy.log")
        let config = try Configuration.parse("""
        listen_port: \(port)
        request_timeout_seconds: 10
        base_url:
          api_key: https://selection.invalid\(failingOrigin ? ":444" : (failingBusiness ? ":445" : ""))/v1
        proxies:
          first: http://user:private-password@127.0.0.1:8001
          second: http://127.0.0.1:8002
          third: http://127.0.0.1:8003
        routing:
          api_key_fallback: \(choice)
        """)
        let mockProbe: @Sendable (String, URL, Double) async throws -> Bool = { endpoint, url, timeout in
            await router.record(endpoint)
            XCTAssertEqual(url.path, "/")
            XCTAssertNil(url.query)
            XCTAssertEqual(timeout, 5)
            return available.map { config.proxyEndpoint(for: $0) == endpoint } ?? false
        }
        await router.install(Forwarder(configuration: config, logger: try RequestLogger(fileURL: log, console: nil),
            sessionConfiguration: {
                let value = URLSessionConfiguration.ephemeral
                value.protocolClasses = [SelectionProtocol.self]
                return value
            }, proxyProbe: realProbe ? nil : mockProbe))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/responses?private=not-for-probe")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"business\":true}".utf8)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, selected == nil ? 502 : (failingBusiness ? 503 : 200))
        let probes = await router.probes
        XCTAssertEqual(probes, expected.map { config.proxyEndpoint(for: $0) })
        // Terminal log write may occur just after the client's final byte arrives.
        var records: [[String: String]] = []
        for _ in 0..<100 {
            records = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String]
            }
            if records.last?["event"] == (selected == nil ? "request_failed" : "request_finished") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(records.filter { $0["event"] == "upstream_response" }.count, selected == nil ? 0 : 1)
        if let selected { XCTAssertEqual(records.last?["proxy"], selected) }
        let rawLog = try String(contentsOf: log, encoding: .utf8)
        XCTAssertFalse(rawLog.contains("private-password"))
        XCTAssertFalse(rawLog.contains("test-token"))
    }
}
