import Foundation
import Network

public struct HTTPRequest: Sendable {
    public var method: String
    public var target: String
    public var headers: [String: String]
    public var body: Data
}

struct HTTPFailure: Error {
    let status: Int
    let message: String
}

/// One request per connection; bounded HTTP/1.1 parsing, including chunked uploads.
public enum HTTPParser {
    public static let maxBody = 32 * 1024 * 1024
    public static let maxHeader = 64 * 1024

    public static func parse(_ data: Data) throws -> HTTPRequest? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeader { throw HTTPFailure(status: 431, message: "Headers too large") }
            return nil
        }
        guard range.upperBound <= maxHeader,
              let text = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw HTTPFailure(status: 400, message: "Invalid headers")
        }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count == 3, ["HTTP/1.1", "HTTP/1.0"].contains(parts[2]),
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"), !parts[1].contains("#") else {
            throw HTTPFailure(status: 400, message: "Invalid request line")
        }
        var headers: [String: String] = [:]
        let tokenCharacters = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPFailure(status: 400, message: "Invalid header") }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) }),
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else {
                throw HTTPFailure(status: 400, message: "Invalid header")
            }
            guard headers[key] == nil else { throw HTTPFailure(status: 400, message: "Duplicate header") }
            headers[key] = value
        }
        if headers["expect"] != nil { throw HTTPFailure(status: 417, message: "Expect is unsupported") }
        let start = range.upperBound
        let body: Data
        if let transfer = headers["transfer-encoding"] {
            guard transfer.lowercased() == "chunked", headers["content-length"] == nil else {
                throw HTTPFailure(status: 400, message: "Ambiguous or unsupported body framing")
            }
            guard let decoded = try decodeChunks(data, start: start) else { return nil }
            body = decoded
        } else {
            let raw = headers["content-length"] ?? "0"
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }), let length = Int(raw) else {
                throw HTTPFailure(status: 400, message: "Invalid Content-Length")
            }
            guard length <= maxBody else { throw HTTPFailure(status: 413, message: "Body too large") }
            guard data.count - start >= length else { return nil }
            body = data.subdata(in: start..<(start + length))
        }
        return HTTPRequest(method: String(parts[0]), target: String(parts[1]), headers: headers, body: body)
    }

    private static func decodeChunks(_ data: Data, start: Int) throws -> Data? {
        var cursor = start
        var body = Data()
        while true {
            guard let end = data.range(of: Data("\r\n".utf8), in: cursor..<data.count) else { return nil }
            guard end.lowerBound - cursor < 1024,
                  let line = String(data: data[cursor..<end.lowerBound], encoding: .utf8),
                  let sizeText = line.split(separator: ";").first,
                  !sizeText.isEmpty, sizeText.allSatisfy({ $0.isHexDigit }),
                  let size = Int(sizeText, radix: 16) else {
                throw HTTPFailure(status: 400, message: "Invalid chunk size")
            }
            cursor = end.upperBound
            guard size <= maxBody - body.count else { throw HTTPFailure(status: 413, message: "Body too large") }
            if size == 0 {
                guard data.count - cursor >= 2 else { return nil }
                // Trailers are not forwarded, but their terminator must be complete.
                if data[cursor..<(cursor + 2)] == Data("\r\n".utf8) { return body }
                guard let trailers = data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count) else { return nil }
                guard trailers.upperBound - cursor <= maxHeader else { throw HTTPFailure(status: 431, message: "Trailers too large") }
                return body
            }
            guard data.count - cursor >= size + 2 else { return nil }
            guard data[(cursor + size)..<(cursor + size + 2)] == Data("\r\n".utf8) else {
                throw HTTPFailure(status: 400, message: "Invalid chunk terminator")
            }
            body.append(data[cursor..<(cursor + size)])
            cursor += size + 2
        }
    }
}

public final class HTTPConnection: @unchecked Sendable {
    let connection: NWConnection
    init(_ connection: NWConnection) { self.connection = connection }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            })
        }
    }

    func readRequest() async throws -> HTTPRequest {
        var buffer = Data()
        while true {
            let (data, ended) = try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let error { c.resume(throwing: error) } else { c.resume(returning: (data ?? Data(), complete)) }
                }
            }
            buffer.append(data)
            guard buffer.count <= HTTPParser.maxBody + 2 * HTTPParser.maxHeader else {
                throw HTTPFailure(status: 413, message: "Request too large")
            }
            if let request = try HTTPParser.parse(buffer) { return request }
            if ended { throw HTTPFailure(status: 400, message: "Incomplete request") }
        }
    }

    public func error(status: Int, message: String) async {
        let body = (try? JSONSerialization.data(withJSONObject: ["error": ["message": message]])) ?? Data()
        let header = "HTTP/1.1 \(status) Error\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        try? await write(Data(header.utf8) + body)
    }
}

public final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "coding-agent-proxy.listener")
    private let handler: @Sendable (HTTPRequest, HTTPConnection) async -> Void
    private let lock = NSLock()
    private var connections: [UUID: NWConnection] = [:]

    public init(port: UInt16, handler: @escaping @Sendable (HTTPRequest, HTTPConnection) async -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    public var port: UInt16? { listener.port?.rawValue }

    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // Listener state callbacks run on the serial listener queue.
            let gate = StartGate()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if gate.take() { c.resume() }
                case .failed(let error): if gate.take() { c.resume(throwing: error) }
                case .cancelled: if gate.take() { c.resume(throwing: ProxyError("Listener cancelled")) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        lock.withLock { for c in connections.values { c.cancel() }; connections.removeAll() }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let admitted = lock.withLock {
            if connections.count >= 128 { return false }
            connections[id] = connection
            return true
        }
        guard admitted else { connection.cancel(); return }
        connection.start(queue: queue)
        let client = HTTPConnection(connection)
        let task = Task {
            defer {
                connection.stateUpdateHandler = nil
                connection.cancel()
                _ = self.lock.withLock { self.connections.removeValue(forKey: id) }
            }
            let deadline = Task {
                try await Task.sleep(for: .seconds(30))
                connection.cancel()
            }
            do {
                let request = try await client.readRequest()
                deadline.cancel()
                await handler(request, client)
            } catch let error as HTTPFailure {
                deadline.cancel()
                await client.error(status: error.status, message: error.message)
            } catch { deadline.cancel() }
        }
        connection.stateUpdateHandler = { state in
            if case .cancelled = state { task.cancel() }
            if case .failed = state { task.cancel() }
        }
    }
}

private final class StartGate: @unchecked Sendable {
    let lock = NSLock()
    var pending = true
    func take() -> Bool { lock.withLock { if !pending { return false }; pending = false; return true } }
}
