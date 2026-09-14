import Foundation
import XCTest
@testable import RegionProxyCore

final class ShellEnvironmentTests: XCTestCase {
    func testShellLookupIgnoresStartupOutputAndRefreshesExportedVariable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rc = folder.appendingPathComponent(".zshrc")
        let environment = ["SHELL": "/bin/zsh", "HOME": folder.path, "ZDOTDIR": folder.path, "CODEX_HOME": folder.path]
        try "echo startup-noise\nexport SHELL_TEST_KEY='first-key'\n".write(to: rc, atomically: true, encoding: .utf8)
        let config = try Configuration.parse("""
        listen_port: 7889
        request_timeout_seconds: 10
        api_key_providers:
          - api_key_env: SHELL_TEST_KEY
            upstream_base_url: https://api.openai.com/v1
            proxy: none
        """)
        let provider = try XCTUnwrap(config.providers.first)
        XCTAssertEqual(try provider.resolveCredential(environment: environment).key, "first-key")
        XCTAssertThrowsError(try provider.resolveCredential(environment: environment, allowShellLookup: false))
        try "export SHELL_TEST_KEY='second-key'\n".write(to: rc, atomically: true, encoding: .utf8)
        XCTAssertEqual(try provider.resolveCredential(environment: environment).key, "second-key")
        var inherited = environment
        inherited["SHELL_TEST_KEY"] = "inherited-key"
        XCTAssertEqual(try provider.resolveCredential(environment: inherited).key, "inherited-key")
        XCTAssertThrowsError(try ShellEnvironment.value(for: "MISSING_KEY", environment: environment))
        XCTAssertThrowsError(try ShellEnvironment.value(for: "KEY; echo injected", environment: environment))
        try "sleep 10\nexport SHELL_TEST_KEY='never-return'\n".write(to: rc, atomically: true, encoding: .utf8)
        let started = Date()
        XCTAssertThrowsError(try ShellEnvironment.value(for: "SHELL_TEST_KEY", environment: environment))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
