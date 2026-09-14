import Foundation
import XCTest
@testable import RegionProxyCore

final class UsernameRoutingTests: XCTestCase {
    private func jwt(_ claims: [String: Any]) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(payload).fixture"
    }

    private func identity(access: String = "saved-token", id: String? = nil) throws -> Identity {
        var tokens = ["account_id": "actual-id", "access_token": access]
        tokens["id_token"] = id
        return try Identity.parse(JSONSerialization.data(withJSONObject: ["tokens": tokens]))
    }

    private func config(_ entries: String) throws -> Configuration {
        try Configuration.parse("""
        listen_port: 7889
        request_timeout_seconds: 30
        auth_file: /unused/auth.json
        proxies:
          jp: http://127.0.0.1:8101
        routing:
          account:
        \(entries)
        """)
    }

    func testEmailInsteadOfIDAndCredentialChecks() throws {
        let login = try identity(id: jwt(["email": "you@example.com", "name": "Your Name"]))
        let config = try config("    you@example.com: jp")
        let route = try config.resolveRoute(authorization: "Bearer saved-token", loadIdentity: { login })
        XCTAssertEqual(route.proxy, "jp")
        XCTAssertEqual(route.accountID, "actual-id")
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer other-token", loadIdentity: { login }))
        XCTAssertEqual(config.resolveMCPRoute(authorization: "Bearer saved-token", accountID: "actual-id", loadIdentity: { login }).credential?.accountID, "actual-id")
        XCTAssertNil(config.resolveMCPRoute(authorization: "Bearer saved-token", accountID: "you@example.com", loadIdentity: { login }).credential)
        let refreshed = try identity(id: jwt(["email": "other@example.com"]))
        XCTAssertThrowsError(try config.resolveRoute(authorization: "Bearer saved-token", loadIdentity: { refreshed }))
        XCTAssertEqual(try Configuration.parse(config.canonicalYAML()).accounts, config.accounts)
    }

    func testProfilePrecedenceAndUsernameAliases() throws {
        let login = try identity(access: jwt(["https://api.openai.com/profile": ["email": "new@example.com", "name": "张三"]]),
                                 id: jwt(["email": "old@example.com", "preferred_username": "my-login"]))
        XCTAssertEqual(login.usernames, ["new@example.com", "my-login", "张三"])
        for key in login.usernames {
            XCTAssertEqual(try config("    \"\(key)\": jp").proxyName(for: login), "jp")
        }
        XCTAssertThrowsError(try config("    old@example.com: jp").proxyName(for: login))
        XCTAssertEqual(try config("    actual-id: none\n    new@example.com: jp").proxyName(for: login), "none")
        XCTAssertEqual(try config("    new@example.com: none\n    my-login: jp").proxyName(for: login), "none")
    }

    func testAuthFileRestrictionDefaultsAndOpenMode() throws {
        let token = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "other-id"],
                             "https://api.openai.com/profile": ["email": "other@example.com"]])
        let source = """
        listen_port: 7889
        request_timeout_seconds: 30
        auth_file: /missing/auth.json
        routing:
          account:
            other@example.com: none
        """
        let restricted = try Configuration.parse(source)
        XCTAssertTrue(restricted.account_auth_file_only)
        XCTAssertThrowsError(try restricted.resolveRoute(authorization: "Bearer \(token)", loadIdentity: {
            Identity(accountID: "local-id", accessToken: "saved-token")
        }))
        XCTAssertThrowsError(try restricted.checkCredentials())
        for yaml in [source, source.replacingOccurrences(of: "auth_file: /missing/auth.json\n", with: "")] {
            let open = try Configuration.parse(yaml + "\naccount_auth_file_only: false")
            XCTAssertFalse(open.account_auth_file_only)
            XCTAssertNoThrow(try open.checkCredentials())
            let route = try open.resolveRoute(authorization: "Bearer \(token)")
            XCTAssertEqual(route.accountID, "other-id")
            XCTAssertEqual(route.token, token)
            XCTAssertEqual(route.proxy, "none")
            XCTAssertEqual(route.upstream, "https://chatgpt.com/backend-api")
            XCTAssertNil(open.resolveMCPRoute(authorization: "Bearer \(token)", accountID: "wrong-id").credential)
            XCTAssertEqual(open.resolveMCPRoute(authorization: "Bearer \(token)", accountID: "other-id").credential?.accountID, "other-id")
            XCTAssertFalse(try Configuration.parse(open.canonicalYAML()).account_auth_file_only)
        }
        XCTAssertThrowsError(try Configuration.parse(source + "\naccount_auth_file_only: maybe"))
    }

    func testOpenModeAccountFallbackAndMalformedTokens() throws {
        let open = try Configuration.parse("""
        listen_port: 7889
        request_timeout_seconds: 30
        account_auth_file_only: false
        routing:
          account_fallback: none
        """)
        let token = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "other-id"]])
        XCTAssertEqual(try open.resolveRoute(authorization: "Bearer \(token)").accountID, "other-id")
        for token in ["opaque-token", "a.@@@.c", try jwt(["email": "other@example.com"]),
                      try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "bad\nheader"]])] {
            XCTAssertThrowsError(try open.resolveRoute(authorization: "Bearer \(token)"))
        }
        XCTAssertThrowsError(try open.resolveRoute(authorization: nil))
        let disabled = try Configuration.parse("listen_port: 7889\nrequest_timeout_seconds: 30\naccount_auth_file_only: false")
        XCTAssertThrowsError(try disabled.resolveRoute(authorization: "Bearer \(token)"))
    }

    func testMissingOrMalformedMetadataPreservesIDAndFallback() throws {
        for token in [nil, "broken", "a.@@@.c", "a.W10.c", "a.e30.c"] as [String?] {
            let login = try identity(id: token)
            XCTAssertTrue(login.usernames.isEmpty)
            XCTAssertEqual(try config("    actual-id: jp").proxyName(for: login), "jp")
            XCTAssertThrowsError(try config("    you@example.com: jp").proxyName(for: login))
            XCTAssertEqual(try config("    you@example.com: jp\n  account_fallback: none").proxyName(for: login), "none")
        }
    }
}
