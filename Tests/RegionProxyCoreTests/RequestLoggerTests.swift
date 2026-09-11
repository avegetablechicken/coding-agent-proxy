import Foundation
import XCTest
@testable import RegionProxyCore

final class RequestLoggerTests: XCTestCase {
    func testConcurrentLinesConsoleAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("proxy.log")
        let pipe = Pipe()
        let logger = try RequestLogger(fileURL: url, console: pipe.fileHandleForWriting)
        // Keep the console fixture below the pipe capacity; disk concurrency is exercised separately.
        logger.write("route_selected", ["account_id": "account-a", "proxy": "us\nquoted\"value"])
        try pipe.fileHandleForWriting.close()
        let console = pipe.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(console, try Data(contentsOf: url))
        let diskLogger = try RequestLogger(fileURL: directory.appendingPathComponent("parallel.log"), console: nil)
        DispatchQueue.concurrentPerform(iterations: 100) { index in
            diskLogger.write("route_selected", ["request_id": String(index), "account_id": "account-a"])
        }
        let lines = try String(contentsOf: directory.appendingPathComponent("parallel.log"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 100)
        let records = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
        XCTAssertEqual(Set(records.compactMap { $0["request_id"] }).count, 100)
        XCTAssertTrue(records.allSatisfy { $0["account_id"] == "account-a" && $0["timestamp"] != nil })
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRotationKeepsMostRecentBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("proxy.log")
        let logger = try RequestLogger(fileURL: url, console: nil, maxBytes: 1)
        for index in 1...3 { logger.write("event", ["sequence": String(index)]) }
        let current = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: String]
        let backup = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: url.path + ".1"))) as! [String: String]
        XCTAssertEqual(current["sequence"], "3")
        XCTAssertEqual(backup["sequence"], "2")
    }
}
