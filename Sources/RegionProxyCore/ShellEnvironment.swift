import Foundation
import Darwin

enum ShellEnvironment {
    /// Resolve one exported variable through the user's login/interactive shell.
    /// Startup output is discarded; only printenv's private result is returned.
    static func value(for name: String, environment: [String: String]) throws -> String {
        guard name.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else {
            throw ProxyError("Invalid API Key environment variable name.")
        }
        let accountShell = getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let shell = environment["SHELL"] ?? accountShell
        guard ["zsh", "bash", "sh"].contains(URL(fileURLWithPath: shell).lastPathComponent),
              shell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: shell) else {
            throw ProxyError("Shell credential lookup requires zsh, bash or sh.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.environment = environment
        process.arguments = ["-I", "-c", """
        import os, pathlib, signal, subprocess, sys, tempfile
        os.umask(0o077)
        with tempfile.TemporaryDirectory(prefix='coding-proxy-env-') as directory:
            output = pathlib.Path(directory) / 'value'
            command = 'exec /usr/bin/printenv "$1" > "$2"'
            child = subprocess.Popen([sys.argv[1], '-l', '-i', '-c', command,
                'coding-agent-proxy', sys.argv[2], str(output)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, start_new_session=True)
            try:
                status = child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
                sys.exit(1)
            if status != 0 or not output.exists() or output.stat().st_size > 65536:
                sys.exit(1)
            sys.stdout.buffer.write(output.read_bytes())
        """, shell, name]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw ProxyError("Cannot start shell credential lookup.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw ProxyError("API Key environment variable is unavailable in the process and shell configuration, or shell lookup timed out.")
        }
        return value
    }
}
