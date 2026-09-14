import Foundation

/// A scalar keeps existing behavior; a list opts into ordered availability probes.
public struct ProxyChoice: Codable, Sendable, Equatable, ExpressibleByStringLiteral {
    public let candidates: [String]
    public let isList: Bool
    public var label: String { isList ? "[" + candidates.joined(separator: ", ") + "]" : candidates[0] }

    public init(stringLiteral value: String) {
        candidates = [value]
        isList = false
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let name = try? value.decode(String.self) {
            candidates = [name]
            isList = false
        } else {
            candidates = try value.decode([String].self)
            isList = true
        }
        guard !candidates.isEmpty, candidates.allSatisfy({ !$0.isEmpty }) else {
            throw ProxyError("Proxy selection must be a nonempty name or nonempty list of names.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        if isList { try value.encode(candidates) }
        else { try value.encode(candidates[0]) }
    }

    public func isValid(in proxies: [String: String]) -> Bool {
        candidates.allSatisfy { $0 == "none" || proxies[$0] != nil }
    }
}
