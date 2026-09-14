import Foundation
import XCTest
@testable import RegionProxyCore

final class APIKeyMappingTests: XCTestCase {
    func testProviderAndEnvironmentKeysResolveCredentialsAndUpstreams() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let toml = """
        openai_base_url = "http://127.0.0.1:7889/v1"
        [model_providers.ShareCoder]
        env_key = "SHARECODER_API_KEY"
        base_url = "http://127.0.0.1:7889/https://sharecoder.cc"
        """
        try toml.write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let environment = ["CODEX_HOME": folder.path, "SHARECODER_API_KEY": "share-key", "OPENAI_API_KEY": "openai-key", "UNKNOWN_KEY": "other-key"]
        for (selector, key, upstream) in [("ShareCoder", "share-key", "https://sharecoder.cc"),
                                           ("SHARECODER_API_KEY", "share-key", "https://sharecoder.cc"),
                                           ("OPENAI_API_KEY", "openai-key", "https://api.openai.com/v1"),
                                           ("UNKNOWN_KEY", "other-key", "https://api.openai.com/v1")] {
            let config = try Configuration.parse("listen_port: 7889\nrequest_timeout_seconds: 10\nrouting:\n  api_key:\n    \(selector): none")
            let route = try XCTUnwrap(config.providers.first)
            let credential = try route.resolveCredential(environment: environment)
            XCTAssertEqual(credential.key, key)
            XCTAssertEqual(credential.upstream, upstream)
            XCTAssertEqual(route.name, selector)
        }
        let duplicate = toml + "\n[model_providers.other]\nenv_key = 'SHARECODER_API_KEY'\nbase_url = 'https://other.example.com/v1'\n"
        try duplicate.write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try APIKeyProvider(selector: "SHARECODER_API_KEY", proxy: "none").resolveCredential(environment: environment))
        XCTAssertEqual(try APIKeyProvider(selector: "ShareCoder", proxy: "none").resolveCredential(environment: environment).key, "share-key")
    }

    func testStructuredEntriesAreRejectedAndExplicitMigrationPreservesMap() throws {
        let prefix = "listen_port: 7889\nrequest_timeout_seconds: 10\nrouting:\n  api_key:\n"
        for entry in ["    - name: ShareCoder\n      proxy: none", "    ShareCoder: {proxy: none}", "    ShareCoder: {api_key_env: KEY}"] {
            XCTAssertThrowsError(try Configuration.parse(prefix + entry))
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try (prefix + "    - name: ShareCoder\n      proxy: none\n    - name: openai\n      api_key_env: OPENAI_API_KEY\n      proxy: [none]")
            .write(to: file, atomically: true, encoding: .utf8)
        let migrated = try Configuration.read(file.path, migrateAPIKeyLayout: true)
        XCTAssertEqual(Set(migrated.providers.map(\.name)), ["ShareCoder", "OPENAI_API_KEY"])
        XCTAssertEqual(try Configuration.parse(migrated.canonicalYAML()).providers.count, 2)
        try (prefix + "    - name: ShareCoder\n      api_key_file: /private/key\n      proxy: none")
            .write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Configuration.read(file.path, migrateAPIKeyLayout: true))
    }
}
