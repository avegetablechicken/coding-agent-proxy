import Foundation
import XCTest
@testable import RegionProxyCore

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stream-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private let lock = NSLock()
    private var stopped = false
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream", "X-Fixture": "yes"])!
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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let slot = RouterSlot()
        let server = try HTTPServer(port: 0) { request, client in await slot.handle(request, client) }
        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let auth = directory.appendingPathComponent("auth.json")
        try Data(#"{"tokens":{"account_id":"fixture","access_token":"test-token"}}"#.utf8).write(to: auth)
        let config = directory.appendingPathComponent("config.yaml")
        try """
        listen_port: \(port)
        auth_file: "\(auth.path)"
        upstream_base_url: "https://stream-fixture.invalid/backend-api/codex"
        request_timeout_seconds: 10
        proxies:
          test: "http://127.0.0.1:1"
        accounts:
          fixture: test
        """.write(to: config, atomically: true, encoding: .utf8)
        let logURL = directory.appendingPathComponent("proxy.log")
        let logger = try RequestLogger(fileURL: logURL, console: nil)
        await slot.install(Forwarder(configPath: config.path, port: port, logger: logger, sessionConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureProtocol.self]
            return configuration
        }))
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/responses")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
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
        XCTAssertEqual(records.map { $0["event"] }, ["request_received", "route_selected", "upstream_response", "request_finished"])
        XCTAssertEqual(Set(records.compactMap { $0["request_id"] }).count, 1)
        XCTAssertEqual(records.last?["account_id"], "fixture")
        XCTAssertEqual(records.last?["proxy"], "test")
        XCTAssertEqual(records.last?["status"], "200")
        XCTAssertEqual(records.last?["received_bytes"], "27")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(text.contains("test-token"))
        XCTAssertFalse(text.contains("data: first"))
    }
}
