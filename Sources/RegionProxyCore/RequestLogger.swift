import Foundation

/// Line-delimited JSON, serialized across concurrent requests. Callers supply metadata only.
public final class RequestLogger: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL
    private let console: FileHandle?
    private let maxBytes: UInt64
    private var handle: FileHandle
    private var reportedFailure = false
    private let timestamp = ISO8601DateFormatter()

    public init(fileURL: URL, console: FileHandle? = .standardError, maxBytes: UInt64 = 5 * 1024 * 1024) throws {
        self.fileURL = fileURL
        self.console = console
        self.maxBytes = maxBytes
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            self.handle = try Self.open(fileURL)
        } catch { throw ProxyError("Cannot open request log file. Check its path and write permissions.") }
    }

    deinit { try? handle.close() }

    private static func open(_ url: URL) throws -> FileHandle {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw ProxyError("Cannot create log file.")
            }
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try FileHandle(forWritingTo: url)
    }

    public func write(_ event: String, _ fields: [String: String] = [:]) {
        lock.withLock {
            var record = fields
            record["timestamp"] = timestamp.string(from: Date())
            record["event"] = event
            guard var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
            line.append(10)
            if let console { try? console.write(contentsOf: line) }
            do {
                let length = try handle.seekToEnd()
                if length > 0 && length + UInt64(line.count) > maxBytes {
                    let backup = URL(fileURLWithPath: fileURL.path + ".1")
                    if FileManager.default.fileExists(atPath: backup.path) { try FileManager.default.removeItem(at: backup) }
                    try FileManager.default.moveItem(at: fileURL, to: backup)
                    try handle.close()
                    handle = try Self.open(fileURL)
                }
                try handle.write(contentsOf: line)
                reportedFailure = false
            } catch {
                if !reportedFailure {
                    let warning = Data("{\"event\":\"logging_error\",\"message\":\"Cannot write request log; console logging continues.\"}\n".utf8)
                    try? console?.write(contentsOf: warning)
                    reportedFailure = true
                }
            }
        }
    }
}
