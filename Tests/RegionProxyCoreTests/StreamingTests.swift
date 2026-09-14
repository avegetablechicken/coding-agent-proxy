import Foundation
import XCTest
@testable import RegionProxyCore

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        ["stream-fixture.invalid", "developers.openai.com"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let lock = NSLock()
    private var stopped = false
    override func startLoading() {
        if request.url?.host == "developers.openai.com" {
            XCTAssertEqual(request.url?.path, "/mcp")
            XCTAssertEqual(request.url?.query, "test=1")
            for name in ["Authorization", "ChatGPT-Account-Id", "X-Api-Key", "Api-Key", "Cookie", "X-Private-Token"] {
                XCTAssertNil(request.value(forHTTPHeaderField: name), "Do not send model credentials to MCP: \(name)")
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "fixture-session")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Protocol-Version"), "2025-03-26")
        } else if request.url?.path.hasPrefix("/v1/") == true {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Api-Key"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Api-Key"))
            XCTAssertEqual(request.url?.query, "test=1")
        } else {
            XCTAssertEqual(request.url?.path, "/backend-api/codex/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "fixture")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream", "X-Fixture": "yes", "Mcp-Session-Id": "returned-session"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: first\n\n".utf8))
        // Keeping the response open makes buffering the entire SSE response observable.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if stopped { return }
                client?.urlProtocol(self, didLoad: Data("data: second\n\n".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

private actor RouterSlot {
    var forwarder: Forwarder?
    func install(_ value: Forwarder) { forwarder = value }
    func handle(_ request: HTTPRequest, _ client: HTTPConnection) async { await forwarder?.handle(request, client: client) }
}

@MainActor
final class StreamingTests: XCTestCase {
    func testSSEArrivesBeforeUpstreamCompletes() async throws {
        try await exerciseStreaming(apiKeyMode: false)
    }

    func testEmailRoutingPreservesAccountHeadersAndStreaming() async throws {
        try await exerciseStreaming(apiKeyMode: false, emailRouting: true)
    }

    func testAPIKeyAuthenticationHeadersAndStreaming() async throws {
        try await exerciseStreaming(apiKeyMode: true)
    }

    func testExplicitUpstreamGETStreaming() async throws {
        try await exerciseStreaming(apiKeyMode: true, explicitPath: true)
    }

    func testExplicitChatGPTAccountPathStreaming() async throws {
        try await exerciseStreaming(apiKeyMode: false, explicitPath: true)
    }

    func testExplicitDirectAPIKeyStreaming() async throws {
        try await exerciseStreaming(apiKeyMode: true, direct: true)
    }

    func testDocsMCPUsesChatGPTRouteWithoutLeakingCredentials() async throws {
        try await exerciseStreaming(apiKeyMode: false, mcpMethod: "POST")
    }

    func testDocsMCPUsesAPIKeyRouteWithoutLeakingCredentials() async throws {
        try await exerciseStreaming(apiKeyMode: true, mcpMethod: "POST")
    }

    func testDocsMCPSessionGETAndDELETE() async throws {
        try await exerciseStreaming(apiKeyMode: false, mcpMethod: "GET")
        try await exerciseStreaming(apiKeyMode: true, mcpMethod: "DELETE")
    }

    func testDocsMCPWithoutCredentialDefaultsToDirect() async throws {
        try await exerciseStreaming(apiKeyMode: false, mcpMethod: "POST", mcpCredential: nil)
    }

    func testDocsMCPUnknownCredentialUsesConfiguredFallback() async throws {
        try await exerciseStreaming(apiKeyMode: true, mcpMethod: "POST", mcpCredential: "unknown", mcpFallback: "test")
    }

    private func exerciseStreaming(apiKeyMode: Bool, explicitPath: Bool = false, direct: Bool = false,
                                   mcpMethod: String? = nil, mcpCredential: String? = "test-token", mcpFallback: String? = nil, emailRouting: Bool = false) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slot = RouterSlot()
        let server = try HTTPServer(port: 0) { request, client in await slot.handle(request, client) }
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let auth = directory.appendingPathComponent("auth.json")
        let payload = Data(#"{"email":"you@example.com"}"#.utf8).base64EncodedString()
        let tokens = ["account_id": "fixture", "access_token": "test-token", "id_token": "e30.\(payload).fixture"]
        try JSONSerialization.data(withJSONObject: ["tokens": tokens]).write(to: auth)
        let config = directory.appendingPathComponent("config.yaml")
        try """
        listen_port: \(port)
        auth_file: "\(auth.path)"
        upstream_base_url: "https://stream-fixture.invalid/backend-api"
        request_timeout_seconds: 10
        proxies:
          test: "http://127.0.0.1:1"
        accounts:
          "\(emailRouting ? "you@example.com" : "fixture")": test
        """.write(to: config, atomically: true, encoding: .utf8)
        if apiKeyMode {
            let keyFile = directory.appendingPathComponent("api-key")
            try "test-token\n".write(to: keyFile, atomically: true, encoding: .utf8)
            try """
            listen_port: \(port)
            upstream_base_url: "https://stream-fixture.invalid/v1"
            request_timeout_seconds: 10
            proxies:
              test: "http://127.0.0.1:1"
            api_key_providers:
            - name: fixture-provider
              upstream_base_url: "https://stream-fixture.invalid/v1"
              proxy: test
              api_key_file: "\(keyFile.path)"
            """.write(to: config, atomically: true, encoding: .utf8)
        }
        if direct {
            try String(contentsOf: config, encoding: .utf8)
                .replacingOccurrences(of: "proxy: test", with: "proxy: none")
                .write(to: config, atomically: true, encoding: .utf8)
        }
        if let mcpFallback {
            try (String(contentsOf: config, encoding: .utf8) + "\nmcp_fallback_proxy: \(mcpFallback)\n")
                .write(to: config, atomically: true, encoding: .utf8)
        }
        let logURL = directory.appendingPathComponent("proxy.log")
        let logger = try RequestLogger(fileURL: logURL, console: nil)
        await slot.install(Forwarder(configuration: try Configuration.read(config.path), logger: logger, sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            return configuration
        }))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let explicitTarget = apiKeyMode ? "/https://stream-fixture.invalid/v1/models?test=1"
            : "/https://stream-fixture.invalid/backend-api/codex/responses?test=1"
        let path = mcpMethod != nil ? Forwarder.docsMCPPath + "?test=1" : (explicitPath ? explicitTarget : "/v1/responses?test=1")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = mcpMethod ?? (explicitPath && apiKeyMode ? "GET" : "POST")
        request.httpBody = request.httpMethod == "GET" ? nil : Data("{}".utf8)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        if apiKeyMode {
            request.setValue("wrong-key", forHTTPHeaderField: "X-Api-Key")
            request.setValue("another-key", forHTTPHeaderField: "Api-Key")
            request.setValue("unrelated-account", forHTTPHeaderField: "ChatGPT-Account-Id")
            if mcpMethod == nil {
                var rejected = request
                rejected.setValue("Bearer incorrect", forHTTPHeaderField: "Authorization")
                let (_, response) = try await session.data(for: rejected)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
            }
        }
        if mcpMethod != nil {
            request.setValue(apiKeyMode ? nil : "fixture", forHTTPHeaderField: "ChatGPT-Account-Id")
            request.setValue("fixture-session", forHTTPHeaderField: "Mcp-Session-Id")
            request.setValue("2025-03-26", forHTTPHeaderField: "Mcp-Protocol-Version")
            request.setValue("hidden", forHTTPHeaderField: "X-Private-Token")
            request.setValue("hidden", forHTTPHeaderField: "Cookie")
            var unknown = request
            unknown.url = URL(string: "http://127.0.0.1:\(port)/mcp/unknown")!
            let (_, response) = try await session.data(for: unknown)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
            unknown = request
            unknown.httpMethod = "PUT"
            let (_, methodResponse) = try await session.data(for: unknown)
            XCTAssertEqual((methodResponse as? HTTPURLResponse)?.statusCode, 405)
            request.setValue(mcpCredential.map { "Bearer " + $0 }, forHTTPHeaderField: "Authorization")
        }
        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id"), "returned-session")
        var result = Data()
        var firstLineAt: TimeInterval?
        for try await byte in bytes {
            result.append(byte)
            if byte == 10, firstLineAt == nil { firstLineAt = Date().timeIntervalSince(started) }
        }
        XCTAssertLessThan(try XCTUnwrap(firstLineAt), 1.5, "SSE must reach the client before the upstream closes")
        XCTAssertEqual(result, Data("data: first\n\ndata: second\n\n".utf8))
        // Receiving the final chunk can race with the final log's synchronous write.
        var records: [[String: String]] = []
        for _ in 0..<100 {
            let text = try String(contentsOf: logURL, encoding: .utf8)
            records = try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
            if records.last?["event"] == "request_finished" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let successfulRecords = records.filter { $0["request_id"] == records.last?["request_id"] }
        XCTAssertEqual(successfulRecords.map { $0["event"] }, ["request_received", "route_selected", "upstream_response", "request_finished"])
        XCTAssertEqual(Set(successfulRecords.compactMap { $0["request_id"] }).count, 1)
        let usesMCPFallback = mcpMethod != nil && mcpCredential != "test-token"
        if usesMCPFallback {
            XCTAssertNil(records.last?["account_id"])
            XCTAssertNil(records.last?["provider"])
        } else if apiKeyMode {
            XCTAssertEqual(records.last?["provider"], "fixture-provider")
            XCTAssertNil(records.last?["account_id"])
        } else {
            XCTAssertEqual(records.last?["account_id"], "fixture")
        }
        XCTAssertEqual(records.last?["proxy"], usesMCPFallback ? (mcpFallback ?? "none") : (direct ? "none" : "test"))
        if direct { XCTAssertEqual(records.last?["proxy_endpoint"], "none") }
        XCTAssertEqual(records.last?["status"], "200")
        if mcpMethod != nil {
            XCTAssertEqual(records.last?["service"], "openaiDeveloperDocs")
            XCTAssertEqual(records.last?["routing"], usesMCPFallback ? "mcp_fallback" : "credential")
        }
        XCTAssertEqual(records.last?["received_bytes"], "27")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains("test-token"))
        XCTAssertFalse(text.contains("data: first"))
    }
}
