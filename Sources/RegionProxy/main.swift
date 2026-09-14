import Foundation
import Darwin
import RegionProxyCore

@main
struct CodingAgentProxy {
    static func main() async {
        // This executable routes solely through YAML, not inherited shell bypass rules.
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            unsetenv(key)
        }
        var args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print("Usage: coding-agent-proxy [--config config.yaml] [--log-file path] [--check] [--write-config path]\nBinds 127.0.0.1 only. --check validates YAML, credentials, account mapping and duplicate credentials without network requests.")
            return
        }
        var check = false
        var printListenPort = false
        var path = "config.yaml"
        var logPath: String?
        var writeConfigPath: String?
        while !args.isEmpty {
            let argument = args.removeFirst()
            switch argument {
            case "--check": check = true
            case "--print-listen-port": printListenPort = true
            case "--config", "--log-file", "--write-config":
                guard !args.isEmpty, !args[0].hasPrefix("--") else {
                    FileHandle.standardError.write(Data("Missing option value. Use --help.\n".utf8)); exit(2)
                }
                let value = args.removeFirst()
                if argument == "--config" { path = value }
                else if argument == "--write-config" { writeConfigPath = value }
                else { logPath = value }
            default:
                FileHandle.standardError.write(Data("Invalid arguments. Use --help.\n".utf8)); exit(2)
            }
        }
        path = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL.path
        do {
            let config = try Configuration.read(path)
            if let destination = writeConfigPath {
                let text = try config.canonicalYAML()
                _ = try Configuration.parse(text)
                let url = URL(fileURLWithPath: NSString(string: destination).expandingTildeInPath)
                try Data(text.utf8).write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                print("Wrote configuration using base_url and routing sections.")
                return
            }
            if printListenPort {
                print(config.listen_port)
                return
            }
            if check {
                try config.checkCredentials()
                print("Configuration, credential and route are valid. Proxy reachability was not tested.")
                return
            }
            let logURL = logPath.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL }
                ?? URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("logs/proxy.log")
            let logger = try RequestLogger(fileURL: logURL)
            let forwarder = Forwarder(configuration: config, logger: logger)
            let server = try HTTPServer(port: config.listen_port) { request, client in
                await forwarder.handle(request, client: client)
            }
            try await server.start()
            print("coding-agent-proxy listening on http://127.0.0.1:\(config.listen_port)")
            print("Configuration is loaded at startup; restart to apply configuration changes. Credentials refresh per request.")
            print("Request log: \(logURL.path)")
            logger.write("server_started", ["listen": "127.0.0.1:\(config.listen_port)", "log_file": logURL.path])
            await forwarder.logCurrentRoute()
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signals = [SIGINT, SIGTERM].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { logger.write("server_stopped"); server.stop(); exit(0) }
                source.resume()
                return source
            }
            defer { withExtendedLifetime(signals) {} }
            while true { try await Task.sleep(for: .seconds(3600)) }
        } catch {
            let message = (error as? ProxyError)?.message ?? "Unable to start server. Check the port and configuration."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
