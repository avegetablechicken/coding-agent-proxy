import Foundation
import XCTest
@testable import RegionProxyCore

final class ConfigurationLayoutTests: XCTestCase {
    let yaml = """
    listen_port: 7889
    request_timeout_seconds: 30
    auth_file: /unused/auth.json
    base_url:
      account: https://chatgpt.com/backend-api
      api_key: https://api.openai.com/v1
    proxies:
      us: http://127.0.0.1:8101
      jp: socks5://127.0.0.1:8102
    routing:
      account:
        mapped: none
      account_fallback: us
      api_key_fallback: jp
      mcp_fallback: none
    """

    func testIndependentFallbacksAndAccountMappingPriority() throws {
        let config = try Configuration.parse(yaml)
        let unmapped = { Identity(accountID: "unmapped", accessToken: "account-token") }
        let account = try config.resolveRoute(authorization: "Bearer account-token", loadIdentity: unmapped)
        XCTAssertEqual(account.proxy, "us")
        XCTAssertEqual(account.accountID, "unmapped")
        XCTAssertEqual(account.upstream, "https://chatgpt.com/backend-api")
        let mapped = try config.resolveRoute(authorization: "Bearer account-token", loadIdentity: {
            Identity(accountID: "mapped", accessToken: "account-token")
        })
        XCTAssertEqual(mapped.proxy, "none")
        let key = try config.resolveRoute(authorization: "Bearer unmatched-key", loadIdentity: unmapped)
        XCTAssertEqual(key.proxy, "jp")
        XCTAssertNil(key.accountID)
        XCTAssertEqual(key.upstream, "https://api.openai.com/v1")
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer account-token", loadIdentity: unmapped).proxy, "us")
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer unmatched-key", loadIdentity: unmapped).proxy, "none")
        XCTAssertThrowsError(try config.resolveRoute(authorization: nil, loadIdentity: unmapped))
        let onlyFallback = try Configuration.parse(yaml.replacingOccurrences(of: "  account:\n    mapped: none\n", with: ""))
        XCTAssertEqual(try onlyFallback.resolveRoute(authorization: "Bearer account-token", loadIdentity: unmapped).proxy, "us")
    }

    func testNestedAPIKeyRouteAndMigration() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "[model_providers.vendor]\nenv_key = 'VENDOR_KEY'\nbase_url = 'https://vendor.example.com/v1'\n"
            .write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let config = try Configuration.parse(yaml + "\n  api_key:\n    vendor: us\n")
        let provider = try XCTUnwrap(config.providers.first)
        let credential = try provider.resolveCredential(environment: ["CODEX_HOME": folder.path, "VENDOR_KEY": "test-key"])
        XCTAssertEqual(provider.proxy, "us")
        XCTAssertEqual(credential.upstream, "https://vendor.example.com/v1")
        let encoded = try config.canonicalYAML()
        let decoded = try Configuration.parse(encoded)
        XCTAssertEqual(decoded.accounts, config.accounts)
        XCTAssertEqual(decoded.account_fallback_proxy, "us")
        XCTAssertEqual(decoded.openai_fallback_proxy, "jp")
        XCTAssertEqual(decoded.mcp_fallback_proxy, "none")
        XCTAssertEqual(decoded.providers.first?.name, "vendor")
        XCTAssertFalse(encoded.contains("test-key"))
        let legacy = try Configuration.parse("listen_port: 7889\nrequest_timeout_seconds: 30\nupstream_base_url: https://chatgpt.com/backend-api/codex")
        XCTAssertEqual(try Configuration.parse(legacy.canonicalYAML()).account_upstream_base_url, "https://chatgpt.com/backend-api")
    }

    func testNestedUnknownKeysAndMixedFormatsAreRejected() throws {
        for invalid in [yaml.replacingOccurrences(of: "account_fallback: us", with: "account_fallback: missing"),
                        yaml.replacingOccurrences(of: "account_fallback: us", with: "account_falback: us"),
                        yaml.replacingOccurrences(of: "account: https:", with: "accout: https:"),
                        yaml + "\naccounts: {}", yaml + "\napi_key_upstream_base_url: https://api.openai.com/v1",
                        yaml + "\n  api_key:\n    - name: vendor\n      proxy: us\n      unknown: value"] {
            XCTAssertThrowsError(try Configuration.parse(invalid))
        }
    }
}
