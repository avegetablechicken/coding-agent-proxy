import Foundation
import XCTest
@testable import RegionProxyCore

final class APIKeyTests: XCTestCase {
    func testBuiltInOpenAIUsesServiceDefaultInsteadOfCodexModelURL() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        openai_base_url = "http://127.0.0.1:7889/v1"
        [model_providers.vendor]
        env_key = "VENDOR_KEY"
        base_url = "http://127.0.0.1:7889/https://vendor.example.com/v1"
        """.write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let environment = ["CODEX_HOME": folder.path, "OPENAI_API_KEY": "test-key", "ALT_KEY": "alternate", "VENDOR_KEY": "vendor-key"]
        for (fields, expected) in [
            ("name: openai", "https://default.example.com/v1"),
            ("api_key_env: OPENAI_API_KEY", "https://default.example.com/v1"),
            ("name: openai\n      api_key_env: ALT_KEY", "https://default.example.com/v1"),
            ("name: openai\n      upstream_base_url: https://override.example.com/v1", "https://override.example.com/v1"),
            ("name: vendor", "https://vendor.example.com/v1")
        ] {
            let config = try Configuration.parse("""
            listen_port: 7889
            request_timeout_seconds: 30
            base_url:
              api_key: https://default.example.com/v1
            api_key_providers:
              - \(fields.replacingOccurrences(of: "\n      ", with: "\n    "))
                proxy: none
            """)
            let provider = try XCTUnwrap(config.providers.first)
            XCTAssertEqual(try provider.resolveCredential(environment: environment, defaultUpstream: config.api_key_upstream_base_url).upstream, expected)
        }
    }

    func testTopLevelAPIKeyDefaultAndFallback() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "configured-key".write(to: file, atomically: true, encoding: .utf8)
        let yaml = """
        listen_port: 7889
        request_timeout_seconds: 30
        api_key_upstream_base_url: https://default.example.com/v1
        proxies:
          us: http://127.0.0.1:8101
        openai_fallback_proxy: us
        api_key_providers:
        - name: test
          api_key_file: '\(file.path)'
          proxy: us
        """
        let config = try Configuration.parse(yaml)
        try config.checkCredentials()
        for token in ["configured-key", "unknown-key"] {
            XCTAssertEqual(try config.resolveRoute(authorization: "Bearer \(token)").upstream,
                           "https://default.example.com/v1")
        }
        let override = try Configuration.parse(yaml + "\n  upstream_base_url: https://override.example.com/v1")
        XCTAssertEqual(try override.resolveRoute(authorization: "Bearer configured-key").upstream,
                       "https://override.example.com/v1")
        XCTAssertEqual(try override.resolveRoute(authorization: "Bearer unknown-key").upstream,
                       "https://default.example.com/v1")
        for invalid in ["http://default.example.com/v1", "https://127.0.0.1/v1", "''"] {
            XCTAssertThrowsError(try Configuration.parse(yaml.replacingOccurrences(of: "https://default.example.com/v1", with: invalid)))
        }
    }

    func testReverseProviderLookupAndUpstreamPrecedence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codexConfig = directory.appendingPathComponent("config.toml")
        let toml = """
        [model_providers.custom]
        env_key = "CUSTOM_KEY"
        base_url = "https://custom.example.com/v1"
        [model_providers.other]
        env_key = "OTHER_KEY"
        base_url = "https://other.example.com/v1"
        """
        try toml.write(to: codexConfig, atomically: true, encoding: .utf8)
        let env = ["CODEX_HOME": directory.path, "CUSTOM_KEY": "key", "OTHER_KEY": "key", "UNMAPPED_KEY": "key"]
        func provider(_ fields: String) throws -> APIKeyProvider {
            try Configuration.parse("""
            listen_port: 7889
            request_timeout_seconds: 30
            proxies:
              selected: http://127.0.0.1:8118
            api_key_providers:
            - proxy: selected
            \(fields)
            """).providers[0]
        }
        for fields in ["  name: custom", "  api_key_env: CUSTOM_KEY", "  name: custom\n  api_key_env: CUSTOM_KEY"] {
            let route = try provider(fields)
            let credential = try route.resolveCredential(environment: env)
            XCTAssertEqual(credential.key, "key")
            XCTAssertEqual(credential.upstream, "https://custom.example.com/v1")
            XCTAssertEqual(try route.resolveCredential(environment: env, defaultUpstream: "https://default.example.com/v1").upstream,
                           "https://custom.example.com/v1")
            XCTAssertEqual(route.proxy, "selected")
            XCTAssertEqual(try provider(fields + "\n  upstream_base_url: https://override.example.com/v1")
                .resolveCredential(environment: env).upstream, "https://override.example.com/v1")
        }
        // Explicit name controls the upstream; explicit environment controls the key.
        XCTAssertEqual(try provider("  name: custom\n  api_key_env: OTHER_KEY").resolveCredential(environment: env).upstream,
                       "https://custom.example.com/v1")
        XCTAssertEqual(try provider("  api_key_env: UNMAPPED_KEY").resolveCredential(environment: env).upstream,
                       "https://api.openai.com/v1")
        try (toml + "\n[model_providers.duplicate]\nenv_key = 'CUSTOM_KEY'\nbase_url = 'https://duplicate.example.com/v1'")
            .write(to: codexConfig, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try provider("  api_key_env: CUSTOM_KEY").resolveCredential(environment: env))
        // Supplying name avoids reverse-lookup ambiguity and does not require its own key.
        XCTAssertEqual(try provider("  name: custom\n  api_key_env: OTHER_KEY")
            .resolveCredential(environment: ["CODEX_HOME": directory.path, "OTHER_KEY": "different-key"]).key, "different-key")
        XCTAssertThrowsError(try provider("  name: custom\n  api_key_env: MISSING_KEY").resolveCredential(environment: env))
        try "[model_providers.url_only]\nbase_url = 'https://url-only.example.com/v1'"
            .write(to: codexConfig, atomically: true, encoding: .utf8)
        XCTAssertEqual(try provider("  name: url_only\n  api_key_env: OTHER_KEY")
            .resolveCredential(environment: env).upstream, "https://url-only.example.com/v1")
        try toml.replacingOccurrences(of: "https://custom.example.com/v1", with: "http://127.0.0.1:7889/v1")
            .write(to: codexConfig, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try provider("  api_key_env: CUSTOM_KEY").resolveCredential(environment: env))
        XCTAssertEqual(try provider("  api_key_env: CUSTOM_KEY\n  upstream_base_url: https://override.example.com/v1")
            .resolveCredential(environment: env).upstream, "https://override.example.com/v1")
        try toml.replacingOccurrences(of: "https://custom.example.com/v1", with: "http://127.0.0.1:7889/https://custom.example.com/v1")
            .write(to: codexConfig, atomically: true, encoding: .utf8)
        XCTAssertEqual(try provider("  api_key_env: CUSTOM_KEY").resolveCredential(environment: env).upstream,
                       "https://custom.example.com/v1")
    }

    func testCodexProviderLookupReadsTOML() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.toml")
        try """
        [model_providers."provider.with.dots"]
        env_key = "CUSTOM_KEY"
        requires_openai_auth = false
        """.write(to: config, atomically: true, encoding: .utf8)
        let environment = ["CODEX_HOME": directory.path]
        XCTAssertEqual(try CodexProviderLookup.definitions(environment: environment).first(where: { $0.id == "provider.with.dots" })?.env_key, "CUSTOM_KEY")
        XCTAssertNil(try CodexProviderLookup.definitions(environment: environment).first(where: { $0.id == "missing" }))
        XCTAssertEqual(try CodexProviderLookup.definitions(environment: [:]).first(where: { $0.id == "openai" })?.env_key, "OPENAI_API_KEY")
        try "invalid = [".write(to: config, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CodexProviderLookup.definitions(environment: environment).first(where: { $0.id == "provider.with.dots" })?.env_key)
    }

    func testOmittedAPIUpstreamDefaultsToOpenAIAndKeepsSelectedProxy() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "test-openai-key".write(to: file, atomically: true, encoding: .utf8)
        do {
            let text = """
            listen_port: 7889
            upstream_base_url: https://chatgpt.com/backend-api/codex
            request_timeout_seconds: 30
            proxies:
              selected: http://127.0.0.1:8118
            api_key_providers:
            - name: openai
              proxy: selected
              api_key_file: '\(file.path)'
            """
            let config = try Configuration.parse(text)
            let route = try config.resolveRoute(authorization: "Bearer test-openai-key")
            XCTAssertEqual(route.upstream, "https://api.openai.com/v1")
            XCTAssertEqual(route.proxy, "selected")
            XCTAssertEqual(config.proxies[route.proxy.candidates[0]], "http://127.0.0.1:8118")
            XCTAssertNil(route.accountID)
            let overridden = try Configuration.parse(text + "\n  upstream_base_url: https://custom.example.com/v1")
            XCTAssertEqual(try overridden.resolveRoute(authorization: "Bearer test-openai-key").upstream,
                           "https://custom.example.com/v1")
            XCTAssertThrowsError(try Configuration.parse(text + "\n  upstream_base_url: ''"))
        }
    }

    func testMixedRoutesRotationAndAmbiguity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.key")
        let b = directory.appendingPathComponent("b.key")
        try "key-a".write(to: a, atomically: true, encoding: .utf8)
        try "key-b".write(to: b, atomically: true, encoding: .utf8)
        let config = try Configuration.parse("""
        listen_port: 7889
        auth_file: /missing/auth.json
        upstream_base_url: https://chatgpt.com/backend-api/codex
        request_timeout_seconds: 30
        proxies:
          us: http://127.0.0.1:8101
          jp: http://127.0.0.1:8102
        accounts:
          account-a: us
        api_key_providers:
          - name: a
            upstream_base_url: https://a.example.com/v1
            proxy: us
            api_key_file: '\(a.path)'
          - name: b
            upstream_base_url: https://b.example.com/v1
            proxy: jp
            api_key_file: '\(b.path)'
        """)
        let identity = { Identity(accountID: "account-a", accessToken: "chat-token") }
        let chat = try config.resolveRoute(authorization: "Bearer chat-token", loadIdentity: identity)
        XCTAssertEqual(chat.accountID, "account-a")
        XCTAssertEqual(chat.upstream, "https://chatgpt.com/backend-api/codex")
        for (key, name, proxy) in [("key-a", "a", "us"), ("key-b", "b", "jp")] {
            let route = try config.resolveRoute(authorization: "Bearer \(key)", loadIdentity: identity)
            XCTAssertEqual(route.provider, name)
            XCTAssertEqual(route.proxy.candidates, [proxy])
            XCTAssertEqual(route.upstream, "https://\(name).example.com/v1")
            XCTAssertNil(route.accountID)
        }
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer unknown", loadIdentity: identity)) {
            XCTAssertEqual(($0 as? RouteRejection)?.status, 401)
        }
        // An unavailable auth.json must not disable an independently configured API Key.
        XCTAssertEqual(try config.resolveRoute(authorization: "Bearer key-a").provider, "a")
        try "new-key".write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer key-a", loadIdentity: identity))
        XCTAssertEqual(try config.resolveRoute(authorization: "Bearer new-key", loadIdentity: identity).provider, "a")
        try "key-b".write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer key-b", loadIdentity: identity)) {
            XCTAssertEqual(($0 as? RouteRejection)?.status, 409)
        }
        try "chat-token".write(to: a, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer chat-token", loadIdentity: identity)) {
            XCTAssertEqual(($0 as? RouteRejection)?.status, 409)
        }
        try FileManager.default.removeItem(at: a)
        XCTAssertEqual(try config.resolveRoute(authorization: "Bearer key-b", loadIdentity: identity).provider, "b")
    }

    let yaml = """
    listen_port: 8788
    upstream_base_url: "https://api.example.com/v1"
    request_timeout_seconds: 30
    proxies:
      us: "http://127.0.0.1:8101"
    api_key_providers:
    - name: provider-a
      proxy: us
      api_key_env: TEST_PROVIDER_KEY
    """

    func testEnvironmentCredentialAndRoute() throws {
        let config = try Configuration.parse(yaml.replacingOccurrences(of: "- name: provider-a", with: "- upstream_base_url: https://api.example.com/v1"))
        let provider = try XCTUnwrap(config.providers.first)
        XCTAssertEqual(try provider.resolveCredential(environment: ["TEST_PROVIDER_KEY": "sk-test"]).key, "sk-test")
        XCTAssertEqual(provider.proxy, "us")
        XCTAssertThrowsError(try provider.resolveCredential(environment: [:]))
        for key in ["", " ", "bad\r\nheader", "two words", "key\u{0}", "key\u{7f}", "密钥"] {
            XCTAssertThrowsError(try provider.resolveCredential(environment: ["TEST_PROVIDER_KEY": key]))
        }
    }

    func testInvalidProvidersFailClosed() {
        for text in [
            yaml.replacingOccurrences(of: "proxy: us", with: "proxy: unknown"),
            yaml.replacingOccurrences(of: "api_key_env: TEST_PROVIDER_KEY", with: "api_key_env: ''"),
            yaml.replacingOccurrences(of: "api_key_env: TEST_PROVIDER_KEY", with: "api_key_file: ''"),
            yaml.replacingOccurrences(of: "api_key_env: TEST_PROVIDER_KEY", with: "unknown: secret"),
            yaml + "\n  api_key_file: /tmp/unused-key",
            yaml + "\nauth_file: /tmp/auth.json",
            yaml + "\naccounts:\n  account-a: us",
            yaml.replacingOccurrences(of: "https://api.example.com", with: "http://api.example.com"),
            yaml.replacingOccurrences(of: "api.example.com", with: "127.0.0.1")
        ] {
            XCTAssertThrowsError(try Configuration.parse(text))
        }
    }

    func testKeyFileReloadAndMissingFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let config = try Configuration.parse(yaml.replacingOccurrences(
            of: "api_key_env: TEST_PROVIDER_KEY", with: "api_key_file: '\(file.path)'"))
        XCTAssertThrowsError(try config.providers[0].resolveCredential().key)
        try "first-key\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try config.providers[0].resolveCredential().key
        try "second-key\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(first, "first-key")
        XCTAssertEqual(try config.providers[0].resolveCredential().key, "second-key")
    }

    func testAPIPathsArePassedThroughWithoutProtocolTranslation() throws {
        for suffix in ["responses", "chat/completions", "models"] {
            XCTAssertEqual(try Forwarder.upstreamURL(base: "https://api.example.com/v1", target: "/v1/\(suffix)?a=1").absoluteString,
                           "https://api.example.com/v1/\(suffix)?a=1")
        }
    }
}
