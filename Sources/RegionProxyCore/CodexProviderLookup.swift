import Foundation

/// Read only routing metadata from Codex TOML; never evaluate configuration as code.
enum CodexProviderLookup {
    struct Definition: Decodable, Sendable {
        let id: String
        let env_key: String?
        let base_url: String?
    }

    static func definitions(environment: [String: String]) throws -> [Definition] {
        let home = environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        let config = URL(fileURLWithPath: home).appendingPathComponent("config.toml")
        if !FileManager.default.fileExists(atPath: config.path) {
            return [Definition(id: "openai", env_key: "OPENAI_API_KEY", base_url: nil)]
        }
        // Use a standards-compliant TOML parser, including quoted IDs and inline tables.
        // Only IDs, environment variable names and base URLs cross the pipe; never key values.
        guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProxyError("Codex provider lookup requires Homebrew Python 3.11+.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", "-c", """
        import json, sys, tomllib
        with open(sys.argv[1], 'rb') as f:
            data = tomllib.load(f)
        result = [{'id': 'openai', 'env_key': 'OPENAI_API_KEY', 'base_url': data.get('openai_base_url')}]
        for name, provider in data.get('model_providers', {}).items():
            if name == 'openai':
                raise ValueError('reserved provider ID')
            key = provider.get('env_key')
            if provider.get('requires_openai_auth') is True:
                continue
            if key is not None and (not isinstance(key, str) or not key.strip()):
                raise ValueError('invalid env_key')
            result.append({'id': name, 'env_key': key, 'base_url': provider.get('base_url')})
        print(json.dumps(result))
        """, config.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ProxyError("Cannot start Codex provider configuration reader.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let definitions = try? JSONDecoder().decode([Definition].self, from: data) else {
            throw ProxyError("Cannot resolve provider env_key; check Codex config.toml and Python 3.11+.")
        }
        return definitions
    }
}
